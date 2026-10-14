terraform {
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.4"
    }
  }
}

# Credentials come from the environment (up.sh exports each sandbox's keys).
# Each Terraform workspace (aws1, aws2, ...) is a separate Pluralsight sandbox.
provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = "multicloud-k8s-labs"
      Sandbox   = terraform.workspace
      ManagedBy = "terraform"
    }
  }
}
