variable "location" {
  description = "Azure region"
  type        = string
}

variable "resource_group_name" {
  description = "Resource group name"
  type        = string
}

variable "app_name" {
  description = "App Service name"
  type        = string
}

variable "service_plan_sku" {
  description = "App Service Plan SKU (must support Private Endpoints)"
  type        = string
  default     = "S1"
}

variable "hub_resource_group_name" {
  description = "Resource group containing shared hub network resources"
  type        = string
  default     = "mikeo-lab-rg"
}

variable "hub_vnet_name" {
  description = "Shared hub virtual network name"
  type        = string
  default     = "mikeo-lab-hub-vnet"
}

variable "private_dns_zone_resource_group_name" {
  description = "Resource group containing the shared private DNS zone"
  type        = string
  default     = "mikeo-lab-rg"
}

variable "private_dns_zone_name" {
  description = "Shared private DNS zone name for App Service private endpoints"
  type        = string
  default     = "privatelink.azurewebsites.net"
}

variable "vnet_address_space" {
  description = "Address space for the VNet"
  type        = list(string)
  default     = ["10.0.12.0/27"]
}

variable "private_endpoint_subnet_prefix" {
  description = "Subnet prefix for Private Endpoints"
  type        = string
  default     = "10.0.12.0/28"
}

# ---------------------------------------------------------------------------
# Monitoring
# ---------------------------------------------------------------------------

variable "log_analytics_workspace_name" {
  description = "Name of the shared Log Analytics workspace to send diagnostics to"
  type        = string
  default     = "mikeo-lab-hub-law"
}

variable "alerts_enabled" {
  description = "Whether metric alerts are enabled"
  type        = bool
  default     = true
}

variable "alert_email_receivers" {
  description = "Email recipients for metric alerts. Leave empty to create alerts without an email action group."
  type = list(object({
    name          = string
    email_address = string
  }))
  default = []
}

# Web app thresholds

variable "http_5xx_threshold" {
  description = "Total HTTP 5xx errors per 5-minute window before alerting (severity 1)"
  type        = number
  default     = 10
}

variable "http_4xx_threshold" {
  description = "Total HTTP 4xx errors per 5-minute window before alerting (severity 2)"
  type        = number
  default     = 50
}

variable "response_time_threshold_seconds" {
  description = "Average HTTP response time in seconds before alerting (severity 2)"
  type        = number
  default     = 5
}

variable "request_queue_threshold" {
  description = "Average requests queued in application pipeline before alerting (severity 2)"
  type        = number
  default     = 10
}

variable "memory_working_set_threshold_bytes" {
  description = "Average memory working set in bytes before alerting (severity 2). Default 512 MiB."
  type        = number
  default     = 536870912
}

variable "connections_threshold" {
  description = "Average open socket connections before alerting (severity 3)"
  type        = number
  default     = 200
}

# Service plan thresholds

variable "plan_cpu_percentage_threshold" {
  description = "Average CPU percentage across plan instances before alerting (severity 2)"
  type        = number
  default     = 80
}

variable "plan_memory_percentage_threshold" {
  description = "Average memory percentage across plan instances before alerting (severity 2)"
  type        = number
  default     = 80
}

variable "plan_http_queue_threshold" {
  description = "Average HTTP queue length across plan instances before alerting (severity 2)"
  type        = number
  default     = 10
}

variable "plan_disk_queue_threshold" {
  description = "Average disk queue length across plan instances before alerting (severity 3)"
  type        = number
  default     = 100
}