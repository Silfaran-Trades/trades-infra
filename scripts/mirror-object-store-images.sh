#!/usr/bin/env bash
#
# Trades — the ONE-TIME push of the cached MinIO and mc images into this project's ECR
# (production-infrastructure-first-deploy BR-33, ADR-126; AC-24). Runs on the developer's Mac
# under the operator profile, in Phase 7 step 6 — after the first apply created the two
# repositories and before the compose digests are pinned.
#
# WHY: MinIO's community edition stopped publishing images in October 2025 and both 10.4
# digests return "no such manifest" upstream (verified 2026-10-02); only the developer's local
# image cache holds them (arm64). Stage 1 therefore runs the cached images from ECR, by digest.
# The software receives no fixes — accepted for synthetic media only; native S3 before the
# first real data (BR-29, BR-33).
#
# What it does, per image:
#   1. asserts the EXACT cached reference (tag@digest, the 10.4 pins) is present locally — never
#      a `latest`, never a re-pull (there is nothing to pull from)
#   2. refuses when ECR already holds the tag (the repositories are IMMUTABLE; a second push
#      would be rejected anyway) and prints the digest ECR holds
#   3. tags it `<registry>/trades/<name>:<release tag>`, logs in with a short-lived
#      `aws ecr get-login-password`, pushes, logs out
#   4. prints the digest ECR REPORTS for the pushed tag — THAT value is what
#      deploy/docker-compose.prod.yml pins (`${REGISTRY:?…}/trades/<name>@sha256:…`), in one PR
#      with deploy/production/web.build-args (Phase 7 step 6). The digest ECR reports is the
#      pushed manifest's, which for a single-platform push differs from the upstream
#      manifest-LIST digest the compose carries today — do not expect them to be equal.
#
# Usage:  AWS_PROFILE=trades-prod scripts/mirror-object-store-images.sh
#   AWS_PROFILE  default trades-prod (BR-4)      AWS_REGION  default eu-south-2
#   REGISTRY     default derived from the account id (`terraform output registry` is the same value)
#
# Never run from an agent session (IA-004: the push is the developer's act); the agent role
# is denied ecr:BatchGetImage / GetDownloadUrlForLayer anyway.

set -euo pipefail

export AWS_PROFILE="${AWS_PROFILE:-trades-prod}"
export AWS_REGION="${AWS_REGION:-eu-south-2}"
export AWS_PAGER=""
PROJECT="trades"

# The exact 10.4 references (deploy/docker-compose.prod.yml before 10.6) — tag@digest.
MINIO_SRC="quay.io/minio/minio:RELEASE.2025-09-07T16-13-09Z@sha256:14cea493d9a34af32f524e538b8346cf79f3321eff8e708c1e2960462bd8936e"
MC_SRC="quay.io/minio/mc:RELEASE.2025-08-13T08-35-41Z@sha256:a7fe349ef4bd8521fb8497f55c6042871b2ae640607cf99d9bede5e9bdf11727"

log()  { printf '→ mirror: %s\n' "$*"; }
die()  { printf '✗ mirror: %s\n' "$*" >&2; exit 1; }

command -v docker >/dev/null 2>&1 || die "docker not found"
command -v aws >/dev/null 2>&1 || die "aws CLI not found"
docker info >/dev/null 2>&1 || die "the Docker daemon is not reachable"

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)" || die "no AWS session — run \`aws sso login --profile $AWS_PROFILE\` first"
CALLER_ARN="$(aws sts get-caller-identity --query Arn --output text)"
case "$CALLER_ARN" in
  *"/${PROJECT}-production-operator/"*) ;;
  *) die "the session is not the operator role ($CALLER_ARN) — the mirror push runs under AWS_PROFILE=trades-prod (BR-4)" ;;
esac
REGISTRY="${REGISTRY:-${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com}"
log "registry $REGISTRY (operator session)"

ecr_digest_for_tag() {   # ecr_digest_for_tag <repo> <tag> → the digest or empty
  aws ecr describe-images --repository-name "$1" --image-ids "imageTag=$2" \
    --query 'imageDetails[0].imageDigest' --output text 2>/dev/null | grep -v '^None$' || true
}

aws ecr get-login-password | docker login --username AWS --password-stdin "$REGISTRY" >/dev/null \
  || die "ECR login failed"
trap 'docker logout "$REGISTRY" >/dev/null 2>&1 || true' EXIT

PINS=()
for pair in "minio|$MINIO_SRC" "mc|$MC_SRC"; do
  name="${pair%%|*}"; src="${pair#*|}"
  release_tag="${src#*:}"; release_tag="${release_tag%%@*}"
  repo="${PROJECT}/${name}"
  dst="${REGISTRY}/${repo}:${release_tag}"

  # 1. the exact cached image
  docker image inspect "$src" >/dev/null 2>&1 \
    || die "cached image $src not found — upstream no longer serves it (ADR-126); the push must come from the cache that ran the 10.4 rehearsal"
  log "$name: cached $src present (id $(docker image inspect -f '{{.Id}}' "$src" | cut -c8-19))"

  # 2. already mirrored? IMMUTABLE tags: never push twice
  existing="$(ecr_digest_for_tag "$repo" "$release_tag")"
  if [ -n "$existing" ]; then
    log "$name: ECR already holds $repo:$release_tag — digest $existing (nothing pushed; the repository is IMMUTABLE)"
    PINS+=("$name|$existing")
    continue
  fi

  # 3. tag + push (single platform — the Mac's arm64 cache; the host is arm64)
  docker tag "$src" "$dst"
  log "$name: pushing $dst"
  docker push "$dst" >/dev/null || die "$name: push failed"

  # 4. the digest ECR reports
  pushed="$(ecr_digest_for_tag "$repo" "$release_tag")"
  [ -n "$pushed" ] || die "$name: pushed, but ECR reports no digest for $repo:$release_tag — inspect the repository before pinning anything"
  log "$name: ECR digest $pushed"
  PINS+=("$name|$pushed")
done

echo ""
echo "✓ mirror: done. Pin THESE digests in deploy/docker-compose.prod.yml (Phase 7 step 6, one PR with deploy/production/web.build-args):"
for pin in "${PINS[@]}"; do
  name="${pin%%|*}"; digest="${pin#*|}"
  echo "    image: \${REGISTRY:?set REGISTRY in deploy/.env}/${PROJECT}/${name}@${digest}"
done
echo "  then \`make quality\` (image-pins reads the new lines) and sync the host (scripts/sync-host-deploy.sh)."
