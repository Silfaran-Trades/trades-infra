# Network module — single-host baseline: one VPC, one PUBLIC subnet, no NAT.
#
# Derived from: ai-standards/templates/terraform/aws/modules/network/main.tf.template
# (verbatim except the CIDR default). Authoritative rules:
# ai-standards/standards/infrastructure.md § "Host baseline".
#
# This project's VPC is 10.81.0.0/24 — KHA Energy's, in the same account, is
# 10.80.0.0/24 (BR-1, verified against KHA's network module at refinement).
#
# There is deliberately NO private subnet and NO NAT gateway in this module
# (IA-006 also denies creating one): a NAT gateway bills ~$32/month before the
# first byte and a single public host with a strict security group does not
# need it. When a private tier becomes justified, that is a graduation ADR.
#
# The security group opens 80/443 to the world (the reverse proxy) and NOTHING
# else inbound — no SSH port; host access is the SSM session lane (IA-009, BR-6).
# Postgres / Mailpit / MinIO stay on the container network, never here
# (deployment.md § "TLS and the perimeter").

variable "project" { type = string }
variable "environment" { type = string }
variable "vpc_cidr" {
  type    = string
  default = "10.81.0.0/24"
}

locals {
  tags = {
    project     = var.project
    environment = var.environment
    managed-by  = "terraform"
  }
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = merge(local.tags, { Name = "${var.project}-${var.environment}" })
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = merge(local.tags, { Name = "${var.project}-${var.environment}" })
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.vpc_cidr
  map_public_ip_on_launch = false # the host gets a stable EIP instead
  tags                    = merge(local.tags, { Name = "${var.project}-${var.environment}-public" })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }
  tags = merge(local.tags, { Name = "${var.project}-${var.environment}-public" })
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_security_group" "host" {
  name        = "${var.project}-${var.environment}-host"
  description = "Single host: HTTP/HTTPS in, everything out. No SSH - SSM sessions only."
  vpc_id      = aws_vpc.this.id
  tags        = merge(local.tags, { Name = "${var.project}-${var.environment}-host" })

  ingress {
    description = "HTTP (redirect + ACME challenge only - deployment.md)"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description      = "HTTPS"
    from_port        = 443
    to_port          = 443
    protocol         = "tcp"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

output "subnet_id" { value = aws_subnet.public.id }
output "security_group_id" { value = aws_security_group.host.id }
output "vpc_id" { value = aws_vpc.this.id }
