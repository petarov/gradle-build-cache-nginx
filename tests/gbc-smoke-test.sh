#!/usr/bin/env bash
# Stage 1 of the test plan: HttpBuildCache protocol conformance, curl level.
# Requires bash (the torn-upload case uses /dev/tcp) and curl.
#
#   ./gbc-smoke-test.sh <cache-url> [writeuser:pass] [readuser:pass]
#   ./gbc-smoke-test.sh http://localhost/cache/ ci:secret
#   ./gbc-smoke-test.sh https://cache.internal.example/cache/ ci:secret dev:secret
#
# Exits non-zero on the first failure count > 0. Safe against production: it only
# writes the four fa11bacc… keys below. Those stay in the store until eviction
# collects them -- DELETE is intentionally not enabled on the server.
# No `set -u`: WOPT/ROPT are intentionally empty arrays when no credentials are
# given, and "${EMPTY[@]}" is an unbound-variable error under set -u in bash.
set -o pipefail

BASE=${1:?usage: gbc-smoke-test.sh <cache-url-with-or-without-trailing-slash> [w_user:pass] [r_user:pass]}
BASE=${BASE%/}
W=${2:-}
R=${3:-}
if [[ -n $W ]]; then WOPT=(-u "$W"); else WOPT=(); fi
if [[ -n $R ]]; then ROPT=(-u "$R"); else ROPT=(); fi

K_BASIC=fa11bacc000000000000000000000001
K_TORN=fa11bacc000000000000000000000002
K_CONC=fa11bacc000000000000000000000003
K_BIG=fa11bacc000000000000000000000004

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
chk() { if [[ $2 == "$3" ]]; then ok "$1 -> $2"; else bad "$1: got $2, want $3"; fi; }
sc()  { curl -s -o /dev/null -w '%{http_code}' "$@"; }
get() { curl -s -o "$1" -w '%{http_code}' "${@:2}"; }
section() { printf '\n\033[1m%s\033[0m\n' "$1"; }
fill() { head -c "$2" /dev/zero | LC_ALL=C tr '\000' "$3" > "$1"; }

head -c 262144 /dev/urandom > "$TMP/entry.bin"
head -c 262144 /dev/urandom > "$TMP/entry2.bin"

section "1. GET/PUT round trip"
chk "GET unknown key is a miss"          "$(sc "${ROPT[@]}" "$BASE/$K_BASIC")" 404
chk "PUT new entry"                      "$(sc "${WOPT[@]}" -X PUT --data-binary @"$TMP/entry.bin" "$BASE/$K_BASIC")" 201
chk "GET stored entry is a hit"          "$(get "$TMP/got.bin" "${ROPT[@]}" "$BASE/$K_BASIC")" 200
if cmp -s "$TMP/entry.bin" "$TMP/got.bin"; then ok "body is byte-identical"; else bad "body differs from what was stored"; fi
# The Nexus "deployment policy = Allow redeploy" trap: re-storing a key must be a 2xx.
chk "PUT over an existing key (redeploy)" "$(sc "${WOPT[@]}" -X PUT --data-binary @"$TMP/entry2.bin" "$BASE/$K_BASIC")" 204
chk "GET returns the new bytes"           "$(get "$TMP/got2.bin" "${ROPT[@]}" "$BASE/$K_BASIC")" 200
if cmp -s "$TMP/entry2.bin" "$TMP/got2.bin"; then ok "overwrite took effect"; else bad "overwrite did not take effect"; fi

section "2. Key validation -- every malformed key must be 404, never 403/405/500"
for k in \
  "FA11BACC000000000000000000000001" \
  "short" \
  "fa11bacc00000000000000000000000" \
  "fa11bacc000000000000000000000001f" \
  "fa11bacc000000000000000000000001/" \
  "sub/fa11bacc000000000000000000000001" \
  "../../etc/passwd" \
  "fa11bacc0000000000000000000000zz" ; do
    chk "GET /$k" "$(sc "${ROPT[@]}" "$BASE/$k")" 404
done
chk "PUT to a malformed key" "$(sc "${WOPT[@]}" -X PUT --data-binary @"$TMP/entry.bin" "$BASE/nothex")" 404

section "3. Torn upload -- a half-finished PUT must stay a miss, never a truncated 200"
proto=${BASE%%://*}
rest=${BASE#*://}
if [[ $rest == */* ]]; then hostport=${rest%%/*}; path=/${rest#*/}; else hostport=$rest; path=""; fi
host=${hostport%%:*}
port=${hostport##*:}
if [[ $port == "$host" ]]; then if [[ $proto == https ]]; then port=443; else port=80; fi; fi
if [[ $proto == https ]]; then
    # Pure bash cannot speak TLS, so abort the client instead. Same nginx path:
    # premature EOF while reading the request body.
    head -c 33554432 /dev/urandom > "$TMP/slow.bin"
    curl -s -o /dev/null "${WOPT[@]}" -X PUT --limit-rate 200k --max-time 2 \
         --data-binary @"$TMP/slow.bin" "$BASE/$K_TORN"
    ok "aborted a 32 MB PUT after ~2s"
else
    auth=""
    if [[ -n $W ]]; then
        auth="Authorization: Basic $(printf '%s' "$W" | base64 | tr -d '\n')"$'\r\n'
    fi
    if exec 3<>"/dev/tcp/$host/$port"; then
        printf 'PUT %s/%s HTTP/1.1\r\nHost: %s\r\n%sContent-Length: 4000000\r\nConnection: close\r\n\r\n' \
            "$path" "$K_TORN" "$hostport" "$auth" >&3
        head -c 65536 /dev/urandom >&3
        sleep 0.2
        exec 3>&-; exec 3<&-
        ok "declared 4000000 bytes, sent 65536, closed the connection"
    else
        bad "cannot open a raw socket to $host:$port"
    fi
fi
sleep 1
chk "GET after the torn upload is still a miss" "$(sc "${ROPT[@]}" "$BASE/$K_TORN")" 404

section "4. Concurrent PUTs of one key -- last writer wins, no interleaving"
: > "$TMP/conc.err"
for i in 0 1 2 3 4 5 6 7 8 9; do
    fill "$TMP/p$i.bin" 2000000 "$i"      # 2 MB of a single distinct digit
done
for i in 0 1 2 3 4 5 6 7 8 9; do
    ( c=$(sc "${WOPT[@]}" -X PUT --data-binary @"$TMP/p$i.bin" "$BASE/$K_CONC")
      [[ $c == 201 || $c == 204 ]] || echo "writer $i got $c" >> "$TMP/conc.err" ) &
done
wait
if [[ -s $TMP/conc.err ]]; then bad "non-2xx from a concurrent writer: $(tr '\n' ';' < "$TMP/conc.err")"
else ok "all 10 concurrent PUTs returned 201/204"; fi
chk "GET after the concurrent PUTs" "$(get "$TMP/conc.bin" "${ROPT[@]}" "$BASE/$K_CONC")" 200
matched=""
for i in 0 1 2 3 4 5 6 7 8 9; do
    cmp -s "$TMP/p$i.bin" "$TMP/conc.bin" && matched="$i"
done
if [[ -n $matched ]]; then ok "stored entry is byte-identical to writer $matched's payload"
else bad "stored entry matches no single writer -- interleaved or truncated ($(wc -c < "$TMP/conc.bin") bytes)"; fi

section "5. Auth"
if [[ -n $W ]]; then
    chk "PUT with no credentials"     "$(sc -X PUT --data-binary @"$TMP/entry.bin" "$BASE/$K_BASIC")" 401
    chk "PUT with a wrong password"   "$(sc -u "${W%%:*}:definitely-wrong" -X PUT --data-binary @"$TMP/entry.bin" "$BASE/$K_BASIC")" 401
    if [[ -n $R && $R != "$W" ]]; then
        # This is what a developer who sets isPush=true by accident sees. It
        # presents as "caching just stopped" in their build log.
        chk "PUT with reader credentials" "$(sc "${ROPT[@]}" -X PUT --data-binary @"$TMP/entry.bin" "$BASE/$K_BASIC")" 401
    fi
    chk "PUT with writer credentials"  "$(sc "${WOPT[@]}" -X PUT --data-binary @"$TMP/entry.bin" "$BASE/$K_BASIC")" 204
else
    printf '  \033[33mSKIP\033[0m no write credentials given\n'
fi
if [[ -n $R ]]; then
    chk "GET with no credentials" "$(sc "$BASE/$K_BASIC")" 401
else
    chk "GET with no credentials (anonymous pull expected)" "$(sc "$BASE/$K_BASIC")" 200
fi

section "6. Methods Gradle never sends (documented, not a requirement)"
printf '  DELETE -> %s (405 expected: dav_methods lists PUT only)\n' "$(sc "${WOPT[@]}" -X DELETE "$BASE/$K_BASIC")"
printf '  HEAD   -> %s\n' "$(sc "${ROPT[@]}" -I "$BASE/$K_BASIC")"

section "7. Oversize entry -- the 413 boundary, which must never be reached in production"
if [[ -n ${GBC_TEST_OVERSIZE:-} ]]; then
    head -c "$GBC_TEST_OVERSIZE" /dev/zero > "$TMP/big.bin"
    chk "PUT $GBC_TEST_OVERSIZE bytes" "$(sc "${WOPT[@]}" -X PUT --data-binary @"$TMP/big.bin" "$BASE/$K_BIG")" 413
else
    printf '  \033[33mSKIP\033[0m set GBC_TEST_OVERSIZE=<bytes above client_max_body_size> to run\n'
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
