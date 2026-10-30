variable "prefix" {
  description = "Préfixe de nommage des ressources de la solution EC2"
  type        = string
}

variable "environnement" {
  description = "dev ou prod"
  type        = string
}

variable "cidr_vpc" {
  description = "Plage d'adresses du VPC (distincte du VPC par défaut 172.31.0.0/16)"
  type        = string
  default     = "10.20.0.0/16"
}

variable "type_instance" {
  description = "Type des instances EC2 (t3.micro : 750 h/mois dans le Free Tier 12 mois)"
  type        = string
  default     = "t3.micro"
}

variable "serveurs_web_min" {
  description = "Nombre minimal de serveurs web dans l'Auto Scaling group"
  type        = number
  default     = 1
}

variable "serveurs_web_max" {
  description = "Nombre maximal de serveurs web (montée en charge sur l'usage CPU)"
  type        = number
  default     = 2
}

variable "classe_bdd" {
  description = "Classe de l'instance RDS (db.t4g.micro : 750 h/mois dans le Free Tier 12 mois)"
  type        = string
  default     = "db.t4g.micro"
}

variable "bdd_multi_az" {
  description = "RDS Multi-AZ (instance de secours synchrone dans une 2e zone). Facturé : false pour rester gratuit."
  type        = bool
  default     = false
}

variable "expediteur" {
  description = "Adresse expéditrice des e-mails (identité SES déjà vérifiée par la solution serverless). Vide = pas d'e-mail."
  type        = string
  default     = ""
}

variable "version_kafka" {
  description = "Version d'Apache Kafka installée sur le serveur de traitement (mode KRaft, sans ZooKeeper)"
  type        = string
  default     = "3.9.1"
}

variable "delai_max_s" {
  description = "Durée maximale, tirée au hasard, de chaque étape simulée (secondes)"
  type        = number
  default     = 8
}

variable "log_retention_days" {
  description = "Rétention des logs CloudWatch"
  type        = number
  default     = 7
}

variable "dossier_site" {
  description = "Front compilé (frontend/dist), le même que la solution serverless"
  type        = string
}

variable "dossier_backend" {
  description = "Dossier backend/ du dépôt (code EC2 et modules métier des Lambdas réutilisés)"
  type        = string
}
