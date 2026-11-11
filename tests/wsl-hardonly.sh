#!/usr/bin/env bash
# Exercise the synchronous path on the installed kernel: soft off, hard kept,
# a 10 GiB read and a 6 GiB buffered write (dirty pages bounded by
# vm.dirty_bytes). Restores the previous limits at the end.
set -Eeuo pipefail
IFS=$'\n\t'

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
P=/sys/module/pagecache_limit/parameters
PCLTEST="$ROOT/out/pcltest"
BENCH_DIR="${BENCH_DIR:-/root/pclimit-bench}"
out="$ROOT/results/hardonly-$(date +%Y%m%d-%H%M%S).txt"
old_soft=$(cat $P/soft_limit)
trap 'echo "$old_soft" > $P/soft_limit; rm -f "$BENCH_DIR/write6g.dat"' EXIT
hard=$(cat $P/hard_limit)
fail=0
log() { echo "$*" | tee -a "$out"; }
st() { awk -v k="$1" '$1 == k { print $2 }' $P/stats; }
clean_kb() { awk '/^Active\(file\):/ { a = $2 } /^Inactive\(file\):/ { i = $2 } /^Dirty:/ { d = $2 } /^Writeback:/ { w = $2 } END { f = a + i; u = d + w; print (u < f ? f - u : 0) }' /proc/meminfo; }
lim=$((hard / 1024 + 65536))

echo 0 > $P/soft_limit
log "# kernel=$(uname -r) soft=0 hard=$hard dirty_bytes=$(sysctl -n vm.dirty_bytes) date=$(date -Is)"

sync; echo 3 > /proc/sys/vm/drop_caches
c0=$(st sync_calls) r0=$(st sync_reclaimed_pages)
r=$("$PCLTEST" read "$BENCH_DIR/func10g.dat")
pk=$(sed -n 's/.*peak_clean_kb=\([0-9]*\).*/\1/p' <<<"$r")
log "hard-only 10G read: $r"
log "  sync_calls +$(( $(st sync_calls) - c0 )), sync_reclaimed_pages +$(( $(st sync_reclaimed_pages) - r0 ))"
if ((pk <= lim)); then log "PASS peak clean $pk kB <= hard + 64M"; else log "FAIL peak clean $pk kB > hard + 64M"; fail=1; fi

sync; echo 3 > /proc/sys/vm/drop_caches
r=$("$PCLTEST" write "$BENCH_DIR/write6g.dat" 6144); sync
log "hard-only 6G write + sync: $r"
n=0; while (( $(clean_kb) > lim && n < 50 )); do sleep 0.1; n=$((n + 1)); done
if (( $(clean_kb) <= lim )); then log "PASS clean back under hard + 64M ($(clean_kb) kB) $((n / 10)).$((n % 10)) s after sync"; else log "FAIL clean $(clean_kb) kB after 5 s"; fail=1; fi
exit $fail
