#!/usr/bin/env bash
# Smoke gates after booting a wsl2-pagecache-limit kernel (run by scripts/install.ps1).
#
#   tests/validate.sh --release R --soft S --hard H
#
# Blocking gates fail the install (and trigger the automatic rollback).
# Informational gates are only reported. Machine-specific extra gates can live
# in tests/validate.local.sh (git-ignored), which is sourced if present and may
# call: gate blocking|info <name> <command...>.
set -Euo pipefail
IFS=$'\n\t'

release="" soft="" hard=""
while (($#)); do
  case "$1" in
    --release) release="$2"; shift 2 ;;
    --soft) soft="$2"; shift 2 ;;
    --hard) hard="$2"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
[[ -n "$release" && -n "$soft" && -n "$hard" ]] || { echo "usage: validate.sh --release R --soft S --hard H" >&2; exit 2; }

P=/sys/module/pagecache_limit/parameters
fail=0
gate() {  # gate <blocking|info> <name> <command...>
  local kind="$1" name="$2"; shift 2
  if "$@" >/dev/null 2>&1; then
    echo "PASS $name"
  elif [[ "$kind" == blocking ]]; then
    echo "FAIL $name"; fail=1
  else
    echo "INFO-FAIL $name (not blocking)"
  fi
}
bytes() { numfmt --from=iec "$1"; }
sysconf() { awk -F= -v k="$1" '{ gsub(/[ \t]/, "", $1); gsub(/[ \t]/, "", $2) } $1 == k { print $2 }' /etc/sysctl.d/90-pclimit-dirty.conf; }

echo "release=$(uname -r)"
gate blocking "kernel release $release" test "$(uname -r)" = "$release"
gate blocking "systemd is PID 1" test "$(ps -p 1 -o comm= | tr -d '[:space:]')" = systemd
gate blocking "/mnt/c readable" test -d /mnt/c/Users
gate blocking "DNS" getent hosts github.com
gate blocking "GPU visible (nvidia-smi)" nvidia-smi -L
gate blocking "/dev/kvm present" test -c /dev/kvm
gate blocking "BTF present" test -r /sys/kernel/btf/vmlinux
gate blocking "soft_limit = $soft" test "$(cat $P/soft_limit)" = "$(bytes "$soft")"
gate blocking "hard_limit = $hard" test "$(cat $P/hard_limit)" = "$(bytes "$hard")"
# Kernel threads live outside the distro's PID namespace (pgrep cannot see
# kpclimitd in WSL), so check the init message and the absence of its failure.
gate blocking "pagecache_limit initialised, kpclimitd started" \
  sh -c 'dmesg | grep -q "pagecache_limit: soft_limit=" && ! dmesg | grep -q "kpclimitd not started"'
gate blocking "vm.dirty_bytes from sysctl.d" test "$(sysctl -n vm.dirty_bytes)" = "$(sysconf vm.dirty_bytes)"
gate blocking "vm.dirty_background_bytes from sysctl.d" test "$(sysctl -n vm.dirty_background_bytes)" = "$(sysconf vm.dirty_background_bytes)"

local_gates="$(dirname -- "${BASH_SOURCE[0]}")/validate.local.sh"
# shellcheck source=/dev/null
[[ -f "$local_gates" ]] && . "$local_gates"

if ((fail)); then echo "validate: FAILED"; exit 1; fi
echo "validate: ok"
