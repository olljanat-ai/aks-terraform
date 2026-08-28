locals {
  # API version of the AKS resource provider used by the resources written directly rather than
  # through the module. One place to bump, so that the two cannot drift apart.
  aks_api_version = "2026-03-01"

  # Authorized IP ranges only apply to a public API server; an empty list means "no restriction".
  api_server_authorized_ip_ranges = var.private_cluster_enabled || length(var.api_server_authorized_ip_ranges) == 0 ? null : var.api_server_authorized_ip_ranges

  # Whether the cluster is attached to a network that already exists. Without one, AKS creates and
  # manages a virtual network for it inside the node resource group: no subnet is looked up, there
  # is nothing to grant the cluster identity, and every bring-your-own network field stays null.
  byo_network = var.virtual_network_name != null

  # Azure refuses an Automatic cluster on the network AKS manages unless the cluster runs on a
  # system assigned identity: `Managed cluster 'Automatic' SKU should use SAMI when using managed
  # vnet`. That works out, because the user assigned identity below exists precisely to be granted
  # access to resources that already exist - and a cluster that brings no network has none of those
  # to be granted. The identity is not created at all in that case; the cluster's own is used.
  system_assigned_identity = local.is_automatic && !local.byo_network

  # Whether the API server is joined to the existing network. It takes both halves: the integration
  # turned on and a subnet to inject the API server into. Either one missing leaves the API server
  # where AKS puts it by default, and nothing about the subnet reaches Azure.
  api_server_vnet_integration = var.api_server_vnet_integration_enabled && var.api_server_subnet_name != null

  # How the cluster authorizes calls to the Kubernetes API. With Azure RBAC - "Microsoft Entra ID
  # authentication with Azure RBAC" - AKS decides every call from Azure role assignments on the
  # cluster; without it the cluster falls back to Kubernetes RBAC, where the only Entra ID groups
  # that get anything are the admin groups of the cluster's own Entra ID profile. AKS Automatic is
  # preconfigured with Azure RBAC and cannot be moved off it, so the SKU overrides the variable
  # rather than sending Azure a request it would ignore.
  azure_rbac_enabled = local.is_automatic || var.azure_rbac_enabled

  # The admin groups sent in the cluster's Entra ID profile. Under Azure RBAC they are not honored -
  # authorization comes from the role assignments below instead - so nothing is sent there, which is
  # also what Azure itself reports for such a cluster: `"adminGroupObjectIds": null`.
  kubernetes_rbac_admin_group_object_ids = local.azure_rbac_enabled ? null : var.entra_admin_group_object_ids

  # Whether the group grants on the cluster are made here. They only exist under Azure RBAC, and
  # they are role assignments like any other, so an estate that has role assignments managed
  # elsewhere gets these from there too.
  create_entra_group_role_assignments = local.azure_rbac_enabled && var.create_role_assignments

  # Tags the cluster already carries in Azure, or null while it does not exist yet or carries none.
  # Feeding them back keeps the tags out of the plan instead of having Terraform delete them.
  cluster_tags = try(data.azapi_resource_list.managed_clusters.output.tags, null)

  # Cost analysis breaks the cluster spend down by namespace and deployment in Azure Cost
  # Management. Azure sells it with the paid tiers only and refuses the request on Free.
  cost_analysis_enabled = var.cost_analysis_enabled == null ? null : var.cost_analysis_enabled

  # What of `default_node_pool` reaches Azure. A Base cluster gets all of it. An AKS Automatic
  # cluster sizes, scales and rolls its own node pools, so it gets only the name and the node
  # subnet - what the module's own Automatic example sends - and the count falls back to the three
  # nodes the module defaults to, rather than a number written for a Base cluster.
  #
  # Leaving the rest set and relying on the module to drop it does not work. The module filters the
  # create request down to what Automatic accepts, but the follow-up request it sends straight to
  # the agent pool afterwards - the one that exists because the cluster resource ignores changes to
  # `agentPoolProfiles` - is not filtered at all, so a VM size, an autoscaler setting and a set of
  # upgrade settings reach an Automatic cluster that has no place to put them.
  default_agent_pool = {
    availability_zones  = var.default_node_pool.availability_zones
    count_of            = var.default_node_pool.node_count
    enable_auto_scaling = var.default_node_pool.enable_auto_scaling
    max_count           = var.default_node_pool.enable_auto_scaling ? var.default_node_pool.max_count : null
    max_pods            = var.default_node_pool.max_pods
    min_count           = var.default_node_pool.enable_auto_scaling ? var.default_node_pool.min_count : null
    name                = var.default_node_pool.name
    os_disk_size_gb     = var.default_node_pool.os_disk_size_gb
    type                = "VirtualMachineScaleSets"
    # How the pool is rolled during an upgrade. These belong to the pool: the cluster level
    # upgrade_settings of the module only carries the force-upgrade override, and silently drops
    # anything else, because Terraform discards object attributes a type constraint does not declare.
    upgrade_settings = {
      drain_timeout_in_minutes      = var.default_node_pool.drain_timeout_minutes
      max_surge                     = var.default_node_pool.max_surge
      node_soak_duration_in_minutes = var.default_node_pool.node_soak_duration_minutes
    }
    vm_size        = var.default_node_pool.vm_size
    vnet_subnet_id = one(data.azurerm_subnet.node[*].id)
  }

  # The pod and service ranges Azure assigns by itself when the create request carries no network
  # profile of its own. This is a RECORD OF WHAT AKS DOES, not a setting: editing it changes nothing
  # about the cluster, only what the overlap check below compares against. Change it only if Azure's
  # own defaults change. To choose the ranges a cluster runs on, set network_profile.pod_cidr and
  # network_profile.service_cidr - and note that they only reach Azure when the module sends the
  # network profile at all, which the README's AKS Automatic section explains.
  azure_assigned_cluster_cidrs = ["10.244.0.0/16", "10.0.0.0/16"]

  # The ranges the cluster will actually run on, whichever of the two they came from.
  effective_cluster_cidrs = local.network_profile_is_sent ? compact([
    var.network_profile.pod_cidr,
    var.network_profile.service_cidr,
  ]) : local.azure_assigned_cluster_cidrs

  # Short code for the region, for the identity name below. Azure has no standard for these, so this
  # is the estate's own convention rather than something derivable - a region that is not listed here
  # gets added here. The identity is refused rather than named with a guess.
  # Country codes ALPHA-2 & ALPHA-3: https://www.iban.com/country-codes 
  location_code = lookup(local.location_codes, var.location, "")
  location_codes = {
    finlandcentral = "fic"
    francecentral  = "frc"
    swedencentral  = "sec"
    westeurope     = "euw"
    uksouth        = "uks"
    ukwest         = "ukw"
  }
  # `id-<region code>-<environment>-<function>`, worked out from the cluster name and the region
  # rather than stated per environment. A cluster name reads <what it is>-<environment>-<which one>,
  # so `aks-prototype-free` in swedencentral is run by `id-sec-prototype-aks-free`: the environment
  # moves to the front of the function, and everything past it distinguishes the cluster from its
  # siblings in the same environment. A name with nothing to split has no environment to lift out,
  # and becomes `id-<region code>-<name>`.
  managed_identity_name = length(local.name_segments) < 2 ? join("-", ["id", local.location_code, var.name]) : join("-", concat(
    ["id", local.location_code, local.name_segments[1], local.name_segments[0]],
    slice(local.name_segments, 2, length(local.name_segments)),
  ))
  name_segments = split("-", var.name)

  # Every managed namespace as the request body AKS takes, with the estate-wide defaults filled in
  # wherever the namespace itself says nothing. Labels and annotations merge key by key, so a
  # namespace adds to the default set instead of replacing it; everything else is a plain override.
  #
  # The optional parts are merged in rather than sent as null, because AzAPI only tracks what the
  # body declares: a key written out as null is sent as null and then differs from what Azure
  # answers with, which turns up as an update in every later plan.
  managed_namespace_properties = {
    for name, namespace in var.managed_namespaces : name => merge(
      {
        adoptionPolicy = coalesce(namespace.adoption_policy, var.managed_namespace_defaults.adoption_policy)
        defaultNetworkPolicy = {
          egress  = coalesce(namespace.network_policy.egress, var.managed_namespace_defaults.network_policy.egress)
          ingress = coalesce(namespace.network_policy.ingress, var.managed_namespace_defaults.network_policy.ingress)
        }
        deletePolicy = coalesce(namespace.delete_policy, var.managed_namespace_defaults.delete_policy)
      },
      length(local.managed_namespace_annotations[name]) == 0 ? {} : { annotations = local.managed_namespace_annotations[name] },
      length(local.managed_namespace_labels[name]) == 0 ? {} : { labels = local.managed_namespace_labels[name] },
      length(local.managed_namespace_resource_quotas[name]) == 0 ? {} : { defaultResourceQuota = local.managed_namespace_resource_quotas[name] },
    )
  }

  managed_namespace_annotations = {
    for name, namespace in var.managed_namespaces : name => merge(var.managed_namespace_defaults.annotations, namespace.annotations)
  }

  managed_namespace_labels = {
    for name, namespace in var.managed_namespaces : name => merge(var.managed_namespace_defaults.labels, namespace.labels)
  }

  # The quota figures a namespace ends up with, in the shape the API takes and with the ones nobody
  # named left out entirely. An empty map means no quota at all, which is a different thing from a
  # quota whose every figure is unset: AKS applies the latter and limits nothing by it.
  managed_namespace_resource_quotas = {
    for name, namespace in var.managed_namespaces : name => {
      for field, quantity in {
        cpuLimit      = namespace.resource_quota.cpu_limit != null ? namespace.resource_quota.cpu_limit : var.managed_namespace_defaults.resource_quota.cpu_limit
        cpuRequest    = namespace.resource_quota.cpu_request != null ? namespace.resource_quota.cpu_request : var.managed_namespace_defaults.resource_quota.cpu_request
        memoryLimit   = namespace.resource_quota.memory_limit != null ? namespace.resource_quota.memory_limit : var.managed_namespace_defaults.resource_quota.memory_limit
        memoryRequest = namespace.resource_quota.memory_request != null ? namespace.resource_quota.memory_request : var.managed_namespace_defaults.resource_quota.memory_request
      } : field => quantity if quantity != null
    }
  }

  # Namespaces whose default policies actually restrict something, which is what needs a network
  # policy engine in the cluster to be worth anything. A namespace left wide open in both
  # directions is unaffected by whether one is running.
  managed_namespaces_relying_on_network_policy = [
    for name, properties in local.managed_namespace_properties : name
    if properties.defaultNetworkPolicy.egress != "AllowAll" || properties.defaultNetworkPolicy.ingress != "AllowAll"
  ]

  # Whether the cluster runs something that enforces Kubernetes network policies at all. AKS
  # Automatic always runs Cilium, so it does regardless of what network_profile says - and the
  # profile is not even sent for an Automatic cluster on loadBalancer egress.
  network_policy_engine_enabled = local.is_automatic || var.network_profile.network_policy != "none"

  # Azure rejects a dnsPrefix when a custom private DNS zone is used and requires an fqdnSubdomain
  # instead. AKS Automatic derives both itself.
  fqdn_subdomain = local.is_automatic ? null : (local.use_byo_private_dns_zone ? coalesce(var.fqdn_subdomain, var.name) : var.fqdn_subdomain)
  is_automatic   = var.sku_name == "Automatic"

  # AKS Automatic provisions its own node pools through node autoprovisioning, which Microsoft
  # documents as needing Network Contributor on the whole virtual network - an assignment on the
  # subnets the cluster was handed is not enough, because the pools it creates are not limited to
  # them. A Base cluster joins only the subnets named here, so it keeps the narrower grant.
  network_role_assignment_scope = coalesce(var.network_role_assignment_scope, local.is_automatic ? "virtual_network" : "subnet")

  # Scopes the cluster identity is granted Network Contributor on. Keyed by role rather than by
  # resource ID, so that renaming a subnet does not churn the state addresses of the assignments.
  network_role_assignment_scopes = !var.create_role_assignments || !local.byo_network ? {} : (
    local.network_role_assignment_scope == "virtual_network"
    ? { virtual_network = data.azurerm_virtual_network.this[0].id }
    # One entry per distinct subnet: the same subnet can carry more than one of these roles, and
    # Azure refuses a second assignment of the same role to the same principal at the same scope.
    : { for key, id in local.network_role_assignment_subnet_scopes : key => id
      if key == sort([for other_key, other_id in local.network_role_assignment_subnet_scopes : other_key if other_id == id])[0]
    }
  )
  network_role_assignment_subnet_scopes = merge(
    { node_subnet = one(data.azurerm_subnet.node[*].id) },
    var.system_node_subnet_name == null ? {} : { system_node_subnet = data.azurerm_subnet.system_node[0].id },
    !local.api_server_vnet_integration ? {} : { api_server_subnet = data.azurerm_subnet.api_server[0].id },
  )

  # Whether the module sends a `network_profile` at all. It drops the whole profile - the pod and
  # service ranges with it - for an Automatic cluster left on the default `loadBalancer` egress,
  # even though podCidr, serviceCidr and dnsServiceIP are on the short list of properties the
  # Automatic SKU does accept. Anything else, and the profile is sent.
  network_profile_is_sent = !(local.is_automatic && var.network_profile.outbound_type == "loadBalancer")

  # Cluster-internal ranges that collide with the address space of the existing network. Two CIDRs
  # overlap when they share a network address at the shorter of their two prefix lengths. IPv6
  # ranges are skipped rather than compared against IPv4 ones.
  overlapping_cluster_cidrs = [
    for pair in setproduct(
      [for range in local.virtual_network_address_space : range if !strcontains(range, ":")],
      local.effective_cluster_cidrs
    ) : "${pair[1]} overlaps ${pair[0]}"
    if try(
      cidrhost(format("%s/%d", cidrhost(pair[0], 0), min(tonumber(split("/", pair[0])[1]), tonumber(split("/", pair[1])[1]))), 0)
      ==
      cidrhost(format("%s/%d", cidrhost(pair[1], 0), min(tonumber(split("/", pair[0])[1]), tonumber(split("/", pair[1])[1]))), 0),
      false
    )
  ]

  # The grant on a bring-your-own private DNS zone needs a principal that exists before the cluster,
  # which a system assigned identity is not.
  create_private_dns_zone_assignment   = var.create_role_assignments && local.use_byo_private_dns_zone && !local.system_assigned_identity
  private_dns_zone                     = var.private_cluster_enabled ? (local.use_byo_private_dns_zone ? one(data.azurerm_private_dns_zone.this[*].id) : "system") : null
  private_dns_zone_resource_group_name = coalesce(var.private_dns_zone_resource_group_name, var.resource_group_name)
  use_byo_private_dns_zone             = var.private_cluster_enabled && var.private_dns_zone_name != null

  # Address space of the existing network, or nothing to collide with when AKS brings the network.
  virtual_network_address_space       = local.byo_network ? data.azurerm_virtual_network.this[0].address_space : []
  virtual_network_resource_group_name = coalesce(var.virtual_network_resource_group_name, var.resource_group_name)
}
