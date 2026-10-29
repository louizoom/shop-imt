# CloudFront : point d'entrée unique en HTTPS pour le site ET l'API.
#   /             -> bucket S3 privé (Origin Access Control)
#   /produits     -> API Gateway, mis en cache 5 s en edge (catalogue très lu)
#   /commandes*   -> API Gateway, jamais mis en cache
#   /compte/*     -> API Gateway avec le jeton Cognito (Mes commandes, commande liée au compte)
#   /admin/*      -> API Gateway avec le jeton Cognito, groupe admins (interface admin)
# Même domaine pour le site et l'API : pas de CORS, et l'URL de l'API n'a pas à être injectée dans le front.
# Free Tier permanent : 1 To de transfert et 10 M de requêtes par mois.

data "aws_cloudfront_cache_policy" "optimise" {
  name = "Managed-CachingOptimized"
}

data "aws_cloudfront_cache_policy" "desactive" {
  name = "Managed-CachingDisabled"
}

data "aws_cloudfront_origin_request_policy" "api" {
  name = "Managed-AllViewerExceptHostHeader"
}

data "aws_cloudfront_response_headers_policy" "securite" {
  name = "Managed-SecurityHeadersPolicy" # HSTS, X-Frame-Options, nosniff...
}

resource "aws_cloudfront_cache_policy" "catalogue" {
  name        = "${var.prefix}-catalogue-5s"
  min_ttl     = 0
  default_ttl = 5
  max_ttl     = 30

  parameters_in_cache_key_and_forwarded_to_origin {
    enable_accept_encoding_gzip   = true
    enable_accept_encoding_brotli = true
    cookies_config {
      cookie_behavior = "none"
    }
    headers_config {
      header_behavior = "none"
    }
    query_strings_config {
      query_string_behavior = "none"
    }
  }
}

# /compte/* : le jeton de connexion (en-tête Authorization) doit atteindre l'API. CloudFront ne le
# transmet que s'il fait partie de la clé de cache ; durée de cache 0 par défaut, chaque client a sa clé.
resource "aws_cloudfront_cache_policy" "compte" {
  name        = "${var.prefix}-compte"
  min_ttl     = 0
  default_ttl = 0
  max_ttl     = 1

  parameters_in_cache_key_and_forwarded_to_origin {
    cookies_config {
      cookie_behavior = "none"
    }
    headers_config {
      header_behavior = "whitelist"
      headers {
        items = ["Authorization"]
      }
    }
    query_strings_config {
      query_string_behavior = "none"
    }
  }
}

resource "aws_cloudfront_origin_access_control" "site" {
  name                              = "${var.prefix}-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# Langue par défaut du site d'après le navigateur (Accept-Language), cookie « lang »
resource "aws_cloudfront_function" "langue" {
  name    = "${var.prefix}-langue"
  runtime = "cloudfront-js-2.0"
  comment = "Cookie lang (fr/en) d'après Accept-Language"
  publish = true
  code    = <<-JS
    // CloudFront Function (viewer-response) : langue du site choisie à la périphérie, sans Lambda.
    // Première visite : lit Accept-Language et dépose le cookie « lang » (fr ou en), que le front lit
    // au démarrage. Un choix manuel dans le site remplace ce cookie. Gratuit jusqu'à 2 M d'appels/mois.
    function handler(event) {
      var request = event.request;
      var response = event.response;
      if (request.cookies.lang) {
        return response;
      }
      var accept = request.headers['accept-language'] ? request.headers['accept-language'].value.toLowerCase() : '';
      // La langue citée en premier l'emporte (« en-US,en;q=0.9,fr;q=0.8 » -> en) ; français par défaut
      var fr = accept.indexOf('fr');
      var en = accept.indexOf('en');
      var langue = en !== -1 && (fr === -1 || en < fr) ? 'en' : 'fr';
      response.cookies.lang = { value: langue, attributes: 'Path=/; Max-Age=31536000; SameSite=Lax; Secure' };
      return response;
    }
  JS
}

# Adresses du front (/suivi/<id>, /compte, /admin) servies par index.html : routage côté navigateur
resource "aws_cloudfront_function" "routage" {
  name    = "${var.prefix}-routage"
  runtime = "cloudfront-js-2.0"
  comment = "Chemins sans extension vers index.html (Vue Router)"
  publish = true
  code    = <<-JS
    // CloudFront Function (viewer-request) : routage du front (Vue Router, historique HTML5).
    // Une adresse sans extension (/suivi/<id>, /compte, /admin) est servie par index.html, le routeur
    // du navigateur affiche ensuite la bonne page. Les fichiers (/assets/x.js, /img/p001.jpg) passent tels quels.
    // Les routes de l'API (/produits, /commandes*, /compte/*, /admin/*) ont leurs propres comportements :
    // cette fonction ne les voit jamais.
    function handler(event) {
      var request = event.request;
      var dernier = request.uri.split('/').pop();
      if (dernier.indexOf('.') === -1) {
        request.uri = '/index.html';
      }
      return request;
    }
  JS
}

resource "aws_cloudfront_distribution" "site" {
  enabled             = true
  comment             = "SHOP'IMT - boutique en ligne (${var.prefix})"
  default_root_object = "index.html"
  price_class         = "PriceClass_100" # Europe + Amérique du Nord
  http_version        = "http2and3"

  origin {
    domain_name              = aws_s3_bucket.frontend.bucket_regional_domain_name
    origin_id                = "s3-frontend"
    origin_access_control_id = aws_cloudfront_origin_access_control.site.id
  }

  origin {
    domain_name = replace(aws_apigatewayv2_api.api.api_endpoint, "https://", "")
    origin_id   = "api"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  default_cache_behavior {
    target_origin_id           = "s3-frontend"
    viewer_protocol_policy     = "redirect-to-https"
    allowed_methods            = ["GET", "HEAD"]
    cached_methods             = ["GET", "HEAD"]
    cache_policy_id            = data.aws_cloudfront_cache_policy.optimise.id
    response_headers_policy_id = data.aws_cloudfront_response_headers_policy.securite.id
    compress                   = true

    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.routage.arn
    }

    function_association {
      event_type   = "viewer-response"
      function_arn = aws_cloudfront_function.langue.arn
    }
  }

  ordered_cache_behavior {
    path_pattern               = "/produits"
    target_origin_id           = "api"
    viewer_protocol_policy     = "https-only"
    allowed_methods            = ["GET", "HEAD"]
    cached_methods             = ["GET", "HEAD"]
    cache_policy_id            = aws_cloudfront_cache_policy.catalogue.id
    response_headers_policy_id = data.aws_cloudfront_response_headers_policy.securite.id
    compress                   = true
  }

  ordered_cache_behavior {
    path_pattern               = "/commandes*"
    target_origin_id           = "api"
    viewer_protocol_policy     = "https-only"
    allowed_methods            = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods             = ["GET", "HEAD"]
    cache_policy_id            = data.aws_cloudfront_cache_policy.desactive.id
    origin_request_policy_id   = data.aws_cloudfront_origin_request_policy.api.id
    response_headers_policy_id = data.aws_cloudfront_response_headers_policy.securite.id
    compress                   = true
  }

  ordered_cache_behavior {
    path_pattern               = "/compte/*"
    target_origin_id           = "api"
    viewer_protocol_policy     = "https-only"
    allowed_methods            = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods             = ["GET", "HEAD"]
    cache_policy_id            = aws_cloudfront_cache_policy.compte.id
    origin_request_policy_id   = data.aws_cloudfront_origin_request_policy.api.id
    response_headers_policy_id = data.aws_cloudfront_response_headers_policy.securite.id
    compress                   = true
  }

  ordered_cache_behavior {
    path_pattern               = "/admin/*"
    target_origin_id           = "api"
    viewer_protocol_policy     = "https-only"
    allowed_methods            = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods             = ["GET", "HEAD"]
    cache_policy_id            = aws_cloudfront_cache_policy.compte.id # jeton dans la clé, cache 0
    origin_request_policy_id   = data.aws_cloudfront_origin_request_policy.api.id
    response_headers_policy_id = data.aws_cloudfront_response_headers_policy.securite.id
    compress                   = true
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  aliases = local.domaine_actif ? [var.domaine_site] : []

  viewer_certificate {
    cloudfront_default_certificate = !local.domaine_actif
    acm_certificate_arn            = local.domaine_actif ? aws_acm_certificate_validation.site[0].certificate_arn : null
    ssl_support_method             = local.domaine_actif ? "sni-only" : null
    minimum_protocol_version       = local.domaine_actif ? "TLSv1.2_2021" : "TLSv1"
  }
}
