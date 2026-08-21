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
- `Failed` - Azure gave up too, and the reason is in the deployment operations below.
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

### Missing `Network Contributor` on the virtual network (AKS Automatic)

The most likely reason an Automatic cluster hangs where an equivalent `Base` cluster succeeds.
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

### The API server subnet is not delegated, or is too small

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

Terraform warns about this on every plan, but to check a cluster that already exists:

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
