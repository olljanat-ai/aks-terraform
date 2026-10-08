# Prototype cluster A on the Free tier: one system node pool, Azure CNI overlay with Cilium, no
# uptime SLA. One of the environment's two clusters, beside aks-prototype-b (envs/prototype-b.tfvars),
# so that workloads can be moved between them. shared/envs/prototype.tfvars is applied first.
#
#   terraform workspace select -or-create prototype-a
#   terraform apply -var-file=envs/prototype-a.tfvars

name     = "aks-prototype-a"
location = "swedencentral"

sku_name = "Base"
sku_tier = "Free"

# Existing resource group. It holds both clusters of the environment and what they share - see
# shared/envs/prototype.tfvars. What is this cluster's own carries its name (`aks-prototype-a`,
# `id-sec-prototype-aks-a...`); what is shared carries `shared` (`kv-sec-prototype-shared`,
# `id-sec-prototype-shared-kv-...`).
resource_group_name = "rg-aks-prototype"

# Existing network. Set virtual_network_resource_group_name when the network lives elsewhere.
virtual_network_name                = "vnet-aks-prototype"
node_subnet_name                    = "snet-aks-nodes"
virtual_network_resource_group_name = "rg-network"

# SHARED. The environment's Key Vault, created by shared/ and looked up here. It holds the secrets
# of every namespace - the listener certificates of ingress-gateway, the example team's - each
# namespace reading only the ones named `<namespace>--<name>`, as the environment's shared identity
# `id-sec-prototype-shared-kv-<namespace>`. This cluster adds a federated credential of its own to
# each; every grant on the vault is shared/'s.
key_vault_name   = "kv-sec-prototype-shared"
key_vault_create = false

# SHARED. The zones the Gateway's hostnames are published in, created by shared/ and looked up here.
# This cluster's external-dns gets an identity of its own, granted on both zones, and owns its own
# records in them; the Flux repository is told where they are.
dns_zone_name          = "onek8s.lol"
internal_dns_zone_name = "internal.onek8s.lol"

# The disks of the platform's `portable-disk` StorageClass go to resource_group_name rather than the
# node resource group, so they outlive this cluster and can be attached to aks-prototype-b. The
# cluster identity is granted a role of its own for disks there, and nothing else.
portable_disks_enabled = true

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

# No Azure Policy add-on: its Gatekeeper alone asks for 360m CPU and 868Mi of memory, a fifth of
# the single B2s node, and nothing in this prototype is governed by policy.
azure_policy_enabled = false

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

# The `example` team. Its own Flux configuration deploys apps/ of olljanat-ai/aks-fluxcd-example
# into it, read with the token aks-fluxcd-platform syncs from the vault as `aks-fluxcd-example-git`
# (tenants/example), and its apps publish themselves through the shared Gateway. It keeps the
# default closed ingress: a NetworkPolicy from aks-fluxcd-platform lets the Traefik pods in, and
# nothing else.
managed_namespaces = {
  example = {
    flux = {
      url         = "https://github.com/olljanat-ai/aks-fluxcd-example"
      path        = "./apps"
      secret_name = "aks-fluxcd-example-git"
      # Read every minute, like the platform's repository.
      sync_interval_seconds = 60
    }
  }
}

flux_git_repository = {
  url    = "https://github.com/olljanat-ai/aks-fluxcd-platform"
  branch = "main"
  path   = "./clusters/prototype-a"
  # Read every minute rather than every five, so a merged change reaches the cluster within one.
  sync_interval_seconds = 60
}

# A GitHub push reaches the cluster at once: the platform repository publishes Flux's webhook
# receiver (flux-webhook-a.onek8s.lol), checked against the token shared/ keeps in the shared vault.
# flux-system gets this cluster's credential on its shared identity to read it. Set a repository
# webhook to it once - see the README, "Flux".
flux_github_webhook = true
