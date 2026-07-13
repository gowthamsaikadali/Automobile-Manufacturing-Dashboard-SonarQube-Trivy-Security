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

variable "tf_state_bucket_name" {
  description = "S3 bucket name from the bootstrap stage's `state_bucket_name` output"
  type        = string
}

variable "tf_lock_table_name" {
  description = "DynamoDB table name from the bootstrap stage's `lock_table_name` output"
  type        = string
}

variable "domain_name" {
  description = "Optional. Leave blank if you don't own a domain yet - the app will be reachable over plain HTTP via the ALB's own DNS name. Set this later to enable ACM/HTTPS."
  type        = string
  default     = ""
}
