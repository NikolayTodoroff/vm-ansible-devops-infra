resource "azurerm_network_security_group" "main" {
  name                = "nsg-${var.prefix}"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

# HTTP (80) is static — the nginx static site is meant to be publicly viewable.
# SSH (22) is intentionally absent: the pipeline opens it to the agent's IP at
# runtime (inside the Ansible stage) and removes it under always(). Inbound from
# the internet is otherwise blocked by the default DenyAllInBound rule (65500).
resource "azurerm_network_security_rule" "allow_http" {
  name                        = "AllowHTTPInbound"
  priority                    = 200
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "80"
  source_address_prefix       = "Internet"
  destination_address_prefix  = "*"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.main.name
}

resource "azurerm_subnet_network_security_group_association" "main" {
  subnet_id                 = azurerm_subnet.main.id
  network_security_group_id = azurerm_network_security_group.main.id
}