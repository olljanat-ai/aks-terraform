# aks-terraform

Minimal Terraform for deploying AKS clusters with [Azure Verified Modules][avm].

There is a single root module at the repository root. Everything an environment differs by lives in
a variables file under `envs/` - no per-environment Terraform code.

Clusters are attached to infrastructure that already exists - a resource group, a virtual network
and a private DNS zone - and are **private by default**. The network is the one piece that can be
left out: name none, and AKS creates and manages one for the cluster instead, which is what
`envs/prototype-automatic.tfvars` does. See
[Clusters without a network of their own](#clusters-without-a-network-of-their-own).

[avm]: https://azure.github.io/Azure-Verified-Modules/

## Layout

| Path | Purpose |
| --- | --- |
| `main.tf`, `variables.tf`, `locals.tf`, `outputs.tf`, `terraform.tf` | The root module. Wraps [`Azure/avm-res-containerservice-managedcluster/azurerm`][module]: looks up the existing resources by name, creates the cluster identity and its role assignments, wires up private or public API server access, and creates the managed namespaces. |
| `key_vault.tf` | The cluster's Key Vault, and the identities and conditional role assignments that give each namespace its own share of it. See [Key Vault](#key-vault). |
| `envs/prototype-free.tfvars` | Cluster on the **Free** tier: one system node pool, Azure CNI overlay with Cilium, no uptime SLA. |
| `envs/prototype-automatic.tfvars` | Cluster on the **Automatic** SKU: Azure manages node provisioning, scaling, networking and upgrades - the virtual network included, since this cluster brings none of its own. Runs on the Standard tier, which Automatic requires, and with a public API server. |
| `tests/aks.tftest.hcl` | `terraform test` suite. The providers are mocked, so it plans the whole configuration - role assignment scopes, upgrade windows, every input validation - without a subscription. |
| `backend.hcl.example` | Template for the shared remote state backend. |
| `docs/troubleshooting.md` | What to do when an apply fails or times out, and how to get a cluster stuck in `Creating` back under Terraform's control. |
| `.tflint.hcl`, `.github/` | Lint configuration, the CI workflow that runs the offline checks, the manual deploy workflow for prototype-free, and the Dependabot schedule that watches the pinned module and provider versions. |

[module]: https://registry.terraform.io/modules/Azure/avm-res-containerservice-managedcluster/azurerm/0.8.1

## Prerequisites

These must exist before running Terraform:

- A **resource group** for the cluster. This one is always needed.
- A **virtual network** in the same region, unless the cluster brings none and lets AKS create one -
  see [Clusters without a network of their own](#clusters-without-a-network-of-their-own). Where
  there is one, it needs:
  - a subnet for the cluster nodes;
  - for AKS Automatic, a subnet for the hosted system components, which must be a different subnet
    from the node one;
  - a subnet delegated to `Microsoft.ContainerService/managedClusters` and at least a `/28`, only
    while [API Server VNet Integration](#api-server-vnet-integration) is in use.

  See [AKS Automatic](#aks-automatic) for the rest of what that SKU needs.
- A **private DNS zone** named `privatelink.<region>.azmk8s.io`, linked to the virtual network.
  Only needed while the cluster is private.
- The public **Azure DNS zone** the Gateway's hostnames are published in - only where
  `dns_zone_name` names it, and not when `dns_zone_create` has it created here. See [Certificates and DNS](#certificates-and-dns). The Key Vault is not a
  prerequisite: it is created here - see [Key Vault](#key-vault).
- The **Azure Private DNS zone** the same hostnames are published in privately - only where
  `internal_dns_zone_name` names it, and not when `internal_dns_zone_create` has it created here
  (and linked to the virtual network). An existing one has to be linked to the networks that
  should resolve it already.

`envs/prototype-automatic.tfvars` needs none of the network pieces: it names a resource group and
nothing else about the existing estate. `envs/prototype-free.tfvars` needs all of them.

The identity running Terraform needs `Contributor` on the resource group and, unless
`create_role_assignments = false`, permission to create role assignments on the subnets and the
private DNS zone. Linking a private zone created here (`internal_dns_zone_create`) to the network
also takes `Microsoft.Network/virtualNetworks/join/action` on it - `Network Contributor` has it.

Every cluster runs the managed Gateway API CRDs, which are in **preview**. The subscription needs the
preview feature registered first:

```sh
az feature register --namespace Microsoft.ContainerService --name ManagedGatewayAPIPreview
az provider register --namespace Microsoft.ContainerService
```

The `Microsoft.PolicyInsights` resource provider should be **registered in the subscription**, since
both SKUs run the Azure Policy add-on and AKS Automatic installs it whether or not you ask:

```sh
az provider register --namespace Microsoft.PolicyInsights
```

A cluster with a [Flux repository](#gitops-with-flux) needs the `Microsoft.KubernetesConfiguration`
resource provider registered as well:

```sh
az provider register --namespace Microsoft.KubernetesConfiguration
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

`prototype-free` can also be deployed from GitHub: the [Deploy prototype-free](.github/workflows/deploy-prototype-free.yml)
workflow, started by hand, plans with `envs/prototype-free.tfvars` and - when run with `apply` -
applies that plan. It uses the service principal of the `AZURE_*` variables and the
`AZURE_CLIENT_SECRET` secret, and finds the state through the variables `TF_STATE_RESOURCE_GROUP`,
`TF_STATE_STORAGE_ACCOUNT` and, optionally, `TF_STATE_KEY`. It refuses to plan against an empty state
unless told it is a first deployment.

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
identity, and by default [Azure RBAC][entraauthz] decides what that identity may do inside the
cluster.

```sh
az aks get-credentials --resource-group <resource_group_name> --name "$(terraform output -raw name)"
kubectl get nodes
```

Two things have to be granted before that returns anything:

- **`Azure Kubernetes Service Cluster User Role`** on the cluster, to download a kubeconfig at all.
  This one is never created here, whichever mode the cluster runs in.
- A Kubernetes-level role, which is what `entra_admin_group_object_ids` and
  `entra_reader_group_object_ids` are for.

### Which authorization mode, and what the groups mean in it

`azure_rbac_enabled` picks the mode, and the same group list means two entirely different things
depending on it:

| `azure_rbac_enabled` | Mode | How the groups are granted |
| --- | --- | --- |
| `true` (the default; always on for **Automatic**) | Microsoft Entra ID authentication with Azure RBAC | Azure role assignments on the cluster |
| `false` | Microsoft Entra ID authentication with Kubernetes RBAC | Admin groups of the cluster's own Entra ID profile |

- **With Azure RBAC**, every group in `entra_admin_group_object_ids` is assigned
  `Azure Kubernetes Service RBAC Cluster Admin` on the cluster, and every group in
  `entra_reader_group_object_ids` is assigned `Azure Kubernetes Service RBAC Reader`. The admin
  groups carried in the cluster's Entra ID profile are **not** honored in this mode - Azure reports
  `"adminGroupObjectIds": null` for such a cluster - so nothing is sent there.
- **With Kubernetes RBAC**, `entra_admin_group_object_ids` becomes exactly those admin groups, bound
  to `cluster-admin` inside the cluster, and no role assignment is made.
  `entra_reader_group_object_ids` has no counterpart at all in this mode: those groups are granted
  nothing, and Terraform says so on every plan. Bind them with a Kubernetes `ClusterRoleBinding`
  instead, or turn Azure RBAC on.

AKS Automatic is preconfigured with Azure RBAC and cannot be moved off it, so `azure_rbac_enabled`
is ignored for that SKU: the cluster is authorized that way regardless, and a plan that asks for
anything else says so.

Anything narrower than those two roles is assigned by hand: `Azure Kubernetes Service RBAC Admin`
and `... RBAC Writer` exist as well, and `... RBAC Reader` and `... RBAC Writer` can be scoped to a
single namespace with `--scope $AKS_ID/namespaces/<namespace>`. With
`create_role_assignments = false` none of these grants are made here at all, and every one of them
has to come from wherever the role assignments of the estate are managed.

Because the cluster is private, the kubeconfig only resolves from inside the virtual network or from
a network that reaches it - and for a cluster that brings no network of its own, there is no such
path at all. Without one, `az aks command invoke` runs a command in the cluster through the Azure
control plane instead:

```sh
az aks command invoke --resource-group <resource_group_name> \
  --name "$(terraform output -raw name)" --command "kubectl get nodes"
```

[entraauthz]: https://learn.microsoft.com/azure/aks/manage-azure-rbac

## Managed namespaces

Namespaces are created by AKS rather than by whatever deploys workloads into them, so that the
boundary a namespace draws is in place before anything lands in it. List the names in the variables
file and there is nothing else to write:

```hcl
managed_namespaces = {
  team-payments = {}
  team-search   = {}
}
```

Each one is a [managed namespace][namespaces]: an Azure resource that AKS reconciles into a
Kubernetes `Namespace`, a default `NetworkPolicy` and - where one is asked for - a default
`ResourceQuota`. Deleting the namespace inside the cluster does not get rid of it, and Azure role
assignments can be scoped to the namespace alone - see
[Who gets into a namespace](#who-gets-into-a-namespace).

### What a namespace gets by default

| | Default | What it means |
| --- | --- | --- |
| `network_policy.ingress` | `AllowSameNamespace` | Only pods of the same namespace can open a connection to a pod in it. |
| `network_policy.egress` | `AllowAll` | A pod may reach the API server, DNS, the internet and the rest of the cluster. |
| `adoption_policy` | `Never` | A Kubernetes namespace of that name that already exists fails the apply instead of being taken over. |
| `delete_policy` | `Keep` | Removing the entry deletes the Azure resource and leaves the Kubernetes namespace, and whatever runs in it, standing. |
| `resource_quota` | 2 cores and 4Gi of limits, 500m and 1Gi of requests | Azure requires a quota on every managed namespace, so this is a ceiling to raise or lower rather than one to turn off. |
| `pod_security` | `restricted` | The namespace is held to the hardened [Pod Security Standard][pss], enforced, audited and warned about - see [Pod Security Standards](#pod-security-standards). |

**Closed inbound, open outbound** is the shape this settles on: a workload talks out to what it
needs without anyone having to enumerate it, and nothing in another namespace talks in until it is
allowed to. It is the half of the pair that is worth having by default - the one that stops a
compromised or merely misconfigured workload in one namespace from reaching straight into another -
while a default-deny egress would break DNS, the API server and every outbound call on the first
day and be turned off again by the afternoon.

These are the namespace's *default* policies, not a ceiling. Kubernetes network policies are
additive, so a `NetworkPolicy` applied inside the namespace can only widen what these permit -
tightening egress for a particular workload is done by narrowing it here, not inside the cluster.

### Changing them

Anything in the table can be overridden on a single namespace:

```hcl
managed_namespaces = {
  # Fronted by the ingress controller, which runs in another namespace.
  team-payments = {
    network_policy = { ingress = "AllowAll" }
  }
  # Batch jobs that have no business reaching anything outside their own namespace.
  team-search = {
    network_policy = { egress = "AllowSameNamespace" }
    resource_quota = { cpu_limit = "4", memory_limit = "8Gi" }
  }
}
```

...or for the whole cluster at once through `managed_namespace_defaults`, which is what every
namespace falls back to:

```hcl
managed_namespace_defaults = {
  labels        = { "cost-centre" = "platform" }
  delete_policy = "Delete"
}
```

Both `ingress` and `egress` take `AllowAll`, `AllowSameNamespace` or `DenyAll`. `labels` and
`annotations` merge with the defaults key by key, so a namespace adds to the estate-wide set rather
than replacing it; everything else is a plain override. A namespace that names no quota figures is
sent the four figures of `managed_namespace_defaults` rather than none at all.

Quota figures are written the way a manifest writes them - `"500m"`, `"0.5"` or `"2"` for CPU,
`"512Mi"` or `"4Gi"` for memory. Azure takes the CPU ones in milliCPU alone, so `"2"` is sent on as
`"2000m"` and a figure finer than a milliCPU is refused rather than rounded away.

**Every namespace has a quota.** Azure requires all four figures on a managed namespace - the API
spec marks the quota optional and the service refuses a namespace that arrives without one - so
`resource_quota` sets a ceiling rather than deciding whether there is one. The figures cap the sum
of what the pods in the namespace request and are limited to, which also means a pod that declares
neither a request nor a limit is refused by the quota; a `LimitRange` inside the namespace is what
gives such pods their figures. A namespace that needs more room says so:

```hcl
managed_namespaces = {
  team-search = {
    resource_quota = { cpu_limit = "8", memory_limit = "16Gi" }
  }
}
```

### Pod Security Standards

Every managed namespace is held to the **`restricted`** [Pod Security Standard][pss] unless it says
otherwise. There is nothing to install: the standard is applied as the
`pod-security.kubernetes.io/*` labels the API server's built-in [Pod Security Admission][psa]
controller reads, so a labelled namespace is an enforced one.

Each namespace gets all three modes at `restricted`:

| Mode | What it does |
| --- | --- |
| `enforce` | Rejects a pod that breaks the standard. |
| `audit` | Records the violation in the API server audit log and lets the pod through. |
| `warn` | Returns a warning to whoever applied it and lets the pod through. |

`restricted` is genuinely strict - it wants `runAsNonRoot`, `allowPrivilegeEscalation: false`,
`seccompProfile: RuntimeDefault` and all capabilities dropped - and plenty of off-the-shelf charts
do not meet it as shipped. That is the point of it being the default: a workload that needs more has
to say so, in the variables file, where it is reviewed.

#### Exceptions

An exception is stated on the namespace that needs it, not by lowering the standard for the cluster:

```hcl
managed_namespaces = {
  # A monitoring agent that wants the host network and a privileged container.
  observability = {
    pod_security = { enforce = "privileged" }
  }
  # Charts that are not quite there yet, held at the middle standard while they catch up.
  team-search = {
    pod_security = { enforce = "baseline", warn = "baseline" }
  }
}
```

Each mode takes `restricted`, `baseline`, `privileged` - the level that permits everything, and so
the normal way to write an exception - or `none`, which leaves that label off the namespace
entirely.

**Relaxing `enforce` on its own leaves `audit` and `warn` where they were.** The pods that break the
standard still land in the audit log and still warn whoever applies them, so the exception is
visible and can be walked back later. Terraform warns when a namespace relaxes `enforce` *and* turns
off both of the other two: that is an exception nothing refuses and nothing records.

`version` pins the standard to a Kubernetes release:

```hcl
managed_namespace_defaults = {
  pod_security = { version = "v1.31" }
}
```

The default, `latest`, follows the cluster - which means an AKS upgrade can tighten what a namespace
enforces under a workload that was passing the day before. Pin it in an environment where that
matters, and move the pin deliberately.

The labels are set through `pod_security` alone; a `pod-security.kubernetes.io/*` key written into
`labels` by hand is refused, so a namespace cannot end up with two answers about what it enforces.

[psa]: https://kubernetes.io/docs/concepts/security/pod-security-admission/
[pss]: https://kubernetes.io/docs/concepts/security/pod-security-standards/

### Who gets into a namespace

`access` grants Entra ID groups, service principals and users their rights on that one namespace, as
Azure role assignments scoped to the namespace resource. A team listed here reaches its own
namespace and has no way into the one next door, and needs no cluster-wide grant at all:

```hcl
managed_namespaces = {
  team-payments = {
    access = [
      # The team: a kubeconfig for this namespace, and read/write inside it.
      { role = "namespace_user", principal_id = "00000000-0000-0000-0000-000000000000" },
      { role = "writer", principal_id = "00000000-0000-0000-0000-000000000000" },
      # Their deployment pipeline.
      { role = "writer", principal_id = "11111111-1111-1111-1111-111111111111", principal_type = "ServicePrincipal" },
      # Support, who may look but not touch.
      { role = "reader", principal_id = "22222222-2222-2222-2222-222222222222" },
    ]
  }
}
```

`principal_id` is an Entra ID **object ID** - for an application, the object ID of its service
principal rather than the application ID. `principal_type` is `Group` (the default),
`ServicePrincipal` or `User`; it is stated rather than looked up, so that a principal created moments
ago and not yet replicated does not fail the assignment.

| `role` | Azure built-in role | What it allows |
| --- | --- | --- |
| `namespace_user` | `Azure Kubernetes Service Namespace User` | Read-only on the namespace resource, and the right to list credentials for it. |
| `reader` | `Azure Kubernetes Service RBAC Reader` | Reads most objects in the namespace, but not `Secrets`, roles or role bindings. |
| `writer` | `Azure Kubernetes Service RBAC Writer` | Reads and writes most objects, `Secrets` included, and can run pods as any service account in the namespace. |
| `admin` | `Azure Kubernetes Service RBAC Admin` | `writer`, plus roles and role bindings inside the namespace. Cannot change the namespace itself or its quota - those come from here. |

**`namespace_user` is the one that is easy to forget.** The three data plane roles say what a
principal may do once it reaches the cluster; `namespace_user` is what lets it reach the cluster at
all, by allowing `az aks namespace get-credentials` for that namespace:

```sh
az aks namespace get-credentials \
  --resource-group <resource_group_name> \
  --cluster-name "$(terraform output -raw name)" \
  --name team-payments
```

Unlike the cluster-wide `Azure Kubernetes Service Cluster User Role`, which is
[never created here](#cluster-access), this one is - a namespace-scoped kubeconfig is the whole
point of granting at namespace scope, and it hands out nothing outside the namespace.

The three data plane roles are enforced by
[Azure RBAC for Kubernetes authorization][entraauthz], so they grant nothing while
`azure_rbac_enabled = false`, and Terraform says so on every plan. `namespace_user` is a control
plane role on the Azure resource and works either way. Nothing is granted at all while
`create_role_assignments = false`, which is also warned about; the `managed_namespace_ids` output is
what an estate in that arrangement scopes its own assignments to.

Grants are addressed by namespace, role and principal rather than by their position in the list, so
removing one entry does not renumber the assignments after it and have Azure drop and recreate them.

### What to watch for

- **Something has to enforce the policies.** A `NetworkPolicy` in a cluster with no policy engine is
  an object nobody reads: the namespace looks closed in Azure and every pod in the cluster can still
  reach into it. Terraform warns on every plan when `network_profile.network_policy = "none"` and a
  namespace restricts anything - as `envs/prototype-prd-economy.tfvars` does. AKS Automatic always
  runs Cilium and is never warned about.
- **A managed namespace is no longer yours to edit from `kubectl`.** AKS installs a component that
  reconciles the namespace against what Azure holds and blocks changes to the managed fields through
  the Kubernetes API, so the variables file becomes the only way to change them.
- **Names are Kubernetes namespace names**: lowercase letters, digits and hyphens. System namespaces
  cannot be on-boarded at all - `kube-system` and anything else starting with `kube-`,
  `gatekeeper-system`, `istio-system`, `app-routing-system` - and Terraform refuses the ones
  Microsoft names.
- **The labels cannot be edited back out from inside the cluster.** Because the namespace is
  managed, AKS blocks changes to its labels through the Kubernetes API - so `kubectl label namespace
  team-search pod-security.kubernetes.io/enforce=privileged` does not work, and an exception has to
  go through the variables file. That is the point, but it does mean a team cannot unblock itself at
  three in the morning.
- **A namespace grant does not carry over to the cluster.** `Azure Kubernetes Service Cluster User
  Role` and the cluster-wide `entra_admin_group_object_ids` are separate, and a principal that has
  only namespace grants cannot run `az aks get-credentials` or see anything outside its namespace -
  which is the point, but it does mean `kubectl get nodes` comes back forbidden for them.
- **`delete_policy = "Keep"` leaves the namespace behind.** Removing an entry from the variables
  file destroys the Azure resource but not the Kubernetes namespace, which is deliberate - a
  workload should not disappear because a line moved. Clean it up with `kubectl delete namespace`,
  or set `delete_policy = "Delete"` up front for namespaces that are meant to be disposable.

[namespaces]: https://learn.microsoft.com/azure/aks/concepts-managed-namespaces

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

Monitoring is handled by third party solutions running inside the cluster, so **nothing is sent to
Azure Monitor**. Ingress is the [Kubernetes Gateway API][gatewayapi], served by Traefik Proxy
behind an Azure internal load balancer - see [Ingress through the Gateway API](#ingress-through-the-gateway-api). The Azure features that would
otherwise duplicate them are off on every cluster, with no variable to turn them back on:

| Disabled | What it would have done |
| --- | --- |
| [Container Insights][insights] (`omsagent`) | Ships node and pod telemetry to a Log Analytics workspace. |
| [Azure Monitor managed Prometheus][prometheus] | Scrapes cluster metrics into an Azure Monitor workspace. |
| Control plane [diagnostic setting][diagnostics] | Ships the API server, audit and autoscaler logs to a Log Analytics workspace. |
| [Defender for Containers][defender] | Runs the Defender security agent on the nodes for threat detection. |
| [Application Routing][approuting] (`webAppRouting`) | Installs and manages the default NGINX ingress controller, or an Istio based Gateway API implementation. |
| [Application Gateway for Containers][agcaddon] (`applicationLoadBalancer`) | Runs the ALB Controller add-on, which programs an Azure-hosted, public Gateway API load balancer. |

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

## Ingress through the Gateway API

Every cluster publishes its workloads through the [Kubernetes Gateway API][gatewayapi]. What this
configuration provides is the API itself; the controller serving it is deployed through
[Flux](#gitops-with-flux):

| Setting | What it does |
| --- | --- |
| `ingressProfile.gatewayAPI.installation = "Standard"` | The [managed Gateway API CRDs][managedgw], standard channel. AKS installs and upgrades them, so nothing else in the cluster may bring its own. |
| `ingressProfile.applicationLoadBalancer.enabled = false` | No Application Gateway for Containers add-on. Stated rather than left out, so a cluster that had it loses it; it keeps the module on the `2025-09-02-preview` API, the only one that knows the setting. |

The Flux repository runs [Traefik Proxy][traefik], which provides the `traefik`
GatewayClass, behind a `LoadBalancer` Service annotated
`service.beta.kubernetes.io/azure-load-balancer-internal: "true"`. AKS creates an
[internal load balancer][ilb] for it, in the node resource group, with a private frontend IP:

- **In an existing network**, the frontend is in the node subnet. The cluster identity already holds
  `Network Contributor` there, which is all AKS needs - no subnet of its own, no delegation and no
  further grant.
- **Without a network of its own**, it is in the network AKS creates for the cluster.

Either way the Gateway is reachable from inside the virtual network - and whatever is peered or
connected to it - only. Traffic reaches the pods from the Traefik pods inside the cluster, so a
managed namespace that keeps its default closed ingress lets the `traefik` namespace in with a
`NetworkPolicy` of its own.

### Certificates and DNS

The Gateway terminates TLS with certificates it reads from Kubernetes Secrets, and Traefik has no Key
Vault or Azure DNS integration of its own - AKS's, through the App Routing operator, serves the Istio
based GatewayClasses only. So both are done from inside the cluster, by workloads the Flux repository
deploys, each acting as an identity created here:

- **Certificates** are kept in the cluster's [Key Vault](#key-vault) as `ingress-gateway--<name>` -
  the share of the vault that belongs to `ingress-gateway`. External Secrets Operator syncs it into
  the Secret the listeners name, as `ingress-gateway/key-vault`, unpacking the secret behind the
  certificate as PKCS#12 - so a certificate is imported as a `.pfx`, never as PEM. A new version is
  picked up within the hour.

  Every listener serves one wildcard certificate, `ingress-gateway--wildcard`
  (`*.onek8s.lol` and `*.internal.onek8s.lol`), issued and renewed by the
  [Renew Certificate](.github/workflows/renew-certificate.yml) workflow: Let's Encrypt, with the
  DNS-01 challenge solved in the environment's `dns_zone_name` - the private zone's names too, since
  their `_acme-challenge` records go in the public zone above it - imported into its
  `key_vault_name`, both read from `envs/<environment>.tfvars`. It runs monthly for `prototype-free`,
  and whenever the workflow changes on `main`, and renews when fewer than 30 days are left; run it
  by hand for another environment, other domains or the staging CA. It needs the variables `AZURE_CLIENT_ID`,
  `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID` and `LETSENCRYPT_EMAIL` and the secret
  `AZURE_CLIENT_SECRET`, for a service principal holding `Key Vault Certificates Officer` and
  `Key Vault Secrets Officer` on the vault and `DNS Zone Contributor` on the zone. The Let's Encrypt
  account key is kept in the vault beside the certificate, as `letsencrypt-account-key` - a name in
  no namespace's share. Other certificates can still be imported by hand by an admin group.
- **DNS**: with `dns_zone_name` set, `<cluster identity>-dns` is federated with
  `external-dns/external-dns` and granted `DNS Zone Contributor` on the zone. external-dns keeps an A
  record per listener hostname, pointing at the Gateway's internal load balancer IP. The zone is
  looked up in `resource_group_name` unless `dns_zone_resource_group_name` says otherwise - or, with
  `dns_zone_create = true`, created there. A created zone answers nothing until the domain's
  registrar delegates to it: set the domain's NS records to the `dns_zone_name_servers` output
  (`terraform output dns_zone_name_servers`). **The zone answers with a private address**: a public zone then tells anyone who asks
  the internal IP of the Gateway, which only resolves to something reachable from inside the network.
- **Private DNS**: with `internal_dns_zone_name` set, the same identity is also federated with
  `external-dns/external-dns-internal` - a second external-dns release, since its Azure provider
  writes public or private zones, never both - and granted `Private DNS Zone Contributor` on that
  Azure Private DNS zone. It keeps the same A records for the listener hostnames in that zone, and
  they resolve only in the networks the zone is linked to. The zone is looked up in
  `resource_group_name` unless `internal_dns_zone_resource_group_name` says otherwise - or, with
  `internal_dns_zone_create = true`, created there and linked to the cluster's virtual network
  (which takes one: a cluster on the network AKS manages has nothing to link it to, and Terraform
  warns). In `prototype-free` the zone is `internal.onek8s.lol`, a subdomain of the public zone:
  inside the network it is answered by the private zone, outside by nothing. The wildcard certificate
  covers its hostnames as well.

## Key Vault

`key_vault_name` creates one Key Vault for the cluster, in `resource_group_name`, on the Azure RBAC
permission model. Every namespace keeps its secrets in it, and reads only its own: the namespaces
are kept apart by the names of the secrets, with [Azure ABAC conditions][kvabac] on the role
assignments.

**A namespace owns the secrets named `<namespace>--<name>`** - `example--api-key`,
`ingress-gateway--wildcard`. The namespaces with a share are every managed namespace and the ones
in `key_vault_namespaces`, by default the platform's own `ingress-gateway` (listener certificates).

| Who | Role on the vault | Condition |
| --- | --- | --- |
| The namespace's `key-vault` service account, as `<cluster identity>-kv-<namespace>` | `Key Vault Secrets User` | Reads the value of a secret only if it is the namespace's own |
| The namespace's `writer` and `admin` grants in `managed_namespaces` | `Key Vault Secrets Officer` | Creates, changes, deletes, backs up, restores, recovers and purges the namespace's own secrets only |
| `entra_admin_group_object_ids` | `Key Vault Administrator` | None: the whole vault, certificates included |

In the cluster, each namespace with a share has a `key-vault` service account - created by the Flux
repository - and a `SecretStore` naming it. External Secrets Operator has no Azure identity of its
own: it requests a token for that service account on every read, so a namespace's store reads that
namespace's secrets and no others, and a namespace's `writer` can put a secret in the vault for it
without anyone else's help.

```sh
az keyvault secret set --vault-name <key_vault_name> --name example--api-key --value ...
```

- **Names, not values, are shared.** Listing the vault is not covered by a condition - Key Vault
  evaluates one on a list call as a whole rather than secret by secret, and a name condition there
  refuses the list - so every identity with a role on the vault can see every secret's name. Keep
  secrets out of the names. An `ExternalSecret` that finds secrets by pattern rather than by name
  has to match the namespace's own prefix, or it is refused reading the rest.
- **A namespace name with `--` in it is refused**, since its prefix would overlap another's:
  `team--a--x` starts with `team--`.
- **Certificates are imported by an admin group.** Conditions cover secret operations only, so a
  namespace's writers manage secrets; a certificate's private key is read as the secret behind it,
  under the same name, so the namespace's identity reads its own certificates as well.
- **Key Vault ABAC is in preview.**
- The vault is reached over its public endpoint, authenticated with Entra ID. A deleted secret can
  be recovered for 90 days; purge protection is off, so the vault of a cluster that is torn down can
  be purged and its name reused.

[kvabac]: https://learn.microsoft.com/azure/key-vault/general/rbac-abac

[agcaddon]: https://learn.microsoft.com/azure/application-gateway/for-containers/quickstart-deploy-application-gateway-for-containers-alb-controller-addon
[gatewayapi]: https://gateway-api.sigs.k8s.io/
[ilb]: https://learn.microsoft.com/azure/aks/internal-lb
[managedgw]: https://learn.microsoft.com/azure/aks/managed-gateway-api
[traefik]: https://doc.traefik.io/traefik/reference/install-configuration/providers/kubernetes/kubernetes-gateway/

## GitOps with Flux

A cluster can sync its main configuration from one Git repository through [Flux][flux]. Name the
repository in the variables file, on either SKU:

```hcl
flux_git_repository = {
  url    = "https://github.com/example/cluster-config"
  branch = "main"                 # default
  path   = "./clusters/prototype" # default "./"
}
```

That installs the Flux cluster extension (`microsoft.flux`) into `flux-system`, kept on the newest
minor version of the `Stable` release train, and creates a Flux configuration named `platform` that
reconciles the Kustomization at `path` every `sync_interval_seconds` (default 300; `prototype-free`
reads every 60) and retries a failed run at the same interval. Flux prunes what is removed from the
repository. `platform` runs no health checks of its own (`wait = false`): it applies what `path`
holds - in practice the cluster's own Flux Kustomizations, each waiting for its objects - and is
done, so a commit is never held back behind one of them that is unhealthy.

With `flux_github_webhook = true` the repository can also be told about a push as it happens: a
token is generated and kept in the vault as `flux-system--github-webhook-token`, `flux-system` gets a
share of the vault to read it with (`key_vault_client_id_flux_system`), and the Flux repository
publishes a GitHub webhook receiver that checks deliveries against it. The repository's webhook in
GitHub is then set once, with that token as its secret - olljanat-ai/aks-fluxcd-platform's README,
"Webhook", has the URL. `prototype-free` turns it on.

The `platform` Kustomization is also given the Azure facts the repository cannot know on its own, as
Flux [post-build variables][postbuild], so they are never copied into it by hand:

| Variable | Value |
| --- | --- |
| `key_vault_url`, `key_vault_client_id_<namespace>` | The vault of `key_vault_name`, and for each namespace with a share of it the identity its `key-vault` service account reads it as - the namespace's hyphens as underscores, `key_vault_client_id_ingress_gateway`. |
| `dns_zone_name`, `dns_zone_resource_group_name`, `dns_zone_subscription_id` | The zone of `dns_zone_name`. |
| `internal_dns_zone_name`, `internal_dns_zone_resource_group_name`, `internal_dns_zone_subscription_id` | The private zone of `internal_dns_zone_name`. |
| `dns_identity_client_id` | The identity external-dns writes either zone as. |
| `cluster_name`, `azure_tenant_id` | Always sent. |

A variable the cluster has no value for - those of a vault or zone that is not named - is left out rather than sent empty. They apply to what `path` holds itself; the repository passes them
on from there to whatever needs them.

[postbuild]: https://fluxcd.io/flux/components/kustomize/kustomizations/#post-build-variable-substitution

### Private repositories

A private repository also needs `flux_git_credentials`, with exactly one of:

| Credential | URL | On GitHub |
| --- | --- | --- |
| `https_key` | `https://github.com/<org>/<repo>` | A fine-grained personal access token with read-only `Contents` on the repository. |
| `ssh_private_key` | `ssh://git@github.com/<org>/<repo>` | The private half of a read-only deploy key on the repository. |

The variable is sensitive and sent to Azure **write-only**: the credential is not stored in the
Terraform state, only a SHA-256 hash of it, which is how a rotated credential gets sent again on the
next apply. Keep it out of the variables file and pass it from a secret store instead:

```sh
export TF_VAR_flux_git_credentials='{ https_key = "github_pat_..." }'
# or
export TF_VAR_flux_git_credentials="{ ssh_private_key = $(jq -Rs . < deploy_key) }"
terraform apply -var-file=envs/prototype-free.tfvars
```

The Flux extension already knows GitHub's SSH host keys, so no `known_hosts` is needed.

Leave `flux_git_repository` unset, and name no tenant repository (below), and Flux is not installed
at all.

### Tenants

A managed namespace can deploy itself from a Git repository of its own - the team's - by naming it
in `flux`. The namespace, who gets into it, its share of the Key Vault and its repository are then
one entry in the variables file:

```hcl
managed_namespaces = {
  example = {
    access = [
      { role = "namespace_user", principal_id = "00000000-0000-0000-0000-000000000000" },
      { role = "writer", principal_id = "00000000-0000-0000-0000-000000000000" },
    ]
    flux = {
      url         = "https://github.com/olljanat-ai/aks-fluxcd-example"
      path        = "./apps"
      secret_name = "aks-fluxcd-example-git"
    }
  }
}
```

That creates a second Flux configuration, named after the namespace, **namespace-scoped** and
installed into the namespace itself. It reconciles `path` on `branch` (default `main`) every
`sync_interval_seconds` (default 300), retries at the same interval, prunes, and waits for what it
applied to become ready. Because it is an Azure resource of its own rather than a Kustomization
nested under `platform`, each team's sync status - and the error, when there is one - shows on its
own row in the portal's GitOps view of the cluster.

- The extension applies the repository as the `flux-applier` service account of that namespace and
  refuses references across namespaces, so a team's repository changes its own namespace and
  nothing else. There is no `targetNamespace`: the repository's `kustomization.yaml` sets
  `namespace:` for its objects itself.
- A private repository is read with `secret_name`, a Secret in the namespace. No credential passes
  through Terraform or Azure: the Flux repository syncs it from the namespace's share of the Key
  Vault (olljanat-ai/aks-fluxcd-platform, `tenants/<team>/key-vault.yaml`).
- The rest of what a tenant needs inside the cluster - the `key-vault` service account and
  SecretStore, the ExternalSecrets, the NetworkPolicy that lets Traefik in - stays in the Flux
  repository, under `tenants/<team>/`.

[flux]: https://learn.microsoft.com/azure/azure-arc/kubernetes/conceptual-gitops-flux2

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

`envs/prototype-automatic.tfvars` runs this SKU **without an existing network**, so most of what
follows does not apply to it - it is what an Automatic cluster needs when you do attach it to one,
which `prototype-free` does and which this environment may go back to. Skip to
[Clusters without a network of their own](#clusters-without-a-network-of-their-own) for the
arrangement it is actually on.

Beyond the [prerequisites](#prerequisites), an Automatic cluster in an existing network needs:

- **Two separate subnets** - one for the nodes and one for the hosted system components - and a
  third, delegated one only while [API Server VNet Integration](#api-server-vnet-integration) is in
  use. Microsoft's own example sizes them `/24`, `/26` and `/28`, and none of them can be shared:

  - `node_subnet_name` and `system_node_subnet_name` **must name different subnets**. Azure hosts
    the system components apart from the nodes and answers a request that names one subnet for both
    with `400 InvalidParameter: systemNodeByoSubnetId and nodeByoSubnetId must be different
    subnets`, so Terraform refuses it at plan time.
  - `api_server_subnet_name` is used by AKS alone, and only when the API server is joined to the
    network. **Microsoft documents it as required for an Automatic cluster in an existing virtual
    network** - see [API Server VNet Integration](#api-server-vnet-integration).
- **`Network Contributor` on the whole virtual network**, not on the individual subnets. Node
  autoprovisioning creates node pools that the subnet assignments do not cover, which is why
  `network_role_assignment_scope` defaults to `virtual_network` for this SKU and Terraform warns
  when an environment scopes it back down. A cluster missing this grant is created, gets stuck part
  way through bringing its nodes up, and sits in `Creating` until the deployment times out.
- **NSG rules that allow the traffic AKS needs**, if the subnets carry a network security group -
  node-to-node, node-to-pod and pod-to-pod traffic on all ports, and, where the API server is joined
  to the network, nodes to the API server subnet on TCP 443 and 4443 and the Azure Load Balancer to
  it on TCP 9988. Traffic inside a virtual network is allowed by default, so this only matters where
  that default has been narrowed.
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

## Clusters without a network of their own

Leave `virtual_network_name` and `node_subnet_name` unset and the cluster brings no network at all:
AKS creates and manages a virtual network for it inside the node resource group, sizes the subnets,
and joins the nodes - and, on Automatic, the hosted system components - to it without being told
how. It is what the portal does when it creates an Automatic cluster without asking for any of this.

The two go together. Naming one without the other is refused rather than half-applied, and so is
naming `system_node_subnet_name` or `api_server_subnet_name` for a cluster that has no network to
put them in. With no network there is also nothing to grant: no `Network Contributor` assignment is
created whatever `network_role_assignment_scope` says, and the propagation wait is skipped along
with it.

**An Automatic cluster on this arrangement runs on a system assigned identity**, and no user assigned
one is created for it. Azure requires it - a request that pairs the Automatic SKU with the network
AKS manages and an identity of your own comes back as:

```
400 BadRequest / AKSAutomaticSKUFeatureValidationError
Managed cluster 'Automatic' SKU should use SAMI when using managed vnet.
```

It follows from what the identity is for. It exists to be granted access to resources that already
exist, before the cluster is created; a cluster that brings no network has nothing of the sort. The
`identity_principal_id` output carries the cluster's own principal instead, so anything it has to
reach - a container registry, a key vault - is granted after the cluster is created rather than
before. `identity_resource_id` is null there, since a system assigned identity is part of the
cluster rather than a resource of its own.

The one thing that does not survive it is a **bring-your-own private DNS zone**: the cluster has to
hold `Private DNS Zone Contributor` before it is created in order to register its record, and there
is no principal to grant in advance. Terraform warns when the two are asked for together. A Base
cluster with no network is unaffected - Azure's rule is Automatic's alone, so it keeps the user
assigned identity and the grant with it.

**`envs/prototype-automatic.tfvars` is on this arrangement.** Attaching an Automatic cluster to the
existing network is what has been failing here - the bring-your-own subnets and the API server
injected into a delegated one - while `prototype-free` builds in that same network without trouble,
so the network is taken out of the picture rather than tuned around. The support for the other
arrangement is entirely intact: name the network and its subnets again to go back to it, and the
variables file lists the lines to put back.

What it costs:

- **The cluster is reachable only from the network AKS made.** The node resource group is locked
  down, so that network cannot be peered from outside and no virtual network link can be added to
  it. A private cluster on this arrangement is reachable through `az aks command invoke` and little
  else, which is why `prototype-automatic` runs a **public** API server and should carry a real
  `api_server_authorized_ip_ranges` allowlist rather than `0.0.0.0/0`.
- **A bring-your-own private DNS zone does not work here at all** on the Automatic SKU, per the
  identity note above - and would be of limited use regardless, since nothing outside could resolve
  through it without a link to the AKS-managed network.
- **Azure picks the address ranges**, as it does for any Automatic cluster on `loadBalancer` egress
  - see [Address ranges on Automatic](#address-ranges-on-automatic). There is no existing address
  space for them to collide with, so Terraform's overlap check has nothing to compare and stays
  quiet; a network peered to the cluster later is a different matter and is not checked here.
- **Nothing routes to your estate.** Anything the workloads need to reach on the existing network -
  a database, a private endpoint, a firewall for egress - is not reachable from here. A cluster that
  needs any of that belongs on an existing network.

It is a prototype arrangement, in other words: it takes the network out of the equation while the
SKU itself is what is being proven, and it is not where a cluster with real dependencies belongs.

## API Server VNet Integration

API Server VNet Integration injects the API server into a subnet of the existing virtual network, so
that the nodes reach it across the network rather than through the tunnel AKS otherwise sets up. It
needs a network to inject into, so it is available only to a cluster that brings one. It is off
unless an environment asks for it, and asking for it means naming the subnet:

```hcl
api_server_subnet_name = "snet-aks-api"
```

That subnet is used by AKS alone. It has to be delegated to
`Microsoft.ContainerService/managedClusters` and be a `/28` or larger - a cluster reserves at least
nine addresses in it - and it cannot be shared with anything other than AKS clusters in the same
virtual network. The cluster identity is granted `Network Contributor` on it along with the other
subnets, and where the subnets carry a network security group, the nodes need to reach it on TCP 443
and 4443 and the Azure Load Balancer on TCP 9988.

An environment that wants nothing to do with any of this says so:

```hcl
api_server_vnet_integration_enabled = false
```

The API server is then reached over its public endpoint, or over the AKS-managed private endpoint
for a private cluster, and no delegated subnet is needed. Naming `api_server_subnet_name` while the
flag is `false` is **refused** rather than ignored, so an environment cannot half-say both.

**`envs/prototype-automatic.tfvars` ships with the integration off** and states it with that flag,
even though the cluster brings no network for it to use either way - so that naming a subnet is
refused rather than quietly ignored if the network is ever named again. Injecting the API server
into a delegated subnet is part of what has been failing there; `prototype-free` builds in the
existing network without any of it.

Microsoft documents the delegated subnet as **required** for an AKS Automatic cluster in an existing
virtual network, so Terraform warns on every plan for an Automatic cluster that is attached to one
and has no `api_server_subnet_name` - unless `api_server_vnet_integration_enabled = false` states
that the absence is deliberate, which is the one case where the warning would be noise rather than
news. A cluster that brings no network is not warned about at all: the requirement is about an
existing virtual network, and there is none. Azure has the final say on whether it will build such a
cluster; `docs/troubleshooting.md` covers what to look at when it does not.

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
  virtual network - the least privilege AKS documents for a bring-your-own network. A cluster that
  brings no network is granted nothing at all: AKS owns the one it creates. Set
  `network_role_assignment_scope = "virtual_network"` for the wider grant when the cluster has to
  reach network resources outside its own subnets.
- The cluster uses a **user assigned identity** created by this module, except where it brings no
  network and runs on the Automatic SKU - see
  [Clusters without a network of their own](#clusters-without-a-network-of-their-own). The identity
  exists because AKS has to be granted the existing network and the private DNS zone *before* the
  cluster is created, which a system assigned identity cannot be: it does not exist until the cluster
  does. Its name is **worked out, not configured**: `id-<region code>-<environment>-<function>`,
  built from the cluster name and the region. A cluster name reads `<what it is>-<environment>-<which
  one>`, so `aks-prototype-free` in `swedencentral` is run by `id-sec-prototype-aks-free`. The region
  codes are the estate's own convention rather than anything Azure defines, so they live in
  `local.location_codes` in `locals.tf`; a region that is not listed there stops the plan rather than
  being given a guessed code. An identity cannot be renamed in place, so a name that changes replaces
  the identity, its principal ID and its role assignments - the replacement is built and granted
  before the old one goes, so the cluster is never left pointing at an identity that no longer
  exists.
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
