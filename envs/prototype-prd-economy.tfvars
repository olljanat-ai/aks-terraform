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
