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
    condition     = azurerm_role_assignment.network_contributor["node_subnet"].scope == data.azurerm_subnet.node[0].id
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
    condition     = azurerm_user_assigned_identity.this[0].name == "id-sec-prototype-aks-free"
    error_message = "aks-prototype-free in swedencentral should be run by id-sec-prototype-aks-free."
  }
}

run "an_automatic_cluster_is_named_apart_from_its_sibling" {
  command = plan

  variables {
    name = "aks-prototype-automatic"
  }

  assert {
    condition     = azurerm_user_assigned_identity.this[0].name == "id-sec-prototype-aks-automatic"
    error_message = "Two clusters in one environment must not end up sharing an identity name."
  }
}

run "a_cluster_name_with_nothing_after_the_environment_keeps_the_short_form" {
  command = plan

  variables {
    name = "aks-prod"
  }

  assert {
    condition     = azurerm_user_assigned_identity.this[0].name == "id-sec-prod-aks"
    error_message = "A name with no distinguishing tail should stop after the function."
  }
}

run "a_cluster_name_with_nothing_to_split_has_no_environment_to_lift" {
  command = plan

  variables {
    name = "cluster"
  }

  assert {
    condition     = azurerm_user_assigned_identity.this[0].name == "id-sec-cluster"
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
    condition     = azurerm_user_assigned_identity.this[0].name == "id-euw-prod-aks-main"
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
    condition     = azurerm_role_assignment.network_contributor["virtual_network"].scope == data.azurerm_virtual_network.this[0].id
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
    condition     = azurerm_role_assignment.network_contributor["virtual_network"].scope == data.azurerm_virtual_network.this[0].id
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
    target = data.azurerm_virtual_network.this[0]
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
    target = data.azurerm_virtual_network.this[0]
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
    target = data.azurerm_virtual_network.this[0]
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
# Entra ID group access
# ----------------------------------------------------------------------------------------------

# Azure RBAC is how these clusters authorize the Kubernetes API, and there the groups are granted
# Azure roles on the cluster. The admin groups of the cluster's own Entra ID profile are not honored
# in that mode, so nothing is sent there.
run "azure_rbac_grants_the_entra_groups_on_the_cluster" {
  command = plan

  variables {
    entra_admin_group_object_ids  = ["22222222-2222-2222-2222-222222222222"]
    entra_reader_group_object_ids = ["33333333-3333-3333-3333-333333333333"]
  }

  assert {
    condition     = local.azure_rbac_enabled && local.kubernetes_rbac_admin_group_object_ids == null
    error_message = "A cluster on Azure RBAC should send no admin groups in its Entra ID profile."
  }
  assert {
    condition     = keys(azurerm_role_assignment.entra_cluster_admin) == ["22222222-2222-2222-2222-222222222222"]
    error_message = "Each admin group should get an assignment of its own."
  }
  assert {
    condition     = azurerm_role_assignment.entra_cluster_admin["22222222-2222-2222-2222-222222222222"].role_definition_name == "Azure Kubernetes Service RBAC Cluster Admin"
    error_message = "Cluster admin under Azure RBAC is the Azure Kubernetes Service RBAC Cluster Admin role."
  }
  assert {
    condition     = azurerm_role_assignment.entra_cluster_admin["22222222-2222-2222-2222-222222222222"].scope == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aks-test/providers/Microsoft.ContainerService/managedClusters/aks-test"
    error_message = "The grant belongs on the cluster, not on the resource group around it."
  }
  assert {
    condition     = azurerm_role_assignment.entra_reader["33333333-3333-3333-3333-333333333333"].role_definition_name == "Azure Kubernetes Service RBAC Reader"
    error_message = "Read-only access under Azure RBAC is the Azure Kubernetes Service RBAC Reader role."
  }
  assert {
    condition     = azurerm_role_assignment.entra_cluster_admin["22222222-2222-2222-2222-222222222222"].principal_type == "Group"
    error_message = "The principal is a group, and saying so keeps Azure from looking one up that has not replicated yet."
  }
}

run "a_cluster_with_no_entra_groups_grants_nothing" {
  command = plan

  assert {
    condition     = length(azurerm_role_assignment.entra_cluster_admin) == 0 && length(azurerm_role_assignment.entra_reader) == 0
    error_message = "Nothing should be granted to groups that were never named."
  }
}

# Kubernetes RBAC is the other half of the same decision: no role assignments, and the admin groups
# ride along in the cluster's Entra ID profile instead, where they are bound to cluster-admin.
run "kubernetes_rbac_sends_the_admin_groups_with_the_cluster" {
  command = plan

  variables {
    azure_rbac_enabled           = false
    entra_admin_group_object_ids = ["22222222-2222-2222-2222-222222222222"]
  }

  assert {
    condition     = local.kubernetes_rbac_admin_group_object_ids == tolist(["22222222-2222-2222-2222-222222222222"])
    error_message = "Without Azure RBAC the admin groups are the only way in, so they have to reach the cluster."
  }
  assert {
    condition     = length(azurerm_role_assignment.entra_cluster_admin) == 0
    error_message = "An Azure role assignment authorizes nothing on a cluster that runs on Kubernetes RBAC."
  }
}

# Read-only access has no counterpart in Kubernetes RBAC: the Entra ID profile of the cluster carries
# admin groups and nothing else, so the reader groups are granted nothing and are warned about.
run "warns_about_reader_groups_without_azure_rbac" {
  command = plan

  variables {
    azure_rbac_enabled            = false
    entra_reader_group_object_ids = ["33333333-3333-3333-3333-333333333333"]
  }

  expect_failures = [check.reader_groups_need_azure_rbac]

  assert {
    condition     = length(azurerm_role_assignment.entra_reader) == 0
    error_message = "There is no read-only grant to make while the cluster authorizes through Kubernetes RBAC."
  }
}

# Azure preconfigures Automatic with Azure RBAC and gives it no way off, so the SKU decides and the
# groups are granted as role assignments regardless of what the variable asked for.
run "automatic_stays_on_azure_rbac_whatever_the_variable_says" {
  command = plan

  variables {
    sku_name                     = "Automatic"
    sku_tier                     = "Standard"
    api_server_subnet_name       = "snet-aks-apiserver"
    system_node_subnet_name      = "snet-aks-system"
    azure_rbac_enabled           = false
    entra_admin_group_object_ids = ["22222222-2222-2222-2222-222222222222"]
  }

  expect_failures = [check.automatic_is_always_authorized_through_azure_rbac]

  assert {
    condition     = local.azure_rbac_enabled && local.kubernetes_rbac_admin_group_object_ids == null
    error_message = "An Automatic cluster is authorized through Azure RBAC whatever azure_rbac_enabled says."
  }
  assert {
    condition     = length(azurerm_role_assignment.entra_cluster_admin) == 1
    error_message = "The admin groups of an Automatic cluster are granted as role assignments on it."
  }
}

# With the role assignments of the estate managed elsewhere, the groups are named here and granted
# there - which is worth saying out loud, because the cluster is otherwise unreachable.
run "warns_about_entra_groups_with_role_assignments_managed_elsewhere" {
  command = plan

  variables {
    create_role_assignments      = false
    entra_admin_group_object_ids = ["22222222-2222-2222-2222-222222222222"]
  }

  expect_failures = [check.entra_groups_are_granted_somewhere]

  assert {
    condition     = length(azurerm_role_assignment.entra_cluster_admin) == 0
    error_message = "create_role_assignments = false should create no assignments."
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

run "rejects_an_entra_reader_group_name_where_an_object_id_belongs" {
  command = plan

  variables {
    entra_reader_group_object_ids = ["aks-readers"]
  }

  expect_failures = [var.entra_reader_group_object_ids]
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

# Turning the integration off is a decision rather than an omission, so the warning above goes with
# it. This is what envs/prototype-automatic.tfvars asks for.
run "automatic_with_vnet_integration_turned_off_is_not_warned_about" {
  command = plan

  variables {
    sku_name                            = "Automatic"
    sku_tier                            = "Standard"
    system_node_subnet_name             = "snet-aks-system"
    api_server_vnet_integration_enabled = false
  }

  assert {
    condition     = !local.api_server_vnet_integration
    error_message = "The API server should not be joined to the network while the integration is off."
  }
  assert {
    condition     = length(data.azurerm_subnet.api_server) == 0
    error_message = "No API server subnet should be looked up while the integration is off."
  }
}

# The subnet is still granted to the cluster identity when the integration is on and the scope is
# narrowed to the subnets; with the integration off there is nothing there to grant.
run "no_api_server_subnet_assignment_while_the_integration_is_off" {
  command = plan

  variables {
    sku_name                            = "Automatic"
    sku_tier                            = "Standard"
    system_node_subnet_name             = "snet-aks-system"
    api_server_vnet_integration_enabled = false
    network_role_assignment_scope       = "subnet"
  }

  override_data {
    target = data.azurerm_subnet.system_node[0]
    values = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aks-test/providers/Microsoft.Network/virtualNetworks/vnet-aks-test/subnets/snet-aks-system"
    }
  }

  expect_failures = [check.automatic_network_role_assignment_scope]

  assert {
    condition     = keys(azurerm_role_assignment.network_contributor) == ["node_subnet", "system_node_subnet"]
    error_message = "Only the node and system node subnets should be granted while the integration is off."
  }
}

# Saying "no integration" and naming a subnet for it at the same time is refused, rather than one of
# the two being dropped silently.
run "rejects_an_api_server_subnet_while_the_integration_is_off" {
  command = plan

  variables {
    sku_name                            = "Automatic"
    sku_tier                            = "Standard"
    system_node_subnet_name             = "snet-aks-system"
    api_server_subnet_name              = "snet-aks-apiserver"
    api_server_vnet_integration_enabled = false
  }

  expect_failures = [var.api_server_subnet_name]
}

# A Base cluster keeps its own default: nothing to turn off, nothing to warn about.
run "the_integration_is_off_by_default_without_a_subnet_to_join" {
  command = plan

  assert {
    condition     = !local.api_server_vnet_integration
    error_message = "A cluster with no api_server_subnet_name should not ask for VNet integration."
  }
}

# ----------------------------------------------------------------------------------------------
# Clusters that bring no network
# ----------------------------------------------------------------------------------------------

# What envs/prototype-automatic.tfvars asks for: no virtual network, no subnets, nothing to look up
# and nothing to grant. AKS creates the network inside the node resource group instead.
run "a_cluster_without_a_network_looks_nothing_up_and_grants_nothing" {
  command = plan

  variables {
    sku_name                            = "Automatic"
    sku_tier                            = "Standard"
    virtual_network_name                = null
    node_subnet_name                    = null
    api_server_vnet_integration_enabled = false
  }

  assert {
    condition     = !local.byo_network
    error_message = "A cluster with no virtual_network_name should not be treated as attached to one."
  }
  assert {
    condition = alltrue([
      length(data.azurerm_virtual_network.this) == 0,
      length(data.azurerm_subnet.node) == 0,
      length(data.azurerm_subnet.system_node) == 0,
      length(data.azurerm_subnet.api_server) == 0,
    ])
    error_message = "There is no existing network to read, so none of the lookups should run."
  }
  assert {
    condition     = length(azurerm_role_assignment.network_contributor) == 0
    error_message = "AKS owns the network it creates, so the cluster identity needs nothing granted on it."
  }
  assert {
    condition     = length(time_sleep.role_assignment_propagation) == 0
    error_message = "With no role assignments there is nothing to wait for."
  }
  assert {
    condition     = local.default_agent_pool.vnet_subnet_id == null
    error_message = "The node pool should be sent no subnet when the cluster brings no network."
  }
}

# The two Automatic warnings are both about an existing virtual network, and the overlap check has
# no address space to compare against. None of them should fire on this arrangement.
run "a_cluster_without_a_network_raises_none_of_the_network_warnings" {
  command = plan

  variables {
    sku_name                            = "Automatic"
    sku_tier                            = "Standard"
    virtual_network_name                = null
    node_subnet_name                    = null
    api_server_vnet_integration_enabled = false
    private_cluster_enabled             = false
    api_server_authorized_ip_ranges     = ["203.0.113.0/24"]
  }

  assert {
    condition     = length(local.overlapping_cluster_cidrs) == 0
    error_message = "There is no existing address space for the cluster ranges to collide with."
  }
}

# AKS Automatic hosts its system components in the network it creates, so the subnet that is
# otherwise required for this SKU is not.
run "automatic_without_a_network_needs_no_system_node_subnet" {
  command = plan

  variables {
    sku_name             = "Automatic"
    sku_tier             = "Standard"
    virtual_network_name = null
    node_subnet_name     = null
  }

  assert {
    condition     = length(data.azurerm_subnet.system_node) == 0
    error_message = "A cluster with no network has no system node subnet to look up."
  }
}

# A Base cluster can do without a network too; the module then gets no subnet for its node pool.
run "base_without_a_network_sends_no_node_subnet" {
  command = plan

  variables {
    virtual_network_name = null
    node_subnet_name     = null
  }

  assert {
    condition     = local.default_agent_pool.vnet_subnet_id == null
    error_message = "A Base node pool should be sent no subnet when the cluster brings no network."
  }
}

# The network and the node subnet are one decision, so half of it is refused rather than half done.
run "rejects_a_virtual_network_without_a_node_subnet" {
  command = plan

  variables {
    node_subnet_name = null
  }

  expect_failures = [var.node_subnet_name]
}

run "rejects_a_node_subnet_without_a_virtual_network" {
  command = plan

  variables {
    virtual_network_name = null
  }

  expect_failures = [var.node_subnet_name]
}

run "rejects_a_system_node_subnet_without_a_virtual_network" {
  command = plan

  variables {
    sku_name                = "Automatic"
    sku_tier                = "Standard"
    virtual_network_name    = null
    node_subnet_name        = null
    system_node_subnet_name = "snet-aks-system"
  }

  expect_failures = [var.system_node_subnet_name]
}

run "rejects_an_api_server_subnet_without_a_virtual_network" {
  command = plan

  variables {
    virtual_network_name   = null
    node_subnet_name       = null
    api_server_subnet_name = "snet-aks-apiserver"
  }

  expect_failures = [var.api_server_subnet_name]
}

# Azure answers an Automatic cluster on the network it manages with `Managed cluster 'Automatic' SKU
# should use SAMI when using managed vnet`, so that combination runs on the cluster's own identity
# and none is created here. There is nothing to pre-grant either way.
run "automatic_without_a_network_runs_on_a_system_assigned_identity" {
  command = plan

  variables {
    sku_name             = "Automatic"
    sku_tier             = "Standard"
    virtual_network_name = null
    node_subnet_name     = null
  }

  assert {
    condition     = local.system_assigned_identity
    error_message = "Azure refuses an Automatic cluster on a managed virtual network with a user assigned identity."
  }
  assert {
    condition     = length(azurerm_user_assigned_identity.this) == 0
    error_message = "No user assigned identity should be created for a cluster that runs on its own."
  }
}

# The rule is Automatic's alone, and only on the network AKS manages.
run "automatic_on_an_existing_network_keeps_the_user_assigned_identity" {
  command = plan

  variables {
    sku_name                = "Automatic"
    sku_tier                = "Standard"
    system_node_subnet_name = "snet-aks-system"
    api_server_subnet_name  = "snet-aks-apiserver"
  }

  assert {
    condition     = !local.system_assigned_identity
    error_message = "An Automatic cluster on an existing network is granted access before it is created, so it needs an identity that already exists."
  }
  assert {
    condition     = length(azurerm_user_assigned_identity.this) == 1
    error_message = "The identity should still be created for a cluster on an existing network."
  }
}

run "base_without_a_network_keeps_the_user_assigned_identity" {
  command = plan

  variables {
    virtual_network_name = null
    node_subnet_name     = null
  }

  assert {
    condition     = length(azurerm_user_assigned_identity.this) == 1
    error_message = "Only the Automatic SKU is refused a user assigned identity on a managed network."
  }
}

# The zone has to be granted to a principal that exists before the cluster, and a system assigned
# identity does not. Terraform warns rather than refusing - Azure creates the cluster either way,
# and it is the DNS registration that suffers.
run "warns_about_a_byo_private_dns_zone_with_no_identity_to_grant_it" {
  command = plan

  variables {
    sku_name                = "Automatic"
    sku_tier                = "Standard"
    virtual_network_name    = null
    node_subnet_name        = null
    private_cluster_enabled = true
    private_dns_zone_name   = "privatelink.swedencentral.azmk8s.io"
  }

  expect_failures = [check.byo_private_dns_zone_has_an_identity_to_grant]

  assert {
    condition     = length(azurerm_role_assignment.private_dns_zone_contributor) == 0
    error_message = "There is no principal to grant the zone to before the cluster exists."
  }
  assert {
    condition     = length(time_sleep.role_assignment_propagation) == 0
    error_message = "With no assignments created there is nothing to wait for."
  }
}

# A bring-your-own private DNS zone is still reachable without a network of your own - it is the
# private cluster that needs it, not the subnets - so the grant on the zone survives.
run "a_cluster_without_a_network_still_grants_the_private_dns_zone" {
  command = plan

  variables {
    virtual_network_name  = null
    node_subnet_name      = null
    private_dns_zone_name = "privatelink.swedencentral.azmk8s.io"
  }

  assert {
    condition     = length(azurerm_role_assignment.private_dns_zone_contributor) == 1
    error_message = "The zone lives outside the network, so the cluster identity should still be granted it."
  }
  assert {
    condition     = length(time_sleep.role_assignment_propagation) == 1
    error_message = "There is an assignment to wait for, even with no network assignments."
  }
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

# ----------------------------------------------------------------------------------------------
# Managed namespaces
# ----------------------------------------------------------------------------------------------

run "a_cluster_with_no_managed_namespaces_creates_none" {
  command = plan

  assert {
    condition     = length(azapi_resource.managed_namespace) == 0
    error_message = "Namespaces are opt-in; an environment that lists none should get none."
  }
}

# Listing the names is the whole of it: everything else comes from managed_namespace_defaults.
run "a_namespace_closes_ingress_to_itself_and_leaves_egress_open" {
  command = plan

  variables {
    managed_namespaces = {
      team-payments = {}
      team-search   = {}
    }
  }

  assert {
    condition     = toset(keys(azapi_resource.managed_namespace)) == toset(["team-payments", "team-search"])
    error_message = "Every name listed in managed_namespaces should get a namespace of its own."
  }
  assert {
    condition     = azapi_resource.managed_namespace["team-payments"].name == "team-payments"
    error_message = "The namespace is named by the key, not by anything derived from it."
  }
  assert {
    condition     = azapi_resource.managed_namespace["team-payments"].parent_id == module.aks.resource_id
    error_message = "A managed namespace belongs to the cluster."
  }
  assert {
    condition     = azapi_resource.managed_namespace["team-payments"].type == "Microsoft.ContainerService/managedClusters/managedNamespaces@2026-03-01"
    error_message = "The namespace should use the same AKS API version as everything else written directly."
  }
  assert {
    condition = alltrue([
      for namespace in azapi_resource.managed_namespace :
      namespace.body.properties.defaultNetworkPolicy.ingress == "AllowSameNamespace"
    ])
    error_message = "By default only pods of the same namespace should be able to reach into it."
  }
  assert {
    condition = alltrue([
      for namespace in azapi_resource.managed_namespace :
      namespace.body.properties.defaultNetworkPolicy.egress == "AllowAll"
    ])
    error_message = "By default a workload should be able to reach out without further ado."
  }
}

# What a namespace says nothing about is left out of the body rather than sent as null: AzAPI tracks
# only the keys the body declares, and a key sent as null differs from whatever Azure answers with.
# The quota is the exception - Azure requires one - and has a run of its own further down.
run "a_namespace_nobody_gave_labels_to_is_sent_none" {
  command = plan

  variables {
    managed_namespaces = {
      team-payments = {}
    }
  }

  # The pod security labels are always there - a namespace is held to the estate standard whether or
  # not it says anything - so what is checked here is that nothing else came along with them.
  assert {
    condition = toset(keys(azapi_resource.managed_namespace["team-payments"].body.properties.labels)) == toset([
      "pod-security.kubernetes.io/audit",
      "pod-security.kubernetes.io/audit-version",
      "pod-security.kubernetes.io/enforce",
      "pod-security.kubernetes.io/enforce-version",
      "pod-security.kubernetes.io/warn",
      "pod-security.kubernetes.io/warn-version",
    ])
    error_message = "No labels were asked for, so only the pod security ones should be sent."
  }
  assert {
    condition     = !can(azapi_resource.managed_namespace["team-payments"].body.properties.annotations)
    error_message = "No annotations were asked for, so none should be sent."
  }
}

# Nothing is deleted or taken over behind anyone's back: an existing namespace of the same name
# fails the apply, and dropping the entry again leaves the Kubernetes namespace standing.
run "a_namespace_neither_adopts_nor_deletes_by_default" {
  command = plan

  variables {
    managed_namespaces = {
      team-payments = {}
    }
  }

  assert {
    condition     = azapi_resource.managed_namespace["team-payments"].body.properties.adoptionPolicy == "Never"
    error_message = "A namespace that already exists should stop the apply rather than be taken over."
  }
  assert {
    condition     = azapi_resource.managed_namespace["team-payments"].body.properties.deletePolicy == "Keep"
    error_message = "Dropping a line from a variables file should not delete a running workload."
  }
}

run "a_namespace_overrides_only_the_defaults_it_names" {
  command = plan

  variables {
    managed_namespaces = {
      team-payments = {
        network_policy = { ingress = "AllowAll" }
      }
      team-search = {
        network_policy = { egress = "AllowSameNamespace" }
      }
    }
  }

  assert {
    condition     = azapi_resource.managed_namespace["team-payments"].body.properties.defaultNetworkPolicy.ingress == "AllowAll"
    error_message = "A namespace that opens ingress should get what it asked for."
  }
  assert {
    condition     = azapi_resource.managed_namespace["team-payments"].body.properties.defaultNetworkPolicy.egress == "AllowAll"
    error_message = "Overriding ingress should leave egress on the default."
  }
  assert {
    condition     = azapi_resource.managed_namespace["team-search"].body.properties.defaultNetworkPolicy.egress == "AllowSameNamespace"
    error_message = "A namespace that confines egress should get what it asked for."
  }
  assert {
    condition     = azapi_resource.managed_namespace["team-search"].body.properties.defaultNetworkPolicy.ingress == "AllowSameNamespace"
    error_message = "Overriding egress should leave ingress on the default."
  }
}

# One place to move a whole cluster at once, rather than repeating the same override per namespace.
run "the_estate_wide_defaults_move_every_namespace_that_says_nothing" {
  command = plan

  variables {
    managed_namespace_defaults = {
      adoption_policy = "IfIdentical"
      delete_policy   = "Delete"
      network_policy  = { egress = "DenyAll" }
      resource_quota  = { cpu_limit = "2", memory_limit = "4Gi" }
    }
    managed_namespaces = {
      team-payments = {}
      team-search = {
        network_policy = { egress = "AllowAll" }
      }
    }
  }

  assert {
    condition     = azapi_resource.managed_namespace["team-payments"].body.properties.defaultNetworkPolicy.egress == "DenyAll"
    error_message = "A namespace that says nothing should follow the estate-wide default."
  }
  assert {
    condition     = azapi_resource.managed_namespace["team-search"].body.properties.defaultNetworkPolicy.egress == "AllowAll"
    error_message = "A namespace that says otherwise should still win over the default."
  }
  assert {
    condition     = azapi_resource.managed_namespace["team-payments"].body.properties.defaultNetworkPolicy.ingress == "AllowSameNamespace"
    error_message = "Changing the default egress should leave the default ingress alone."
  }
  assert {
    condition = alltrue([
      for namespace in azapi_resource.managed_namespace :
      namespace.body.properties.adoptionPolicy == "IfIdentical" && namespace.body.properties.deletePolicy == "Delete"
    ])
    error_message = "The adoption and delete policies should follow the defaults as well."
  }
  assert {
    condition     = keys(azapi_resource.managed_namespace["team-payments"].body.properties.defaultResourceQuota) == ["cpuLimit", "cpuRequest", "memoryLimit", "memoryRequest"]
    error_message = "The default quota should reach every namespace, all four figures of it."
  }
  assert {
    condition = alltrue([
      azapi_resource.managed_namespace["team-payments"].body.properties.defaultResourceQuota.cpuLimit == "2000m",
      azapi_resource.managed_namespace["team-payments"].body.properties.defaultResourceQuota.memoryLimit == "4Gi",
    ])
    error_message = "The figures the defaults do name should reach the namespace, the CPU one as milliCPU."
  }
}

run "a_namespace_takes_the_quota_figures_it_names_and_the_defaults_for_the_rest" {
  command = plan

  variables {
    managed_namespace_defaults = {
      resource_quota = { cpu_limit = "2", memory_limit = "4Gi" }
    }
    managed_namespaces = {
      team-search = {
        resource_quota = { cpu_limit = "8", memory_request = "1Gi" }
      }
    }
  }

  assert {
    condition     = azapi_resource.managed_namespace["team-search"].body.properties.defaultResourceQuota.cpuRequest == "500m"
    error_message = "Neither side named a CPU request, so the built-in default should fill it in - Azure takes no namespace without one."
  }
  assert {
    condition = alltrue([
      azapi_resource.managed_namespace["team-search"].body.properties.defaultResourceQuota.cpuLimit == "8000m",
      azapi_resource.managed_namespace["team-search"].body.properties.defaultResourceQuota.memoryLimit == "4Gi",
      azapi_resource.managed_namespace["team-search"].body.properties.defaultResourceQuota.memoryRequest == "1Gi",
    ])
    error_message = "A namespace should override the figures it names and inherit the ones it does not."
  }
}

# Azure requires the quota on a managed namespace even though the API spec marks it optional: a
# namespace that arrives without one is refused with "The managed namespace CPU request number is
# not valid". A namespace that names nothing at all still has to carry all four figures.
run "a_namespace_that_names_no_quota_still_gets_a_whole_one" {
  command = plan

  variables {
    managed_namespaces = {
      team-payments = {}
    }
  }

  assert {
    condition     = keys(azapi_resource.managed_namespace["team-payments"].body.properties.defaultResourceQuota) == ["cpuLimit", "cpuRequest", "memoryLimit", "memoryRequest"]
    error_message = "A namespace with no quota of its own should still be sent all four figures."
  }
  assert {
    condition = alltrue([
      azapi_resource.managed_namespace["team-payments"].body.properties.defaultResourceQuota.cpuLimit == "2000m",
      azapi_resource.managed_namespace["team-payments"].body.properties.defaultResourceQuota.cpuRequest == "500m",
      azapi_resource.managed_namespace["team-payments"].body.properties.defaultResourceQuota.memoryLimit == "4Gi",
      azapi_resource.managed_namespace["team-payments"].body.properties.defaultResourceQuota.memoryRequest == "1Gi",
    ])
    error_message = "The built-in quota should be the documented one, with the CPU figures in milliCPU."
  }
}

# Azure refuses a quota that states CPU in anything but milliCPU, while a manifest writes the same
# figure either way. Whichever form the variables name it in, what leaves here is milliCPU.
run "cpu_quota_figures_reach_azure_as_millicpu" {
  command = plan

  variables {
    managed_namespace_defaults = {
      resource_quota = { cpu_request = "0.5" }
    }
    managed_namespaces = {
      team-payments = {
        resource_quota = { cpu_limit = "2" }
      }
      # Named in milliCPU on both sides, which is the form Azure takes.
      team-search = {
        resource_quota = { cpu_limit = "1500m", cpu_request = "0.125" }
      }
    }
  }

  assert {
    condition = alltrue([
      azapi_resource.managed_namespace["team-payments"].body.properties.defaultResourceQuota.cpuLimit == "2000m",
      azapi_resource.managed_namespace["team-payments"].body.properties.defaultResourceQuota.cpuRequest == "500m",
    ])
    error_message = "Whole and fractional cores should be sent as the milliCPU figure they mean."
  }
  assert {
    condition = alltrue([
      azapi_resource.managed_namespace["team-search"].body.properties.defaultResourceQuota.cpuLimit == "1500m",
      azapi_resource.managed_namespace["team-search"].body.properties.defaultResourceQuota.cpuRequest == "125m",
    ])
    error_message = "A figure already written in milliCPU should be sent as it stands."
  }
}

# Labels and annotations are added to rather than replaced, so an estate-wide set survives a
# namespace adding one of its own.
run "namespace_labels_and_annotations_merge_with_the_defaults" {
  command = plan

  variables {
    managed_namespace_defaults = {
      annotations = { "estate" = "prototype" }
      labels      = { "cost-centre" = "platform", "tier" = "shared" }
    }
    managed_namespaces = {
      team-search = {
        annotations = { "owner" = "search" }
        labels      = { "tier" = "dedicated" }
      }
    }
  }

  assert {
    condition = azapi_resource.managed_namespace["team-search"].body.properties.labels == tomap({
      "cost-centre"                                = "platform"
      "tier"                                       = "dedicated"
      "pod-security.kubernetes.io/audit"           = "restricted"
      "pod-security.kubernetes.io/audit-version"   = "latest"
      "pod-security.kubernetes.io/enforce"         = "restricted"
      "pod-security.kubernetes.io/enforce-version" = "latest"
      "pod-security.kubernetes.io/warn"            = "restricted"
      "pod-security.kubernetes.io/warn-version"    = "latest"
    })
    error_message = "A namespace should add to the default labels and win on the keys it repeats."
  }
  assert {
    condition = azapi_resource.managed_namespace["team-search"].body.properties.annotations == tomap({
      "estate" = "prototype"
      "owner"  = "search"
    })
    error_message = "Annotations should merge the same way the labels do."
  }
}

# A NetworkPolicy in a cluster with nothing to enforce it is an object nobody reads: the namespace
# looks closed in Azure and every pod in the cluster can still reach into it.
run "warns_about_restricted_namespaces_with_no_network_policy_engine" {
  command = plan

  variables {
    network_profile = {
      network_policy    = "none"
      network_dataplane = "azure"
    }
    managed_namespaces = {
      team-payments = {}
    }
  }

  expect_failures = [check.managed_namespaces_have_something_enforcing_their_network_policies]
}

run "a_namespace_open_in_both_directions_needs_no_engine_to_enforce_it" {
  command = plan

  variables {
    network_profile = {
      network_policy    = "none"
      network_dataplane = "azure"
    }
    managed_namespaces = {
      team-payments = {
        network_policy = { egress = "AllowAll", ingress = "AllowAll" }
      }
    }
  }

  assert {
    condition     = length(local.managed_namespaces_relying_on_network_policy) == 0
    error_message = "A namespace that restricts nothing has nothing for an engine to enforce."
  }
}

# AKS Automatic runs Cilium whatever network_profile says, and is sent no network profile at all on
# loadBalancer egress - so the warning must not fire on it.
run "automatic_enforces_network_policies_whatever_the_profile_says" {
  command = plan

  variables {
    sku_name                = "Automatic"
    sku_tier                = "Standard"
    api_server_subnet_name  = "snet-aks-apiserver"
    system_node_subnet_name = "snet-aks-system"
    network_profile = {
      network_policy    = "none"
      network_dataplane = "azure"
      pod_cidr          = "100.201.0.0/16"
      service_cidr      = "100.202.0.0/16"
      dns_service_ip    = "100.202.0.10"
      outbound_type     = "userDefinedRouting"
    }
    managed_namespaces = {
      team-payments = {}
    }
  }

  assert {
    condition     = local.network_policy_engine_enabled
    error_message = "An Automatic cluster always runs Cilium, so its namespaces are enforced."
  }
}

run "rejects_a_namespace_name_kubernetes_reserves" {
  command = plan

  variables {
    managed_namespaces = {
      kube-payments = {}
    }
  }

  expect_failures = [var.managed_namespaces]
}

run "rejects_a_system_namespace_aks_will_not_hand_over" {
  command = plan

  variables {
    managed_namespaces = {
      gatekeeper-system = {}
    }
  }

  expect_failures = [var.managed_namespaces]
}

run "rejects_a_namespace_name_kubernetes_would_refuse" {
  command = plan

  variables {
    managed_namespaces = {
      Team_Payments = {}
    }
  }

  expect_failures = [var.managed_namespaces]
}

run "rejects_a_network_policy_rule_azure_does_not_have" {
  command = plan

  variables {
    managed_namespaces = {
      team-payments = {
        network_policy = { ingress = "AllowSameCluster" }
      }
    }
  }

  expect_failures = [var.managed_namespaces]
}

run "rejects_a_delete_policy_azure_does_not_have" {
  command = plan

  variables {
    managed_namespaces = {
      team-payments = {
        delete_policy = "Retain"
      }
    }
  }

  expect_failures = [var.managed_namespaces]
}

run "rejects_a_quota_that_is_not_a_kubernetes_quantity" {
  command = plan

  variables {
    managed_namespaces = {
      team-payments = {
        resource_quota = { memory_limit = "4GB" }
      }
    }
  }

  expect_failures = [var.managed_namespaces]
}

run "rejects_a_cpu_quota_azure_cannot_hold" {
  command = plan

  variables {
    managed_namespaces = {
      # Finer than the milliCPU Azure counts in, which would otherwise be quietly rounded away.
      team-payments = {
        resource_quota = { cpu_limit = "0.0005" }
      }
    }
  }

  expect_failures = [var.managed_namespaces]
}

run "rejects_a_cpu_quota_of_nothing_at_all" {
  command = plan

  variables {
    managed_namespace_defaults = {
      # Azure takes nothing below 1m, and a quota of zero CPU is not what anybody meant by it.
      resource_quota = { cpu_request = "0" }
    }
  }

  expect_failures = [var.managed_namespace_defaults]
}

run "rejects_estate_wide_defaults_azure_does_not_have" {
  command = plan

  variables {
    managed_namespace_defaults = {
      network_policy = { egress = "AllowSameCluster" }
    }
  }

  expect_failures = [var.managed_namespace_defaults]
}

# ----------------------------------------------------------------------------------------------
# Namespace-scoped access
# ----------------------------------------------------------------------------------------------

run "a_namespace_grants_nothing_unless_it_is_asked_to" {
  command = plan

  variables {
    managed_namespaces = {
      team-payments = {}
    }
  }

  assert {
    condition     = length(azurerm_role_assignment.managed_namespace) == 0
    error_message = "A namespace with no access listed should hand nobody anything."
  }
}

# The grants land on the namespace resource, not on the cluster: that is what keeps a team out of
# the namespace next door.
run "namespace_access_is_scoped_to_the_namespace_it_was_listed_on" {
  command = plan

  variables {
    managed_namespaces = {
      team-payments = {
        access = [
          { role = "namespace_user", principal_id = "22222222-2222-2222-2222-222222222222" },
          { role = "writer", principal_id = "22222222-2222-2222-2222-222222222222" },
        ]
      }
      team-search = {
        access = [
          { role = "reader", principal_id = "33333333-3333-3333-3333-333333333333" },
        ]
      }
    }
  }

  assert {
    condition = toset(keys(azurerm_role_assignment.managed_namespace)) == toset([
      "team-payments/namespace_user/22222222-2222-2222-2222-222222222222",
      "team-payments/writer/22222222-2222-2222-2222-222222222222",
      "team-search/reader/33333333-3333-3333-3333-333333333333",
    ])
    error_message = "A grant should be addressed by what it grants, so that reordering the list churns nothing."
  }
  # The namespace IDs are only known after the apply, so they are overridden here to pin down that a
  # grant is scoped to its own namespace rather than to the cluster or to the namespace next door.
  override_resource {
    target          = azapi_resource.managed_namespace["team-search"]
    override_during = plan
    values = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aks-test/providers/Microsoft.ContainerService/managedClusters/aks-test/managedNamespaces/team-search"
    }
  }

  assert {
    condition     = azurerm_role_assignment.managed_namespace["team-search/reader/33333333-3333-3333-3333-333333333333"].scope == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aks-test/providers/Microsoft.ContainerService/managedClusters/aks-test/managedNamespaces/team-search"
    error_message = "A grant belongs to the namespace it was listed on, not to the cluster."
  }
  assert {
    condition = alltrue([
      azurerm_role_assignment.managed_namespace["team-payments/namespace_user/22222222-2222-2222-2222-222222222222"].role_definition_name == "Azure Kubernetes Service Namespace User",
      azurerm_role_assignment.managed_namespace["team-payments/writer/22222222-2222-2222-2222-222222222222"].role_definition_name == "Azure Kubernetes Service RBAC Writer",
      azurerm_role_assignment.managed_namespace["team-search/reader/33333333-3333-3333-3333-333333333333"].role_definition_name == "Azure Kubernetes Service RBAC Reader",
    ])
    error_message = "Each short role name should reach Azure as the built-in role it stands for."
  }
}

run "the_admin_role_is_the_namespace_one_and_not_the_cluster_one" {
  command = plan

  variables {
    managed_namespaces = {
      team-payments = {
        access = [
          { role = "admin", principal_id = "22222222-2222-2222-2222-222222222222" },
        ]
      }
    }
  }

  assert {
    condition     = azurerm_role_assignment.managed_namespace["team-payments/admin/22222222-2222-2222-2222-222222222222"].role_definition_name == "Azure Kubernetes Service RBAC Admin"
    error_message = "A namespace admin should not be handed cluster admin by accident."
  }
}

# A group is the usual case, but a pipeline is a service principal and Azure has to be told which is
# which rather than being left to look the principal up.
run "a_service_principal_is_granted_as_one" {
  command = plan

  variables {
    managed_namespaces = {
      team-payments = {
        access = [
          { role = "writer", principal_id = "22222222-2222-2222-2222-222222222222" },
          { role = "writer", principal_id = "44444444-4444-4444-4444-444444444444", principal_type = "ServicePrincipal" },
          { role = "reader", principal_id = "55555555-5555-5555-5555-555555555555", principal_type = "User" },
        ]
      }
    }
  }

  assert {
    condition     = azurerm_role_assignment.managed_namespace["team-payments/writer/22222222-2222-2222-2222-222222222222"].principal_type == "Group"
    error_message = "A grant that says nothing about the principal should be a group."
  }
  assert {
    condition     = azurerm_role_assignment.managed_namespace["team-payments/writer/44444444-4444-4444-4444-444444444444"].principal_type == "ServicePrincipal"
    error_message = "A service principal should be granted as a service principal."
  }
  assert {
    condition     = azurerm_role_assignment.managed_namespace["team-payments/reader/55555555-5555-5555-5555-555555555555"].principal_type == "User"
    error_message = "A user should be granted as a user."
  }
}

run "namespace_access_is_left_to_someone_else_when_assignments_are" {
  command = plan

  variables {
    create_role_assignments = false
    managed_namespaces = {
      team-payments = {
        access = [
          { role = "writer", principal_id = "22222222-2222-2222-2222-222222222222" },
        ]
      }
    }
  }

  assert {
    condition     = length(azurerm_role_assignment.managed_namespace) == 0
    error_message = "An estate with role assignments managed elsewhere should get these from there too."
  }

  expect_failures = [check.namespace_access_is_granted_somewhere]
}

# The data plane roles are Azure RBAC roles; a cluster on Kubernetes RBAC never consults them.
run "warns_about_namespace_data_plane_roles_without_azure_rbac" {
  command = plan

  variables {
    azure_rbac_enabled = false
    managed_namespaces = {
      team-payments = {
        access = [
          { role = "writer", principal_id = "22222222-2222-2222-2222-222222222222" },
        ]
      }
    }
  }

  expect_failures = [check.namespace_access_needs_azure_rbac]
}

# namespace_user is a control plane role on the Azure resource, so it works either way.
run "a_namespace_user_grant_needs_no_azure_rbac" {
  command = plan

  variables {
    azure_rbac_enabled = false
    managed_namespaces = {
      team-payments = {
        access = [
          { role = "namespace_user", principal_id = "22222222-2222-2222-2222-222222222222" },
        ]
      }
    }
  }

  assert {
    condition     = length(local.managed_namespace_data_plane_grants) == 0
    error_message = "namespace_user is granted on the Azure resource, not through Kubernetes authorization."
  }
  assert {
    condition     = length(azurerm_role_assignment.managed_namespace) == 1
    error_message = "The grant should still be made."
  }
}

run "rejects_a_namespace_role_azure_does_not_have" {
  command = plan

  variables {
    managed_namespaces = {
      team-payments = {
        access = [
          { role = "cluster_admin", principal_id = "22222222-2222-2222-2222-222222222222" },
        ]
      }
    }
  }

  expect_failures = [var.managed_namespaces]
}

run "rejects_a_namespace_grant_to_a_principal_type_azure_does_not_have" {
  command = plan

  variables {
    managed_namespaces = {
      team-payments = {
        access = [
          { role = "writer", principal_id = "22222222-2222-2222-2222-222222222222", principal_type = "ManagedIdentity" },
        ]
      }
    }
  }

  expect_failures = [var.managed_namespaces]
}

run "rejects_a_namespace_grant_named_after_a_group_instead_of_its_object_id" {
  command = plan

  variables {
    managed_namespaces = {
      team-payments = {
        access = [
          { role = "writer", principal_id = "aks-payments-writers" },
        ]
      }
    }
  }

  expect_failures = [var.managed_namespaces]
}

# Two identical grants would collide on the address they are keyed by, which Terraform reports as
# something rather harder to read than this.
run "rejects_the_same_grant_listed_twice_in_one_namespace" {
  command = plan

  variables {
    managed_namespaces = {
      team-payments = {
        access = [
          { role = "writer", principal_id = "22222222-2222-2222-2222-222222222222" },
          { role = "writer", principal_id = "22222222-2222-2222-2222-222222222222", principal_type = "Group" },
        ]
      }
    }
  }

  expect_failures = [var.managed_namespaces]
}

# The same principal in two namespaces is two grants, not a collision.
run "the_same_principal_can_be_granted_in_more_than_one_namespace" {
  command = plan

  variables {
    managed_namespaces = {
      team-payments = {
        access = [{ role = "writer", principal_id = "22222222-2222-2222-2222-222222222222" }]
      }
      team-search = {
        access = [{ role = "writer", principal_id = "22222222-2222-2222-2222-222222222222" }]
      }
    }
  }

  assert {
    condition     = length(azurerm_role_assignment.managed_namespace) == 2
    error_message = "A principal granted in two namespaces should get one assignment in each."
  }
}

# ----------------------------------------------------------------------------------------------
# Pod Security Standards
# ----------------------------------------------------------------------------------------------

# The labels the API server's Pod Security Admission controller reads. Nothing else is involved:
# admission is built into the API server, so a labelled namespace is an enforced one.
run "a_namespace_is_held_to_the_restricted_standard_by_default" {
  command = plan

  variables {
    managed_namespaces = {
      team-payments = {}
    }
  }

  assert {
    condition = azapi_resource.managed_namespace["team-payments"].body.properties.labels == tomap({
      "pod-security.kubernetes.io/audit"           = "restricted"
      "pod-security.kubernetes.io/audit-version"   = "latest"
      "pod-security.kubernetes.io/enforce"         = "restricted"
      "pod-security.kubernetes.io/enforce-version" = "latest"
      "pod-security.kubernetes.io/warn"            = "restricted"
      "pod-security.kubernetes.io/warn-version"    = "latest"
    })
    error_message = "A namespace that says nothing should enforce, audit and warn at restricted."
  }
}

# Relaxing enforce is the exception; audit and warn stay put, so the pods that break the standard
# are still recorded and still warn whoever applies them.
run "an_exception_relaxes_only_what_it_names" {
  command = plan

  variables {
    managed_namespaces = {
      observability = {
        pod_security = { enforce = "privileged" }
      }
    }
  }

  assert {
    condition     = azapi_resource.managed_namespace["observability"].body.properties.labels["pod-security.kubernetes.io/enforce"] == "privileged"
    error_message = "A namespace that cannot meet the standard should be able to say so."
  }
  assert {
    condition = alltrue([
      azapi_resource.managed_namespace["observability"].body.properties.labels["pod-security.kubernetes.io/audit"] == "restricted",
      azapi_resource.managed_namespace["observability"].body.properties.labels["pod-security.kubernetes.io/warn"] == "restricted",
    ])
    error_message = "An exception should stay visible: relaxing enforce must not drag audit and warn down with it."
  }
  assert {
    condition     = length(local.managed_namespaces_with_silent_pod_security_exceptions) == 0
    error_message = "An exception that is still audited is not a silent one."
  }
}

run "a_mode_set_to_none_leaves_its_label_off_entirely" {
  command = plan

  variables {
    managed_namespaces = {
      team-payments = {
        pod_security = { warn = "none" }
      }
    }
  }

  assert {
    condition     = !can(azapi_resource.managed_namespace["team-payments"].body.properties.labels["pod-security.kubernetes.io/warn"])
    error_message = "A mode nobody wants should leave no label rather than an empty one."
  }
  assert {
    condition     = !can(azapi_resource.managed_namespace["team-payments"].body.properties.labels["pod-security.kubernetes.io/warn-version"])
    error_message = "The version label goes with the mode it belongs to."
  }
  assert {
    condition     = azapi_resource.managed_namespace["team-payments"].body.properties.labels["pod-security.kubernetes.io/enforce"] == "restricted"
    error_message = "Turning off the warning should leave enforcement alone."
  }
}

# `latest` follows the cluster, so an upgrade can tighten the standard under a running workload.
run "the_standard_can_be_pinned_to_a_kubernetes_version" {
  command = plan

  variables {
    managed_namespace_defaults = {
      pod_security = { version = "v1.31" }
    }
    managed_namespaces = {
      team-payments = {}
      team-search = {
        pod_security = { version = "v1.30" }
      }
    }
  }

  assert {
    condition     = azapi_resource.managed_namespace["team-payments"].body.properties.labels["pod-security.kubernetes.io/enforce-version"] == "v1.31"
    error_message = "A pinned estate-wide version should reach every namespace."
  }
  assert {
    condition     = azapi_resource.managed_namespace["team-search"].body.properties.labels["pod-security.kubernetes.io/enforce-version"] == "v1.30"
    error_message = "A namespace should be able to hold a version of its own."
  }
}

run "the_estate_wide_standard_can_be_lowered_for_a_whole_cluster" {
  command = plan

  variables {
    managed_namespace_defaults = {
      pod_security = { audit = "restricted", enforce = "baseline", warn = "baseline" }
    }
    managed_namespaces = {
      team-payments = {}
    }
  }

  assert {
    condition = alltrue([
      azapi_resource.managed_namespace["team-payments"].body.properties.labels["pod-security.kubernetes.io/enforce"] == "baseline",
      azapi_resource.managed_namespace["team-payments"].body.properties.labels["pod-security.kubernetes.io/warn"] == "baseline",
      azapi_resource.managed_namespace["team-payments"].body.properties.labels["pod-security.kubernetes.io/audit"] == "restricted",
    ])
    error_message = "One place should move the standard for the whole cluster."
  }
}

# The labels sit alongside whatever else the namespace carries, rather than replacing it.
run "pod_security_labels_join_the_labels_a_namespace_already_has" {
  command = plan

  variables {
    managed_namespace_defaults = {
      labels = { "cost-centre" = "platform" }
    }
    managed_namespaces = {
      team-payments = {
        labels = { "team" = "payments" }
      }
    }
  }

  assert {
    condition = azapi_resource.managed_namespace["team-payments"].body.properties.labels == tomap({
      "cost-centre"                                = "platform"
      "team"                                       = "payments"
      "pod-security.kubernetes.io/audit"           = "restricted"
      "pod-security.kubernetes.io/audit-version"   = "latest"
      "pod-security.kubernetes.io/enforce"         = "restricted"
      "pod-security.kubernetes.io/enforce-version" = "latest"
      "pod-security.kubernetes.io/warn"            = "restricted"
      "pod-security.kubernetes.io/warn-version"    = "latest"
    })
    error_message = "The pod security labels should be added to the namespace labels, not replace them."
  }
}

# An exception is fine. An exception nobody can see is what this warns about.
run "warns_about_an_exception_that_is_neither_enforced_nor_recorded" {
  command = plan

  variables {
    managed_namespaces = {
      observability = {
        pod_security = { audit = "none", enforce = "privileged", warn = "none" }
      }
    }
  }

  expect_failures = [check.pod_security_exceptions_stay_on_the_record]
}

run "an_exception_recorded_by_warn_alone_is_not_warned_about" {
  command = plan

  variables {
    managed_namespaces = {
      observability = {
        pod_security = { audit = "none", enforce = "privileged" }
      }
    }
  }

  assert {
    condition     = length(local.managed_namespaces_with_silent_pod_security_exceptions) == 0
    error_message = "Either audit or warn at the estate standard is enough to keep an exception visible."
  }
}

# Nothing was relaxed, so there is no exception to record - even with audit and warn turned off.
run "a_namespace_at_the_estate_standard_needs_no_record_of_an_exception" {
  command = plan

  variables {
    managed_namespaces = {
      team-payments = {
        pod_security = { audit = "none", warn = "none" }
      }
    }
  }

  assert {
    condition     = length(local.managed_namespaces_with_silent_pod_security_exceptions) == 0
    error_message = "A namespace that still enforces the estate standard has made no exception."
  }
}

run "rejects_a_pod_security_level_kubernetes_does_not_have" {
  command = plan

  variables {
    managed_namespaces = {
      team-payments = {
        pod_security = { enforce = "hardened" }
      }
    }
  }

  expect_failures = [var.managed_namespaces]
}

run "rejects_a_pod_security_version_that_is_not_one" {
  command = plan

  variables {
    managed_namespaces = {
      team-payments = {
        pod_security = { version = "1.31" }
      }
    }
  }

  expect_failures = [var.managed_namespaces]
}

# One place decides the standard, so a hand-written label cannot contradict pod_security.
run "rejects_a_pod_security_label_written_by_hand" {
  command = plan

  variables {
    managed_namespaces = {
      team-payments = {
        labels = { "pod-security.kubernetes.io/enforce" = "privileged" }
      }
    }
  }

  expect_failures = [var.managed_namespaces]
}

run "rejects_a_pod_security_label_written_by_hand_in_the_defaults" {
  command = plan

  variables {
    managed_namespace_defaults = {
      labels = { "pod-security.kubernetes.io/enforce" = "privileged" }
    }
  }

  expect_failures = [var.managed_namespace_defaults]
}

run "rejects_an_estate_wide_pod_security_level_kubernetes_does_not_have" {
  command = plan

  variables {
    managed_namespace_defaults = {
      pod_security = { enforce = "hardened" }
    }
  }

  expect_failures = [var.managed_namespace_defaults]
}
