#!/usr/bin/env bash
#
# Trades — the local first-deploy rehearsal (production-packaging-promotion-lane, BR-26;
# deployment.md § "First-deploy rehearsal"; first-deploy-checklist.md step 9).
#
# Boots deploy/docker-compose.prod.yml ON THIS MACHINE from images built with the CD job's
# Dockerfiles and build arguments, a scratch env file set and scratch secrets, and runs
# deploy.sh's OWN sequence — so the next DE-001/DE-002/DE-003-class defect is found here, not
# on the first production host. Everything lands in the gitignored `.scratch/` tree next to
# this script; nothing here is a secret until it is generated there.
#
# Usage:
#   ./rehearse.sh up        build the images, generate the scratch secrets, boot the perimeter,
#                           promote app → media → web through deploy.sh, then verify that EVERY
#                           service the production compose declares is running
#   ./rehearse.sh status    compose ps + the evidence commands
#   ./rehearse.sh down      tear the stack down (volumes included); the scratch tree stays — the
#                           next `up` regenerates every secret in it (the age key pair excepted)
#
# Knobs (env):
#   REHEARSE_SERVICES   "app media web" (default) — drop `web` while the SPA image has no
#                       `runtime` target yet
#   DOMAIN              trades.test (default) — resolved to loopback with curl --resolve / the
#                       browser's --host-resolver-rules; no /etc/hosts edit
#   CADDY_HTTP_PORT / CADDY_HTTPS_PORT   80 / 443 (default) — move them if the laptop holds them
#   TRADES_PROD_SUBNET  172.30.0.0/24 (default)
#   COMPOSER_AUTH       Composer's github-oauth JSON for the private llm-gateway package;
#                       derived from `gh auth token` when unset (the credential never touches
#                       disk, an image layer or this log — it is a BuildKit secret)
#   SKIP_BUILD=1        reuse the images already built for the repos' current HEAD SHAs
#   REGISTRY            rehearsal.invalid (default) — the rehearsal registry NAME the local
#                       builds and the cached object-store images are tagged under, so the
#                       production compose's `${REGISTRY}/trades/<name>` references resolve
#                       OFFLINE (10.6, BR-36). Nothing is ever pushed there.
#
# Rehearsal-only deviations from the committed deploy/ (each applied to the SCRATCH COPY, never
# to the committed files): the object-store images by tag (above); and the app containers
# trusting Caddy's local CA root through a merged CA bundle mounted over the image's bundle
# path (write_deploy_env + trust_perimeter_ca) — the synthetic-data lane's presigned uploads go
# through the perimeter, and in production that site carries a publicly trusted certificate.
# TLS verification is never switched off anywhere (SE-003).
#
# Host tools: docker (with BuildKit), age + age-keygen (already on the developer machine; on
# the production host 10.6's user-data installs them — the backup lane needs them there).
# Everything else runs inside the built images or digest-pinned containers.
#
# Bash 3.2-safe on purpose (macOS /bin/bash): no mapfile, no associative arrays.

set -euo pipefail

CMD="${1:-up}"
REHEARSAL_DIR="$(cd "$(dirname "$0")" && pwd)"
DEPLOY_SRC="$(cd "$REHEARSAL_DIR/.." && pwd)"
INFRA_DIR="$(cd "$DEPLOY_SRC/.." && pwd)"
WORKSPACE="$(cd "$INFRA_DIR/.." && pwd)"
SCRATCH="$REHEARSAL_DIR/.scratch"
SECRETS="$SCRATCH/secrets"
DEPLOY="$SCRATCH/deploy"
TEMPLATES="$REHEARSAL_DIR/templates"

DOMAIN="${DOMAIN:-trades.test}"
CADDY_HTTP_PORT="${CADDY_HTTP_PORT:-80}"
CADDY_HTTPS_PORT="${CADDY_HTTPS_PORT:-443}"
TRADES_PROD_SUBNET="${TRADES_PROD_SUBNET:-172.30.0.0/24}"
REHEARSE_SERVICES="${REHEARSE_SERVICES:-app media web}"
# The rehearsal registry name (10.6): a reserved, unresolvable host — a typo'd `docker pull`
# can never reach a real registry. Production's REGISTRY is `terraform output registry`.
REGISTRY="${REGISTRY:-rehearsal.invalid}"
REGISTRY_NS="$REGISTRY/trades"

# The cached object-store images (ADR-126): the exact 10.4 references, present only in the
# developer's local cache — upstream no longer serves them. The rehearsal re-tags them under
# the rehearsal registry name; production runs the ECR-mirrored copies by digest.
MINIO_SRC="quay.io/minio/minio:RELEASE.2025-09-07T16-13-09Z@sha256:14cea493d9a34af32f524e538b8346cf79f3321eff8e708c1e2960462bd8936e"
MC_SRC="quay.io/minio/mc:RELEASE.2025-08-13T08-35-41Z@sha256:a7fe349ef4bd8521fb8497f55c6042871b2ae640607cf99d9bede5e9bdf11727"
MINIO_TAG="$REGISTRY_NS/minio:RELEASE.2025-09-07T16-13-09Z"
MC_TAG="$REGISTRY_NS/mc:RELEASE.2025-08-13T08-35-41Z"

PORT_SUFFIX=""
[ "$CADDY_HTTPS_PORT" = 443 ] || PORT_SUFFIX=":${CADDY_HTTPS_PORT}"

COMPOSE=(docker compose --project-directory "$DEPLOY" -f "$DEPLOY/docker-compose.prod.yml")
# The merged CA bundle the app containers of the scratch stack trust (write_deploy_env +
# trust_perimeter_ca): the image's bundle plus Caddy's local root. Rehearsal only.
APP_CA_BUNDLE="$SCRATCH/ca/app-ca-bundle.crt"

log()  { printf '→ rehearse: %s\n' "$*"; }
warn() { printf '⚠ rehearse: %s\n' "$*" >&2; }
die()  { printf '✗ rehearse: %s\n' "$*" >&2; exit 1; }

require_tool() { command -v "$1" >/dev/null 2>&1 || die "$1 not found — $2"; }

# 32 random bytes as hex, no host openssl needed.
gen_hex() { head -c "${1:-32}" /dev/urandom | od -An -tx1 | tr -d ' \n'; }

# --- env-file rendering -----------------------------------------------------------------
# render_env <.env.example> <overrides> <out>: every key of the example, in its order; an
# override wins; CHANGE_ME (or `@generate…`) is generated; override keys absent from the
# example are appended. Tokens @DOMAIN@ @SUBNET@ @POSTGRES_PASSWORD@ @MINIO_ROOT_USER@
# @MINIO_ROOT_PASSWORD@ are substituted last.
override_value() {   # override_value <overrides> <key>  → prints the value, rc 1 if absent
  grep -E "^${2}=" "$1" 2>/dev/null | head -1 | cut -d= -f2- || return 1
  grep -qE "^${2}=" "$1" 2>/dev/null
}
materialise() {      # materialise <value> → generated when the value asks for it
  case "$1" in
    CHANGE_ME|@generate|@generate:hex32) gen_hex 32 ;;
    @generate:hex64) gen_hex 64 ;;
    *) printf '%s' "$1" ;;
  esac
}
render_env() {
  example="$1"; overrides="$2"; out="$3"
  : > "$out"
  seen=" "
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|'#'*) continue ;;
    esac
    key="${line%%=*}"; value="${line#*=}"
    case "$key" in *[!A-Za-z0-9_]*) continue ;; esac
    if ov="$(override_value "$overrides" "$key")"; then value="$ov"; fi
    printf '%s=%s\n' "$key" "$(materialise "$value")" >> "$out"
    seen="$seen$key "
  done < "$example"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    key="${line%%=*}"; value="${line#*=}"
    case "$seen" in *" $key "*) continue ;; esac
    printf '%s=%s\n' "$key" "$(materialise "$value")" >> "$out"
  done < "$overrides"
  # token substitution (sed on the whole file; values never contain the delimiter `|`)
  sed -e "s|@DOMAIN@|${DOMAIN}${PORT_SUFFIX}|g" \
      -e "s|@SUBNET@|${TRADES_PROD_SUBNET}|g" \
      -e "s|@POSTGRES_PASSWORD@|${POSTGRES_PASSWORD}|g" \
      -e "s|@MINIO_ROOT_USER@|${MINIO_ROOT_USER}|g" \
      -e "s|@MINIO_ROOT_PASSWORD@|${MINIO_ROOT_PASSWORD}|g" \
      "$out" > "$out.tmp" && mv "$out.tmp" "$out"
  chmod 600 "$out"
}
env_value() { grep -E "^${2}=" "$1" | head -1 | cut -d= -f2-; }

# --- the repos and their SHAs ------------------------------------------------------------
repo_sha() { git -C "$WORKSPACE/$1" rev-parse HEAD; }

image_for() {
  case "$1" in
    app)   printf '%s/trades-backend:%s' "$REGISTRY_NS" "$(repo_sha trades-backend)" ;;
    media) printf '%s/media-service:%s'  "$REGISTRY_NS" "$(repo_sha media-service)" ;;
    web)   printf '%s/trades-front:%s'   "$REGISTRY_NS" "$(repo_sha trades-front)" ;;
  esac
}

# The object store's images under the rehearsal registry name (10.6, BR-33). A `docker tag`
# gives an image a NAME, never a repository DIGEST (digests are recorded by pull/push only), so
# the production compose's `${REGISTRY}/trades/minio@sha256:…` reference can NOT resolve a
# locally tagged copy — write_deploy_env below rewrites those two lines in the rehearsal's
# scratch COPY of the compose to the tagged references. The committed compose is untouched.
tag_object_store_images() {
  for pair in "$MINIO_SRC|$MINIO_TAG" "$MC_SRC|$MC_TAG"; do
    src="${pair%%|*}"; dst="${pair#*|}"
    docker image inspect "$src" >/dev/null 2>&1 \
      || die "cached object-store image $src not found — upstream no longer serves it (ADR-126); the rehearsal needs the developer's local cache"
    docker tag "$src" "$dst"
    log "tagged $src → $dst (rehearsal name; nothing is pushed)"
  done
}

build_images() {
  for svc in $REHEARSE_SERVICES; do
    img="$(image_for "$svc")"
    if [ "${SKIP_BUILD:-0}" = "1" ] && docker image inspect "$img" >/dev/null 2>&1; then
      log "reusing $img (SKIP_BUILD=1)"; continue
    fi
    case "$svc" in
      app)
        if [ -z "${COMPOSER_AUTH:-}" ]; then
          require_tool gh "COMPOSER_AUTH is unset and gh is not available to derive it (the private llm-gateway package needs a read-only GitHub token)"
          # A literal JSON string is the intended value (Composer's github-oauth shape).
          # shellcheck disable=SC2089,SC2090
          COMPOSER_AUTH='{"github-oauth":{"github.com":"'"$(gh auth token)"'"}}'
          # shellcheck disable=SC2090
          export COMPOSER_AUTH
        fi
        log "building $img (trades-backend runtime target; COMPOSER_AUTH as a BuildKit secret)"
        docker build --target runtime -t "$img" --secret id=composer_auth,env=COMPOSER_AUTH "$WORKSPACE/trades-backend"
        ;;
      media)
        log "building $img (media-service runtime target)"
        docker build --target runtime -t "$img" "$WORKSPACE/media-service"
        ;;
      web)
        grep -qE '^FROM .* AS runtime' "$WORKSPACE/trades-front/Dockerfile" \
          || die "trades-front/Dockerfile has no 'runtime' target yet — run with REHEARSE_SERVICES=\"app media\" until it lands"
        args=()
        while IFS= read -r line || [ -n "$line" ]; do
          case "$line" in ''|'#'*) continue ;; esac
          line="$(printf '%s' "$line" | sed -e "s|@DOMAIN@|${DOMAIN}|g" -e "s|@PORT@|${PORT_SUFFIX}|g")"
          args+=(--build-arg "$line")
        done < "$TEMPLATES/web.build-args"
        args+=(--build-arg "VITE_APP_VERSION=$(repo_sha trades-front)")
        log "building $img (trades-front runtime target, ${DOMAIN} origins)"
        docker build --target runtime -t "$img" "${args[@]}" "$WORKSPACE/trades-front"
        ;;
    esac
  done
}

# --- scratch secrets ------------------------------------------------------------------------
generate_secrets() {
  mkdir -p "$SECRETS/files" "$SCRATCH/backups" "$SCRATCH/log-archive" "$SCRATCH/ca"
  chmod 700 "$SECRETS"

  # infrastructure credentials (postgres.env / storage.env; mercure.env after app.env)
  POSTGRES_PASSWORD="$(gen_hex 32)"; MINIO_ROOT_USER="trades-storage"; MINIO_ROOT_PASSWORD="$(gen_hex 32)"
  printf 'POSTGRES_USER=trades\nPOSTGRES_PASSWORD=%s\nPOSTGRES_DB=trades_app\n' "$POSTGRES_PASSWORD" > "$SECRETS/postgres.env"
  printf 'MINIO_ROOT_USER=%s\nMINIO_ROOT_PASSWORD=%s\n' "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" > "$SECRETS/storage.env"
  chmod 600 "$SECRETS/postgres.env" "$SECRETS/storage.env"

  # the two application env files — every key of each .env.example (AC-13 parity)
  render_env "$WORKSPACE/trades-backend/.env.example" "$TEMPLATES/app.env.overrides" "$SECRETS/app.env"
  render_env "$WORKSPACE/media-service/.env.example"  "$TEMPLATES/media.env.overrides" "$SECRETS/media.env"

  # the hub reads the SAME two values under its own names — copied, so they cannot drift here
  printf 'MERCURE_PUBLISHER_JWT_KEY=%s\nMERCURE_SUBSCRIBER_JWT_KEY=%s\n' \
    "$(env_value "$SECRETS/app.env" MERCURE_JWT_SECRET)" \
    "$(env_value "$SECRETS/app.env" MERCURE_SUBSCRIBER_JWT_KEY)" > "$SECRETS/mercure.env"
  chmod 600 "$SECRETS/mercure.env"

  # file-shaped secrets, mounted read-only at /run/secrets/files (BR-4, spec § Open Questions).
  # Every `up` regenerates the whole set from scratch — app.env above was just re-rendered
  # with a NEW passphrase, so a key pair left by the previous run can never match it. The
  # previous files are 0440/0444 and, on the macOS bind mount, not writable even by the
  # container's root: `openssl genpkey` then reports "Can't open ... for writing" and STILL
  # exits 0, leaving the old key on disk for the new passphrase to fail against (rehearsal,
  # D8). So: wipe the directory first (the host user owns it), and treat "the file was not
  # written" as the error genpkey's exit code does not report — stderr stays visible (`-quiet` drops only the progress dots).
  rm -rf "$SECRETS/files"; mkdir -p "$SECRETS/files"
  app_img="$(image_for app)"
  jwt_pass="$(env_value "$SECRETS/app.env" JWT_PASSPHRASE)"
  log "generating the JWT key pair (RSA 4096, passphrase-protected) inside the backend image"
  docker run --rm --user 0 -e "JWT_PASS=$jwt_pass" -v "$SECRETS/files:/out" --entrypoint sh "$app_img" -c '
    set -e
    [ -z "$(ls -A /out)" ] || { echo "✗ /out is not empty — the previous secrets were not removed" >&2; exit 1; }
    openssl genpkey -quiet -algorithm RSA -pkeyopt rsa_keygen_bits:4096 -aes-256-cbc -pass env:JWT_PASS -out /out/jwt-private.pem
    [ -s /out/jwt-private.pem ] || { echo "✗ /out/jwt-private.pem was not written" >&2; exit 1; }
    # decrypting with THIS passphrase is the proof the key on disk is the one just generated
    openssl pkey -in /out/jwt-private.pem -passin env:JWT_PASS -pubout -out /out/jwt-public.pem
    [ -s /out/jwt-public.pem ] || { echo "✗ /out/jwt-public.pem was not written" >&2; exit 1; }
    openssl genpkey -quiet -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out /out/.fcm-rehearsal-key.pem
    [ -s /out/.fcm-rehearsal-key.pem ] || { echo "✗ /out/.fcm-rehearsal-key.pem was not written" >&2; exit 1; }
    php -r "file_put_contents(\"/out/dummy-password-hash.txt\", password_hash(bin2hex(random_bytes(32)), PASSWORD_ARGON2ID));"
    [ -s /out/dummy-password-hash.txt ] || { echo "✗ /out/dummy-password-hash.txt was not written" >&2; exit 1; }
    chown 33:33 /out/*.pem /out/.fcm-rehearsal-key.pem /out/dummy-password-hash.txt
    chmod 0440 /out/jwt-private.pem /out/dummy-password-hash.txt; chmod 0444 /out/jwt-public.pem
  ' || die "the file-shaped secrets were not (re)generated — see the openssl/php output above"
  for f in jwt-private.pem jwt-public.pem .fcm-rehearsal-key.pem dummy-password-hash.txt; do
    [ -s "$SECRETS/files/$f" ] || die "$SECRETS/files/$f is missing or empty after generation"
  done
  # the FCM placeholder: the template's shape with a throwaway private key (newlines escaped)
  fcm_key="$(awk 'BEGIN{ORS="\\n"} {print}' "$SECRETS/files/.fcm-rehearsal-key.pem")"
  awk -v k="$fcm_key" '{ gsub(/@REHEARSAL_RSA_PRIVATE_KEY_PEM@/, k); print }' "$TEMPLATES/fcm-credentials.rehearsal.json" > "$SECRETS/files/fcm-credentials.json"
  rm -f "$SECRETS/files/.fcm-rehearsal-key.pem"
  chmod 0444 "$SECRETS/files/fcm-credentials.json"

  # the backup lane's age key pair — the identity stays here for restore-drill.sh
  if [ ! -f "$SECRETS/backup-age.key" ]; then
    age-keygen -o "$SECRETS/backup-age.key" 2>/dev/null
    grep -E '^# public key:' "$SECRETS/backup-age.key" | sed 's/^# public key: //' > "$SECRETS/backup-age.recipient"
    chmod 600 "$SECRETS/backup-age.key"
  fi
  # The stage-1 basic-auth credential (BR-18/19): a per-run password and its bcrypt hash from
  # the pinned Caddy image. The password is printed ONCE below for the browser walk; the hash
  # goes into the scratch deploy/.env SINGLE-QUOTED (compose corrupts an unquoted `$`).
  BASIC_AUTH_USER="partner"
  BASIC_AUTH_PASSWORD="$(gen_hex 16)"
  caddy_img="$(grep -oE 'image: caddy:[^[:space:]]+' "$DEPLOY_SRC/docker-compose.prod.yml" | head -1 | cut -d' ' -f2)"
  BASIC_AUTH_HASH="$(docker run --rm "$caddy_img" caddy hash-password -p "$BASIC_AUTH_PASSWORD" 2>/dev/null)" \
    || die "could not hash the rehearsal basic-auth password with $caddy_img"
  printf 'BASIC_AUTH_USER=%s\nBASIC_AUTH_PASSWORD=%s\n' "$BASIC_AUTH_USER" "$BASIC_AUTH_PASSWORD" > "$SECRETS/basic-auth.env"
  chmod 600 "$SECRETS/basic-auth.env"
  log "scratch secrets written under $SECRETS (gitignored); the basic-auth password is in $SECRETS/basic-auth.env"
}

write_deploy_env() {
  mkdir -p "$DEPLOY"
  # a fresh copy of deploy/ so deploy/.env, the lock and the compose project live in scratch
  for f in docker-compose.prod.yml Caddyfile deploy.sh backup-postgres.sh restore-drill.sh host-sentinel.sh seed-synthetic.sh; do
    cp "$DEPLOY_SRC/$f" "$DEPLOY/$f"
  done
  rm -rf "$DEPLOY/postgres-init"; cp -R "$DEPLOY_SRC/postgres-init" "$DEPLOY/postgres-init"
  rm -rf "$DEPLOY/agent-db"; cp -R "$DEPLOY_SRC/agent-db" "$DEPLOY/agent-db"
  chmod +x "$DEPLOY"/*.sh "$DEPLOY"/agent-db/*.sh
  # The object store BY TAG in the scratch copy only (see tag_object_store_images): the two
  # `${REGISTRY:?…}/trades/<minio|mc>@sha256:<digest>` lines become `…/<name>:<release tag>`.
  # awk, not sed -i (GNU and BSD disagree on its argument); the committed file is untouched.
  awk -v minio="$MINIO_TAG" -v mc="$MC_TAG" '
    /^[[:space:]]*image:[[:space:]]*\$\{REGISTRY[^}]*\}\/trades\/minio@sha256:/ { sub(/image:.*/, "image: " minio "   # rehearsal: tagged copy of the cached image (rehearse.sh)") }
    /^[[:space:]]*image:[[:space:]]*\$\{REGISTRY[^}]*\}\/trades\/mc@sha256:/    { sub(/image:.*/, "image: " mc "   # rehearsal: tagged copy of the cached image (rehearse.sh)") }
    { print }' "$DEPLOY_SRC/docker-compose.prod.yml" > "$DEPLOY/docker-compose.prod.yml"
  grep -q "image: $MINIO_TAG" "$DEPLOY/docker-compose.prod.yml" || die "the rehearsal compose rewrite did not land (minio) — check the image: line shape in deploy/docker-compose.prod.yml"
  grep -q "image: $MC_TAG" "$DEPLOY/docker-compose.prod.yml" || die "the rehearsal compose rewrite did not land (mc) — check the image: line shape in deploy/docker-compose.prod.yml"
  # REHEARSAL-ONLY TRUST OF THE LOCAL CA (10.6 seed lane, SE-003 kept): the synthetic-data lane
  # PUTs presigned uploads to https://storage.${DOMAIN} through the perimeter (`caddy`, see
  # deploy/seed-synthetic.sh UPLOAD TARGET), and here that site is signed by Caddy's `tls
  # internal` root, which the app image's CA bundle cannot know. Production trusts the public
  # CA and needs nothing. So — in the SCRATCH COPY of the compose only — every container of the
  # `x-app-common` anchor (app + workers + the one-off seed containers) mounts a MERGED bundle
  # (the image's own /etc/ssl/certs/ca-certificates.crt + the exported root, written by
  # trust_perimeter_ca after the perimeter boots) read-only OVER the image's bundle path.
  # Verification is never switched off: an extra trusted root, nothing else. The committed
  # compose is untouched; the bind source must exist before any app container starts.
  awk -v bundle="$APP_CA_BUNDLE" '
    /^x-app-common:/ { in_anchor = 1 }
    in_anchor && /^[^[:space:]]/ && !/^x-app-common:/ { in_anchor = 0 }
    { print }
    in_anchor && /^[[:space:]]*-[[:space:]]*\$\{TRADES_SECRETS_DIR[^}]*\}\/files:\/run\/secrets\/files:ro/ {
      print "    - " bundle ":/etc/ssl/certs/ca-certificates.crt:ro   # rehearsal: the image bundle + Caddy local root (rehearse.sh; verification stays ON)"
    }' "$DEPLOY/docker-compose.prod.yml" > "$DEPLOY/docker-compose.prod.yml.tmp" && mv "$DEPLOY/docker-compose.prod.yml.tmp" "$DEPLOY/docker-compose.prod.yml"
  [ "$(grep -c "$APP_CA_BUNDLE:/etc/ssl/certs/ca-certificates.crt:ro" "$DEPLOY/docker-compose.prod.yml")" = 1 ] \
    || die "the rehearsal compose rewrite did not land (app CA bundle) — check the x-app-common volumes shape in deploy/docker-compose.prod.yml"
  {
    echo "DOMAIN=${DOMAIN}"
    echo "CADDY_TLS_ARG=internal"
    echo "CADDY_HTTP_PORT=${CADDY_HTTP_PORT}"
    echo "CADDY_HTTPS_PORT=${CADDY_HTTPS_PORT}"
    echo "TRADES_SECRETS_DIR=${SECRETS}"
    echo "TRADES_PROD_SUBNET=${TRADES_PROD_SUBNET}"
    echo "REGISTRY=${REGISTRY}"
    echo "BASIC_AUTH_USER=${BASIC_AUTH_USER}"
    # SINGLE-QUOTED (BR-19): compose interpolates an unquoted `$` and corrupts the hash.
    echo "BASIC_AUTH_HASH='${BASIC_AUTH_HASH}'"
    # No BACKUPS_BUCKET in the rehearsal: backup-postgres.sh needs REHEARSAL_NO_OFFHOST_COPY=1.
  } > "$DEPLOY/.env"
  # tags: every deployable starts as the unpromotable sentinel; deploy.sh pins each SHA
  for var in APP_TAG MEDIA_TAG WEB_TAG; do echo "${var}=bootstrap-pending" >> "$DEPLOY/.env"; done
}

# --- the perimeter first: its local CA is what the smoke checks trust -----------------------
boot_perimeter() {
  log "starting the perimeter (Caddy, tls internal)"
  "${COMPOSE[@]}" up -d caddy
  i=0
  until "${COMPOSE[@]}" cp caddy:/data/caddy/pki/authorities/local/root.crt "$SCRATCH/ca/root.crt" >/dev/null 2>&1; do
    i=$((i + 1)); [ "$i" -lt 60 ] || die "Caddy's local CA root did not appear within 60s (docker compose logs caddy)"
    sleep 1
  done
  log "Caddy local CA root exported to $SCRATCH/ca/root.crt — curl trusts it via CURL_CA_BUNDLE; Chromium via --ignore-certificate-errors-spki-list=$(spki_hash)"
  trust_perimeter_ca
}
# The merged CA bundle the scratch compose mounts over the app image's bundle path (see
# write_deploy_env): the image's own bundle, verbatim, plus the root just exported. Rebuilt on
# every `up` because `down -v` wipes caddy-data and the next boot mints a new local root.
trust_perimeter_ca() {
  app_img="$(image_for app)"
  docker run --rm --entrypoint cat "$app_img" /etc/ssl/certs/ca-certificates.crt > "$APP_CA_BUNDLE.tmp" \
    || die "could not read /etc/ssl/certs/ca-certificates.crt from $app_img (the Debian php image ships it there; adjust trust_perimeter_ca if the base image moved it)"
  [ -s "$APP_CA_BUNDLE.tmp" ] || die "the app image's CA bundle came back empty"
  printf '\n# --- rehearsal only: Caddy local CA root (tls internal) ---\n' >> "$APP_CA_BUNDLE.tmp"
  cat "$SCRATCH/ca/root.crt" >> "$APP_CA_BUNDLE.tmp"
  mv "$APP_CA_BUNDLE.tmp" "$APP_CA_BUNDLE"
  chmod 0444 "$APP_CA_BUNDLE"
  log "app-image CA bundle + Caddy root merged into $APP_CA_BUNDLE (mounted read-only by the scratch compose's app containers; rehearsal only)"
}
spki_hash() {
  docker run --rm -v "$SCRATCH/ca:/ca:ro" --entrypoint sh "$(image_for app)" -c \
    'openssl x509 -in /ca/root.crt -pubkey -noout | openssl pkey -pubin -outform der | openssl dgst -sha256 -binary | openssl base64' 2>/dev/null || echo '?'
}

deploy_env_exports() {
  export CURL_CA_BUNDLE="$SCRATCH/ca/root.crt"
  export SMOKE_CURL_EXTRA_ARGS="--resolve app.${DOMAIN}:${CADDY_HTTPS_PORT}:127.0.0.1 --resolve api.${DOMAIN}:${CADDY_HTTPS_PORT}:127.0.0.1 --resolve media.${DOMAIN}:${CADDY_HTTPS_PORT}:127.0.0.1 --resolve storage.${DOMAIN}:${CADDY_HTTPS_PORT}:127.0.0.1 --resolve mail.${DOMAIN}:${CADDY_HTTPS_PORT}:127.0.0.1"
  export BACKUP_DIR="$SCRATCH/backups"
  export LOG_ARCHIVE_DIR="$SCRATCH/log-archive"
  export DEPLOY_LOCK_DIR="$SCRATCH/deploy.lock"
  export AGE_RECIPIENT_FILE="$SECRETS/backup-age.recipient"
  export SKIP_PULL=1
  # No S3 in the rehearsal: the inline DE-005 backup runs local-only, loudly (10.6, BR-28).
  export REHEARSAL_NO_OFFHOST_COPY=1
}

promote_all() {
  deploy_env_exports
  for svc in $REHEARSE_SERVICES; do
    case "$svc" in
      app)   sha="$(repo_sha trades-backend)" ;;
      media) sha="$(repo_sha media-service)" ;;
      web)   sha="$(repo_sha trades-front)" ;;
    esac
    # First boot: the database is empty, so the DE-005 gate is skipped EXPLICITLY here — the
    # second run (the Tester's AC-7 proof) runs deploy.sh without it and must be refused.
    log "deploy.sh $svc $sha (SKIP_BACKUP_GATE=1 — first boot, empty database)"
    SKIP_BACKUP_GATE=1 "$DEPLOY/deploy.sh" "$svc" "$sha"
  done
}

# --- every declared service is RUNNING after the first boot ---------------------------------
# A promotion starts services one at a time, and a service nothing depends on is exactly what
# such a sequence leaves out — the Mercure hub was (rehearsal AC-23: 502, no container). So the
# harness does not trust the sequence: it lists what docker-compose.prod.yml DECLARES and
# checks each one — `running` (and `healthy` where a healthcheck exists), `storage-init` exited
# 0 (a one-shot). Services that ride a deployable dropped from REHEARSE_SERVICES are skipped.
#
# `starting` is neither: it is a healthcheck that has not concluded yet, and a service the
# promotion does not gate — `clamav` (media only `depends_on` it `service_started`; its first
# boot pulls the signature DB inside a 180 s start_period) — can legitimately still be there
# when the last deploy.sh returns. So a `starting` service is given up to $1 seconds to settle:
# `healthy` passes, `unhealthy`/`exited`/timeout fail (rehearsal, D6 — where the harness read
# `web` as `starting` because deploy.sh returned on its exec probe; deploy.sh step 4a now gates
# the promoted container's Docker health itself, so the poll here is for the ungated rest).
# A hard miss (no container, exited, unhealthy) fails at once — waiting cannot fix it.
verify_runtime_set() {
  budget="${1:-240}"; deadline=$(( $(date +%s) + budget ))
  while :; do
    missing=""; starting=""
    for svc in $("${COMPOSE[@]}" config --services); do
      case "$svc" in
        web)                               case " $REHEARSE_SERVICES " in *" web "*) ;; *) continue ;; esac ;;
        media|clamav|storage|storage-init) case " $REHEARSE_SERVICES " in *" media "*) ;; *) continue ;; esac ;;
      esac
      cid="$("${COMPOSE[@]}" ps -aq "$svc" 2>/dev/null | head -1)"
      if [ -z "$cid" ]; then
        missing="$missing $svc(no container)"; continue
      fi
      state="$(docker inspect -f '{{.State.Status}}/{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}/{{.State.ExitCode}}' "$cid" 2>/dev/null || echo 'absent/none/-')"
      case "$svc:$state" in
        storage-init:exited/*/0) ;;
        *:running/healthy/*|*:running/none/*) ;;
        *:running/starting/*) starting="$starting $svc" ;;
        *) missing="$missing $svc($state)" ;;
      esac
    done
    if [ -n "$missing" ] || [ -z "$starting" ] || [ "$(date +%s)" -ge "$deadline" ]; then break; fi
    log "healthcheck(s) still starting:$starting — waiting (up to ${budget}s)"
    sleep 5
  done
  for svc in $starting; do missing="$missing $svc(running/starting — not healthy within ${budget}s)"; done
  if [ -n "$missing" ]; then
    warn "declared services NOT running/healthy after the promotion:$missing"
    return 1
  fi
  log "runtime set complete — every service docker-compose.prod.yml declares is running and healthy (storage-init exited 0)"
}

print_evidence_hints() {
  cat <<EOF

✓ rehearse: stack up — project trades-prod, domain ${DOMAIN}${PORT_SUFFIX}, scratch $SCRATCH

  Evidence commands (10.4 AC-1..AC-24 and 10.6's rehearsal rows / deployment.md § First-deploy rehearsal):
    export CURL_CA_BUNDLE=$SCRATCH/ca/root.crt
    R="--resolve api.${DOMAIN}:${CADDY_HTTPS_PORT}:127.0.0.1 --resolve app.${DOMAIN}:${CADDY_HTTPS_PORT}:127.0.0.1 --resolve media.${DOMAIN}:${CADDY_HTTPS_PORT}:127.0.0.1 --resolve storage.${DOMAIN}:${CADDY_HTTPS_PORT}:127.0.0.1 --resolve mail.${DOMAIN}:${CADDY_HTTPS_PORT}:127.0.0.1"
    curl -sSI \$R https://api.${DOMAIN}${PORT_SUFFIX}/api/health                              # headers as served; answers without credentials (AC-5)
    curl -sSI \$R https://app.${DOMAIN}${PORT_SUFFIX}/                                        # 401 + the floor + private, no-store + noindex (AC-3, AC-5)
    curl -sSI \$R https://mail.${DOMAIN}${PORT_SUFFIX}/                                       # 401 as well (BR-25); with -u \$(cut -d= -f2 $SECRETS/basic-auth.env | paste -sd: -) the viewer (AC-7)
    curl -sS -o /dev/null -w '%{http_code}\n' \$R https://api.${DOMAIN}${PORT_SUFFIX}/api/v1/school-link/training-needs   # 401, never 404 (AC-19)
    docker compose --project-directory $DEPLOY -f $DEPLOY/docker-compose.prod.yml ps        # every service healthy, mailpit included
    docker compose --project-directory $DEPLOY -f $DEPLOY/docker-compose.prod.yml exec caddy tail -n 5 /var/log/caddy/access.log   # LO-009 lines
    REHEARSAL_NO_OFFHOST_COPY=1 BACKUP_DIR=$SCRATCH/backups AGE_RECIPIENT_FILE=$SECRETS/backup-age.recipient $DEPLOY/backup-postgres.sh   # local dumps (no S3 here)
    BACKUP_DIR=$SCRATCH/backups $DEPLOY/restore-drill.sh $SECRETS/backup-age.key                                     # drill (AC-16's local half)
    SKIP_PULL=1 REHEARSAL_NO_OFFHOST_COPY=1 BACKUP_DIR=$SCRATCH/backups LOG_ARCHIVE_DIR=$SCRATCH/log-archive DEPLOY_LOCK_DIR=$SCRATCH/deploy.lock $DEPLOY/deploy.sh app <sha>   # the gate without a fresh dump
    SKIP_PULL=1 SKIP_BACKUP_GATE=1 BACKUP_DIR=$SCRATCH/backups LOG_ARCHIVE_DIR=$SCRATCH/log-archive DEPLOY_LOCK_DIR=$SCRATCH/deploy.lock $DEPLOY/deploy.sh app <sha>   # AC-23: REFUSED once identity.users has rows
    (seed lane, AC-18/AC-22 — on the EMPTY database, once; uploads go through caddy, whose local root the app containers trust here via $APP_CA_BUNDLE)
    umask 077 && printf 'SYNTHETIC_SEED_PASSWORD=%s\n' "\$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')" > $SECRETS/synthetic-seed.env
    COMPOSE_DIR=$DEPLOY SEED_PASSWORD_FILE=$SECRETS/synthetic-seed.env $DEPLOY/seed-synthetic.sh --confirm-production-stage-1
    (agent-role lane, AC-14/TM-3 — after the migrations; re-run after any inventory change)
    umask 077 && printf 'AI_READONLY_PASSWORD=%s\n' "\$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')" > $SECRETS/ai-readonly.env
    COMPOSE_DIR=$DEPLOY AI_READONLY_ENV_FILE=$SECRETS/ai-readonly.env $DEPLOY/agent-db/provision-agent-role.sh
  Browser (AC-4/AC-21): Chromium with --host-resolver-rules="MAP *.${DOMAIN} 127.0.0.1" --ignore-certificate-errors-spki-list=$(spki_hash); basic auth: $SECRETS/basic-auth.env
  Tear down: $0 down
EOF
}

case "$CMD" in
  up)
    require_tool docker "install Docker Desktop"
    require_tool age-keygen "age is on the developer machine already; the backup lane needs it"
    require_tool age "age is on the developer machine already; the backup lane needs it"
    docker info >/dev/null 2>&1 || die "the Docker daemon is not reachable"
    for r in trades-backend media-service; do [ -d "$WORKSPACE/$r" ] || die "sibling repo $WORKSPACE/$r not found"; done
    mkdir -p "$SCRATCH"
    build_images
    tag_object_store_images
    generate_secrets
    write_deploy_env
    boot_perimeter
    promote_all
    verify_runtime_set || die "the promotion left part of the runtime set down — a first production boot would too (docker compose ps above; fix deploy.sh, not the harness)"
    print_evidence_hints
    ;;
  status)
    [ -f "$DEPLOY/.env" ] || die "no rehearsal stack (run: $0 up)"
    "${COMPOSE[@]}" ps
    verify_runtime_set 0 || true    # the state NOW — `status` never waits
    print_evidence_hints
    ;;
  down)
    [ -f "$DEPLOY/docker-compose.prod.yml" ] || die "no rehearsal stack to tear down"
    log "tearing the rehearsal stack down (volumes included — it is scratch)"
    "${COMPOSE[@]}" down -v --remove-orphans
    rm -rf "$SCRATCH/deploy.lock"
    log "done; the scratch tree $SCRATCH is kept (gitignored) — delete it by hand when finished"
    ;;
  *)
    die "usage: $0 up | status | down"
    ;;
esac
