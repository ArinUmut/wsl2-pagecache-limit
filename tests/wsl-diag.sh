#!/usr/bin/env bash
# Diagnose throughput with the limits on vs off: one fio case per mode, with
# deltas of the pagecache_limit stats, reclaim-related /proc/vmstat counters
# and memory/io PSI. Restores the previous limits.
#   tests/wsl-diag.sh <read|write> [soft hard]...
set -Eeuo pipefail
IFS=$'\n\t'
P=/sys/module/pagecache_limit/parameters
BENCH_DIR="${BENCH_DIR:-/root/pclimit-bench}"
case_="${1:?read|write}"; shift
old_soft=$(cat $P/soft_limit) old_hard=$(cat $P/hard_limit)
trap 'echo "$old_soft" > $P/soft_limit; echo "$old_hard" > $P/hard_limit; rm -f "$BENCH_DIR/diagw.dat"' EXIT
VM='pgscan_file|pgsteal_file|pgscan_anon|pgsteal_anon|allocstall_normal|allocstall_movable|nr_vmscan_immediate_reclaim|pgrotated|workingset_refault_file|workingset_activate_file|pgactivate|pgdeactivate|nr_vmscan_write|pgpgout|pgpgin'
snap() { { awk '{ print "pcl_" $1, $2 }' $P/stats; grep -E "^($VM) " /proc/vmstat;
           awk '/^some/ { split($5, a, "="); print "psi_mem_some_us", a[2] } /^full/ { split($5, a, "="); print "psi_mem_full_us", a[2] }' /proc/pressure/memory;
           awk '/^some/ { split($5, a, "="); print "psi_io_some_us", a[2] }' /proc/pressure/io; } | sort; }
run() {
  local soft="$1" hard="$2" a b
  echo "$soft" > $P/soft_limit; echo "$hard" > $P/hard_limit
  sync; echo 3 > /proc/sys/vm/drop_caches; sleep 1
  a=$(snap)
  if [[ "$case_" == read ]]; then
    fio --name=r --filename="$BENCH_DIR/read.dat" --rw=read --bs=1M --size=8G --ioengine=psync --direct=0 --output-format=terse --terse-version=3 |
      awk -F';' '{ printf "fio read %.0f MB/s usr %.1f%% sys %.1f%%\n", $7 / 1024, $88, $89 }'
  else
    rm -f "$BENCH_DIR/diagw.dat"
    fio --name=w --filename="$BENCH_DIR/diagw.dat" --rw=write --bs=1M --size=4G --ioengine=psync --direct=0 --end_fsync=1 --output-format=terse --terse-version=3 |
      awk -F';' '{ printf "fio write %.0f MB/s usr %.1f%% sys %.1f%%\n", $48 / 1024, $88, $89 }'
  fi
  b=$(snap)
  join <(echo "$a") <(echo "$b") | awk '$3 != $2 && $1 !~ /bytes$/ { printf "  %-32s %+d\n", $1, $3 - $2 }'
}
(($#)) || set -- 0 0 3G 4G
while (($#)); do echo "== $case_ soft=$1 hard=$2"; run "$1" "$2"; shift 2; done
