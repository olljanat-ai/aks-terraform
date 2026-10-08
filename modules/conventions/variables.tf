variable "location" {
  type        = string
  description = "Azure region, for its short code."
  nullable    = false
}

variable "key_vault_namespaces" {
  type        = set(string)
  default     = []
  description = "The namespaces with a share of the Key Vault: each owns the secrets named `<namespace>--<name>`."
  nullable    = false
}

variable "environment" {
  type        = string
  default     = null
  description = "The environment, such as `prototype`, for the names of its shared resources. Null for none."
}
