locals {
  # Authorized IP ranges only apply to a public API server; an empty list means "no restriction".
  api_server_authorized_ip_ranges = var.private_cluster_enabled || length(var.api_server_authorized_ip_ranges) == 0 ? null : var.api_server_authorized_ip_ranges
  # Tags the cluster already carries in Azure, or null while it does not exist yet or carries none.
  # Feeding them back keeps the tags out of the plan instead of having Terraform delete them.
  cluster_tags = try(data.azapi_resource_list.managed_clusters.output.tags, null)
  # Azure rejects a dnsPrefix when a custom private DNS zone is used and requires an fqdnSubdomain
  # instead. AKS Automatic derives both itself.
  fqdn_subdomain = local.is_automatic ? null : (local.use_byo_private_dns_zone ? coalesce(var.fqdn_subdomain, var.name) : var.fqdn_subdomain)
  is_automatic   = var.sku_name == "Automatic"
  # Every upgrade AKS performs on its own is held to the same window: the weekly AKS release of the
  # control plane and add-ons (`default`), the Kubernetes version upgrade driven by
  # `upgrade_channel` (`aksManagedAutoUpgradeSchedule`) and the node image patching driven by
  # `node_os_upgrade_channel` (`aksManagedNodeOSUpgradeSchedule`). Azure fixes the three names. The
  # windows are identical and therefore overlap, which is allowed - AKS picks the order it runs
  # them in. Work already started when the window closes runs to completion; nothing new begins.
  maintenance_configurations = {
    for name in ["aksManagedAutoUpgradeSchedule", "aksManagedNodeOSUpgradeSchedule", "default"] :
    name => {
      name = name
      maintenance_window = {
        duration_hours = var.maintenance_window.duration_hours
        schedule = {
          weekly = {
            day_of_week    = var.maintenance_window.day_of_week
            interval_weeks = var.maintenance_window.interval_weeks
          }
        }
        start_time = var.maintenance_window.start_time
        utc_offset = var.maintenance_window.utc_offset
      }
    }
  }
  private_dns_zone                     = var.private_cluster_enabled ? (local.use_byo_private_dns_zone ? one(data.azurerm_private_dns_zone.this[*].id) : "system") : null
  private_dns_zone_resource_group_name = coalesce(var.private_dns_zone_resource_group_name, var.resource_group_name)
  use_byo_private_dns_zone             = var.private_cluster_enabled && var.private_dns_zone_name != null
  virtual_network_resource_group_name  = coalesce(var.virtual_network_resource_group_name, var.resource_group_name)
}
