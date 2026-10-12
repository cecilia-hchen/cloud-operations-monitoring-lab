# =============================================================================
# PHASE 1 - Core Azure environment
#   Resource group, networking (VNet, subnet, NSG), Data Lake storage,
#   Key Vault, Log Analytics, least-privilege RBAC, diagnostic logging.
# =============================================================================

data "azurerm_client_config" "current" {}

# Random suffix keeps globally unique names (storage, Key Vault, Synapse) from clashing.
resource "random_string" "suffix" {
  length  = 5
  upper   = false
  special = false
}

locals {
  name_prefix = "${var.project_name}${random_string.suffix.result}"
}

# --- Resource group ----------------------------------------------------------
resource "azurerm_resource_group" "lab" {
  name     = "rg-${local.name_prefix}"
  location = var.location
  tags     = var.tags
}

# --- Monitoring: Log Analytics -----------------------------------------------
resource "azurerm_log_analytics_workspace" "ops" {
  name                = "log-${local.name_prefix}"
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  sku                 = "PerGB2018"
  retention_in_days   = var.log_retention_days
  tags                = var.tags
}

# --- Networking ----------------------------------------------------------------
resource "azurerm_virtual_network" "lab" {
  name                = "vnet-${local.name_prefix}"
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  address_space       = [var.vnet_address_space]
  tags                = var.tags
}

resource "azurerm_subnet" "workload" {
  name                 = "snet-workload"
  resource_group_name  = azurerm_resource_group.lab.name
  virtual_network_name = azurerm_virtual_network.lab.name
  address_prefixes     = [var.subnet_prefix]
  service_endpoints    = ["Microsoft.Storage", "Microsoft.KeyVault"]
}

# Rules are defined inline, so Terraform owns the full rule set:
# any rule added by hand in the portal is removed on the next `terraform apply`.
resource "azurerm_network_security_group" "workload" {
  name                = "nsg-${local.name_prefix}"
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location

  security_rule {
    name                       = "Allow-HTTPS-From-Client"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "${var.client_ip}/32"
    destination_address_prefix = "VirtualNetwork"
  }

  security_rule {
    name                       = "Deny-All-Inbound"
    priority                   = 4096
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  tags = var.tags
}

resource "azurerm_subnet_network_security_group_association" "workload" {
  subnet_id                 = azurerm_subnet.workload.id
  network_security_group_id = azurerm_network_security_group.workload.id
}

# --- Storage: Data Lake Gen2 ---------------------------------------------------
resource "azurerm_storage_account" "datalake" {
  name                     = "st${local.name_prefix}"
  resource_group_name      = azurerm_resource_group.lab.name
  location                 = azurerm_resource_group.lab.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  account_kind             = "StorageV2"
  is_hns_enabled           = true
  min_tls_version          = "TLS1_2"

  allow_nested_items_to_be_public = false

  tags = var.tags
}

resource "azurerm_storage_data_lake_gen2_filesystem" "data" {
  name               = "data"
  storage_account_id = azurerm_storage_account.datalake.id
}

# --- Key Vault (RBAC mode) -----------------------------------------------------
resource "azurerm_key_vault" "ops" {
  name                       = "kv-${local.name_prefix}"
  resource_group_name        = azurerm_resource_group.lab.name
  location                   = azurerm_resource_group.lab.location
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  rbac_authorization_enabled = true
  soft_delete_retention_days = 7
  purge_protection_enabled   = false # lab only, so `terraform destroy` can fully clean up

  tags = var.tags
}

# --- RBAC (least privilege for the person running the lab) --------------------
# Data-plane access to the data lake, needed to upload reports and (phase 2) query files.
resource "azurerm_role_assignment" "me_storage" {
  scope                = azurerm_storage_account.datalake.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = data.azurerm_client_config.current.object_id
}

# Read-only access to secret metadata and values in the vault.
resource "azurerm_role_assignment" "me_key_vault" {
  scope                = azurerm_key_vault.ops.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = data.azurerm_client_config.current.object_id
}

# --- Diagnostic logging to Log Analytics ---------------------------------------
resource "azurerm_monitor_diagnostic_setting" "key_vault" {
  name                       = "diag-kv-to-law"
  target_resource_id         = azurerm_key_vault.ops.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.ops.id

  enabled_log {
    category = "AuditEvent"
  }
}

resource "azurerm_monitor_diagnostic_setting" "nsg" {
  name                       = "diag-nsg-to-law"
  target_resource_id         = azurerm_network_security_group.workload.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.ops.id

  enabled_log {
    category = "NetworkSecurityGroupEvent"
  }
}
