# =============================================================================
# WAF
# AWS-managed rule groups cover SQLi, XSS, and known bad inputs/bots without
# you having to hand-write attack signatures. Associated directly with the
# ALB (works whether the ALB was created by Terraform or the AWS Load
# Balancer Controller from an Ingress -- see the data source at the bottom).
# =============================================================================

resource "aws_wafv2_web_acl" "app_waf" {
  name        = "${var.project_name}-waf"
  description = "WAF for the automobile manufacturing dashboard ALB"
  scope       = "REGIONAL"

  default_action {
    allow {}
  }

  rule {
    name     = "AWS-CommonRuleSet"
    priority = 1
    override_action { none {} }
    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "commonRuleSet"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "AWS-SQLiRuleSet"
    priority = 2
    override_action { none {} }
    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesSQLiRuleSet"
        vendor_name = "AWS"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "sqliRuleSet"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "AWS-KnownBadInputs"
    priority = 3
    override_action { none {} }
    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "knownBadInputs"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "RateLimitPerIP"
    priority = 4
    action { block {} }
    statement {
      rate_based_statement {
        limit              = 2000 # requests per 5-minute window per IP
        aggregate_key_type = "IP"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "rateLimitPerIp"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.project_name}-waf"
    sampled_requests_enabled   = true
  }
}

# The ALB created by the AWS Load Balancer Controller (from your k8s Ingress)
# isn't a Terraform resource, so we look it up by tag and associate the WAF
# with it after Ingress apply. Run `terraform apply` a second time (or use
# -target) once the Ingress has created the ALB -- see README Part-Security
# step 6 for the exact sequencing.
data "aws_lb" "app_alb" {
  count = var.alb_arn_lookup_tag_value != "" ? 1 : 0
  tags = {
    "elbv2.k8s.aws/cluster" = var.alb_arn_lookup_tag_value
  }
}

variable "alb_arn_lookup_tag_value" {
  description = "EKS cluster name used to tag the ALB created by the Load Balancer Controller. Leave blank until the Ingress/ALB exists."
  type        = string
  default     = ""
}

resource "aws_wafv2_web_acl_association" "app_waf_assoc" {
  count        = var.alb_arn_lookup_tag_value != "" ? 1 : 0
  resource_arn = data.aws_lb.app_alb[0].arn
  web_acl_arn  = aws_wafv2_web_acl.app_waf.arn
}

output "waf_web_acl_arn" {
  value = aws_wafv2_web_acl.app_waf.arn
}
