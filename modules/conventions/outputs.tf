output "location_code" {
  description = "Short code of the region, for resource names. Empty for a region with no code yet - add it to local.location_codes."
  value       = local.location_code
}

output "key_vault_read_conditions" {
  description = "Per namespace, the ABAC condition that holds `Key Vault Secrets User` to reading its own secrets."
  value       = local.key_vault_read_conditions
}

output "key_vault_write_conditions" {
  description = "Per namespace, the ABAC condition that holds `Key Vault Secrets Officer` to managing its own secrets."
  value       = local.key_vault_write_conditions
}

output "shared_key_vault_identity_names" {
  description = "Per namespace, the name of the identity it reads the environment's shared Key Vault as. Empty without an environment."
  value       = local.shared_key_vault_identity_names
}
