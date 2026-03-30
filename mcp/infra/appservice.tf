resource "azurerm_service_plan" "this" {
  name                = "${var.app_name}-plan"
  location            = var.location
  resource_group_name = var.resource_group_name

  os_type  = "Linux"
  sku_name = var.service_plan_sku
}

resource "azurerm_linux_web_app" "this" {
  name                = var.app_name
  location            = var.location
  resource_group_name = var.resource_group_name
  service_plan_id     = azurerm_service_plan.this.id

  https_only                    = true
  public_network_access_enabled = false

  site_config {
    app_command_line = "gunicorn -k uvicorn.workers.UvicornWorker main:app"
  }

  app_settings = {
    SCM_DO_BUILD_DURING_DEPLOYMENT       = "true"
    WEBSITES_ENABLE_APP_SERVICE_STORAGE = "false"
  }
}