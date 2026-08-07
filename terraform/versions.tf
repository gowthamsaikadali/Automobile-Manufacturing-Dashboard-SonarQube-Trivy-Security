terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.31"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.4"
    }
  }

  # Left empty on purpose -- values are supplied at `terraform init` time via
  # -backend-config flags, using the bucket/table created by bootstrap/.
  # See README Part 2, Step 2.
  backend "s3" {}
}

provider "aws" {
  region = var.aws_region
}
