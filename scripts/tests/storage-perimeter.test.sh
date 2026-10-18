#!/usr/bin/env bash
#
# The `storage.` perimeter filter, live — minio-storage-perimeter-hardening AC-1..AC-6, BR-8,
# TM-1..TM-6 (Tester scope; ADR-135). Runs against the REHEARSAL stack (`make rehearse`), which
# serves the committed deploy/Caddyfile in front of the pinned MinIO — exactly what stage 1
# serves (BR-9, BR-20). Never point it at stage 1.
#
# Every refused shape is sent for real through Caddy and must come back as THE PERIMETER's
# refusal — never MinIO's: status 403, the error lane's body `403 Forbidden` (13 bytes; a MinIO
# 403 is an XML document), `Cache-Control: private, no-store` and the six floor headers. A
# write-shaped refusal is then checked from inside the store with root (`mc stat`): no object
# at the key. Legitimate presigned URLs are minted by the running media-service itself (the
# real `S3ObjectStorage` with the rehearsal's `media-presign` credentials), so a refusal is
# never an artefact of a hand-made signature.
#
# Sections:
#   0 positive controls — the legitimate shapes still pass (the full byte-level replay is the
#     separate AC-7 comparison)
#   1 AC-1 / TM-1  unsigned-trailer content hash: header (upper / lower / mixed case) and query
#                  (upper / lower / mixed, percent-encoded value, percent-encoded name)
#   2 AC-2 / TM-2  Snowball: header, query, percent-encoded name; the three MinIO siblings
#   3 AC-3 / TM-3  X-Amz-Trailer, X-Amz-Decoded-Content-Length, Content-Encoding aws-chunked
#                  (alone, in a list, as a second header line), and EVERY named presence
#                  refusal of the Caddyfile (read from the file, so the probe follows the list);
#                  then the family strips: unnamed family members on a legitimate PUT pass and
#                  never reach the store (`mc admin trace -v` shows the PUT without them)
#   4 AC-4 / TM-4  POST ?select&select-type=2, POST ?uploads, POST ?delete, POST on an object,
#                  DELETE on an object — the object unchanged afterwards
#   5 AC-5 / TM-5/6 /, a bare bucket, another bucket, /minio/…, sub-resource query keys, `..` and
#                  `%2e%2e` sent as-is, `;` in the query
#   6 AC-6 / TM-6  a header-signed GET with VALID media-service credentials, HTTP/1.1 and HTTP/2
#                  (control: the same identity's signed GET straight at the store answers 200)
#   7 TM-1 / TM-6  two X-Amz-Content-Sha256 header lines; a query repeating it with a streaming
#                  second value
#   8 BR-8 / LO-009 the access-log line of a refused request: status 403, the path, no query
#
# Usage: scripts/tests/storage-perimeter.test.sh            (after `make rehearse`)
# Env:   SCRATCH (deploy/rehearsal/.scratch), DOMAIN (trades.test), HTTPS_PORT (443),
#        MC_IMAGE (the pinned mc image), STORE_NETWORK (trades-prod-network)
# Exit:  0 every case as asserted · 1 at least one case failed · 2 environment error.
# Bash 3.2-safe; host tools: curl (with HTTP/2), docker.

set -uo pipefail

INFRA_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SCRATCH="${SCRATCH:-$INFRA_DIR/deploy/rehearsal/.scratch}"
DOMAIN="${DOMAIN:-trades.test}"
HTTPS_PORT="${HTTPS_PORT:-443}"
STORE_NETWORK="${STORE_NETWORK:-trades-prod-network}"
MC_IMAGE="${MC_IMAGE:-quay.io/minio/mc:RELEASE.2025-08-13T08-35-41Z@sha256:a7fe349ef4bd8521fb8497f55c6042871b2ae640607cf99d9bede5e9bdf11727}"
CADDYFILE="$INFRA_DIR/deploy/Caddyfile"
HOST="storage.$DOMAIN"
PORT_SUFFIX=""; [ "$HTTPS_PORT" = 443 ] || PORT_SUFFIX=":$HTTPS_PORT"
BASE="https://$HOST$PORT_SUFFIX"
APP_ORIGIN="https://app.$DOMAIN$PORT_SUFFIX"
export CURL_CA_BUNDLE="${CURL_CA_BUNDLE:-$SCRATCH/ca/root.crt}"
RESOLVE=(--resolve "$HOST:$HTTPS_PORT:127.0.0.1")
COMPOSE=(docker compose --project-directory "$SCRATCH/deploy" -f "$SCRATCH/deploy/docker-compose.prod.yml")

[ -r "$CURL_CA_BUNDLE" ] && [ -r "$SCRATCH/secrets/storage.env" ] || { echo "✗ no rehearsal scratch at $SCRATCH (run make rehearse)" >&2; exit 2; }
"${COMPOSE[@]}" exec -T media true 2>/dev/null || { echo "✗ the rehearsal media container is not running" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/storage-perimeter-XXXXXX")"
RUN="$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')"
PROBE="storage-perimeter-$RUN"
TRACE="storage-perimeter-trace-$RUN"
cleanup() { docker rm -f "$PROBE" "$TRACE" >/dev/null 2>&1 || true; rm -rf "$WORK"; }
trap cleanup EXIT

# root, from inside the store's network, for the "nothing written" checks (secrets via env only)
val() { grep -E "^$1=" "$SCRATCH/secrets/storage.env" | head -1 | cut -d= -f2-; }
docker run -d --name "$PROBE" --network "$STORE_NETWORK" --entrypoint sh \
  -e ROOT_USER="$(val MINIO_ROOT_USER)" -e ROOT_PASSWORD="$(val MINIO_ROOT_PASSWORD)" \
  "$MC_IMAGE" -c 'mc alias set root http://storage:9000 "$ROOT_USER" "$ROOT_PASSWORD" >/dev/null && sleep 1800' >/dev/null
sleep 2
store() { docker exec "$PROBE" sh -c "$1" 2>&1; }
store 'mc ls root/media-public/.bootstrap-probe' >/dev/null || { echo "✗ root cannot reach the rehearsal store" >&2; exit 2; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ✓ %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  ✗ %s\n      %s\n' "$1" "$(printf '%s' "${2:-}" | tr '\n' ' ' | cut -c1-400)"; }

uuid() { od -An -tx1 -N16 /dev/urandom | tr -d ' \n' | sed -E 's/^(.{8})(.{4}).(.{3}).(.{3})(.{12})$/\1-\2-4\3-8\4-\5/'; }
ctype_of() { case "$1" in *.png) echo image/png ;; *.pdf) echo application/pdf ;; *.jpg) echo image/jpeg ;; *) echo application/octet-stream ;; esac; }

# mint put|get <bucket> <key> [asset-id] — by the running media-service, its real adapter
mint() {
  # shellcheck disable=SC2016  # PHP source, not shell
  "${COMPOSE[@]}" exec -T media php -r '
    require "vendor/autoload.php";
    $op = $argv[1]; $bucket = $argv[2]; $key = $argv[3]; $asset = $argv[4] ?? ""; $ctype = $argv[5] ?? "application/octet-stream";
    $s = App\Infrastructure\Storage\S3ObjectStorage::fromDsn(getenv("MEDIA_STORAGE_DSN"), getenv("MEDIA_STORAGE_PUBLIC_ENDPOINT"), getenv("MEDIA_STORAGE_PRESIGN_ACCESS_KEY"), getenv("MEDIA_STORAGE_PRESIGN_SECRET_KEY"));
    echo "put" === $op ? $s->presignPutUrl($bucket, $key, $ctype, 600, "" === $asset ? [] : ["asset-id" => $asset])->url : $s->presignGetUrl($bucket, $key, 600)->url;
  ' -- "$1" "$2" "$3" "${4:-}" "$(ctype_of "$3")"
}
# header_sign <endpoint> <bucket> <key> — Authorization-signed GET headers, media-service identity
header_sign() {
  # shellcheck disable=SC2016  # PHP source, not shell
  "${COMPOSE[@]}" exec -T media php -r '
    require "vendor/autoload.php";
    $cfg = App\Infrastructure\Storage\S3DsnParser::parse(getenv("MEDIA_STORAGE_DSN"));
    $cfg["endpoint"] = $argv[1];
    $client = new Aws\S3\S3Client($cfg);
    $req = Aws\serialize($client->getCommand("GetObject", ["Bucket" => $argv[2], "Key" => $argv[3]]));
    foreach (["X-Amz-User-Agent", "aws-sdk-invocation-id", "aws-sdk-retry", "User-Agent"] as $h) { $req = $req->withoutHeader($h); }
    $signed = (new Aws\Signature\S3SignatureV4("s3", $cfg["region"]))->signRequest($req, $client->getCredentials()->wait());
    foreach (["Authorization", "X-Amz-Date", "X-Amz-Content-Sha256"] as $h) { echo $h, ": ", $signed->getHeaderLine($h), "\n"; }
  ' -- "$1" "$2" "$3"
}

# send <curl args…> → writes $WORK/last.{h,b,e}, prints "<status> <http version>". It runs in a
# command substitution (a subshell), so it writes to a FIXED name the caller reads afterwards.
N=last
send() {
  curl -sS -o "$WORK/$N.b" -D "$WORK/$N.h" -w '%{http_code} %{http_version}' "${RESOLVE[@]}" "$@" 2>"$WORK/$N.e" || true
}
hdr() { grep -i "^$1:" "$WORK/$N.h" | head -1 | cut -d: -f2- | tr -d '\r' | sed 's/^ //'; }

FLOOR="Strict-Transport-Security Content-Security-Policy X-Content-Type-Options Referrer-Policy Cross-Origin-Opener-Policy Cross-Origin-Resource-Policy"
# refused <label> <curl args…>: the PERIMETER's 403 (never MinIO's)
refused() {
  label="$1"; shift
  res="$(send "$@")"; status="${res%% *}"
  body="$(cat "$WORK/$N.b")"
  if [ "$status" != 403 ]; then bad "$label → 403 (got $status)" "$body"; return 1; fi
  if [ "$body" != "403 Forbidden" ]; then bad "$label → the perimeter's body \`403 Forbidden\` (a MinIO refusal?)" "$body"; return 1; fi
  if [ "$(hdr Cache-Control)" != "private, no-store" ]; then bad "$label → Cache-Control: private, no-store" "$(hdr Cache-Control)"; return 1; fi
  for h in $FLOOR; do [ -n "$(hdr "$h")" ] || { bad "$label → floor header $h" "$(cat "$WORK/$N.h")"; return 1; }; done
  if grep -qi '^server:' "$WORK/$N.h"; then bad "$label → no Server header" "$(hdr Server)"; return 1; fi
  ok "$label → 403 \`403 Forbidden\`, no-store + floor"
}
absent() {   # absent <bucket/key> <label>
  if store "mc stat root/$1" >/dev/null 2>&1; then bad "nothing written: $2" "object exists at $1"; else ok "nothing written: $2"; fi
}
passes() {   # passes <label> <expected status> <curl args…>
  label="$1"; want="$2"; shift 2
  res="$(send "$@")"; status="${res%% *}"
  if [ "$status" = "$want" ]; then ok "$label → $status"; else bad "$label → $want (got $status)" "$(head -c 300 "$WORK/$N.b")"; fi
}
set_query_value() {   # set_query_value <url> <key> <new value> — replace the value of one query key
  printf '%s' "$1" | sed -E "s/([?&])$2=[^&]*/\\1$2=$3/"
}

O1="$(uuid)"; A1="$(uuid)"
echo "→ storage-perimeter: $BASE (run $RUN; CA $CURL_CA_BUNDLE)"

# ---------------------------------------------------------------------------------------------
echo "0 positive controls (legitimate shapes, minted by media-service)"
PUBKEY="public/$O1/$A1/original.png"; PRIVKEY="private/$O1/$A1/original.pdf"; ALIAS="public/$A1/medium.jpg"
printf 'png-bytes-%s' "$RUN" > "$WORK/body.png"
U="$(mint put media-public "$PUBKEY" "$A1")"
case "$U" in *"X-Amz-Credential=media-presign%2F"*) ok "the minted URL names media-presign" ;; *) bad "the minted URL names media-presign" "$U" ;; esac
passes "presigned PUT public" 200 -X PUT -H "Content-Type: image/png" -H "X-Amz-Meta-Asset-Id: $A1" -H "Origin: $APP_ORIGIN" --data-binary @"$WORK/body.png" "$U"
passes "CORS preflight (OPTIONS) from the app origin" 204 -X OPTIONS -H "Origin: $APP_ORIGIN" -H "Access-Control-Request-Method: PUT" -H "Access-Control-Request-Headers: content-type,x-amz-meta-asset-id" "$U"
U="$(mint put media-private "$PRIVKEY" "$A1")"
passes "presigned PUT private" 200 -X PUT -H "Content-Type: application/pdf" -H "X-Amz-Meta-Asset-Id: $A1" -H "Origin: $APP_ORIGIN" --data-binary "pdf-bytes" "$U"
U="$(mint get media-public "$PUBKEY")"
passes "presigned GET" 200 "$U"
U="$(mint put media-public "$ALIAS" "$A1")"
passes "presigned PUT of the alias key (fixture)" 200 -X PUT -H "Content-Type: image/jpeg" -H "X-Amz-Meta-Asset-Id: $A1" --data-binary "alias-bytes" "$U"
passes "anonymous GET of the public alias" 200 "$BASE/media-public/$ALIAS"
passes "anonymous HEAD of the public alias" 200 -I "$BASE/media-public/$ALIAS"

# ---------------------------------------------------------------------------------------------
echo "1 AC-1 / TM-1 — unsigned-trailer content hash"
for v in STREAMING-UNSIGNED-PAYLOAD-TRAILER streaming-unsigned-payload-trailer Streaming-Unsigned-Payload-Trailer STREAMING-AWS4-HMAC-SHA256-PAYLOAD; do
  K="private/$O1/$(uuid)/original.pdf"; U="$(mint put media-private "$K" "$A1")"
  refused "header X-Amz-Content-Sha256: $v (presigned PUT, media-private)" -X PUT -H "Content-Type: application/pdf" -H "X-Amz-Meta-Asset-Id: $A1" -H "X-Amz-Content-Sha256: $v" --data-binary x "$U"
  absent "media-private/$K" "header $v"
done
for v in STREAMING-UNSIGNED-PAYLOAD-TRAILER streaming-unsigned-payload-trailer sTrEaMiNg-UnSiGnEd-PaYlOaD-TrAiLeR 'STREAMING%2DUNSIGNED%2DPAYLOAD%2DTRAILER' '%53TREAMING-UNSIGNED-PAYLOAD-TRAILER'; do
  K="private/$O1/$(uuid)/original.pdf"; U="$(set_query_value "$(mint put media-private "$K" "$A1")" X-Amz-Content-Sha256 "$v")"
  refused "query X-Amz-Content-Sha256=$v" -X PUT -H "Content-Type: application/pdf" -H "X-Amz-Meta-Asset-Id: $A1" --data-binary x "$U"
  absent "media-private/$K" "query $v"
done
for name in x-amz-content-sha256 X-AMZ-CONTENT-SHA256 '%58-Amz-Content-Sha256' 'X-Amz-Content%2DSha256'; do
  K="private/$O1/$(uuid)/original.pdf"; U="$(mint put media-private "$K" "$A1")"
  U="$(printf '%s' "$U" | sed -E "s/X-Amz-Content-Sha256=UNSIGNED-PAYLOAD/$name=STREAMING-UNSIGNED-PAYLOAD-TRAILER/")"
  refused "query name $name=STREAMING-UNSIGNED-PAYLOAD-TRAILER" -X PUT -H "Content-Type: application/pdf" --data-binary x "$U"
  absent "media-private/$K" "query name $name"
done
# the bare CVE shape: an access key in the query and no secret at all
K="private/$O1/$(uuid)/original.pdf"
refused "bare CVE-2026-41145 shape (X-Amz-Credential only, streaming trailer header)" -X PUT -H "X-Amz-Content-Sha256: STREAMING-UNSIGNED-PAYLOAD-TRAILER" -H "X-Amz-Trailer: x-amz-checksum-crc32" --data-binary x "$BASE/media-private/$K?X-Amz-Credential=media-presign%2F20261018%2Fus-east-1%2Fs3%2Faws4_request"
absent "media-private/$K" "bare CVE shape"

# ---------------------------------------------------------------------------------------------
echo "2 AC-2 / TM-2 — Snowball"
for spec in "H|X-Amz-Meta-Snowball-Auto-Extract: true" "H|x-amz-meta-snowball-auto-extract: true" "H|X-Amz-Meta-Minio-Snowball-Prefix: p" "H|X-Amz-Meta-Minio-Snowball-Ignore-Dirs: true" "H|X-Amz-Meta-Minio-Snowball-Ignore-Errors: true" "Q|X-Amz-Meta-Snowball-Auto-Extract=true" "Q|x-amz-meta-snowball-auto-extract=true" "Q|%58-Amz-Meta-Snowball-Auto-Extract=true" "Q|X-Amz-Meta-Snowball%2DAuto-Extract=true"; do
  kind="${spec%%|*}"; what="${spec#*|}"
  for bucket in media-public media-private; do
    vis="${bucket#media-}"; K="$vis/$O1/$(uuid)/archive.tar"; U="$(mint put "$bucket" "$K" "$A1")"
    if [ "$kind" = H ]; then
      refused "header $what ($bucket)" -X PUT -H "Content-Type: application/octet-stream" -H "X-Amz-Meta-Asset-Id: $A1" -H "$what" --data-binary x "$U"
    else
      refused "query $what ($bucket)" -X PUT -H "Content-Type: application/octet-stream" -H "X-Amz-Meta-Asset-Id: $A1" --data-binary x "$U&$what"
    fi
    absent "$bucket/$K" "$what ($bucket)"
  done
done

# ---------------------------------------------------------------------------------------------
echo "3 AC-3 / TM-3 — trailer / aws-chunked / every named header refusal"
refused_put() {   # refused_put <label> <extra curl header args…> — on a legitimate presigned PUT
  label="$1"; shift
  K="private/$O1/$(uuid)/original.pdf"; U="$(mint put media-private "$K" "$A1")"
  refused "$label" -X PUT -H "Content-Type: application/pdf" -H "X-Amz-Meta-Asset-Id: $A1" "$@" --data-binary x "$U"
  absent "media-private/$K" "$label"
}
refused_put "X-Amz-Trailer" -H "X-Amz-Trailer: x-amz-checksum-crc32"
refused_put "X-Amz-Decoded-Content-Length" -H "X-Amz-Decoded-Content-Length: 1"
refused_put "Content-Encoding: aws-chunked" -H "Content-Encoding: aws-chunked"
refused_put "Content-Encoding: AWS-CHUNKED (case)" -H "Content-Encoding: AWS-CHUNKED"
refused_put "Content-Encoding: gzip, aws-chunked (list)" -H "Content-Encoding: gzip, aws-chunked"
refused_put "Content-Encoding twice (gzip, then aws-chunked as a second line)" -H "Content-Encoding: gzip" -H "Content-Encoding: aws-chunked"
NAMES="$(awk '/^storage\./,/^}/' "$CADDYFILE" | grep -E '^[[:space:]]*@refuse_[a-z0-9_]+ header [A-Za-z0-9-]+ \*' | awk '{print $3}')"
[ "$(printf '%s\n' "$NAMES" | grep -c .)" -ge 50 ] || bad "read the named refusals from the Caddyfile" "only $(printf '%s\n' "$NAMES" | grep -c .) found"
echo "  ($(printf '%s\n' "$NAMES" | grep -c .) named presence refusals read from deploy/Caddyfile)"
for name in $NAMES; do
  case "$name" in Authorization) continue ;; esac   # section 6
  K="private/$O1/$(uuid)/original.pdf"; U="$(mint put media-private "$K" "$A1")"
  refused "$name on a presigned PUT" -X PUT -H "Content-Type: application/pdf" -H "X-Amz-Meta-Asset-Id: $A1" -H "$name: x" --data-binary x "$U"
  absent "media-private/$K" "$name"
done
# letter case and the GET / alias shapes for a few of them
refused "lower-case x-amz-copy-source on a presigned PUT" -X PUT -H "x-amz-copy-source: media-private/private/$O1/$A1/original.pdf" --data-binary x "$(mint put media-public "public/$O1/$(uuid)/original.png" "$A1")"
refused "X-Minio-Source-Proxy-Request on a presigned GET" -H "X-Minio-Source-Proxy-Request: true" "$(mint get media-public "$PUBKEY")"
refused "X-Amz-Server-Side-Encryption-Customer-Key on the anonymous alias GET" -H "X-Amz-Server-Side-Encryption-Customer-Key: AAAA" "$BASE/media-public/$ALIAS"
refused "X-Amz-Security-Token on the anonymous alias GET" -H "X-Amz-Security-Token: x" "$BASE/media-public/$ALIAS"

echo "3b AC-3 — the family strips (unnamed members never reach the store)"
docker run -d --name "$TRACE" --network "$STORE_NETWORK" --entrypoint sh \
  -e ROOT_USER="$(val MINIO_ROOT_USER)" -e ROOT_PASSWORD="$(val MINIO_ROOT_PASSWORD)" \
  "$MC_IMAGE" -c 'mc alias set root http://storage:9000 "$ROOT_USER" "$ROOT_PASSWORD" >/dev/null && exec mc admin trace -v root' >/dev/null
sleep 3
STRIPPED="X-Minio-Tester-Probe X-Amz-Meta-Snowball-Tester X-Amz-Meta-Minio-Tester X-Amz-Server-Side-Encryption-Tester X-Amz-Copy-Source-Tester X-Amz-Replication-Tester X-Amz-Object-Lock-Tester X-Amz-Grant-Tester X-Amz-Tagging-Count"
SK="public/$O1/$(uuid)/stripped.png"; U="$(mint put media-public "$SK" "$A1")"
args=(-X PUT -H "Content-Type: image/png" -H "X-Amz-Meta-Asset-Id: $A1" --data-binary "strip-probe-$RUN")
for h in $STRIPPED; do args+=(-H "$h: tester-$RUN"); done
passes "a legitimate presigned PUT carrying one unnamed member of each of the nine families" 200 "${args[@]}" "$U"
sleep 3
docker logs "$TRACE" > "$WORK/trace.txt" 2>&1
docker rm -f "$TRACE" >/dev/null 2>&1
if grep -q "$(basename "$SK")" "$WORK/trace.txt"; then
  ok "mc admin trace -v captured the PUT ($(grep -c "$(basename "$SK")" "$WORK/trace.txt") trace lines name its key)"
  for h in $STRIPPED; do
    if grep -qi "$h" "$WORK/trace.txt"; then bad "$h never reaches the store" "$(grep -i "$h" "$WORK/trace.txt" | head -2)"; else ok "$h stripped (absent from the store's trace)"; fi
  done
  if grep -qi "tester-$RUN" "$WORK/trace.txt"; then bad "no stripped header VALUE reaches the store" "$(grep -i "tester-$RUN" "$WORK/trace.txt" | head -2)"; else ok "no stripped header value reaches the store"; fi
  if grep -qi 'x-amz-meta-asset-id' "$WORK/trace.txt"; then ok "the legitimate X-Amz-Meta-Asset-Id still reaches the store (the strip is not over-broad)"; else bad "the legitimate X-Amz-Meta-Asset-Id still reaches the store" ""; fi
else
  bad "mc admin trace -v captured the PUT" "$(tail -5 "$WORK/trace.txt")"
fi
cp "$WORK/trace.txt" "${TRACE_OUT:-/dev/null}" 2>/dev/null || true

# ---------------------------------------------------------------------------------------------
echo "4 AC-4 / TM-4 — methods"
etag_before="$(store "mc stat --json root/media-public/$PUBKEY" | sed -n 's/.*"etag":"\([^"]*\)".*/\1/p')"
refused "POST ?select&select-type=2 (S3 Select)" -X POST -H "Content-Type: application/xml" --data-binary '<SelectObjectContentRequest/>' "$BASE/media-public/$PUBKEY?select&select-type=2"
refused "POST ?uploads (multipart initiation)" -X POST "$BASE/media-public/$PUBKEY?uploads"
refused "POST ?delete (batch delete)" -X POST -H "Content-Type: application/xml" --data-binary "<Delete><Object><Key>$PUBKEY</Key></Object></Delete>" "$BASE/media-public?delete"
refused "POST on an object (browser-form upload shape)" -X POST -F "file=@$WORK/body.png" "$BASE/media-public/$PUBKEY"
refused "DELETE on an object (presigned query)" -X DELETE "$(mint get media-public "$PUBKEY")"
refused "DELETE on an object (anonymous)" -X DELETE "$BASE/media-public/$PUBKEY"
refused "PATCH on an object" -X PATCH --data-binary x "$BASE/media-public/$PUBKEY"
etag_after="$(store "mc stat --json root/media-public/$PUBKEY" | sed -n 's/.*"etag":"\([^"]*\)".*/\1/p')"
if [ -n "$etag_before" ] && [ "$etag_before" = "$etag_after" ]; then ok "the target object is unchanged (etag $etag_after)"; else bad "the target object is unchanged" "before=$etag_before after=$etag_after"; fi

# ---------------------------------------------------------------------------------------------
echo "5 AC-5 / TM-5 / TM-6 — paths and query keys"
refused "GET / (bucket listing)" "$BASE/"
refused "GET /media-public (bare bucket)" "$BASE/media-public"
refused "GET /media-public/ (object listing)" "$BASE/media-public/"
refused "GET /media-private/ (object listing)" "$BASE/media-private/"
refused "GET /media-public/?list-type=2" "$BASE/media-public/?list-type=2"
refused "another bucket" "$BASE/other-bucket/public/$O1/$A1/original.png"
refused "/minio/admin/v3/info" "$BASE/minio/admin/v3/info"
refused "/minio/health/live" "$BASE/minio/health/live"
refused "/minio/v2/metrics/cluster" "$BASE/minio/v2/metrics/cluster"
refused "/minio/storage/… (internode endpoint, CVE-2026-42600)" -X PUT "$BASE/minio/storage/data/v63/readmultiple"
refused "the .bootstrap-probe sentinel (not an object-key shape)" "$BASE/media-public/.bootstrap-probe"
for q in acl uploads 'versionId=abc' 'response-content-type=text/html' 'response-content-disposition=attachment' tagging policy 'uploadId=1&partNumber=1' attributes torrent; do
  refused "object ?$q" "$BASE/media-public/$ALIAS?$q"
done
refused "presigned GET + response-content-type" "$(mint get media-public "$PUBKEY")&response-content-type=text/html"
refused "path with .. (sent as-is)" --path-as-is "$BASE/media-public/public/../media-private/$PRIVKEY"
refused "path with %2e%2e (sent as-is)" --path-as-is "$BASE/media-public/public/%2e%2e/media-private/$PRIVKEY"
refused "path with an encoded slash" --path-as-is "$BASE/media-public/public%2F$O1/$A1/original.png"
refused "a ; in the query" "$(mint get media-public "$PUBKEY" | sed -E 's/X-Amz-Date=([0-9TZ]+)/X-Amz-Date=\1;x=1/')"
refused "a bare query key" "$BASE/media-public/$ALIAS?X-Amz-Date"
refused "an empty query pair (&&)" "$(mint get media-public "$PUBKEY")&&"
refused "an upper-case object leaf (outside the minted shape)" "$BASE/media-public/public/$A1/MEDIUM.jpg"

# ---------------------------------------------------------------------------------------------
echo "6 AC-6 / TM-6 — header-signed requests (valid media-service credentials)"
header_sign "http://storage:9000" media-public "$PUBKEY" > "$WORK/sig-internal.txt"
ctl_auth="$(grep '^Authorization:' "$WORK/sig-internal.txt")"
case "$ctl_auth" in *"Credential=media-service/"*) ok "the signature names media-service" ;; *) bad "the signature names media-service" "$(printf '%s' "$ctl_auth" | sed -E 's/Signature=[0-9a-f]+/Signature=…/')" ;; esac
ctl_args=(); while IFS= read -r line; do ctl_args+=(-H "$line"); done < "$WORK/sig-internal.txt"
ctl="$("${COMPOSE[@]}" exec -T media curl -sS -o /dev/null -w '%{http_code}' "${ctl_args[@]}" "http://storage:9000/media-public/$PUBKEY" 2>&1 || true)"
if [ "$ctl" = 200 ]; then ok "control: the same identity's header-signed GET straight at the store → 200 (the credentials are valid)"; else bad "control: header-signed GET straight at the store → 200" "$ctl"; fi
header_sign "https://$HOST$PORT_SUFFIX" media-public "$PUBKEY" > "$WORK/sig-perimeter.txt"
p_args=(); while IFS= read -r line; do p_args+=(-H "$line"); done < "$WORK/sig-perimeter.txt"
refused "header-signed GET through storage. (HTTP/1.1)" --http1.1 "${p_args[@]}" "$BASE/media-public/$PUBKEY"
res="$(send --http2 "${p_args[@]}" "$BASE/media-public/$PUBKEY")"
if [ "${res#* }" = 2 ]; then ok "the HTTP/2 probe really negotiated HTTP/2"; else bad "the HTTP/2 probe really negotiated HTTP/2" "$res"; fi
refused "header-signed GET through storage. (HTTP/2)" --http2 "${p_args[@]}" "$BASE/media-public/$PUBKEY"
refused "Authorization header on a presigned GET" -H "Authorization: AWS4-HMAC-SHA256 Credential=x" "$(mint get media-public "$PUBKEY")"
refused "empty Authorization header on the alias GET" -H "Authorization;" "$BASE/media-public/$ALIAS"

# ---------------------------------------------------------------------------------------------
echo "7 TM-1 / TM-6 — repeated header lines and repeated query keys"
refused_put "two X-Amz-Content-Sha256 lines (UNSIGNED-PAYLOAD, then STREAMING-UNSIGNED-PAYLOAD-TRAILER)" -H "X-Amz-Content-Sha256: UNSIGNED-PAYLOAD" -H "X-Amz-Content-Sha256: STREAMING-UNSIGNED-PAYLOAD-TRAILER"
refused_put "two X-Amz-Content-Sha256 lines (streaming first)" -H "X-Amz-Content-Sha256: STREAMING-UNSIGNED-PAYLOAD-TRAILER" -H "X-Amz-Content-Sha256: UNSIGNED-PAYLOAD"
K="private/$O1/$(uuid)/original.pdf"; U="$(mint put media-private "$K" "$A1")"
refused "a query repeating X-Amz-Content-Sha256 with a streaming second value" -X PUT -H "Content-Type: application/pdf" -H "X-Amz-Meta-Asset-Id: $A1" --data-binary x "$U&X-Amz-Content-Sha256=STREAMING-UNSIGNED-PAYLOAD-TRAILER"
absent "media-private/$K" "repeated query key"
# documented edge case (spec § Edge Cases): a repeated ALLOWLISTED key passes the perimeter and
# MinIO's own signature check judges it. Measured: MinIO reads the FIRST occurrence — a forged
# value placed BEFORE the signed one fails the signature (MinIO's XML refusal, nothing written);
# a duplicate placed AFTER it is ignored, so the holder of a valid URL writes exactly what the
# URL already allowed (no new capability).
K="private/$O1/$(uuid)/original.pdf"; U="$(mint put media-private "$K" "$A1")"
U_FORGED="$(printf '%s' "$U" | sed -E 's/\?/?X-Amz-Date=20200101T000000Z\&/')"
res="$(send -X PUT -H "Content-Type: application/pdf" -H "X-Amz-Meta-Asset-Id: $A1" --data-binary x "$U_FORGED")"
if [ "${res%% *}" = 403 ] && grep -q '<Error>' "$WORK/$N.b"; then ok "a repeated allowlisted key with a forged FIRST value reaches MinIO, which refuses it (MinIO's own 403 $(sed -n 's:.*<Code>\(.*\)</Code>.*:\1:p' "$WORK/$N.b"))"; else bad "a repeated allowlisted key with a forged first value is refused by MinIO" "$res $(head -c 200 "$WORK/$N.b")"; fi
absent "media-private/$K" "forged repeated allowlisted key"
res="$(send -X PUT -H "Content-Type: application/pdf" -H "X-Amz-Meta-Asset-Id: $A1" --data-binary x "$U&X-Amz-Date=20200101T000000Z")"
if [ "${res%% *}" = 200 ]; then ok "a duplicate allowlisted key AFTER the signed one is ignored by MinIO (200 — the URL's own write, no new capability)"; else bad "a trailing duplicate allowlisted key is ignored by MinIO" "$res $(head -c 200 "$WORK/$N.b")"; fi
store "mc rm root/media-private/$K" >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------------------------
echo "8 BR-8 / LO-009 — the refusal's access-log line"
MARK="$(uuid)"
refused "a marked refusal for the log check" -X DELETE "$BASE/media-public/public/$MARK/$A1/original.png?X-Amz-Credential=media-presign%2Fsecret-looking-$RUN"
sleep 1
line="$("${COMPOSE[@]}" exec -T caddy sh -c "grep '$MARK' /var/log/caddy/access.log | tail -1")"
if printf '%s' "$line" | grep -q '"status":403' && printf '%s' "$line" | grep -q "\"uri\":\"/media-public/public/$MARK/$A1/original.png\"" && ! printf '%s' "$line" | grep -q "secret-looking"; then
  ok "access log: status 403, the path, no query string ($(printf '%s' "$line" | sed -n 's/.*"request":\({[^}]*}\).*/\1/p'))"
else
  bad "access log: status 403, the path, no query string" "$line"
fi
if printf '%s' "$line" | grep -qi 'authorization\|x-amz'; then bad "access log carries no header" "$line"; else ok "access log carries no request header"; fi

# cleanup of the positive-control objects (root, exact keys)
store "mc rm root/media-public/$PUBKEY root/media-public/$ALIAS root/media-private/$PRIVKEY root/media-public/$SK" >/dev/null 2>&1 || true

echo "→ storage-perimeter: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
