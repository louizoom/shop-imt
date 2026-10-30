# CloudFront devant l'ALB : HTTPS (certificat *.cloudfront.net fourni), cache des fichiers statiques à la
# périphérie, et l'ALB n'accepte que CloudFront (liste de préfixes gérée dans son groupe de sécurité).
# L'en-tête secret empêche en plus d'appeler l'ALB par une autre distribution CloudFront.

resource "random_password" "entete_origine" {
  length  = 32
  special = false
}

resource "aws_cloudfront_distribution" "site" {
  enabled         = true
  comment         = "SHOP'IMT ${var.environnement} - solution EC2"
  price_class     = "PriceClass_100"
  is_ipv6_enabled = true
  http_version    = "http2and3"

  origin {
    origin_id   = "alb"
    domain_name = aws_lb.web.dns_name
    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
    custom_header {
      name  = "X-Origine-Shopimt"
      value = random_password.entete_origine.result
    }
  }

  # API et pages : jamais en cache, tout est transmis à l'ALB (en-têtes, cookies, paramètres)
  default_cache_behavior {
    target_origin_id         = "alb"
    viewer_protocol_policy   = "redirect-to-https"
    allowed_methods          = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods           = ["GET", "HEAD"]
    cache_policy_id          = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad" # CachingDisabled
    origin_request_policy_id = "216adef6-5c7f-47e4-b989-5492eafa07d3" # AllViewer
    compress                 = true
  }

  # Fichiers du build Vite (noms avec empreinte) et images : en cache à la périphérie
  dynamic "ordered_cache_behavior" {
    for_each = ["/assets/*", "/img/*"]
    content {
      path_pattern           = ordered_cache_behavior.value
      target_origin_id       = "alb"
      viewer_protocol_policy = "redirect-to-https"
      allowed_methods        = ["GET", "HEAD"]
      cached_methods         = ["GET", "HEAD"]
      cache_policy_id        = "658327ea-f89d-4fab-a63d-7e88639e58f6" # CachingOptimized
      compress               = true
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

# L'ALB refuse (403) toute requête sans l'en-tête secret ajouté par CloudFront
resource "aws_lb_listener_rule" "depuis_cloudfront" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 1
  condition {
    http_header {
      http_header_name = "X-Origine-Shopimt"
      values           = [random_password.entete_origine.result]
    }
  }
  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web.arn
  }
}
