#!/usr/bin/env bash
# Functional check on the installed kernel in real WSL, with the configured
# limits (default 3G/4G). Reads a 10 GiB file and a 1 GiB file on drvfs
# (/mnt/c) and checks that clean page cache stayed under the hard limit and
# settled under the soft limit.
#
#   tests/wsl-func.sh
set -Eeuo pipefail
IFS=$'\n\t'

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
P=/sys/module/pagecache_limit/parameters
BENCH_DIR="${BENCH_DIR:-/root/pclimit-bench}"
DRVFS_FILE="${DRVFS_FILE:-/mnt/c/Users/Public/pclimit-drvfs.dat}"
TOL_KB=$((64 * 1024))
out="$ROOT/results/func-$(date +%Y%m%d-%H%M%S).txt"
mkdir -p "$BENCH_DIR" "$ROOT/results"

PCLTEST="$ROOT/out/pcltest"
gcc -static -O2 -Wall -o "$PCLTEST" "$ROOT/tests/qemu/pcltest.c"

soft=$(cat $P/soft_limit) hard=$(cat $P/hard_limit)
[[ "$hard" != 0 && "$soft" != 0 ]] || { echo "set both limits first" >&2; exit 1; }
fail=0
log() { echo "$*" | tee -a "$out"; }
val() { sed -n "s/.*$2=\([0-9.]*\).*/\1/p" <<<"$1"; }
st() { awk -v k="$1" '$1 == k { print $2 }' $P/stats; }
file_kb() { awk '/^Active\(file\):/ { a = $2 } /^Inactive\(file\):/ { i = $2 } END { print a + i }' /proc/meminfo; }
pgsteal_file() { awk '$1 == "pgsteal_file" { print $2 }' /proc/vmstat; }
drop() { sync; echo 3 > /proc/sys/vm/drop_caches; }

log "# kernel=$(uname -r) soft=$soft hard=$hard date=$(date -Is)"

big="$BENCH_DIR/func10g.dat"
[[ "$(stat -c %s "$big" 2>/dev/null || echo 0)" -ge $((10 << 30)) ]] ||
  dd if=/dev/urandom of="$big" bs=16M count=640 status=none

drop
c0=$(st sync_calls) a0=$(st async_reclaimed_pages) g0=$(pgsteal_file)
r=$("$PCLTEST" read "$big")
pk=$(val "$r" peak_clean_kb)
log "10G read: $r"
if ((pk <= hard / 1024 + TOL_KB)); then log "PASS peak clean ${pk} kB <= hard + 64M"; else log "FAIL peak clean ${pk} kB > hard + 64M"; fail=1; fi
n=0; while (( $(file_kb) > soft / 1024 && n < 300 )); do sleep 0.1; n=$((n + 1)); done
if (( $(file_kb) <= soft / 1024 )); then log "PASS settled under soft: $(file_kb) kB after $((n / 10)).$((n % 10)) s"; else log "FAIL still $(file_kb) kB after 30 s"; fail=1; fi
log "sync_calls +$(( $(st sync_calls) - c0 )), async_reclaimed_pages +$(( $(st async_reclaimed_pages) - a0 )), pgsteal_file +$(( $(pgsteal_file) - g0 ))"

dd if=/dev/urandom of="$DRVFS_FILE" bs=16M count=64 status=none
drop
r=$("$PCLTEST" read "$DRVFS_FILE") && log "PASS drvfs 1G read: $r" || { log "FAIL drvfs read"; fail=1; }
rm -f "$DRVFS_FILE"

log "== stats"; cat $P/stats | tee -a "$out"
((fail == 0)) && log "RESULT ok" || log "RESULT FAILED"
echo "results: $out"
exit $fail
