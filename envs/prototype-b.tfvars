# Prototype cluster B: the same as aks-prototype-a (envs/prototype-a.tfvars), beside it in the same
# resource group and network, on the same shared resources - so that workloads can be moved between
# the two - but stateless: no persistent storage at all. shared/envs/prototype.tfvars is applied
# first.
#
#   terraform workspace select -or-create prototype-b
#   terraform apply -var-file=envs/prototype-b.tfvars

name     = "aks-prototype-b"
location = "swedencentral"

sku_name = "Base"
sku_tier = "Free"

# Existing resource group. It holds both clusters of the environment and what they share - see
# shared/envs/prototype.tfvars. What is this cluster's own carries its name (`aks-prototype-b`,
# `id-sec-prototype-aks-b...`); what is shared carries `shared` (`kv-sec-prototype-shared`,
# `id-sec-prototype-shared-kv-...`).
resource_group_name = "rg-aks-prototype"

# Existing network - aks-prototype-a's, and the same node subnet. With Azure CNI overlay only the
# nodes take addresses from the subnet; the pod range is each cluster's own and can be the same.
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

# Stateless: no CSI driver - Azure Disk, Azure Files, Azure Blob - and no snapshot controller, so
# the cluster has no StorageClass and nothing to provision a PersistentVolumeClaim from. Hence no
# portable disks either: nothing is granted for disks in resource_group_name, and the platform's
# clusters/prototype-b runs no `portable-disk` StorageClass. Only workloads that keep no state run
# here - the `example` team syncs `stateless/` of its repository, without boot-log.
persistent_storage_enabled = false
portable_disks_enabled     = false

# SHARED. The environment's container registry, created by shared/ and looked up here. The kubelet
# pulls the images from it, and the Flux source-controller the example team's manifests - each as an
# identity of this cluster's own, with AcrPull. Nothing secret to read it with.
container_registry_name = "acrsecprototypeshared"

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

# The `example` team. Its own Flux configuration deploys stateless/ of olljanat-ai/aks-fluxcd-example
# into it - the apps of apps/ that keep no state, aks-hello but not boot-log, whose volume this
# cluster cannot provide - from the OCI artifact the repository is published as in the shared
# registry, and its apps publish themselves through the shared Gateway. It keeps the
# default closed ingress: a NetworkPolicy from aks-fluxcd-platform lets the Traefik pods in, and
# nothing else.
managed_namespaces = {
  example = {
    flux = {
      # Published there by aks-fluxcd-example on every push to main (flux push artifact), and read by
      # the source-controller as this cluster's identity.
      url  = "oci://acrsecprototypeshared.azurecr.io/manifests/aks-fluxcd-example"
      tag  = "main"
      path = "./stateless"
      # Read every minute, like the platform's repository.
      sync_interval_seconds = 60
    }
  }
}

flux_git_repository = {
  url    = "https://github.com/olljanat-ai/aks-fluxcd-platform"
  branch = "main"
  path   = "./clusters/prototype-b"
  # Read every minute rather than every five, so a merged change reaches the cluster within one.
  sync_interval_seconds = 60
}

# A GitHub push reaches the cluster at once: the platform repository publishes Flux's webhook
# receiver (flux-webhook-b.onek8s.lol), checked against the token shared/ keeps in the shared vault.
# flux-system gets this cluster's credential on its shared identity to read it. Set a repository
# webhook to it once - see the README, "Flux".
flux_github_webhook = true
