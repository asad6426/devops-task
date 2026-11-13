terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.80"
    }
  }

  # Partial configuration: bucket/key/region come from backend/<env>.hcl so the same
  # code serves staging and production with fully separate state files.
  # `use_lockfile = true` enables native S3 state locking (Terraform >= 1.10), no DynamoDB needed.
  backend "s3" {}
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = "devops-task"
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}
