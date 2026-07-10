resource "azurerm_resource_group" "rg_main" {
  name     = "rg-main-${local.prefix}"
  location = var.location

  lifecycle {
    prevent_destroy = true
  }
}

module "networking" {
  source = "../modules/networking"

  prefix              = local.prefix
  location            = var.location
  resource_group_name = azurerm_resource_group.rg_main.name
  tags                = local.common_tags
}

module "vm" {
  source              = "../modules/vm"
  prefix              = local.prefix
  location            = var.location
  resource_group_name = azurerm_resource_group.rg_main.name
  subnet_id           = module.networking.subnet_id
  tags                = local.common_tags
}

module "key_vault" {
  source              = "../modules/key-vault"
  prefix              = local.prefix
  location            = var.location
  resource_group_name = azurerm_resource_group.rg_main.name
  tags                = local.common_tags
}

resource "azurerm_key_vault_secret" "ssh_private_key" {
  name         = "vm-ssh-private-key"
  value        = module.vm.private_key_pem
  key_vault_id = module.key_vault.key_vault_id

  lifecycle {
    prevent_destroy = true
  }
}

module "automation" {
  source              = "../modules/automation"
  prefix              = local.prefix
  location            = var.location
  resource_group_name = azurerm_resource_group.rg_main.name
  tags                = local.common_tags
  vm_name             = module.vm.vm_name
}
