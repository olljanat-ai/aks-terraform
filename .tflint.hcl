# Ruleset versions are pinned so that a new release cannot turn a green branch red on its own.
# `tflint --init` installs the plugin; CI does that for you.

plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

plugin "azurerm" {
  enabled = true
  version = "0.29.0"
  source  = "github.com/terraform-linters/tflint-ruleset-azurerm"
}
