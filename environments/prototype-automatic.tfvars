# Prototype cluster on the Automatic SKU: Azure manages node provisioning, scaling, networking and
# upgrades. Automatic requires the Standard tier and API Server VNet Integration. Private by default.
#
#   terraform workspace select -or-create prototype-automatic
#   terraform apply -var-file=environments/prototype-automatic.tfvars
#
# Every name below points at infrastructure that must already exist. Replace them with your own.

name     = "aks-prototype-automatic"
location = "swedencentral"

sku_name = "Automatic"
sku_tier = "Standard"

# Existing resource group.
resource_group_name = "rg-aks-prototype"

# Existing network. Set virtual_network_resource_group_name when the network lives elsewhere.
virtual_network_name = "vnet-aks-prototype"
node_subnet_name     = "snet-aks-nodes"
# Hosted system components of the Automatic cluster.
system_node_subnet_name = "snet-aks-system"
# Must be delegated to Microsoft.ContainerService/managedClusters.
api_server_subnet_name = "snet-aks-apiserver"
# virtual_network_resource_group_name = "rg-network"

# Existing private DNS zone for the API server.
private_dns_zone_name = "privatelink.swedencentral.azmk8s.io"
# private_dns_zone_resource_group_name = "rg-network"

# Private by default. Set to false, and optionally restrict the source ranges, for a public cluster.
private_cluster_enabled = true
# api_server_authorized_ip_ranges = ["203.0.113.0/24"]

# Existing Log Analytics workspace for the control plane logs. Without one the cluster keeps no
# record of what the API server was asked to do. Container Insights, managed Prometheus and the
# App Routing ingress controller are disabled on every cluster - third party solutions cover those.
# log_analytics_workspace_resource_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-monitoring/providers/Microsoft.OperationalInsights/workspaces/law-shared"
# defender_enabled = true

# Object IDs of the Entra ID groups that get cluster admin. Local accounts are disabled, so without
# either these or an Azure RBAC role assignment on the cluster nobody can reach the API server.
entra_admin_group_object_ids = []

# Automatic keeps only the initial size and provisions nodes on demand from there on.
default_node_pool = {
  node_count = 3

  # Spread the pool across availability zones in a region that has them. Only settable at creation.
  # availability_zones = ["1", "2", "3"]
}
