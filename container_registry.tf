# The registry the cluster pulls its images from - the environment's, created by shared/ and looked up
# here. See container_registry_name. The kubelet identity pulls them, so a pod names no image pull
# secret and nothing secret is kept for the registry.
data "azurerm_container_registry" "this" {
  count = var.container_registry_name == null ? 0 : 1

  name                = var.container_registry_name
  resource_group_name = coalesce(var.container_registry_resource_group_name, var.resource_group_name)
}

resource "azurerm_role_assignment" "kubelet_container_registry_pull" {
  count = var.container_registry_name != null && var.create_role_assignments ? 1 : 0

  principal_id         = module.aks.kubelet_identity.objectId
  scope                = data.azurerm_container_registry.this[0].id
  role_definition_name = "AcrPull"
  principal_type       = "ServicePrincipal"
}
