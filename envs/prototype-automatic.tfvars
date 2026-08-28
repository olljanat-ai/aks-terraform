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

# Cluster access. An Automatic cluster always authorizes through Microsoft Entra ID with Azure RBAC,
# so these groups are granted their access as role assignments on the cluster: `Azure Kubernetes
# Service RBAC Cluster Admin` for the admins, `... RBAC Reader` for the readers. Members of both
# still need `Azure Kubernetes Service Cluster User Role` on the cluster to download a kubeconfig at
# all, which is granted elsewhere.
entra_admin_group_object_ids  = []
entra_reader_group_object_ids = []

# Workaround to https://github.com/Azure/terraform-azurerm-avm-res-containerservice-managedcluster/issues/296
/*
default_node_pool = {
  vm_size             = "Standard_D4ds_v5" # Requires size with >= 150 GB local disk
  enable_auto_scaling = false
  node_count          = 1
}
*/

# Namespaces AKS creates and keeps. Listing the names is the whole of it: each one gets ingress from
# its own namespace only and egress to anywhere, which managed_namespace_defaults can move for the
# whole cluster and any entry below can override for itself. An Automatic cluster always runs
# Cilium, so the policies are enforced whatever network_profile says.
#
# `access` grants a group, service principal or user its rights on that namespace alone.
#
# Every namespace is held to the restricted Pod Security Standard unless it says otherwise. A
# workload that cannot meet it states the exception on its own namespace - pod_security = { enforce
# = "privileged" } - which leaves audit and warn at restricted, so the exception stays on the record.
#
# managed_namespaces = {
#   team-payments = {
#     access = [
#       { role = "namespace_user", principal_id = "00000000-0000-0000-0000-000000000000" },
#       { role = "writer", principal_id = "00000000-0000-0000-0000-000000000000" },
#     ]
#   }
#   team-search = {}
# }
