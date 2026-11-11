#!/usr/bin/env bash
# Interleaved A/B throughput: limits off vs on, alternating every run so that
# drift in the Windows host cache of the VHDX hits both modes equally.
#   tests/wsl-ab.sh [N]        N rounds (default 5); restores the limits
set -Eeuo pipefail
IFS=$'\n\t'
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
P=/sys/module/pagecache_limit/parameters
BENCH_DIR="${BENCH_DIR:-/root/pclimit-bench}"
N="${1:-5}"
ON_SOFT="${ON_SOFT:-3G}" ON_HARD="${ON_HARD:-4G}"
out="$ROOT/results/ab-$(date +%Y%m%d-%H%M%S).txt"
old_soft=$(cat $P/soft_limit) old_hard=$(cat $P/hard_limit)
trap 'echo "$old_soft" > $P/soft_limit; echo "$old_hard" > $P/hard_limit; rm -f "$BENCH_DIR/abw.dat"' EXIT

declare -A R
drop() { sync; echo 3 > /proc/sys/vm/drop_caches; }
fio_bw() {  # $1 = read|write
  if [[ "$1" == read ]]; then
    fio --name=r --filename="$BENCH_DIR/read.dat" --rw=read --bs=1M --size=8G --ioengine=psync --direct=0 \
        --output-format=terse --terse-version=3 | awk -F';' '{ printf "%.0f", $7 / 1024 }'
  else
    rm -f "$BENCH_DIR/abw.dat"
    fio --name=w --filename="$BENCH_DIR/abw.dat" --rw=write --bs=1M --size=4G --ioengine=psync --direct=0 \
        --end_fsync=1 --output-format=terse --terse-version=3 | awk -F';' '{ printf "%.0f", $48 / 1024 }'
  fi
}
for ((i = 1; i <= N; i++)); do
  for mode in off on; do
    if [[ $mode == off ]]; then echo 0 > $P/soft_limit; echo 0 > $P/hard_limit
    else echo "$ON_SOFT" > $P/soft_limit; echo "$ON_HARD" > $P/hard_limit; fi
    drop; r=$(fio_bw read)
    drop; w=$(fio_bw write)
    R[$mode,read]+="$r "; R[$mode,write]+="$w "
    echo "round $i $mode read=${r}MB/s write=${w}MB/s"
  done
done | tee -a "$out"
stats() { python3 -I -c 'import sys,statistics as s; v=[float(x) for x in sys.argv[1:]]; print(f"median {s.median(v):.0f}  min {min(v):.0f}  max {max(v):.0f}  (n={len(v)})")' "$@"; }
{
  echo "# kernel=$(uname -r) on=$ON_SOFT/$ON_HARD N=$N"
  for c in read write; do
    for mode in off on; do
      mapfile -t vals < <(awk -v m="$mode" -v c="$c" '$1 == "round" && $3 == m {
          for (i = 4; i <= NF; i++) if (index($i, c "=") == 1) { v = substr($i, length(c) + 2); sub(/MB\/s$/, "", v); print v } }' "$out")
      echo "$c $mode: $(stats "${vals[@]}")"
    done
  done
} | tee -a "$out"
echo "results: $out"
