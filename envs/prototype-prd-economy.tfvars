# Prototype cluster on the Production Economy
#
#   terraform workspace select -or-create prototype-prd-economy
#   terraform apply -var-file=envs/prototype-prd-economy.tfvars

name     = "aks-prototype-prd-economy"
location = "swedencentral"

sku_name = "Base"
sku_tier = "Standard"

# Existing resource group.
resource_group_name = "rg-aks-prototype"

# Existing network. Set virtual_network_resource_group_name when the network lives elsewhere.
#virtual_network_name = "vnet-aks-prototype"
#node_subnet_name     = "snet-aks-nodes"
# virtual_network_resource_group_name = "rg-network"

# Minimize load by leaving out components which are not needed for this configuration
network_profile = {
  network_plugin      = "azure"
  network_plugin_mode = "overlay"
  network_policy      = "none"
  network_dataplane   = "azure"
  advanced_networking = {
    enabled = false
    observability = {
      enabled = false
    }
    security = {
      enabled = false
    }
  }
}
cost_analysis_enabled = false
azure_policy_enabled  = false

# Private by default. Set to false, and optionally restrict the source ranges, for a public cluster.
private_cluster_enabled         = false
api_server_authorized_ip_ranges = ["0.0.0.0/0"]

# Cluster access. Azure RBAC is on, so these groups are granted their access as role assignments on
# the cluster: `Azure Kubernetes Service RBAC Cluster Admin` for the admins, `... RBAC Reader` for
# the readers. Members of both still need `Azure Kubernetes Service Cluster User Role` on the
# cluster to download a kubeconfig at all, which is granted elsewhere.
entra_admin_group_object_ids  = []
entra_reader_group_object_ids = []

default_node_pool = {
  vm_size            = "Standard_A2m_v2"
  node_count         = 3
  availability_zones = ["1", "2", "3"]
}

# Namespaces AKS creates and keeps. Listing the names is the whole of it: each one gets ingress from
# its own namespace only and egress to anywhere, which managed_namespace_defaults can move for the
# whole cluster and any entry below can override for itself.
#
# NOTE: this cluster runs network_policy = "none", so nothing in it enforces a NetworkPolicy - a
# namespace would look closed in Azure while every pod in the cluster could still reach into it.
# Terraform warns on every plan while that is the case. Set network_policy = "cilium" together with
# network_dataplane = "cilium" above before relying on the boundary.
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
