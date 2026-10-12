variable "subscription_id" {
  description = "Azure subscription ID to deploy into."
  type        = string
}

variable "location" {
  description = "Azure region for all resources."
  type        = string
  default     = "canadacentral"
}

variable "project_name" {
  description = "Short prefix for resource names (3-10 lowercase letters or numbers)."
  type        = string
  default     = "cloudops"

  validation {
    condition     = can(regex("^[a-z0-9]{3,10}$", var.project_name))
    error_message = "project_name must be 3-10 lowercase letters or numbers."
  }
}

variable "client_ip" {
  description = "Your public IPv4 address. Used in the NSG rule and (phase 2) the Synapse firewall."
  type        = string

  validation {
    condition     = can(cidrhost("${var.client_ip}/32", 0))
    error_message = "client_ip must be a single IPv4 address, for example 203.0.113.10."
  }
}

variable "vnet_address_space" {
  description = "Address space for the virtual network."
  type        = string
  default     = "10.20.0.0/16"
}

variable "subnet_prefix" {
  description = "Address prefix for the workload subnet."
  type        = string
  default     = "10.20.1.0/24"
}

variable "log_retention_days" {
  description = "Log Analytics retention in days."
  type        = number
  default     = 30
}

# ---------------------------------------------------------------------------
# Phase 2 switch: set to true to add the Synapse workspace and sample data.
# ---------------------------------------------------------------------------
variable "enable_synapse" {
  description = "Phase 2: deploy the Synapse workspace (serverless SQL only)."
  type        = bool
  default     = false
}

variable "sql_admin_login" {
  description = "SQL administrator login for the Synapse workspace (phase 2)."
  type        = string
  default     = "sqladminuser"
}

variable "tags" {
  description = "Standard tags applied to every resource."
  type        = map(string)
  default = {
    project     = "cloud-operations-monitoring-lab"
    environment = "lab"
    owner       = "hongyi-chen"
    managed_by  = "terraform"
  }
}
