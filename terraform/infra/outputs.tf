output "ecr_repository_url" {
  value       = aws_ecr_repository.app.repository_url
  description = "Set this as the GitHub Actions repo variable ECR_REPOSITORY"
}

output "cicd_role_arn" {
  value       = aws_iam_role.cicd_role.arn
  description = "Set this as the GitHub Actions repo variable CICD_ROLE_ARN"
}

output "app_pod_role_arn" {
  value       = aws_iam_role.app_pod_role.arn
  description = "Set this as the GitHub Actions repo variable APP_POD_ROLE_ARN"
}

output "eks_cluster_name" {
  value       = aws_eks_cluster.main.name
  description = "Pass to `aws eks update-kubeconfig --name <this>`"
}

output "vpc_id" {
  value = aws_vpc.main.id
}

output "waf_web_acl_arn" {
  value       = aws_wafv2_web_acl.autoforge.arn
  description = "Pass into helm values.ingress.wafAclArn"
}

output "alb_controller_role_arn" {
  value       = aws_iam_role.alb_controller_role.arn
  description = "Annotate the aws-load-balancer-controller ServiceAccount with this (see README Step 4)"
}
