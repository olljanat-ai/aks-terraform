# The prototype environment's shared resources: what aks-prototype-a (envs/prototype-a.tfvars) and
# aks-prototype-b (envs/prototype-b.tfvars) both use, in a state of its own. Applied first - the
# clusters look all of this up by name.
#
#   cd shared
#   terraform apply -var-file=envs/prototype.tfvars

environment = "prototype"
location    = "swedencentral"

# Existing resource group. It holds both clusters and what they share.
resource_group_name = "rg-aks-prototype"

# The environment's Key Vault, which the clusters name in key_vault_name with key_vault_create =
# false. Key Vault names are global; pick another if this one is taken.
key_vault_name = "kv-sec-prototype-shared"

# Every namespace with a share of the vault in any of the clusters: the platform's ingress-gateway
# (listener certificates), flux-system (the Flux webhook's token) and every managed namespace of the
# clusters. A cluster's plan fails on a namespace missing here, since its identity is not there to
# look up.
key_vault_namespaces = {
  ingress-gateway = {}
  flux-system     = {}
  example         = {}
}

# Run the whole vault as Key Vault Administrator: the clusters' admin group.
key_vault_admin_group_object_ids = ["2c406e00-7a2a-447a-a617-ff0c907380e3"]

# The token both clusters' Flux webhook receivers check GitHub's deliveries against.
flux_github_webhook = true

# The zones the clusters publish the Gateway's hostnames in. Point the domain's NS records at the
# dns_zone_name_servers output. The private zone is linked to the clusters' network.
dns_zone_name                       = "onek8s.lol"
internal_dns_zone_name              = "internal.onek8s.lol"
virtual_network_name                = "vnet-aks-prototype"
virtual_network_resource_group_name = "rg-network"
