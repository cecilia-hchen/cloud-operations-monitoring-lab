terraform {
  required_version = ">= 1.5.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "azurerm" {
  features {
    key_vault {
      # Lab setting: fully remove the vault on destroy so names can be reused.
      purge_soft_delete_on_destroy = true
    }
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }

  # azurerm 4.x requires the subscription ID. Set it in terraform.tfvars
  # (git-ignored) or export ARM_SUBSCRIPTION_ID.
  subscription_id = var.subscription_id
}
