# Interface admin : onglet du site réservé au groupe Cognito « admins ».
#   GET /admin/stats      -> statistiques sur N jours (commandes, chiffre d'affaires, statuts, produits)
#   GET /admin/commandes  -> liste des commandes avec l'e-mail du client (recherche ?q=)
#   GET /admin/export     -> export CSV dans S3, téléchargé par URL présignée (5 min)
#   GET|POST /admin/stock -> niveaux de stock et réassort (+/-), mise à jour conditionnelle DynamoDB
# API Gateway refuse sans jeton (401), la Lambda admin refuse sans le groupe (403).
# Rôle IAM minimal : Query sur l'index par-jour, Scan et UpdateItem sur la table produits.

resource "aws_cognito_user_group" "admins" {
  name         = "admins"
  user_pool_id = aws_cognito_user_pool.clients.id
  description  = "Accès à l'interface admin SHOP'IMT"
}

# Les comptes sont créés depuis le site (« Mon compte »), puis ajoutés ici par leur e-mail.
# Nouvelle connexion nécessaire pour que le jeton contienne le groupe.
resource "aws_cognito_user_in_group" "admins" {
  for_each     = toset([for e in var.admins : lower(e)])
  user_pool_id = aws_cognito_user_pool.clients.id
  group_name   = aws_cognito_user_group.admins.name
  username     = each.key
}

resource "aws_apigatewayv2_route" "admin" {
  for_each           = toset(["GET /admin/stats", "GET /admin/commandes", "GET /admin/export", "GET /admin/stock", "POST /admin/stock"])
  api_id             = aws_apigatewayv2_api.api.id
  route_key          = each.key
  target             = "integrations/${aws_apigatewayv2_integration.lambda["admin"].id}"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.cognito.id
}

# --- Récap quotidien : Amazon EventBridge Scheduler déclenche la Lambda rapport chaque soir à 21 h (Paris).
# Offre gratuite : 14 millions d'invocations planifiées par mois (ici 30).
resource "aws_iam_role" "planificateur" {
  name = "${var.prefix}-planificateur"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "scheduler.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = { StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id } }
    }]
  })
}

resource "aws_iam_role_policy" "planificateur" {
  name = "invoquer-rapport"
  role = aws_iam_role.planificateur.id
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "lambda:InvokeFunction", Resource = aws_lambda_function.fn["rapport"].arn }]
  })
}

resource "aws_scheduler_schedule" "rapport" {
  name                         = "${var.prefix}-recap-quotidien"
  description                  = "Récap des ventes du jour envoyé aux admins"
  schedule_expression          = "cron(0 21 * * ? *)"
  schedule_expression_timezone = "Europe/Paris"
  state                        = length(var.admins) > 0 ? "ENABLED" : "DISABLED"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_lambda_function.fn["rapport"].arn
    role_arn = aws_iam_role.planificateur.arn
    input    = jsonencode({})

    retry_policy {
      maximum_retry_attempts = 2
    }
  }
}

# --- Rappels de livraison : la Lambda notification crée une planification unique par commande
# (at(veille 18 h), fuseau Europe/Paris), supprimée après exécution ou à la livraison.
resource "aws_scheduler_schedule_group" "rappels" {
  name = "${var.prefix}-rappels"
}

resource "aws_iam_role" "rappels" {
  name = "${var.prefix}-rappels"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "scheduler.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = { StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id } }
    }]
  })
}

resource "aws_iam_role_policy" "rappels" {
  name = "invoquer-notification"
  role = aws_iam_role.rappels.id
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "lambda:InvokeFunction", Resource = aws_lambda_function.fn["notification"].arn }]
  })
}
