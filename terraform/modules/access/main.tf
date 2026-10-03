# Access — the permissions boundary, the operator role and the agent role
# (BR-4, BR-5, BR-7; AC-12, AC-13; TM-1, TM-2, TM-10).
#
# NEW module. Shaped after two KHA Energy modules (read-only reference): the
# deny-baseline of its ci-oidc-roles module and its agent-access module — with
# the differences this project needs:
#   - NO CI roles and NO OIDC provider reference (Actions is off, ADR-125). The
#     principals are the owner's Identity Center session (operator, agent) and
#     the host's instance profile + the DLM service role (modules/single-host,
#     modules/backup) — all four carry THIS boundary (BR-5).
#   - The boundary adds two statements KHA's does not have: `ProtectBoundary`
#     (the boundary cannot be edited or detached by a principal carrying it) and
#     `HandsOffSibling` (an explicit Deny on everything tagged or named
#     kha-energy — the account is shared, BR-2, TM-1).
#   - The agent role is denied EVERY parameter outside /trades/production/agent/*
#     (not only env/*), every backup / state object read and every image pull:
#     ReadOnlyAccess is account-wide, so a Deny scoped to this project's env/*
#     alone would still let an agent read KHA's parameters (plan § Decisions).
# Authoritative rules: ai-standards/standards/infrastructure.md § "Cloud access"
#   (IA-006 deny-baseline), § "AI-agent access to production" (IA-010);
#   secrets.md SC-012 (no static key anywhere — these roles are what replace
#   one), SC-013 (state is secret-bearing — denied to the agent).
#
# Guardrail design (IA-006): ONE boundary policy = a ceiling Allow plus the
# explicit Denies (an explicit Deny always wins inside a boundary). It is set as
# `permissions_boundary` on every role this state creates; the per-role
# identity policies do the real scoping. A deny-only boundary would allow
# NOTHING (boundaries are an intersection), hence the ceiling.
#
# FIRST APPLY (HUMAN, IA-004): runs under the owner's administrator Identity
# Center session — it is the only principal that can create the boundary and
# the two roles. Afterwards the owner writes the `trades-prod` (operator) and
# `trades-agent` profiles; every later plan/apply runs as the operator. A LATER
# EDIT TO THE BOUNDARY ITSELF is applied with the administrator session again:
# `ProtectBoundary` denies it to the operator by design (RUNBOOK.md).
#
# THE HONEST LIMIT (copied from KHA's module header, because it holds here too):
# agent sessions run in the owner's own shell on the owner's own workstation, so
# the owner's credentials remain reachable in principle. This role is a
# guardrail against an honest mistake — the agent asks, the cloud refuses — not
# a sandbox against an adversary. What IS mechanical: the masked DSN being the
# only database credential ever handed to a session (deploy/agent-db/), and
# `log_statement = 'all'` on the `ai_readonly` role.
#
# Trust policy shape: an IAM Principal cannot carry a wildcard, and the Identity
# Center role name ends in a hash the console assigns
# (AWSReservedSSO_<PermissionSet>_<hash>). The trust therefore names the account
# root as Principal and pins the caller with an ArnLike condition on
# aws:PrincipalArn — the documented pattern for Identity Center principals.

variable "project" { type = string }
variable "environment" { type = string }
variable "region" { type = string }
variable "allowed_instance_types" {
  type        = list(string)
  description = "IA-006 instance allowlist — ec2:RunInstances outside it is denied"
}
variable "identity_center_permission_set" {
  type        = string
  description = "The Identity Center permission set whose role may assume the operator and agent roles (matched as AWSReservedSSO_<name>_*)"
}
variable "sibling_project" {
  type        = string
  description = "The project sharing this account — the HandsOffSibling Deny names it"
}
variable "backups_bucket_arn" {
  type        = string
  description = "The backups bucket (modules/backups-bucket) — the agent is denied reading its objects"
}
variable "state_bucket_arn" {
  type        = string
  description = "The bootstrapped state bucket — the agent is denied reading its objects (SC-013)"
}
variable "env_parameter_prefix" {
  type        = string
  description = "The parameter-store path holding the per-service env files (e.g. /trades/production/env). No trailing slash."
}
variable "agent_parameter_prefix" {
  type        = string
  description = "The ONLY parameter-store path the agent may read (e.g. /trades/production/agent — the masked DSN). No trailing slash."
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  tags = {
    project     = var.project
    environment = var.environment
    managed-by  = "terraform"
  }

  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition

  boundary_name = "${var.project}-${var.environment}-boundary"
  # Constructed (not referenced) so the boundary policy can name its own ARN
  # without a self-reference.
  boundary_arn = "arn:${local.partition}:iam::${local.account_id}:policy/${local.boundary_name}"

  account_root = "arn:${local.partition}:iam::${local.account_id}:root"
  # The Identity Center permission-set role: path aws-reserved/sso.amazonaws.com/<region>/.
  trusted_principal_pattern = "arn:${local.partition}:iam::${local.account_id}:role/aws-reserved/sso.amazonaws.com/*/AWSReservedSSO_${var.identity_center_permission_set}_*"

  trust_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = local.account_root }
      Action    = "sts:AssumeRole"
      Condition = {
        ArnLike = { "aws:PrincipalArn" = local.trusted_principal_pattern }
      }
    }]
  })

  # Both ARN shapes matter: `…/agent/x` is what ssm:GetParameter(s) evaluates,
  # `…/agent` is what ssm:GetParametersByPath evaluates for the path itself.
  agent_parameter_arns = [
    "arn:${local.partition}:ssm:${var.region}:${local.account_id}:parameter${var.agent_parameter_prefix}",
    "arn:${local.partition}:ssm:${var.region}:${local.account_id}:parameter${var.agent_parameter_prefix}/*",
  ]

  # HandsOffSibling: the ARN shapes KHA's names take in the services this
  # project's principals can reach (ReadOnlyAccess / PowerUserAccess are
  # account-wide). EC2 is deliberately NOT in this list: EC2 ARNs carry a
  # resource id, never a name, so no pattern can match them — KHA's instance,
  # VPC and volumes are covered by the TAG statement alone (every Terraform-managed
  # KHA resource carries project = kha-energy). As-built limit (review, 2026-10-02):
  # an UNTAGGED KHA resource, such as a network interface AWS creates implicitly,
  # is not covered by either statement.
  sibling_arn_patterns = [
    "arn:${local.partition}:s3:::*${var.sibling_project}*",
    "arn:${local.partition}:s3:::*${var.sibling_project}*/*",
    "arn:${local.partition}:ssm:*:*:parameter/${var.sibling_project}",
    "arn:${local.partition}:ssm:*:*:parameter/${var.sibling_project}/*",
    "arn:${local.partition}:iam::*:role/${var.sibling_project}-*",
    "arn:${local.partition}:iam::*:policy/${var.sibling_project}-*",
    "arn:${local.partition}:iam::*:instance-profile/${var.sibling_project}-*",
    "arn:${local.partition}:ecr:*:*:repository/${var.sibling_project}/*",
    "arn:${local.partition}:budgets::*:budget/${var.sibling_project}-*",
    "arn:${local.partition}:cloudwatch:*:*:alarm:${var.sibling_project}-*",
    "arn:${local.partition}:sns:*:*:${var.sibling_project}-*",
  ]
}

# --- The guardrail boundary (IA-006, BR-5) — ceiling Allow + explicit Denies ----
# The description never names the sibling: it is a plain plan attribute, and AC-1's
# checker (scripts/checks/check-tf-plan.py) allows the sibling's name inside Deny
# statements only — the policy body below.
resource "aws_iam_policy" "boundary" {
  name        = local.boundary_name
  description = "Permissions boundary carried by every ${var.project} ${var.environment} principal (IA-006): region lock, instance allowlist, no purchases / quota raises / NAT, role creation needs this boundary, the boundary protects itself, hands off the sibling project's resources."
  tags        = local.tags
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # The ceiling: identity policies do the real scoping; the Denies below
        # always win over this Allow.
        Sid      = "Ceiling"
        Effect   = "Allow"
        Action   = "*"
        Resource = "*"
      },
      {
        # eu-south-2 for everything regional; us-east-1 for the global services
        # that route there (billing, IAM, STS, Budgets, Cost Explorer, Support,
        # Organizations reads).
        Sid    = "RegionLock"
        Effect = "Deny"
        NotAction = [
          "iam:*", "sts:*", "budgets:*", "ce:*", "support:*",
          "organizations:Describe*", "organizations:List*",
        ]
        Resource = "*"
        Condition = {
          StringNotEquals = { "aws:RequestedRegion" = [var.region, "us-east-1"] }
        }
      },
      {
        Sid      = "InstanceTypeAllowlist"
        Effect   = "Deny"
        Action   = ["ec2:RunInstances"]
        Resource = "arn:${local.partition}:ec2:*:*:instance/*"
        Condition = {
          # Plain negated operator = NOR over the list (AWS's documented
          # allowlist shape). ec2:InstanceType is single-valued — never use
          # ForAllValues/ForAnyValue with it.
          StringNotEquals = { "ec2:InstanceType" = var.allowed_instance_types }
        }
      },
      {
        Sid    = "NoPurchasesNoQuotaNoNat"
        Effect = "Deny"
        Action = [
          "ec2:CreateNatGateway",
          "ec2:PurchaseReservedInstancesOffering",
          "ec2:PurchaseHostReservation",
          "ec2:CreateCapacityReservation",
          "savingsplans:*",
          "aws-marketplace:Subscribe",
          "servicequotas:RequestServiceQuotaIncrease",
          "account:*",
        ]
        Resource = "*"
      },
      {
        # A principal here may only mint roles inside the project namespace…
        Sid         = "RoleCreationInsideNamespace"
        Effect      = "Deny"
        Action      = ["iam:CreateRole", "iam:PutRolePermissionsBoundary"]
        NotResource = "arn:${local.partition}:iam::*:role/${var.project}-*"
      },
      {
        # …and every role it mints carries THIS boundary (a role cannot mint a
        # stronger role).
        Sid      = "RoleCreationNeedsBoundary"
        Effect   = "Deny"
        Action   = ["iam:CreateRole", "iam:PutRolePermissionsBoundary"]
        Resource = "*"
        Condition = {
          StringNotEquals = { "iam:PermissionsBoundary" = local.boundary_arn }
        }
      },
      {
        # The boundary protects itself: no principal carrying it can rewrite it
        # or detach it from a project role. An edit to this policy is the
        # administrator session's act (module header).
        Sid    = "ProtectBoundary"
        Effect = "Deny"
        Action = [
          "iam:CreatePolicyVersion",
          "iam:DeletePolicy",
          "iam:DeletePolicyVersion",
          "iam:SetDefaultPolicyVersion",
        ]
        Resource = local.boundary_arn
      },
      {
        Sid      = "ProtectBoundaryAttachment"
        Effect   = "Deny"
        Action   = ["iam:DeleteRolePermissionsBoundary"]
        Resource = "arn:${local.partition}:iam::*:role/${var.project}-*"
      },
      {
        # The sibling project in this account is untouchable — by tag…
        Sid      = "HandsOffSiblingByTag"
        Effect   = "Deny"
        Action   = "*"
        Resource = "*"
        Condition = {
          StringEquals = { "aws:ResourceTag/project" = var.sibling_project }
        }
      },
      {
        # …and by name, for the services whose ARNs carry it.
        Sid      = "HandsOffSiblingByName"
        Effect   = "Deny"
        Action   = "*"
        Resource = local.sibling_arn_patterns
      },
    ]
  })
}

# --- The operator role (BR-4) — the `trades-prod` profile ------------------------
resource "aws_iam_role" "operator" {
  name                 = "${var.project}-${var.environment}-operator"
  description          = "The developer's production lane (plan, apply after the first, image push, promotion, host sync, restore drill, promotion records) - assumed from the Identity Center ${var.identity_center_permission_set} session; never a static key (SC-012)."
  assume_role_policy   = local.trust_policy
  max_session_duration = 3600
  permissions_boundary = local.boundary_arn
  tags                 = local.tags
  depends_on           = [aws_iam_policy.boundary]
}

resource "aws_iam_role_policy_attachment" "operator_power_user" {
  role       = aws_iam_role.operator.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/PowerUserAccess"
}

# PowerUserAccess carries no iam:* — the operator gets it ONLY inside the
# project namespace (roles, policies, instance profiles named trades-*), plus
# read of AWS managed policies (what `terraform plan` needs for the attachments).
resource "aws_iam_role_policy" "operator_iam_namespace" {
  name = "${var.project}-${var.environment}-operator-iam-namespace"
  role = aws_iam_role.operator.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ProjectNamespaceIam"
        Effect = "Allow"
        Action = "iam:*"
        Resource = [
          "arn:${local.partition}:iam::${local.account_id}:role/${var.project}-*",
          "arn:${local.partition}:iam::${local.account_id}:policy/${var.project}-*",
          "arn:${local.partition}:iam::${local.account_id}:instance-profile/${var.project}-*",
        ]
      },
      {
        Sid      = "ReadAwsManagedPolicies"
        Effect   = "Allow"
        Action   = ["iam:GetPolicy", "iam:GetPolicyVersion", "iam:ListPolicyVersions"]
        Resource = "arn:${local.partition}:iam::aws:policy/*"
      },
      {
        Sid      = "ListIam"
        Effect   = "Allow"
        Action   = ["iam:ListRoles", "iam:ListPolicies", "iam:ListInstanceProfiles"]
        Resource = "*"
      },
    ]
  })
}

# --- The agent role (BR-7, IA-010) — the `trades-agent` profile -----------------
resource "aws_iam_role" "agent" {
  name                 = "${var.project}-${var.environment}-agent"
  description          = "The deny-scoped role an AI-agent session acts under: read-only, no env parameters, no host shell, no backup / state object, no image pull. A guardrail against an honest mistake, not a sandbox."
  assume_role_policy   = local.trust_policy
  max_session_duration = 3600
  permissions_boundary = local.boundary_arn
  tags                 = local.tags
  depends_on           = [aws_iam_policy.boundary]
}

# The ceiling: read-only. The Denies below always win over it.
resource "aws_iam_role_policy_attachment" "agent_readonly" {
  role       = aws_iam_role.agent.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/ReadOnlyAccess"
}

resource "aws_iam_role_policy" "agent_denies" {
  name = "${var.project}-${var.environment}-agent-deny-unmasked-lanes"
  role = aws_iam_role.agent.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Every parameter EXCEPT the agent's own path (the masked DSN lives
        # there, outside env/*). `ssm:GetParameter*` covers GetParameter,
        # GetParameters, GetParametersByPath and GetParameterHistory.
        Sid         = "DenyEveryParameterOutsideAgentPath"
        Effect      = "Deny"
        Action      = ["ssm:GetParameter*"]
        NotResource = local.agent_parameter_arns
      },
      {
        # A shell on the host is `cat /srv/trades/secrets/app.env`. StartSession
        # is the interactive door; SendCommand is the same door with the handle
        # on the other side. Both are denied, everywhere (AC-12).
        Sid    = "DenyHostShellLanes"
        Effect = "Deny"
        Action = [
          "ssm:StartSession",
          "ssm:ResumeSession",
          "ssm:SendCommand",
          "ssm:StartAutomationExecution",
        ]
        Resource = "*"
      },
      {
        Sid      = "DenyOtherSecretStores"
        Effect   = "Deny"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = "*"
      },
      {
        # The dumps are personal data and the state is secret-bearing (SC-013).
        Sid    = "DenyBackupAndStateObjectReads"
        Effect = "Deny"
        Action = ["s3:GetObject", "s3:GetObjectVersion"]
        Resource = [
          "${var.backups_bucket_arn}/*",
          "${var.state_bucket_arn}/*",
        ]
      },
      {
        Sid      = "DenyImagePull"
        Effect   = "Deny"
        Action   = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"]
        Resource = "*"
      },
    ]
  })
}

output "boundary_arn" {
  description = "Attach as permissions_boundary to every role this project creates (BR-5)"
  value       = aws_iam_policy.boundary.arn
}
output "operator_role_arn" { value = aws_iam_role.operator.arn }
output "agent_role_arn" { value = aws_iam_role.agent.arn }
