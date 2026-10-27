# --- Bucket d'audit : une trace JSON par commande (audit/AAAA/MM/JJ/<order_id>.json)
# Requêtable avec Athena pour le reporting (non déployé : facturé au volume scanné).

resource "aws_s3_bucket" "audit" {
  bucket        = "${var.prefix}-audit-${data.aws_caller_identity.current.account_id}"
  force_destroy = true # pratique pour terraform destroy en contexte projet
}

resource "aws_s3_bucket_public_access_block" "audit" {
  bucket                  = aws_s3_bucket.audit.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "audit" {
  bucket = aws_s3_bucket.audit.id

  rule {
    id     = "expiration-90-jours"
    status = "Enabled"
    filter {
      prefix = "audit/"
    }
    expiration {
      days = 90
    }
  }

  # Exports CSV de l'interface admin : données personnelles (e-mails), supprimés après 1 jour
  rule {
    id     = "exports-1-jour"
    status = "Enabled"
    filter {
      prefix = "exports/"
    }
    expiration {
      days = 1
    }
  }
}

# --- Bucket du site web : privé, servi uniquement par CloudFront (Origin Access Control)

resource "aws_s3_bucket" "frontend" {
  bucket        = "${var.prefix}-frontend-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "frontend" {
  bucket                  = aws_s3_bucket.frontend.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

data "aws_iam_policy_document" "frontend" {
  statement {
    sid       = "LectureParCloudFront"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.frontend.arn}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.site.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "frontend" {
  bucket     = aws_s3_bucket.frontend.id
  policy     = data.aws_iam_policy_document.frontend.json
  depends_on = [aws_s3_bucket_public_access_block.frontend]
}

locals {
  # Front compilé par Vite (frontend/dist) : type MIME déduit de l'extension
  types_mime = {
    html  = "text/html; charset=utf-8", js = "application/javascript; charset=utf-8", css = "text/css; charset=utf-8",
    svg   = "image/svg+xml", png = "image/png", jpg = "image/jpeg", ico = "image/x-icon",
    json  = "application/json", webmanifest = "application/manifest+json", txt = "text/plain; charset=utf-8",
    woff2 = "font/woff2",
  }
  fichiers_site = { for f in fileset(local.dossier_site, "**") : f => lookup(local.types_mime, reverse(split(".", f))[0], "application/octet-stream") }
}

resource "aws_s3_object" "site" {
  for_each     = local.fichiers_site
  bucket       = aws_s3_bucket.frontend.id
  key          = each.key
  source       = "${local.dossier_site}/${each.key}"
  etag         = filemd5("${local.dossier_site}/${each.key}")
  content_type = each.value
  # Fichiers de assets/ nommés d'après leur contenu par Vite : cache d'un an sans risque.
  # index.html et images : 60 s, une nouvelle version est visible en une minute sans invalidation.
  cache_control = startswith(each.key, "assets/") ? "public, max-age=31536000, immutable" : "public, max-age=60"
}
