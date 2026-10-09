# The environment's container registry: the images the clusters run - see container_registry_name.
# Every cluster of the environment pulls from it as its kubelet identity, granted by the cluster
# configuration, so nothing secret is kept for it anywhere.
#
# Basic: a prototype's few images. Admin user off - only Entra ID identities reach it.
resource "azurerm_container_registry" "this" {
  count = var.container_registry_name == null ? 0 : 1

  name                = var.container_registry_name
  location            = var.location
  resource_group_name = var.resource_group_name
  sku                 = "Basic"
  admin_enabled       = false
}

# Publishing to it: the principal this configuration is applied as - the service principal of the
# GitHub workflows - pushes the images from the apps' repositories.
resource "azurerm_role_assignment" "container_registry_push" {
  count = var.container_registry_name != null && var.create_role_assignments ? 1 : 0

  principal_id         = data.azurerm_client_config.current.object_id
  scope                = azurerm_container_registry.this[0].id
  role_definition_name = "AcrPush"
}
