#!/usr/bin/env bash
# Cache eviction. Runs on the HOST (GNU findutils), against the bind-mounted store.
# Two independent passes, both optional:
#   1. age  -- delete entries not read for GBC_MAX_AGE_DAYS days
#   2. size -- delete least-recently-read entries until the store is under
#              GBC_MAX_SIZE_GB (true LRU, which MinIO ILM and plain cron find
#              cannot do)
#
# Safe to run while nginx is serving: unlink(2) on a file nginx has open is fine,
# the reader keeps its file descriptor and finishes the response. A PUT that is
# in flight lives in tmp/ and is never touched by this script.
#
#   gbc-evict.sh [--dry-run] [--by atime|mtime] [--data-dir DIR]
#
# Reads GBC_DATA_DIR, GBC_MAX_AGE_DAYS, GBC_MAX_SIZE_GB from the .env next to
# this repo, or from the environment.
set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
[[ -f $REPO_DIR/.env ]] && set -a && . "$REPO_DIR/.env" && set +a

DATA_DIR=${GBC_DATA_DIR:-/var/lib/gradle-build-cache-nginx}
MAX_AGE_DAYS=${GBC_MAX_AGE_DAYS:-14}
MAX_SIZE_GB=${GBC_MAX_SIZE_GB:-100}
BY=atime
DRY=0
LOG=${GBC_EVICT_LOG:-$DATA_DIR/logs/evict.log}

while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run)   DRY=1 ;;
        --by)        BY=$2; shift ;;
        --data-dir)  DATA_DIR=$2; shift ;;
        --max-age)   MAX_AGE_DAYS=$2; shift ;;
        --max-size)  MAX_SIZE_GB=$2; shift ;;
        -h|--help)   sed -n '2,20p' "$0"; exit 0 ;;
        *)           echo "unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

CACHE=$DATA_DIR/store/cache
case $BY in
    atime) FIND_TIME=-atime; PRINTF_TIME='%A@' ;;
    mtime) FIND_TIME=-mtime; PRINTF_TIME='%T@' ;;
    *) echo "--by must be atime or mtime" >&2; exit 2 ;;
esac

say() { printf '%s %s\n' "$(date -Is)" "$*" | tee -a "$LOG" >&2; }

# --- guards -----------------------------------------------------------------
[[ -d $CACHE ]] || { echo "no cache directory at $CACHE" >&2; exit 1; }
# Refuse to delete in a directory that is not demonstrably a cache store. The
# marker is written by the container's preflight script.
[[ -f $CACHE/.gbc-cache-root ]] || {
    echo "$CACHE has no .gbc-cache-root marker -- refusing to delete anything" >&2
    exit 1
}
mkdir -p "$(dirname "$LOG")"

# LRU needs atime. Ubuntu's default relatime updates atime on read whenever the
# stored atime is older than 24h, which is exactly the granularity this script
# works at. noatime silently freezes atime and turns the size pass into
# "delete the oldest writes", which is not what you want.
if [[ $BY == atime ]]; then
    mp=$(stat -c %m "$CACHE")
    if findmnt -no OPTIONS "$mp" 2>/dev/null | grep -qw noatime; then
        say "WARNING: $mp is mounted noatime -- atime is frozen. Remount with"
        say "         relatime, or run with --by mtime and accept write-age LRU."
    fi
fi

# One eviction at a time; a long size pass must not overlap the next timer tick.
exec 9>"${TMPDIR:-/tmp}/gbc-evict.lock"
flock -n 9 || { say "another eviction is still running -- skipping this tick"; exit 0; }

# Entry files only: 32 hex chars. Never the marker, never anything in tmp/.
find_entries() { find "$CACHE" -type f -regextype posix-extended -regex '.*/[0-9a-f]{32}$' "$@"; }

before_kb=$(du -sk "$CACHE" | cut -f1)
say "start: store=$CACHE by=$BY dry_run=$DRY size=$((before_kb/1024))MiB max_age=${MAX_AGE_DAYS}d max_size=${MAX_SIZE_GB}GB"

# --- pass 1: age ------------------------------------------------------------
if [[ ${MAX_AGE_DAYS:-0} -gt 0 ]]; then
    n=$(find_entries "$FIND_TIME" "+$MAX_AGE_DAYS" -print | wc -l)
    if [[ $DRY -eq 1 ]]; then
        say "age pass: would delete $n entries with $BY older than ${MAX_AGE_DAYS}d"
    else
        find_entries "$FIND_TIME" "+$MAX_AGE_DAYS" -delete
        say "age pass: deleted $n entries with $BY older than ${MAX_AGE_DAYS}d"
    fi
fi

# --- pass 2: size (LRU) -----------------------------------------------------
if [[ ${MAX_SIZE_GB:-0} -gt 0 ]]; then
    budget=$((MAX_SIZE_GB * 1024 * 1024 * 1024))
    total=$(find_entries -printf '%s\n' | awk '{s+=$1} END {print s+0}')
    if [[ $total -le $budget ]]; then
        say "size pass: $((total/1024/1024))MiB <= budget $((budget/1024/1024))MiB, nothing to do"
    else
        need=$((total - budget))
        say "size pass: $((total/1024/1024))MiB over budget by $((need/1024/1024))MiB, evicting LRU"
        # Entry names are [0-9a-f]{32}, so no spaces or newlines can appear in a
        # path here and line-oriented processing is safe.
        list=$(mktemp); trap 'rm -f "$list"' EXIT
        find_entries -printf "$PRINTF_TIME %s %p\n" | sort -n > "$list"
        freed=0; count=0
        while read -r _ sz path; do
            [[ $freed -ge $need ]] && break
            if [[ $DRY -eq 0 ]]; then rm -f -- "$path" || continue; fi
            freed=$((freed + sz)); count=$((count + 1))
        done < "$list"
        if [[ $DRY -eq 1 ]]; then
            say "size pass: would delete $count entries to free $((freed/1024/1024))MiB"
        else
            say "size pass: deleted $count entries, freed $((freed/1024/1024))MiB"
        fi
    fi
fi

# Shard directories are pre-created by the container and deliberately never
# pruned: an empty shard costs 4 KiB and pruning would race create_full_put_path.

after_kb=$(du -sk "$CACHE" | cut -f1)
say "done: size=$((after_kb/1024))MiB (was $((before_kb/1024))MiB), df=$(df -h --output=pcent "$CACHE" | tail -1 | tr -d ' ')"
