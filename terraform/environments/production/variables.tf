# Values come from terraform.tfvars (committed — NO secret values, IA-003 / SC-013).
# `alert_email` is the one input NOT in terraform.tfvars: an inbox is personal data,
# so it arrives as `TF_VAR_alert_email` at plan time (spec § Infrastructure
# Architecture, "Inputs").

variable "project" { type = string }

variable "environment" {
  type    = string
  default = "production"
}

variable "region" {
  type        = string
  description = "The project's declared region — must match the IA-006 region lock and the environments: registry in trades-docs/workspace.md"
}

variable "instance_type" {
  type        = string
  description = "The host's instance type — sized from 10.4's measured memory (BR-11); must be in allowed_instance_types"
}

variable "allowed_instance_types" {
  type        = list(string)
  description = "The IA-006 instance allowlist carried by the permissions boundary: the host's type plus the ADR-backed graduation size (BR-5)"
}

variable "alert_email" {
  type        = string
  description = "Budget and host-alarm notifications (IA-007, BR-8, BR-30a). Passed as TF_VAR_alert_email — never committed (personal data)."
  validation {
    condition     = can(regex("^[^@[:space:]]+@[^@[:space:]]+$", var.alert_email))
    error_message = "alert_email must be an e-mail address (set TF_VAR_alert_email)."
  }
}

variable "monthly_budget_usd" {
  type        = string
  description = "The tag-filtered monthly budget, taxes included (BR-8; spec § Open Questions)"
}

variable "identity_center_permission_set" {
  type        = string
  description = "The IAM Identity Center permission set whose role may assume the operator and agent roles (BR-4) — matched as AWSReservedSSO_<name>_*"
  default     = "AdministratorAccess"
}

variable "sibling_project" {
  type        = string
  description = "The other project sharing this account; every principal here carries a Deny on its resources (BR-2, TM-1)"
  default     = "kha-energy"
}

variable "root_volume_gb" {
  type    = number
  default = 40
}
