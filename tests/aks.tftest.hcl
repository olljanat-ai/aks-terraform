# Plan-time behaviour of the root module, exercised without touching Azure: the providers are
# mocked, so `terraform test` needs no subscription and no credentials.
#
#   terraform test

# The mocked IDs have to look real: the azurerm provider parses them while it builds the plan and
# rejects the random strings a bare mock hands it.
mock_provider "azurerm" {
  mock_data "azurerm_resource_group" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aks-test"
    }
  }
  mock_data "azurerm_virtual_network" {
    defaults = {
      address_space = ["172.19.0.0/16"]
      id            = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aks-test/providers/Microsoft.Network/virtualNetworks/vnet-aks-test"
    }
  }
  mock_data "azurerm_subnet" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aks-test/providers/Microsoft.Network/virtualNetworks/vnet-aks-test/subnets/snet-aks-nodes"
    }
  }
  mock_data "azurerm_private_dns_zone" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aks-test/providers/Microsoft.Network/privateDnsZones/privatelink.swedencentral.azmk8s.io"
    }
  }
  mock_resource "azurerm_user_assigned_identity" {
    defaults = {
      id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aks-test/providers/Microsoft.ManagedIdentity/userAssignedIdentities/aks-test-identity"
      principal_id = "11111111-1111-1111-1111-111111111111"
    }
  }
}
mock_provider "azapi" {}
mock_provider "time" {}

# The cluster module brings its own providers and its own registry lookups; none of that is under
# test here, so it is replaced by the one output the root module reads back.
override_module {
  target = module.aks
  outputs = {
    resource_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aks-test/providers/Microsoft.ContainerService/managedClusters/aks-test"
  }
}

variables {
  location             = "swedencentral"
  name                 = "aks-test"
  node_subnet_name     = "snet-aks-nodes"
  resource_group_name  = "rg-aks-test"
  virtual_network_name = "vnet-aks-test"
}

# ----------------------------------------------------------------------------------------------
# Defaults
# ----------------------------------------------------------------------------------------------

run "default_cluster_is_private_and_scoped_to_its_node_subnet" {
  command = plan

  assert {
    condition     = length(azurerm_role_assignment.network_contributor) == 1
    error_message = "A cluster with one node subnet should get exactly one Network Contributor assignment."
  }
  assert {
    condition     = azurerm_role_assignment.network_contributor["node_subnet"].scope == data.azurerm_subnet.node.id
    error_message = "The assignment should be scoped to the node subnet, not to the virtual network."
  }
  assert {
    condition     = length(azurerm_role_assignment.private_dns_zone_contributor) == 0
    error_message = "Without a bring-your-own private DNS zone there is nothing to grant access to."
  }
  assert {
    condition     = length(time_sleep.role_assignment_propagation) == 1
    error_message = "Creating role assignments should also wait for them to propagate."
  }
}

# id-<region code>-<environment>-<function>, worked out rather than stated: the environment is
# lifted out of the cluster name and put in front of what the cluster is.
run "the_identity_name_is_built_from_the_cluster_name_and_the_region" {
  command = plan

  variables {
    name = "aks-prototype-free"
  }

  assert {
    condition     = azurerm_user_assigned_identity.this.name == "id-sec-prototype-aks-free"
    error_message = "aks-prototype-free in swedencentral should be run by id-sec-prototype-aks-free."
  }
}

run "an_automatic_cluster_is_named_apart_from_its_sibling" {
  command = plan

  variables {
    name = "aks-prototype-automatic"
  }

  assert {
    condition     = azurerm_user_assigned_identity.this.name == "id-sec-prototype-aks-automatic"
    error_message = "Two clusters in one environment must not end up sharing an identity name."
  }
}

run "a_cluster_name_with_nothing_after_the_environment_keeps_the_short_form" {
  command = plan

  variables {
    name = "aks-prod"
  }

  assert {
    condition     = azurerm_user_assigned_identity.this.name == "id-sec-prod-aks"
    error_message = "A name with no distinguishing tail should stop after the function."
  }
}

run "a_cluster_name_with_nothing_to_split_has_no_environment_to_lift" {
  command = plan

  variables {
    name = "cluster"
  }

  assert {
    condition     = azurerm_user_assigned_identity.this.name == "id-sec-cluster"
    error_message = "A single segment name has no environment, so the name follows the region directly."
  }
}

run "the_region_follows_the_location" {
  command = plan

  variables {
    location = "westeurope"
    name     = "aks-prod-main"
  }

  assert {
    condition     = azurerm_user_assigned_identity.this.name == "id-weu-prod-aks-main"
    error_message = "The region code should come from location, not from swedencentral by habit."
  }
}

# Guessing a code for an unknown region would put an off-convention name on a real identity.
run "refuses_a_region_with_no_short_code" {
  command = plan

  variables {
    location = "moonbase1"
  }

  expect_failures = [azurerm_user_assigned_identity.this]
}

run "wider_scope_grants_the_virtual_network_instead" {
  command = plan

  variables {
    network_role_assignment_scope = "virtual_network"
  }

  assert {
    condition     = azurerm_role_assignment.network_contributor["virtual_network"].scope == data.azurerm_virtual_network.this.id
    error_message = "network_role_assignment_scope = \"virtual_network\" should grant the whole network."
  }
}

run "role_assignments_can_be_left_to_someone_else" {
  command = plan

  variables {
    create_role_assignments = false
    private_dns_zone_name   = "privatelink.swedencentral.azmk8s.io"
  }

  assert {
    condition     = length(azurerm_role_assignment.network_contributor) == 0
    error_message = "create_role_assignments = false should create no assignments."
  }
  assert {
    condition     = length(azurerm_role_assignment.private_dns_zone_contributor) == 0
    error_message = "create_role_assignments = false should create no assignments."
  }
  assert {
    condition     = length(time_sleep.role_assignment_propagation) == 0
    error_message = "There is nothing to wait for when no assignment is created."
  }
}

run "byo_private_dns_zone_is_granted_and_named" {
  command = plan

  variables {
    private_dns_zone_name = "privatelink.swedencentral.azmk8s.io"
  }

  assert {
    condition     = length(azurerm_role_assignment.private_dns_zone_contributor) == 1
    error_message = "A bring-your-own zone needs the cluster identity to be able to write records into it."
  }
}

# Node autoprovisioning creates node pools of its own, which the subnet assignments do not cover, so
# Microsoft documents Network Contributor on the whole virtual network for this SKU. A cluster left
# on the subnet scope comes up half way and then sits in Creating until the deployment times out.
run "automatic_is_granted_the_whole_virtual_network" {
  command = plan

  variables {
    sku_name                = "Automatic"
    sku_tier                = "Standard"
    api_server_subnet_name  = "snet-aks-apiserver"
    system_node_subnet_name = "snet-aks-system"
  }

  assert {
    condition     = keys(azurerm_role_assignment.network_contributor) == ["virtual_network"]
    error_message = "AKS Automatic should get one assignment on the virtual network, not one per subnet."
  }
  assert {
    condition     = azurerm_role_assignment.network_contributor["virtual_network"].scope == data.azurerm_virtual_network.this.id
    error_message = "The assignment should be scoped to the virtual network."
  }
}

# The narrower scope stays reachable, since an environment may have the assignment already in place
# at that scope, but it is the configuration the check block warns about.
run "automatic_can_still_be_scoped_down_by_hand" {
  command = plan

  variables {
    sku_name                      = "Automatic"
    sku_tier                      = "Standard"
    api_server_subnet_name        = "snet-aks-apiserver"
    system_node_subnet_name       = "snet-aks-system"
    network_role_assignment_scope = "subnet"
  }

  # The mocked subnet data source hands out one ID for every subnet, which would collapse into a
  # single assignment. Three distinct subnets is the point of this run, so they are named here.
  override_data {
    target = data.azurerm_subnet.system_node[0]
    values = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aks-test/providers/Microsoft.Network/virtualNetworks/vnet-aks-test/subnets/snet-aks-system"
    }
  }
  override_data {
    target = data.azurerm_subnet.api_server[0]
    values = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aks-test/providers/Microsoft.Network/virtualNetworks/vnet-aks-test/subnets/snet-aks-apiserver"
    }
  }

  expect_failures = [check.automatic_network_role_assignment_scope]

  assert {
    condition     = length(azurerm_role_assignment.network_contributor) == 3
    error_message = "An explicit subnet scope should still produce one assignment per subnet."
  }
}

# A Base cluster is unaffected: it joins the subnets it is handed and nothing else.
run "base_keeps_the_subnet_scoped_assignments" {
  command = plan

  assert {
    condition     = keys(azurerm_role_assignment.network_contributor) == ["node_subnet"]
    error_message = "A Base cluster should keep the least privilege subnet assignments."
  }
}

# The whole cluster can share a single subnet. Azure refuses a second assignment of the same role to
# the same principal at the same scope, so the duplicate has to be collapsed rather than sent twice.
run "one_subnet_in_two_roles_is_granted_once" {
  command = plan

  variables {
    system_node_subnet_name = "snet-aks-nodes"
  }

  assert {
    condition     = length(azurerm_role_assignment.network_contributor) == 1
    error_message = "A node subnet that is also the system node subnet should be granted exactly once."
  }
}

# AKS Automatic sizes and rolls its own node pools. Everything written for a Base cluster has to be
# dropped before it reaches the module, because the request the module sends to the agent pool after
# the cluster is created is not filtered by SKU the way the create request is.
run "automatic_sends_no_base_cluster_node_pool_settings" {
  command = plan

  variables {
    sku_name                = "Automatic"
    sku_tier                = "Standard"
    api_server_subnet_name  = "snet-aks-apiserver"
    system_node_subnet_name = "snet-aks-system"
    default_node_pool = {
      vm_size             = "Standard_B2s"
      enable_auto_scaling = false
      node_count          = 1
    }
  }

  assert {
    condition = alltrue([
      local.default_agent_pool.vm_size == null,
      local.default_agent_pool.count_of == null,
      local.default_agent_pool.enable_auto_scaling == null,
      local.default_agent_pool.type == null,
      local.default_agent_pool.upgrade_settings == null,
      local.default_agent_pool.availability_zones == null,
    ])
    error_message = "AKS Automatic should be sent no VM size, count, autoscaler, pool type or upgrade settings."
  }
  assert {
    condition     = local.default_agent_pool.vnet_subnet_id == data.azurerm_subnet.node.id
    error_message = "AKS Automatic still places its nodes in the node subnet."
  }
}

run "base_keeps_its_node_pool_settings" {
  command = plan

  variables {
    default_node_pool = {
      vm_size             = "Standard_B2s"
      enable_auto_scaling = false
      node_count          = 1
    }
  }

  assert {
    condition = alltrue([
      local.default_agent_pool.vm_size == "Standard_B2s",
      local.default_agent_pool.count_of == 1,
      local.default_agent_pool.enable_auto_scaling == false,
      local.default_agent_pool.type == "VirtualMachineScaleSets",
      local.default_agent_pool.upgrade_settings.max_surge == "10%",
    ])
    error_message = "A Base cluster should still be sent the node pool it asked for."
  }
}

# The AzAPI default of 30 minutes is under what an AKS Automatic cluster in an existing network
# takes, and a Terraform side timeout does not stop the deployment - it just leaves the cluster in
# Creating with nothing in state.
run "cluster_operations_are_given_longer_than_the_provider_default" {
  command = plan

  assert {
    condition     = var.cluster_timeouts.create == "90m"
    error_message = "The cluster create timeout should be well above the 30 minute AzAPI default."
  }
}

run "rejects_a_cluster_timeout_that_is_not_a_duration" {
  command = plan

  variables {
    cluster_timeouts = {
      create = "90 minutes"
    }
  }

  expect_failures = [var.cluster_timeouts]
}

# The module drops the whole network profile for an Automatic cluster on loadBalancer egress, so the
# ranges it runs on are Azure's rather than the ones network_profile asks for. They cannot be changed
# once the cluster exists, which is why this is worth catching before the apply.
run "automatic_on_load_balancer_egress_falls_back_to_the_azure_ranges" {
  command = plan

  variables {
    sku_name                = "Automatic"
    sku_tier                = "Standard"
    api_server_subnet_name  = "snet-aks-apiserver"
    system_node_subnet_name = "snet-aks-system"
  }

  assert {
    condition     = !local.network_profile_is_sent
    error_message = "The module sends no network profile for this combination, so the configured ranges do not apply."
  }
  assert {
    condition     = local.effective_cluster_cidrs == tolist(["10.244.0.0/16", "10.0.0.0/16"])
    error_message = "The cluster should be reported as running on Azure's default pod and service ranges."
  }
}

# Any other egress type and the profile is sent, filtered down to the four properties Automatic
# accepts - which include the two ranges.
run "automatic_off_load_balancer_egress_keeps_the_configured_ranges" {
  command = plan

  variables {
    sku_name                = "Automatic"
    sku_tier                = "Standard"
    api_server_subnet_name  = "snet-aks-apiserver"
    system_node_subnet_name = "snet-aks-system"
    network_profile = {
      outbound_type = "userDefinedRouting"
    }
  }

  assert {
    condition     = local.network_profile_is_sent
    error_message = "Anything other than loadBalancer egress should send the network profile."
  }
  assert {
    condition     = local.effective_cluster_cidrs == tolist(["100.201.0.0/16", "100.202.0.0/16"])
    error_message = "The configured ranges should survive for this combination."
  }
}

run "base_always_keeps_the_configured_ranges" {
  command = plan

  assert {
    condition     = local.network_profile_is_sent && local.effective_cluster_cidrs == tolist(["100.201.0.0/16", "100.202.0.0/16"])
    error_message = "A Base cluster is sent the network profile it asked for."
  }
}

run "an_address_space_clear_of_the_cluster_ranges_raises_nothing" {
  command = plan

  assert {
    condition     = length(local.overlapping_cluster_cidrs) == 0
    error_message = "100.201.0.0/16 and 100.202.0.0/16 do not overlap 172.19.0.0/16."
  }
}

# Azure's default service range is 10.0.0.0/16, which collides with a great many existing networks -
# and an Automatic cluster on loadBalancer egress gets it whether or not network_profile says so.
run "warns_when_the_azure_ranges_collide_with_the_existing_network" {
  command = plan

  variables {
    sku_name                = "Automatic"
    sku_tier                = "Standard"
    api_server_subnet_name  = "snet-aks-apiserver"
    system_node_subnet_name = "snet-aks-system"
  }

  override_data {
    target = data.azurerm_virtual_network.this
    values = {
      id            = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aks-test/providers/Microsoft.Network/virtualNetworks/vnet-aks-test"
      address_space = ["10.0.0.0/16"]
    }
  }

  expect_failures = [check.cluster_cidrs_do_not_overlap_the_network]
}

# A shorter prefix on either side still counts as an overlap.
run "warns_when_a_supernet_of_the_cluster_ranges_is_in_use" {
  command = plan

  override_data {
    target = data.azurerm_virtual_network.this
    values = {
      id            = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aks-test/providers/Microsoft.Network/virtualNetworks/vnet-aks-test"
      address_space = ["100.200.0.0/14"]
    }
  }

  expect_failures = [check.cluster_cidrs_do_not_overlap_the_network]
}

# An IPv6 range is skipped rather than compared against an IPv4 one.
run "an_ipv6_address_space_is_not_compared_against_the_ipv4_ranges" {
  command = plan

  override_data {
    target = data.azurerm_virtual_network.this
    values = {
      id            = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aks-test/providers/Microsoft.Network/virtualNetworks/vnet-aks-test"
      address_space = ["fd00::/48", "172.19.0.0/16"]
    }
  }

  assert {
    condition     = length(local.overlapping_cluster_cidrs) == 0
    error_message = "An IPv6 range should neither match an IPv4 one nor break the comparison."
  }
}

run "cost_analysis_stays_off_on_the_free_tier" {
  command = plan

  assert {
    condition     = !local.cost_analysis_enabled
    error_message = "Azure refuses cost analysis on the Free tier, so a Free cluster must not ask for it."
  }
}

run "cost_analysis_is_on_for_the_standard_tier" {
  command = plan

  variables {
    sku_tier = "Standard"
  }

  assert {
    condition     = local.cost_analysis_enabled
    error_message = "A paid tier cluster should have cost analysis enabled."
  }
}

run "cost_analysis_is_on_for_the_premium_tier" {
  command = plan

  variables {
    sku_tier = "Premium"
  }

  assert {
    condition     = local.cost_analysis_enabled
    error_message = "Premium is a paid tier too, so cost analysis should be enabled there as well."
  }
}

# ----------------------------------------------------------------------------------------------
# Upgrade windows
# ----------------------------------------------------------------------------------------------

run "upgrade_windows_cover_all_three_schedules_and_send_no_start_date" {
  command = plan

  assert {
    condition = toset(keys(azapi_resource.maintenance_configuration)) == toset([
      "aksManagedAutoUpgradeSchedule",
      "aksManagedNodeOSUpgradeSchedule",
      "default",
    ])
    error_message = "Azure fixes the three maintenance configuration names; all three should be managed."
  }
  assert {
    condition = alltrue([
      for configuration in azapi_resource.maintenance_configuration :
      !contains(keys(configuration.body.properties.maintenanceWindow), "startDate")
    ])
    error_message = "Sending a startDate makes every later plan propose an update, so it must stay out of the body."
  }
  assert {
    condition     = azapi_resource.maintenance_configuration["default"].body.properties.maintenanceWindow.durationHours == 8
    error_message = "The window should carry the configured duration."
  }
}

run "warns_about_a_public_api_server_without_an_allowlist" {
  command = plan

  variables {
    private_cluster_enabled = false
  }

  # In a real plan the check reports a warning; `terraform test` treats it as a failure, which is
  # what pins the warning down as still being raised.
  expect_failures = [check.api_server_exposure]
}

run "an_allowlisted_public_api_server_raises_nothing" {
  command = plan

  variables {
    private_cluster_enabled         = false
    api_server_authorized_ip_ranges = ["203.0.113.0/24"]
  }
}

# ----------------------------------------------------------------------------------------------
# Input validation
# ----------------------------------------------------------------------------------------------

run "rejects_a_cluster_name_azure_would_refuse" {
  command = plan

  variables {
    name = "aks_test!"
  }

  expect_failures = [var.name]
}

run "rejects_a_dns_service_ip_outside_the_service_cidr" {
  command = plan

  variables {
    network_profile = {
      service_cidr   = "100.202.0.0/16"
      dns_service_ip = "100.203.0.10"
    }
  }

  expect_failures = [var.network_profile]
}

run "rejects_cilium_network_policy_on_the_azure_dataplane" {
  command = plan

  variables {
    network_profile = {
      network_policy    = "cilium"
      network_dataplane = "azure"
    }
  }

  expect_failures = [var.network_profile]
}

run "rejects_an_authorized_range_that_is_not_a_cidr" {
  command = plan

  variables {
    private_cluster_enabled         = false
    api_server_authorized_ip_ranges = ["203.0.113.5"]
  }

  expect_failures = [var.api_server_authorized_ip_ranges]
}

run "rejects_an_entra_group_name_where_an_object_id_belongs" {
  command = plan

  variables {
    entra_admin_group_object_ids = ["aks-admins"]
  }

  expect_failures = [var.entra_admin_group_object_ids]
}

run "rejects_a_node_pool_that_cannot_scale" {
  command = plan

  variables {
    default_node_pool = {
      min_count = 5
      max_count = 3
    }
  }

  expect_failures = [var.default_node_pool]
}

run "rejects_a_max_surge_azure_cannot_read" {
  command = plan

  variables {
    default_node_pool = {
      max_surge = "10 percent"
    }
  }

  expect_failures = [var.default_node_pool]
}

run "rejects_a_pinned_version_the_upgrade_channel_would_move_past" {
  command = plan

  variables {
    kubernetes_version = "1.32"
    auto_upgrade = {
      kubernetes_channel = "stable"
    }
  }

  expect_failures = [var.auto_upgrade]
}

run "rejects_patch_upgrades_of_an_exactly_pinned_version" {
  command = plan

  variables {
    kubernetes_version = "1.32.4"
    auto_upgrade = {
      kubernetes_channel = "patch"
    }
  }

  expect_failures = [var.auto_upgrade]
}

run "accepts_patch_upgrades_of_a_minor_version_pin" {
  command = plan

  variables {
    kubernetes_version = "1.32"
    auto_upgrade = {
      kubernetes_channel = "patch"
    }
  }
}

run "rejects_a_kubernetes_version_with_a_leading_v" {
  command = plan

  variables {
    kubernetes_version = "v1.32"
  }

  expect_failures = [var.kubernetes_version]
}

run "rejects_a_maintenance_window_too_short_to_upgrade_in" {
  command = plan

  variables {
    maintenance_window = {
      duration_hours = 2
    }
  }

  expect_failures = [var.maintenance_window]
}

# Azure answers this with 400 InvalidParameter, so it is refused before the request is built.
run "rejects_automatic_reusing_the_node_subnet_for_system_nodes" {
  command = plan

  variables {
    sku_name                = "Automatic"
    sku_tier                = "Standard"
    api_server_subnet_name  = "snet-aks-apiserver"
    system_node_subnet_name = "snet-aks-nodes"
  }

  expect_failures = [var.system_node_subnet_name]
}

run "rejects_automatic_without_a_system_node_subnet" {
  command = plan

  variables {
    sku_name               = "Automatic"
    sku_tier               = "Standard"
    api_server_subnet_name = "snet-aks-apiserver"
  }

  expect_failures = [var.system_node_subnet_name]
}

# Microsoft documents the API server subnet as required for an Automatic cluster in an existing
# network, but a cluster can be asked for without one - with a warning rather than a refusal.
run "warns_about_automatic_without_api_server_vnet_integration" {
  command = plan

  variables {
    sku_name                = "Automatic"
    sku_tier                = "Standard"
    system_node_subnet_name = "snet-aks-system"
  }

  expect_failures = [check.automatic_api_server_subnet]
}

run "rejects_automatic_on_the_free_tier" {
  command = plan

  variables {
    sku_name                = "Automatic"
    sku_tier                = "Free"
    api_server_subnet_name  = "snet-aks-apiserver"
    system_node_subnet_name = "snet-aks-system"
  }

  expect_failures = [var.sku_tier]
}
