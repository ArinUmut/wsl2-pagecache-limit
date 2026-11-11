#!/usr/bin/env bash
# Cost of the filemap_add_folio() hook on a RAM-backed filesystem, so disk
# latency cannot hide it: an ext4 image in /dev/shm, loop-mounted, read cold
# (drop_caches drops the ext4 page cache, the tmpfs backing stays in RAM).
#
#   tests/wsl-hookcost.sh            (restores the current limits at the end)
#
# Modes: off (0/0, static key off), on-under (hard=64G, never reached),
#        on-over (hard=512M: every read pays sync reclaim).
set -Eeuo pipefail
IFS=$'\n\t'

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
P=/sys/module/pagecache_limit/parameters
REPS="${REPS:-5}"
IMG=/dev/shm/pclimit-hookcost.img
MNT=/mnt/pclimit-hookcost
PCLTEST="$ROOT/out/pcltest"
out="$ROOT/results/hookcost-$(date +%Y%m%d-%H%M%S).txt"
mkdir -p "$ROOT/results" "$MNT"
gcc -static -O2 -Wall -o "$PCLTEST" "$ROOT/tests/qemu/pcltest.c"

old_soft=$(cat $P/soft_limit) old_hard=$(cat $P/hard_limit)
loopdev=""
cleanup() {
  echo "$old_soft" > $P/soft_limit; echo "$old_hard" > $P/hard_limit
  mountpoint -q "$MNT" && umount "$MNT"
  [[ -n "$loopdev" ]] && losetup -d "$loopdev" 2>/dev/null
  rm -f "$IMG"
}
trap cleanup EXIT

truncate -s 3G "$IMG"
mkfs.ext4 -q -F "$IMG"
loopdev=$(losetup --find --show "$IMG")
mount "$loopdev" "$MNT"
dd if=/dev/urandom of="$MNT/f.dat" bs=16M count=128 status=none
sync

median() { python3 -I -c 'import sys,statistics; print(f"{statistics.median(float(x) for x in sys.argv[1:]):.1f}")' "$@"; }
declare -A V
one() {  # name soft hard: one cold read, MB/s appended to V[name]
  echo "$2" > $P/soft_limit; echo "$3" > $P/hard_limit
  sync; echo 3 > /proc/sys/vm/drop_caches
  local r s b
  r=$("$PCLTEST" read "$MNT/f.dat")
  s=$(sed -n 's/.*secs=\([0-9.]*\).*/\1/p' <<<"$r")
  b=$(sed -n 's/.*bytes=\([0-9]*\).*/\1/p' <<<"$r")
  V[$1]+="$(python3 -I -c "print(round($b / 1e6 / $s))") "
}

{ echo "# kernel=$(uname -r) reps=$REPS file=2GiB on loop(ext4 in tmpfs), modes interleaved"; } > "$out"
for ((i = 0; i < REPS; i++)); do
  one off 0 0
  one on-under 0 64G
  one soft-over 512M 0
  one hard-over 0 512M
done
for m in off on-under soft-over hard-over; do
  IFS=' ' read -r -a vals <<<"${V[$m]}"
  echo "$m MBps $(median "${vals[@]}") runs: ${V[$m]}" | tee -a "$out"
done
echo "results: $out"
