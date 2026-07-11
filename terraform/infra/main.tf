terraform {
  required_version = ">= 1.7.0"

  backend "s3" {
    bucket         = "autoforge-tfstate-762131619075"
    key            = "infra/terraform.tfstate"
    region         = "ap-south-1"
    dynamodb_table = "autoforge-tf-locks"
    encrypt        = true
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
