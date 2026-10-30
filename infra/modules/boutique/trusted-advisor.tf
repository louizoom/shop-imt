# AWS Trusted Advisor : contrôles de bonnes pratiques du compte (sécurité, quotas de service, tolérance aux pannes).
# Avec le support Basic, seuls les contrôles de base sont disponibles et l'API Trusted Advisor est refusée,
# mais chaque rafraîchissement de contrôle émet un événement EventBridge, gratuit, dans us-east-1.
# Une règle envoie les contrôles qui passent en orange (WARN) ou rouge (ERROR) sur un topic SNS, puis par e-mail.
# Les contrôles portent sur tout le compte : la règle n'existe qu'en prod, pour ne pas recevoir chaque alerte deux fois.
locals {
  trusted_advisor = var.environnement == "prod" && var.budget_email != ""
}

resource "aws_sns_topic" "trusted_advisor" {
  count    = local.trusted_advisor ? 1 : 0
  provider = aws.us_east_1
  name     = "${var.prefix}-trusted-advisor"
}

resource "aws_sns_topic_policy" "trusted_advisor" {
  count    = local.trusted_advisor ? 1 : 0
  provider = aws.us_east_1
  arn      = aws_sns_topic.trusted_advisor[0].arn
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "sns:Publish"
      Resource  = aws_sns_topic.trusted_advisor[0].arn
      Condition = { ArnEquals = { "aws:SourceArn" = aws_cloudwatch_event_rule.trusted_advisor[0].arn } }
    }]
  })
}

# Abonnement e-mail : AWS envoie un lien de confirmation à cliquer une fois.
resource "aws_sns_topic_subscription" "trusted_advisor" {
  count     = local.trusted_advisor ? 1 : 0
  provider  = aws.us_east_1
  topic_arn = aws_sns_topic.trusted_advisor[0].arn
  protocol  = "email"
  endpoint  = var.budget_email
}

resource "aws_cloudwatch_event_rule" "trusted_advisor" {
  count       = local.trusted_advisor ? 1 : 0
  provider    = aws.us_east_1
  name        = "${var.prefix}-trusted-advisor"
  description = "Controles Trusted Advisor passes en WARN ou ERROR"
  event_pattern = jsonencode({
    source        = ["aws.trustedadvisor"]
    "detail-type" = ["Trusted Advisor Check Item Refresh Notification"]
    detail        = { status = ["WARN", "ERROR"] }
  })
}

resource "aws_cloudwatch_event_target" "trusted_advisor" {
  count     = local.trusted_advisor ? 1 : 0
  provider  = aws.us_east_1
  rule      = aws_cloudwatch_event_rule.trusted_advisor[0].name
  target_id = "sns"
  arn       = aws_sns_topic.trusted_advisor[0].arn

  input_transformer {
    input_paths = {
      controle  = "$.detail.check-name"
      statut    = "$.detail.status"
      ressource = "$.detail.resource_id"
      region    = "$.region"
    }
    input_template = "\"SHOP'IMT - Trusted Advisor : le contrôle « <controle> » est en <statut> (ressource <ressource>, <region>). Détails : https://console.aws.amazon.com/trustedadvisor\""
  }
}
