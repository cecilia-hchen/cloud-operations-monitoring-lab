# --- Phase 1 -------------------------------------------------------------------
output "resource_group_name" {
  value = azurerm_resource_group.lab.name
}

output "storage_account_name" {
  value = azurerm_storage_account.datalake.name
}

output "key_vault_name" {
  value = azurerm_key_vault.ops.name
}

output "log_analytics_workspace_name" {
  value = azurerm_log_analytics_workspace.ops.name
}

output "nsg_name" {
  value = azurerm_network_security_group.workload.name
}

# --- Phase 2 (null until enable_synapse = true) --------------------------------
output "synapse_workspace_name" {
  value = try(azurerm_synapse_workspace.lab[0].name, null)
}

output "synapse_studio_url" {
  value = try("https://web.azuresynapse.net?workspace=${urlencode(azurerm_synapse_workspace.lab[0].id)}", null)
}

output "data_lake_base_url" {
  description = "Base URL for OPENROWSET queries (phase 2)."
  value       = "https://${azurerm_storage_account.datalake.name}.dfs.core.windows.net/${azurerm_storage_data_lake_gen2_filesystem.data.name}"
}

output "sql_admin_password" {
  description = "Run: terraform output -raw sql_admin_password"
  value       = try(random_password.sql_admin[0].result, null)
  sensitive   = true
}
