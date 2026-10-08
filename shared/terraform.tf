terraform {
  # The environment's shared resources have a state of their own, apart from every cluster's: a
  # cluster can then be destroyed and built again without touching them.
  backend "azurerm" {
    container_name = "tfstate"
    key            = "shared.tfstate"
    use_oidc       = true
  }

  required_version = ">= 1.11, < 2.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 4.46.0, < 5.0.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "azurerm" {
  resource_provider_registrations = "none"
  subscription_id                 = var.subscription_id

  features {}
}
