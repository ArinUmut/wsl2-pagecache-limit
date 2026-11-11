#!/usr/bin/env bash
# Boot the debug kernel (KASAN, lockdep, hung-task, DEBUG_VM) in QEMU/KVM and
# run tests/qemu/init.sh inside it.
#
#   tests/qemu/run.sh [--stress SECONDS] [--kernel BZIMAGE]
#
# Exit status 0 only if the guest prints "RESULT fails=0".
set -Eeuo pipefail
IFS=$'\n\t'

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TAG="$(tr -d '[:space:]' < "$ROOT/patches/BASE_TAG")"
KERNEL="$ROOT/out/$TAG-debug/build/arch/x86/boot/bzImage"
STRESS=600
while (($#)); do
  case "$1" in
    --stress) STRESS="${2:?}"; shift 2 ;;
    --kernel) KERNEL="${2:?}"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
[[ -f "$KERNEL" ]] || { echo "kernel not found: $KERNEL (build with scripts/build.sh --variant debug)" >&2; exit 1; }
[[ -r /dev/kvm ]] || { echo "/dev/kvm not available" >&2; exit 1; }
BUSYBOX="$(command -v busybox)"
file -L "$BUSYBOX" | grep -q 'statically linked' || { echo "need a static busybox (apt install busybox-static)" >&2; exit 1; }

W="$ROOT/out/qemu"
mkdir -p "$W"

gcc -static -O2 -Wall -Wextra -o "$W/pcltest" "$ROOT/tests/qemu/pcltest.c"

rm -rf "$W/initramfs"
mkdir -p "$W/initramfs/bin"
cp "$BUSYBOX" "$W/initramfs/bin/busybox"
cp "$W/pcltest" "$W/initramfs/bin/pcltest"
install -m 0755 "$ROOT/tests/qemu/init.sh" "$W/initramfs/init"
(cd "$W/initramfs" && find . | cpio -o -H newc --quiet | gzip -1 > "$W/initramfs.cpio.gz")

if [[ ! -f "$W/data.img" ]]; then
  echo "== creating data disk"
  rm -rf "$W/datadir" "$W/loopdir"
  mkdir -p "$W/datadir" "$W/loopdir"
  head -c 2G /dev/urandom > "$W/datadir/big1.dat"
  head -c 1G /dev/urandom > "$W/datadir/big2.dat"
  head -c 768M /dev/urandom > "$W/datadir/lock.dat"
  head -c 512M /dev/urandom > "$W/loopdir/f.dat"
  mke2fs -q -F -t ext4 -d "$W/loopdir" "$W/datadir/loop.img" 700M
  mke2fs -q -F -t ext4 -d "$W/datadir" "$W/data.img" 8G
  rm -rf "$W/datadir" "$W/loopdir"
fi

log="$W/console-$(date +%Y%m%d-%H%M%S).log"
echo "== booting $KERNEL (stress ${STRESS}s), console -> $log"
timeout $((STRESS + 3000)) qemu-system-x86_64 \
  -enable-kvm -cpu host -smp 4 -m 4096 \
  -nographic -no-reboot \
  -kernel "$KERNEL" -initrd "$W/initramfs.cpio.gz" \
  -drive "file=$W/data.img,if=virtio,format=raw,cache=none" \
  -append "console=ttyS0 panic=-1 loglevel=4 pagecache_limit.hard_limit=12Q pagecache_limit.stats=1 pagecache_limit.soft_limit=384M pagecache_limit.hard_limit=512M pcltest.stress=$STRESS" \
  < /dev/null > "$log" 2>&1 || true

grep -E '^(PASS|FAIL|info|RESULT|==)' "$log" || true
grep -q '^RESULT fails=0' "$log"
