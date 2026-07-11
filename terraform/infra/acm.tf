resource "aws_acm_certificate" "autoforge" {
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
#   for_each = {
#     for dvo in aws_acm_certificate.autoforge.domain_validation_options : dvo.domain_name => {
#       name   = dvo.resource_record_name
#       type   = dvo.resource_record_type
#       record = dvo.resource_record_value
#     }
#   }
#   zone_id = data.aws_route53_zone.this.zone_id
#   name    = each.value.name
#   type    = each.value.type
#   ttl     = 60
#   records = [each.value.record]
# }
#
# resource "aws_acm_certificate_validation" "autoforge" {
#   certificate_arn         = aws_acm_certificate.autoforge.arn
#   validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
# }

output "acm_certificate_arn" {
  value       = aws_acm_certificate.autoforge.arn
  description = "Pass this into the Helm chart's ingress.tls.acmCertArn value"
}
