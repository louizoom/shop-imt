# Environnement prod : même module que l'autre environnement, seuls les réglages ci-dessous changent.
terraform {
  required_version = ">= 1.10"

  # État partagé dans S3 (créé par infra/bootstrap), verrou natif S3 (use_lockfile) sans table DynamoDB
  backend "s3" {
    bucket       = "shopimt-tfstate-204924594218"
    key          = "prod/terraform.tfstate"
    region       = "eu-west-3"
    encrypt      = true
    use_lockfile = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.70"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.6"
    }
  }
}

provider "aws" {
  region = "eu-west-3"

  default_tags {
    tags = {
      Projet        = "shop-imt"
      Solution      = "serverless"
      Environnement = "prod"
      GerePar       = "terraform"
    }
  }
}

# Réglages personnels (adresses e-mail, admins) hors du dépôt : paramètre SSM Parameter Store
# /shopimt/prod/config, un JSON créé une fois à la main (voir README).
data "aws_ssm_parameter" "config" {
  name = "/shopimt/prod/config"
}

locals {
  config = jsondecode(nonsensitive(data.aws_ssm_parameter.config.value))
}

module "boutique" {
  source = "../../modules/boutique"

  environnement       = "prod"
  prefix              = "shopimt-sls"
  capacite_dynamodb   = 5
  gerer_identites_ses = true

  notification_email = try(local.config.notification_email, "")
  budget_email       = try(local.config.budget_email, "")
  emails_verifies    = try(local.config.emails_verifies, [])
  domaine_email      = try(local.config.domaine_email, "")
  expediteur_domaine = try(local.config.expediteur_domaine, false)
  admins             = try(local.config.admins, [])
}
