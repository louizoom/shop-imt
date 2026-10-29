# Une fonction par responsabilité, un rôle IAM chacune (moindre privilège), tracées par X-Ray.
# Free Tier permanent Lambda : 1 M d'invocations et 400 000 Go-s par mois.

locals {
  lambdas = {
    catalogue = {
      description = "GET /produits : liste du catalogue (noms anglais traduits une fois par Amazon Translate)"
      timeout     = 10
      env = {
        TABLE_PRODUITS = aws_dynamodb_table.produits.name
      }
      statements = [
        { actions = ["dynamodb:Scan", "dynamodb:UpdateItem"], resources = [aws_dynamodb_table.produits.arn] },
        { actions = ["translate:TranslateText"], resources = ["*"] }, # l'API Translate n'a pas de ressource à cibler
      ]
    }

    commandes = {
      description = "Commandes : création, suivi, et historique des clients connectés"
      timeout     = 10
      env = {
        TABLE_PRODUITS  = aws_dynamodb_table.produits.name
        TABLE_COMMANDES = aws_dynamodb_table.commandes.name
      }
      statements = [
        { actions = ["dynamodb:BatchGetItem", "dynamodb:UpdateItem"], resources = [aws_dynamodb_table.produits.arn] },
        { actions = ["dynamodb:PutItem", "dynamodb:GetItem"], resources = [aws_dynamodb_table.commandes.arn] },
        { actions = ["dynamodb:Query"], resources = ["${aws_dynamodb_table.commandes.arn}/index/par-client"] },
        # Compteur des numéros de commande : UpdateItem limité à la seule ligne #compteur (contrôle d'accès fin)
        {
          actions    = ["dynamodb:UpdateItem"]
          resources  = [aws_dynamodb_table.commandes.arn]
          conditions = [{ test = "ForAllValues:StringEquals", variable = "dynamodb:LeadingKeys", values = ["#compteur"] }]
        },
      ]
    }

    publication = {
      description = "Flux DynamoDB des commandes -> SNS (outbox)"
      timeout     = 10
      env = {
        TOPIC_ARN    = aws_sns_topic.commandes.arn
        SITE_URL     = local.url_site     # lien de suivi dans l'e-mail
        METRIQUES_NS = local.metriques_ns # métriques métier (format EMF, voir monitoring.tf)
      }
      statements = [
        { actions = ["dynamodb:DescribeStream", "dynamodb:GetRecords", "dynamodb:GetShardIterator", "dynamodb:ListStreams"], resources = [aws_dynamodb_table.commandes.stream_arn] },
        { actions = ["sns:Publish"], resources = [aws_sns_topic.commandes.arn] },
        { actions = ["sqs:SendMessage"], resources = [aws_sqs_queue.dlq.arn] },
      ]
    }

    notification = {
      description = "E-mails HTML via SES : confirmation (abonné SNS), expédition et livraison (Step Functions), rappel la veille (EventBridge Scheduler)"
      timeout     = 10
      env = {
        EXPEDITEUR      = local.expediteur
        SITE_URL        = local.url_site
        TABLE_COMMANDES = aws_dynamodb_table.commandes.name
        GROUPE_RAPPELS  = aws_scheduler_schedule_group.rappels.name
        ROLE_RAPPELS    = aws_iam_role.rappels.arn
      }
      statements = [
        # Rappel « votre colis arrive demain » : une planification unique par commande, dans un groupe dédié
        { actions = ["scheduler:CreateSchedule", "scheduler:DeleteSchedule"], resources = ["arn:aws:scheduler:${var.region}:${data.aws_caller_identity.current.account_id}:schedule/${aws_scheduler_schedule_group.rappels.name}/*"] },
        { actions = ["iam:PassRole"], resources = [aws_iam_role.rappels.arn] },
        { actions = ["ses:SendEmail"], resources = ["arn:aws:ses:${var.region}:${data.aws_caller_identity.current.account_id}:identity/*"] },
        # Sandbox SES : envoi automatique du lien de vérification aux nouveaux clients
        { actions = ["ses:CreateEmailIdentity", "ses:TagResource"], resources = ["arn:aws:ses:${var.region}:${data.aws_caller_identity.current.account_id}:identity/*"] },
        { actions = ["dynamodb:GetItem"], resources = [aws_dynamodb_table.commandes.arn] },
      ]
    }

    traitement = {
      description = "Consomme la file traitement : lance l'expédition simulée (Step Functions)"
      timeout     = 10
      env = {
        TABLE_COMMANDES   = aws_dynamodb_table.commandes.name
        STATE_MACHINE_ARN = aws_sfn_state_machine.expedition.arn
        DELAI_MAX         = tostring(var.delai_max_s)
      }
      statements = [
        { actions = ["dynamodb:GetItem", "dynamodb:UpdateItem"], resources = [aws_dynamodb_table.commandes.arn] },
        { actions = ["states:StartExecution"], resources = [aws_sfn_state_machine.expedition.arn] },
        { actions = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"], resources = [aws_sqs_queue.traitement.arn] },
      ]
    }

    admin = {
      description = "Interface admin : ventes et stock, accès par rôle (groupes Cognito admins, ventes, stock)"
      timeout     = 15
      env = {
        TABLE_COMMANDES = aws_dynamodb_table.commandes.name
        TABLE_PRODUITS  = aws_dynamodb_table.produits.name
        BUCKET_EXPORT   = aws_s3_bucket.audit.bucket
      }
      statements = [
        { actions = ["dynamodb:Query"], resources = ["${aws_dynamodb_table.commandes.arn}/index/par-jour"] },
        # Onglet Stock : lecture du catalogue et réassort (mise à jour conditionnelle, jamais de suppression)
        { actions = ["dynamodb:Scan", "dynamodb:UpdateItem"], resources = [aws_dynamodb_table.produits.arn] },
        # Export CSV : écriture puis lecture par URL présignée, limitées au préfixe exports/
        { actions = ["s3:PutObject", "s3:GetObject"], resources = ["${aws_s3_bucket.audit.arn}/exports/*"] },
      ]
    }

    rapport = {
      description = "Récap quotidien des ventes par e-mail aux admins (EventBridge Scheduler)"
      timeout     = 15
      env = {
        TABLE_COMMANDES = aws_dynamodb_table.commandes.name
        TABLE_PRODUITS  = aws_dynamodb_table.produits.name
        EXPEDITEUR      = local.expediteur
        DESTINATAIRES   = join(",", [for e in var.admins : lower(e)])
        SITE_URL        = local.url_site
      }
      statements = [
        { actions = ["dynamodb:Query"], resources = ["${aws_dynamodb_table.commandes.arn}/index/par-jour"] },
        { actions = ["dynamodb:Scan"], resources = [aws_dynamodb_table.produits.arn] },
        { actions = ["ses:SendEmail"], resources = ["arn:aws:ses:${var.region}:${data.aws_caller_identity.current.account_id}:identity/*"] },
      ]
    }

    audit = {
      description = "Consomme la file audit : archive chaque commande dans S3"
      timeout     = 10
      env = {
        BUCKET_AUDIT = aws_s3_bucket.audit.bucket
      }
      statements = [
        { actions = ["s3:PutObject"], resources = ["${aws_s3_bucket.audit.arn}/audit/*"] },
        { actions = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"], resources = [aws_sqs_queue.audit.arn] },
      ]
    }
  }
}

data "archive_file" "lambda" {
  for_each    = local.lambdas
  type        = "zip"
  source_file = "${local.dossier_lambdas}/${each.key}.py"
  output_path = "${path.root}/.build/${each.key}.zip"
}

resource "aws_cloudwatch_log_group" "lambda" {
  for_each          = local.lambdas
  name              = "/aws/lambda/${var.prefix}-${each.key}"
  retention_in_days = var.log_retention_days
}

data "aws_iam_policy_document" "assume_lambda" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda" {
  for_each           = local.lambdas
  name               = "${var.prefix}-${each.key}"
  assume_role_policy = data.aws_iam_policy_document.assume_lambda.json
}

data "aws_iam_policy_document" "lambda" {
  for_each = local.lambdas

  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.lambda[each.key].arn}:*"]
  }

  statement {
    sid       = "XRay"
    actions   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
    resources = ["*"]
  }

  dynamic "statement" {
    for_each = each.value.statements
    content {
      actions   = statement.value.actions
      resources = statement.value.resources

      dynamic "condition" {
        for_each = try(statement.value.conditions, [])
        content {
          test     = condition.value.test
          variable = condition.value.variable
          values   = condition.value.values
        }
      }
    }
  }
}

resource "aws_iam_role_policy" "lambda" {
  for_each = local.lambdas
  name     = "moindre-privilege"
  role     = aws_iam_role.lambda[each.key].id
  policy   = data.aws_iam_policy_document.lambda[each.key].json
}

resource "aws_lambda_function" "fn" {
  for_each         = local.lambdas
  function_name    = "${var.prefix}-${each.key}"
  description      = each.value.description
  role             = aws_iam_role.lambda[each.key].arn
  runtime          = "python3.12"
  architectures    = ["arm64"] # Graviton : ~20 % moins cher au-delà du Free Tier
  handler          = "${each.key}.handler"
  filename         = data.archive_file.lambda[each.key].output_path
  source_code_hash = data.archive_file.lambda[each.key].output_base64sha256
  memory_size      = 128
  timeout          = each.value.timeout

  environment {
    variables = each.value.env
  }

  # X-Ray : 100 000 traces par mois gratuites, montre le temps passé dans chaque appel AWS.
  tracing_config {
    mode = "Active"
  }

  depends_on = [aws_cloudwatch_log_group.lambda, aws_iam_role_policy.lambda]
}

# Déclencheurs SQS -> Lambda (échecs partiels gérés message par message)
resource "aws_lambda_event_source_mapping" "traitement" {
  event_source_arn        = aws_sqs_queue.traitement.arn
  function_name           = aws_lambda_function.fn["traitement"].arn
  batch_size              = 5
  function_response_types = ["ReportBatchItemFailures"]
}

resource "aws_lambda_event_source_mapping" "audit" {
  event_source_arn        = aws_sqs_queue.audit.arn
  function_name           = aws_lambda_function.fn["audit"].arn
  batch_size              = 10
  function_response_types = ["ReportBatchItemFailures"]
}

# Déclencheur DynamoDB Streams -> Lambda publication (uniquement les nouvelles commandes)
resource "aws_lambda_event_source_mapping" "publication" {
  event_source_arn               = aws_dynamodb_table.commandes.stream_arn
  function_name                  = aws_lambda_function.fn["publication"].arn
  starting_position              = "LATEST"
  batch_size                     = 10
  maximum_retry_attempts         = 3
  bisect_batch_on_function_error = true
  function_response_types        = ["ReportBatchItemFailures"]

  filter_criteria {
    filter {
      # Nouvelles commandes seulement : la ligne #compteur (sans statut) ne déclenche rien
      pattern = jsonencode({ eventName = ["INSERT"], dynamodb = { NewImage = { statut = { S = [{ exists = true }] } } } })
    }
  }

  destination_config {
    on_failure {
      destination_arn = aws_sqs_queue.dlq.arn
    }
  }
}
