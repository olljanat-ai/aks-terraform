# Prototype cluster on the Free tier: one system node pool, Azure CNI overlay with Cilium,
# no uptime SLA. Private by default.
#
#   terraform workspace select -or-create prototype-free
#   terraform apply -var-file=environments/prototype-free.tfvars
#
# Every name below points at infrastructure that must already exist. Replace them with your own.

name     = "aks-prototype-free"
location = "swedencentral"

sku_name = "Base"
sku_tier = "Free"

# Existing resource group.
resource_group_name = "rg-aks-prototype"

# Existing network. Set virtual_network_resource_group_name when the network lives elsewhere.
virtual_network_name = "vnet-aks-prototype"
node_subnet_name     = "snet-aks-nodes"
# virtual_network_resource_group_name = "rg-network"

# Existing private DNS zone for the API server.
private_dns_zone_name = "privatelink.swedencentral.azmk8s.io"
# private_dns_zone_resource_group_name = "rg-network"

# Private by default. Set to false, and optionally restrict the source ranges, for a public cluster.
private_cluster_enabled = true
# api_server_authorized_ip_ranges = ["203.0.113.0/24"]

# Object IDs of the Entra ID groups that get cluster admin. Local accounts are disabled, so without
# either these or an Azure RBAC role assignment on the cluster nobody can reach the API server.
entra_admin_group_object_ids = []

default_node_pool = {
  vm_size   = "Standard_D4ds_v5"
  min_count = 2
  max_count = 4
}
