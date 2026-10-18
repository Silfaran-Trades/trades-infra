#!/usr/bin/env bash
#
# Trades — build and push the project's OWN PostgreSQL + PostGIS image (images/postgis/Dockerfile)
# into this project's ECR, for the production host. Runs on the developer's Mac under the
# operator profile; never from an agent session (IA-004 — the push is the developer's act; the
# agent role is denied the ECR write anyway).
#
# WHY an own image: upstream has no maintained arm64 PostGIS image — `postgis/postgis:18-*` is
# amd64-only and the multi-arch `imresamu/postgis` tags froze on PostgreSQL 18.1. The Dockerfile
# is the official `postgres:<x.y>-trixie` image (digest-pinned) + the PGDG PostGIS packages at an
# exact version; the same file builds the development image (docker-compose.yml).
#
# What it does:
#   1. asserts this repository is clean and `master` equals `origin/master` (after a fetch), and
#      builds from `git archive origin/master:images/postgis` — a pristine tree, never the
#      working copy (the promote.sh rule)
#   2. refuses when ECR already holds the tag (the repository is IMMUTABLE) and prints the digest
#      ECR holds — a re-run is a no-op, never a second push
#   3. builds linux/arm64 (the host is a Graviton t4g), scans it with the repository's Trivy gate
#      (HIGH / CRITICAL with a fix available blocks — AS-018; PostgreSQL / PostGIS / OS findings
#      are fixed by a version bump in the Dockerfile; the one exclusion, gosu, is documented on
#      the Makefile target), pushes with a short-lived
#      ECR login, logs out
#   4. prints the digest ECR REPORTS for the pushed tag — THAT value is what
#      deploy/docker-compose.prod.yml pins (`${REGISTRY:?…}/trades/postgres@sha256:…`) and
#      deploy/restore-drill.sh's PG_IMAGE default, in one PR; then RUNBOOK.md § "PostgreSQL image
#      upgrade" on the host.
#
# The TAG is the image's version label (org.opencontainers.image.version in the Dockerfile,
# e.g. 18.6-postgis-3.6.4): one tag per PostgreSQL + PostGIS pair. A Dockerfile change that
# keeps both versions (a base re-pin for an OS fix) MUST bump the label's revision suffix
# (`-r2`, …) — the repository refuses a second push of a tag.
#
# Usage:  AWS_PROFILE=trades-prod scripts/publish-postgres-image.sh
#   AWS_PROFILE  default trades-prod (BR-4)      AWS_REGION  default eu-south-2
#   REGISTRY     default derived from the account id (`terraform output registry` is the same value)

set -euo pipefail

export AWS_PROFILE="${AWS_PROFILE:-trades-prod}"
export AWS_REGION="${AWS_REGION:-eu-south-2}"
export AWS_PAGER=""
PROJECT="trades"
REPO_NAME="postgres"
INFRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

log()  { printf '→ publish-postgres: %s\n' "$*"; }
die()  { printf '✗ publish-postgres: %s\n' "$*" >&2; exit 1; }

command -v docker >/dev/null 2>&1 || die "docker not found"
command -v aws >/dev/null 2>&1 || die "aws CLI not found"
docker info >/dev/null 2>&1 || die "the Docker daemon is not reachable"
docker buildx version >/dev/null 2>&1 || die "docker buildx not found (the arm64 build needs it)"

# --- 1. pristine source -------------------------------------------------------------------
git -C "$INFRA_DIR" fetch --quiet origin master || die "git fetch origin master failed"
[ -z "$(git -C "$INFRA_DIR" status --porcelain)" ] || die "trades-infra has uncommitted changes — publish from a clean checkout"
[ "$(git -C "$INFRA_DIR" rev-parse master)" = "$(git -C "$INFRA_DIR" rev-parse origin/master)" ] \
  || die "trades-infra master is not origin/master — pull first (the image is built from merged code only)"
SRC_SHA="$(git -C "$INFRA_DIR" rev-parse origin/master)"
CONTEXT="$(mktemp -d)"
trap 'rm -rf "$CONTEXT"' EXIT
git -C "$INFRA_DIR" archive "$SRC_SHA" images/postgis | tar -x -C "$CONTEXT"
[ -f "$CONTEXT/images/postgis/Dockerfile" ] || die "images/postgis/Dockerfile is not on origin/master"
TAG="$(sed -n 's/.*org\.opencontainers\.image\.version="\([^"]*\)".*/\1/p' "$CONTEXT/images/postgis/Dockerfile" | head -1)"
[ -n "$TAG" ] || die "no org.opencontainers.image.version label in images/postgis/Dockerfile — the tag comes from it"
log "source trades-infra@${SRC_SHA:0:12}, tag $TAG"

# --- 2. the session, the registry, and the immutability check -------------------------------
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)" || die "no AWS session — run \`aws sso login --profile $AWS_PROFILE\` first"
CALLER_ARN="$(aws sts get-caller-identity --query Arn --output text)"
case "$CALLER_ARN" in
  *"/${PROJECT}-production-operator/"*) ;;
  *) die "the session is not the operator role ($CALLER_ARN) — the push runs under AWS_PROFILE=trades-prod (BR-4)" ;;
esac
REGISTRY="${REGISTRY:-${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com}"
REPO="${PROJECT}/${REPO_NAME}"
DST="${REGISTRY}/${REPO}:${TAG}"

ecr_digest_for_tag() {   # → the digest, empty when the TAG is absent; dies on any other AWS error
  local out
  if out="$(aws ecr describe-images --repository-name "$REPO" --image-ids "imageTag=$1" \
      --query 'imageDetails[0].imageDigest' --output text 2>&1)"; then
    [ "$out" = "None" ] || printf '%s' "$out"
    return 0
  fi
  case "$out" in
    *ImageNotFoundException*) return 0 ;;
    *) die "aws ecr describe-images failed (not a missing tag — is the repository applied, RUNBOOK step 1?): $out" ;;
  esac
}
existing="$(ecr_digest_for_tag "$TAG")"
if [ -n "$existing" ]; then
  log "ECR already holds $REPO:$TAG — digest $existing (nothing built or pushed; the repository is IMMUTABLE)"
  PUSHED="$existing"
else
  # --- 3. build (arm64) → scan → push ---------------------------------------------------------
  log "building linux/arm64 → $DST"
  docker buildx build --platform linux/arm64 --load -t "$DST" "$CONTEXT/images/postgis"
  log "scanning $DST (make container-scan — HIGH / CRITICAL with a fix available blocks)"
  ( cd "$INFRA_DIR" && make container-scan IMAGE="$DST" ) || die "HIGH / CRITICAL finding(s) with a fix available in $DST (AS-018) — bump the Dockerfile and rebuild"
  aws ecr get-login-password | docker login --username AWS --password-stdin "$REGISTRY" >/dev/null || die "ECR login failed"
  trap 'docker logout "$REGISTRY" >/dev/null 2>&1 || true; rm -rf "$CONTEXT"' EXIT
  log "pushing $DST"
  docker push "$DST" >/dev/null || die "push failed"
  PUSHED="$(ecr_digest_for_tag "$TAG")"
  [ -n "$PUSHED" ] || die "pushed, but ECR reports no digest for $REPO:$TAG — inspect the repository before pinning anything"
fi

# --- 4. what to pin -------------------------------------------------------------------------
echo ""
echo "✓ publish-postgres: $REPO:$TAG = $PUSHED"
echo "  Pin it in ONE PR (then \`make quality\`; then RUNBOOK.md § \"PostgreSQL image upgrade\" on the host):"
echo "    deploy/docker-compose.prod.yml   image: \${REGISTRY:?set REGISTRY in deploy/.env}/${REPO}@${PUSHED}"
echo "    deploy/restore-drill.sh          PG_IMAGE default → ${REGISTRY}/${REPO}@${PUSHED} (or keep the local build tag; RUNBOOK.md)"
