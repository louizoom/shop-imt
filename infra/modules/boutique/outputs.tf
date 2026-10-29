output "site_url" {
  description = "URL de SHOP'IMT (nom de domaine s'il est actif, sinon adresse CloudFront)"
  value       = local.url_site
}

output "api_url" {
  description = "URL directe de l'API HTTP (le site, lui, passe par CloudFront)"
  value       = aws_apigatewayv2_api.api.api_endpoint
}

output "table_commandes" {
  value = aws_dynamodb_table.commandes.name
}

output "table_produits" {
  value = aws_dynamodb_table.produits.name
}

output "bucket_audit" {
  value = aws_s3_bucket.audit.bucket
}

output "topic_commandes" {
  value = aws_sns_topic.commandes.arn
}

output "file_dlq" {
  value = aws_sqs_queue.dlq.url
}

output "cloudfront_id" {
  description = "Pour invalider le cache après une modification du front"
  value       = aws_cloudfront_distribution.site.id
}

output "machine_expedition" {
  value = aws_sfn_state_machine.expedition.arn
}

output "tableau_de_bord" {
  description = "Tableau de bord CloudWatch"
  value       = "https://${var.region}.console.aws.amazon.com/cloudwatch/home?region=${var.region}#dashboards/dashboard/${aws_cloudwatch_dashboard.boutique.dashboard_name}"
}

output "cognito_user_pool" {
  value = aws_cognito_user_pool.clients.id
}

output "dns_a_ajouter" {
  description = "Enregistrements DNS à créer chez le registraire pour vérifier le domaine d'envoi SES"
  value = length(aws_sesv2_email_identity.domaine) == 0 ? [] : concat(
    [for t in aws_sesv2_email_identity.domaine[0].dkim_signing_attributes[0].tokens :
    "CNAME  ${t}._domainkey.${var.domaine_email}  ->  ${t}.dkim.amazonses.com"],
    ["TXT    _dmarc.${var.domaine_email}  ->  \"v=DMARC1; p=none;\""]
  )
}

output "fonction_admin" {
  description = "Lambda de l'interface admin (scénario de test)"
  value       = aws_lambda_function.fn["admin"].function_name
}

output "recap_quotidien" {
  description = "Planification EventBridge Scheduler du récap envoyé aux admins"
  value       = aws_scheduler_schedule.rapport.name
}


output "bucket_site" {
  description = "Bucket S3 du front (déploiement du build Vite)"
  value       = aws_s3_bucket.frontend.bucket
}

output "dns_site" {
  description = "Enregistrements à créer chez le registraire du domaine (validation du certificat, puis site)"
  value = var.domaine_site == "" ? [] : concat(
    [for o in aws_acm_certificate.site[0].domain_validation_options : { nom = o.resource_record_name, type = o.resource_record_type, valeur = o.resource_record_value }],
    [{ nom = "${var.domaine_site}.", type = "CNAME", valeur = "${aws_cloudfront_distribution.site.domain_name}." }],
  )
}

output "certificat_statut" {
  description = "PENDING_VALIDATION tant que le CNAME de validation n'est pas visible, puis ISSUED"
  value       = var.domaine_site == "" ? null : aws_acm_certificate.site[0].status
}
