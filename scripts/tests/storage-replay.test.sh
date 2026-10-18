#!/usr/bin/env bash
#
# Replay of the legitimate `storage.` request shapes, before vs after the filter —
# minio-storage-perimeter-hardening AC-7 / BR-7 (Tester scope; ADR-135). Rehearsal stack only.
#
# The recorded shapes (refinement evidence § 1): presigned PUT public and private (the SPA's
# XHR: Content-Type + X-Amz-Meta-Asset-Id + Origin), the CORS preflight from the `app.` origin,
# the presigned GET of a variant, the anonymous GET and HEAD of a public alias key, and the
# seed lane's PUT (no Origin). The URLs are minted ONCE by the running media-service (its real
# adapter, the `media-presign` identity) and the very same requests are replayed three times
# on the same stack and identities:
#   A  the SHIPPED Caddyfile (the scratch copy, as `make rehearse` wrote it)
#   B  the PREVIOUS Caddyfile (`git show master:deploy/Caddyfile`), swapped into the scratch
#      copy and applied with `restart caddy` — the baseline
#   C  the shipped Caddyfile restored and applied again
# and for every request the status, the body digest and the stable response headers (the
# security headers, Cache-Control, Content-Type, Content-Length, ETag, the Access-Control-* set)
# must be equal across A, B and C. Per-request values (Date, X-Amz-Request-Id, X-Amz-Id-2,
# Last-Modified of a re-written object, Alt-Svc) are excluded. Only the scratch copy is ever
# swapped; the committed deploy/Caddyfile is never touched.
#
# Usage: scripts/tests/storage-replay.test.sh [<out dir for the three captures>]
# Env:   SCRATCH, DOMAIN, HTTPS_PORT (as storage-perimeter.test.sh)
# Exit:  0 equal · 1 a difference (printed) · 2 environment error. Bash 3.2-safe.

set -uo pipefail

INFRA_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SCRATCH="${SCRATCH:-$INFRA_DIR/deploy/rehearsal/.scratch}"
DOMAIN="${DOMAIN:-trades.test}"
HTTPS_PORT="${HTTPS_PORT:-443}"
OUT="${1:-$(mktemp -d "${TMPDIR:-/tmp}/storage-replay-XXXXXX")}"
mkdir -p "$OUT"
HOST="storage.$DOMAIN"
PORT_SUFFIX=""; [ "$HTTPS_PORT" = 443 ] || PORT_SUFFIX=":$HTTPS_PORT"
BASE="https://$HOST$PORT_SUFFIX"
APP_ORIGIN="https://app.$DOMAIN$PORT_SUFFIX"
export CURL_CA_BUNDLE="${CURL_CA_BUNDLE:-$SCRATCH/ca/root.crt}"
COMPOSE=(docker compose --project-directory "$SCRATCH/deploy" -f "$SCRATCH/deploy/docker-compose.prod.yml")
SHIPPED="$SCRATCH/deploy/Caddyfile"

[ -r "$SHIPPED" ] && [ -r "$CURL_CA_BUNDLE" ] || { echo "✗ no rehearsal scratch at $SCRATCH" >&2; exit 2; }
cmp -s "$SHIPPED" "$INFRA_DIR/deploy/Caddyfile" || { echo "✗ the scratch Caddyfile is not the committed one — refusing to call it 'shipped'" >&2; exit 2; }
git -C "$INFRA_DIR" show master:deploy/Caddyfile > "$OUT/Caddyfile.master" || { echo "✗ cannot read master:deploy/Caddyfile" >&2; exit 2; }
cp "$SHIPPED" "$OUT/Caddyfile.shipped"
# shellcheck disable=SC2329  # invoked by the EXIT trap
restore() { cp "$OUT/Caddyfile.shipped" "$SHIPPED"; }
trap restore EXIT

uuid() { od -An -tx1 -N16 /dev/urandom | tr -d ' \n' | sed -E 's/^(.{8})(.{4}).(.{3}).(.{3})(.{12})$/\1-\2-4\3-8\4-\5/'; }
mint() {
  # shellcheck disable=SC2016  # PHP source, not shell
  "${COMPOSE[@]}" exec -T media php -r '
    require "vendor/autoload.php";
    $s = App\Infrastructure\Storage\S3ObjectStorage::fromDsn(getenv("MEDIA_STORAGE_DSN"), getenv("MEDIA_STORAGE_PUBLIC_ENDPOINT"), getenv("MEDIA_STORAGE_PRESIGN_ACCESS_KEY"), getenv("MEDIA_STORAGE_PRESIGN_SECRET_KEY"));
    echo "put" === $argv[1] ? $s->presignPutUrl($argv[2], $argv[3], $argv[5], 900, ["asset-id" => $argv[4]])->url : $s->presignGetUrl($argv[2], $argv[3], 900)->url;
  ' -- "$@"
}
apply_caddyfile() {   # apply_caddyfile <file> — the § "two Caddy lanes" restart on the scratch project
  cp "$1" "$SHIPPED"
  "${COMPOSE[@]}" restart caddy >/dev/null 2>&1 || { echo "✗ restart caddy failed" >&2; exit 2; }
  i=0; until curl -sS -o /dev/null --resolve "$HOST:$HTTPS_PORT:127.0.0.1" "$BASE/media-public/public/$A/medium.jpg" 2>/dev/null; do
    i=$((i + 1)); [ "$i" -lt 30 ] || { echo "✗ caddy did not come back" >&2; exit 2; }; sleep 1
  done
}

O="$(uuid)"; A="$(uuid)"
PUBKEY="public/$O/$A/original.png"; PRIVKEY="private/$O/$A/original.pdf"; VARIANT="public/$O/$A/medium.jpg"; ALIAS="public/$A/medium.jpg"; SEEDKEY="private/$O/$(uuid)/original.pdf"
printf 'replay-png-%s' "$A" > "$OUT/body.png"; printf 'replay-pdf-%s' "$A" > "$OUT/body.pdf"; printf 'replay-jpg-%s' "$A" > "$OUT/body.jpg"
U_PUT_PUB="$(mint put media-public "$PUBKEY" "$A" image/png)"
U_PUT_PRIV="$(mint put media-private "$PRIVKEY" "$A" application/pdf)"
U_PUT_VARIANT="$(mint put media-public "$VARIANT" "$A" image/jpeg)"
U_PUT_ALIAS="$(mint put media-public "$ALIAS" "$A" image/jpeg)"
U_PUT_SEED="$(mint put media-private "$SEEDKEY" "$A" application/pdf)"
U_GET_VARIANT="$(mint get media-public "$VARIANT" "$A" -)"
R=(--resolve "$HOST:$HTTPS_PORT:127.0.0.1")

capture() {   # capture <label> → $OUT/<label>.txt (one block per request)
  f="$OUT/$1.txt"; : > "$f"
  one() {     # one <name> <curl args…>
    name="$1"; shift
    curl -sS -o "$OUT/.b" -D "$OUT/.h" "${R[@]}" "$@" 2>>"$OUT/.e" || true
    # a HEAD (-I) has no body: curl writes the header block to -o as well, Date included
    [ "$1" = "-I" ] && : > "$OUT/.b"
    {
      echo "## $name"
      echo "status: $(head -1 "$OUT/.h" | tr -d '\r' | awk '{print $2}')"
      echo "body-sha256: $(shasum -a 256 < "$OUT/.b" | cut -c1-16) ($(wc -c < "$OUT/.b" | tr -d ' ') bytes)"
      tr -d '\r' < "$OUT/.h" | grep -iE '^(strict-transport-security|content-security-policy|x-content-type-options|x-frame-options|x-robots-tag|referrer-policy|cross-origin-opener-policy|cross-origin-resource-policy|permissions-policy|cache-control|content-type|content-length|etag|access-control-[a-z-]+|vary|server):' \
        | awk -F': ' '{ printf "%s: %s\n", tolower($1), substr($0, length($1) + 3) }' | sort
    } >> "$f"
  }
  one "1 presigned PUT public (SPA)"   -X PUT -H "Content-Type: image/png" -H "X-Amz-Meta-Asset-Id: $A" -H "Origin: $APP_ORIGIN" --data-binary @"$OUT/body.png" "$U_PUT_PUB"
  one "2 presigned PUT private (SPA)"  -X PUT -H "Content-Type: application/pdf" -H "X-Amz-Meta-Asset-Id: $A" -H "Origin: $APP_ORIGIN" --data-binary @"$OUT/body.pdf" "$U_PUT_PRIV"
  one "2b presigned PUT variant fixture" -X PUT -H "Content-Type: image/jpeg" -H "X-Amz-Meta-Asset-Id: $A" --data-binary @"$OUT/body.jpg" "$U_PUT_VARIANT"
  one "2c presigned PUT alias fixture" -X PUT -H "Content-Type: image/jpeg" -H "X-Amz-Meta-Asset-Id: $A" --data-binary @"$OUT/body.jpg" "$U_PUT_ALIAS"
  one "3 presigned GET variant (SPA)"  -H "Referer: $APP_ORIGIN/" -H "Origin: $APP_ORIGIN" "$U_GET_VARIANT"
  one "4 CORS preflight from app."     -X OPTIONS -H "Origin: $APP_ORIGIN" -H "Access-Control-Request-Method: PUT" -H "Access-Control-Request-Headers: content-type,x-amz-meta-asset-id" "$U_PUT_PUB"
  one "5 anonymous GET public alias"   "$BASE/media-public/$ALIAS"
  one "6 anonymous HEAD public alias"  -I "$BASE/media-public/$ALIAS"
  one "7 seed-lane PUT (no Origin)"    -X PUT -H "Content-Type: application/pdf" -H "X-Amz-Meta-Asset-Id: $A" --data-binary @"$OUT/body.pdf" "$U_PUT_SEED"
}

echo "→ storage-replay: A shipped Caddyfile"
apply_caddyfile "$OUT/Caddyfile.shipped"; capture A-shipped
echo "→ storage-replay: B previous Caddyfile (master), restart caddy"
apply_caddyfile "$OUT/Caddyfile.master"; capture B-master
echo "→ storage-replay: C shipped Caddyfile restored, restart caddy"
apply_caddyfile "$OUT/Caddyfile.shipped"; capture C-shipped-again
trap - EXIT

rc=0
for pair in "A-shipped B-master" "C-shipped-again B-master"; do
  a="${pair% *}"; b="${pair#* }"
  if diff -u "$OUT/$b.txt" "$OUT/$a.txt" > "$OUT/diff-$a-vs-$b.txt"; then
    echo "  ✓ $a equals $b ($(grep -c '^## ' "$OUT/$a.txt") requests, $(grep -vc '^## ' "$OUT/$a.txt") compared lines)"
  else
    echo "  ✗ $a differs from $b:"; cat "$OUT/diff-$a-vs-$b.txt"; rc=1
  fi
done
# the replay must have exercised what it claims: every legitimate request succeeded
if grep -A1 '^## ' "$OUT/A-shipped.txt" | grep '^status:' | grep -qvE 'status: (200|204)$'; then echo "  ✗ a legitimate request did not succeed:"; grep -A1 '^## ' "$OUT/A-shipped.txt"; rc=1; else echo "  ✓ every replayed legitimate request succeeded (200/204)"; fi
"${COMPOSE[@]}" exec -T caddy true && cmp -s "$SHIPPED" "$INFRA_DIR/deploy/Caddyfile" && echo "  ✓ the scratch stack serves the shipped Caddyfile again"
echo "→ storage-replay: captures in $OUT"
exit "$rc"
