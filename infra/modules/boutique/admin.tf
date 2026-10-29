# Interface admin : onglet du site, ouvert selon le rôle (groupe Cognito) du compte.
#   admins -> tout ; ventes -> statistiques et commandes en lecture ; stock -> réassort seulement.
#   GET /admin/stats      -> statistiques sur N jours (commandes, chiffre d'affaires, statuts, produits)
#   GET /admin/commandes  -> liste des commandes avec l'e-mail du client (recherche ?q=)
#   GET /admin/export     -> export CSV dans S3, téléchargé par URL présignée (5 min)
#   GET|POST /admin/stock -> niveaux de stock et réassort (+/-), mise à jour conditionnelle DynamoDB
# API Gateway refuse sans jeton (401), la Lambda admin refuse une route que le rôle n'autorise pas (403).
# Rôle IAM minimal : Query sur l'index par-jour, Scan et UpdateItem sur la table produits.

# Rôles du site. La priorité (precedence) départage les rôles d'un compte qui en a plusieurs :
# le plus petit nombre l'emporte pour le rôle « principal » ; la Lambda cumule les droits de tous.
locals {
  roles_site = {
    admins = { precedence = 1, description = "Tout : ventes, export CSV et stock", membres = var.admins }
    ventes = { precedence = 10, description = "Lecture des ventes et des commandes (sans export ni stock)", membres = var.lecteurs_ventes }
    stock  = { precedence = 20, description = "Gestion du stock seulement (réassort +/-)", membres = var.gestionnaires_stock }
  }
  membres_site = merge([
    for role, r in local.roles_site : { for e in r.membres : "${role}/${lower(e)}" => { role = role, email = lower(e) } }
  ]...)
}

resource "aws_cognito_user_group" "role" {
  for_each     = local.roles_site
  name         = each.key
  user_pool_id = aws_cognito_user_pool.clients.id
  precedence   = each.value.precedence
  description  = each.value.description
}

# Les comptes sont créés depuis le site (« Mon compte »), puis ajoutés ici par leur e-mail.
# Nouvelle connexion nécessaire pour que le jeton contienne le groupe.
resource "aws_cognito_user_in_group" "membre" {
  for_each     = local.membres_site
  user_pool_id = aws_cognito_user_pool.clients.id
  group_name   = aws_cognito_user_group.role[each.value.role].name
  username     = each.value.email
}

moved {
  from = aws_cognito_user_group.admins
  to   = aws_cognito_user_group.role["admins"]
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
