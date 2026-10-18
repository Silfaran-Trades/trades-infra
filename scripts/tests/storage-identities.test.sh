#!/usr/bin/env bash
#
# Object-store identities — minio-storage-perimeter-hardening AC-9 / TM-7 / TM-8 / TM-9 (Tester
# scope; ADR-135). Run against the development store and against the rehearsal store.
#
# Proves, straight at the store (no perimeter in between), that each least-privilege identity
# can do exactly its job and nothing else:
#   media-presign (the SIGNING identity, its key is public in every presigned URL)
#     allowed: put + get an object under media-public/public/ and media-private/private/
#     refused: list a bucket, delete an object, a write outside its prefixes, a server-side
#              copy (the explicit `Deny s3:PutObject` when x-amz-copy-source is present),
#              `mc admin info`, minting a service account for itself
#   media-service (the SERVICE identity, header-signed calls on the internal network)
#     allowed: head/list both buckets, put / get / copy (public → private) / delete objects
#     refused: create a bucket, remove a bucket, change the anonymous policy, touch another
#              bucket, list users, `mc admin info`, minting a service account for itself
#   and neither identity owns a service account; both are plain users with their own policy.
#
# A refusal must be MinIO's own authorization refusal (`Access Denied` / `AccessDenied` /
# `Insufficient permissions`) — any other failure (a typo'd alias, a network error) fails the
# case instead of passing it.
#
# Usage:
#   scripts/tests/storage-identities.test.sh dev
#       the development store (media-service/docker-compose.yml: `media-minio` on the
#       `workspace-network`, the committed development values)
#   scripts/tests/storage-identities.test.sh rehearsal [<scratch secrets dir>]
#       the rehearsal store (`storage` on `trades-prod-network`; root and the two identity
#       secrets read from <dir>/storage.env, default deploy/rehearsal/.scratch/secrets)
# Knobs: MC_IMAGE (the pinned mc image), STORE_NETWORK, STORE_ENDPOINT.
# Secrets reach the probe container as environment variables only — never argv, never output.
# Exit: 0 every case as asserted · 1 at least one case failed · 2 usage / environment error.
# Bash 3.2-safe.

set -euo pipefail

INFRA_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
TARGET="${1:-}"
MC_IMAGE="${MC_IMAGE:-quay.io/minio/mc:RELEASE.2025-08-13T08-35-41Z@sha256:a7fe349ef4bd8521fb8497f55c6042871b2ae640607cf99d9bede5e9bdf11727}"

case "$TARGET" in
  dev)
    STORE_NETWORK="${STORE_NETWORK:-workspace-network}"
    STORE_ENDPOINT="${STORE_ENDPOINT:-http://media-minio:9000}"
    # The committed development values (media-service/docker-compose.yml `media-minio-init`) —
    # development-only, published on purpose; never a real secret.
    ROOT_USER=minioadmin; ROOT_PASSWORD=minioadmin
    PRESIGN_SECRET=media-presign-dev-secret; SERVICE_SECRET=media-service-dev-secret
    ;;
  rehearsal)
    SECRETS_DIR="${2:-$INFRA_DIR/deploy/rehearsal/.scratch/secrets}"
    [ -r "$SECRETS_DIR/storage.env" ] || { echo "✗ $SECRETS_DIR/storage.env not readable — is the rehearsal up?" >&2; exit 2; }
    STORE_NETWORK="${STORE_NETWORK:-trades-prod-network}"
    STORE_ENDPOINT="${STORE_ENDPOINT:-http://storage:9000}"
    val() { grep -E "^$1=" "$SECRETS_DIR/storage.env" | head -1 | cut -d= -f2-; }
    ROOT_USER="$(val MINIO_ROOT_USER)"; ROOT_PASSWORD="$(val MINIO_ROOT_PASSWORD)"
    PRESIGN_SECRET="$(val MEDIA_STORAGE_PRESIGN_SECRET_KEY)"; SERVICE_SECRET="$(val MEDIA_STORAGE_SERVICE_SECRET_KEY)"
    ;;
  *)
    sed -n '2,33p' "$0"; exit 2 ;;
esac
for v in ROOT_USER ROOT_PASSWORD PRESIGN_SECRET SERVICE_SECRET; do
  [ -n "$(eval "printf '%s' \"\$$v\"")" ] || { echo "✗ $v is empty" >&2; exit 2; }
done

RUN="identity-probe-$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')"
PROBE="storage-identities-$RUN"
OTHER_BUCKET="$RUN-other"
RB_BUCKET="$RUN-rb"
NEW_BUCKET="$RUN-mb"

cleanup() { docker rm -f "$PROBE" >/dev/null 2>&1 || true; }
trap cleanup EXIT

docker run -d --name "$PROBE" --network "$STORE_NETWORK" --entrypoint sh \
  -e ROOT_USER="$ROOT_USER" -e ROOT_PASSWORD="$ROOT_PASSWORD" \
  -e PRESIGN_SECRET="$PRESIGN_SECRET" -e SERVICE_SECRET="$SERVICE_SECRET" -e EP="$STORE_ENDPOINT" \
  "$MC_IMAGE" -c 'sleep 900' >/dev/null
x() { docker exec "$PROBE" sh -c "$1" 2>&1; }

# shellcheck disable=SC2016  # expanded by the probe container's shell, on purpose
x 'mc alias set root "$EP" "$ROOT_USER" "$ROOT_PASSWORD" >/dev/null && mc alias set presign "$EP" media-presign "$PRESIGN_SECRET" >/dev/null && mc alias set service "$EP" media-service "$SERVICE_SECRET" >/dev/null && echo aliases-ok' \
  | grep -q aliases-ok || { echo "✗ could not register the three mc aliases against $STORE_ENDPOINT on $STORE_NETWORK" >&2; exit 2; }
x 'printf probe > /tmp/probe.bin' >/dev/null

PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); printf '  ✓ %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  ✗ %s\n      %s\n' "$1" "$(printf '%s' "$2" | tr '\n' ' ' | cut -c1-300)"; }
DENIED_RE='Access Denied|AccessDenied|Insufficient permissions|not allowed'
allow() {   # allow <label> <command>
  if out="$(docker exec "$PROBE" sh -c "$2" 2>&1)"; then ok "allowed: $1"; else bad "allowed: $1 (expected success)" "$out"; fi
}
deny() {    # deny <label> <command> — must FAIL and with MinIO's authorization refusal
  if out="$(docker exec "$PROBE" sh -c "$2" 2>&1)"; then
    bad "refused: $1 (expected an authorization refusal, the call SUCCEEDED)" "$out"
  elif printf '%s' "$out" | grep -qE "$DENIED_RE"; then
    ok "refused: $1"
  else
    bad "refused: $1 (failed, but not with an authorization refusal)" "$out"
  fi
}

echo "→ storage-identities: target=$TARGET endpoint=$STORE_ENDPOINT network=$STORE_NETWORK run=$RUN"

# root-made fixtures: another bucket (with one object) and a bucket to try removing
x "mc mb root/$OTHER_BUCKET >/dev/null && mc cp /tmp/probe.bin root/$OTHER_BUCKET/x.bin >/dev/null && mc mb root/$RB_BUCKET >/dev/null && echo fx-ok" | grep -q fx-ok \
  || { echo "✗ root could not create the probe fixtures" >&2; exit 2; }
PUB="media-public/public/$RUN"; PRIV="media-private/private/$RUN"

echo "media-presign (signing identity)"
allow "put media-public/public/…"            "mc cp /tmp/probe.bin presign/$PUB/a.bin"
allow "get media-public/public/…"            "mc cat presign/$PUB/a.bin"
allow "put media-private/private/…"          "mc cp /tmp/probe.bin presign/$PRIV/a.bin"
allow "get media-private/private/…"          "mc cat presign/$PRIV/a.bin"
deny  "list media-public"                    "mc ls presign/media-public"
deny  "list media-private"                   "mc ls presign/media-private/private/"
deny  "delete an object"                     "mc rm presign/$PUB/a.bin"
deny  "write outside its prefixes (media-public/other/)" "mc cp /tmp/probe.bin presign/media-public/$RUN-outside.bin"
deny  "write outside its prefixes (media-private/public/)" "mc cp /tmp/probe.bin presign/media-private/public/$RUN/x.bin"
deny  "server-side copy inside its own prefix (copy Deny)" "mc cp presign/$PUB/a.bin presign/$PUB/copied.bin"
deny  "server-side copy private → public (copy Deny)"      "mc cp presign/$PRIV/a.bin presign/$PUB/leaked.bin"
deny  "another bucket"                       "mc cat presign/$OTHER_BUCKET/x.bin"
deny  "mc admin info"                        "mc admin info presign"
deny  "mint a service account for itself"    "mc admin user svcacct add presign media-presign"

echo "media-service (service identity)"
allow "head/list media-public"               "mc ls service/media-public/.bootstrap-probe"
allow "head/list media-private"              "mc ls service/media-private/private/$RUN/"
allow "put media-public"                     "mc cp /tmp/probe.bin service/$PUB/s.bin"
allow "get media-public"                     "mc cat service/$PUB/s.bin"
allow "copy public → private"                "mc cp service/$PUB/s.bin service/$PRIV/s-copy.bin"
allow "delete in media-private"              "mc rm service/$PRIV/s-copy.bin"
deny  "create a bucket"                      "mc mb service/$NEW_BUCKET"
deny  "remove a bucket"                      "mc rb service/$RB_BUCKET"
deny  "change the anonymous policy (media-private → download)" "mc anonymous set download service/media-private"
deny  "change the anonymous policy (media-public → none)"      "mc anonymous set none service/media-public"
deny  "another bucket (read)"                "mc cat service/$OTHER_BUCKET/x.bin"
deny  "another bucket (write)"               "mc cp /tmp/probe.bin service/$OTHER_BUCKET/y.bin"
deny  "list users"                           "mc admin user ls service"
deny  "mc admin info"                        "mc admin info service"
deny  "mint a service account for itself"    "mc admin user svcacct add service media-service"

echo "the identities themselves (root's view)"
users="$(x 'mc admin user ls root --json')"
for u in media-presign media-service; do
  if printf '%s\n' "$users" | grep "\"accessKey\":\"$u\"" | grep -q "\"policyName\":\"$u\"" && printf '%s\n' "$users" | grep "\"accessKey\":\"$u\"" | grep -q '"userStatus":"enabled"'; then
    ok "$u is a plain enabled user with policy $u attached, exactly once ($(printf '%s\n' "$users" | grep -c "\"accessKey\":\"$u\"")×)"
    [ "$(printf '%s\n' "$users" | grep -c "\"accessKey\":\"$u\"")" = 1 ] || bad "$u listed more than once" "$users"
  else
    bad "$u is a plain enabled user with policy $u attached" "$users"
  fi
  sa="$(x "mc admin user svcacct ls root $u --json")"
  if printf '%s' "$sa" | grep -q '"accessKey"'; then bad "$u owns NO service account" "$sa"; else ok "$u owns no service account"; fi
done

# the store state the refusals must have left untouched
if x "mc stat root/$PUB/a.bin" >/dev/null; then ok "the object media-presign could not delete is still there"; else bad "the object media-presign could not delete is still there" "gone"; fi
for k in "media-public/$RUN-outside.bin" "media-private/public/$RUN/x.bin" "$PUB/copied.bin" "$PUB/leaked.bin" "$OTHER_BUCKET/y.bin"; do
  if x "mc stat root/$k" >/dev/null 2>&1; then bad "nothing written at $k by a refused call" "object exists"; else ok "nothing written at $k by a refused call"; fi
done
if x "mc ls root/$NEW_BUCKET" >/dev/null 2>&1; then bad "bucket $NEW_BUCKET was not created" "exists"; else ok "bucket $NEW_BUCKET was not created"; fi
if x "mc ls root/$RB_BUCKET" >/dev/null 2>&1; then ok "bucket $RB_BUCKET still exists"; else bad "bucket $RB_BUCKET still exists" "removed"; fi
anon="$(x 'mc anonymous get root/media-public; mc anonymous get root/media-private')"
if printf '%s' "$anon" | grep -q 'media-public.*download' && printf '%s' "$anon" | grep -q 'media-private.*private'; then ok "anonymous policies unchanged (media-public download, media-private private)"; else bad "anonymous policies unchanged" "$anon"; fi

# cleanup by exact keys / names (root)
x "mc rm root/$PUB/a.bin root/$PUB/s.bin root/$PRIV/a.bin root/$OTHER_BUCKET/x.bin >/dev/null 2>&1; mc rb root/$OTHER_BUCKET >/dev/null 2>&1; mc rb root/$RB_BUCKET >/dev/null 2>&1; mc rb root/$NEW_BUCKET >/dev/null 2>&1; true" >/dev/null

echo "→ storage-identities ($TARGET): $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
