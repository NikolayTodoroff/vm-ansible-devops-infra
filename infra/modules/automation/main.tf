resource "azurerm_log_analytics_workspace" "main" {
  name                = "log-${var.prefix}"
  location            = var.location
  resource_group_name = var.resource_group_name
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = var.tags
}

resource "azurerm_automation_account" "main" {
  name                = "aa-${var.prefix}"
  location            = var.location
  resource_group_name = var.resource_group_name
  sku_name            = "Basic"
  tags                = var.tags

  identity {
    type = "SystemAssigned"
  }
}

resource "azurerm_log_analytics_linked_service" "automation" {
  resource_group_name = var.resource_group_name
  workspace_id        = azurerm_log_analytics_workspace.main.id
  read_access_id      = azurerm_automation_account.main.id
}

resource "azurerm_automation_runbook" "health_check" {
  name                    = "vm-health-check"
  location                = var.location
  resource_group_name     = var.resource_group_name
  automation_account_name = azurerm_automation_account.main.name
  log_verbose             = true
  log_progress            = true
  runbook_type            = "PowerShell"
  content                 = file("${path.module}/runbooks/vm-health-check.ps1")
  tags                    = var.tags
}

resource "azurerm_automation_schedule" "daily" {
  name                    = "daily-health-check"
  resource_group_name     = var.resource_group_name
  automation_account_name = azurerm_automation_account.main.name
  frequency               = "Day"
  interval                = 1
  timezone                = "Europe/Sofia"
  description             = "Runs the VM health check once per day"
}

resource "azurerm_automation_job_schedule" "health_check_daily" {
  resource_group_name     = var.resource_group_name
  automation_account_name = azurerm_automation_account.main.name
  runbook_name            = azurerm_automation_runbook.health_check.name
  schedule_name           = azurerm_automation_schedule.daily.name

  parameters = {
    vmname            = var.vm_name
    resourcegroupname = var.resource_group_name
  }
}