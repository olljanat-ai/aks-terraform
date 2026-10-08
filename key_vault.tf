# The Key Vault the cluster's namespaces keep their secrets in, and what each namespace reads it as.
# What keeps the namespaces apart is not the vault but the names of the secrets in it: a namespace
# owns the secrets whose names start with `<namespace>--`, and every grant on the vault carries an
# Azure ABAC condition holding it to that prefix. See the README, "Key Vault".
#
# The vault is one of two:
#
#   - The cluster's own (key_vault_create = true), created here with everything on it: the
#     namespaces' identities, every grant, the Flux webhook's token. It goes with the cluster.
#   - The environment's shared one (key_vault_create = false), created with its namespaces'
#     identities and grants by shared/, and only looked up here. The cluster adds a federated
#     credential of its own to each identity and nothing else, so it can be destroyed and built again
#     - or replaced by the next cluster - while the secrets and the identities stay. See the README,
#     "Shared resources".
#
# The vault is on the Azure RBAC permission model - access policies know no conditions - and reached
# over its public endpoint, authenticated with Entra ID.
resource "azurerm_key_vault" "this" {
  count = local.key_vault_owned ? 1 : 0

  location                   = var.location
  name                       = var.key_vault_name
  resource_group_name        = var.resource_group_name
  sku_name                   = "standard"
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  rbac_authorization_enabled = true
  # A deleted secret can be recovered for the default 90 days. Purge protection is left off, so that a
  # prototype's vault can be purged and its name reused when the cluster is torn down.
  purge_protection_enabled = false
}

data "azurerm_key_vault" "this" {
  count = local.key_vault_shared ? 1 : 0

  name                = var.key_vault_name
  resource_group_name = var.resource_group_name
}

# The identity each namespace reads its own secrets as, federated with the `key-vault` service account
# in that namespace. External Secrets Operator has no Azure identity of its own: a SecretStore in the
# namespace names that service account, and the operator requests a token for it on every read - so a
# namespace's store can read that namespace's secrets and no others.
#
# Beside the cluster's own vault, the cluster's own identities: `<cluster identity>-kv-<namespace>`.
resource "azurerm_user_assigned_identity" "key_vault" {
  for_each = local.key_vault_owned ? local.key_vault_namespaces : toset([])

  location            = var.location
  name                = "${local.managed_identity_name}-kv-${each.key}"
  resource_group_name = var.resource_group_name
}

# Beside the shared vault, the environment's shared identities -
# `id-<region>-<environment>-shared-kv-<namespace>`, see modules/conventions - so a namespace is the
# same principal, with the same client ID and the same grants, in every cluster of the environment. A
# namespace with a share here has to have one in shared/ too, or its identity is not there to find.
data "azurerm_user_assigned_identity" "key_vault" {
  for_each = local.key_vault_shared ? local.key_vault_namespaces : toset([])

  name                = module.conventions.shared_key_vault_identity_names[each.key]
  resource_group_name = var.resource_group_name
}

# The cluster's credential on each identity, named after the cluster. A shared identity carries one per
# cluster of the environment - Azure allows 20 - and each is destroyed with its cluster, leaving the
# identity to the rest.
resource "azurerm_federated_identity_credential" "key_vault" {
  for_each = local.key_vault_namespaces

  name                      = "aks-${var.name}"
  user_assigned_identity_id = local.key_vault_identities[each.key].id
  audience                  = ["api://AzureADTokenExchange"]
  issuer                    = module.aks.oidc_issuer_profile_issuer_url
  subject                   = "system:serviceaccount:${each.key}:${local.key_vault_service_account}"

  lifecycle {
    # A namespace's prefix must not be the start of another namespace's: `team--a` would own every
    # secret of `team`, since `team--a--x` starts with `team--`. Kubernetes allows a double hyphen in a
    # namespace name, so it is refused here - for a vault created here and a shared one alike.
    precondition {
      condition     = !strcontains(each.key, "--")
      error_message = "${each.key} cannot be given a share of Key Vault ${coalesce(var.key_vault_name, "-")}: a namespace owns the secrets named `<namespace>--...`, and a name with `--` in it would overlap with another namespace's. Rename the namespace, or leave it out of key_vault_namespaces."
    }
  }
}

# Read access to the namespace's own secrets. The condition gates reading a secret's value only: the
# names of every secret in the vault can still be listed, because Key Vault evaluates a condition on
# listing against the whole collection rather than secret by secret, and a name condition there
# refuses the list outright. A certificate's private key is the secret behind it, under the same name,
# so a certificate is read the same way.
#
# Made for the cluster's own identities only: shared/ grants the shared ones.
resource "azurerm_role_assignment" "key_vault_namespace_reader" {
  for_each = var.create_role_assignments && local.key_vault_owned ? local.key_vault_namespaces : toset([])

  principal_id         = azurerm_user_assigned_identity.key_vault[each.key].principal_id
  scope                = local.key_vault_id
  role_definition_name = "Key Vault Secrets User"
  principal_type       = "ServicePrincipal"
  condition_version    = "2.0"
  condition            = local.key_vault_read_conditions[each.key]
}

# The people and pipelines who may write in a namespace - its `writer` and `admin` grants in
# managed_namespaces - manage its secrets in the vault too, and only its secrets: they can create,
# change, delete and recover the ones under the namespace's prefix. They work with secrets only; a
# certificate is imported by someone holding Key Vault Administrator. On the cluster's own vault only:
# shared/ grants the shared one's writers.
resource "azurerm_role_assignment" "key_vault_namespace_writer" {
  for_each = local.key_vault_writer_role_assignments

  principal_id         = each.value.principal_id
  scope                = local.key_vault_id
  role_definition_name = "Key Vault Secrets Officer"
  principal_type       = each.value.principal_type
  condition_version    = "2.0"
  condition            = local.key_vault_write_conditions[each.value.namespace]
}

# The cluster's admin groups run the whole vault: the platform's secrets and certificates - the
# listener certificates in ingress-gateway - are put there by them. On the cluster's own vault only,
# like the writers.
resource "azurerm_role_assignment" "key_vault_admin" {
  for_each = toset(var.create_role_assignments && local.key_vault_owned ? var.entra_admin_group_object_ids : [])

  principal_id         = each.value
  scope                = local.key_vault_id
  role_definition_name = "Key Vault Administrator"
  principal_type       = "Group"
}

# The token GitHub signs the Flux webhook's deliveries with, and the Receiver checks them against:
# generated here, kept in flux-system's share of the vault, and set by hand as the secret of the
# repository's webhook (see the README, "Flux"). The vault, not this state, is where it is read from.
#
# In the cluster's own vault only. The shared vault's is shared/'s, and every cluster of the
# environment reads the same token - so each Receiver answers on the same path.
resource "random_password" "flux_github_webhook" {
  count = local.flux_github_webhook_enabled && local.key_vault_owned ? 1 : 0

  length  = 40
  special = false
}

resource "azurerm_key_vault_secret" "flux_github_webhook" {
  count = local.flux_github_webhook_enabled && local.key_vault_owned ? 1 : 0

  key_vault_id = local.key_vault_id
  name         = "flux-system--github-webhook-token"
  value        = random_password.flux_github_webhook[0].result
  content_type = "text/plain"
}
