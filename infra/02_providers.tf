# providers.tf

# ##############################
# Version
# ##############################
terraform {
  required_version = ">= 1.7"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }

  # remote state
  backend "s3" {}
}

# ##############################
# Providers
# ##############################
provider "aws" {
  region  = local.aws_region
  profile = local.project_name

  default_tags {
    tags = {
      Project   = local.project_name
      ManagedBy = "terraform"
    }
  }
}
