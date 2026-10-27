# Modèle événementiel : la Lambda "publication" (déclenchée par le flux DynamoDB) publie un événement COMMANDE_CREEE
# sur un topic SNS, qui le diffuse (fan-out) vers :
#   - la file SQS "traitement" (préparation, expédition et livraison simulées par Step Functions)
#   - la file SQS "audit" (archivage S3 pour audit / reporting)
#   - la Lambda "notification" (e-mail HTML de confirmation via SES)

resource "aws_sns_topic" "commandes" {
  name = "${var.prefix}-commandes"
}

resource "aws_sqs_queue" "dlq" {
  name                      = "${var.prefix}-dlq"
  message_retention_seconds = 1209600 # 14 jours
  sqs_managed_sse_enabled   = true
}

resource "aws_sqs_queue" "traitement" {
  name                       = "${var.prefix}-traitement"
  visibility_timeout_seconds = 60 # >= 6 x timeout de la Lambda (10 s)
  sqs_managed_sse_enabled    = true
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = 3
  })
}

resource "aws_sqs_queue" "audit" {
  name                       = "${var.prefix}-audit"
  visibility_timeout_seconds = 60
  sqs_managed_sse_enabled    = true
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = 3
  })
}

locals {
  files_abonnees = {
    traitement = aws_sqs_queue.traitement
    audit      = aws_sqs_queue.audit
  }
}

data "aws_iam_policy_document" "sqs_depuis_sns" {
  for_each = local.files_abonnees

  statement {
    sid       = "AutoriserSNS"
    actions   = ["sqs:SendMessage"]
    resources = [each.value.arn]

    principals {
      type        = "Service"
      identifiers = ["sns.amazonaws.com"]
    }

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_sns_topic.commandes.arn]
    }
  }
}

resource "aws_sqs_queue_policy" "depuis_sns" {
  for_each  = local.files_abonnees
  queue_url = each.value.id
  policy    = data.aws_iam_policy_document.sqs_depuis_sns[each.key].json
}

resource "aws_sns_topic_subscription" "sqs" {
  for_each             = local.files_abonnees
  topic_arn            = aws_sns_topic.commandes.arn
  protocol             = "sqs"
  endpoint             = each.value.arn
  raw_message_delivery = true

  depends_on = [aws_sqs_queue_policy.depuis_sns]
}

# Confirmation client : une Lambda abonnée au topic envoie un e-mail HTML via SES
# (logo, photos des articles, bouton de suivi). SNS seul ne sait envoyer que du texte brut.
resource "aws_sns_topic_subscription" "notification" {
  count     = var.notification_email == "" ? 0 : 1
  topic_arn = aws_sns_topic.commandes.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.fn["notification"].arn
}

resource "aws_lambda_permission" "sns" {
  statement_id  = "AutoriserSNS"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.fn["notification"].function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.commandes.arn
}

# Amazon SES : en mode « sandbox » (par défaut), l'expéditeur ET chaque destinataire doivent être
# des adresses vérifiées. AWS envoie un e-mail de vérification à chacune après l'apply.
# Les identités SES sont propres au compte : un seul environnement les gère (gerer_identites_ses).
resource "aws_sesv2_email_identity" "adresse" {
  for_each       = var.gerer_identites_ses ? toset(compact(concat([var.notification_email], var.emails_verifies))) : toset([])
  email_identity = each.value
}

# Domaine d'envoi (Easy DKIM) : les e-mails sont signés par SES pour ce domaine, ce qui évite
# le dossier spam et permet de demander la sortie du sandbox. Les 3 enregistrements CNAME
# à créer chez le registraire du domaine sont donnés par la sortie « dns_a_ajouter ».
resource "aws_sesv2_email_identity" "domaine" {
  count          = var.gerer_identites_ses && var.domaine_email != "" ? 1 : 0
  email_identity = var.domaine_email
}

locals {
  expediteur = var.expediteur_domaine && var.domaine_email != "" ? "commandes@${var.domaine_email}" : var.notification_email
}
