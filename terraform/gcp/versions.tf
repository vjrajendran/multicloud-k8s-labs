terraform {
  required_version = ">= 1.9.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
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

# Credentials come from GOOGLE_APPLICATION_CREDENTIALS (up.sh points it at a
# service-account key or at this sandbox's `gcloud auth application-default login`).
provider "google" {
  project               = var.project
  region                = var.region
  billing_project       = var.project
  user_project_override = true

  default_labels = {
    project    = "multicloud-k8s-labs"
    sandbox    = terraform.workspace
    managed-by = "terraform"
  }
}
