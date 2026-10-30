# Un bucket S3 pour la solution EC2 : code/ (application et front, lus par les instances au démarrage)
# et audit/ (une trace JSON par événement Kafka). Privé, chiffré, accès par les rôles IAM des instances.

resource "aws_s3_bucket" "ec2" {
  bucket        = "${var.prefix}-${local.compte}"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "ec2" {
  bucket                  = aws_s3_bucket.ec2.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "ec2" {
  bucket = aws_s3_bucket.ec2.id

  rule {
    id     = "audit-90-jours"
    status = "Enabled"
    filter {
      prefix = "audit/"
    }
    expiration {
      days = 90
    }
  }

  rule {
    id     = "anciennes-versions-du-code"
    status = "Enabled"
    filter {
      prefix = "code/"
    }
    expiration {
      days = 30 # chaque version porte l'empreinte de son contenu : les anciennes ne servent plus
    }
  }
}

# Application : code EC2 + modules métier des Lambdas réutilisés (validation, e-mails, plan d'expédition)
data "archive_file" "application" {
  type        = "zip"
  output_path = "${path.root}/.build/ec2-application.zip"

  dynamic "source" {
    for_each = fileset("${var.dossier_backend}/ec2", "**/*.{py,txt}")
    content {
      content  = file("${var.dossier_backend}/ec2/${source.value}")
      filename = source.value
    }
  }

  dynamic "source" {
    for_each = toset(["commandes.py", "notification.py", "traitement.py"])
    content {
      content  = file("${var.dossier_backend}/lambdas/${source.value}")
      filename = source.value
    }
  }
}

# Front : le même build Vue que la solution serverless
data "archive_file" "site" {
  type        = "zip"
  source_dir  = var.dossier_site
  output_path = "${path.root}/.build/ec2-site.zip"
}

resource "aws_s3_object" "application" {
  bucket = aws_s3_bucket.ec2.id
  key    = "code/application-${data.archive_file.application.output_md5}.zip"
  source = data.archive_file.application.output_path
  etag   = data.archive_file.application.output_md5
}

resource "aws_s3_object" "site" {
  bucket = aws_s3_bucket.ec2.id
  key    = "code/site-${data.archive_file.site.output_md5}.zip"
  source = data.archive_file.site.output_path
  etag   = data.archive_file.site.output_md5
}
