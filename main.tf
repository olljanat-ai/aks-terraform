data "azurerm_client_config" "current" {}

data "azurerm_resource_group" "this" {
  name = var.resource_group_name
}

# The existing network and its subnets, looked up only when the cluster is attached to one. A
# cluster that brings no network has AKS create one for it, and none of these have anything to read.
data "azurerm_virtual_network" "this" {
  count = local.byo_network ? 1 : 0

  name                = var.virtual_network_name
  resource_group_name = local.virtual_network_resource_group_name
}

data "azurerm_subnet" "node" {
  count = local.byo_network ? 1 : 0

  name                 = var.node_subnet_name
  resource_group_name  = local.virtual_network_resource_group_name
  virtual_network_name = var.virtual_network_name
}

data "azurerm_subnet" "system_node" {
  count = var.system_node_subnet_name == null ? 0 : 1

  name                 = var.system_node_subnet_name
  resource_group_name  = local.virtual_network_resource_group_name
  virtual_network_name = var.virtual_network_name
}

data "azurerm_subnet" "api_server" {
  count = local.api_server_vnet_integration ? 1 : 0

  name                 = var.api_server_subnet_name
  resource_group_name  = local.virtual_network_resource_group_name
  virtual_network_name = var.virtual_network_name
}

data "azurerm_private_dns_zone" "this" {
  count = local.use_byo_private_dns_zone ? 1 : 0

  name                = var.private_dns_zone_name
  resource_group_name = local.private_dns_zone_resource_group_name
}

# Cluster tags are maintained outside Terraform, by the automation running against the cluster. They
# are read back here and handed to the module unchanged, so that Terraform leaves them alone. Without
# that every plan proposes deleting them, and the resulting update turns every computed cluster
# attribute - FQDN, node resource group, OIDC issuer URL - unknown again. The cluster is listed
# rather than looked up directly, because it does not exist yet on the first apply and a lookup of a
# missing resource is an error.
data "azapi_resource_list" "managed_clusters" {
  parent_id = data.azurerm_resource_group.this.id
  type      = "Microsoft.ContainerService/managedClusters@${local.aks_api_version}"
  response_export_values = {
    tags = "value[?name=='${var.name}'] | [0].tags"
  }
}

# AKS needs an identity that already exists when the cluster is created, so that it can be granted
# access to the pre-existing network and private DNS zone. A system assigned identity cannot be used
# for that, because it only comes into existence together with the cluster.
#
# A cluster that brings no network has nothing of the sort to be granted, and an Automatic one is
# refused by Azure unless it runs on a system assigned identity - so there the cluster's own identity
# is used and none is created here.
resource "azurerm_user_assigned_identity" "this" {
  count = local.system_assigned_identity ? 0 : 1

  location            = var.location
  name                = local.managed_identity_name
  resource_group_name = var.resource_group_name

  # An identity cannot be renamed in place, so a new name replaces it. Building the replacement
  # first means the cluster is updated from one live identity to another, rather than losing the
  # one it has while the new one is created - which would leave a running cluster unable to reach
  # the network it is attached to. The two names differ, so nothing collides while both exist.
  lifecycle {
    create_before_destroy = true

    precondition {
      condition     = local.location_code != ""
      error_message = "No short code is known for ${var.location}, so the identity of ${var.name} cannot be named. Add it to local.location_codes in locals.tf."
    }
  }
}

# The identity became countable when clusters that bring no network arrived. Without this, every
# cluster that already has one would have it destroyed and rebuilt under the new address - and a
# running cluster pointing at an identity that no longer exists loses access to its network.
moved {
  from = azurerm_user_assigned_identity.this
  to   = azurerm_user_assigned_identity.this[0]
}

# Lets the cluster join nodes, load balancers and the integrated API server to the existing network.
# A Base cluster is scoped to the subnets it uses; AKS Automatic is scoped to the whole virtual
# network, because node autoprovisioning needs it. Either can be overridden through
# network_role_assignment_scope.
resource "azurerm_role_assignment" "network_contributor" {
  for_each = local.network_role_assignment_scopes

  principal_id                     = azurerm_user_assigned_identity.this[0].principal_id
  scope                            = each.value
  role_definition_name             = "Network Contributor"
  skip_service_principal_aad_check = true
}

# Clusters created before the assignment was scoped down keep the virtual network wide one when they
# ask for it, instead of dropping and recreating it. With the default subnet scope the wide
# assignment is replaced by the narrow ones, which is the point of the change.
moved {
  from = azurerm_role_assignment.network_contributor[0]
  to   = azurerm_role_assignment.network_contributor["virtual_network"]
}

# Lets the cluster register the API server record in the existing private DNS zone.
resource "azurerm_role_assignment" "private_dns_zone_contributor" {
  count = local.create_private_dns_zone_assignment ? 1 : 0

  principal_id                     = azurerm_user_assigned_identity.this[0].principal_id
  scope                            = data.azurerm_private_dns_zone.this[0].id
  role_definition_name             = "Private DNS Zone Contributor"
  skip_service_principal_aad_check = true
}

# Azure RBAC is eventually consistent: an assignment can be returned as created and still not be in
# effect when the cluster is created seconds later, which fails the apply with an authorization error
# on the subnet. Waiting once on creation is cheaper than a half-created cluster.
resource "time_sleep" "role_assignment_propagation" {
  count = (length(local.network_role_assignment_scopes) > 0 || local.create_private_dns_zone_assignment) && var.role_assignment_propagation_delay != "0s" ? 1 : 0

  create_duration = var.role_assignment_propagation_delay
  triggers = {
    network_contributor          = join(",", [for assignment in azurerm_role_assignment.network_contributor : assignment.id])
    private_dns_zone_contributor = join(",", azurerm_role_assignment.private_dns_zone_contributor[*].id)
  }
}

module "aks" {
  # FixMe: Waiting for https://github.com/Azure/terraform-azurerm-avm-res-containerservice-managedcluster/pull/297
  source = "git::https://github.com/Azure/terraform-azurerm-avm-res-containerservice-managedcluster.git?ref=099362f89c16452429e5b92489d6a1d93051d96b"
  # source  = "Azure/avm-res-containerservice-managedcluster/azurerm"
  # version = "0.8.1"

  location  = var.location
  name      = var.name
  parent_id = data.azurerm_resource_group.this.id
  aad_profile = {
    admin_group_object_ids = local.kubernetes_rbac_admin_group_object_ids
    enable_azure_rbac      = local.azure_rbac_enabled
    managed                = true
    tenant_id              = data.azurerm_client_config.current.tenant_id
  }
  # Gatekeeper, so that Azure Policy definitions are actually enforced inside the cluster.
  addon_profile_azure_policy = {
    enabled = var.azure_policy_enabled
  }
  # Container Insights stays off: node and pod telemetry is collected by the third party agent that
  # runs inside the cluster. AKS Automatic turns the add-on on by itself unless the request says
  # otherwise, so it is disabled explicitly rather than left out. It goes through
  # `addon_profiles_extra` because `addon_profile_oms_agent` insists on a workspace to name even
  # when the add-on is being turned off.
  addon_profiles_extra = {
    omsagent = {
      enabled = false
    }
  }
  api_server_access_profile = {
    authorized_ip_ranges               = local.api_server_authorized_ip_ranges
    enable_private_cluster             = var.private_cluster_enabled
    enable_private_cluster_public_fqdn = var.private_cluster_enabled ? var.private_cluster_public_fqdn_enabled : null
    enable_vnet_integration            = local.api_server_vnet_integration ? true : null
    private_dns_zone                   = local.private_dns_zone
    subnet_id                          = one(data.azurerm_subnet.api_server[*].id)
  }
  # Azure Monitor managed Prometheus. On by default on AKS Automatic as well, and replaced by the
  # same third party metrics pipeline.
  azure_monitor_profile = {
    metrics = {
      enabled = false
    }
  }
  cluster_timeouts   = var.cluster_timeouts
  default_agent_pool = local.default_agent_pool
  dns_prefix         = var.name
  enable_telemetry   = var.enable_telemetry
  fqdn_subdomain     = local.fqdn_subdomain
  # AKS Automatic places its hosted system components in a subnet of the existing network. A cluster
  # that brings no network sends no profile at all, and AKS hosts them in the network it creates.
  hosted_system_profile = local.is_automatic && var.system_node_subnet_name != null ? {
    enabled               = true
    node_subnet_id        = one(data.azurerm_subnet.node[*].id)
    system_node_subnet_id = one(data.azurerm_subnet.system_node[*].id)
  } : null
  # Ingress is handled by a third party controller installed into the cluster, so every managed
  # ingress AKS offers is turned off: App Routing with its NGINX controller, the Istio based Gateway
  # API implementation App Routing can front it with, and the managed Gateway API installation. All
  # three are stated rather than left out, because AKS Automatic enables App Routing unless the
  # create request says otherwise - and because the module cannot validate a partially filled
  # ingress_profile: it reads through the nested objects and fails on the ones left null.
  ingress_profile = {
    gateway_api = {
      installation = "Disabled"
    }
    web_app_routing = {
      enabled = false
      gateway_api_implementations = {
        app_routing_istio = {
          mode = "Disabled"
        }
      }
      nginx = {
        default_ingress_controller_type = "None"
      }
    }
  }
  kubernetes_version = var.kubernetes_version
  lock = var.lock_kind == null ? null : {
    kind = var.lock_kind
  }
  # The identity created above, or the cluster's own where Azure insists on one - see
  # local.system_assigned_identity. The splat is empty in that case, which leaves `SystemAssigned`.
  managed_identities = {
    system_assigned            = local.system_assigned_identity
    user_assigned_resource_ids = azurerm_user_assigned_identity.this[*].id
  }
  # Cost analysis, which is the one Azure side telemetry these clusters do keep: it feeds Azure Cost
  # Management rather than Azure Monitor, and it is the only place the spend of a namespace or a
  # deployment can be seen at all. Off on the Free tier, where Azure rejects it.
  metrics_profile = {
    cost_analysis = {
      enabled = local.cost_analysis_enabled
    }
  }
  network_profile = var.network_profile
  sku = {
    name = var.sku_name
    tier = var.sku_tier
  }
  tags = local.cluster_tags

  disable_local_accounts = true
  # Workload identity federates Kubernetes service accounts with Entra ID, which only works when the
  # cluster publishes an OIDC issuer. Azure rejects the one without the other, and the
  # `oidc_issuer_url` output stays null until the issuer is on.
  oidc_issuer_profile = {
    enabled = true
  }
  security_profile = {
    # Defender for Containers is off, like the rest of the Azure monitoring stack. Stated rather
    # than left out, because a subscription with the Defender for Containers plan and its
    # auto-provisioning on turns the agent on by itself.
    defender = {
      security_monitoring = {
        enabled = false
      }
    }
    image_cleaner = {
      enabled        = true
      interval_hours = 168
    }
  }

  auto_upgrade_profile = {
    node_os_upgrade_channel = var.auto_upgrade.node_os_channel
    upgrade_channel         = var.auto_upgrade.kubernetes_channel
  }
  depends_on = [
    azurerm_role_assignment.network_contributor,
    azurerm_role_assignment.private_dns_zone_contributor,
    time_sleep.role_assignment_propagation,
  ]
}

# Cluster admin for the Entra ID groups that are meant to have it, under Azure RBAC. The groups the
# cluster itself carries in its Entra ID profile - `admin_group_object_ids` above - are not honored
# in this mode, so the grant is a role assignment on the cluster instead, and the same list means
# one or the other depending on how the cluster authorizes. `Azure Kubernetes Service RBAC Cluster
# Admin` is the Azure role that answers to `cluster-admin` inside the cluster.
#
# It does not let anyone download a kubeconfig: that takes `Azure Kubernetes Service Cluster User
# Role` on the cluster, which is a control plane role and is not created here.
resource "azurerm_role_assignment" "entra_cluster_admin" {
  for_each = toset(local.create_entra_group_role_assignments ? var.entra_admin_group_object_ids : [])

  principal_id         = each.value
  scope                = module.aks.resource_id
  role_definition_name = "Azure Kubernetes Service RBAC Cluster Admin"
  # Stated, so that Azure takes the object ID as given rather than looking the principal up: a group
  # created moments ago has not replicated everywhere yet, and the assignment fails on a principal
  # Azure cannot find.
  principal_type = "Group"
}

# Read-only access for the Entra ID groups that only need to look. `Azure Kubernetes Service RBAC
# Reader` reads most objects in every namespace, but not `Secrets` - reading those is a way to act
# as any service account in the namespace - and not roles or role bindings.
#
# Azure RBAC only. Kubernetes RBAC has no counterpart: the cluster's Entra ID profile carries admin
# groups and nothing else, so a reader group has nowhere to go and the check below says so.
resource "azurerm_role_assignment" "entra_reader" {
  for_each = toset(local.create_entra_group_role_assignments ? var.entra_reader_group_object_ids : [])

  principal_id         = each.value
  scope                = module.aks.resource_id
  role_definition_name = "Azure Kubernetes Service RBAC Reader"
  principal_type       = "Group"
}

# A public API server with no allowlist is reachable from anywhere on the internet, and Azure will
# not stop you from creating one. Terraform reports this as a warning rather than an error, because
# it is a legitimate choice for a throwaway cluster and a bad one for anything else.
check "api_server_exposure" {
  assert {
    condition     = var.private_cluster_enabled || length(var.api_server_authorized_ip_ranges) > 0
    error_message = "The API server of ${var.name} is public and reachable from any address. Set private_cluster_enabled = true, or list the ranges that need to reach it in api_server_authorized_ip_ranges."
  }
}

# Microsoft documents a delegated API server subnet as required for an AKS Automatic cluster in an
# existing virtual network - the API server is injected into that subnet, and there is nowhere else
# in the network for it to go. Terraform warns rather than refuses, because the requirement is
# Microsoft's rather than something that can be checked here, and Azure has the final say.
#
# An environment that has turned the integration off through api_server_vnet_integration_enabled is
# left alone: the missing subnet is the decision there, not an omission, and a warning on every plan
# would only train people to ignore this one. So is a cluster that brings no network - the
# requirement is about an existing virtual network, and there is none.
check "automatic_api_server_subnet" {
  assert {
    condition     = !local.is_automatic || !local.byo_network || !var.api_server_vnet_integration_enabled || var.api_server_subnet_name != null
    error_message = "${var.name} is an AKS Automatic cluster in an existing virtual network with no api_server_subnet_name, so API Server VNet Integration is off. Microsoft documents a subnet delegated to Microsoft.ContainerService/managedClusters as required for this combination; Azure may refuse the cluster or leave it in Creating. Set api_server_vnet_integration_enabled = false to state that this is deliberate."
  }
}

# Pods and services on a range that also belongs to the existing network have nowhere to route to.
# Azure creates the cluster regardless and the damage only shows once something tries to talk across
# it, so this is checked before the apply rather than discovered afterwards.
#
# It matters most for AKS Automatic. The module drops the whole network profile for that SKU while
# `outbound_type` is `loadBalancer`, so the ranges below are Azure's own defaults rather than the
# ones network_profile asks for - and Azure's default service range, 10.0.0.0/16, collides with a
# great many existing networks. The ranges cannot be changed after the cluster is created.
check "cluster_cidrs_do_not_overlap_the_network" {
  assert {
    condition     = length(local.overlapping_cluster_cidrs) == 0
    error_message = "The cluster-internal ranges of ${var.name} collide with the address space of ${coalesce(var.virtual_network_name, "the existing network")}: ${join(", ", local.overlapping_cluster_cidrs)}.${local.network_profile_is_sent ? " Move network_profile.pod_cidr and network_profile.service_cidr out of the way." : " These are Azure's defaults, because an AKS Automatic cluster on loadBalancer egress is sent no network profile at all - see the AKS Automatic section of the README."}"
  }
}

# AKS Automatic cannot bring its own node pools up without Network Contributor on the whole virtual
# network. This only fires when an environment overrides the scope back down to the subnets, since
# that is otherwise the default for Base clusters only. A cluster with no network of its own grants
# nothing and needs nothing granted: AKS owns the network it creates.
check "automatic_network_role_assignment_scope" {
  assert {
    condition     = !local.is_automatic || !local.byo_network || !var.create_role_assignments || local.network_role_assignment_scope == "virtual_network"
    error_message = "${var.name} is an AKS Automatic cluster scoped to its subnets. Node autoprovisioning creates node pools the subnet assignments do not cover, and the cluster can sit in Creating until it times out. Leave network_role_assignment_scope unset, or set it to \"virtual_network\"."
  }
}

# Azure preconfigures an Automatic cluster with Microsoft Entra ID authentication with Azure RBAC and
# gives it no way off, so `azure_rbac_enabled = false` is overridden rather than sent. The groups are
# granted through role assignments regardless of what the variable says, and this warns that the
# variable is not what decided it.
check "automatic_is_always_authorized_through_azure_rbac" {
  assert {
    condition     = !local.is_automatic || var.azure_rbac_enabled
    error_message = "${var.name} is an AKS Automatic cluster with azure_rbac_enabled = false. Azure preconfigures Automatic with Microsoft Entra ID authentication with Azure RBAC, so the cluster is authorized that way regardless and the Entra ID groups are granted their access as role assignments on it. Leave azure_rbac_enabled unset, or use the Base SKU to authorize through Kubernetes RBAC."
  }
}

# Read-only access exists in Azure RBAC only. Under Kubernetes RBAC the cluster's Entra ID profile
# takes admin groups and nothing else, so listed reader groups are granted nothing at all - by
# Terraform or by anyone else - and the silence is worth a word.
check "reader_groups_need_azure_rbac" {
  assert {
    condition     = local.azure_rbac_enabled || length(var.entra_reader_group_object_ids) == 0
    error_message = "${var.name} authorizes through Kubernetes RBAC, where entra_reader_group_object_ids has no equivalent: the cluster's Entra ID profile carries admin groups only, so those ${length(var.entra_reader_group_object_ids)} group(s) are granted nothing. Set azure_rbac_enabled = true to grant them Azure Kubernetes Service RBAC Reader, or bind them inside the cluster with a Kubernetes ClusterRoleBinding."
  }
}

# With role assignments managed elsewhere, the groups are named here but granted somewhere else -
# and nobody notices until the first kubectl comes back forbidden.
check "entra_groups_are_granted_somewhere" {
  assert {
    condition     = var.create_role_assignments || !local.azure_rbac_enabled || length(var.entra_admin_group_object_ids) + length(var.entra_reader_group_object_ids) == 0
    error_message = "${var.name} has create_role_assignments = false, so the Entra ID groups listed for it are not granted anything here. Assign Azure Kubernetes Service RBAC Cluster Admin to entra_admin_group_object_ids and Azure Kubernetes Service RBAC Reader to entra_reader_group_object_ids on the cluster wherever the role assignments of this estate are managed."
  }
}

# A bring-your-own private DNS zone is registered by the cluster identity, which has to hold Private
# DNS Zone Contributor before the cluster is created. A system assigned identity does not exist until
# then, so the grant cannot be made in advance and the create can fail to register its record.
check "byo_private_dns_zone_has_an_identity_to_grant" {
  assert {
    condition     = !local.system_assigned_identity || !local.use_byo_private_dns_zone
    error_message = "${var.name} is a private AKS Automatic cluster on the network AKS manages, so it runs on a system assigned identity that does not exist until the cluster does - and ${coalesce(var.private_dns_zone_name, "the private DNS zone")} cannot be granted to it in advance. Use the AKS-managed zone (leave private_dns_zone_name unset), or attach the cluster to an existing virtual network, which lets it run on the identity created here."
  }
}

# The upgrade windows. Azure fixes the three names: `default` covers the weekly AKS release of the
# control plane and add-ons, `aksManagedAutoUpgradeSchedule` the Kubernetes version upgrade driven by
# `upgrade_channel`, and `aksManagedNodeOSUpgradeSchedule` the node image patching driven by
# `node_os_upgrade_channel`. The windows are identical and therefore overlap, which is allowed - AKS
# picks the order it runs them in.
#
# These are written directly instead of through the module, because the module always sends a
# `startDate` - null when it is not set - while Azure answers with the date the configuration was
# created. That difference turns up as an update in every subsequent plan, and Azure rejects a
# request carrying a startDate that has since fallen into the past, so the value cannot simply be
# pinned either. AzAPI only tracks the properties the body declares, so leaving startDate out keeps
# it entirely server-side: the window activates immediately, which is what an unset startDate means.
resource "azapi_resource" "maintenance_configuration" {
  for_each = toset(["aksManagedAutoUpgradeSchedule", "aksManagedNodeOSUpgradeSchedule", "default"])

  name      = each.key
  parent_id = module.aks.resource_id
  type      = "Microsoft.ContainerService/managedClusters/maintenanceConfigurations@${local.aks_api_version}"
  body = {
    properties = {
      maintenanceWindow = {
        durationHours = var.maintenance_window.duration_hours
        schedule = {
          weekly = {
            dayOfWeek     = var.maintenance_window.day_of_week
            intervalWeeks = var.maintenance_window.interval_weeks
          }
        }
        startTime = var.maintenance_window.start_time
        utcOffset = var.maintenance_window.utc_offset
      }
    }
  }
  # AzAPI's embedded AKS schema does not cover that API version yet. Azure still validates it.
  schema_validation_enabled = false
}

# Clusters that already ran the module-managed configurations keep them, rather than having their
# upgrade windows deleted and recreated. Safe to drop once every environment has applied this.
moved {
  from = module.aks.module.maintenanceconfiguration["aksManagedAutoUpgradeSchedule"].azapi_resource.this
  to   = azapi_resource.maintenance_configuration["aksManagedAutoUpgradeSchedule"]
}

moved {
  from = module.aks.module.maintenanceconfiguration["aksManagedNodeOSUpgradeSchedule"].azapi_resource.this
  to   = azapi_resource.maintenance_configuration["aksManagedNodeOSUpgradeSchedule"]
}

moved {
  from = module.aks.module.maintenanceconfiguration["default"].azapi_resource.this
  to   = azapi_resource.maintenance_configuration["default"]
}
