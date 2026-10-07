# Plan-time behaviour of the Application Gateway Ingress Controller add-on, with the providers mocked
# as in aks.tftest.hcl.
#
#   terraform test

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
      id               = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aks-test/providers/Microsoft.Network/virtualNetworks/vnet-aks-test/subnets/snet-aks-nodes"
      address_prefixes = ["172.19.0.0/24"]
    }
  }
  mock_data "azurerm_application_gateway" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-agw-test/providers/Microsoft.Network/applicationGateways/agw-aks-test"
      gateway_ip_configuration = [{
        id        = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-agw-test/providers/Microsoft.Network/applicationGateways/agw-aks-test/gatewayIPConfigurations/gateway"
        name      = "gateway"
        subnet_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aks-test/providers/Microsoft.Network/virtualNetworks/vnet-aks-test/subnets/snet-agw"
      }]
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

override_module {
  target = module.aks
  outputs = {
    resource_id                    = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aks-test/providers/Microsoft.ContainerService/managedClusters/aks-test"
    ingress_app_object_id          = "66666666-6666-6666-6666-666666666666"
    oidc_issuer_profile_issuer_url = "https://swedencentral.oic.prod-aks.azure.com/00000000-0000-0000-0000-000000000000/11111111-1111-1111-1111-111111111111/"
    ingress_profile_application_load_balancer_identity = {
      clientId   = "33333333-3333-3333-3333-333333333333"
      objectId   = "44444444-4444-4444-4444-444444444444"
      resourceId = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/MC_rg-aks-test_aks-test_swedencentral/providers/Microsoft.ManagedIdentity/userAssignedIdentities/applicationloadbalancer-aks-test"
    }
  }
}

variables {
  application_gateway_for_containers_subnet_name = "snet-aks-alb"
  location                                       = "swedencentral"
  name                                           = "aks-test"
  node_subnet_name                               = "snet-aks-nodes"
  resource_group_name                            = "rg-aks-test"
  virtual_network_name                           = "vnet-aks-test"
}

run "the_ingress_controller_is_off_unless_asked_for" {
  command = plan

  assert {
    condition = alltrue([
      length(data.azurerm_application_gateway.ingress) == 0,
      length(azurerm_role_assignment.application_gateway_ingress_controller) == 0,
      output.application_gateway_ingress_controller_identity_principal_id == null,
    ])
    error_message = "Without application_gateway_ingress_controller no gateway should be looked up and nothing granted."
  }
}

run "the_ingress_controller_identity_is_granted_the_gateway" {
  command = plan

  variables {
    application_gateway_ingress_controller = {
      application_gateway_name = "agw-aks-test"
      resource_group_name      = "rg-agw-test"
    }
  }

  assert {
    condition = alltrue([
      data.azurerm_application_gateway.ingress[0].resource_group_name == "rg-agw-test",
      length(azurerm_role_assignment.application_gateway_ingress_controller) == 3,
      alltrue([for assignment in azurerm_role_assignment.application_gateway_ingress_controller : assignment.principal_id == "66666666-6666-6666-6666-666666666666"]),
      azurerm_role_assignment.application_gateway_ingress_controller["gateway"].role_definition_name == "Contributor",
      azurerm_role_assignment.application_gateway_ingress_controller["gateway"].scope == data.azurerm_application_gateway.ingress[0].id,
      azurerm_role_assignment.application_gateway_ingress_controller["resource_group"].role_definition_name == "Reader",
      azurerm_role_assignment.application_gateway_ingress_controller["resource_group"].scope == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-agw-test",
      azurerm_role_assignment.application_gateway_ingress_controller["subnet"].role_definition_name == "Network Contributor",
      azurerm_role_assignment.application_gateway_ingress_controller["subnet"].scope == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aks-test/providers/Microsoft.Network/virtualNetworks/vnet-aks-test/subnets/snet-agw",
      output.application_gateway_ingress_controller_identity_principal_id == "66666666-6666-6666-6666-666666666666",
    ])
    error_message = "The add-on identity should be granted Contributor on the gateway, Reader on its resource group and Network Contributor on its subnet."
  }
}

run "the_gateway_defaults_to_the_cluster_resource_group" {
  command = plan

  variables {
    application_gateway_ingress_controller = {
      application_gateway_name = "agw-aks-test"
    }
  }

  assert {
    condition     = data.azurerm_application_gateway.ingress[0].resource_group_name == "rg-aks-test"
    error_message = "The gateway should be looked up in resource_group_name when no resource group is given for it."
  }
}

run "no_gateway_grant_is_left_to_someone_else" {
  command = plan

  variables {
    application_gateway_ingress_controller = {
      application_gateway_name = "agw-aks-test"
    }
    create_role_assignments = false
  }

  assert {
    condition     = length(azurerm_role_assignment.application_gateway_ingress_controller) == 0
    error_message = "With create_role_assignments = false the gateway grants belong to whoever manages the estate's role assignments."
  }
}
