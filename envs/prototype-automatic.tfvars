# Prototype cluster on the Automatic SKU: Azure manages node provisioning, scaling, networking and
# upgrades - the virtual network included, since this cluster brings none of its own. Automatic
# requires the Standard tier, and the API server is public here rather than private.
#
#   terraform workspace select -or-create prototype-automatic
#   terraform apply -var-file=envs/prototype-automatic.tfvars

name     = "aks-prototype-automatic"
location = "swedencentral"

sku_name = "Automatic"
sku_tier = "Standard"

# Existing resource group.
resource_group_name = "rg-aks-prototype"

# NO EXISTING NETWORK. This cluster brings none: AKS creates and manages a virtual network for it
# inside the node resource group, sizes the subnets, and joins the nodes, the hosted system
# components and the API server to it without being told how.
#
# That is the whole point of this file. Attaching an Automatic cluster to the existing network is
# what has been failing - the bring-your-own subnets and the API server injected into a delegated
# one - while prototype-free builds in that same network without trouble. So the network is taken
# out of the picture here rather than tuned around, and what is left is the SKU on its own.
#
# The configuration supports the existing-network arrangement in full; nothing about it was removed,
# and prototype-free still uses it. To put this cluster back on it, name the network and its subnets
# again - all of these go together, and Terraform refuses a half-filled set:
#
#   virtual_network_name                = "vnet-aks-prototype"
#   node_subnet_name                    = "snet-aks-nodes"
#   system_node_subnet_name             = "snet-aks-system"   # a different subnet from the nodes'
#   api_server_vnet_integration_enabled = true                # the default; drop the line below too
#   api_server_subnet_name              = "snet-aks-api"      # delegated /28, for the API server
#   # virtual_network_resource_group_name = "rg-network"      # when the network lives elsewhere
#
# API Server VNet Integration is stated as off rather than merely left out, so that naming a subnet
# for it is refused instead of quietly ignored while the cluster has no network to put one in.
api_server_vnet_integration_enabled = false

# No private DNS zone either. The API server is public here, so nothing resolves through one - and a
# bring-your-own zone would have to be linked to the network AKS manages, which the node resource
# group lockdown does not allow. See the README on what that costs.
# private_dns_zone_name = "privatelink.swedencentral.azmk8s.io"

# Public API server. It is how this cluster is reached at all: the network AKS creates for it cannot
# be peered or linked from outside, so a private cluster here would be reachable only through
# `az aks command invoke`. Restrict the source ranges to the addresses that need it.
private_cluster_enabled         = false
api_server_authorized_ip_ranges = ["0.0.0.0/0"]

entra_admin_group_object_ids = []

# default_node_pool is deliberately left out. AKS Automatic sizes, scales and rolls its own node
# pools, and everything this variable carries is dropped for this SKU - see the README.
