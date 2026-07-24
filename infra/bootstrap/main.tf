# Bootstraps initial terraform resources.

#----------------------------------------------------------
# Basic config
#----------------------------------------------------------

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.54"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.9"
    }
  }

  required_version = ">= 1.15"
}

provider "aws" {
  region = "us-east-1"
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.region
}

#----------------------------------------------------------
# S3 bucket holding terraform state
#----------------------------------------------------------

resource "aws_s3_bucket" "terraform_state" {
  bucket = format("waypoint-tfstate-%s-%s", local.account_id, local.region)
  lifecycle {
    prevent_destroy = true
  }
}

# Enable versioning so we can easily revert changes
resource "aws_s3_bucket_versioning" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  versioning_configuration {
    status = "Enabled"
  }
}

# Completely block public access:
resource "aws_s3_bucket_public_access_block" "terraform_state" {
  bucket                  = aws_s3_bucket.terraform_state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

#----------------------------------------------------------
# Auto-apply output to backend.tf on bootstrap
#----------------------------------------------------------

resource "local_file" "backend_config" {
  filename = "${path.module}/../live/backend.tf"
  content  = <<-EOF
terraform {
  backend "s3" {
    bucket         = "${aws_s3_bucket.terraform_state.bucket}"
    key            = "waypoint/live/terraform.tfstate"
    region         = "${local.region}"
    use_lockfile   = true
    encrypt        = true
  }
}
EOF
}
