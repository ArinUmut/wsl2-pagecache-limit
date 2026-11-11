#!/usr/bin/env bash
# Show or change the page cache limits and the dirty-page bounds at runtime
# (inside WSL, as root). Windows-side persistence: scripts/set-limits.ps1.
#
#   pclimit.sh show
#   pclimit.sh set [--soft S] [--hard H] [--dirty D] [--dirty-bg B] [--persist]
#
# Sizes accept K/M/G suffixes (e.g. 3G, 512M); 0 turns a limit off.
# --persist rewrites /etc/sysctl.d/90-pclimit-dirty.conf with the dirty values.
set -Eeuo pipefail
IFS=$'\n\t'

P=/sys/module/pagecache_limit/parameters
CONF=/etc/sysctl.d/90-pclimit-dirty.conf
[[ -d "$P" ]] || { echo "this kernel has no page cache limit ($(uname -r))" >&2; exit 1; }

show() {
  printf 'soft_limit %s\nhard_limit %s\n' "$(numfmt --to=iec "$(cat $P/soft_limit)")" "$(numfmt --to=iec "$(cat $P/hard_limit)")"
  printf 'vm.dirty_bytes %s\nvm.dirty_background_bytes %s\n' \
    "$(numfmt --to=iec "$(sysctl -n vm.dirty_bytes)")" "$(numfmt --to=iec "$(sysctl -n vm.dirty_background_bytes)")"
  cat $P/stats
}

case "${1:-show}" in
  show) show ;;
  set)
    shift
    soft="" hard="" dirty="" dirtybg="" persist=0
    while (($#)); do
      case "$1" in
        --soft) soft="$2"; shift 2 ;;
        --hard) hard="$2"; shift 2 ;;
        --dirty) dirty="$(numfmt --from=iec "$2")"; shift 2 ;;
        --dirty-bg) dirtybg="$(numfmt --from=iec "$2")"; shift 2 ;;
        --persist) persist=1; shift ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
      esac
    done
    [[ -n "$soft" ]] && echo "$soft" > $P/soft_limit
    [[ -n "$hard" ]] && echo "$hard" > $P/hard_limit
    [[ -n "$dirty" ]] && sysctl -q -w vm.dirty_bytes="$dirty"
    [[ -n "$dirtybg" ]] && sysctl -q -w vm.dirty_background_bytes="$dirtybg"
    if ((persist)); then
      tmp="$(mktemp)"
      {
        echo "# Written by wsl2-pagecache-limit scripts/pclimit.sh on $(date -Is)."
        echo "# The page cache hard limit applies to clean cache; these bound dirty data on top."
        echo "vm.dirty_bytes = $(sysctl -n vm.dirty_bytes)"
        echo "vm.dirty_background_bytes = $(sysctl -n vm.dirty_background_bytes)"
      } > "$tmp"
      install -m 0644 "$tmp" "$CONF"; rm -f "$tmp"
    fi
    show ;;
  *) echo "usage: pclimit.sh show | set [--soft S] [--hard H] [--dirty D] [--dirty-bg B] [--persist]" >&2; exit 2 ;;
esac
