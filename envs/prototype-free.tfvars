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

# Existing network. Set virtual_network_resource_group_name when the network lives elsewhere.
virtual_network_name                = "vnet-aks-prototype"
node_subnet_name                    = "snet-aks-nodes"
virtual_network_resource_group_name = "rg-network"

# Subnet Application Gateway for Containers joins to reach the pods: exactly a /24, delegated to
# Microsoft.ServiceNetworking/trafficControllers, used for nothing else. Created ahead of time like
# the rest of the network; the add-on identity is granted Network Contributor on it.
application_gateway_for_containers_subnet_name = "snet-aks-alb"

# Where the Gateway's listener certificates are kept and its hostnames published. Both exist already;
# the cluster gets an identity for each, federated with the service account that uses it, and the
# Flux repository is told where they are. The vault has to use the Azure RBAC permission model.
# TODO: name the vault and the zone.
# key_vault_name                = "kv-..."
# key_vault_resource_group_name = "rg-..."
# dns_zone_name                 = "contoso.com"
# dns_zone_resource_group_name  = "rg-..."

# Existing private DNS zone for the API server.
private_dns_zone_name = "privatelink.swedencentral.azmk8s.io"
# private_dns_zone_resource_group_name = "rg-network"

# Private by default. Set to false, and optionally restrict the source ranges, for a public cluster.
private_cluster_enabled         = false
api_server_authorized_ip_ranges = ["0.0.0.0/0"]

# Cluster access. Azure RBAC is on, so these groups are granted their access as role assignments on
# the cluster: `Azure Kubernetes Service RBAC Cluster Admin` for the admins, `... RBAC Reader` for
# the readers. Members of both still need `Azure Kubernetes Service Cluster User Role` on the
# cluster to download a kubeconfig at all, which is granted elsewhere.
entra_admin_group_object_ids  = ["2c406e00-7a2a-447a-a617-ff0c907380e3"]
entra_reader_group_object_ids = []

default_node_pool = {
  vm_size             = "Standard_B2s"
  enable_auto_scaling = false
  node_count          = 1
}

# Namespaces AKS creates and keeps. Listing the names is the whole of it: each one gets ingress from
# its own namespace only and egress to anywhere, which managed_namespace_defaults can move for the
# whole cluster and any entry below can override for itself. This cluster runs Cilium, so the
# policies are actually enforced.
#
# `access` grants a group, service principal or user its rights on that namespace alone -
# namespace_user for a kubeconfig scoped to it, then reader, writer or admin for what they may do
# inside it. Object IDs, not names.
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
#       { role = "writer", principal_id = "11111111-1111-1111-1111-111111111111", principal_type = "ServicePrincipal" },
#     ]
#   }
#   team-search = {
#     network_policy = { egress = "AllowSameNamespace" }
#     resource_quota = { cpu_limit = "4", memory_limit = "8Gi" }
#   }
# }

# The `example` team. Flux deploys olljanat-ai/aks-hello into it (see olljanat-ai/aks-fluxcd,
# tenants/example), and the app publishes itself through the shared Gateway. It keeps the default
# closed ingress: a NetworkPolicy from aks-fluxcd lets Application Gateway for Containers in from
# snet-aks-alb, and nothing else.
managed_namespaces = {
  example = {}
}

flux_git_repository = {
  url    = "https://github.com/olljanat-ai/aks-fluxcd-platform"
  branch = "main"
  path   = "./clusters/prototype"
}
