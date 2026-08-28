#!/bin/sh
# Render the one thing nginx cannot express itself: the optional basic-auth
# includes. Everything else is a plain .conf file in the repo.
# `docker compose exec gbc nginx -T` prints the effective result.
set -eu

GBC_MAX_ENTRY_SIZE="${GBC_MAX_ENTRY_SIZE:-512m}"
GBC_HTTP_GET_USER="${GBC_HTTP_GET_USER:-}"
GBC_HTTP_GET_PASSWORD="${GBC_HTTP_GET_PASSWORD:-}"
GBC_HTTP_PUT_USER="${GBC_HTTP_PUT_USER:-}"
GBC_HTTP_PUT_PASSWORD="${GBC_HTTP_PUT_PASSWORD:-}"

# Only ever seen by a human curling the endpoint: Gradle sends Basic credentials
# preemptively and never reads a challenge.
REALM=gradle-build-cache-raw

INC=/etc/nginx/gbc-inc
GETH=$INC/htpasswd.get
PUTH=$INC/htpasswd.put

log() { echo "gbc-config: $*" >&2; }
die() { echo "gbc-config: FATAL: $*" >&2; exit 1; }

mkdir -p "$INC"

# ---------------------------------------------------------------- basic auth ---
# Two independent switches, named after the HTTP verbs they guard, because that
# is what nginx can actually enforce -- it authenticates methods, not callers.
#
#   GBC_HTTP_GET_*   empty -> anyone may read the cache
#                    set   -> credentials required to read
#   GBC_HTTP_PUT_*   empty -> anyone may write to the cache
#                    set   -> credentials required to write
#
# PUT is a CI-only verb. Developer builds set isPush=false and never issue one,
# so in practice only the CI credential needs GBC_HTTP_PUT_*; setting it is what
# stops a laptop with isPush=true from writing to the shared cache.
#
# htpasswd -m => apr1. Never -B (bcrypt): musl's crypt() has no bcrypt, so
# nginx:alpine answers 401 for every bcrypt hash, with only a terse log line.
: > "$GETH"; : > "$PUTH"
GET_AUTH=0
PUT_AUTH=0

if [ -n "$GBC_HTTP_GET_USER" ]; then
    [ -n "$GBC_HTTP_GET_PASSWORD" ] || die "GBC_HTTP_GET_USER is set but GBC_HTTP_GET_PASSWORD is empty"
    htpasswd -bm "$GETH" "$GBC_HTTP_GET_USER" "$GBC_HTTP_GET_PASSWORD" >/dev/null
    GET_AUTH=1
fi
if [ -n "$GBC_HTTP_PUT_USER" ]; then
    [ -n "$GBC_HTTP_PUT_PASSWORD" ] || die "GBC_HTTP_PUT_USER is set but GBC_HTTP_PUT_PASSWORD is empty"
    htpasswd -bm "$PUTH" "$GBC_HTTP_PUT_USER" "$GBC_HTTP_PUT_PASSWORD" >/dev/null
    PUT_AUTH=1
    # CI reads before it writes, so the PUT credential must satisfy the GET realm
    # too -- otherwise every CI cache lookup is a 401.
    if [ "$GET_AUTH" = 1 ]; then
        htpasswd -bm "$GETH" "$GBC_HTTP_PUT_USER" "$GBC_HTTP_PUT_PASSWORD" >/dev/null
    fi
fi
chmod 0640 "$GETH" "$PUTH"; chown root:nginx "$GETH" "$PUTH"

if [ "$GET_AUTH" = 1 ]; then
    printf 'auth_basic           "%s";\nauth_basic_user_file %s;\n' "$REALM" "$GETH" > "$INC/auth-get.conf"
else
    echo 'auth_basic off;' > "$INC/auth-get.conf"
fi

# limit_except GET applies to every other method, i.e. PUT. GET implies HEAD.
if [ "$PUT_AUTH" = 1 ]; then
    printf '    limit_except GET {\n        auth_basic           "%s (write)";\n        auth_basic_user_file %s;\n    }\n' \
        "$REALM" "$PUTH" > "$INC/auth-put.conf"
else
    printf '    limit_except GET {\n        auth_basic off;\n    }\n' > "$INC/auth-put.conf"
fi

log "auth: GET=$([ "$GET_AUTH" = 1 ] && echo on || echo off) PUT=$([ "$PUT_AUTH" = 1 ] && echo on || echo off)"
if [ "$PUT_AUTH" = 0 ]; then
    log "WARNING: PUT is unauthenticated -- anything that can reach this port can"
    log "         write to the cache. Set GBC_HTTP_PUT_USER/PASSWORD."
fi

# -------------------------------------------------------------- config files ---
# Explicit variable list: envsubst must not touch nginx's own $variables.
envsubst '${GBC_MAX_ENTRY_SIZE}' < /etc/nginx/gbc-src/cache.conf > "$INC/cache.conf"

log "rendered: max_entry=$GBC_MAX_ENTRY_SIZE"
