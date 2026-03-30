locals {
  webapp_metric_namespace = "Microsoft.Web/sites"
  plan_metric_namespace   = "Microsoft.Web/serverFarms"
  alert_action_group_ids  = length(azurerm_monitor_action_group.webapp) == 0 ? [] : [azurerm_monitor_action_group.webapp[0].id]
}

# ---------------------------------------------------------------------------
# Shared Log Analytics Workspace (hub-owned)
# ---------------------------------------------------------------------------
data "azurerm_log_analytics_workspace" "hub" {
  name                = var.log_analytics_workspace_name
  resource_group_name = var.hub_resource_group_name
}

# ---------------------------------------------------------------------------
# Diagnostic settings — web app (all log categories + AllMetrics)
# ---------------------------------------------------------------------------
resource "azurerm_monitor_diagnostic_setting" "webapp" {
  name                       = "${var.app_name}-diag"
  target_resource_id         = azurerm_linux_web_app.this.id
  log_analytics_workspace_id = data.azurerm_log_analytics_workspace.hub.id

  enabled_log { category = "AppServiceHTTPLogs" }
  enabled_log { category = "AppServiceConsoleLogs" }
  enabled_log { category = "AppServiceAppLogs" }
  enabled_log { category = "AppServiceAuditLogs" }
  enabled_log { category = "AppServiceIPSecAuditLogs" }
  enabled_log { category = "AppServiceAuthenticationLogs" }
  enabled_log { category = "AppServicePlatformLogs" }

  enabled_metric { category = "AllMetrics" }
}

# ---------------------------------------------------------------------------
# Diagnostic settings — service plan (AllMetrics)
# ---------------------------------------------------------------------------
resource "azurerm_monitor_diagnostic_setting" "service_plan" {
  name                       = "${var.app_name}-plan-diag"
  target_resource_id         = azurerm_service_plan.this.id
  log_analytics_workspace_id = data.azurerm_log_analytics_workspace.hub.id

  enabled_metric { category = "AllMetrics" }
}

# ---------------------------------------------------------------------------
# Action group (optional email receivers)
# ---------------------------------------------------------------------------
resource "azurerm_monitor_action_group" "webapp" {
  count               = length(var.alert_email_receivers) > 0 ? 1 : 0
  name                = "${var.app_name}-alerts"
  resource_group_name = var.resource_group_name
  short_name          = "mcpalerts"
  enabled             = var.alerts_enabled

  dynamic "email_receiver" {
    for_each = { for r in var.alert_email_receivers : r.name => r }
    content {
      name                    = email_receiver.value.name
      email_address           = email_receiver.value.email_address
      use_common_alert_schema = true
    }
  }
}

# ---------------------------------------------------------------------------
# Web app metric alerts
# ---------------------------------------------------------------------------

resource "azurerm_monitor_metric_alert" "http_5xx" {
  name                = "${var.app_name}-http-5xx"
  resource_group_name = var.resource_group_name
  scopes              = [azurerm_linux_web_app.this.id]
  description         = "Alert when HTTP 5xx server errors exceed threshold."
  enabled             = var.alerts_enabled
  frequency           = "PT1M"
  severity            = 1
  window_size         = "PT5M"

  criteria {
    metric_namespace = local.webapp_metric_namespace
    metric_name      = "Http5xx"
    aggregation      = "Total"
    operator         = "GreaterThan"
    threshold        = var.http_5xx_threshold
  }

  dynamic "action" {
    for_each = toset(local.alert_action_group_ids)
    content { action_group_id = action.value }
  }
}

resource "azurerm_monitor_metric_alert" "http_4xx" {
  name                = "${var.app_name}-http-4xx"
  resource_group_name = var.resource_group_name
  scopes              = [azurerm_linux_web_app.this.id]
  description         = "Alert when HTTP 4xx client errors exceed threshold."
  enabled             = var.alerts_enabled
  frequency           = "PT5M"
  severity            = 2
  window_size         = "PT5M"

  criteria {
    metric_namespace = local.webapp_metric_namespace
    metric_name      = "Http4xx"
    aggregation      = "Total"
    operator         = "GreaterThan"
    threshold        = var.http_4xx_threshold
  }

  dynamic "action" {
    for_each = toset(local.alert_action_group_ids)
    content { action_group_id = action.value }
  }
}

resource "azurerm_monitor_metric_alert" "response_time" {
  name                = "${var.app_name}-response-time"
  resource_group_name = var.resource_group_name
  scopes              = [azurerm_linux_web_app.this.id]
  description         = "Alert when average HTTP response time exceeds threshold."
  enabled             = var.alerts_enabled
  frequency           = "PT1M"
  severity            = 2
  window_size         = "PT5M"

  criteria {
    metric_namespace = local.webapp_metric_namespace
    metric_name      = "AverageResponseTime"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = var.response_time_threshold_seconds
  }

  dynamic "action" {
    for_each = toset(local.alert_action_group_ids)
    content { action_group_id = action.value }
  }
}


resource "azurerm_monitor_metric_alert" "health_check" {
  name                = "${var.app_name}-health-check"
  resource_group_name = var.resource_group_name
  scopes              = [azurerm_linux_web_app.this.id]
  description         = "Alert when the App Service health check reports unhealthy."
  enabled             = var.alerts_enabled
  frequency           = "PT1M"
  severity            = 1
  window_size         = "PT5M"

  criteria {
    metric_namespace = local.webapp_metric_namespace
    metric_name      = "HealthCheckStatus"
    aggregation      = "Average"
    operator         = "LessThan"
    threshold        = 100
  }

  dynamic "action" {
    for_each = toset(local.alert_action_group_ids)
    content { action_group_id = action.value }
  }
}

resource "azurerm_monitor_metric_alert" "memory_working_set" {
  name                = "${var.app_name}-memory"
  resource_group_name = var.resource_group_name
  scopes              = [azurerm_linux_web_app.this.id]
  description         = "Alert when app memory working set exceeds threshold."
  enabled             = var.alerts_enabled
  frequency           = "PT5M"
  severity            = 2
  window_size         = "PT5M"

  criteria {
    metric_namespace = local.webapp_metric_namespace
    metric_name      = "MemoryWorkingSet"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = var.memory_working_set_threshold_bytes
  }

  dynamic "action" {
    for_each = toset(local.alert_action_group_ids)
    content { action_group_id = action.value }
  }
}

# ---------------------------------------------------------------------------
# Service plan metric alerts
# ---------------------------------------------------------------------------

resource "azurerm_monitor_metric_alert" "plan_cpu" {
  name                = "${var.app_name}-plan-cpu"
  resource_group_name = var.resource_group_name
  scopes              = [azurerm_service_plan.this.id]
  description         = "Alert when App Service Plan CPU percentage exceeds threshold."
  enabled             = var.alerts_enabled
  frequency           = "PT1M"
  severity            = 2
  window_size         = "PT5M"

  criteria {
    metric_namespace = local.plan_metric_namespace
    metric_name      = "CpuPercentage"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = var.plan_cpu_percentage_threshold

    dimension {
      name     = "Instance"
      operator = "Include"
      values   = ["*"]
    }
  }

  dynamic "action" {
    for_each = toset(local.alert_action_group_ids)
    content { action_group_id = action.value }
  }
}

resource "azurerm_monitor_metric_alert" "plan_memory" {
  name                = "${var.app_name}-plan-memory"
  resource_group_name = var.resource_group_name
  scopes              = [azurerm_service_plan.this.id]
  description         = "Alert when App Service Plan memory percentage exceeds threshold."
  enabled             = var.alerts_enabled
  frequency           = "PT5M"
  severity            = 2
  window_size         = "PT5M"

  criteria {
    metric_namespace = local.plan_metric_namespace
    metric_name      = "MemoryPercentage"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = var.plan_memory_percentage_threshold

    dimension {
      name     = "Instance"
      operator = "Include"
      values   = ["*"]
    }
  }

  dynamic "action" {
    for_each = toset(local.alert_action_group_ids)
    content { action_group_id = action.value }
  }
}

resource "azurerm_monitor_metric_alert" "plan_http_queue" {
  name                = "${var.app_name}-plan-http-queue"
  resource_group_name = var.resource_group_name
  scopes              = [azurerm_service_plan.this.id]
  description         = "Alert when the HTTP request queue for the App Service Plan exceeds threshold."
  enabled             = var.alerts_enabled
  frequency           = "PT1M"
  severity            = 2
  window_size         = "PT5M"

  criteria {
    metric_namespace = local.plan_metric_namespace
    metric_name      = "HttpQueueLength"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = var.plan_http_queue_threshold

    dimension {
      name     = "Instance"
      operator = "Include"
      values   = ["*"]
    }
  }

  dynamic "action" {
    for_each = toset(local.alert_action_group_ids)
    content { action_group_id = action.value }
  }
}

resource "azurerm_monitor_metric_alert" "plan_disk_queue" {
  name                = "${var.app_name}-plan-disk-queue"
  resource_group_name = var.resource_group_name
  scopes              = [azurerm_service_plan.this.id]
  description         = "Alert when the disk queue length for the App Service Plan exceeds threshold."
  enabled             = var.alerts_enabled
  frequency           = "PT5M"
  severity            = 3
  window_size         = "PT5M"

  criteria {
    metric_namespace = local.plan_metric_namespace
    metric_name      = "DiskQueueLength"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = var.plan_disk_queue_threshold

    dimension {
      name     = "Instance"
      operator = "Include"
      values   = ["*"]
    }
  }

  dynamic "action" {
    for_each = toset(local.alert_action_group_ids)
    content { action_group_id = action.value }
  }
}
