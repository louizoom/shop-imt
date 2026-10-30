# Réseau : un VPC dédié sur deux zones de disponibilité (haute disponibilité de l'ALB et de l'Auto Scaling).
#   - sous-réseaux publics : ALB, serveurs web et serveur de traitement (IP publique pour sortir vers les API AWS)
#   - sous-réseaux privés : RDS seulement, sans aucune route vers Internet
# Pas de NAT Gateway (environ 35 $/mois) : les instances sortent par l'Internet Gateway, mais leurs groupes de
# sécurité n'acceptent aucune connexion entrante depuis Internet (ni SSH : accès par SSM Session Manager).

data "aws_availability_zones" "zones" {
  state = "available"
}

locals {
  zones = slice(data.aws_availability_zones.zones.names, 0, 2)
}

resource "aws_vpc" "principal" {
  cidr_block           = var.cidr_vpc
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = var.prefix }
}

resource "aws_internet_gateway" "principal" {
  vpc_id = aws_vpc.principal.id
  tags   = { Name = var.prefix }
}

resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.principal.id
  availability_zone       = local.zones[count.index]
  cidr_block              = cidrsubnet(var.cidr_vpc, 8, count.index + 1) # 10.20.1.0/24, 10.20.2.0/24
  map_public_ip_on_launch = true
  tags                    = { Name = "${var.prefix}-public-${local.zones[count.index]}" }
}

resource "aws_subnet" "prive" {
  count             = 2
  vpc_id            = aws_vpc.principal.id
  availability_zone = local.zones[count.index]
  cidr_block        = cidrsubnet(var.cidr_vpc, 8, count.index + 11) # 10.20.11.0/24, 10.20.12.0/24
  tags              = { Name = "${var.prefix}-prive-${local.zones[count.index]}" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.principal.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.principal.id
  }
  tags = { Name = "${var.prefix}-public" }
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# Table des sous-réseaux privés : uniquement la route locale du VPC
resource "aws_route_table" "prive" {
  vpc_id = aws_vpc.principal.id
  tags   = { Name = "${var.prefix}-prive" }
}

resource "aws_route_table_association" "prive" {
  count          = 2
  subnet_id      = aws_subnet.prive[count.index].id
  route_table_id = aws_route_table.prive.id
}

# VPC endpoint de type Gateway vers S3 (gratuit) : code, front et audit transitent par le réseau AWS
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.principal.id
  service_name      = "com.amazonaws.${local.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.public.id]
  tags              = { Name = "${var.prefix}-s3" }
}

# ---------- Groupes de sécurité : chaque couche n'accepte que la couche précédente

# Plages d'adresses des serveurs CloudFront qui contactent les origines (liste gérée par AWS)
data "aws_ec2_managed_prefix_list" "cloudfront" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}

resource "aws_security_group" "alb" {
  name        = "${var.prefix}-alb"
  description = "ALB : HTTP depuis CloudFront uniquement"
  vpc_id      = aws_vpc.principal.id
  tags        = { Name = "${var.prefix}-alb" }
}

resource "aws_vpc_security_group_ingress_rule" "alb_cloudfront" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTP depuis CloudFront"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  prefix_list_id    = data.aws_ec2_managed_prefix_list.cloudfront.id
}

resource "aws_vpc_security_group_egress_rule" "alb_web" {
  security_group_id            = aws_security_group.alb.id
  description                  = "Vers les serveurs web"
  ip_protocol                  = "tcp"
  from_port                    = 8080
  to_port                      = 8080
  referenced_security_group_id = aws_security_group.web.id
}

resource "aws_security_group" "web" {
  name        = "${var.prefix}-web"
  description = "Serveurs web : port 8080 depuis l'ALB uniquement"
  vpc_id      = aws_vpc.principal.id
  tags        = { Name = "${var.prefix}-web" }
}

resource "aws_vpc_security_group_ingress_rule" "web_alb" {
  security_group_id            = aws_security_group.web.id
  description                  = "Application depuis l'ALB"
  ip_protocol                  = "tcp"
  from_port                    = 8080
  to_port                      = 8080
  referenced_security_group_id = aws_security_group.alb.id
}

resource "aws_security_group" "traitement" {
  name        = "${var.prefix}-traitement"
  description = "Serveur de traitement : Kafka depuis les serveurs web uniquement"
  vpc_id      = aws_vpc.principal.id
  tags        = { Name = "${var.prefix}-traitement" }
}

resource "aws_vpc_security_group_ingress_rule" "kafka_web" {
  security_group_id            = aws_security_group.traitement.id
  description                  = "Kafka depuis les serveurs web"
  ip_protocol                  = "tcp"
  from_port                    = 9092
  to_port                      = 9092
  referenced_security_group_id = aws_security_group.web.id
}

resource "aws_security_group" "bdd" {
  name        = "${var.prefix}-bdd"
  description = "RDS MySQL : depuis les serveurs web et de traitement uniquement"
  vpc_id      = aws_vpc.principal.id
  tags        = { Name = "${var.prefix}-bdd" }
}

resource "aws_vpc_security_group_ingress_rule" "bdd" {
  for_each = {
    web        = aws_security_group.web.id
    traitement = aws_security_group.traitement.id
  }
  security_group_id            = aws_security_group.bdd.id
  description                  = "MySQL depuis ${each.key}"
  ip_protocol                  = "tcp"
  from_port                    = 3306
  to_port                      = 3306
  referenced_security_group_id = each.value
}

# Sorties des instances : HTTPS (API AWS, paquets), MySQL vers RDS, Kafka entre web et traitement
resource "aws_vpc_security_group_egress_rule" "https" {
  for_each          = { web = aws_security_group.web.id, traitement = aws_security_group.traitement.id }
  security_group_id = each.value
  description       = "HTTPS sortant (API AWS, paquets)"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "http" {
  for_each          = { web = aws_security_group.web.id, traitement = aws_security_group.traitement.id }
  security_group_id = each.value
  description       = "HTTP sortant (dépôts de paquets Amazon Linux)"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "mysql" {
  for_each                     = { web = aws_security_group.web.id, traitement = aws_security_group.traitement.id }
  security_group_id            = each.value
  description                  = "MySQL vers RDS"
  ip_protocol                  = "tcp"
  from_port                    = 3306
  to_port                      = 3306
  referenced_security_group_id = aws_security_group.bdd.id
}

resource "aws_vpc_security_group_egress_rule" "web_kafka" {
  security_group_id            = aws_security_group.web.id
  description                  = "Kafka vers le serveur de traitement"
  ip_protocol                  = "tcp"
  from_port                    = 9092
  to_port                      = 9092
  referenced_security_group_id = aws_security_group.traitement.id
}
