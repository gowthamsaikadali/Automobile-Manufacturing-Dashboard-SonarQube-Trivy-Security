output "ecr_repository_url" {
  value       = aws_ecr_repository.app.repository_url
  description = "Set this as the GitHub Actions repo variable ECR_REPOSITORY"
}

output "cicd_role_arn" {
  value       = aws_iam_role.cicd_role.arn
  description = "Set this as the GitHub Actions repo variable CICD_ROLE_ARN"
}

output "app_pod_role_arn" {
  value       = var.eks_oidc_provider_arn != "" ? aws_iam_role.app_pod_role[0].arn : ""
  description = "Set this as the GitHub Actions repo variable APP_POD_ROLE_ARN (populated once eks_oidc_provider_arn is set)"
}

output "waf_web_acl_arn" {
  value       = aws_wafv2_web_acl.autoforge.arn
  description = "Pass into helm values.ingress.wafAclArn"
}
