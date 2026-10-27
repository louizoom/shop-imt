# Alarme CloudWatch (10 alarmes gratuites) : un message en DLQ = une commande
# dont le traitement ou l'audit a échoué 3 fois.
resource "aws_cloudwatch_metric_alarm" "dlq" {
  alarm_name          = "${var.prefix}-dlq-non-vide"
  alarm_description   = "Des commandes n'ont pas pu être traitées ou auditées"
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

# Budget mensuel à 1 USD (les 2 premiers budgets sont gratuits).
resource "aws_budgets_budget" "mensuel" {
  count        = var.budget_email == "" ? 0 : 1
  name         = "${var.prefix}-budget"
  budget_type  = "COST"
  limit_amount = "1"
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 1
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.budget_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.budget_email]
  }
}

# Tableau de bord CloudWatch (3 gratuits) : la vue d'ensemble pour la démo.
# Métriques métier Commandes et ChiffreAffaires : écrites par la Lambda publication au format EMF
# (une ligne de journal convertie par CloudWatch, 2 métriques personnalisées sur 10 gratuites).
locals {
  fonctions    = [for k in keys(local.lambdas) : "${var.prefix}-${k}"]
  metriques_ns = "SHOPIMT/${var.prefix}"
}

resource "aws_cloudwatch_dashboard" "boutique" {
  dashboard_name = "${var.prefix}-tableau-de-bord"
  dashboard_body = jsonencode({
    widgets = [
      {
        type = "metric", x = 0, y = 0, width = 12, height = 6
        properties = {
          title = "API : requêtes et erreurs", region = var.region, stat = "Sum", period = 60
          metrics = [
            ["AWS/ApiGateway", "Count", "ApiId", aws_apigatewayv2_api.api.id],
            [".", "4xx", ".", "."],
            [".", "5xx", ".", "."],
          ]
        }
      },
      {
        type = "metric", x = 12, y = 0, width = 12, height = 6
        properties = {
          title = "API : latence (ms)", region = var.region, period = 60
          metrics = [
            ["AWS/ApiGateway", "Latency", "ApiId", aws_apigatewayv2_api.api.id, { stat = "p50" }],
            ["...", { stat = "p95" }],
          ]
        }
      },
      {
        type = "metric", x = 0, y = 18, width = 12, height = 6
        properties = {
          title   = "Ventes : commandes par heure", region = var.region, stat = "Sum", period = 3600
          metrics = [[local.metriques_ns, "Commandes", "Boutique", "SHOP'IMT"]]
        }
      },
      {
        type = "metric", x = 12, y = 18, width = 12, height = 6
        properties = {
          title   = "Ventes : chiffre d'affaires par heure (EUR)", region = var.region, stat = "Sum", period = 3600
          metrics = [[local.metriques_ns, "ChiffreAffaires", "Boutique", "SHOP'IMT"]]
        }
      },
      {
        type = "metric", x = 0, y = 6, width = 12, height = 6
        properties = {
          title   = "Lambda : invocations", region = var.region, stat = "Sum", period = 60
          metrics = [for f in local.fonctions : ["AWS/Lambda", "Invocations", "FunctionName", f]]
        }
      },
      {
        type = "metric", x = 12, y = 6, width = 12, height = 6
        properties = {
          title   = "Lambda : erreurs", region = var.region, stat = "Sum", period = 60
          metrics = [for f in local.fonctions : ["AWS/Lambda", "Errors", "FunctionName", f]]
        }
      },
      {
        type = "metric", x = 0, y = 12, width = 12, height = 6
        properties = {
          title = "Files SQS : messages en attente", region = var.region, stat = "Maximum", period = 60
          metrics = [for q in [aws_sqs_queue.traitement, aws_sqs_queue.audit, aws_sqs_queue.dlq] :
          ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", q.name]]
        }
      },
      {
        type = "metric", x = 12, y = 12, width = 12, height = 6
        properties = {
          title = "SNS et DynamoDB", region = var.region, stat = "Sum", period = 60
          metrics = [
            ["AWS/SNS", "NumberOfMessagesPublished", "TopicName", aws_sns_topic.commandes.name],
            ["AWS/DynamoDB", "ConsumedWriteCapacityUnits", "TableName", aws_dynamodb_table.commandes.name],
            ["AWS/DynamoDB", "ConsumedReadCapacityUnits", "TableName", aws_dynamodb_table.produits.name],
          ]
        }
      },
    ]
  })
}

# --- CloudTrail (optionnel) : journal des actions sur le compte (qui a créé / supprimé quoi).
# Le 1er trail d'événements de gestion est gratuit ; seul le stockage S3 des journaux est facturé
# (quelques centimes par mois). Désactivé par défaut : l'historique de 90 jours reste consultable
# gratuitement dans la console CloudTrail, sans trail.

resource "aws_s3_bucket" "trail" {
  count         = var.activer_cloudtrail ? 1 : 0
  bucket        = "${var.prefix}-trail-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "trail" {
  count                   = var.activer_cloudtrail ? 1 : 0
  bucket                  = aws_s3_bucket.trail[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "trail" {
  count  = var.activer_cloudtrail ? 1 : 0
  bucket = aws_s3_bucket.trail[0].id

  rule {
    id     = "expiration-30-jours"
    status = "Enabled"
    filter {}
    expiration {
      days = 30
    }
  }
}

data "aws_iam_policy_document" "trail" {
  count = var.activer_cloudtrail ? 1 : 0

  statement {
    sid       = "VerificationAcl"
    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.trail[0].arn]
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
  }

  statement {
    sid       = "EcritureJournaux"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.trail[0].arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"]
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }
  }
}

resource "aws_s3_bucket_policy" "trail" {
  count      = var.activer_cloudtrail ? 1 : 0
  bucket     = aws_s3_bucket.trail[0].id
  policy     = data.aws_iam_policy_document.trail[0].json
  depends_on = [aws_s3_bucket_public_access_block.trail]
}

resource "aws_cloudtrail" "compte" {
  count                         = var.activer_cloudtrail ? 1 : 0
  name                          = "${var.prefix}-trail"
  s3_bucket_name                = aws_s3_bucket.trail[0].id
  include_global_service_events = true
  is_multi_region_trail         = false # une seule région : moins de fichiers, donc moins de requêtes S3
  depends_on                    = [aws_s3_bucket_policy.trail]
}
