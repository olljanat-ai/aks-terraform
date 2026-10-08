variable "environment" {
  type        = string
  description = <<DESCRIPTION
The environment these resources are shared by, such as `prototype`: the clusters named
`aks-<environment>-<which one>`. Part of the shared identities' names, which the clusters work out
from their own names - see modules/conventions.
DESCRIPTION
  nullable    = false

  validation {
    condition     = can(regex("^[a-z0-9]+$", var.environment))
    error_message = "environment must be lowercase letters and digits: it is one segment of a cluster name."
  }
}

variable "location" {
  type        = string
  description = "Azure region of the shared resources - the clusters' region."
  nullable    = false
}

variable "resource_group_name" {
  type        = string
  description = "Name of the existing resource group the shared resources are created in - the clusters' resource group."
  nullable    = false
}

variable "key_vault_name" {
  type        = string
  description = <<DESCRIPTION
Name of the environment's shared Key Vault, which the clusters name in their `key_vault_name` with
`key_vault_create = false`. Key Vault names are global: 3 to 24 letters, digits and single hyphens,
starting with a letter.
DESCRIPTION
  nullable    = false

  validation {
    condition     = can(regex("^[a-zA-Z](-?[a-zA-Z0-9])+$", var.key_vault_name)) && length(var.key_vault_name) >= 3 && length(var.key_vault_name) <= 24
    error_message = "key_vault_name must be 3 to 24 letters, digits and single hyphens, starting with a letter and ending with a letter or digit."
  }
}

variable "key_vault_namespaces" {
  type = map(object({
    writers = optional(list(object({
      principal_id   = string
      principal_type = optional(string, "Group")
    })), [])
  }))
  description = <<DESCRIPTION
The namespaces with a share of the vault, in any cluster of the environment: each owns the secrets
named `<namespace>--<name>`, and reads them as the identity `id-<region>-<environment>-shared-kv-
<namespace>`, granted `Key Vault Secrets User` under an ABAC condition that holds it to them. A
cluster federates the identity with its namespace's `key-vault` service account - so a namespace
with a share in a cluster has to be listed here.

`writers` manage the namespace's secrets and no others: `Key Vault Secrets Officer` under the same
condition. Object IDs, not names.
DESCRIPTION
  nullable    = false

  validation {
    condition     = alltrue([for namespace in keys(var.key_vault_namespaces) : !strcontains(namespace, "--")])
    error_message = "A namespace owns the secrets named `<namespace>--...`, so a namespace name with `--` in it would overlap with another namespace's."
  }
  validation {
    condition = alltrue(flatten([
      for namespace in values(var.key_vault_namespaces) : [for writer in namespace.writers : contains(["Group", "ServicePrincipal", "User"], writer.principal_type)]
    ]))
    error_message = "A writer's principal_type must be Group, ServicePrincipal or User."
  }
}

variable "key_vault_admin_group_object_ids" {
  type        = list(string)
  default     = []
  description = "Entra ID groups that run the whole vault as `Key Vault Administrator`, certificates included."
  nullable    = false
}

variable "flux_github_webhook" {
  type        = bool
  default     = false
  description = <<DESCRIPTION
Whether to generate the token GitHub signs Flux webhook deliveries with, as
`flux-system--github-webhook-token`. Every cluster's Receiver reads the same token, so each answers
on the same path. `flux-system` needs a share in `key_vault_namespaces` to read it.
DESCRIPTION
  nullable    = false
}

variable "dns_zone_name" {
  type        = string
  default     = null
  description = "The public Azure DNS zone every cluster of the environment publishes its hostnames in. Null for none."
}

variable "internal_dns_zone_name" {
  type        = string
  default     = null
  description = "The Azure Private DNS zone every cluster of the environment publishes its hostnames in privately. Null for none."
}

variable "virtual_network_name" {
  type        = string
  default     = null
  description = "The existing network the clusters are in, which the private zone is linked to so that it resolves there."
}

variable "virtual_network_resource_group_name" {
  type        = string
  default     = null
  description = "Resource group of the network. Defaults to `resource_group_name`."
}

variable "create_role_assignments" {
  type        = bool
  default     = true
  description = "Whether to grant the identities and the people their access to the vault here, or leave it to whoever manages the estate's role assignments."
  nullable    = false
}

variable "subscription_id" {
  type        = string
  default     = null
  description = "Subscription to deploy into. Defaults to the one the Azure CLI or the ARM_SUBSCRIPTION_ID environment variable points at."
}

variable "container_registry_name" {
  type        = string
  default     = null
  description = <<DESCRIPTION
Name of the environment's Azure Container Registry, created here: the images the clusters run, and
the teams' Kubernetes manifests as OCI artifacts that their Flux configurations read - each cluster
with an identity of its own, so nothing is stored to read it with. Registry names are global, 5 to 50
letters and digits. Null for none.
DESCRIPTION

  validation {
    condition     = var.container_registry_name == null || can(regex("^[a-zA-Z0-9]{5,50}$", coalesce(var.container_registry_name, "-")))
    error_message = "container_registry_name must be 5 to 50 letters and digits."
  }
}
