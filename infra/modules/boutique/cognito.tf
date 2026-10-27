# Amazon Cognito : comptes clients SHOP'IMT (inscription, confirmation par e-mail, connexion).
# Gratuit jusqu'à 10 000 utilisateurs actifs par mois. Les e-mails de code sont envoyés par
# Cognito lui-même (50 par jour), sans dépendre de SES.

resource "aws_cognito_user_pool" "clients" {
  name                     = "${var.prefix}-clients"
  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]
  deletion_protection      = "INACTIVE" # pour que terraform destroy fonctionne

  password_policy {
    minimum_length                   = 8
    require_lowercase                = true
    require_numbers                  = true
    require_uppercase                = false
    require_symbols                  = false
    temporary_password_validity_days = 7
  }

  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }

  verification_message_template {
    default_email_option = "CONFIRM_WITH_CODE"
    email_subject        = "SHOP'IMT - votre code de confirmation"
    email_message        = "Bienvenue sur SHOP'IMT ! Votre code de confirmation : {####}"
  }
}

# Client « site web » : application publique (pas de secret), connexion par e-mail et mot de passe.
resource "aws_cognito_user_pool_client" "site" {
  name                          = "${var.prefix}-site"
  user_pool_id                  = aws_cognito_user_pool.clients.id
  generate_secret               = false
  explicit_auth_flows           = ["ALLOW_USER_PASSWORD_AUTH", "ALLOW_REFRESH_TOKEN_AUTH"]
  prevent_user_existence_errors = "ENABLED"
  id_token_validity             = 60
  access_token_validity         = 60
  refresh_token_validity        = 30

  token_validity_units {
    id_token      = "minutes"
    access_token  = "minutes"
    refresh_token = "days"
  }
}

# API Gateway vérifie lui-même la signature et l'expiration du jeton avant d'appeler la Lambda.
resource "aws_apigatewayv2_authorizer" "cognito" {
  api_id           = aws_apigatewayv2_api.api.id
  name             = "cognito"
  authorizer_type  = "JWT"
  identity_sources = ["$request.header.Authorization"]

  jwt_configuration {
    audience = [aws_cognito_user_pool_client.site.id]
    issuer   = "https://${aws_cognito_user_pool.clients.endpoint}"
  }
}

resource "aws_apigatewayv2_route" "compte" {
  for_each           = toset(["POST /compte/commandes", "GET /compte/commandes"])
  api_id             = aws_apigatewayv2_api.api.id
  route_key          = each.key
  target             = "integrations/${aws_apigatewayv2_integration.lambda["commandes"].id}"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.cognito.id
}

# Configuration lue par le front au démarrage (identifiants publics du pool, aucun secret).
resource "aws_s3_object" "config" {
  bucket        = aws_s3_bucket.frontend.id
  key           = "config.json"
  content_type  = "application/json"
  cache_control = "no-cache"
  content = jsonencode({
    region        = var.region
    cognitoClient = aws_cognito_user_pool_client.site.id
  })
}
