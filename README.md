# aks-terraform

Minimal Terraform for deploying AKS clusters with [Azure Verified Modules][avm].

Clusters are attached to infrastructure that already exists - a resource group, a virtual network
and a private DNS zone - and are **private by default**.

[avm]: https://azure.github.io/Azure-Verified-Modules/

## Layout

| Path | Purpose |
| --- | --- |
| `modules/aks` | Thin wrapper around [`Azure/avm-res-containerservice-managedcluster/azurerm`][module]. Looks up the existing resources by name, creates the cluster identity and its role assignments, and wires up private or public API server access. |
| `environments/prototype-free` | Cluster on the **Free** tier: one system node pool, Azure CNI overlay with Cilium, no uptime SLA. |
| `environments/prototype-automatic` | Cluster on the **Automatic** SKU: Azure manages node provisioning, scaling, networking and upgrades. Runs on the Standard tier, which Automatic requires. |

[module]: https://registry.terraform.io/modules/Azure/avm-res-containerservice-managedcluster/azurerm/0.8.1

## Prerequisites

These must exist before running Terraform:

- A **resource group** for the cluster.
- A **virtual network** in the same region, with:
  - a subnet for the cluster nodes;
  - for `prototype-automatic`, a second subnet for the hosted system components, and a third subnet
    for API Server VNet Integration that is delegated to `Microsoft.ContainerService/managedClusters`.
- A **private DNS zone** named `privatelink.<region>.azmk8s.io`, linked to the virtual network.
  Only needed while the cluster is private.

The identity running Terraform needs `Contributor` on the resource group and, unless
`create_role_assignments = false`, permission to create role assignments on the virtual network and
the private DNS zone.

## Usage

```sh
cd environments/prototype-free          # or environments/prototype-automatic
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars

az login
terraform init
terraform plan
terraform apply
```

State is local by default. Uncomment the `backend "azurerm"` block in `terraform.tf` to share it.

Because the cluster is private, `az aks get-credentials` produces a kubeconfig that only resolves
from inside the virtual network or from a network that can reach it:

```sh
az aks get-credentials --resource-group <resource_group_name> --name "$(terraform output -raw cluster_name)"
```

## Public clusters

Both environments expose `private_cluster_enabled`, which defaults to `true`. Set it to `false` for
a public API server, and optionally restrict who can reach it:

```hcl
private_cluster_enabled         = false
api_server_authorized_ip_ranges = ["203.0.113.0/24"]
```

A public cluster does not use the private DNS zone, so `private_dns_zone_name` can be left unset.

## Notes

- The cluster uses a **user assigned identity** created by `modules/aks`. AKS must be able to write
  records into the private DNS zone before the cluster exists, which a system assigned identity
  cannot do.
- Azure requires an `fqdnSubdomain` instead of a `dnsPrefix` when a bring-your-own private DNS zone
  is used, so the wrapper derives it from the cluster name.
- AKS Automatic ignores most cluster settings on purpose. The wrapper passes only what Automatic
  accepts; the rest of `default_node_pool` and `network_profile` is dropped by the AVM module.
