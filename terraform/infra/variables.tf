variable "aws_region" {
  default = "ap-south-1"
}

variable "project" {
  default = "autoforge"
}

variable "vpc_id" {
  description = "Existing VPC ID (from your network stage)"
  type        = string
}

variable "public_subnet_ids" {
  type = list(string)
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "db_name" {
  default = "autoforge_db"
}

variable "db_username" {
  description = "Master username - must match the value stored in Secrets Manager (see secrets.tf)"
  default     = "admin"
}

variable "eks_cluster_name" {
  default = "autoforge-eks"
}

variable "github_repo" {
  description = "owner/repo for GitHub OIDC trust policy"
  default     = "gowthamsaikadali/Automobile-Manufacturing-Dashboard-SonarQube-Trivy-Security"
}

variable "domain_name" {
  description = "Domain/subdomain the ACM cert + ALB will serve (e.g. autoforge.example.com)"
  type        = string
}
