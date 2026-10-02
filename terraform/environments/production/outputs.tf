# Outputs (BR-15, spec § Infrastructure Architecture "Outputs") — the values the
# first deploy consumes (RUNBOOK.md § "First deploy"): deploy/.env, the SPA build
# arguments, the profiles, the mirror push and workspace.md's environments: entry.
# None of them is a secret.

output "instance_id" {
  description = "The host — `aws ssm start-session --target <this>` (IA-009); workspace.md environments.production.host"
  value       = module.host.instance_id
}

output "public_ip" {
  description = "The Elastic IP — load-bearing (BR-13): the public hostname, the four application hostnames, the CORS origin, the cookie domain and the SPA build all encode it"
  value       = module.host.public_ip
}

output "public_hostname" {
  description = "The base hostname <eip-with-dashes>.sslip.io (BR-15): DOMAIN in deploy/.env; app./api./media./storage./mail. hang off it"
  value       = local.public_hostname
}

output "registry" {
  description = "The ECR registry host: REGISTRY in deploy/.env; the host's credential helper is scoped to it"
  value       = local.registry_host
}

output "ecr_repository_urls" {
  description = "name → URL of the five repositories (the three deployables + the mirrored minio / mc images)"
  value       = module.registry.repository_urls
}

output "backups_bucket" {
  description = "BACKUPS_BUCKET in deploy/.env — nightly dumps under postgres/, promotion records under promotions/"
  value       = module.backups_bucket.bucket_name
}

output "operator_role_arn" {
  description = "trades-production-operator — the `trades-prod` profile assumes it (BR-4)"
  value       = module.access.operator_role_arn
}

output "agent_role_arn" {
  description = "trades-production-agent — the `trades-agent` profile assumes it (BR-7)"
  value       = module.access.agent_role_arn
}

output "host_alerts_topic_arn" {
  description = "The SNS topic the host alarms and the host sentinel publish to (BR-30a); confirm its e-mail subscription after the apply"
  value       = module.host_alarms.alerts_topic_arn
}
