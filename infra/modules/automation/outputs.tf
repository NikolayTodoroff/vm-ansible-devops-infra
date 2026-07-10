output "automation_account_name" {
  value = azurerm_automation_account.main.name
}

output "automation_identity_principal_id" {
  value = azurerm_automation_account.main.identity[0].principal_id
}

output "log_analytics_workspace_id" {
  value = azurerm_log_analytics_workspace.main.id
}