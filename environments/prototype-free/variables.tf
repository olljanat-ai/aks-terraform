variable "location" {
  type        = string
  description = "Azure region of the cluster. Must match the region of the existing virtual network."
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
  description = "CIDR ranges allowed to reach a public API server. Ignored while the cluster is private."
  nullable    = false
}

variable "cluster_name" {
  type        = string
  default     = "aks-prototype-free"
  description = "Name of the AKS cluster."
  nullable    = false
}

variable "dns_service_ip" {
  type        = string
  default     = "10.100.0.10"
  description = "Address of the in-cluster DNS service. Must sit inside `service_cidr`."
  nullable    = false
}

variable "entra_admin_group_object_ids" {
  type        = list(string)
  default     = []
  description = "Object IDs of the Microsoft Entra ID groups granted cluster admin."
  nullable    = false
}

variable "kubernetes_version" {
  type        = string
  default     = null
  description = "Kubernetes minor version, for example `1.32`. Defaults to the AKS default version."
}

variable "node_pool" {
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
  description = "System node pool of the cluster."
  nullable    = false
}

variable "outbound_type" {
  type        = string
  default     = "loadBalancer"
  description = <<DESCRIPTION
How the cluster reaches the internet. Use `userDefinedRouting` when the existing subnet routes
egress through a firewall, which also avoids creating a public load balancer.
DESCRIPTION
  nullable    = false
}

variable "pod_cidr" {
  type        = string
  default     = "100.64.0.0/16"
  description = "Address range for pods. Overlay pod addresses stay inside the cluster."
  nullable    = false
}

variable "private_cluster_enabled" {
  type        = bool
  default     = true
  description = "Whether the API server is reachable only over a private endpoint. Set to `false` for a public cluster."
  nullable    = false
}

variable "private_dns_zone_name" {
  type        = string
  default     = null
  description = <<DESCRIPTION
Name of the existing private DNS zone for the API server, for example
`privatelink.swedencentral.azmk8s.io`. Required while the cluster is private.
DESCRIPTION
}

variable "private_dns_zone_resource_group_name" {
  type        = string
  default     = null
  description = "Resource group of the existing private DNS zone. Defaults to `resource_group_name`."
}

variable "service_cidr" {
  type        = string
  default     = "10.100.0.0/16"
  description = "Address range for Kubernetes services. Must not overlap with the existing virtual network."
  nullable    = false
}

variable "subscription_id" {
  type        = string
  default     = null
  description = "Target subscription. Falls back to `ARM_SUBSCRIPTION_ID` or the current Azure CLI subscription."
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
