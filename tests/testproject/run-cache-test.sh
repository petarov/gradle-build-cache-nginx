#!/usr/bin/env bash
# Stage 2 of the test plan: prove hits come from the REMOTE cache.
#
#   ./run-cache-test.sh http://cache.internal.example/cache/ [user:pass]
#
# Method: two independent clones with separate GRADLE_USER_HOMEs and the local
# cache disabled (-Dgbc.local=false). Clone A pushes, clone B can only pull.
# Any "FROM-CACHE" in clone B therefore came over HTTP -- there is no other
# source. Needs a gradle wrapper or a gradle on PATH.
# No `set -u`: AUTH and INSECURE are intentionally empty arrays when no
# credentials are given or the URL is https, and "${EMPTY[@]}" is an
# unbound-variable error under set -u on bash 3.2 (what macOS ships).
set -eo pipefail

URL=${1:?usage: run-cache-test.sh <cache-url> [user:pass]}
CREDS=${2:-}
SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
INIT=$SRC/../build-cache-test.init.gradle
WORK=$(mktemp -d)
trap 'echo; echo "workdir kept at $WORK"' EXIT

GRADLE=${GRADLE:-$(command -v gradle || true)}
[[ -n $GRADLE ]] || { echo "no gradle on PATH; set GRADLE=/path/to/gradle" >&2; exit 1; }

AUTH=()
if [[ -n $CREDS ]]; then
    AUTH=(-Dgbc.user="${CREDS%%:*}" -Dgbc.password="${CREDS#*:}")
fi
# Gradle refuses a plain-http cache URL unless explicitly allowed.
INSECURE=()
if [[ $URL == http://* ]]; then INSECURE=(-Dgbc.insecure=true); fi

run() { # run <clone> <push> <extra gradle args...>
    local clone=$1 push=$2; shift 2
    ( cd "$WORK/$clone"
      GRADLE_USER_HOME="$WORK/$clone-home" "$GRADLE" \
        --build-cache --no-daemon --console=plain \
        -I "$INIT" -Dgbc.url="$URL" -Dgbc.local=false -Dgbc.push="$push" \
        "${AUTH[@]}" "${INSECURE[@]}" "$@" )
}

for c in a b; do
    mkdir -p "$WORK/$c"
    cp -R "$SRC/." "$WORK/$c/"
    rm -rf "$WORK/$c/build" "$WORK/$c/.gradle"
done

echo "=============== clone A: populate the remote cache (push=true)"
run a true clean build --info | grep -Ei 'stamp|compileJava|Stored entry|build cache|BUILD ' | tail -25

echo
echo "=============== clone B: pull only (push=false, local cache disabled)"
run b false clean build --info | grep -Ei 'stamp|compileJava|Loaded entry|FROM-CACHE|build cache|BUILD ' | tail -25

echo
echo "Expected in clone B: ':compileJava FROM-CACHE' and ':stamp FROM-CACHE'."
echo "  local cache is off in both runs and the GRADLE_USER_HOMEs differ, so a"
echo "  hit can only have come from $URL."
echo "Cross-check on the server: tail the access log and count GET 200s."
