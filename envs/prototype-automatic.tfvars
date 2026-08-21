# Prototype cluster on the Automatic SKU: Azure manages node provisioning, scaling, networking and
# upgrades. Automatic requires the Standard tier. Private by default.
#
#   terraform workspace select -or-create prototype-automatic
#   terraform apply -var-file=envs/prototype-automatic.tfvars

name     = "aks-prototype-automatic"
location = "swedencentral"

sku_name = "Automatic"
sku_tier = "Standard"

# Existing resource group.
resource_group_name = "rg-aks-prototype"

# Existing network. Set virtual_network_resource_group_name when the network lives elsewhere.
# The nodes go into snet-aks-nodes. The hosted system components need a subnet of their own - Azure
# refuses a request that names one subnet for both - so snet-aks-system carries those and nothing
# else. The cluster identity is granted Network Contributor on the whole virtual network for this
# SKU, because node autoprovisioning creates node pools these subnets do not cover.
virtual_network_name    = "vnet-aks-prototype"
node_subnet_name        = "snet-aks-nodes"
system_node_subnet_name = "snet-aks-system"
# virtual_network_resource_group_name = "rg-network"

# No API Server VNet Integration: api_server_subnet_name is deliberately left unset, so the API
# server is not injected into the network and no delegated subnet is needed. Terraform warns on
# every plan, because Microsoft documents the subnet as required for an AKS Automatic cluster in an
# existing virtual network - see the README before taking the warning as noise.

# Existing private DNS zone for the API server.
private_dns_zone_name = "privatelink.swedencentral.azmk8s.io"
# private_dns_zone_resource_group_name = "rg-network"

# Private by default. Set to false, and optionally restrict the source ranges, for a public cluster.
private_cluster_enabled         = false
api_server_authorized_ip_ranges = ["0.0.0.0/0"]

entra_admin_group_object_ids = []

# default_node_pool is deliberately left out. AKS Automatic sizes, scales and rolls its own node
# pools, and everything this variable carries is dropped for this SKU - see the README.
