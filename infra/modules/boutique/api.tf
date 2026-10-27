# API Gateway HTTP API (moins chère et plus simple que REST API).
# Throttling volontairement bas pour protéger le budget en cas d'abus.
# Le navigateur l'appelle via CloudFront (même domaine que le site) : pas besoin de CORS.

resource "aws_apigatewayv2_api" "api" {
  name          = "${var.prefix}-api"
  protocol_type = "HTTP"
}

locals {
  fonctions_api = toset(["catalogue", "commandes", "admin"])
  routes = {
    "GET /produits"              = "catalogue"
    "POST /commandes"            = "commandes"
    "GET /commandes/{id}"        = "commandes"
    "GET /commandes/{id}/agenda" = "commandes" # événement .ics (Apple Calendrier, Outlook)
  }
}

resource "aws_apigatewayv2_integration" "lambda" {
  for_each               = local.fonctions_api
  api_id                 = aws_apigatewayv2_api.api.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.fn[each.key].invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "route" {
  for_each  = local.routes
  api_id    = aws_apigatewayv2_api.api.id
  route_key = each.key
  target    = "integrations/${aws_apigatewayv2_integration.lambda[each.value].id}"
}

resource "aws_cloudwatch_log_group" "api" {
  name              = "/aws/apigateway/${var.prefix}-api"
  retention_in_days = var.log_retention_days
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.api.id
  name        = "$default"
  auto_deploy = true

  default_route_settings {
    throttling_burst_limit = 20
    throttling_rate_limit  = 10
  }

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api.arn
    format = jsonencode({
      requestId = "$context.requestId"
      ip        = "$context.identity.sourceIp"
      route     = "$context.routeKey"
      status    = "$context.status"
      latenceMs = "$context.integrationLatency"
    })
  }
}

resource "aws_lambda_permission" "apigw" {
  for_each      = local.fonctions_api
  statement_id  = "AutoriserAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.fn[each.key].function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.api.execution_arn}/*/*"
}
