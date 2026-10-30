# Amazon RDS for MySQL 8.4 (LTS) : la base relationnelle de la solution EC2 (catalogue, commandes, historique).
# Free Tier 12 mois : 750 h de db.t4g.micro mono-AZ et 20 Go de stockage. Multi-AZ (secours synchrone dans
# l'autre zone, bascule automatique) double le prix : présenté dans le LLD, désactivé par défaut (bdd_multi_az).

resource "random_password" "bdd" {
  length  = 32
  special = false # évite les caractères refusés par RDS (/, @, ", espace)
}

# Mot de passe lu au démarrage par les instances (rôle IAM), jamais écrit dans le user_data ni dans le code.
# SecureString chiffré avec la clé KMS gérée aws/ssm (gratuite).
resource "aws_ssm_parameter" "bdd" {
  name        = "/shopimt/${var.environnement}/ec2/mot-de-passe-bdd"
  description = "Mot de passe de la base RDS de la solution EC2"
  type        = "SecureString"
  value       = random_password.bdd.result
}

resource "aws_db_subnet_group" "bdd" {
  name       = var.prefix
  subnet_ids = aws_subnet.prive[*].id
}

resource "aws_db_parameter_group" "bdd" {
  name   = "${var.prefix}-mysql84"
  family = "mysql8.4"

  # Connexions chiffrées obligatoires (TLS)
  parameter {
    name  = "require_secure_transport"
    value = "1"
  }
}

resource "aws_db_instance" "bdd" {
  identifier     = var.prefix
  engine         = "mysql"
  engine_version = "8.4"
  instance_class = var.classe_bdd

  allocated_storage     = 20
  max_allocated_storage = 0 # pas d'extension automatique : rester dans les 20 Go gratuits
  storage_type          = "gp2"
  storage_encrypted     = true # clé KMS gérée aws/rds, gratuite

  db_name  = "boutique"
  username = "shopimt"
  password = random_password.bdd.result

  multi_az               = var.bdd_multi_az
  db_subnet_group_name   = aws_db_subnet_group.bdd.name
  vpc_security_group_ids = [aws_security_group.bdd.id]
  parameter_group_name   = aws_db_parameter_group.bdd.name
  publicly_accessible    = false

  backup_retention_period    = 1 # sauvegarde automatique quotidienne, restauration à la seconde près sur 24 h
  backup_window              = "02:00-02:30"
  maintenance_window         = "sun:03:00-sun:03:30"
  auto_minor_version_upgrade = true
  apply_immediately          = true

  enabled_cloudwatch_logs_exports = ["error"]
  skip_final_snapshot             = true # projet de cours : pas d'instantané facturé à la destruction
  deletion_protection             = false

  depends_on = [aws_cloudwatch_log_group.rds] # groupe créé avec sa rétention avant que RDS ne le crée
}
