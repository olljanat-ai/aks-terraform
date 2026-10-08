# Plan-time behaviour of the environment's shared resources, without touching Azure: the providers
# are mocked.
#
#   cd shared && terraform test

mock_provider "azurerm" {
  mock_data "azurerm_resource_group" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aks-test"
    }
  }
  mock_data "azurerm_client_config" {
    defaults = {
      tenant_id = "66666666-6666-6666-6666-666666666666"
    }
  }
  mock_data "azurerm_virtual_network" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-network/providers/Microsoft.Network/virtualNetworks/vnet-aks-test"
    }
  }
  mock_resource "azurerm_key_vault" {
    defaults = {
      id        = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aks-test/providers/Microsoft.KeyVault/vaults/kv-sec-test-shared"
      vault_uri = "https://kv-sec-test-shared.vault.azure.net/"
    }
  }
  mock_resource "azurerm_user_assigned_identity" {
    defaults = {
      id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aks-test/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-sec-test-shared-kv-example"
      principal_id = "11111111-1111-1111-1111-111111111111"
    }
  }
  mock_resource "azurerm_private_dns_zone" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aks-test/providers/Microsoft.Network/privateDnsZones/internal.contoso.com"
    }
  }
}
mock_provider "random" {}

variables {
  environment         = "test"
  location            = "swedencentral"
  resource_group_name = "rg-aks-test"
  key_vault_name      = "kv-sec-test-shared"
  key_vault_namespaces = {
    ingress-gateway = {}
    example = {
      writers = [{ principal_id = "33333333-3333-3333-3333-333333333333" }]
    }
  }
}

run "the_vault_and_the_identities_are_named_as_the_environments" {
  command = plan

  assert {
    condition = alltrue([
      azurerm_key_vault.this.name == "kv-sec-test-shared",
      azurerm_key_vault.this.resource_group_name == "rg-aks-test",
      azurerm_key_vault.this.rbac_authorization_enabled == true,
      azurerm_user_assigned_identity.key_vault["example"].name == "id-sec-test-shared-kv-example",
      azurerm_user_assigned_identity.key_vault["ingress-gateway"].name == "id-sec-test-shared-kv-ingress-gateway",
      azurerm_user_assigned_identity.key_vault["example"].resource_group_name == "rg-aks-test",
    ])
    error_message = "The vault and one identity per namespace should be created, named as the environment's shared ones."
  }
}

# The cluster configuration looks the identities up under names it works out itself - the two have to
# agree, which is what the shared module is for.
run "the_identity_names_are_the_ones_a_cluster_looks_for" {
  command = plan

  module {
    source = "../modules/conventions"
  }

  variables {
    environment          = "test"
    key_vault_namespaces = ["example"]
  }

  assert {
    condition     = output.shared_key_vault_identity_names["example"] == "id-sec-test-shared-kv-example"
    error_message = "The conventions should name the shared identity id-<region>-<environment>-shared-kv-<namespace>."
  }
}

run "each_namespace_reads_and_its_writers_manage_its_own_share" {
  command = plan

  assert {
    condition = alltrue([
      keys(azurerm_role_assignment.key_vault_namespace_reader) == ["example", "ingress-gateway"],
      azurerm_role_assignment.key_vault_namespace_reader["example"].role_definition_name == "Key Vault Secrets User",
      strcontains(azurerm_role_assignment.key_vault_namespace_reader["example"].condition, "StringStartsWith 'example--'"),
      keys(azurerm_role_assignment.key_vault_namespace_writer) == ["example/writer/33333333-3333-3333-3333-333333333333"],
      azurerm_role_assignment.key_vault_namespace_writer["example/writer/33333333-3333-3333-3333-333333333333"].role_definition_name == "Key Vault Secrets Officer",
      azurerm_role_assignment.key_vault_namespace_writer["example/writer/33333333-3333-3333-3333-333333333333"].principal_type == "Group",
      strcontains(azurerm_role_assignment.key_vault_namespace_writer["example/writer/33333333-3333-3333-3333-333333333333"].condition, "@Request[Microsoft.KeyVault/vaults/secrets:name] StringStartsWith 'example--'"),
    ])
    error_message = "Each namespace's identity should read, and its writers manage, its own secrets only."
  }
}

run "grants_can_be_left_to_someone_else" {
  command = plan

  variables {
    create_role_assignments          = false
    key_vault_admin_group_object_ids = ["22222222-2222-2222-2222-222222222222"]
  }

  assert {
    condition = alltrue([
      length(azurerm_role_assignment.key_vault_namespace_reader) == 0,
      length(azurerm_role_assignment.key_vault_namespace_writer) == 0,
      length(azurerm_role_assignment.key_vault_admin) == 0,
      length(azurerm_user_assigned_identity.key_vault) == 2,
    ])
    error_message = "With create_role_assignments = false the identities are still created, and the grants left to the estate."
  }
}

run "the_webhook_token_is_flux_systems" {
  command = plan

  variables {
    flux_github_webhook = true
    key_vault_namespaces = {
      flux-system = {}
    }
  }

  assert {
    condition     = azurerm_key_vault_secret.flux_github_webhook[0].name == "flux-system--github-webhook-token"
    error_message = "The webhook's token should be in flux-system's share of the vault."
  }
}

run "the_webhook_token_needs_flux_system_to_have_a_share" {
  command = plan

  variables {
    flux_github_webhook = true
  }

  expect_failures = [azurerm_key_vault_secret.flux_github_webhook]
}

run "rejects_a_namespace_whose_share_would_overlap_another" {
  command = plan

  variables {
    key_vault_namespaces = {
      "team--a" = {}
    }
  }

  expect_failures = [var.key_vault_namespaces]
}

run "the_zones_are_created_and_the_private_one_linked" {
  command = plan

  variables {
    dns_zone_name                       = "contoso.com"
    internal_dns_zone_name              = "internal.contoso.com"
    virtual_network_name                = "vnet-aks-test"
    virtual_network_resource_group_name = "rg-network"
  }

  assert {
    condition = alltrue([
      azurerm_dns_zone.this[0].name == "contoso.com",
      azurerm_dns_zone.this[0].resource_group_name == "rg-aks-test",
      azurerm_private_dns_zone.internal[0].resource_group_name == "rg-aks-test",
      azurerm_private_dns_zone_virtual_network_link.internal[0].name == "test-shared",
      azurerm_private_dns_zone_virtual_network_link.internal[0].virtual_network_id == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-network/providers/Microsoft.Network/virtualNetworks/vnet-aks-test",
    ])
    error_message = "Both zones should be created in the shared resource group, the private one linked to the clusters' network."
  }
}

run "warns_about_a_private_zone_linked_to_nothing" {
  command = plan

  variables {
    internal_dns_zone_name = "internal.contoso.com"
  }

  expect_failures = [check.internal_dns_zone_is_linked]
}

run "refuses_a_region_with_no_code" {
  command = plan

  variables {
    location = "brazilsouth"
  }

  expect_failures = [azurerm_user_assigned_identity.key_vault]
}
