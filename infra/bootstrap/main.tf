# Socle créé une seule fois par compte AWS, avant les environnements :
#  - le bucket S3 qui garde l'état Terraform de dev et prod (versionné, chiffré, privé) ;
#  - la fédération OIDC GitHub → IAM : GitHub Actions obtient des identifiants temporaires,
#    aucune clé d'accès n'est stockée dans GitHub.
# Son propre état est rangé dans le même bucket une fois celui-ci créé (voir README).
terraform {
  required_version = ">= 1.10"

  backend "s3" {
    bucket       = "shopimt-tfstate-204924594218"
    key          = "bootstrap/terraform.tfstate"
    region       = "eu-west-3"
    encrypt      = true
    use_lockfile = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.70"
    }
  }
}

provider "aws" {
  region = "eu-west-3"

  default_tags {
    tags = {
      Projet  = "shop-imt"
      GerePar = "terraform"
    }
  }
}

variable "depot_github" {
  description = "Dépôt autorisé à se connecter à AWS (propriétaire/nom)"
  type        = string
  default     = "louizoom/shop-imt"
}

# GitHub peut émettre le « sub » du jeton OIDC avec les identifiants immuables du compte et du dépôt
# (repo:louizoom@125150055/shop-imt@1436114641:…) : un dépôt recréé sous le même nom n'a pas les mêmes.
variable "depot_github_ids" {
  description = "Même dépôt, au format propriétaire@id/nom@id du claim sub"
  type        = string
  default     = "louizoom@125150055/shop-imt@1436114641"
}

data "aws_caller_identity" "current" {}

locals {
  bucket_etat = "shopimt-tfstate-${data.aws_caller_identity.current.account_id}"
}

# ---------- État Terraform

resource "aws_s3_bucket" "etat" {
  bucket = local.bucket_etat

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "etat" {
  bucket = aws_s3_bucket.etat.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "etat" {
  bucket = aws_s3_bucket.etat.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "etat" {
  bucket                  = aws_s3_bucket.etat.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Les anciennes versions de l'état sont gardées 30 jours (retour arrière possible, stockage limité)
resource "aws_s3_bucket_lifecycle_configuration" "etat" {
  bucket = aws_s3_bucket.etat.id
  rule {
    id     = "anciennes-versions"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }
}

# ---------- GitHub Actions → AWS par OIDC

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

data "aws_iam_policy_document" "confiance_plan" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    # Toute exécution du dépôt (pull requests comprises) peut lancer un plan, en lecture seule
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.depot_github}:*", "repo:${var.depot_github_ids}:*"]
    }
  }
}

data "aws_iam_policy_document" "confiance_deploiement" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    # Seuls les jobs rattachés aux environnements GitHub dev ou prod (règles de protection) peuvent déployer
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = flatten([for d in [var.depot_github, var.depot_github_ids] : [for e in ["dev", "prod"] : "repo:${d}:environment:${e}"]])
    }
  }
}

# Rôle « plan » : lecture seule sur le compte + écriture des seuls fichiers de verrou de l'état
resource "aws_iam_role" "plan" {
  name               = "shopimt-github-plan"
  assume_role_policy = data.aws_iam_policy_document.confiance_plan.json
}

resource "aws_iam_role_policy_attachment" "plan_lecture" {
  role       = aws_iam_role.plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

resource "aws_iam_role_policy" "plan_verrou" {
  name = "verrou-etat"
  role = aws_iam_role.plan.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:PutObject", "s3:DeleteObject"]
      Resource = "${aws_s3_bucket.etat.arn}/*.tflock"
    }]
  })
}

# Rôle « déploiement » : crée et modifie toutes les ressources du projet
resource "aws_iam_role" "deploiement" {
  name                 = "shopimt-github-deploy"
  assume_role_policy   = data.aws_iam_policy_document.confiance_deploiement.json
  max_session_duration = 3600
}

resource "aws_iam_role_policy_attachment" "deploiement_admin" {
  role       = aws_iam_role.deploiement.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

# ---------- Accès console des membres de l'équipe (moindre privilège)

variable "utilisateurs_stock" {
  description = "Utilisateurs IAM qui ne gèrent que le stock (pendant AWS du rôle « stock » du site)"
  type        = list(string)
  default     = ["gabin"]
}

locals {
  tables_produits = "arn:aws:dynamodb:eu-west-3:${data.aws_caller_identity.current.account_id}:table/shopimt-*-produits"
}

# Groupe IAM « stock » : voit le catalogue et ne peut modifier que l'attribut stock d'un produit.
# Contrôle d'accès fin DynamoDB : la condition dynamodb:Attributes refuse toute écriture sur un
# autre attribut (prix, nom…), même avec la console.
resource "aws_iam_group" "stock" {
  name = "shopimt-stock"
}

resource "aws_iam_group_policy" "stock" {
  name  = "stock-seulement"
  group = aws_iam_group.stock.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ListerLesTables"
        Effect   = "Allow"
        Action   = ["dynamodb:ListTables", "dynamodb:DescribeLimits"]
        Resource = "*"
      },
      {
        Sid      = "LireLeCatalogue"
        Effect   = "Allow"
        Action   = ["dynamodb:DescribeTable", "dynamodb:Scan", "dynamodb:Query", "dynamodb:GetItem"]
        Resource = local.tables_produits
      },
      {
        Sid      = "ModifierLeStockSeulement"
        Effect   = "Allow"
        Action   = "dynamodb:UpdateItem"
        Resource = local.tables_produits
        Condition = {
          "ForAllValues:StringEquals" = { "dynamodb:Attributes" = ["id", "stock"] }
          StringEqualsIfExists        = { "dynamodb:ReturnValues" = ["NONE", "UPDATED_OLD", "UPDATED_NEW"] }
        }
      },
      {
        Sid      = "JournalDesActionsDeGestion"
        Effect   = "Allow"
        Action   = ["logs:DescribeLogGroups"]
        Resource = "*"
      },
      {
        Sid      = "LireLesLogsAdmin"
        Effect   = "Allow"
        Action   = ["logs:DescribeLogStreams", "logs:GetLogEvents", "logs:FilterLogEvents", "logs:StartQuery", "logs:GetQueryResults"]
        Resource = "arn:aws:logs:eu-west-3:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/shopimt-*-admin*"
      },
      {
        Sid      = "SonPropreMotDePasse"
        Effect   = "Allow"
        Action   = ["iam:ChangePassword", "iam:GetUser"]
        Resource = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:user/$${aws:username}"
      },
      {
        Sid      = "PolitiqueDeMotDePasse"
        Effect   = "Allow"
        Action   = "iam:GetAccountPasswordPolicy"
        Resource = "*"
      },
    ]
  })
}

resource "aws_iam_group_membership" "stock" {
  name  = "shopimt-stock-membres"
  group = aws_iam_group.stock.name
  users = var.utilisateurs_stock
}

output "bucket_etat" {
  value = aws_s3_bucket.etat.bucket
}

output "role_plan" {
  description = "À mettre dans la variable GitHub AWS_ROLE_PLAN"
  value       = aws_iam_role.plan.arn
}

output "role_deploiement" {
  description = "À mettre dans la variable GitHub AWS_ROLE_DEPLOY"
  value       = aws_iam_role.deploiement.arn
}
