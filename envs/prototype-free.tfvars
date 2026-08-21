# Prototype cluster on the Free tier: one system node pool, Azure CNI overlay with Cilium,
# no uptime SLA. Private by default.
#
#   terraform workspace select -or-create prototype-free
#   terraform apply -var-file=envs/prototype-free.tfvars

name     = "aks-prototype-free"
location = "swedencentral"

sku_name = "Base"
sku_tier = "Free"

# Existing resource group.
resource_group_name = "rg-aks-prototype"

# Identity the cluster runs as, named id-<region code>-<environment>-<function>.
managed_identity_name = "id-sec-prototype-aks-free"

# Existing network. Set virtual_network_resource_group_name when the network lives elsewhere.
virtual_network_name = "vnet-aks-prototype"
node_subnet_name     = "snet-aks-nodes"
# virtual_network_resource_group_name = "rg-network"

# Existing private DNS zone for the API server.
private_dns_zone_name = "privatelink.swedencentral.azmk8s.io"
# private_dns_zone_resource_group_name = "rg-network"

# Private by default. Set to false, and optionally restrict the source ranges, for a public cluster.
private_cluster_enabled         = false
api_server_authorized_ip_ranges = ["0.0.0.0/0"]

entra_admin_group_object_ids = []

default_node_pool = {
  vm_size             = "Standard_B2s"
  enable_auto_scaling = false
  node_count          = 1
}
