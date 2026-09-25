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
REGISTRY_NS="ghcr.io/silfaran-trades"

PORT_SUFFIX=""
[ "$CADDY_HTTPS_PORT" = 443 ] || PORT_SUFFIX=":${CADDY_HTTPS_PORT}"

COMPOSE=(docker compose --project-directory "$DEPLOY" -f "$DEPLOY/docker-compose.prod.yml")

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
          || die "trades-front/Dockerfile has no 'runtime' target yet (the Frontend Developer phase adds it) — run with REHEARSE_SERVICES=\"app media\" until it lands"
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
  log "scratch secrets written under $SECRETS (gitignored)"
}

write_deploy_env() {
  mkdir -p "$DEPLOY"
  # a fresh copy of deploy/ so deploy/.env, the lock and the compose project live in scratch
  for f in docker-compose.prod.yml Caddyfile deploy.sh backup-postgres.sh restore-drill.sh host-sentinel.sh; do
    cp "$DEPLOY_SRC/$f" "$DEPLOY/$f"
  done
  rm -rf "$DEPLOY/postgres-init"; cp -R "$DEPLOY_SRC/postgres-init" "$DEPLOY/postgres-init"
  chmod +x "$DEPLOY"/*.sh
  {
    echo "DOMAIN=${DOMAIN}"
    echo "CADDY_TLS_ARG=internal"
    echo "CADDY_HTTP_PORT=${CADDY_HTTP_PORT}"
    echo "CADDY_HTTPS_PORT=${CADDY_HTTPS_PORT}"
    echo "TRADES_SECRETS_DIR=${SECRETS}"
    echo "TRADES_PROD_SUBNET=${TRADES_PROD_SUBNET}"
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
}
spki_hash() {
  docker run --rm -v "$SCRATCH/ca:/ca:ro" --entrypoint sh "$(image_for app)" -c \
    'openssl x509 -in /ca/root.crt -pubkey -noout | openssl pkey -pubin -outform der | openssl dgst -sha256 -binary | openssl base64' 2>/dev/null || echo '?'
}

deploy_env_exports() {
  export CURL_CA_BUNDLE="$SCRATCH/ca/root.crt"
  export SMOKE_CURL_EXTRA_ARGS="--resolve app.${DOMAIN}:${CADDY_HTTPS_PORT}:127.0.0.1 --resolve api.${DOMAIN}:${CADDY_HTTPS_PORT}:127.0.0.1 --resolve media.${DOMAIN}:${CADDY_HTTPS_PORT}:127.0.0.1 --resolve storage.${DOMAIN}:${CADDY_HTTPS_PORT}:127.0.0.1"
  export BACKUP_DIR="$SCRATCH/backups"
  export LOG_ARCHIVE_DIR="$SCRATCH/log-archive"
  export DEPLOY_LOCK_DIR="$SCRATCH/deploy.lock"
  export AGE_RECIPIENT_FILE="$SECRETS/backup-age.recipient"
  export SKIP_PULL=1
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

  Evidence commands (spec AC-1..AC-24 / deployment.md § First-deploy rehearsal):
    export CURL_CA_BUNDLE=$SCRATCH/ca/root.crt
    R="--resolve api.${DOMAIN}:${CADDY_HTTPS_PORT}:127.0.0.1 --resolve app.${DOMAIN}:${CADDY_HTTPS_PORT}:127.0.0.1 --resolve media.${DOMAIN}:${CADDY_HTTPS_PORT}:127.0.0.1 --resolve storage.${DOMAIN}:${CADDY_HTTPS_PORT}:127.0.0.1"
    curl -sSI \$R https://api.${DOMAIN}${PORT_SUFFIX}/api/health                              # headers as served (AC-14, AC-18)
    curl -sS -o /dev/null -w '%{http_code}\n' \$R https://api.${DOMAIN}${PORT_SUFFIX}/api/v1/school-link/training-needs   # 401, never 404 (AC-6)
    docker compose --project-directory $DEPLOY -f $DEPLOY/docker-compose.prod.yml ps        # every worker healthy (AC-4)
    docker compose --project-directory $DEPLOY -f $DEPLOY/docker-compose.prod.yml exec caddy tail -n 5 /var/log/caddy/access.log   # LO-009 lines (AC-8)
    BACKUP_DIR=$SCRATCH/backups AGE_RECIPIENT_FILE=$SECRETS/backup-age.recipient $DEPLOY/backup-postgres.sh          # dumps (AC-19)
    BACKUP_DIR=$SCRATCH/backups $DEPLOY/restore-drill.sh $SECRETS/backup-age.key                                     # drill (AC-15)
    SKIP_PULL=1 BACKUP_DIR=$SCRATCH/backups LOG_ARCHIVE_DIR=$SCRATCH/log-archive DEPLOY_LOCK_DIR=$SCRATCH/deploy.lock $DEPLOY/deploy.sh app <sha>   # AC-7 (refused without a fresh dump)
  Browser (AC-9/AC-10/AC-21): Chromium with --host-resolver-rules="MAP *.${DOMAIN} 127.0.0.1" --ignore-certificate-errors-spki-list=$(spki_hash)
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
