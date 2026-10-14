terraform {
  required_version = ">= 1.9.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.0"
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

# Credentials come from the environment (up.sh exports them): either a service
# principal (ARM_CLIENT_ID / ARM_CLIENT_SECRET / ARM_TENANT_ID) or an `az login`
# session, plus ARM_SUBSCRIPTION_ID.
provider "azurerm" {
  features {}

  # The sandbox user can't register resource providers
  resource_provider_registrations = "none"
}

provider "azapi" {}
