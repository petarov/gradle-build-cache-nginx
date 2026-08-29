#!/bin/sh
# Fail fast at container start on the misconfigurations that would otherwise
# surface as HTTP 500s or silently torn cache entries at runtime.
# (The noatime check that LRU eviction depends on lives in systemd/gbc-evict.sh,
#  which runs on the host and can see the real mount options.)
set -eu

CACHE=/data/cache
TMP=/data/tmp

log() { echo "gbc-preflight: $*" >&2; }
die() { echo "gbc-preflight: FATAL: $*" >&2; exit 1; }

install -d -o nginx -g nginx -m 0755 "$CACHE" "$TMP" 2>/dev/null || true
[ -d "$CACHE" ] || die "$CACHE does not exist and could not be created (is /data mounted read-only?)"
[ -d "$TMP" ]   || die "$TMP does not exist and could not be created"

# Ownership. Workers run as uid 101 (nginx). A host dir the worker cannot write
# makes the very first PUT a 500, which disables caching for that whole build.
if ! su-exec nginx:nginx sh -c "touch $CACHE/.gbc-probe && rm -f $CACHE/.gbc-probe" 2>/dev/null; then
    die "$CACHE is not writable by uid 101. On the host run:
   chown -R 101:101 <data-dir>/cache <data-dir>/tmp"
fi
if ! su-exec nginx:nginx sh -c "touch $TMP/.gbc-probe && rm -f $TMP/.gbc-probe" 2>/dev/null; then
    die "$TMP is not writable by uid 101 (chown -R 101:101 <data-dir>/tmp)"
fi

# Marker: systemd/gbc-evict.sh refuses to delete anything in a directory without it.
[ -f "$CACHE/.gbc-cache-root" ] || {
    printf 'gradle-build-cache-raw entry store. Files here are disposable.\n' \
        > "$CACHE/.gbc-cache-root"
    chown nginx:nginx "$CACHE/.gbc-cache-root"
}

# Shards. Pre-creating all 256 removes the create_full_put_path/prune race
# entirely: the eviction job never has to remove a directory.
if [ ! -d "$CACHE/ff" ]; then
    log "pre-creating 256 shard directories under $CACHE"
    for a in 0 1 2 3 4 5 6 7 8 9 a b c d e f; do
        for b in 0 1 2 3 4 5 6 7 8 9 a b c d e f; do
            install -d -o nginx -g nginx -m 0755 "$CACHE/$a$b"
        done
    done
fi
