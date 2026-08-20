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
`Microsoft.ContainerService/managedClusters`. Required for AKS Automatic on a bring-your-own network.
DESCRIPTION
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
System node pool of the cluster. Ignored for AKS Automatic clusters apart from `name` and
`node_count`, because Automatic manages its own node pools through node auto-provisioning.
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

variable "network_profile" {
  type = object({
    network_plugin      = optional(string)
    network_plugin_mode = optional(string)
    network_policy      = optional(string)
    network_dataplane   = optional(string)
    load_balancer_sku   = optional(string)
    outbound_type       = optional(string)
    pod_cidr            = optional(string)
    service_cidr        = optional(string)
    dns_service_ip      = optional(string)
  })
  default     = {}
  description = <<DESCRIPTION
Cluster network configuration. `service_cidr`, `pod_cidr` and `dns_service_ip` are cluster-internal
ranges and must not overlap with the address space of the existing virtual network.
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

variable "system_node_subnet_name" {
  type        = string
  default     = null
  description = <<DESCRIPTION
Name of the existing subnet used by the hosted system components of an AKS Automatic cluster.
Required for AKS Automatic on a bring-your-own network, ignored otherwise.
DESCRIPTION
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Tags applied to the cluster and to the cluster identity."
  nullable    = false
}

variable "virtual_network_resource_group_name" {
  type        = string
  default     = null
  description = "Resource group of the existing virtual network. Defaults to `resource_group_name`."
}
