# The registry the cluster pulls from - the environment's, created by shared/ and looked up here. See
# container_registry_name. Nothing secret is kept for it: the cluster reads it as identities of its
# own.
data "azurerm_container_registry" "this" {
  count = var.container_registry_name == null ? 0 : 1

  name                = var.container_registry_name
  resource_group_name = coalesce(var.container_registry_resource_group_name, var.resource_group_name)
}

# Images: the kubelet identity pulls them, so a pod names no image pull secret.
resource "azurerm_role_assignment" "kubelet_container_registry_pull" {
  count = var.container_registry_name != null && var.create_role_assignments ? 1 : 0

  principal_id         = module.aks.kubelet_identity.objectId
  scope                = data.azurerm_container_registry.this[0].id
  role_definition_name = "AcrPull"
  principal_type       = "ServicePrincipal"
}

# Manifests: the OCI artifacts of the managed namespaces' Flux configurations, read by the Flux
# source-controller as this identity - federated with its service account, and set on the extension
# as its workload identity.
resource "azurerm_user_assigned_identity" "flux_source" {
  count = local.flux_source_identity_enabled ? 1 : 0

  location            = var.location
  name                = "${local.managed_identity_name}-flux"
  resource_group_name = var.resource_group_name
}

resource "azurerm_federated_identity_credential" "flux_source" {
  count = local.flux_source_identity_enabled ? 1 : 0

  name                      = "aks-${var.name}"
  user_assigned_identity_id = azurerm_user_assigned_identity.flux_source[0].id
  audience                  = ["api://AzureADTokenExchange"]
  issuer                    = module.aks.oidc_issuer_profile_issuer_url
  subject                   = "system:serviceaccount:flux-system:source-controller"
}

resource "azurerm_role_assignment" "flux_source_container_registry_pull" {
  count = local.flux_source_identity_enabled && var.create_role_assignments ? 1 : 0

  principal_id         = azurerm_user_assigned_identity.flux_source[0].principal_id
  scope                = data.azurerm_container_registry.this[0].id
  role_definition_name = "AcrPull"
  principal_type       = "ServicePrincipal"
}
