#!/usr/bin/env bash
# Compose image pinning — the `image:` half of BR-2 / AS-018 (production-packaging-promotion-lane).
#
# `scripts/checks/check-container-image.sh --pins-only` covers Dockerfiles (FROM / COPY --from /
# RUN --mount from=). A compose file's `image:` line is the same registry pull with the same
# obligation, and nothing checked it: `mailpit:latest` ran unpinned for months. This script
# fails on any `image:` line in the repo's compose files whose reference carries no
# `@sha256:<64 hex>` digest.
#
# Usage:
#   scripts/checks/check-compose-image-pins.sh                 # every docker-compose*.yml / compose*.y(a)ml
#   scripts/checks/check-compose-image-pins.sh deploy/docker-compose.prod.yml other.yml
#
# What counts as an `image:` line — deliberately narrow and text-based (no YAML parser, no
# dependency): a line whose first non-blank token is `image:` followed by a value. A commented
# line is not one. A value that is a pure interpolation (`image: ${FOO}`) is reported as an
# ADVISORY (the pin lives wherever the variable is set — the deploy env file), never as OK.
# A value that carries interpolation only in its TAG (`ghcr.io/x/y:${APP_TAG:?…}`) is the
# SHA-tagged deployable of deployment.md § Images: promoted by git SHA, built by the CD job
# from digest-pinned Dockerfiles — allowed, reported as a SHA-tagged deployable.
#
# Carve-out: a whole-line comment `# as018-ok: <reason>` directly above an `image:` line
# exempts that one line (same shape as the Dockerfile gate; grep-able).

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJECT_ROOT"

if [ $# -gt 0 ]; then
  files=("$@")
else
  files=()
  while IFS= read -r f; do files+=("$f"); done < <(
    find . -type f \( -name 'docker-compose*.yml' -o -name 'docker-compose*.yaml' -o -name 'compose*.yml' -o -name 'compose*.yaml' \) \
      -not -path '*/vendor/*' -not -path '*/node_modules/*' -not -path '*/.git/*' -not -path '*/.wt-*' 2>/dev/null | sort
  )
fi

if [ "${#files[@]}" -eq 0 ]; then
  printf "compose image pinning: no compose file in this repo — skipped\n"
  exit 0
fi

fails=0
checked=0
scanned=0
for f in "${files[@]}"; do
  [ -f "$f" ] || { printf "✗ compose image pinning: %s does not exist\n" "$f" >&2; exit 2; }
  scanned=$((scanned + 1))
  carve=0
  ln=0
  while IFS= read -r line || [ -n "$line" ]; do
    ln=$((ln + 1))
    case "$line" in
      *[![:space:]]*) ;;
      *) continue ;;                      # blank line: does not disarm a carve-out
    esac
    stripped="${line#"${line%%[![:space:]]*}"}"
    case "$stripped" in
      '#'*)
        case "$stripped" in
          '#'*as018-ok:*[![:space:]]*) carve=1 ;;
        esac
        continue
        ;;
    esac
    case "$stripped" in
      image:*) ;;
      *) carve=0; continue ;;
    esac
    exempt=$carve; carve=0
    value="${stripped#image:}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%%#*}"                   # trailing comment
    value="${value%"${value##*[![:space:]]}"}"
    value="${value#\"}"; value="${value%\"}"; value="${value#\'}"; value="${value%\'}"
    [ -n "$value" ] || continue
    checked=$((checked + 1))
    if [ "$exempt" = 1 ]; then
      printf "  ~ %s:%s  %s — exempt (# as018-ok)\n" "$f" "$ln" "$value"
      continue
    fi
    if printf '%s' "$value" | grep -qE '@sha256:[0-9a-f]{64}$'; then
      continue
    fi
    # The patterns below match a literal `${` — no expansion intended.
    # shellcheck disable=SC2016
    case "$value" in
      '${'*'/'*':${'*)
        # `${REGISTRY}/trades/<name>:${X_TAG:?}` — the registry HOST is interpolated (deploy/.env),
        # the TAG is the promoted git SHA (10.6, BR-23): the SHA-tagged deployable of
        # deployment.md § Images, built from a digest-pinned Dockerfile by scripts/promote.sh.
        printf "  · %s:%s  %s — SHA-tagged deployable (registry host from deploy/.env, promoted by git SHA)\n" "$f" "$ln" "$value"
        continue
        ;;
      '${'*)
        printf "  ~ %s:%s  %s — pure interpolation; the pin lives where the variable is set, cannot be verified here\n" "$f" "$ln" "$value"
        continue
        ;;
      *':${'*)
        printf "  · %s:%s  %s — SHA-tagged deployable (promoted by git SHA, built from a digest-pinned Dockerfile)\n" "$f" "$ln" "$value"
        continue
        ;;
    esac
    printf "✗ %s:%s  image: %s — not pinned to an immutable digest\n" "$f" "$ln" "$value" >&2
    fails=$((fails + 1))
  done < "$f"
done

if [ "$fails" -gt 0 ]; then
  printf "\n✗ AS-018 / BR-2: %s compose image reference(s) without @sha256 digest.\n" "$fails" >&2
  printf "Fix — resolve the digest once and commit it:\n" >&2
  printf "  docker buildx imagetools inspect <image>:<tag>   (the multi-arch manifest-list digest)\n" >&2
  printf "  then: image: <image>:<tag>@sha256:<digest>   (keep the tag — it documents what the digest is)\n" >&2
  exit 1
fi
printf "compose image pinning: OK (%s image line(s) in %s file(s))\n" "$checked" "$scanned"
