# Single-host module — the one instance the whole project runs on (BR-6, BR-11, BR-12, BR-13).
#
# Derived from: ai-standards/templates/terraform/aws/modules/single-host/main.tf.template
# Adaptations (spec § Host; the KHA lessons of BR-39 checked against the template):
#   (a) `root_volume_gb` 40 (eleven containers, the MinIO volume, dumps, the log archive).
#   (b) metadata_options.http_put_response_hop_limit = 2 — with the default of 1
#       IMDSv2 is unreachable from bridge-network containers (KHA lesson; the
#       backup lane and the SSM agent run on the host, but a future in-container
#       AWS client must not find no credentials silently).
#   (c) the instance profile carries the project's PERMISSIONS BOUNDARY like
#       every other principal (BR-5; `permissions_boundary_arn`).
#   (d) the ECR read is an INLINE policy scoped to the five `trades/*`
#       repository ARNs (`ecr_repository_arns`) in place of the account-wide
#       managed read policy — the host cannot pull KHA's images (TM-1).
#       `ecr:GetAuthorizationToken` takes no resource.
#   (e) backups bucket: s3:ListBucket on the bucket + s3:PutObject under
#       `postgres/*` ONLY — no read, no delete, no versions, no lifecycle, no
#       `promotions/` write (BR-28, TM-4). Unconditional with a required
#       variable (no plan-time-unknown `count`, KHA lesson).
#   (f) sns:Publish on the host-alerts topic — the sentinel's alert path (BR-30a).
#   (g) user-data per the spec (user-data.sh.tpl beside this file).
# Authoritative rules: ai-standards/standards/infrastructure.md § "Host baseline"
#
# - Keyless by construction: no key_name, no SSH ingress — access is an SSM
#   session (`aws ssm start-session --target <instance-id>`), IA-009 / BR-6.
# - IMDSv2 required (http_tokens) — blocks the classic SSRF→metadata pivot.
# - The instance profile is the host's ONLY credential: SSM, its own parameter
#   path, the scoped ECR read, put-only backups, the alerts topic. No
#   long-lived key on the host (SC-012, TM-10).
# - `credit_specification = standard`: a runaway burst degrades instead of
#   billing (IA-007's philosophy applied to CPU credits; BR-12).
# - Rebuild-not-repair: everything the host needs is in user-data; replacing
#   the instance is an apply. Data that must survive lives on the EBS volume
#   (snapshots via modules/backup) and in the off-host DB dumps.

variable "project" { type = string }
variable "environment" { type = string }
variable "region" { type = string }
variable "instance_type" { type = string } # allowlisted by the boundary (modules/access, IA-006)
variable "subnet_id" { type = string }
variable "security_group_id" { type = string }
variable "root_volume_gb" {
  type    = number
  default = 40
}
# ARM64 (t4g) — every image is built linux/arm64 on the developer's Mac (ADR-125).
variable "architecture" {
  type    = string
  default = "arm64"
  validation {
    condition     = contains(["arm64", "amd64"], var.architecture)
    error_message = "architecture must be arm64 or amd64 (Canonical AMI naming)."
  }
}
variable "registry_host" {
  type        = string
  description = "<account>.dkr.ecr.<region>.amazonaws.com — wires docker's ECR credential helper for the deploy user (BR-12); the IAM grant alone is unusable by docker without it"
}
variable "permissions_boundary_arn" {
  type        = string
  description = "The project boundary (modules/access) — attached to the host role (BR-5)"
}
variable "ecr_repository_arns" {
  type        = list(string)
  description = "The five trades/* repository ARNs the host may pull from (modules/registry) — never the account-wide read policy"
}
variable "backups_bucket_arn" {
  type        = string
  description = "The backups bucket (modules/backups-bucket): list + put under postgres/* only (BR-28)"
}
variable "host_alerts_topic_arn" {
  type        = string
  description = "The SNS topic the host sentinel publishes to (BR-30a) — constructed by the root"
}
variable "swap_gb" {
  type    = number
  default = 2
}

locals {
  tags = {
    project     = var.project
    environment = var.environment
    managed-by  = "terraform"
  }
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-${var.architecture}-server-*"]
  }
  filter {
    name   = "state"
    values = ["available"]
  }
}

resource "aws_iam_role" "host" {
  name                 = "${var.project}-${var.environment}-host"
  description          = "The host's instance profile — its ONLY credential: SSM, its own parameter path, the scoped ECR read, put-only backups, the alerts topic (BR-6)."
  permissions_boundary = var.permissions_boundary_arn
  tags                 = local.tags
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# SSM session lane (keyless host access, IA-009).
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.host.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Scoped parameter-store read: the per-service env files of THIS project and
# environment only (BR-26b) — they land in the chmod-600 files
# deployment.md § "Secrets in production" owns. Both ARN shapes matter: `…/env/x`
# is what ssm:GetParameter evaluates, `…/env` what ssm:GetParametersByPath
# evaluates for the path itself.
locals {
  env_parameter_arns = [
    "arn:aws:ssm:${var.region}:*:parameter/${var.project}/${var.environment}/env",
    "arn:aws:ssm:${var.region}:*:parameter/${var.project}/${var.environment}/env/*",
  ]
}

resource "aws_iam_role_policy" "parameter_read" {
  name = "${var.project}-${var.environment}-host-parameter-read"
  role = aws_iam_role.host.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ssm:GetParameter", "ssm:GetParametersByPath"]
      Resource = local.env_parameter_arns
    }]
  })
}

# The fence around that read. AmazonSSMManagedInstanceCore (ssm_core above) itself
# allows ssm:GetParameter and ssm:GetParameters on `*`, so the Allow above is NOT
# the host's ceiling: without this Deny the host could read every parameter in the
# region — the masked agent DSN at /${project}/${environment}/agent/* included,
# which the host never needs — and a container that reaches IMDS through the hop
# limit of 2 (adaptation (b)) would inherit that read. The Deny narrows the host
# to its env path (IA-006, BR-6); the sibling's parameters are denied a second
# time by the boundary's name-based statement. `ssm:GetParameter*` covers
# GetParameter, GetParameters, GetParametersByPath and GetParameterHistory.
resource "aws_iam_role_policy" "parameter_read_fence" {
  name = "${var.project}-${var.environment}-host-parameter-fence"
  role = aws_iam_role.host.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid         = "DenyEveryParameterOutsideEnvPath"
      Effect      = "Deny"
      Action      = ["ssm:GetParameter*"]
      NotResource = local.env_parameter_arns
    }]
  })
}

# Adaptation (d): the registry read, scoped to this project's repositories.
resource "aws_iam_role_policy" "registry_pull" {
  name = "${var.project}-${var.environment}-host-registry-pull"
  role = aws_iam_role.host.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "PullProjectImages"
        Effect   = "Allow"
        Action   = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:BatchCheckLayerAvailability"]
        Resource = var.ecr_repository_arns
      },
      {
        Sid      = "RegistryLogin"
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
    ]
  })
}

# Adaptation (e): backup shipping — list + put under postgres/* only, never
# read / delete / versions / lifecycle / promotions (BR-28, TM-4).
resource "aws_iam_role_policy" "backups_bucket" {
  name = "${var.project}-${var.environment}-host-backups-put"
  role = aws_iam_role.host.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ListBackups"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = var.backups_bucket_arn
      },
      {
        Sid      = "PutDumpsOnly"
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = "${var.backups_bucket_arn}/postgres/*"
      },
    ]
  })
}

# Adaptation (f): the sentinel's alert path.
resource "aws_iam_role_policy" "host_alerts_publish" {
  name = "${var.project}-${var.environment}-host-alerts-publish"
  role = aws_iam_role.host.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["sns:Publish"]
      Resource = var.host_alerts_topic_arn
    }]
  })
}

resource "aws_iam_instance_profile" "host" {
  name = "${var.project}-${var.environment}-host"
  role = aws_iam_role.host.name
  tags = local.tags
}

resource "aws_instance" "this" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [var.security_group_id]
  iam_instance_profile   = aws_iam_instance_profile.host.name

  # Ephemeral public IP for FIRST BOOT egress (apt in user-data needs the
  # internet before the EIP below is associated; there is no NAT by design).
  # The EIP supersedes it the moment it attaches.
  associate_public_ip_address = true

  # No key_name on purpose — SSM sessions only (IA-009, BR-6).

  credit_specification {
    cpu_credits = "standard"
  }

  metadata_options {
    http_tokens                 = "required" # IMDSv2 only
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 2 # adaptation (b): reachable from bridge-network containers
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = var.root_volume_gb
    encrypted   = true
    tags        = merge(local.tags, { Snapshot = "${var.project}-${var.environment}" }) # picked up by modules/backup (env-scoped)
  }

  # Editing user-data plans as an IN-PLACE update (user_data_replace_on_change is
  # deliberately left false): the apply is a stop → modify → start (brief
  # downtime, EIP kept) and cloud-init does NOT re-run on the live host — the
  # new script only takes effect on a REBUILT host (BR-12; RUNBOOK.md § "Rebuild
  # the host"). Never set user_data_replace_on_change = true here: Postgres,
  # MinIO and the captured mail live on this root volume.
  user_data = templatefile("${path.module}/user-data.sh.tpl", {
    project               = var.project
    environment           = var.environment
    region                = var.region
    registry_host         = var.registry_host
    host_alerts_topic_arn = var.host_alerts_topic_arn
    swap_gb               = var.swap_gb
  })

  tags = merge(local.tags, { Name = "${var.project}-${var.environment}" })

  lifecycle {
    ignore_changes = [ami] # a new AMI must not silently replace the host; bump deliberately
  }
}

# Stable public address — the sslip.io hostname encodes this IP (BR-13, BR-15);
# instance replacement keeps it. Releasing the EIP invalidates the base
# hostname, the four application hostnames, the CORS origin, the cookie domain,
# every certificate and the SPA build — a cutover-level act, never routine.
resource "aws_eip" "this" {
  instance = aws_instance.this.id
  domain   = "vpc"
  tags     = merge(local.tags, { Name = "${var.project}-${var.environment}" })
}

output "instance_id" { value = aws_instance.this.id }
output "public_ip" { value = aws_eip.this.public_ip }
output "host_role_name" { value = aws_iam_role.host.name }
