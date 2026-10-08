# A second prototype cluster on the Free tier, beside aks-prototype-free, for trying out moving
# workloads from one cluster to the other. Built the same way, in the same network, and sharing what
# outlives a cluster: aks-prototype-free's Key Vault and the shared resource group the disks of
# persistent volumes go to. See the README, "Shared resource group".
#
#   terraform workspace select -or-create prototype-free-b
#   terraform apply -var-file=envs/prototype-free-b.tfvars
#
# aks-prototype-free is applied first: it creates the vault and the DNS zones this cluster looks up.

name     = "aks-prototype-free-b"
location = "swedencentral"

sku_name = "Base"
sku_tier = "Free"

# Existing resource group - aks-prototype-free's. The identities are named after the cluster
# (`id-sec-prototype-aks-free-b...`), so the two sit side by side.
resource_group_name = "rg-aks-prototype"

# The same shared resource group as aks-prototype-free: this cluster's identity is granted the disks
# in it, and its Flux repository told to create them there.
shared_resource_group_name = "rg-aks-prototype-shared"

# The same network and node subnet. With Azure CNI overlay only the nodes take addresses from the
# subnet; the pod range is the cluster's own and can be the same in both clusters.
virtual_network_name                = "vnet-aks-prototype"
node_subnet_name                    = "snet-aks-nodes"
virtual_network_resource_group_name = "rg-network"

# aks-prototype-free's Key Vault, looked up in shared_resource_group_name rather than created. Every
# namespace here reads its own share of it with an identity of this cluster's, so the example team
# finds the secrets it has in aks-prototype-free. The vault-wide grants - the admin groups, the
# namespaces' writers - and the Flux webhook's token are aks-prototype-free's to make.
key_vault_name   = "kv-proto-aks-free"
key_vault_create = false

# aks-prototype-free's zones, looked up in resource_group_name rather than created. This cluster
# publishes hostnames of its own in them (clusters/prototype-free-b in aks-fluxcd-platform); its
# external-dns owns its records under its own name and leaves the other cluster's alone. The private
# zone is already linked to the network above.
dns_zone_name          = "onek8s.lol"
internal_dns_zone_name = "internal.onek8s.lol"

# Existing private DNS zone for the API server.
private_dns_zone_name = "privatelink.swedencentral.azmk8s.io"

private_cluster_enabled         = false
api_server_authorized_ip_ranges = ["0.0.0.0/0"]

entra_admin_group_object_ids  = ["2c406e00-7a2a-447a-a617-ff0c907380e3"]
entra_reader_group_object_ids = []

azure_policy_enabled = false

default_node_pool = {
  vm_size             = "Standard_B2s"
  enable_auto_scaling = false
  node_count          = 1
}

# The `example` team, as in aks-prototype-free: the same repository, the same token in the vault.
managed_namespaces = {
  example = {
    flux = {
      url                   = "https://github.com/olljanat-ai/aks-fluxcd-example"
      path                  = "./apps"
      secret_name           = "aks-fluxcd-example-git"
      sync_interval_seconds = 60
    }
  }
}

flux_git_repository = {
  url                   = "https://github.com/olljanat-ai/aks-fluxcd-platform"
  branch                = "main"
  path                  = "./clusters/prototype-free-b"
  sync_interval_seconds = 60
}

# flux-system gets a share of the vault, to read the webhook token aks-prototype-free created. The
# Receiver's path is a digest of that token, its name and namespace, so it is the same path as in
# aks-prototype-free, on this cluster's own hostname (flux-webhook-b.onek8s.lol).
flux_github_webhook = true
