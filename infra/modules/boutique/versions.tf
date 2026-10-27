terraform {
  required_version = ">= 1.10"

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

data "aws_caller_identity" "current" {}

locals {
  # Sources partagées par les environnements : code des Lambdas et front compilé (npm run build)
  dossier_lambdas = "${path.module}/../../../backend/lambdas"
  dossier_site    = "${path.module}/../../../frontend/dist"
}
