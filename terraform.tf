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

  # One root module serves every environment, so each one needs its own state. Locally that is a
  # workspace per environment; with a shared backend, give each environment its own state key.
  # backend "azurerm" {}
}

provider "azurerm" {
  subscription_id = var.subscription_id

  features {}
}

provider "azapi" {
  subscription_id = var.subscription_id
}
