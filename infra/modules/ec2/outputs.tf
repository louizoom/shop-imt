output "site_url" {
  description = "Adresse du site, solution EC2 (CloudFront devant l'ALB)"
  value       = local.site_url
}

output "alb" {
  description = "Nom DNS de l'ALB (répond 403 sans passer par CloudFront)"
  value       = aws_lb.web.dns_name
}

output "bdd" {
  description = "Point de terminaison RDS (privé, joignable seulement depuis le VPC)"
  value       = aws_db_instance.bdd.address
}

output "serveur_traitement" {
  description = "Instance du serveur de traitement et broker Kafka (accès : Session Manager)"
  value       = aws_instance.traitement.id
}

output "auto_scaling_group" {
  description = "Auto Scaling group des serveurs web"
  value       = aws_autoscaling_group.web.name
}

output "bucket" {
  description = "Bucket S3 de la solution EC2 (code/ et audit/)"
  value       = aws_s3_bucket.ec2.id
}

output "tableau_de_bord" {
  description = "Tableau de bord CloudWatch de la solution EC2"
  value       = "https://${local.region}.console.aws.amazon.com/cloudwatch/home?region=${local.region}#dashboards/dashboard/${aws_cloudwatch_dashboard.ec2.dashboard_name}"
}
