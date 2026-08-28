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
  default     = null
  description = <<DESCRIPTION
Name of the existing subnet the cluster nodes are placed in. Required together with
`virtual_network_name`, and left unset with it for a cluster that brings no network of its own.
DESCRIPTION

  validation {
    condition     = var.node_subnet_name == null || length(trimspace(coalesce(var.node_subnet_name, ""))) > 0
    error_message = "node_subnet_name must not be empty."
  }
  # The two are one decision. A subnet without its network cannot be looked up, and a network with
  # no node subnet named in it has nowhere to put the nodes.
  validation {
    condition     = (var.virtual_network_name == null) == (var.node_subnet_name == null)
    error_message = "virtual_network_name and node_subnet_name go together: name both to attach the cluster to an existing network, or leave both unset to let AKS create and manage a virtual network of its own."
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
  default     = null
  description = <<DESCRIPTION
Name of the existing virtual network the cluster is attached to, together with `node_subnet_name`.

Leave both unset for a cluster that brings no network at all: AKS then creates and manages a virtual
network for it inside the node resource group, and every bring-your-own subnet here stays empty. The
cluster is then reachable only from that network, which the node resource group lockdown makes hard
to peer or link - see the README. `envs/prototype-automatic.tfvars` is on that arrangement.
DESCRIPTION

  validation {
    condition     = var.virtual_network_name == null || length(trimspace(coalesce(var.virtual_network_name, ""))) > 0
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
`Microsoft.ContainerService/managedClusters` and be a `/28` or larger.

Leave it unset for a cluster whose API server is not joined to the network. Microsoft documents the
subnet as required for an AKS Automatic cluster in an existing virtual network, so Terraform warns
about that combination rather than refusing it - unless the integration is turned off deliberately
through `api_server_vnet_integration_enabled`, which is what `envs/prototype-automatic.tfvars` does.
DESCRIPTION

  # Naming a subnet for an API server that is not joined to the network says two different things at
  # once. Rather than quietly dropping one of them, the combination is refused.
  validation {
    condition     = var.api_server_vnet_integration_enabled || var.api_server_subnet_name == null
    error_message = "api_server_subnet_name names a subnet for an API server that is not joined to the network. Leave it unset while api_server_vnet_integration_enabled = false, or set that back to true to use the subnet."
  }
  validation {
    condition     = var.virtual_network_name != null || var.api_server_subnet_name == null
    error_message = "api_server_subnet_name names a subnet of an existing virtual network, and this cluster brings none. Name virtual_network_name and node_subnet_name as well, or leave the API server where AKS puts it."
  }
}

variable "api_server_vnet_integration_enabled" {
  type        = bool
  default     = true
  description = <<DESCRIPTION
Whether the API server may be joined to the existing virtual network. The integration only actually
happens when `api_server_subnet_name` also names a subnet to inject it into, so leaving this at its
default changes nothing on its own.

Set it to `false` to turn API Server VNet Integration off for good in an environment: naming a
subnet is then refused rather than ignored, and the warning about an AKS Automatic cluster without
one is dropped, because the absence is the point rather than an oversight. The API server is reached
over its public or AKS-managed private endpoint instead, exactly as it is on a `Base` cluster here.
DESCRIPTION
  nullable    = false
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

variable "azure_rbac_enabled" {
  type        = bool
  default     = true
  description = <<DESCRIPTION
Whether the cluster authorizes the Kubernetes API through Azure RBAC - "Microsoft Entra ID
authentication with Azure RBAC" - rather than through Kubernetes RBAC. Always on for the Automatic
SKU, which Azure preconfigures with it and does not let a cluster off.

This decides how `entra_admin_group_object_ids` and `entra_reader_group_object_ids` reach the
cluster: as Azure role assignments on it, or as the admin groups of its own Entra ID profile. See
those two.
DESCRIPTION
  nullable    = false
}

variable "cluster_timeouts" {
  type = object({
    create = optional(string, "90m")
    delete = optional(string, "90m")
    read   = optional(string, "10m")
    update = optional(string, "90m")
  })
  default     = {}
  description = <<DESCRIPTION
How long Terraform waits for a cluster operation to finish before giving up. The AzAPI provider
defaults to 30 minutes, which an AKS Automatic cluster in an existing network regularly exceeds -
the API server, the hosted system node pools and the add-ons Azure installs on its own are all
created before the request returns. Terraform then reports a timeout while Azure carries on, and the
cluster is left in `Creating` with nothing in state to reconcile it against.

Giving up early does not stop the deployment, so these are set well above what a healthy create
takes rather than close to it.
DESCRIPTION
  nullable    = false

  validation {
    condition = alltrue([for timeout in [
      var.cluster_timeouts.create,
      var.cluster_timeouts.delete,
      var.cluster_timeouts.read,
      var.cluster_timeouts.update,
    ] : can(regex("^[0-9]+(s|m|h)$", timeout))])
    error_message = "Every cluster_timeouts value must be a duration such as \"90m\" or \"2h\"."
  }
}

variable "create_role_assignments" {
  type        = bool
  default     = true
  description = <<DESCRIPTION
Create the role assignments made here: the ones the cluster identity needs on the existing network
and private DNS zone, and the ones that grant `entra_admin_group_object_ids` and
`entra_reader_group_object_ids` their access to the cluster under Azure RBAC. Set to `false` when
the assignments are managed elsewhere - the deployment then requires no
`Microsoft.Authorization/roleAssignments/write` permission, and has to be given every one of those
grants by whoever does manage them. A cluster that brings no network has no network assignments to
create either way.
DESCRIPTION
  nullable    = false
}

variable "default_node_pool" {
  type = object({
    name                = optional(string, "system")
    vm_size             = optional(string, "Standard_D4ds_v5")
    node_count          = optional(number, 1)
    enable_auto_scaling = optional(bool, false)
    min_count           = optional(number, 1)
    max_count           = optional(number, 1)
    max_pods            = optional(number)
    os_disk_size_gb     = optional(number)
    availability_zones  = optional(list(string))

    max_surge                  = optional(string, "10%")
    drain_timeout_minutes      = optional(number)
    node_soak_duration_minutes = optional(number)
  })
  default     = {}
  description = <<DESCRIPTION
System node pool of the cluster. **Ignored for AKS Automatic apart from `name`**, which sizes,
scales and rolls its own node pools - see the README for what that SKU drops.

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
  description = <<DESCRIPTION
Object IDs of the Microsoft Entra ID groups granted cluster admin. How they are granted follows
`azure_rbac_enabled`, because the two authorization modes have nothing in common:

- With Azure RBAC, each group is assigned `Azure Kubernetes Service RBAC Cluster Admin` on the
  cluster. The admin groups of the cluster's Entra ID profile are not honored in this mode, so
  nothing is sent there.
- With Kubernetes RBAC, each group becomes an admin group of the cluster's Entra ID profile, which
  binds it to `cluster-admin` inside the cluster. No role assignment is created.

Members still need `Azure Kubernetes Service Cluster User Role` on the cluster to download a
kubeconfig at all; that one is not created here.
DESCRIPTION
  nullable    = false

  validation {
    condition     = alltrue([for id in var.entra_admin_group_object_ids : can(regex("^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$", id))])
    error_message = "entra_admin_group_object_ids must contain group object IDs as GUIDs, not group names."
  }
}

variable "entra_reader_group_object_ids" {
  type        = list(string)
  default     = []
  description = <<DESCRIPTION
Object IDs of the Microsoft Entra ID groups granted read-only access to the cluster, by assigning
them `Azure Kubernetes Service RBAC Reader` on it. That role reads most objects in every namespace,
but not `Secrets` and not roles or role bindings.

Azure RBAC only. Kubernetes RBAC has no equivalent - the cluster's Entra ID profile carries admin
groups and nothing else - so these groups are granted nothing while `azure_rbac_enabled = false`.

Members still need `Azure Kubernetes Service Cluster User Role` on the cluster to download a
kubeconfig at all; that one is not created here.
DESCRIPTION
  nullable    = false

  validation {
    condition     = alltrue([for id in var.entra_reader_group_object_ids : can(regex("^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$", id))])
    error_message = "entra_reader_group_object_ids must contain group object IDs as GUIDs, not group names."
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

variable "managed_namespace_defaults" {
  type = object({
    adoption_policy = optional(string, "Never")
    annotations     = optional(map(string), {})
    delete_policy   = optional(string, "Keep")
    labels          = optional(map(string), {})
    network_policy = optional(object({
      egress  = optional(string, "AllowAll")
      ingress = optional(string, "AllowSameNamespace")
    }), {})
    resource_quota = optional(object({
      cpu_limit      = optional(string)
      cpu_request    = optional(string)
      memory_limit   = optional(string)
      memory_request = optional(string)
    }), {})
  })
  default     = {}
  description = <<DESCRIPTION
What every entry in `managed_namespaces` gets unless it says otherwise. Change it here to move a
whole cluster at once; change it on the namespace to move one.

- `network_policy.ingress` - Who may open a connection to a pod in the namespace. Defaults to
  `AllowSameNamespace`: only pods of the same namespace, which is what makes a namespace a boundary
  rather than a label. `AllowAll` lets any pod in the cluster in, `DenyAll` nothing at all - not
  even the namespace itself.
- `network_policy.egress` - Where a pod in the namespace may open a connection to. Defaults to
  `AllowAll`, so that a workload reaches the API server, DNS, the internet and the rest of the
  cluster without further ado. `AllowSameNamespace` confines it to its own namespace and `DenyAll`
  cuts it off entirely - both of which take a deliberate look at what the workload actually talks
  to before they are turned on.
- `adoption_policy` - What AKS does when a Kubernetes namespace of that name already exists.
  `Never` refuses and fails the apply, which is the default and what keeps this from taking over a
  namespace somebody else owns. `IfIdentical` adopts one whose labels and annotations already
  match, `Always` adopts and overwrites.
- `delete_policy` - What happens to the Kubernetes namespace when the managed namespace is removed
  from here. `Keep` leaves it and whatever runs in it standing, which is the default: dropping a
  line from a variables file should not delete a running workload. `Delete` removes the namespace
  with it.
- `resource_quota` - Default `ResourceQuota` for the namespace. CPU is in Kubernetes CPU units
  (`"500m"`, `"2"`), memory in the power-of-two forms (`"512Mi"`, `"4Gi"`). Left unset there is no
  quota at all, which is not the same as one that limits nothing.

The network policies are the *default* ones AKS puts in the namespace, not the only ones allowed in
it: Kubernetes network policies are additive, so a policy applied inside the namespace can only
widen what these permit, never narrow it.
DESCRIPTION
  nullable    = false

  validation {
    condition     = contains(["Always", "IfIdentical", "Never"], var.managed_namespace_defaults.adoption_policy)
    error_message = "managed_namespace_defaults.adoption_policy must be one of \"Always\", \"IfIdentical\" or \"Never\"."
  }
  validation {
    condition     = contains(["Delete", "Keep"], var.managed_namespace_defaults.delete_policy)
    error_message = "managed_namespace_defaults.delete_policy must be either \"Delete\" or \"Keep\"."
  }
  validation {
    condition = alltrue([
      for rule in [var.managed_namespace_defaults.network_policy.egress, var.managed_namespace_defaults.network_policy.ingress] :
      contains(["AllowAll", "AllowSameNamespace", "DenyAll"], rule)
    ])
    error_message = "managed_namespace_defaults.network_policy.egress and .ingress must each be one of \"AllowAll\", \"AllowSameNamespace\" or \"DenyAll\"."
  }
  validation {
    condition = alltrue([
      for quantity in [var.managed_namespace_defaults.resource_quota.cpu_limit, var.managed_namespace_defaults.resource_quota.cpu_request] :
      quantity == null || can(regex("^[0-9]+(\\.[0-9]+)?m?$", quantity))
    ])
    error_message = "managed_namespace_defaults.resource_quota.cpu_limit and .cpu_request must be Kubernetes CPU quantities, for example \"500m\" or \"2\"."
  }
  validation {
    condition = alltrue([
      for quantity in [var.managed_namespace_defaults.resource_quota.memory_limit, var.managed_namespace_defaults.resource_quota.memory_request] :
      quantity == null || can(regex("^[0-9]+(\\.[0-9]+)?(Ei|Pi|Ti|Gi|Mi|Ki|E|P|T|G|M|K)?$", quantity))
    ])
    error_message = "managed_namespace_defaults.resource_quota.memory_limit and .memory_request must be Kubernetes memory quantities, for example \"512Mi\" or \"4Gi\"."
  }
}

variable "managed_namespaces" {
  type = map(object({
    adoption_policy = optional(string)
    annotations     = optional(map(string), {})
    delete_policy   = optional(string)
    labels          = optional(map(string), {})
    network_policy = optional(object({
      egress  = optional(string)
      ingress = optional(string)
    }), {})
    resource_quota = optional(object({
      cpu_limit      = optional(string)
      cpu_request    = optional(string)
      memory_limit   = optional(string)
      memory_request = optional(string)
    }), {})
  }))
  default     = {}
  description = <<DESCRIPTION
Namespaces AKS creates and keeps inside the cluster, keyed by namespace name. Listing the names is
the whole of it - everything a namespace needs comes from `managed_namespace_defaults`, so an
environment that wants nothing special writes only this:

```hcl
managed_namespaces = {
  team-payments = {}
  team-search   = {}
}
```

Each entry may then override any of the defaults for itself, and only what it names changes:

```hcl
managed_namespaces = {
  # Reachable from the ingress controller in another namespace, so it opens ingress up.
  team-payments = {
    network_policy = { ingress = "AllowAll" }
  }
  # Batch jobs that must not reach anything outside their own namespace.
  team-search = {
    network_policy = { egress = "AllowSameNamespace" }
    resource_quota = { cpu_limit = "4", memory_limit = "8Gi" }
  }
}
```

`labels` and `annotations` are merged with the ones in `managed_namespace_defaults` key by key, so
a namespace adds to the estate-wide set rather than replacing it. Everything else is a plain
override of the default.

These are Azure resources rather than plain Kubernetes namespaces: AKS creates the namespace, the
default `NetworkPolicy` and the default `ResourceQuota` in the cluster and reconciles them, and
Azure RBAC can be scoped to the namespace. Removing an entry deletes the Azure resource; whether
the Kubernetes namespace goes with it is `delete_policy`.
DESCRIPTION
  nullable    = false

  validation {
    condition = alltrue([
      for name in keys(var.managed_namespaces) : can(regex("^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$", name))
    ])
    error_message = "Every key of managed_namespaces must be a Kubernetes namespace name: 1 to 63 characters of lowercase letters, digits and hyphens, starting and ending with a letter or digit."
  }
  # Microsoft documents system namespaces as not on-boardable at all - `kube-system`,
  # `gatekeeper-system`, `istio-system`, `app-routing-system` and the rest. The list is open-ended,
  # so this catches the named ones and the `kube-` prefix Kubernetes reserves; anything else
  # Microsoft adds to it is refused by Azure rather than here.
  validation {
    condition = alltrue([
      for name in keys(var.managed_namespaces) :
      !startswith(name, "kube-") && !contains(["app-routing-system", "gatekeeper-system", "istio-system"], name)
    ])
    error_message = "managed_namespaces names a system namespace. AKS does not allow one to be on-boarded as a managed namespace: not kube-system or anything else starting with \"kube-\", and not app-routing-system, gatekeeper-system or istio-system."
  }
  validation {
    condition = alltrue([
      for namespace in values(var.managed_namespaces) :
      namespace.adoption_policy == null || contains(["Always", "IfIdentical", "Never"], coalesce(namespace.adoption_policy, ""))
    ])
    error_message = "managed_namespaces[*].adoption_policy must be one of \"Always\", \"IfIdentical\" or \"Never\", or left unset to follow managed_namespace_defaults."
  }
  validation {
    condition = alltrue([
      for namespace in values(var.managed_namespaces) :
      namespace.delete_policy == null || contains(["Delete", "Keep"], coalesce(namespace.delete_policy, ""))
    ])
    error_message = "managed_namespaces[*].delete_policy must be either \"Delete\" or \"Keep\", or left unset to follow managed_namespace_defaults."
  }
  validation {
    condition = alltrue(flatten([
      for namespace in values(var.managed_namespaces) : [
        for rule in [namespace.network_policy.egress, namespace.network_policy.ingress] :
        rule == null || contains(["AllowAll", "AllowSameNamespace", "DenyAll"], coalesce(rule, ""))
      ]
    ]))
    error_message = "managed_namespaces[*].network_policy.egress and .ingress must each be one of \"AllowAll\", \"AllowSameNamespace\" or \"DenyAll\", or left unset to follow managed_namespace_defaults."
  }
  validation {
    condition = alltrue(flatten([
      for namespace in values(var.managed_namespaces) : [
        for quantity in [namespace.resource_quota.cpu_limit, namespace.resource_quota.cpu_request] :
        quantity == null || can(regex("^[0-9]+(\\.[0-9]+)?m?$", quantity))
      ]
    ]))
    error_message = "managed_namespaces[*].resource_quota.cpu_limit and .cpu_request must be Kubernetes CPU quantities, for example \"500m\" or \"2\"."
  }
  validation {
    condition = alltrue(flatten([
      for namespace in values(var.managed_namespaces) : [
        for quantity in [namespace.resource_quota.memory_limit, namespace.resource_quota.memory_request] :
        quantity == null || can(regex("^[0-9]+(\\.[0-9]+)?(Ei|Pi|Ti|Gi|Mi|Ki|E|P|T|G|M|K)?$", quantity))
      ]
    ]))
    error_message = "managed_namespaces[*].resource_quota.memory_limit and .memory_request must be Kubernetes memory quantities, for example \"512Mi\" or \"4Gi\"."
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
  default     = null
  description = <<DESCRIPTION
Scope of the `Network Contributor` assignment the cluster identity gets on the existing network.

- `subnet` - One assignment per subnet the cluster actually uses. This is the least privilege AKS
  documents for a bring-your-own network, and the default for a `Base` cluster.
- `virtual_network` - A single assignment on the whole virtual network. The default for AKS
  Automatic, which Microsoft documents as requiring it: node autoprovisioning creates the node pools
  itself and works at virtual network scope, not at the scope of the subnets named here. Also needed
  on a `Base` cluster that has to reach network resources outside its own subnets.

Left unset, this follows `sku_name`. Ignored when `create_role_assignments = false`, and when the
cluster brings no network for the identity to be granted anything on.
DESCRIPTION

  validation {
    condition     = var.network_role_assignment_scope == null || contains(["subnet", "virtual_network"], coalesce(var.network_role_assignment_scope, ""))
    error_message = "network_role_assignment_scope must be either \"subnet\" or \"virtual_network\", or left unset."
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
assignments already existed. Ignored when there are no assignments to wait for - either
`create_role_assignments = false`, or a cluster that brings no network.
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
Required for AKS Automatic **in an existing virtual network**, ignored otherwise - a cluster that
brings no network hosts them in the one AKS creates for it. **It must be a different subnet from
`node_subnet_name`** - Azure hosts the system components separately from the nodes and refuses a
request that names one subnet for both.
DESCRIPTION

  validation {
    condition     = var.sku_name != "Automatic" || var.virtual_network_name == null || var.system_node_subnet_name != null
    error_message = "AKS Automatic on an existing network requires system_node_subnet_name."
  }
  validation {
    condition     = var.virtual_network_name != null || var.system_node_subnet_name == null
    error_message = "system_node_subnet_name names a subnet of an existing virtual network, and this cluster brings none. AKS places the hosted system components in the network it creates for itself."
  }
  # Azure answers this one with `400 InvalidParameter: systemNodeByoSubnetId and nodeByoSubnetId
  # must be different subnets`, so there is no point sending it.
  validation {
    condition     = var.sku_name != "Automatic" || var.system_node_subnet_name == null || var.system_node_subnet_name != var.node_subnet_name
    error_message = "system_node_subnet_name must name a different subnet from node_subnet_name. AKS places the hosted system components of an Automatic cluster in their own subnet and rejects a request that gives it the node subnet."
  }
}

variable "virtual_network_resource_group_name" {
  type        = string
  default     = null
  description = "Resource group of the existing virtual network. Defaults to `resource_group_name`."
}

variable "cost_analysis_enabled" {
  type    = bool
  default = false
}
