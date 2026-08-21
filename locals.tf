locals {
  # API version of the AKS resource provider used by the resources written directly rather than
  # through the module. One place to bump, so that the two cannot drift apart.
  aks_api_version = "2026-03-01"
  # Authorized IP ranges only apply to a public API server; an empty list means "no restriction".
  api_server_authorized_ip_ranges = var.private_cluster_enabled || length(var.api_server_authorized_ip_ranges) == 0 ? null : var.api_server_authorized_ip_ranges
  # Tags the cluster already carries in Azure, or null while it does not exist yet or carries none.
  # Feeding them back keeps the tags out of the plan instead of having Terraform delete them.
  cluster_tags = try(data.azapi_resource_list.managed_clusters.output.tags, null)
  # Cost analysis breaks the cluster spend down by namespace and deployment in Azure Cost
  # Management. Azure sells it with the paid tiers only and refuses the request on Free.
  cost_analysis_enabled = var.sku_tier != "Free"
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
  default_agent_pool = local.is_automatic ? {
    availability_zones  = null
    count_of            = null
    enable_auto_scaling = null
    max_count           = null
    max_pods            = null
    min_count           = null
    name                = var.default_node_pool.name
    os_disk_size_gb     = null
    type                = null
    upgrade_settings    = null
    vm_size             = null
    vnet_subnet_id      = data.azurerm_subnet.node.id
    } : {
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
    vnet_subnet_id = data.azurerm_subnet.node.id
  }
  # The ranges the cluster will actually run on. They are the ones `network_profile` asks for only
  # when the module sends a network profile at all; otherwise Azure fills in its own, and these are
  # what it uses. Pinned here rather than left implicit, so the overlap check below has something to
  # compare against.
  aks_default_pod_cidr     = "100.102.0.0/16"
  aks_default_service_cidr = "100.101.0.0/16"
  effective_cluster_cidrs = compact(local.network_profile_is_sent
    ? [var.network_profile.pod_cidr, var.network_profile.service_cidr]
  : [local.aks_default_pod_cidr, local.aks_default_service_cidr])
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
  network_role_assignment_scopes = !var.create_role_assignments ? {} : (
    local.network_role_assignment_scope == "virtual_network"
    ? { virtual_network = data.azurerm_virtual_network.this.id }
    : merge(
      { node_subnet = data.azurerm_subnet.node.id },
      var.system_node_subnet_name == null ? {} : { system_node_subnet = data.azurerm_subnet.system_node[0].id },
      var.api_server_subnet_name == null ? {} : { api_server_subnet = data.azurerm_subnet.api_server[0].id },
    )
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
      [for range in data.azurerm_virtual_network.this.address_space : range if !strcontains(range, ":")],
      local.effective_cluster_cidrs
    ) : "${pair[1]} overlaps ${pair[0]}"
    if try(
      cidrhost(format("%s/%d", cidrhost(pair[0], 0), min(tonumber(split("/", pair[0])[1]), tonumber(split("/", pair[1])[1]))), 0)
      ==
      cidrhost(format("%s/%d", cidrhost(pair[1], 0), min(tonumber(split("/", pair[0])[1]), tonumber(split("/", pair[1])[1]))), 0),
      false
    )
  ]
  private_dns_zone                     = var.private_cluster_enabled ? (local.use_byo_private_dns_zone ? one(data.azurerm_private_dns_zone.this[*].id) : "system") : null
  private_dns_zone_resource_group_name = coalesce(var.private_dns_zone_resource_group_name, var.resource_group_name)
  use_byo_private_dns_zone             = var.private_cluster_enabled && var.private_dns_zone_name != null
  virtual_network_resource_group_name  = coalesce(var.virtual_network_resource_group_name, var.resource_group_name)
}
