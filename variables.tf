variable "location" {
  type        = string
  description = "Azure region of the cluster. Must match the region of the existing virtual network."
  nullable    = false
}

variable "name" {
  type        = string
  description = "Name of the AKS cluster."
  nullable    = false
}

variable "node_subnet_name" {
  type        = string
  description = "Name of the existing subnet the cluster nodes are placed in."
  nullable    = false
}

variable "resource_group_name" {
  type        = string
  description = "Name of the existing resource group the cluster is deployed into."
  nullable    = false
}

variable "virtual_network_name" {
  type        = string
  description = "Name of the existing virtual network the cluster is attached to."
  nullable    = false
}

variable "api_server_authorized_ip_ranges" {
  type        = list(string)
  default     = []
  description = <<DESCRIPTION
CIDR ranges allowed to reach the API server. Only meaningful for a public cluster
(`private_cluster_enabled = false`); an empty list leaves the API server open to the internet.
DESCRIPTION
  nullable    = false
}

variable "api_server_subnet_name" {
  type        = string
  default     = null
  description = <<DESCRIPTION
Name of the existing subnet used for API Server VNet Integration. The subnet must be delegated to
`Microsoft.ContainerService/managedClusters`. Required for AKS Automatic.
DESCRIPTION

  validation {
    condition     = var.sku_name != "Automatic" || var.api_server_subnet_name != null
    error_message = "AKS Automatic on an existing network requires api_server_subnet_name."
  }
}

variable "create_role_assignments" {
  type        = bool
  default     = true
  description = <<DESCRIPTION
Create the role assignments the cluster identity needs on the existing network and private DNS zone.
Set to `false` when the assignments are managed elsewhere - the deployment then requires no
`Microsoft.Authorization/roleAssignments/write` permission.
DESCRIPTION
  nullable    = false
}

variable "default_node_pool" {
  type = object({
    name                = optional(string, "systempool")
    vm_size             = optional(string, "Standard_D4ds_v5")
    node_count          = optional(number, 2)
    enable_auto_scaling = optional(bool, true)
    min_count           = optional(number, 2)
    max_count           = optional(number, 4)
    max_pods            = optional(number)
    os_disk_size_gb     = optional(number)
    availability_zones  = optional(list(string))
  })
  default     = {}
  description = <<DESCRIPTION
System node pool of the cluster. An AKS Automatic cluster keeps only `name` and `node_count` and
provisions nodes on demand from there on, so the rest is dropped for that SKU.
DESCRIPTION
  nullable    = false
}

variable "enable_telemetry" {
  type        = bool
  default     = true
  description = "Whether to send the anonymous telemetry that Azure Verified Modules collect."
  nullable    = false
}

variable "entra_admin_group_object_ids" {
  type        = list(string)
  default     = []
  description = "Object IDs of the Microsoft Entra ID groups granted cluster admin."
  nullable    = false
}

variable "fqdn_subdomain" {
  type        = string
  default     = null
  description = <<DESCRIPTION
Subdomain registered in the bring-your-own private DNS zone. Azure requires it whenever a custom
private DNS zone is used, so it defaults to the cluster name in that case.
DESCRIPTION
}

variable "kubernetes_version" {
  type        = string
  default     = null
  description = "Kubernetes minor version, for example `1.32`. Defaults to the AKS default version."
}

variable "maintenance_window" {
  type = object({
    day_of_week    = optional(string, "Tuesday")
    start_time     = optional(string, "22:00")
    duration_hours = optional(number, 8)
    interval_weeks = optional(number, 1)
    utc_offset     = optional(string, "+00:00")
  })
  default     = {}
  description = <<DESCRIPTION
Weekly window the cluster is allowed to upgrade itself in. Defaults to the night between Tuesday and
Wednesday, 22:00 - 06:00 UTC. A window that runs past midnight simply continues into the next day.

- `day_of_week` - Day the window opens on, `Monday` through `Sunday`.
- `start_time` - Time the window opens as `HH:MM`, in the time zone given by `utc_offset`.
- `duration_hours` - Length of the window. Azure allows 4 to 24 hours, and needs at least 4 for an
  upgrade to be attempted at all.
- `interval_weeks` - Weeks between windows. `1` opens one every week.
- `utc_offset` - Time zone of `start_time` as `+/-HH:MM`, for example `+03:00` for Finnish summer
  time. Note that Azure does not follow daylight saving time, so a fixed offset shifts by an hour
  relative to local time for part of the year.
DESCRIPTION
  nullable    = false

  validation {
    condition     = contains(["Friday", "Monday", "Saturday", "Sunday", "Thursday", "Tuesday", "Wednesday"], var.maintenance_window.day_of_week)
    error_message = "maintenance_window.day_of_week must be an English weekday name, for example \"Tuesday\"."
  }
  validation {
    condition     = can(regex("^([01][0-9]|2[0-3]):[0-5][0-9]$", var.maintenance_window.start_time))
    error_message = "maintenance_window.start_time must be of the form HH:MM, between \"00:00\" and \"23:59\"."
  }
  validation {
    condition     = var.maintenance_window.duration_hours >= 4 && var.maintenance_window.duration_hours <= 24
    error_message = "maintenance_window.duration_hours must be between 4 and 24."
  }
  validation {
    condition     = var.maintenance_window.interval_weeks >= 1
    error_message = "maintenance_window.interval_weeks must be at least 1."
  }
  validation {
    condition     = can(regex("^[-+][0-9]{2}:[0-9]{2}$", var.maintenance_window.utc_offset))
    error_message = "maintenance_window.utc_offset must be of the form +HH:MM or -HH:MM."
  }
}

variable "network_profile" {
  type = object({
    network_plugin      = optional(string, "azure")
    network_plugin_mode = optional(string, "overlay")
    network_policy      = optional(string, "cilium")
    network_dataplane   = optional(string, "cilium")
    load_balancer_sku   = optional(string)
    outbound_type       = optional(string, "loadBalancer")
    pod_cidr            = optional(string, "100.201.0.0/16")
    service_cidr        = optional(string, "100.202.0.0/16")
    dns_service_ip      = optional(string, "100.202.0.10")
  })
  default     = {}
  description = <<DESCRIPTION
Cluster network configuration. `service_cidr`, `pod_cidr` and `dns_service_ip` are cluster-internal
ranges and must not overlap with the address space of the existing virtual network. Use
`outbound_type = "userDefinedRouting"` when the existing subnet routes egress through a firewall,
which also avoids creating a public load balancer.

An AKS Automatic cluster manages its own dataplane, so only `outbound_type` survives for that SKU.
DESCRIPTION
  nullable    = false
}

variable "private_cluster_enabled" {
  type        = bool
  default     = true
  description = "Whether the API server is reachable only over a private endpoint. Set to `false` for a public cluster."
  nullable    = false
}

variable "private_cluster_public_fqdn_enabled" {
  type        = bool
  default     = false
  description = "Whether a private cluster also gets a public FQDN resolving to its private IP."
  nullable    = false
}

variable "private_dns_zone_name" {
  type        = string
  default     = null
  description = <<DESCRIPTION
Name of the existing private DNS zone for the API server, for example
`privatelink.swedencentral.azmk8s.io`. When left null a private cluster uses an AKS-managed zone.
DESCRIPTION
}

variable "private_dns_zone_resource_group_name" {
  type        = string
  default     = null
  description = "Resource group of the existing private DNS zone. Defaults to `resource_group_name`."
}

variable "sku_name" {
  type        = string
  default     = "Base"
  description = "Managed cluster SKU name. `Base` for a normal cluster, `Automatic` for AKS Automatic."
  nullable    = false

  validation {
    condition     = contains(["Automatic", "Base"], var.sku_name)
    error_message = "sku_name must be either \"Base\" or \"Automatic\"."
  }
}

variable "sku_tier" {
  type        = string
  default     = "Free"
  description = "Managed cluster SKU tier: `Free`, `Standard` or `Premium`."
  nullable    = false

  validation {
    condition     = contains(["Free", "Premium", "Standard"], var.sku_tier)
    error_message = "sku_tier must be one of \"Free\", \"Standard\" or \"Premium\"."
  }
  validation {
    condition     = var.sku_name != "Automatic" || var.sku_tier != "Free"
    error_message = "AKS Automatic clusters require the \"Standard\" or \"Premium\" tier."
  }
}

variable "subscription_id" {
  type        = string
  default     = null
  description = "Target subscription. Falls back to `ARM_SUBSCRIPTION_ID` or the current Azure CLI subscription."
}

variable "system_node_subnet_name" {
  type        = string
  default     = null
  description = <<DESCRIPTION
Name of the existing subnet used by the hosted system components of an AKS Automatic cluster.
Required for AKS Automatic, ignored otherwise.
DESCRIPTION

  validation {
    condition     = var.sku_name != "Automatic" || var.system_node_subnet_name != null
    error_message = "AKS Automatic on an existing network requires system_node_subnet_name."
  }
}

variable "virtual_network_resource_group_name" {
  type        = string
  default     = null
  description = "Resource group of the existing virtual network. Defaults to `resource_group_name`."
}
