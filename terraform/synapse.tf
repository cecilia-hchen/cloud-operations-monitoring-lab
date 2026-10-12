# =============================================================================
# PHASE 2 - Synapse analytics (only created when enable_synapse = true)
#   Synapse workspace on the existing data lake (serverless SQL only),
#   firewall, managed identity RBAC, diagnostic logs, sample ticket data.
# =============================================================================

resource "random_password" "sql_admin" {
  count = var.enable_synapse ? 1 : 0

  length           = 20
  special          = true
  override_special = "!#%*-_"
  min_upper        = 2
  min_lower        = 2
  min_numeric      = 2
  min_special      = 2
}

resource "azurerm_storage_data_lake_gen2_filesystem" "synapse" {
  count = var.enable_synapse ? 1 : 0

  name               = "synapse"
  storage_account_id = azurerm_storage_account.datalake.id
}

resource "azurerm_synapse_workspace" "lab" {
  count = var.enable_synapse ? 1 : 0

  name                                 = "syn-${local.name_prefix}"
  resource_group_name                  = azurerm_resource_group.lab.name
  location                             = azurerm_resource_group.lab.location
  storage_data_lake_gen2_filesystem_id = azurerm_storage_data_lake_gen2_filesystem.synapse[0].id
  sql_administrator_login              = var.sql_admin_login
  sql_administrator_login_password     = random_password.sql_admin[0].result

  identity {
    type = "SystemAssigned"
  }

  tags = var.tags
}

# Firewall: Azure services + your IP only.
resource "azurerm_synapse_firewall_rule" "allow_azure_services" {
  count = var.enable_synapse ? 1 : 0

  name                 = "AllowAllWindowsAzureIps"
  synapse_workspace_id = azurerm_synapse_workspace.lab[0].id
  start_ip_address     = "0.0.0.0"
  end_ip_address       = "0.0.0.0"
}

resource "azurerm_synapse_firewall_rule" "allow_client_ip" {
  count = var.enable_synapse ? 1 : 0

  name                 = "AllowClientIP"
  synapse_workspace_id = azurerm_synapse_workspace.lab[0].id
  start_ip_address     = var.client_ip
  end_ip_address       = var.client_ip
}

# The workspace managed identity reads/writes its data lake.
resource "azurerm_role_assignment" "synapse_storage" {
  count = var.enable_synapse ? 1 : 0

  scope                = azurerm_storage_account.datalake.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_synapse_workspace.lab[0].identity[0].principal_id
}

# Every serverless SQL query and Synapse RBAC change goes to Log Analytics.
resource "azurerm_monitor_diagnostic_setting" "synapse" {
  count = var.enable_synapse ? 1 : 0

  name                       = "diag-synapse-to-law"
  target_resource_id         = azurerm_synapse_workspace.lab[0].id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.ops.id

  enabled_log {
    category = "BuiltinSqlReqsEnded"
  }

  enabled_log {
    category = "SynapseRbacOperations"
  }
}

# Sample operational data for the serverless SQL queries.
resource "azurerm_storage_blob" "sample_tickets" {
  count = var.enable_synapse ? 1 : 0

  name                   = "tickets/it_tickets.csv"
  storage_account_name   = azurerm_storage_account.datalake.name
  storage_container_name = azurerm_storage_data_lake_gen2_filesystem.data.name
  type                   = "Block"
  source                 = "${path.module}/../data/it_tickets.csv"
  content_type           = "text/csv"
}
