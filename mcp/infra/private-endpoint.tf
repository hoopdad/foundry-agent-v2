data "azurerm_private_dns_zone" "webapps" {
  name                = var.private_dns_zone_name
  resource_group_name = var.private_dns_zone_resource_group_name
}

resource "azurerm_private_dns_zone_virtual_network_link" "webapps" {
  name                  = "${var.app_name}-webapps-link"
  resource_group_name   = var.private_dns_zone_resource_group_name
  private_dns_zone_name = data.azurerm_private_dns_zone.webapps.name
  virtual_network_id    = azurerm_virtual_network.this.id
}

resource "azurerm_private_endpoint" "webapp" {
  name                = "${var.app_name}-pe"
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id            = azurerm_subnet.private_endpoint.id

  private_service_connection {
    name                           = "${var.app_name}-psc"
    private_connection_resource_id = azurerm_linux_web_app.this.id
    subresource_names              = ["sites"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "webapps"
    private_dns_zone_ids = [data.azurerm_private_dns_zone.webapps.id]
  }
}