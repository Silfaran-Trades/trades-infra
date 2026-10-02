# Terraform state backend — production root (IA-001, IA-002).
#
# Derived from: ai-standards/templates/terraform/aws/backend.tf.template
# Authoritative rules: ai-standards/standards/infrastructure.md § "State"
# Spec: Deployment/production-infrastructure-first-deploy BR-3.
#
# - Native S3 locking (`use_lockfile`) requires Terraform >= 1.11. No DynamoDB
#   lock table — deprecated in favour of the lockfile.
# - The state bucket is the ONE-TIME HUMAN BOOTSTRAP (RUNBOOK.md § "First deploy",
#   step 2): versioned, SSE, all public access blocked, named
#   `trades-terraform-state-<account-id>`. The name carries the account id, so
#   `bucket` is supplied as partial configuration at init, never hardcoded:
#     terraform init -backend-config="bucket=trades-terraform-state-<account-id>"
#   It is THIS project's bucket — never KHA Energy's (BR-2).
# - State is secret-bearing (SC-013): restrict who can read the bucket like a
#   secret store; the agent role is DENIED s3:GetObject on it (modules/access).
#   Plan files are never uploaded anywhere; `make tf-plan-check` reads the JSON
#   the HUMAN saved locally.
# - The `key` embeds the environment: two environments NEVER share a state root.

terraform {
  required_version = ">= 1.11"

  backend "s3" {
    # bucket supplied via -backend-config (account-id-suffixed; see header)
    key          = "trades/production/terraform.tfstate"
    region       = "eu-south-2"
    encrypt      = true
    use_lockfile = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.70"
    }
  }
}
