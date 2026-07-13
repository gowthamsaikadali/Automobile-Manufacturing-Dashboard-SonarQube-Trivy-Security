# ACM certificate is OPTIONAL. If you don't own a domain yet, leave
# var.domain_name = "" (the default) and this whole file becomes a no-op -
# the app will be reachable over plain HTTP at the ALB's own auto-generated
# DNS name (e.g. k8s-autoforge-xxxx.ap-south-1.elb.amazonaws.com).
#
# Once you buy/register a domain (or get a free one, e.g. via DuckDNS,
# which supports the DNS validation ACM needs), set domain_name and
# re-apply - this will then create a real cert and you flip
# ingress.tls.enabled = true in Helm values.

resource "aws_acm_certificate" "autoforge" {
  count             = var.domain_name != "" ? 1 : 0
  domain_name       = var.domain_name
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

# If your hosted zone is in Route53, uncomment and set the zone id:
# data "aws_route53_zone" "this" {
#   name = "example.com."
# }
#
# resource "aws_route53_record" "cert_validation" {
#   for_each = var.domain_name != "" ? {
#     for dvo in aws_acm_certificate.autoforge[0].domain_validation_options : dvo.domain_name => {
#       name   = dvo.resource_record_name
#       type   = dvo.resource_record_type
#       record = dvo.resource_record_value
#     }
#   } : {}
#   zone_id = data.aws_route53_zone.this.zone_id
#   name    = each.value.name
#   type    = each.value.type
#   ttl     = 60
#   records = [each.value.record]
# }
#
# resource "aws_acm_certificate_validation" "autoforge" {
#   count                   = var.domain_name != "" ? 1 : 0
#   certificate_arn         = aws_acm_certificate.autoforge[0].arn
#   validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
# }

output "acm_certificate_arn" {
  value       = var.domain_name != "" ? aws_acm_certificate.autoforge[0].arn : ""
  description = "Empty until you set var.domain_name and re-apply. Pass into helm values.ingress.acmCertArn once populated."
}
