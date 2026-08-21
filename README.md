# aks-terraform

Minimal Terraform for deploying AKS clusters with [Azure Verified Modules][avm].

There is a single root module at the repository root. Everything an environment differs by lives in
a variables file under `envs/` - no per-environment Terraform code.

Clusters are attached to infrastructure that already exists - a resource group, a virtual network
and a private DNS zone - and are **private by default**.

[avm]: https://azure.github.io/Azure-Verified-Modules/

## Layout

| Path | Purpose |
| --- | --- |
| `main.tf`, `variables.tf`, `locals.tf`, `outputs.tf`, `terraform.tf` | The root module. Wraps [`Azure/avm-res-containerservice-managedcluster/azurerm`][module]: looks up the existing resources by name, creates the cluster identity and its role assignments, and wires up private or public API server access. |
| `envs/prototype-free.tfvars` | Cluster on the **Free** tier: one system node pool, Azure CNI overlay with Cilium, no uptime SLA. |
| `envs/prototype-automatic.tfvars` | Cluster on the **Automatic** SKU: Azure manages node provisioning, scaling, networking and upgrades. Runs on the Standard tier, which Automatic requires. |
| `tests/aks.tftest.hcl` | `terraform test` suite. The providers are mocked, so it plans the whole configuration - role assignment scopes, upgrade windows, every input validation - without a subscription. |
| `backend.hcl.example` | Template for the shared remote state backend. |
| `docs/troubleshooting.md` | What to do when an apply fails or times out, and how to get a cluster stuck in `Creating` back under Terraform's control. |
| `.tflint.hcl`, `.github/` | Lint configuration, the CI workflow that runs the offline checks, and the Dependabot schedule that watches the pinned module and provider versions. |

[module]: https://registry.terraform.io/modules/Azure/avm-res-containerservice-managedcluster/azurerm/0.8.1

## Prerequisites

These must exist before running Terraform:

- A **resource group** for the cluster.
- A **virtual network** in the same region, with:
  - a subnet for the cluster nodes;
  - for AKS Automatic, a subnet for the hosted system components - which may be the node subnet -
    and, for API Server VNet Integration, a subnet delegated to
    `Microsoft.ContainerService/managedClusters` that is at least a `/28`. See
    [AKS Automatic](#aks-automatic) for the rest of what that SKU needs.
- A **private DNS zone** named `privatelink.<region>.azmk8s.io`, linked to the virtual network.
  Only needed while the cluster is private.

The identity running Terraform needs `Contributor` on the resource group and, unless
`create_role_assignments = false`, permission to create role assignments on the subnets and the
private DNS zone.

The `Microsoft.PolicyInsights` resource provider should be **registered in the subscription**, since
both SKUs run the Azure Policy add-on and AKS Automatic installs it whether or not you ask:

```sh
az provider register --namespace Microsoft.PolicyInsights
```

## Usage

Edit the environment's variables file to name your existing resources, then apply it:

```sh
az login
terraform init

terraform workspace select -or-create prototype-free
terraform apply -var-file=envs/prototype-free.tfvars
```

One root module serves every environment, so **each environment needs its own state**. Locally that
is one workspace per environment, as above. Adding an environment means adding a variables file;
nothing else changes.

Anything beyond a prototype belongs in remote state: local state is not shared, not locked and not
backed up. Uncomment `backend "azurerm"` in `terraform.tf`, copy `backend.hcl.example` to
`backend.hcl`, and give each environment its own key:

```sh
terraform init -backend-config=backend.hcl -backend-config="key=prototype-free.tfstate"
```

The backend holds a blob lease for the duration of an apply, so two people cannot write the same
state at once. Turn on versioning and soft delete for the container too - a truncated state file is
only recoverable if an earlier version survives.

The configuration can be checked without an Azure subscription at all, which is exactly what CI
runs on every pull request:

```sh
terraform fmt -check -recursive
terraform validate
terraform test
tflint --init && tflint
```

## Cluster access

Local Kubernetes accounts are **disabled**, so there is no cluster-admin certificate to hand around
and `az aks get-credentials --admin` does not work. Everything authenticates as an Entra ID
identity, and Azure RBAC decides what that identity may do inside the cluster.

```sh
az aks get-credentials --resource-group <resource_group_name> --name "$(terraform output -raw name)"
kubectl get nodes
```

Two things have to be granted before that returns anything:

- **`Azure Kubernetes Service Cluster User Role`** on the cluster, to download a kubeconfig at all.
- A Kubernetes-level role, either by listing a group in `entra_admin_group_object_ids` or by
  assigning `Azure Kubernetes Service RBAC Cluster Admin`, `... RBAC Admin`, `... RBAC Writer` or
  `... RBAC Reader` on the cluster or on a namespace inside it.

Because the cluster is private, the kubeconfig only resolves from inside the virtual network or from
a network that reaches it. Without that path, `az aks command invoke` runs a command in the cluster
through the Azure control plane instead:

```sh
az aks command invoke --resource-group <resource_group_name> \
  --name "$(terraform output -raw name)" --command "kubectl get nodes"
```

## Upgrade window

The cluster upgrades itself - by default the `stable` channel for the Kubernetes version and the
`NodeImage` channel for node OS patching, both configurable through `auto_upgrade`. Those upgrades,
together with the weekly AKS release of the control plane and add-ons, are confined to a single
weekly [planned maintenance][maintenance] window. It defaults to the night between Tuesday and
Wednesday, 22:00 - 06:00 UTC.

Change it per environment in the variables file:

```hcl
maintenance_window = {
  day_of_week    = "Tuesday"
  start_time     = "23:00"
  duration_hours = 8
  utc_offset     = "+03:00"
}
```

Azure keeps the window at a fixed UTC offset and does not follow daylight saving time, so an offset
matching local winter time drifts an hour during summer time, and vice versa.

The window must be at least four hours long, or AKS does not attempt an upgrade at all. AKS only
*starts* work inside it: an upgrade still running when the window closes is allowed to finish, but
nothing new begins. Windows are best effort - AKS reserves the right to break them for urgent,
unplanned maintenance.

Pinning `kubernetes_version` and letting a channel move past it are mutually exclusive, and
Terraform refuses the combination: AKS would upgrade the cluster, the next apply would write the
pinned version back, and Azure rejects a downgrade. Pin the version and set
`auto_upgrade = { kubernetes_channel = "none" }`, or pin only the minor version and use `"patch"`.

[maintenance]: https://learn.microsoft.com/azure/aks/planned-maintenance

## Monitoring and ingress

Monitoring and ingress are handled by third party solutions running inside the cluster, so
**nothing is sent to Azure Monitor and no managed ingress controller is installed**. The Azure
features that would otherwise duplicate them are off on every cluster, with no variable to turn
them back on:

| Disabled | What it would have done |
| --- | --- |
| [Container Insights][insights] (`omsagent`) | Ships node and pod telemetry to a Log Analytics workspace. |
| [Azure Monitor managed Prometheus][prometheus] | Scrapes cluster metrics into an Azure Monitor workspace. |
| Control plane [diagnostic setting][diagnostics] | Ships the API server, audit and autoscaler logs to a Log Analytics workspace. |
| [Defender for Containers][defender] | Runs the Defender security agent on the nodes for threat detection. |
| [Application Routing][approuting] (`webAppRouting`) | Installs and manages the default NGINX ingress controller. |

Most of them are stated as disabled rather than simply left unconfigured, because Azure turns them
on by itself otherwise: **AKS Automatic** creates a cluster with Container Insights, managed
Prometheus and App Routing already enabled, and a subscription running the **Defender for Containers
plan** with auto-provisioning on enables the security agent on clusters as they appear.

Two consequences worth knowing about:

- **The control plane logs are not collected anywhere.** The control plane keeps no history of its
  own and is not part of the cluster, so no in-cluster agent can pick up `kube-audit` or
  `kube-apiserver` for you. If those are needed - typically for an audit trail - they have to come
  from a diagnostic setting on the cluster resource, created outside this configuration.
- **Nothing is billed for ingestion**, and the cluster emits platform metrics only.

What the clusters do keep is [cost analysis][costanalysis], which is a Cost Management feature
rather than an Azure Monitor one: it breaks the cluster spend down by namespace and deployment in
the portal, which nothing inside the cluster can work out on its own. Azure sells it with the paid
tiers only, so it follows `sku_tier` - on for `Standard` and `Premium`, off on `Free`, where the
request would be rejected.

The **Azure Policy add-on** is on by default (`azure_policy_enabled`), so policy definitions
assigned to the subscription or resource group are enforced inside the cluster rather than merely
reported on. AKS Automatic always runs it.

[approuting]: https://learn.microsoft.com/azure/aks/app-routing
[costanalysis]: https://learn.microsoft.com/azure/aks/cost-analysis
[defender]: https://learn.microsoft.com/azure/defender-for-cloud/defender-for-containers-introduction
[diagnostics]: https://learn.microsoft.com/azure/aks/monitor-aks-reference
[insights]: https://learn.microsoft.com/azure/azure-monitor/containers/container-insights-overview
[prometheus]: https://learn.microsoft.com/azure/azure-monitor/essentials/prometheus-metrics-overview

## Node pool upgrades

Node image patching and Kubernetes upgrades roll the system pool one node at a time by default,
which is slow on anything but a small pool. `default_node_pool` controls the roll:

```hcl
default_node_pool = {
  max_surge                  = "33%"
  drain_timeout_minutes      = 30
  node_soak_duration_minutes = 5
}
```

`max_surge` is the extra capacity added while upgrading, so the subscription needs quota for it.
`drain_timeout_minutes` bounds how long a node is allowed to take to drain - a pod with a
restrictive disruption budget can otherwise hold the upgrade indefinitely - and
`node_soak_duration_minutes` waits after each node comes back before the next one is drained.

## AKS Automatic

`sku_name = "Automatic"` hands node provisioning, scaling, networking and upgrades to Azure. It is
not simply a different value for the same cluster: Azure ignores most of the request and fills in
its own answers, so the two SKUs behave differently even though they share one set of variables.

Beyond the [prerequisites](#prerequisites), an Automatic cluster in an existing network needs:

- **Three separate subnets** - nodes, hosted system components and the API server. Microsoft's own
  example sizes them `/24`, `/26` and `/28`, and none of the three can be shared:

  - `node_subnet_name` and `system_node_subnet_name` **must name different subnets**. Azure hosts
    the system components apart from the nodes and answers a request that names one subnet for both
    with `400 InvalidParameter: systemNodeByoSubnetId and nodeByoSubnetId must be different
    subnets`, so Terraform refuses it at plan time.
  - `api_server_subnet_name` is used by AKS alone. It has to be delegated to
    `Microsoft.ContainerService/managedClusters`, and a cluster reserves at least nine addresses
    in it.

  Leaving `api_server_subnet_name` unset turns API Server VNet Integration off, so no delegated
  subnet is needed and the API server is not injected into the network. **Microsoft documents the
  subnet as required for an Automatic cluster in an existing virtual network**, so Terraform warns
  on every plan rather than refusing; Azure has the final say on whether it will build the cluster.

  A cluster that brings no network at all is a different arrangement again: AKS creates its own
  virtual network inside the `MC_` resource group and the bring-your-own subnet fields stay null,
  which is why the portal can create an Automatic cluster without asking for any of this. That
  cluster cannot be reached across a network boundary - see the node resource group lockdown note
  below - and this configuration does not offer it, since every environment here attaches to a
  network that already exists.
- **`Network Contributor` on the whole virtual network**, not on the individual subnets. Node
  autoprovisioning creates node pools that the subnet assignments do not cover, which is why
  `network_role_assignment_scope` defaults to `virtual_network` for this SKU and Terraform warns
  when an environment scopes it back down. A cluster missing this grant is created, gets stuck part
  way through bringing its nodes up, and sits in `Creating` until the deployment times out.
- **NSG rules that allow the traffic AKS needs**, if the subnets carry a network security group -
  nodes to the API server subnet on TCP 443 and 4443, the Azure Load Balancer to it on TCP 9988,
  and node-to-node, node-to-pod and pod-to-pod traffic on all ports. Traffic inside a virtual
  network is allowed by default, so this only matters where that default has been narrowed.
- **Outbound access** to the [AKS egress endpoints][egress] where a firewall or a user defined route
  handles egress.

What this configuration drops for the Automatic SKU, because Azure refuses or ignores it:

| Setting | What happens |
| --- | --- |
| `default_node_pool` | Dropped in full apart from the pool name. Azure sizes, scales and rolls the pools itself, and the node count falls back to the three nodes the module defaults to. |
| `network_profile` | Dropped by the module **in full, including `pod_cidr` and `service_cidr`**, while `outbound_type` is `loadBalancer`. Azure then uses its own ranges - `10.244.0.0/16` for pods, `10.0.0.0/16` for services - and they cannot be changed once the cluster exists. See [Address ranges on Automatic](#address-ranges-on-automatic). |
| `azure_policy_enabled` | Ignored. Automatic always runs the Azure Policy add-on. |
| `disable_local_accounts` | **Not sent.** The module's Automatic request has no place for it, so unlike a `Base` cluster an Automatic cluster is created with local accounts enabled. Turn them off afterwards with `az aks update --disable-local-accounts`. |
| `kubernetes_version` | Sent as a separate update after the cluster exists, not as part of the create. |

### Address ranges on Automatic

An Automatic cluster on the default `loadBalancer` egress runs on Azure's ranges, not on the ones
`network_profile` asks for:

```
Pod CIDR        10.244.0.0/16
Service CIDR    10.0.0.0/16
DNS service IP  10.0.0.10
```

This is the AVM module rather than AKS. `podCidr`, `serviceCidr` and `dnsServiceIP` are three of the
four network properties the Automatic SKU *does* accept, but the module nulls the whole network
profile before it filters it, for any Automatic cluster whose `outbound_type` is `loadBalancer`
(`locals.network_profile.tf` in version 0.8.1). Nothing is sent, so Azure fills in its defaults.

It matters because `10.0.0.0/16` collides with a great many existing networks, and **the ranges are
fixed at creation** - a cluster on the wrong ones has to be rebuilt. Terraform warns on every plan
when the effective ranges overlap the address space of the virtual network, whichever SKU they came
from.

There are three ways out, in order of how much they cost:

1. **Leave it**, once you have confirmed the defaults do not overlap your network. This is the
   sensible answer for a prototype.
2. **Set `outbound_type` to something other than `loadBalancer`.** The profile is then sent and the
   configured ranges survive - but `userDefinedRouting` needs a route table and somewhere for egress
   to go, so this is a real change to the network rather than a flag.
3. **Carry a patched module.** The condition is one expression; upstream has no newer release with
   it fixed as of 0.8.1.

Two more things worth knowing:

- **Migration between SKUs is not supported.** Changing `sku_name` on a cluster that already exists
  is not a route from one to the other; the cluster has to be rebuilt.
- **The node resource group is locked down**, so the `MC_` resource group cannot be changed and no
  virtual network link can be added to the AKS-managed private DNS zone. Bring your own zone for
  cross-network or custom DNS scenarios.

If a deployment of an Automatic cluster times out, see [Troubleshooting](docs/troubleshooting.md).

[egress]: https://learn.microsoft.com/azure/aks/outbound-rules-control-egress

## Public clusters

`private_cluster_enabled` defaults to `true`. Set it to `false` in the variables file for a public
API server, and optionally restrict who can reach it:

```hcl
private_cluster_enabled         = false
api_server_authorized_ip_ranges = ["203.0.113.0/24"]
```

A public cluster does not use the private DNS zone, so `private_dns_zone_name` can be left unset.

Leaving `api_server_authorized_ip_ranges` empty leaves the API server reachable from any address on
the internet. Terraform warns about that on every plan rather than refusing it - it is a defensible
choice for a throwaway cluster and a poor one for anything else.

## Notes

- `lock_kind = "CanNotDelete"` puts a **management lock** on the cluster, so that neither Terraform
  nor a portal click can delete it. Terraform can still change it; removing the lock is a separate,
  deliberate step. Note that `ReadOnly` also blocks the upgrades AKS runs on its own.
- The system pool runs in **one availability zone** unless `default_node_pool.availability_zones` is
  set. Spreading it - `availability_zones = ["1", "2", "3"]` in a region that has them - is what
  raises the control plane SLA from 99.9% to 99.95% on the paid tiers, and keeps the cluster running
  through the loss of a datacentre. Zones can only be chosen when the pool is created; changing them
  later replaces it.
- The `Free` tier carries **no uptime SLA** for the control plane. `sku_tier = "Standard"` buys the
  99.9% (or 99.95% across availability zones) financially backed SLA, raises the supported node
  count and is what makes cost analysis available; production clusters belong there.
- **Workload identity** is on, together with the **OIDC issuer** it requires. Federate a Kubernetes
  service account with an Entra ID application against the `oidc_issuer_url` output instead of
  storing credentials in the cluster.
- Terraform **waits after creating the role assignments** before creating the cluster, because Azure
  RBAC is eventually consistent and the cluster is otherwise regularly refused access to the subnet
  it is supposed to join. Tune or disable the wait with `role_assignment_propagation_delay`.
- Cluster operations are given **90 minutes** rather than the 30 the AzAPI provider defaults to,
  through `cluster_timeouts`. Giving up on the Terraform side does not stop the deployment: Azure
  carries on, and the cluster is left in `Creating` with nothing in state pointing at it. An AKS
  Automatic cluster in an existing network regularly needs more than half an hour.
- The cluster identity gets `Network Contributor` **on the subnets it uses**, not on the whole
  virtual network - the least privilege AKS documents for a bring-your-own network. Set
  `network_role_assignment_scope = "virtual_network"` for the wider grant when the cluster has to
  reach network resources outside its own subnets.
- The cluster uses a **user assigned identity** created by this module. AKS must be able to write
  records into the private DNS zone before the cluster exists, which a system assigned identity
  cannot do.
- Azure requires an `fqdnSubdomain` instead of a `dnsPrefix` when a bring-your-own private DNS zone
  is used, so the module derives it from the cluster name.
- Cluster **tags are not managed here**. Automation outside Terraform adjusts them, so the existing
  tags are read back from Azure and passed to the module as-is. Otherwise every plan would propose
  deleting them, and that update alone would make Terraform re-read every computed cluster
  attribute, showing `fqdn`, `node_resource_group_name` and `oidc_issuer_url` as
  `(known after apply)` on an unchanged cluster.
- The **upgrade windows** are `azapi_resource` blocks in `main.tf` rather than module arguments. The
  module always sends a `startDate`, Azure answers with the date the window was created, and that
  difference shows up as an update in every later plan. Terraform can leave the property alone only
  by not mentioning it.
- AKS Automatic ignores most cluster settings on purpose, which is why both SKUs share one set of
  variables: the AVM module drops everything Automatic does not accept from `default_node_pool` and
  `network_profile`. Switching an environment between the two SKUs is a `sku_name` change plus the
  two extra subnets Automatic needs.
