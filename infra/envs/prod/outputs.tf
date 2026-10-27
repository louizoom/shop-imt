output "site_url" {
  description = "Adresse publique du site (CloudFront)"
  value       = module.boutique.site_url
}

output "api_url" {
  description = "URL directe de l'API HTTP (API Gateway)"
  value       = module.boutique.api_url
}

output "bucket_site" {
  description = "Bucket S3 du front"
  value       = module.boutique.bucket_site
}

output "cloudfront_id" {
  description = "Distribution CloudFront"
  value       = module.boutique.cloudfront_id
}

output "tableau_de_bord" {
  description = "Tableau de bord CloudWatch"
  value       = module.boutique.tableau_de_bord
}

output "cognito_user_pool" {
  description = "User pool Cognito des comptes clients"
  value       = module.boutique.cognito_user_pool
}

output "dns_a_ajouter" {
  description = "Enregistrements DKIM à créer chez le registraire (prod uniquement)"
  value       = module.boutique.dns_a_ajouter
}

output "table_commandes" {
  description = "Table DynamoDB des commandes (scripts/scenario.sh)"
  value       = module.boutique.table_commandes
}

output "bucket_audit" {
  description = "Bucket S3 d'audit des commandes (scripts/scenario.sh)"
  value       = module.boutique.bucket_audit
}

output "machine_expedition" {
  description = "Machine à états Step Functions de l'expédition (scripts/scenario.sh)"
  value       = module.boutique.machine_expedition
}

output "fonction_admin" {
  description = "Lambda admin (scripts/scenario.sh)"
  value       = module.boutique.fonction_admin
}
