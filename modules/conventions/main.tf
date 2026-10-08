# The estate's conventions, shared by the cluster configuration at the repository root and the
# environment's shared resources in shared/: what they compute has to come out the same in both, or
# a cluster would look for a shared identity under a name nobody created, or hold a namespace to a
# share of the vault the shared configuration drew differently. No resources; only values.

locals {
  # Short code for the region, for the identity names. Azure has no standard for these, so this
  # is the estate's own convention rather than something derivable - a region that is not listed here
  # gets added here. The identity is refused rather than named with a guess.
  # Country codes ALPHA-2 & ALPHA-3: https://www.iban.com/country-codes 
  location_code = lookup(local.location_codes, var.location, "")
  location_codes = {
    finlandcentral = "fic"
    francecentral  = "frc"
    swedencentral  = "sec"
    westeurope     = "euw"
    uksouth        = "uks"
    ukwest         = "ukw"
  }

  # The identities a namespace reads the environment's shared Key Vault as - shared by every cluster
  # of the environment, created by shared/ and looked up by each cluster:
  # `id-<region code>-<environment>-shared-kv-<namespace>`. `shared` where a cluster's identity has
  # the cluster's own name, so the two never mix in a listing of the resource group.
  shared_key_vault_identity_names = var.environment == null ? {} : {
    for namespace in var.key_vault_namespaces : namespace => "id-${local.location_code}-${var.environment}-shared-kv-${namespace}"
  }

  # The share of each: the secrets whose names start with this. Key Vault names are case-insensitive
  # and compared in lowercase, which a namespace name already is.
  key_vault_secret_prefixes = { for namespace in var.key_vault_namespaces : namespace => "${namespace}--" }

  # Azure ABAC conditions (version 2.0) holding a role assignment on the vault to one namespace's
  # secrets. A condition applies to the actions it names and leaves the rest of the role alone, so
  # each says: for these actions, only a secret under the prefix. An existing secret is matched by its
  # name as a resource; one being created or restored, which does not exist yet, by the name in the
  # request.
  #
  # Reading the value of a secret - `Key Vault Secrets User`. Listing the vault is not gated: Key
  # Vault evaluates a condition on listing against the whole collection, and a name condition there
  # refuses the list outright.
  key_vault_read_conditions = {
    for namespace, prefix in local.key_vault_secret_prefixes : namespace => <<-CONDITION
      (
       (
        !(ActionMatches{'Microsoft.KeyVault/vaults/secrets/getSecret/action'})
       )
       OR
       (
        @Resource[Microsoft.KeyVault/vaults/secrets:name] StringStartsWith '${prefix}'
       )
      )
    CONDITION
  }

  # Everything `Key Vault Secrets Officer` can do to a secret, apart from listing them.
  key_vault_write_conditions = {
    for namespace, prefix in local.key_vault_secret_prefixes : namespace => <<-CONDITION
      (
       (
        !(ActionMatches{'Microsoft.KeyVault/vaults/secrets/getSecret/action'})
        AND
        !(ActionMatches{'Microsoft.KeyVault/vaults/secrets/update/action'})
        AND
        !(ActionMatches{'Microsoft.KeyVault/vaults/secrets/delete'})
        AND
        !(ActionMatches{'Microsoft.KeyVault/vaults/secrets/backup/action'})
        AND
        !(ActionMatches{'Microsoft.KeyVault/vaults/secrets/recover/action'})
        AND
        !(ActionMatches{'Microsoft.KeyVault/vaults/secrets/purge/action'})
       )
       OR
       (
        @Resource[Microsoft.KeyVault/vaults/secrets:name] StringStartsWith '${prefix}'
       )
      )
      AND
      (
       (
        !(ActionMatches{'Microsoft.KeyVault/vaults/secrets/setSecret/action'})
        AND
        !(ActionMatches{'Microsoft.KeyVault/vaults/secrets/restore/action'})
       )
       OR
       (
        @Request[Microsoft.KeyVault/vaults/secrets:name] StringStartsWith '${prefix}'
       )
      )
    CONDITION
  }
}
