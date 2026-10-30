# CloudWatch : logs des serveurs (agent CloudWatch), alarmes et tableau de bord de la solution EC2

resource "aws_cloudwatch_log_group" "serveurs" {
  for_each          = toset(["web", "traitement"])
  name              = "/shopimt/${var.prefix}/${each.key}"
  retention_in_days = var.log_retention_days
}

resource "aws_cloudwatch_log_group" "rds" {
  name              = "/aws/rds/instance/${var.prefix}/error"
  retention_in_days = var.log_retention_days
}

resource "aws_cloudwatch_metric_alarm" "web_malade" {
  alarm_name          = "${var.prefix}-web-aucune-instance-saine"
  alarm_description   = "Aucun serveur web sain derrière l'ALB"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HealthyHostCount"
  dimensions          = { LoadBalancer = aws_lb.web.arn_suffix, TargetGroup = aws_lb_target_group.web.arn_suffix }
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 5
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"
}

resource "aws_cloudwatch_metric_alarm" "dlq" {
  alarm_name          = "${var.prefix}-dlq-non-vide"
  alarm_description   = "Des commandes de la solution EC2 ont échoué 3 fois (file d'erreurs)"
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  dimensions          = { QueueName = aws_sqs_queue.dlq.name }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
}

resource "aws_cloudwatch_dashboard" "ec2" {
  dashboard_name = var.prefix
  dashboard_body = jsonencode({
    widgets = [
      { type = "metric", x = 0, y = 0, width = 12, height = 6, properties = {
        title = "ALB : requêtes et erreurs", region = local.region, stat = "Sum", period = 60
        metrics = [
          ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", aws_lb.web.arn_suffix],
          [".", "HTTPCode_Target_5XX_Count", ".", "."],
          [".", "HTTPCode_ELB_5XX_Count", ".", "."],
        ]
      } },
      { type = "metric", x = 12, y = 0, width = 12, height = 6, properties = {
        title = "Serveurs web sains et temps de réponse", region = local.region, period = 60
        metrics = [
          ["AWS/ApplicationELB", "HealthyHostCount", "TargetGroup", aws_lb_target_group.web.arn_suffix, "LoadBalancer", aws_lb.web.arn_suffix, { stat = "Minimum" }],
          [".", "TargetResponseTime", "LoadBalancer", aws_lb.web.arn_suffix, { stat = "Average", yAxis = "right" }],
        ]
      } },
      { type = "metric", x = 0, y = 6, width = 12, height = 6, properties = {
        title = "CPU des instances (%)", region = local.region, stat = "Average", period = 300
        metrics = [
          ["AWS/EC2", "CPUUtilization", "AutoScalingGroupName", aws_autoscaling_group.web.name],
          [".", ".", "InstanceId", aws_instance.traitement.id],
          ["AWS/RDS", "CPUUtilization", "DBInstanceIdentifier", aws_db_instance.bdd.identifier],
        ]
      } },
      { type = "metric", x = 12, y = 6, width = 12, height = 6, properties = {
        title = "RDS et file de traitement", region = local.region, period = 60
        metrics = [
          ["AWS/RDS", "DatabaseConnections", "DBInstanceIdentifier", aws_db_instance.bdd.identifier, { stat = "Maximum" }],
          ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", aws_sqs_queue.traitement.name, { stat = "Maximum" }],
          ["AWS/SNS", "NumberOfMessagesPublished", "TopicName", aws_sns_topic.commandes.name, { stat = "Sum" }],
        ]
      } },
      { type = "log", x = 0, y = 12, width = 24, height = 6, properties = {
        title = "Commandes et étapes (serveurs EC2)", region = local.region, view = "table"
        query = "SOURCE '${aws_cloudwatch_log_group.serveurs["web"].name}' | SOURCE '${aws_cloudwatch_log_group.serveurs["traitement"].name}' | fields @timestamp, evenement, order_id, statut | filter ispresent(evenement) | sort @timestamp desc | limit 50"
      } },
    ]
  })
}
