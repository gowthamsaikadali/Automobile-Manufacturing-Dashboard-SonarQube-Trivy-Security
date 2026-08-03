# =============================================================================
# ACM CERTIFICATE + HTTPS
#
# IMPORTANT CAVEAT: ACM cannot issue a certificate for an ALB's
# auto-generated DNS name (e.g. automobile-project-dev-alb-xxxx.elb.
# amazonaws.com). Certificates require a domain you control, validated via
# DNS (Route 53) or email. There are only two real options:
#
#   OPTION A (recommended): register/use a domain, e.g. via Route 53
#   ($12/yr for a .com), point a subdomain at the ALB, and validate the
#   cert against that subdomain. This is what this file implements.
#
#   OPTION B (stay domain-free): terminate TLS with a self-signed cert
#   instead of ACM. Browsers will show "Not Secure" -- functionally
#   private the same way, but not a trusted public cert. Only appropriate
#   for a dev/demo environment. See the commented block at the bottom.
#
# Set var.domain_name to enable Option A. Leave it blank and the ALB stays
# HTTP-only (current behavior) until you're ready to add a domain.
# =============================================================================

variable "domain_name" {
  description = "Domain you own for the app, e.g. app.example.com. Leave empty to skip HTTPS/ACM."
  type        = string
  default     = ""
}

variable "route53_zone_id" {
  description = "Existing Route 53 hosted zone ID for domain_name's parent zone"
  type        = string
  default     = ""
}

resource "aws_acm_certificate" "app_cert" {
  count             = var.domain_name != "" ? 1 : 0
  domain_name       = var.domain_name
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "cert_validation" {
  for_each = var.domain_name != "" ? {
    for dvo in aws_acm_certificate.app_cert[0].domain_validation_options : dvo.domain_name => {
      name  = dvo.resource_record_name
      type  = dvo.resource_record_type
      value = dvo.resource_record_value
    }
  } : {}

  zone_id = var.route53_zone_id
  name    = each.value.name
  type    = each.value.type
  records = [each.value.value]
  ttl     = 60
}

resource "aws_acm_certificate_validation" "app_cert_validation" {
  count                   = var.domain_name != "" ? 1 : 0
  certificate_arn         = aws_acm_certificate.app_cert[0].arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}

# The HTTPS listener itself is added on the Ingress resource, not here --
# see k8s/ingress.yaml, which references this cert's ARN via annotation.
output "acm_certificate_arn" {
  value = var.domain_name != "" ? aws_acm_certificate.app_cert[0].arn : ""
}

# ---------------------------------------------------------------------------
# OPTION B: self-signed cert for a domain-free dev environment.
# Uncomment if you are NOT using a real domain and just want TLS in transit
# (browsers will warn "Not Secure" -- do not use for anything but a demo).
# ---------------------------------------------------------------------------
# resource "tls_private_key" "self_signed" {
#   algorithm = "RSA"
#   rsa_bits  = 2048
# }
#
# resource "tls_self_signed_cert" "self_signed" {
#   private_key_pem = tls_private_key.self_signed.private_key_pem
#   subject { common_name = "automobile-dashboard.local" }
#   validity_period_hours = 8760
#   allowed_uses = ["key_encipherment", "digital_signature", "server_auth"]
# }
#
# resource "aws_acm_certificate" "self_signed_import" {
#   private_key      = tls_private_key.self_signed.private_key_pem
#   certificate_body = tls_self_signed_cert.self_signed.cert_pem
# }
