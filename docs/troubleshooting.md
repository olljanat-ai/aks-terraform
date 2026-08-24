# Troubleshooting

What to do when an apply of this configuration fails, and in particular when it times out and leaves
a cluster stuck in `Creating` in Azure.

All of the commands below assume the environment's variables file, so set these once:

```sh
RG=rg-aks-prototype
CLUSTER=aks-prototype-automatic
```

## The apply timed out and the cluster is stuck in "Creating"

This is one situation, not two. **Terraform giving up does not cancel anything.** The create request
is a long-running operation on the Azure side: Terraform sends it, polls for the result, and stops
polling when the timeout expires. Azure carries on regardless, which is why the portal keeps showing
`Creating` long after the apply has failed.

So the first question is not "why did Terraform time out" but "what is Azure still doing".

### 1. Find out whether Azure is still working or has already given up

```sh
az aks show -g "$RG" -n "$CLUSTER" --query "{state:provisioningState, power:powerState.code}" -o table
```

- `Creating` - the operation is still running. Watch it rather than starting another one.
- `Failed` - Azure gave up too. If the reason is `OperationTimeout`, see
  [Azure returned `OperationTimeout`](#azure-returned-operationtimeout); otherwise it is in the
  deployment operations below.
- `Succeeded` - the cluster finished after Terraform stopped watching. Skip to
  [Getting Terraform back in sync](#getting-terraform-back-in-sync).

The reason, when there is one, comes from the resource provider rather than from the cluster
resource:

```sh
az monitor activity-log list -g "$RG" --offset 6h \
  --query "[?contains(resourceId, '$CLUSTER')].{op:operationName.value, status:status.value, sub:subStatus.value, msg:properties.statusMessage}" -o json
```

`properties.statusMessage` carries the actual AKS error - an authorization failure on a subnet, a
quota rejection, an unregistered resource provider - which is the thing worth acting on. A cluster
that sits in `Creating` for an hour and then fails almost always failed for one of the reasons under
[Common causes](#common-causes).

### 2. Watch it, do not re-run

Re-running `terraform apply` against a cluster that is still being created does not help: the create
request is rejected while an operation is in flight, and a second Terraform run cannot adopt the
first one's work. Wait for `provisioningState` to settle:

```sh
watch -n 30 "az aks show -g $RG -n $CLUSTER --query provisioningState -o tsv"
```

### 3. Once it has settled

- **`Succeeded`** - see [Getting Terraform back in sync](#getting-terraform-back-in-sync).
- **`Failed`** - fix the cause, then delete the failed cluster and apply again. A cluster that
  failed to create cannot be repaired in place:

  ```sh
  az aks delete -g "$RG" -n "$CLUSTER" --yes
  ```

  The node resource group (`MC_*`) goes with it. Check that it is gone before applying again; a
  leftover one makes the next create fail on a name conflict.

## Azure returned `OperationTimeout`

```
Error code: OperationTimeout. Message: "Operation timeout, please retry."
```

This is **Azure giving up, not Terraform**. The create request was accepted, AKS worked on it, the
cluster did not converge inside the resource provider's own deadline, and the operation was failed
off. Raising `cluster_timeouts` does nothing for this - Terraform was still waiting when the answer
came back.

Nor is it a reason to retry as the message suggests. `OperationTimeout` on a **first create** is
almost never transient: something in the request or the network stopped the cluster reaching a
working state, and a second attempt meets the same wall. Retry is worth one shot only if the
previous attempt got visibly further.

### Narrow it down by what changed

`envs/prototype-automatic.tfvars` **brings no network at all** - AKS creates one for the cluster
inside the node resource group - so the existing network, its subnets and the role assignments on
them are not in the picture, and neither is anything under [Common causes](#common-causes) that
talks about them. What is left is the SKU itself, the settings this configuration turns off, and the
subscription around them: quota, `Microsoft.PolicyInsights`, and the region.

That is what the arrangement is for. The bring-your-own subnets and the API server injected into a
delegated one are what the cluster kept failing on, while `prototype-free` builds in the existing
network without trouble. **If the environment you are looking at has been put back on the existing
network** - `virtual_network_name` and the subnets named again - then the network is back in the
picture, and taking it out again is the fastest way to find out whether it is the cause.

Look at how far it got before it was failed off:

```sh
# Did any node ever appear? The node resource group is created early, the scale sets later. It also
# holds the virtual network AKS made, for a cluster that brought none.
az resource list -g "MC_${RG}_${CLUSTER}_swedencentral" -o table

# Only on an existing network with API Server VNet Integration on: did the API server get injected
# into its subnet? It takes addresses there as it comes up.
az network vnet subnet show -g "$RG" --vnet-name vnet-aks-prototype -n snet-aks-api \
  --query "{prefix:addressPrefix, delegations:delegations[].serviceName, ips:ipConfigurations[].id}" -o json

# What the resource provider recorded, which is more specific than the error Terraform surfaced.
az monitor activity-log list -g "$RG" --offset 6h \
  --query "[?contains(resourceId, '$CLUSTER')].{op:operationName.value, status:status.value, sub:subStatus.value, msg:properties.statusMessage}" -o json
```

- **No node resource group** - the failure is early, before AKS built anything. On an existing
  network, suspect the subnets: size, an NSG, or, where the integration is on, the delegation of the
  API server subnet and the addresses it never took. With no network of your own, the subnets cannot
  be it: look at the activity log for a quota or provider rejection instead.
- **Nodes exist but never became ready** - they could not reach the API server or the internet. On
  an existing network, suspect a route table or NSG rules on the node subnets, and on the API server
  subnet while the integration is on. With no network of your own there is nothing of yours in the
  path, so this points at the cluster or the region rather than at the estate.

### Isolate the configuration from the network

The fastest way to tell whether the request is at fault is to build an Automatic cluster next to it
with none of this configuration's opinions - no disabled add-ons, no disabled ingress, nothing but
the identity, exactly as `envs/prototype-automatic.tfvars` asks for it:

```sh
SUB=$(az account show --query id -o tsv)

az aks create -g "$RG" -n aks-probe --location swedencentral --sku automatic --no-ssh-key \
  --assign-identity "/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-sec-prototype-aks-automatic"
```

- **The probe succeeds** - something this configuration sends is the problem. The candidates are the
  settings AKS Automatic turns on by itself and this configuration turns back off: Container
  Insights, managed Prometheus, App Routing and the Gateway API installation, Defender. Put them
  back one at a time.
- **The probe times out the same way** - the request is not the problem, and neither is the network,
  since neither cluster brought one. That leaves the subscription and the region: quota,
  `Microsoft.PolicyInsights`, and whether Automatic is offered there at all.

To probe the existing-network arrangement instead - the one this environment came off - add the
subnets back to the same command, and the API server subnet after that:

```sh
NET=/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.Network/virtualNetworks/vnet-aks-prototype

  --node-subnet-id        "$NET/subnets/snet-aks-nodes" \
  --system-node-subnet-id "$NET/subnets/snet-aks-system" \
  --apiserver-subnet-id   "$NET/subnets/snet-aks-api"
```

A probe that comes up without those lines and hangs with them is the network, or the API server
injected into it, rather than anything this configuration sends - which is the finding the current
`envs/prototype-automatic.tfvars` is built on.

Delete the probe when it has answered the question: `az aks delete -g "$RG" -n aks-probe --yes`.

## Getting Terraform back in sync

The cluster exists in Azure but Terraform's state may or may not know about it. Check first:

```sh
terraform workspace select prototype-automatic
terraform state list | grep module.aks
```

- **The resource is in state.** Nothing to do. Run `terraform plan` - it reads the cluster back and
  shows what, if anything, still differs.
- **The resource is not in state.** Import it rather than deleting the cluster:

  ```sh
  SUB=$(az account show --query id -o tsv)
  terraform import -var-file=envs/prototype-automatic.tfvars \
    'module.aks.azapi_resource.this' \
    "/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.ContainerService/managedClusters/$CLUSTER"
  ```

  Then `terraform plan` and read the diff carefully before applying: anything the create request did
  not carry - the maintenance windows, the agent pool update, the Kubernetes version update - is
  still outstanding and shows up here.

If the import is more trouble than the cluster is worth, deleting it and applying again is a
perfectly reasonable answer for a prototype. It is not for anything with state in it.

## Common causes

Everything here except `Microsoft.PolicyInsights` is about a cluster attached to an existing
network. A cluster that brings none - which `envs/prototype-automatic.tfvars` now does - has no
subnets to get wrong, nothing to be granted and nothing of yours in the path, so skip to the
provider registration and to what the activity log says.

### Missing `Network Contributor` on the virtual network (AKS Automatic)

The most likely reason an Automatic cluster on an existing network hangs where an equivalent `Base`
cluster succeeds. Not applicable to a cluster that brings no network: AKS owns the one it creates,
and this configuration asks for no assignment at all in that case.
Microsoft documents `Network Contributor` **on the virtual network** for this SKU, because node
autoprovisioning creates node pools that assignments on the individual subnets do not cover. The
cluster resource is created, the nodes never come up, and the operation runs until it times out.

This configuration now grants the virtual network scope automatically for `sku_name = "Automatic"`.
Confirm the assignment is actually there and is in effect:

```sh
IDENTITY_ID=$(terraform output -raw identity_principal_id)
az role assignment list --assignee "$IDENTITY_ID" --all -o table
```

Azure RBAC is eventually consistent, so an assignment created seconds before the cluster can still
be invisible to it. That is what `role_assignment_propagation_delay` is for; raise it if an apply
fails with an authorization error on a subnet.

### The API server subnet is not delegated, is too small, or is missing

Only when API Server VNet Integration is on, which needs an existing network to inject the API
server into. `envs/prototype-automatic.tfvars` has neither, so there is no API server subnet to get
wrong there.

Microsoft documents the subnet as required for this SKU in an existing virtual network, so an
Automatic cluster *on such a network* that is refused or hangs without one is a real possibility -
the README says what to weigh against it. Check the delegation and the size before concluding that,
though: an integration that was on and pointed at a subnet AKS could not use looks the same from the
outside.

When there is one:

```sh
az network vnet subnet show -g "$RG" --vnet-name vnet-aks-prototype -n snet-aks-api \
  --query "{prefix:addressPrefix, delegations:delegations[].serviceName}" -o json
```

It must be delegated to `Microsoft.ContainerService/managedClusters` and be a `/28` or larger. AKS
reserves at least nine addresses in it, and it cannot be shared with anything other than AKS
clusters in the same virtual network.

### `Microsoft.PolicyInsights` is not registered

AKS Automatic installs the Azure Policy add-on whether or not the request asks for it. An
unregistered provider makes that step slow or fatal:

```sh
az provider show --namespace Microsoft.PolicyInsights --query registrationState -o tsv
az provider register --namespace Microsoft.PolicyInsights   # if it is not "Registered"
```

### Overlapping address ranges

An Automatic cluster on `loadBalancer` egress is sent no network profile at all, so it runs on
Azure's `10.244.0.0/16` pod range and `10.0.0.0/16` service range rather than on the ones
`network_profile` asks for. See the README for why, and for the ways out. Pods and services on a
range the existing network also uses have nowhere to route to.

A cluster that brings no network has no existing address space to collide with, so Terraform has
nothing to compare and stays quiet - but the ranges are still Azure's, and still fixed at creation.
They are worth knowing before anything is ever peered to that cluster.

Terraform warns about this on every plan where there is a network, but to check a cluster that
already exists:

```sh
az network vnet show -g "$RG" -n vnet-aks-prototype --query addressSpace.addressPrefixes -o tsv
az aks show -g "$RG" -n "$CLUSTER" \
  --query "networkProfile.{pod:podCidr, service:serviceCidr, dns:dnsServiceIP}" -o json
```

**These cannot be changed on an existing cluster.** A cluster on colliding ranges has to be deleted
and recreated, so it is worth confirming before the first apply rather than after.

### Compute quota

Node autoprovisioning picks VM sizes itself, and a family with no quota left in the region means
nodes that are requested and never appear:

```sh
az vm list-usage --location swedencentral -o table | awk '$NF != 0 || /Name/'
```

### NSG rules on the subnets

Traffic inside a virtual network is allowed by default, but a network security group that narrows
that has to keep allowing the nodes to reach the API server subnet on TCP 443 and 4443, the Azure
Load Balancer to reach it on TCP 9988, and node-to-node, node-to-pod and pod-to-pod traffic on all
ports.

```sh
az network vnet subnet list -g "$RG" --vnet-name vnet-aks-prototype \
  --query "[].{name:name, nsg:networkSecurityGroup.id, routeTable:routeTable.id}" -o table
```

A route table on the subnet matters too: `outbound_type` defaults to `loadBalancer`, which assumes
the nodes can reach the internet directly. Where egress goes through a firewall, set
`outbound_type = "userDefinedRouting"` and allow the
[AKS egress endpoints](https://learn.microsoft.com/azure/aks/outbound-rules-control-egress).

## The apply fails rather than times out

Read the error before anything else - AzAPI passes the AKS message through more or less intact.

- **`AuthorizationFailed` / `LinkedAuthorizationFailed` on a subnet** - the cluster identity's role
  assignment is missing or has not propagated. See above.
- **`RequestDisallowedByPolicy`** - an Azure Policy assignment on the subscription or resource group
  is refusing the cluster. The policy name is in the error.
- **A property Azure does not recognise** - usually a setting that does not apply to the SKU.
  `schema_validation_enabled = false` means AzAPI passes the body through and Azure does the
  validating, so the message names the property.
- **`terraform plan` shows a replacement of the cluster** - check `nodeResourceGroup` and the node
  pool's `vnetSubnetID`, which are the two properties that trigger one. Neither can be changed in
  place.

## Useful reading

- [AKS Automatic in a custom virtual network](https://learn.microsoft.com/azure/aks/automatic/quick-automatic-private-custom-network)
- [Outbound network rules and FQDNs for AKS](https://learn.microsoft.com/azure/aks/outbound-rules-control-egress)
- [Node autoprovisioning](https://learn.microsoft.com/azure/aks/node-autoprovision)
