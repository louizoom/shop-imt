# Rôles IAM des instances (profils d'instance) : identifiants temporaires fournis par l'IMDSv2,
# aucune clé d'accès sur les serveurs. Moindre privilège : chaque rôle n'a que ce que son serveur utilise.

data "aws_iam_policy_document" "confiance_ec2" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

locals {
  roles = {
    web = {
      SNS = { actions = ["sns:Publish"], resources = [aws_sns_topic.commandes.arn] }
    }
    traitement = {
      SQS   = { actions = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:ChangeMessageVisibility"], resources = [aws_sqs_queue.traitement.arn] }
      Audit = { actions = ["s3:PutObject"], resources = ["${aws_s3_bucket.ec2.arn}/audit/*", "${aws_s3_bucket.ec2.arn}/kafka/*"] }
      Kafka = { actions = ["s3:GetObject"], resources = ["${aws_s3_bucket.ec2.arn}/kafka/*"] }
      # E-mails : mêmes droits que la Lambda notification (envoi, et demande de vérification en sandbox SES)
      SES = { actions = ["ses:SendEmail", "ses:CreateEmailIdentity", "ses:TagResource"], resources = ["*"] }
    }
  }
  communs = {
    Code       = { actions = ["s3:GetObject"], resources = ["${aws_s3_bucket.ec2.arn}/code/*"] }
    MotDePasse = { actions = ["ssm:GetParameter"], resources = [aws_ssm_parameter.bdd.arn] }
  }
}

resource "aws_iam_role" "instance" {
  for_each           = local.roles
  name               = "${var.prefix}-${each.key}"
  assume_role_policy = data.aws_iam_policy_document.confiance_ec2.json
}

data "aws_iam_policy_document" "instance" {
  for_each = local.roles
  dynamic "statement" {
    for_each = merge(local.communs, each.value)
    content {
      sid       = statement.key
      actions   = statement.value.actions
      resources = statement.value.resources
    }
  }
}

resource "aws_iam_role_policy" "instance" {
  for_each = local.roles
  name     = "moindre-privilege"
  role     = aws_iam_role.instance[each.key].id
  policy   = data.aws_iam_policy_document.instance[each.key].json
}

# Session Manager (console sans SSH ni port ouvert) et agent CloudWatch (logs, mémoire) : politiques gérées AWS
resource "aws_iam_role_policy_attachment" "ssm" {
  for_each   = local.roles
  role       = aws_iam_role.instance[each.key].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "cloudwatch" {
  for_each   = local.roles
  role       = aws_iam_role.instance[each.key].name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_iam_instance_profile" "instance" {
  for_each = local.roles
  name     = "${var.prefix}-${each.key}"
  role     = aws_iam_role.instance[each.key].name
}
