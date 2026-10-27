# Step Functions : déroulé simulé de la préparation et de la livraison d'une commande.
# La Lambda traitement fournit les étapes tirées au sort ; la machine attend le délai de
# chaque étape (état Wait, gratuit) puis met à jour DynamoDB directement (intégration SDK,
# sans Lambda). Free Tier permanent : 4 000 transitions d'état par mois (~13 par commande).

# ARN construit à partir du nom : la Lambda traitement dépend déjà de cette machine,
# la référencer directement créerait une dépendance circulaire.
locals {
  arn_notification = "arn:aws:lambda:${var.region}:${data.aws_caller_identity.current.account_id}:function:${var.prefix}-notification"
}

resource "aws_iam_role" "expedition" {
  name = "${var.prefix}-expedition"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "states.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "expedition" {
  name = "moindre-privilege"
  role = aws_iam_role.expedition.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["dynamodb:UpdateItem"], Resource = aws_dynamodb_table.commandes.arn },
      { Effect = "Allow", Action = ["lambda:InvokeFunction"], Resource = local.arn_notification },
      { Effect = "Allow", Action = ["xray:PutTraceSegments", "xray:PutTelemetryRecords", "xray:GetSamplingRules", "xray:GetSamplingTargets"], Resource = "*" },
    ]
  })
}

resource "aws_sfn_state_machine" "expedition" {
  name     = "${var.prefix}-expedition"
  role_arn = aws_iam_role.expedition.arn

  tracing_configuration {
    enabled = true
  }

  definition = jsonencode({
    Comment = "Préparation, expédition et livraison simulées d'une commande SHOP'IMT"
    StartAt = "Etapes"
    States = {
      Etapes = {
        Type           = "Map"
        ItemsPath      = "$.etapes"
        MaxConcurrency = 1 # les étapes se jouent dans l'ordre
        ItemSelector = {
          "order_id.$" = "$.order_id"
          "etape.$"    = "$$.Map.Item.Value"
        }
        ItemProcessor = {
          ProcessorConfig = { Mode = "INLINE" }
          StartAt         = "Attendre"
          States = {
            Attendre = {
              Type        = "Wait"
              SecondsPath = "$.etape.delai"
              Next        = "MettreAJourStatut"
            }
            MettreAJourStatut = {
              Type     = "Task"
              Resource = "arn:aws:states:::dynamodb:updateItem"
              Parameters = {
                TableName           = aws_dynamodb_table.commandes.name
                Key                 = { order_id = { "S.$" = "$.order_id" } }
                UpdateExpression    = "SET statut = :s, historique = list_append(historique, :h)"
                ConditionExpression = "attribute_exists(order_id)"
                ExpressionAttributeValues = {
                  ":s" = { "S.$" = "$.etape.statut" }
                  ":h" = { "L" = [{ "S.$" = "States.Format('{} {} | {}', $$.State.EnteredTime, $.etape.statut, $.etape.detail)" }] }
                }
              }
              ResultPath = null # garde l'étape en entrée de l'état suivant
              Retry = [{
                ErrorEquals     = ["States.TaskFailed"]
                IntervalSeconds = 2
                MaxAttempts     = 3
                BackoffRate     = 2
              }]
              Next = "EmailAuClient"
            }
            # Expédition, incident et livraison : e-mail au client (Lambda notification, appel asynchrone)
            EmailAuClient = {
              Type    = "Choice"
              Choices = [{ Variable = "$.etape.notifier", IsPresent = true, Next = "EnvoyerEmail" }]
              Default = "EtapeTerminee"
            }
            EnvoyerEmail = {
              Type     = "Task"
              Resource = "arn:aws:states:::lambda:invoke"
              Parameters = {
                FunctionName   = local.arn_notification
                InvocationType = "Event"
                Payload = {
                  type         = "STATUT_COLIS"
                  "order_id.$" = "$.order_id"
                  "statut.$"   = "$.etape.statut"
                  "detail.$"   = "$.etape.detail"
                }
              }
              Retry = [{
                ErrorEquals     = ["States.ALL"]
                IntervalSeconds = 2
                MaxAttempts     = 2
                BackoffRate     = 2
              }]
              Catch = [{ ErrorEquals = ["States.ALL"], Next = "EtapeTerminee" }] # un e-mail raté ne bloque pas la livraison
              End   = true
            }
            EtapeTerminee = { Type = "Succeed" }
          }
        }
        End = true
      }
    }
  })
}
