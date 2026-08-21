data "azurerm_client_config" "current" {}

data "azurerm_resource_group" "this" {
  name = var.resource_group_name
}

data "azurerm_virtual_network" "this" {
  name                = var.virtual_network_name
  resource_group_name = local.virtual_network_resource_group_name
}

data "azurerm_subnet" "node" {
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
  count = var.api_server_subnet_name == null ? 0 : 1

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
resource "azurerm_user_assigned_identity" "this" {
  location            = var.location
  name                = "${var.name}-identity"
  resource_group_name = var.resource_group_name
}

# Lets the cluster join nodes, load balancers and the integrated API server to the existing network.
# Scoped to the subnets the cluster uses rather than the whole virtual network, unless
# network_role_assignment_scope says otherwise.
resource "azurerm_role_assignment" "network_contributor" {
  for_each = local.network_role_assignment_scopes

  principal_id                     = azurerm_user_assigned_identity.this.principal_id
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
  count = var.create_role_assignments && local.use_byo_private_dns_zone ? 1 : 0

  principal_id                     = azurerm_user_assigned_identity.this.principal_id
  scope                            = data.azurerm_private_dns_zone.this[0].id
  role_definition_name             = "Private DNS Zone Contributor"
  skip_service_principal_aad_check = true
}

# Azure RBAC is eventually consistent: an assignment can be returned as created and still not be in
# effect when the cluster is created seconds later, which fails the apply with an authorization error
# on the subnet. Waiting once on creation is cheaper than a half-created cluster.
resource "time_sleep" "role_assignment_propagation" {
  count = var.create_role_assignments && var.role_assignment_propagation_delay != "0s" ? 1 : 0

  create_duration = var.role_assignment_propagation_delay
  triggers = {
    network_contributor          = join(",", [for assignment in azurerm_role_assignment.network_contributor : assignment.id])
    private_dns_zone_contributor = join(",", azurerm_role_assignment.private_dns_zone_contributor[*].id)
  }
}

module "aks" {
  source  = "Azure/avm-res-containerservice-managedcluster/azurerm"
  version = "0.8.1"

  location  = var.location
  name      = var.name
  parent_id = data.azurerm_resource_group.this.id
  aad_profile = {
    admin_group_object_ids = var.entra_admin_group_object_ids
    enable_azure_rbac      = true
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
    enable_vnet_integration            = var.api_server_subnet_name == null ? null : true
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
  default_agent_pool = {
    availability_zones  = var.default_node_pool.availability_zones
    count_of            = var.default_node_pool.node_count
    enable_auto_scaling = var.default_node_pool.enable_auto_scaling
    max_count           = var.default_node_pool.enable_auto_scaling ? var.default_node_pool.max_count : null
    max_pods            = var.default_node_pool.max_pods
    min_count           = var.default_node_pool.enable_auto_scaling ? var.default_node_pool.min_count : null
    name                = var.default_node_pool.name
    os_disk_size_gb     = var.default_node_pool.os_disk_size_gb
    type                = "VirtualMachineScaleSets"
    # How the pool is rolled during an upgrade. These belong to the pool: the cluster level
    # upgrade_settings of the module only carries the force-upgrade override, and silently drops
    # anything else, because Terraform discards object attributes a type constraint does not declare.
    upgrade_settings = {
      drain_timeout_in_minutes      = var.default_node_pool.drain_timeout_minutes
      max_surge                     = var.default_node_pool.max_surge
      node_soak_duration_in_minutes = var.default_node_pool.node_soak_duration_minutes
    }
    vm_size        = var.default_node_pool.vm_size
    vnet_subnet_id = data.azurerm_subnet.node.id
  }
  dns_prefix       = var.name
  enable_telemetry = var.enable_telemetry
  fqdn_subdomain   = local.fqdn_subdomain
  # AKS Automatic places its hosted system components in a subnet of the existing network.
  hosted_system_profile = local.is_automatic && var.system_node_subnet_name != null ? {
    enabled               = true
    node_subnet_id        = data.azurerm_subnet.node.id
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
    }
  }
  kubernetes_version = var.kubernetes_version
  lock = var.lock_kind == null ? null : {
    kind = var.lock_kind
  }
  managed_identities = {
    system_assigned            = false
    user_assigned_resource_ids = [azurerm_user_assigned_identity.this.id]
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
    workload_identity = {
      enabled = true
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

# A public API server with no allowlist is reachable from anywhere on the internet, and Azure will
# not stop you from creating one. Terraform reports this as a warning rather than an error, because
# it is a legitimate choice for a throwaway cluster and a bad one for anything else.
check "api_server_exposure" {
  assert {
    condition     = var.private_cluster_enabled || length(var.api_server_authorized_ip_ranges) > 0
    error_message = "The API server of ${var.name} is public and reachable from any address. Set private_cluster_enabled = true, or list the ranges that need to reach it in api_server_authorized_ip_ranges."
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
