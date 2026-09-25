#!/usr/bin/env bash
# Caddyfile gate — `caddy adapt` in the digest-pinned Caddy image, then READ the adapted JSON
# (production-packaging-promotion-lane, BR-25). The exit code of `caddy validate` proves the
# file parses; it proves nothing about what the log lines carry (the template's lexer trap:
# a wrong escape makes the uri filter fail OPEN with "Valid configuration"). So the checks
# below assert the adapted config's SHAPE:
#   1. adapts cleanly with the rehearsal AND the production tls argument
#   2. the query-string filter on request>uri is present, with the `[?].*$` pattern
#   3. remote_ip AND client_ip are ip_mask'ed (both, on the access loggers and the default one)
#   4. the file writer carries BOTH ceilings: roll_interval (24h) and roll_keep_days (14)
#   5. every site block has a logger (Caddy logs nothing without one)
#   6. exactly ONE Strict-Transport-Security writer — the storage host (BR-32); the other
#      hosts carry no security header (application-emitted, BR-15a)
#
# Usage: scripts/checks/check-caddyfile.sh [deploy/Caddyfile]
# Needs docker. Fails closed: no docker → red.

set -euo pipefail

cd "$(dirname "$0")/../.."
CADDYFILE="${1:-deploy/Caddyfile}"
CADDY_IMAGE="${CADDY_IMAGE:-caddy:2.11@sha256:0c994536bddb66445885237f1a5dcc1916bccea922661c76b4e9fc24061f9b52}"

[ -f "$CADDYFILE" ] || { echo "✗ check-caddyfile: $CADDYFILE not found" >&2; exit 2; }
command -v docker >/dev/null 2>&1 || { echo "✗ check-caddyfile: docker not found — the check runs Caddy as a container and does not skip" >&2; exit 1; }

adapt() {
  docker run --rm -v "$PWD/$CADDYFILE:/etc/caddy/Caddyfile:ro" -e "DOMAIN=$1" -e "CADDY_TLS_ARG=$2" \
    "$CADDY_IMAGE" caddy adapt --config /etc/caddy/Caddyfile 2>&1
}

json_prod="$(adapt example.com ops@example.com)" || { echo "✗ check-caddyfile: adapt failed (production args):"; echo "$json_prod"; exit 1; }
json_reh="$(adapt trades.test internal)" || { echo "✗ check-caddyfile: adapt failed (rehearsal args):"; echo "$json_reh"; exit 1; }
echo "→ caddy adapt: OK (production + rehearsal arguments)"

# `caddy adapt` prints COMPACT JSON and Go's encoder escapes `>` as \u003e — every pattern
# below is a FIXED STRING (grep -F) matched against exactly that shape. `|| true` keeps a
# zero-count from ending the script under pipefail: zero is a verdict, not an error.
count() { printf '%s' "$1" | grep -oF -- "$2" | wc -l | tr -d ' ' || true; }
count_re() { printf '%s' "$1" | grep -oE -- "$2" | wc -l | tr -d ' ' || true; }

fails=0
check() {   # check <ok?> <message>
  if [ "$1" = 0 ]; then echo "  ✓ $2"; else echo "  ✗ $2" >&2; fails=$((fails + 1)); fi
}

# 2. query-string filter on request>uri (the exact pattern; a re-escaped one fails open)
n="$(count "$json_reh" '"request\u003euri":{"filter":"regexp","regexp":"[?].*$"}')"
check "$([ "$n" -ge 5 ] && echo 0 || echo 1)" "request>uri regexp filter '[?].*\$' present on every logger ($n found, need >=5: 4 site loggers + default)"

# 3. both IP fields masked, /24 and /48
n_remote="$(count "$json_reh" '"request\u003eremote_ip":{"filter":"ip_mask","ipv4_cidr":24,"ipv6_cidr":48}')"
n_client="$(count "$json_reh" '"request\u003eclient_ip":{"filter":"ip_mask","ipv4_cidr":24,"ipv6_cidr":48}')"
check "$([ "$n_remote" -ge 5 ] && [ "$n_client" -ge 5 ] && echo 0 || echo 1)" "remote_ip and client_ip ip_mask'ed /24 /48 on every logger (remote=$n_remote client=$n_client)"

# 4. both roll ceilings on the file writer (Caddy's JSON: roll_interval in ns, roll_keep_days)
n_int="$(count "$json_reh" '"roll_interval":86400000000000')"
n_days="$(count "$json_reh" '"roll_keep_days":14')"
check "$([ "$n_int" -ge 1 ] && [ "$n_days" -ge 1 ] && echo 0 || echo 1)" "file writer carries roll_interval=24h and roll_keep_days=14 (the 14-day ceiling of pii-inventory.md)"

# 5. a logger per site block — the four hostnames
for host in app api media storage; do
  n="$(count_re "$json_reh" "\"${host}\.trades\.test\":\[\"log[0-9]+\"\]")"
  check "$([ "$n" -ge 1 ] && echo 0 || echo 1)" "site ${host}.trades.test has an access logger"
done

# 6. exactly one HSTS writer (the storage host); no CSP anywhere (application-emitted)
n_hsts="$(count "$json_reh" 'Strict-Transport-Security')"
check "$([ "$n_hsts" = 1 ] && echo 0 || echo 1)" "exactly one Strict-Transport-Security writer in the proxy (found $n_hsts — the storage host, BR-32)"
n_csp="$(count "$json_reh" 'Content-Security-Policy')"
check "$([ "$n_csp" = 0 ] && echo 0 || echo 1)" "no Content-Security-Policy set by the proxy (found $n_csp — CSP is application-emitted, BR-15a)"

if [ "$fails" -gt 0 ]; then
  echo "✗ check-caddyfile: $fails check(s) failed" >&2
  exit 1
fi
echo "→ check-caddyfile: OK"
