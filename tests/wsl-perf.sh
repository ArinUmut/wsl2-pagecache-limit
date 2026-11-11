#!/usr/bin/env bash
# Performance probe for the page cache limit work.
#
#   tests/wsl-perf.sh <label> [--quick]
#
# Runs every case REPS times (default 3) and records the median. Results go to
# results/perf-<label>-<timestamp>.txt (one "key value" per line) so that two
# runs can be compared with tests/perf-compare.py.
#
# Cases:
#   seqread    cold-cache buffered sequential read of an 8 GiB file (1 MiB blocks)
#   randread   cold-cache buffered 4 KiB random read, 4 jobs, 20 s
#   seqwrite   buffered sequential write of 4 GiB with a final fsync
#   syscall    perf bench syscall basic   (usecs/op)
#   sched      perf bench sched messaging (seconds)
set -Eeuo pipefail

label="${1:?usage: wsl-perf.sh <label> [--quick]}"
quick=0
[[ "${2:-}" == "--quick" ]] && quick=1

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
BENCH_DIR="${BENCH_DIR:-/root/pclimit-bench}"
REPS="${REPS:-3}"
READ_SIZE="${READ_SIZE:-8G}"
WRITE_SIZE="${WRITE_SIZE:-4G}"
RAND_RUNTIME="${RAND_RUNTIME:-20}"
if ((quick)); then REPS=1; READ_SIZE=2G; WRITE_SIZE=1G; RAND_RUNTIME=5; fi

PERF="${PERF:-$(command -v perf || true)}"
if [[ -z "$PERF" ]]; then
  for p in "$ROOT"/out/*/perf/bin/perf; do
    [[ -x "$p" ]] && PERF="$p"
  done
fi
[[ -x "$PERF" ]] || { echo "perf not found; set PERF=" >&2; exit 1; }
command -v fio >/dev/null || { echo "fio not installed" >&2; exit 1; }

mkdir -p "$BENCH_DIR" "$ROOT/results"
out="$ROOT/results/perf-$label-$(date +%Y%m%d-%H%M%S).txt"
datafile="$BENCH_DIR/read.dat"

median() { python3 -I -c 'import sys,statistics; v=[float(x) for x in sys.argv[1:]]; print(f"{statistics.median(v):.3f}")' "$@"; }
fio_field() {
  # $1 = json file, $2 = read|write, $3 = bw|iops|sys
  python3 -I - "$1" "$2" "$3" <<'PY'
import json, sys
j = json.load(open(sys.argv[1]))
rw, f = sys.argv[2], sys.argv[3]
jobs = j["jobs"]
if f == "bw":      print(sum(x[rw]["bw_bytes"] for x in jobs) / 1e6)       # MB/s
elif f == "iops":  print(sum(x[rw]["iops"] for x in jobs))
elif f == "sys":   print(sum(x["sys_cpu"] for x in jobs) / len(jobs))
elif f == "p99":   print(max(x[rw]["clat_ns"]["percentile"]["99.000000"] for x in jobs) / 1000.0)  # usec
PY
}
drop() { sync; echo 3 > /proc/sys/vm/drop_caches; }
rec() { echo "$1 $2" | tee -a "$out"; }

{
  echo "# label=$label"
  echo "# kernel=$(uname -r)"
  echo "# date=$(date -Is)"
  echo "# reps=$REPS read_size=$READ_SIZE write_size=$WRITE_SIZE"
  for p in soft_limit hard_limit; do
    f=/sys/module/pagecache_limit/parameters/$p
    [[ -r $f ]] && echo "# pagecache_limit.$p=$(cat $f)"
  done
  echo "# vm.dirty_bytes=$(sysctl -n vm.dirty_bytes) vm.dirty_background_bytes=$(sysctl -n vm.dirty_background_bytes) vm.dirty_ratio=$(sysctl -n vm.dirty_ratio)"
} > "$out"

# Data file for the read tests (created once, reused).
want=$(numfmt --from=iec "$READ_SIZE")
have=$(stat -c %s "$datafile" 2>/dev/null || echo 0)
if (( have < want )); then
  fio --name=prep --filename="$datafile" --rw=write --bs=1M --size="$READ_SIZE" \
      --ioengine=psync --end_fsync=1 --output=/dev/null
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"; rm -f "$BENCH_DIR/write.dat"' EXIT

bw=(); sys=()
for ((i = 0; i < REPS; i++)); do
  drop
  fio --name=seqread --filename="$datafile" --rw=read --bs=1M --size="$READ_SIZE" \
      --ioengine=psync --direct=0 --output-format=json --output="$tmp/sr.json"
  bw+=("$(fio_field "$tmp/sr.json" read bw)"); sys+=("$(fio_field "$tmp/sr.json" read sys)")
done
rec seqread_MBps "$(median "${bw[@]}")"
rec seqread_sys_cpu_pct "$(median "${sys[@]}")"

iops=(); p99=()
for ((i = 0; i < REPS; i++)); do
  drop
  fio --name=randread --filename="$datafile" --rw=randread --bs=4k --size="$READ_SIZE" \
      --numjobs=4 --ioengine=psync --direct=0 --time_based --runtime="$RAND_RUNTIME" \
      --group_reporting=0 --output-format=json --output="$tmp/rr.json"
  iops+=("$(fio_field "$tmp/rr.json" read iops)"); p99+=("$(fio_field "$tmp/rr.json" read p99)")
done
rec randread_iops "$(median "${iops[@]}")"
rec randread_p99_us "$(median "${p99[@]}")"

bw=()
for ((i = 0; i < REPS; i++)); do
  rm -f "$BENCH_DIR/write.dat"; drop
  fio --name=seqwrite --filename="$BENCH_DIR/write.dat" --rw=write --bs=1M --size="$WRITE_SIZE" \
      --ioengine=psync --direct=0 --end_fsync=1 --output-format=json --output="$tmp/sw.json"
  bw+=("$(fio_field "$tmp/sw.json" write bw)")
done
rec seqwrite_MBps "$(median "${bw[@]}")"

v=()
for ((i = 0; i < REPS; i++)); do
  v+=("$("$PERF" bench syscall basic 2>/dev/null | awk '/usecs\/op/ {print $1}')")
done
rec syscall_basic_usecs_per_op "$(median "${v[@]}")"

v=()
for ((i = 0; i < REPS; i++)); do
  v+=("$("$PERF" bench sched messaging -g 20 -l 1000 2>/dev/null | awk '/Total time/ {print $3}')")
done
rec sched_messaging_sec "$(median "${v[@]}")"

echo "results: $out"
