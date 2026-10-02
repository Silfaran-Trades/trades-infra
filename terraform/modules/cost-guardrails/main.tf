# Cost guardrails — CUT DOWN to the tag-filtered budget (BR-8, BR-9, BR-10; AC-1, AC-20).
#
# Derived from: ai-standards/templates/terraform/aws/modules/cost-guardrails/main.tf.template
# Authoritative rules: ai-standards/standards/infrastructure.md § "Cost guardrails"
#
# IA-007 DEVIATION, recorded in ADR-124: of the template's three guardrails this
# state carries ONLY the budget. The account already holds KHA Energy's
# account-wide `EstimatedCharges` billing alarm and the account's single Cost
# Explorer anomaly monitor (one dimensional monitor per account — a second one
# fails on the limit, and importing KHA's would put it in this state). Both are
# account-wide, so they fire on this project's spend too; anomaly coverage is
# shared with KHA, and the Run Report lists the change KHA's own workspace needs
# (raise its 12 USD threshold or filter its budget by tag) — never made from here.
# The template's us-east-1 provider alias is therefore not needed and not declared.
#
# The budget is FILTERED to this project's spend through the `project`
# cost-allocation tag (`user:project$trades`). Activating `project` as a
# cost-allocation tag in the Billing console is a HUMAN step taken at least 48 h
# before the first apply (up to 24 h for the key to appear, up to 24 h more to
# activate); until then the filter matches nothing (spec § Edge Cases).
#
# DAMAGE LIMITER, not a cap (billing data lags hours). Budget ACTIONS are
# deliberately NOT enabled — they can self-inflict an outage on a billing false
# positive. The preventive layer is the boundary in modules/access (IA-006).

variable "project" { type = string }
variable "environment" { type = string }
variable "alert_email" { type = string }
variable "monthly_budget_usd" { type = string } # aws_budgets_budget wants a string
variable "cost_allocation_tag_key" {
  type    = string
  default = "project"
}

locals {
  tags = {
    project     = var.project
    environment = var.environment
    managed-by  = "terraform"
  }
  # AWS Budgets' TagKeyValue filter shape: `user:<key>$<value>`.
  tag_filter_value = format("user:%s$%s", var.cost_allocation_tag_key, var.project)
}

# Budget: actual thresholds at 50/80/100% + forecast at 100%, taxes included
# (AWS Budgets counts tax by default — spec § Open Questions "Monthly budget").
resource "aws_budgets_budget" "monthly" {
  name         = "${var.project}-${var.environment}-monthly"
  budget_type  = "COST"
  limit_amount = var.monthly_budget_usd
  limit_unit   = "USD"
  time_unit    = "MONTHLY"
  tags         = local.tags

  cost_filter {
    name   = "TagKeyValue"
    values = [local.tag_filter_value]
  }

  dynamic "notification" {
    for_each = [50, 80, 100]
    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = notification.value
      threshold_type             = "PERCENTAGE"
      notification_type          = "ACTUAL"
      subscriber_email_addresses = [var.alert_email]
    }
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.alert_email]
  }
}

output "budget_name" { value = aws_budgets_budget.monthly.name }
