# =============================================================================
# WAF
# AWS-managed rule groups cover SQLi, XSS, and known bad inputs/bots.
# Works purely off the ALB's auto-generated DNS name -- no domain needed.
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
        limit              = 2000
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

# The ALB is created by the AWS Load Balancer Controller from your k8s
# Ingress, not by Terraform directly -- so it's looked up by cluster tag and
# associated in a second apply pass. See README Part 8.
data "aws_lb" "app_alb" {
  count = var.associate_waf ? 1 : 0
  tags = {
    "elbv2.k8s.aws/cluster" = var.project_name
  }
}

variable "associate_waf" {
  description = "Set true once the Ingress/ALB exists (second terraform apply pass)"
  type        = bool
  default     = false
}

resource "aws_wafv2_web_acl_association" "app_waf_assoc" {
  count        = var.associate_waf ? 1 : 0
  resource_arn = data.aws_lb.app_alb[0].arn
  web_acl_arn  = aws_wafv2_web_acl.app_waf.arn
}

output "waf_web_acl_arn" {
  value = aws_wafv2_web_acl.app_waf.arn
}
