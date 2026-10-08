# What an environment's clusters share: the Key Vault and the identities their namespaces read it as,
# and the DNS zones they publish their hostnames in. In a state of its own, so that any cluster of the
# environment can be destroyed, built again or replaced by the next while all of this stays - which is
# what lets a workload move from one cluster to another. Each cluster looks these up by name (its
# `key_vault_create = false`, `dns_zone_create = false`) and adds only what is its own: a federated
# credential on each identity, and its external-dns's grant on the zones. See the README, "Shared
# resources".
#
# Everything here is named as the environment's - `shared` in an identity's name, the environment in
# the vault's - where a cluster's resources carry the cluster's name.

data "azurerm_client_config" "current" {}

module "conventions" {
  source = "../modules/conventions"

  location             = var.location
  environment          = var.environment
  key_vault_namespaces = toset(keys(var.key_vault_namespaces))
}

locals {
  # Each writer of each namespace, keyed like the cluster configuration's namespace grants.
  key_vault_writers = {
    for writer in flatten([
      for namespace, share in var.key_vault_namespaces : [
        for writer in share.writers : merge(writer, { namespace = namespace })
      ]
    ]) : "${writer.namespace}/writer/${writer.principal_id}" => writer
  }
}

# The vault, on the Azure RBAC permission model - access policies know no conditions - and reached
# over its public endpoint, authenticated with Entra ID.
resource "azurerm_key_vault" "this" {
  location                   = var.location
  name                       = var.key_vault_name
  resource_group_name        = var.resource_group_name
  sku_name                   = "standard"
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  rbac_authorization_enabled = true
  # A deleted secret can be recovered for the default 90 days. Purge protection is left off, so that a
  # prototype's vault can be purged and its name reused.
  purge_protection_enabled = false
}

# The identity each namespace reads its own secrets as, in every cluster of the environment. A cluster
# adds a federated credential of its own for its namespace's `key-vault` service account; Azure
# allows 20 on an identity.
resource "azurerm_user_assigned_identity" "key_vault" {
  for_each = var.key_vault_namespaces

  location            = var.location
  name                = module.conventions.shared_key_vault_identity_names[each.key]
  resource_group_name = var.resource_group_name

  lifecycle {
    precondition {
      condition     = module.conventions.location_code != ""
      error_message = "No short code is known for ${var.location}, so the shared identities cannot be named. Add it to local.location_codes in modules/conventions/main.tf."
    }
  }
}

# Reading the value of the namespace's own secrets. Listing the names of every secret is not gated -
# see the README, "Key Vault".
resource "azurerm_role_assignment" "key_vault_namespace_reader" {
  for_each = var.create_role_assignments ? var.key_vault_namespaces : {}

  principal_id         = azurerm_user_assigned_identity.key_vault[each.key].principal_id
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets User"
  principal_type       = "ServicePrincipal"
  condition_version    = "2.0"
  condition            = module.conventions.key_vault_read_conditions[each.key]
}

# Managing the namespace's own secrets, and no others.
resource "azurerm_role_assignment" "key_vault_namespace_writer" {
  for_each = var.create_role_assignments ? local.key_vault_writers : {}

  principal_id         = each.value.principal_id
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_type       = each.value.principal_type
  condition_version    = "2.0"
  condition            = module.conventions.key_vault_write_conditions[each.value.namespace]
}

# The whole vault: the platform's secrets and certificates - the listener certificates in
# ingress-gateway - are put there by them.
resource "azurerm_role_assignment" "key_vault_admin" {
  for_each = toset(var.create_role_assignments ? var.key_vault_admin_group_object_ids : [])

  principal_id         = each.value
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Administrator"
  principal_type       = "Group"
}

# The token GitHub signs the Flux webhook's deliveries with, in flux-system's share of the vault. Set
# by hand as the secret of the platform repository's webhooks - one per cluster, each to its own
# hostname, all with this token.
resource "random_password" "flux_github_webhook" {
  count = var.flux_github_webhook ? 1 : 0

  length  = 40
  special = false
}

resource "azurerm_key_vault_secret" "flux_github_webhook" {
  count = var.flux_github_webhook ? 1 : 0

  key_vault_id = azurerm_key_vault.this.id
  name         = "flux-system--github-webhook-token"
  value        = random_password.flux_github_webhook[0].result
  content_type = "text/plain"

  lifecycle {
    precondition {
      condition     = contains(keys(var.key_vault_namespaces), "flux-system")
      error_message = "The Flux webhook's token is flux-system's secret, and flux-system has no share in key_vault_namespaces to read it with."
    }
  }
}

# The zones every cluster of the environment publishes in. Each cluster's external-dns owns its own
# records under its own name, so the clusters never touch each other's - and a hostname moves with
# its workload. The registrar is pointed at the public zone's name servers (dns_zone_name_servers).
resource "azurerm_dns_zone" "this" {
  count = var.dns_zone_name == null ? 0 : 1

  name                = var.dns_zone_name
  resource_group_name = var.resource_group_name
}

resource "azurerm_private_dns_zone" "internal" {
  count = var.internal_dns_zone_name == null ? 0 : 1

  name                = var.internal_dns_zone_name
  resource_group_name = var.resource_group_name
}

data "azurerm_virtual_network" "this" {
  count = var.internal_dns_zone_name != null && var.virtual_network_name != null ? 1 : 0

  name                = var.virtual_network_name
  resource_group_name = coalesce(var.virtual_network_resource_group_name, var.resource_group_name)
}

# The private zone resolves in the clusters' network, for every cluster in it.
resource "azurerm_private_dns_zone_virtual_network_link" "internal" {
  count = var.internal_dns_zone_name != null && var.virtual_network_name != null ? 1 : 0

  name                  = "${var.environment}-shared"
  private_dns_zone_name = azurerm_private_dns_zone.internal[0].name
  resource_group_name   = var.resource_group_name
  virtual_network_id    = data.azurerm_virtual_network.this[0].id
  registration_enabled  = false
}

check "internal_dns_zone_is_linked" {
  assert {
    condition     = var.internal_dns_zone_name == null || var.virtual_network_name != null
    error_message = "The private zone ${coalesce(var.internal_dns_zone_name, "-")} is linked to no network, so nothing resolves its names. Set virtual_network_name."
  }
}
