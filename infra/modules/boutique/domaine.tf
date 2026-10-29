# Nom de domaine du site (facultatif), par exemple shopimt.prodhommed.fr.
# CloudFront n'accepte que des certificats ACM de us-east-1 ; ACM est gratuit et se renouvelle seul.
# Le domaine est chez un autre registraire (OVH) : pas de Route 53 (zone hébergée payante),
# les enregistrements sont créés à la main d'après la sortie dns_site. En deux temps :
#   1. domaine_site renseigné : le certificat est demandé, on crée chez OVH le CNAME de validation ;
#   2. domaine_site_actif = true une fois le certificat émis : alias CloudFront, puis CNAME du site.
locals {
  domaine_actif = var.domaine_site != "" && var.domaine_site_actif
  url_site      = local.domaine_actif ? "https://${var.domaine_site}" : "https://${aws_cloudfront_distribution.site.domain_name}"
}

resource "aws_acm_certificate" "site" {
  count    = var.domaine_site != "" ? 1 : 0
  provider = aws.us_east_1

  domain_name       = var.domaine_site
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

# Attend que le certificat soit émis (CNAME de validation en place) avant de le donner à CloudFront
resource "aws_acm_certificate_validation" "site" {
  count    = local.domaine_actif ? 1 : 0
  provider = aws.us_east_1

  certificate_arn = aws_acm_certificate.site[0].arn
}
