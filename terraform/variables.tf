variable "aws_region" {
  default = "ap-south-1"
}

variable "project_name" {
  default = "automobile-project"
}

variable "vpc_cidr" {
  default = "10.0.0.0/16"
}

variable "eks_cluster_version" {
  default = "1.34"
}

variable "eks_node_instance_types" {
  description = "Instance type for EKS managed node group"
  type        = list(string)
  default     = ["c7i-flex.large"] # NOT Free Tier eligible -- see README cost note
}

variable "node_desired_size" {
  default = 2
}

variable "node_min_size" {
  default = 2
}

variable "node_max_size" {
  default = 4
}

variable "db_instance_class" {
  default = "db.t3.micro"
}

variable "db_name" {
  default = "automobile_db"
}

variable "db_username" {
  default = "appadmin"
}

variable "admin_username" {
  description = "Login username for the app's own admin account (not the DB)"
  default     = "admin"
}

variable "github_org" {
  description = "GitHub org/user that owns this repo (for CI/CD OIDC trust condition)"
  type        = string
}

variable "github_repo" {
  description = "GitHub repo name (for CI/CD OIDC trust condition)"
  type        = string
}

variable "sonarqube_instance_type" {
  description = "EC2 instance size for the self-hosted SonarQube server"
  default     = "c7i-flex.large" # *GB RAM -- below this, Elasticsearch (bundled) struggles
}

variable "sonarqube_allowed_cidrs" {
  description = "CIDR(s) allowed to reach the SonarQube web UI on port 9000. Default is open to the internet for simplicity (portfolio use); restrict to your own IP/32 for tighter security."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "additional_admin_arns" {
  description = "IAM user/role ARNs (besides the Terraform apply identity) that should get EKS cluster admin access -- add your own console login identity here"
  type        = list(string)
  default     = []
}
