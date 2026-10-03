# Host alarms — monitoring-ladder Rung 1 and the topic of Rung 2 (DE-006, BR-30a, AC-17).
#
# Derived from: ai-standards/templates/terraform/aws/modules/host-alarms/main.tf.template
# Adaptations (spec § Monitoring):
#   - the SNS topic's NAME is an input (`topic_name`): the root constructs the
#     topic ARN deterministically for the host's user-data (the sentinel's
#     NOTIFY_CMD) and the host role's sns:Publish — this module MUST create the
#     topic under exactly that name, or the sentinel publishes into nothing;
#   - a `CPUCreditBalance` alarm (standard credits, BR-12: a drained balance is
#     the host degrading before it dies);
#   - the template's optional disk alarm is DROPPED — no CloudWatch agent is
#     installed; disk is watched by deploy/host-sentinel.sh (plan § Decisions).
# Authoritative rules: ai-standards/standards/deployment.md § "Production
#   observability — the monitoring ladder".
#
# ALERT-ONLY by design (SNS → e-mail): no auto-recover, no auto-restart — a
# false positive must never self-inflict an outage on a host co-locating the
# database. The e-mail subscription must be CONFIRMED once from the inbox after
# the apply (HUMAN; a pending subscription silently delivers nothing).

variable "project" { type = string }
variable "environment" { type = string }
variable "instance_id" { type = string } # output `instance_id` of modules/single-host
variable "alert_email" { type = string } # the same inbox as the budget (IA-007)
variable "topic_name" {
  type        = string
  description = "The exact topic name the root constructed the ARN from (see header)"
}
variable "cpu_credit_balance_threshold" {
  type    = number
  default = 30
}

locals {
  tags = {
    project     = var.project
    environment = var.environment
    managed-by  = "terraform"
  }
}

resource "aws_sns_topic" "host_alerts" {
  name = var.topic_name
  tags = local.tags
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.host_alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# Instance status checks: StatusCheckFailed combines the system check
# (AWS-side: hardware, host network) and the instance check (kernel panic,
# exhausted memory, broken network config). Two consecutive failed minutes
# filter transient blips; missing data is breaching — a host too dead to emit
# metrics must alarm, not stay green.
resource "aws_cloudwatch_metric_alarm" "status_check" {
  alarm_name          = "${var.project}-${var.environment}-status-check-failed"
  alarm_description   = "EC2 status check failing - the host itself is unhealthy (monitoring ladder Rung 1, DE-006)"
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "breaching"
  dimensions          = { InstanceId = var.instance_id }
  alarm_actions       = [aws_sns_topic.host_alerts.arn]
  ok_actions          = [aws_sns_topic.host_alerts.arn]
  tags                = local.tags
}

# CPU credits (standard mode, BR-12): below the threshold for three 5-minute
# periods the burstable host is throttling — the graduation signal of BR-11
# before it becomes an outage.
resource "aws_cloudwatch_metric_alarm" "cpu_credit_balance" {
  alarm_name          = "${var.project}-${var.environment}-cpu-credit-balance-low"
  alarm_description   = "CPU credit balance below ${var.cpu_credit_balance_threshold} for 15 minutes - the host is throttling (BR-11 graduation signal)"
  namespace           = "AWS/EC2"
  metric_name         = "CPUCreditBalance"
  statistic           = "Minimum"
  period              = 300
  evaluation_periods  = 3
  threshold           = var.cpu_credit_balance_threshold
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "notBreaching"
  dimensions          = { InstanceId = var.instance_id }
  alarm_actions       = [aws_sns_topic.host_alerts.arn]
  ok_actions          = [aws_sns_topic.host_alerts.arn]
  tags                = local.tags
}

output "alerts_topic_arn" { value = aws_sns_topic.host_alerts.arn }
