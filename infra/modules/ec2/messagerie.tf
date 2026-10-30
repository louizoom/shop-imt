# Modèle événementiel, comme la solution serverless : le serveur web publie COMMANDE_CREEE sur un topic SNS,
# diffusé vers une file SQS que le serveur de traitement lit en long polling. Si le serveur de traitement est
# arrêté ou remplacé, les commandes attendent dans la file (14 jours) : aucune n'est perdue.

resource "aws_sns_topic" "commandes" {
  name = "${var.prefix}-commandes"
}

resource "aws_sqs_queue" "dlq" {
  name                      = "${var.prefix}-dlq"
  message_retention_seconds = 1209600
  sqs_managed_sse_enabled   = true
}

resource "aws_sqs_queue" "traitement" {
  name                       = "${var.prefix}-traitement"
  visibility_timeout_seconds = 180 # durée maximale d'une simulation complète
  message_retention_seconds  = 1209600
  receive_wait_time_seconds  = 20
  sqs_managed_sse_enabled    = true
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = 3
  })
}

data "aws_iam_policy_document" "sqs_depuis_sns" {
  statement {
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.traitement.arn]
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

resource "aws_sqs_queue_policy" "traitement" {
  queue_url = aws_sqs_queue.traitement.id
  policy    = data.aws_iam_policy_document.sqs_depuis_sns.json
}

resource "aws_sns_topic_subscription" "traitement" {
  topic_arn            = aws_sns_topic.commandes.arn
  protocol             = "sqs"
  endpoint             = aws_sqs_queue.traitement.arn
  raw_message_delivery = true
  depends_on           = [aws_sqs_queue_policy.traitement]
}
