variable "location" {
  type        = string
  description = "Azure region of the cluster. Must match the region of the existing virtual network."
  nullable    = false

  validation {
    condition     = length(trimspace(var.location)) > 0
    error_message = "location must not be empty."
  }
}

variable "name" {
  type        = string
  description = "Name of the AKS cluster."
  nullable    = false

  validation {
    condition     = can(regex("^[a-zA-Z0-9][a-zA-Z0-9_-]{0,61}[a-zA-Z0-9]$", var.name))
    error_message = "name must be 2 to 63 characters of letters, digits, underscores and hyphens, starting and ending with a letter or digit."
  }
}

variable "node_subnet_name" {
  type        = string
  description = "Name of the existing subnet the cluster nodes are placed in."
  nullable    = false

  validation {
    condition     = length(trimspace(var.node_subnet_name)) > 0
    error_message = "node_subnet_name must not be empty."
  }
}

variable "resource_group_name" {
  type        = string
  description = "Name of the existing resource group the cluster is deployed into."
  nullable    = false

  validation {
    condition     = length(trimspace(var.resource_group_name)) > 0
    error_message = "resource_group_name must not be empty."
  }
}

variable "virtual_network_name" {
  type        = string
  description = "Name of the existing virtual network the cluster is attached to."
  nullable    = false

  validation {
    condition     = length(trimspace(var.virtual_network_name)) > 0
    error_message = "virtual_network_name must not be empty."
  }
}

variable "api_server_authorized_ip_ranges" {
  type        = list(string)
  default     = []
  description = <<DESCRIPTION
CIDR ranges allowed to reach the API server. Only meaningful for a public cluster
(`private_cluster_enabled = false`); an empty list leaves the API server open to the internet.
DESCRIPTION
  nullable    = false

  validation {
    condition     = alltrue([for range in var.api_server_authorized_ip_ranges : can(cidrhost(range, 0))])
    error_message = "api_server_authorized_ip_ranges must contain CIDR ranges, for example \"203.0.113.0/24\"."
  }
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

variable "auto_upgrade" {
  type = object({
    kubernetes_channel = optional(string, "stable")
    node_os_channel    = optional(string, "NodeImage")
  })
  default     = {}
  description = <<DESCRIPTION
How the cluster upgrades itself. Both run inside the `maintenance_window`.

- `kubernetes_channel` - Kubernetes version upgrades. `stable` follows the second newest minor
  version AKS offers, `rapid` the newest, `patch` stays on the current minor version and takes its
  patches, `node-image` upgrades only the node image, and `none` leaves every upgrade to you.
- `node_os_channel` - Node OS patching. `NodeImage` rolls the nodes onto the weekly AKS node image,
  `SecurityPatch` applies security updates to the running image between those, `None` and
  `Unmanaged` leave the OS to you and to the distribution respectively.
DESCRIPTION
  nullable    = false

  validation {
    condition     = contains(["node-image", "none", "patch", "rapid", "stable"], var.auto_upgrade.kubernetes_channel)
    error_message = "auto_upgrade.kubernetes_channel must be one of \"none\", \"patch\", \"stable\", \"rapid\" or \"node-image\"."
  }
  validation {
    condition     = contains(["NodeImage", "None", "SecurityPatch", "Unmanaged"], var.auto_upgrade.node_os_channel)
    error_message = "auto_upgrade.node_os_channel must be one of \"NodeImage\", \"SecurityPatch\", \"None\" or \"Unmanaged\"."
  }
  # A pinned version and a channel that moves past it fight each other: AKS upgrades the cluster,
  # Terraform writes the pinned version back, and Azure refuses the downgrade.
  validation {
    condition = var.kubernetes_version == null || contains(
      length(split(".", coalesce(var.kubernetes_version, "0.0"))) > 2 ? ["node-image", "none"] : ["node-image", "none", "patch"],
      var.auto_upgrade.kubernetes_channel
    )
    error_message = "A pinned kubernetes_version needs auto_upgrade.kubernetes_channel to be \"none\" or \"node-image\", or \"patch\" when only the minor version is pinned. Any other channel upgrades the cluster past the pin, and Terraform cannot put it back."
  }
}

variable "azure_policy_enabled" {
  type        = bool
  default     = true
  description = <<DESCRIPTION
Whether to install the Azure Policy add-on, which enforces Azure Policy definitions inside the
cluster through Gatekeeper. AKS Automatic always runs it, so this is ignored for that SKU.
DESCRIPTION
  nullable    = false
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

    max_surge                  = optional(string, "10%")
    drain_timeout_minutes      = optional(number)
    node_soak_duration_minutes = optional(number)
  })
  default     = {}
  description = <<DESCRIPTION
System node pool of the cluster. An AKS Automatic cluster keeps only `name` and `node_count` and
provisions nodes on demand from there on, so the rest is dropped for that SKU.

The last three govern how the pool is rolled during an upgrade:

- `max_surge` - Extra capacity added while upgrading, as a node count or a percentage of the pool.
  AKS itself defaults to a single node, which upgrades a large pool one node at a time.
- `drain_timeout_minutes` - How long to wait for a node to drain before moving on. Defaults to the
  AKS default of 30 minutes. A pod with a restrictive disruption budget can hold a node here.
- `node_soak_duration_minutes` - How long to wait after a node comes back before draining the next
  one. Defaults to the AKS default of no wait.
DESCRIPTION
  nullable    = false

  validation {
    condition     = can(regex("^[a-z][a-z0-9]{0,11}$", var.default_node_pool.name))
    error_message = "default_node_pool.name must be 1 to 12 lowercase letters and digits, starting with a letter."
  }
  validation {
    condition     = var.default_node_pool.node_count >= 1
    error_message = "default_node_pool.node_count must be at least 1. A system pool cannot be empty."
  }
  validation {
    condition     = !var.default_node_pool.enable_auto_scaling || var.default_node_pool.min_count <= var.default_node_pool.max_count
    error_message = "default_node_pool.min_count must not exceed default_node_pool.max_count."
  }
  validation {
    condition     = !var.default_node_pool.enable_auto_scaling || (var.default_node_pool.node_count >= var.default_node_pool.min_count && var.default_node_pool.node_count <= var.default_node_pool.max_count)
    error_message = "default_node_pool.node_count must be between min_count and max_count while autoscaling is enabled."
  }
  validation {
    condition     = var.default_node_pool.os_disk_size_gb == null || try(var.default_node_pool.os_disk_size_gb >= 30, false)
    error_message = "default_node_pool.os_disk_size_gb must be at least 30."
  }
  validation {
    condition     = var.default_node_pool.max_pods == null || try(var.default_node_pool.max_pods >= 10, false)
    error_message = "default_node_pool.max_pods must be at least 10."
  }
  validation {
    condition     = can(regex("^[1-9][0-9]*%?$", var.default_node_pool.max_surge))
    error_message = "default_node_pool.max_surge must be a node count or a percentage, for example \"2\" or \"10%\"."
  }
  validation {
    condition     = var.default_node_pool.drain_timeout_minutes == null || try(var.default_node_pool.drain_timeout_minutes >= 1 && var.default_node_pool.drain_timeout_minutes <= 1440, false)
    error_message = "default_node_pool.drain_timeout_minutes must be between 1 and 1440."
  }
  validation {
    condition     = var.default_node_pool.node_soak_duration_minutes == null || try(var.default_node_pool.node_soak_duration_minutes >= 0 && var.default_node_pool.node_soak_duration_minutes <= 30, false)
    error_message = "default_node_pool.node_soak_duration_minutes must be between 0 and 30."
  }
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

  validation {
    condition     = alltrue([for id in var.entra_admin_group_object_ids : can(regex("^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$", id))])
    error_message = "entra_admin_group_object_ids must contain group object IDs as GUIDs, not group names."
  }
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

  validation {
    condition     = var.kubernetes_version == null || can(regex("^[0-9]+\\.[0-9]+(\\.[0-9]+)?$", var.kubernetes_version))
    error_message = "kubernetes_version must be of the form 1.32 or 1.32.4, without a leading \"v\"."
  }
}

variable "lock_kind" {
  type        = string
  default     = null
  description = <<DESCRIPTION
Management lock placed on the cluster, or null for none.

- `CanNotDelete` - The cluster cannot be deleted, by Terraform or from the portal, until the lock is
  removed. Worth having on anything that would take an outage to rebuild.
- `ReadOnly` - Nothing about the cluster can be changed either. This also blocks the upgrades AKS
  runs on its own, so it is rarely what you want.
DESCRIPTION

  validation {
    condition     = var.lock_kind == null || contains(["CanNotDelete", "ReadOnly"], coalesce(var.lock_kind, ""))
    error_message = "lock_kind must be either \"CanNotDelete\" or \"ReadOnly\", or left unset."
  }
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

  validation {
    condition     = contains(["azure", "kubenet", "none"], var.network_profile.network_plugin)
    error_message = "network_profile.network_plugin must be one of \"azure\", \"kubenet\" or \"none\"."
  }
  validation {
    condition     = contains(["azure", "calico", "cilium", "none"], var.network_profile.network_policy)
    error_message = "network_profile.network_policy must be one of \"azure\", \"calico\", \"cilium\" or \"none\"."
  }
  validation {
    condition     = contains(["azure", "cilium"], var.network_profile.network_dataplane)
    error_message = "network_profile.network_dataplane must be either \"azure\" or \"cilium\"."
  }
  validation {
    condition     = var.network_profile.network_policy != "cilium" || var.network_profile.network_dataplane == "cilium"
    error_message = "network_profile.network_policy = \"cilium\" requires network_dataplane = \"cilium\"."
  }
  validation {
    condition     = contains(["loadBalancer", "managedNATGateway", "userAssignedNATGateway", "userDefinedRouting"], var.network_profile.outbound_type)
    error_message = "network_profile.outbound_type must be one of \"loadBalancer\", \"managedNATGateway\", \"userAssignedNATGateway\" or \"userDefinedRouting\"."
  }
  validation {
    condition     = var.network_profile.load_balancer_sku == null || contains(["basic", "standard"], coalesce(var.network_profile.load_balancer_sku, "standard"))
    error_message = "network_profile.load_balancer_sku must be either \"basic\" or \"standard\"."
  }
  validation {
    condition     = alltrue([for cidr in [var.network_profile.pod_cidr, var.network_profile.service_cidr] : can(cidrhost(cidr, 0))])
    error_message = "network_profile.pod_cidr and network_profile.service_cidr must be CIDR ranges, for example \"100.202.0.0/16\"."
  }
  validation {
    condition     = can(cidrhost("${var.network_profile.dns_service_ip}/32", 0))
    error_message = "network_profile.dns_service_ip must be an IPv4 address."
  }
  validation {
    condition = try(
      cidrhost("${var.network_profile.dns_service_ip}/${split("/", var.network_profile.service_cidr)[1]}", 0) == cidrhost(var.network_profile.service_cidr, 0),
      false
    )
    error_message = "network_profile.dns_service_ip must fall inside network_profile.service_cidr."
  }
  validation {
    condition     = try(cidrhost(var.network_profile.pod_cidr, 0) != cidrhost(var.network_profile.service_cidr, 0), false)
    error_message = "network_profile.pod_cidr and network_profile.service_cidr must not be the same range."
  }
}

variable "network_role_assignment_scope" {
  type        = string
  default     = "subnet"
  description = <<DESCRIPTION
Scope of the `Network Contributor` assignment the cluster identity gets on the existing network.

- `subnet` - One assignment per subnet the cluster actually uses. This is the least privilege that
  AKS documents for a bring-your-own network, and the default.
- `virtual_network` - A single assignment on the whole virtual network. Needed only when the cluster
  has to reach network resources outside its own subnets.

Ignored when `create_role_assignments = false`.
DESCRIPTION
  nullable    = false

  validation {
    condition     = contains(["subnet", "virtual_network"], var.network_role_assignment_scope)
    error_message = "network_role_assignment_scope must be either \"subnet\" or \"virtual_network\"."
  }
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

  validation {
    condition     = var.private_dns_zone_name == null || can(regex("\\.azmk8s\\.io$", coalesce(var.private_dns_zone_name, "")))
    error_message = "private_dns_zone_name must end in .azmk8s.io, for example \"privatelink.swedencentral.azmk8s.io\"."
  }
}

variable "private_dns_zone_resource_group_name" {
  type        = string
  default     = null
  description = "Resource group of the existing private DNS zone. Defaults to `resource_group_name`."
}

variable "role_assignment_propagation_delay" {
  type        = string
  default     = "60s"
  description = <<DESCRIPTION
How long to wait after creating the role assignments before creating the cluster. Azure RBAC is
eventually consistent, so a cluster created the moment the assignment returns is regularly refused
access to the subnet it is supposed to join. Set to `"0s"` to skip the wait, for example when the
assignments already existed. Ignored when `create_role_assignments = false`.
DESCRIPTION
  nullable    = false

  validation {
    condition     = can(regex("^[0-9]+(ms|s|m|h)$", var.role_assignment_propagation_delay))
    error_message = "role_assignment_propagation_delay must be a duration such as \"60s\" or \"2m\"."
  }
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

  validation {
    condition     = var.subscription_id == null || can(regex("^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$", coalesce(var.subscription_id, "")))
    error_message = "subscription_id must be a GUID."
  }
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
