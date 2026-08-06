# =============================================================================
# BOOTSTRAP -- run this FIRST, on its own, with purely local state.
# Creates the S3 bucket + DynamoDB table that the main terraform/ project
# will use as its remote backend. This is the one piece of infra that can
# never live in the backend it creates (chicken-and-egg), so it stays local.
# =============================================================================
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
  }
}

provider "aws" {
  region = var.aws_region
}

variable "aws_region" {
  default = "ap-south-1"
}

variable "project_name" {
  default = "automobile-project"
}

# Random suffix so the bucket name is globally unique without you having to
# think of one -- S3 bucket names are unique across ALL AWS accounts.
resource "random_id" "suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "tf_state" {
  bucket = "${var.project_name}-tfstate-${random_id.suffix.hex}"

  # Prevents `terraform destroy` from ever accidentally nuking your state
  # bucket in the same run as the rest of your infra.
  lifecycle {
    prevent_destroy = false # set true once you're done iterating and want a hard guard
  }
}

resource "aws_s3_bucket_versioning" "tf_state_versioning" {
  bucket = aws_s3_bucket.tf_state.id
  versioning_configuration {
    status = "Enabled" # lets you roll back a corrupted/bad state file
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tf_state_encryption" {
  bucket = aws_s3_bucket.tf_state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tf_state_block" {
  bucket                  = aws_s3_bucket.tf_state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_dynamodb_table" "tf_lock" {
  name         = "${var.project_name}-tfstate-lock"
  billing_mode = "PAY_PER_REQUEST" # no capacity planning, scales to zero cost when idle
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }
}

output "state_bucket_name" {
  value = aws_s3_bucket.tf_state.bucket
}

output "lock_table_name" {
  value = aws_dynamodb_table.tf_lock.name
}
