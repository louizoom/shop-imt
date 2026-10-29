variable "region" {
  description = "Région AWS du projet"
  type        = string
  default     = "eu-west-3" # Paris
}

variable "prefix" {
  description = "Préfixe de nommage de toutes les ressources"
  type        = string
  default     = "shopimt-sls"
}

variable "notification_email" {
  description = "Adresse expéditrice des e-mails de confirmation (identité SES vérifiée, reçoit aussi les confirmations de ses commandes). Vide = pas d'e-mail."
  type        = string
  default     = ""
}

variable "budget_email" {
  description = "E-mail d'alerte du budget AWS (seuil 1 USD). Vide = pas de budget créé."
  type        = string
  default     = ""
}

variable "log_retention_days" {
  description = "Rétention des logs CloudWatch (courte pour rester dans le Free Tier)"
  type        = number
  default     = 7
}

variable "delai_max_s" {
  description = "Durée maximale, tirée au hasard, de chaque étape simulée (préparation, expédition, livraison) en secondes"
  type        = number
  default     = 8
}

variable "activer_cloudtrail" {
  description = "Crée un trail CloudTrail (journaux dans S3, quelques centimes par mois). false = historique gratuit de la console seulement."
  type        = bool
  default     = false
}

variable "emails_verifies" {
  description = "Autres adresses à vérifier dans SES pour recevoir les confirmations tant que le compte SES est en sandbox (ex. les membres du groupe)"
  type        = list(string)
  default     = []
}

variable "domaine_email" {
  description = "Domaine (ou sous-domaine) d'envoi vérifié dans SES par DKIM, ex. shopimt.mondomaine.fr. Vide : pas de domaine."
  type        = string
  default     = ""
}

variable "expediteur_domaine" {
  description = "true une fois le domaine vérifié (statut SUCCESS) : les e-mails partent de commandes@<domaine_email>"
  type        = bool
  default     = false
}

variable "admins" {
  description = "Adresses des comptes clients (déjà inscrits sur le site) à placer dans le groupe Cognito admins : accès à l'onglet Admin"
  type        = list(string)
  default     = []
}

variable "gestionnaires_stock" {
  description = "Comptes du site (déjà inscrits) au rôle stock : onglet Stock seulement"
  type        = list(string)
  default     = []
}

variable "lecteurs_ventes" {
  description = "Comptes du site (déjà inscrits) au rôle ventes : statistiques et commandes en lecture"
  type        = list(string)
  default     = []
}

variable "environnement" {
  description = "Nom de l'environnement (dev ou prod), repris dans les tags et le tableau de bord"
  type        = string
}

variable "capacite_dynamodb" {
  description = "Capacité provisionnée (RCU et WCU) de chaque table et index DynamoDB"
  type        = number
  default     = 5
}

variable "gerer_identites_ses" {
  description = "Crée les identités SES (adresses, domaine). Une seule fois par compte : false en dev"
  type        = bool
  default     = true
}

variable "domaine_site" {
  description = "Nom de domaine du site (ex. shopimt.exemple.fr), vide pour garder l'adresse CloudFront"
  type        = string
  default     = ""
}

variable "domaine_site_actif" {
  description = "true une fois le certificat ACM émis : branche le domaine sur CloudFront"
  type        = bool
  default     = false
}
