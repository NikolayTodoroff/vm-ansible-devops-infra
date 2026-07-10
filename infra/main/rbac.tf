resource "azurerm_role_assignment" "vm_secrets_user" {
  scope                = module.key_vault.key_vault_id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = module.vm.identity_principal_id
}

resource "azurerm_role_assignment" "pipeline_sp" {
  scope                = module.key_vault.key_vault_id
  role_definition_name = "Key Vault Administrator"
  principal_id         = var.pipeline_sp_object_id
}

resource "azurerm_role_assignment" "deployer_network_contributor" {
  scope                = azurerm_resource_group.rg_main.id
  role_definition_name = "Network Contributor"
  principal_id         = var.pipeline_sp_object_id
}

resource "azurerm_role_assignment" "automation_reader" {
  scope                = azurerm_resource_group.rg_main.id
  role_definition_name = "Reader"
  principal_id         = module.automation.automation_identity_principal_id
}

resource "azurerm_role_assignment" "automation_vm_command" {
  scope                = module.vm.vm_id
  role_definition_name = "Virtual Machine Contributor"
  principal_id         = module.automation.automation_identity_principal_id
}