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
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aks-test/providers/Microsoft.Network/virtualNetworks/vnet-aks-test"
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

run "automatic_grants_every_subnet_it_uses" {
  command = plan

  variables {
    sku_name                = "Automatic"
    sku_tier                = "Standard"
    api_server_subnet_name  = "snet-aks-apiserver"
    system_node_subnet_name = "snet-aks-system"
  }

  assert {
    condition     = length(azurerm_role_assignment.network_contributor) == 3
    error_message = "AKS Automatic uses a node, a system node and an API server subnet, and needs access to all three."
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

run "rejects_automatic_without_the_subnets_it_requires" {
  command = plan

  variables {
    sku_name = "Automatic"
    sku_tier = "Standard"
  }

  expect_failures = [
    var.api_server_subnet_name,
    var.system_node_subnet_name,
  ]
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

run "rejects_defender_without_a_workspace_to_report_to" {
  command = plan

  variables {
    defender_enabled = true
  }

  expect_failures = [var.defender_enabled]
}
