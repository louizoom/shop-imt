# Calcul : serveurs web dans un Auto Scaling group sur deux zones, derrière un Application Load Balancer,
# et un serveur de traitement (workers + broker Kafka) protégé par la récupération automatique EC2.

# Dernière Amazon Linux 2023 publiée par AWS (paramètre public SSM)
data "aws_ssm_parameter" "ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

locals {
  ip_kafka = cidrhost(aws_subnet.public[0].cidr_block, 10) # IP privée fixe du serveur de traitement
  site_url = "https://${aws_cloudfront_distribution.site.domain_name}"
  user_data = {
    for role in ["web", "traitement"] : role => templatefile("${path.module}/user_data/serveur.sh.tftpl", {
      role            = role
      region          = local.region
      bucket          = aws_s3_bucket.ec2.id
      cle_application = aws_s3_object.application.key
      cle_site        = aws_s3_object.site.key
      bdd_hote        = aws_db_instance.bdd.address
      bdd_parametre   = aws_ssm_parameter.bdd.name
      topic           = aws_sns_topic.commandes.arn
      file            = aws_sqs_queue.traitement.url
      kafka           = local.ip_kafka
      expediteur      = var.expediteur
      site_url        = local.site_url
      delai_max       = var.delai_max_s
      version_kafka   = var.version_kafka
      groupe_logs     = aws_cloudwatch_log_group.serveurs[role].name
    })
  }
}

# ---------- Serveurs web

resource "aws_launch_template" "web" {
  name                   = "${var.prefix}-web"
  image_id               = data.aws_ssm_parameter.ami.insecure_value
  instance_type          = var.type_instance
  vpc_security_group_ids = [aws_security_group.web.id]
  user_data              = base64encode(local.user_data["web"])
  update_default_version = true

  iam_instance_profile {
    arn = aws_iam_instance_profile.instance["web"].arn
  }

  metadata_options {
    http_tokens                 = "required" # IMDSv2 uniquement
    http_put_response_hop_limit = 1
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size = 8 # Go ; 30 Go d'EBS gratuits au total
      volume_type = "gp3"
      encrypted   = true
    }
  }

  credit_specification {
    cpu_credits = "standard" # pas de surcoût « unlimited » si le CPU reste haut
  }

  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "${var.prefix}-web" }
  }
}

resource "aws_autoscaling_group" "web" {
  name                      = "${var.prefix}-web"
  min_size                  = var.serveurs_web_min
  max_size                  = var.serveurs_web_max
  vpc_zone_identifier       = aws_subnet.public[*].id # une instance remplacée peut repartir dans l'autre zone
  target_group_arns         = [aws_lb_target_group.web.arn]
  health_check_type         = "ELB" # une instance que l'ALB juge malade est remplacée
  health_check_grace_period = 600   # installation des paquets au premier démarrage
  default_instance_warmup   = 300

  launch_template {
    id      = aws_launch_template.web.id
    version = aws_launch_template.web.latest_version
  }

  # Nouvelle version du code : remplacement progressif, la nouvelle instance est saine avant l'arrêt de l'ancienne
  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 100
      max_healthy_percentage = 200
      instance_warmup        = 300
    }
  }

  tag {
    key                 = "Name"
    value               = "${var.prefix}-web"
    propagate_at_launch = true
  }

  # Les règles de sortie doivent exister avant le premier démarrage (paquets, S3, SSM)
  depends_on = [aws_vpc_security_group_egress_rule.https, aws_vpc_security_group_egress_rule.http, aws_vpc_security_group_egress_rule.mysql]
}

# Élasticité : une 2e instance si le CPU moyen dépasse 60 %, retour à 1 quand la charge retombe
resource "aws_autoscaling_policy" "cpu" {
  name                   = "${var.prefix}-cpu-60"
  autoscaling_group_name = aws_autoscaling_group.web.name
  policy_type            = "TargetTrackingScaling"
  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = 60
  }
}

# ---------- Application Load Balancer (750 h/mois gratuites, Free Tier 12 mois)

resource "aws_lb" "web" {
  name               = var.prefix
  load_balancer_type = "application"
  subnets            = aws_subnet.public[*].id
  security_groups    = [aws_security_group.alb.id]
  idle_timeout       = 30
}

resource "aws_lb_target_group" "web" {
  name                 = "${var.prefix}-web"
  port                 = 8080
  protocol             = "HTTP"
  vpc_id               = aws_vpc.principal.id
  deregistration_delay = 30

  health_check {
    path                = "/sante" # répond 503 si l'instance n'atteint plus RDS
    interval            = 15
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.web.arn
  port              = 80
  protocol          = "HTTP"
  # Sans l'en-tête de CloudFront (règle dans cloudfront.tf) : refus
  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "Acces direct refuse"
      status_code  = "403"
    }
  }
}

# ---------- Serveur de traitement (workers SQS et Kafka, broker Kafka)

resource "aws_instance" "traitement" {
  ami                         = data.aws_ssm_parameter.ami.insecure_value
  instance_type               = var.type_instance
  subnet_id                   = aws_subnet.public[0].id
  private_ip                  = local.ip_kafka
  vpc_security_group_ids      = [aws_security_group.traitement.id]
  iam_instance_profile        = aws_iam_instance_profile.instance["traitement"].name
  user_data                   = local.user_data["traitement"]
  user_data_replace_on_change = true # nouvelle version du code : instance recréée, les commandes attendent dans SQS

  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_size = 10
    volume_type = "gp3"
    encrypted   = true
  }

  credit_specification {
    cpu_credits = "standard"
  }

  tags = { Name = "${var.prefix}-traitement" }

  lifecycle {
    ignore_changes = [ami] # pas de remplacement à chaque nouvelle AMI publiée
  }

  # Les règles de sortie doivent exister avant le premier démarrage (paquets, S3, SSM)
  depends_on = [aws_vpc_security_group_egress_rule.https, aws_vpc_security_group_egress_rule.http, aws_vpc_security_group_egress_rule.mysql]
}

# Récupération automatique : si l'hôte physique tombe en panne, EC2 redémarre l'instance ailleurs
# avec la même IP privée et le même disque (action gratuite, alarme dans les 10 gratuites)
resource "aws_cloudwatch_metric_alarm" "recuperation" {
  alarm_name          = "${var.prefix}-traitement-recuperation"
  alarm_description   = "Panne matérielle du serveur de traitement : récupération automatique EC2"
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed_System"
  dimensions          = { InstanceId = aws_instance.traitement.id }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  alarm_actions       = ["arn:aws:automate:${local.region}:ec2:recover"]
}
