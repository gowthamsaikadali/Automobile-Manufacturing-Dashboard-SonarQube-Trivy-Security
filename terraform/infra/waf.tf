resource "aws_wafv2_web_acl" "autoforge" {
  name        = "${var.project}-waf"
  description = "Blocks common web attacks (SQLi, XSS) in front of the AutoForge ALB"
  scope       = "REGIONAL" # use CLOUDFRONT if fronted by CloudFront instead of ALB

  default_action {
    allow {}
  }

  rule {
    name     = "AWS-CommonRuleSet"
    priority = 0
    override_action {
      none {}
    }
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
    priority = 1
    override_action {
      none {}
    }
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
    priority = 2
    override_action {
      none {}
    }
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
    priority = 3
    action {
      block {}
    }
    statement {
      rate_based_statement {
        limit              = 2000 # requests per 5 minutes per IP
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
    metric_name                = "autoforgeWaf"
    sampled_requests_enabled   = true
  }
}

# Associate with the ALB created by the AWS Load Balancer Controller.
# The ALB ARN is only known after the Ingress is created, so this is
# normally applied as a second `terraform apply` (or via a data source
# lookup by tag once the Ingress/ALB exists).
variable "alb_arn" {
  description = "ARN of the ALB provisioned by the Ingress (leave blank on first apply)"
  type        = string
  default     = ""
}

resource "aws_wafv2_web_acl_association" "autoforge" {
  count        = var.alb_arn != "" ? 1 : 0
  resource_arn = var.alb_arn
  web_acl_arn  = aws_wafv2_web_acl.autoforge.arn
}
