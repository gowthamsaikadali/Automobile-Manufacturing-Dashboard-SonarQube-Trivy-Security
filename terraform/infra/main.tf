terraform {
  required_version = ">= 1.7.0"

  # Partial backend configuration on purpose - the bucket/table names are
  # account-specific and are supplied at `terraform init` time via
  # -backend-config flags (or a local, gitignored backend.hcl file), so
  # nothing account-specific ever needs to be committed to this repo.
  # See README Step 0 for the exact init command.
  backend "s3" {
    key     = "infra/terraform.tfstate"
    region  = "ap-south-1"
    encrypt = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.55"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

data "aws_caller_identity" "current" {}
