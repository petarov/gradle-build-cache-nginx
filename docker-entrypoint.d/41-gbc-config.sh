#!/bin/sh
# Writes /etc/nginx/gen/cache.conf -- the only part of the nginx config that
# cannot be static, because nginx has no conditionals. Everything else is a
# plain .conf baked into the image.
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

GEN=/etc/nginx/gen
OUT=$GEN/cache.conf
GETH=$GEN/htpasswd.get
PUTH=$GEN/htpasswd.put

log() { echo "gbc-config: $*" >&2; }
die() { echo "gbc-config: FATAL: $*" >&2; exit 1; }

mkdir -p "$GEN"

# ---------------------------------------------------------------- basic auth ---
# What the GBC_HTTP_* variables mean is documented in .env.example.
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

# ------------------------------------------------------------------- render ---
{
    echo "# Generated at container start by 41-gbc-config.sh. Do not edit."
    echo "client_max_body_size $GBC_MAX_ENTRY_SIZE;"

    if [ "$GET_AUTH" = 1 ]; then
        echo "auth_basic           \"$REALM\";"
        echo "auth_basic_user_file $GETH;"
    else
        echo "auth_basic off;"
    fi

    # limit_except GET applies to every other method, i.e. PUT. GET implies HEAD.
    echo "limit_except GET {"
    if [ "$PUT_AUTH" = 1 ]; then
        echo "    auth_basic           \"$REALM (write)\";"
        echo "    auth_basic_user_file $PUTH;"
    else
        echo "    auth_basic off;"
    fi
    echo "}"
} > "$OUT"

log "auth: GET=$([ "$GET_AUTH" = 1 ] && echo on || echo off) PUT=$([ "$PUT_AUTH" = 1 ] && echo on || echo off) max_entry=$GBC_MAX_ENTRY_SIZE"
if [ "$PUT_AUTH" = 0 ]; then
    log "WARNING: PUT is unauthenticated -- anything that can reach this port can"
    log "         write to the cache. Set GBC_HTTP_PUT_USER/PASSWORD."
fi
