terraform {
  required_version = ">= 1.11, < 2.0"

  required_providers {
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.9"
    }
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 4.46.0, < 5.0.0"
    }
  }

  # Prototype environments keep state locally. Add a backend block here to share state.
  # backend "azurerm" {}
}

provider "azurerm" {
  subscription_id = var.subscription_id

  features {}
}

provider "azapi" {
  subscription_id = var.subscription_id
}
