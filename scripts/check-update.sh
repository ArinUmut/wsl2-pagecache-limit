#!/usr/bin/env bash
# Is there a newer Microsoft WSL kernel than the one the patch is based on /
# the one running, and does it change anything the patch depends on?
#
#   scripts/check-update.sh            exit 0 = up to date, 10 = rebuild needed
#
# On a newer tag it fetches it and flags, as "RETEST REQUIRED", changes to:
#   - config-wsl symbols LRU_GEN*, MEMCG, MEMCG_V1, CGROUP_WRITEBACK, PSI
#   - the bodies of (__)filemap_add_folio, struct scan_control, cgroup_reclaim,
#     writeback_throttling_sane, sc_swappiness, try_to_free_mem_cgroup_pages,
#     get_scan_count, do_try_to_free_pages, shrink_node_memcgs, shrink_folio_list
# Then: scripts/build.sh --tag <new> && tests/qemu/run.sh && scripts/install.ps1.
set -Eeuo pipefail
IFS=$'\n\t'

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
SRC="${PCLIMIT_SRC:-$ROOT/.cache/kernel}"
URL="${PCLIMIT_KERNEL_URL:-https://github.com/microsoft/WSL2-Linux-Kernel.git}"
BASE_TAG="${PCLIMIT_BASE_TAG:-$(tr -d '[:space:]' < "$ROOT/patches/BASE_TAG")}"   # override only to test this script

latest="$(git ls-remote --tags --refs "$URL" 'linux-msft-wsl-*' | sed 's#.*refs/tags/##' |
  grep -E '^linux-msft-wsl-[0-9]+(\.[0-9]+)+$' | sort -V | tail -1)"
running="$(uname -r)"
bundled=""
if command -v wsl.exe >/dev/null 2>&1; then
  # wsl.exe prints UTF-16LE through interop and localises its labels, so pick
  # the value shaped like a WSL kernel version (a.b.c.d-N; the WSL version has no -N).
  bundled="$(wsl.exe --version 2>/dev/null | iconv -f UTF-16LE -t UTF-8 2>/dev/null | tr -d '\r' |
    sed -n 's/^[^:]*: *//p' | grep -m1 -E '^[0-9]+(\.[0-9]+){3}-[0-9]+$' || true)"
fi
echo "patch base:      $BASE_TAG"
echo "latest upstream: $latest"
echo "running kernel:  $running"
[[ -n "$bundled" ]] && echo "WSL bundled:     $bundled"

ver() { sed -E 's/^linux-msft-wsl-//; s/-.*$//' <<<"$1"; }
newer() { [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" == "$1" && "$1" != "$2" ]]; }

if ! newer "$(ver "$latest")" "$(ver "$BASE_TAG")"; then
  if [[ -n "$bundled" ]] && newer "$(ver "$bundled")" "$(ver "$BASE_TAG")"; then
    echo "WSL ships a newer kernel ($bundled) than the patch base but no newer tag is published yet."
  fi
  echo "up to date"
  exit 0
fi

echo "== newer tag $latest: fetching to check the patch's dependencies"
bash "$ROOT/scripts/fetch.sh" "$BASE_TAG" "$latest" >/dev/null
old="refs/tags/$BASE_TAG^{commit}" new="refs/tags/$latest^{commit}"
retest=0
cfg() { git -C "$SRC" show "$1:Microsoft/config-wsl" | grep -E '^(# )?CONFIG_(LRU_GEN[A-Z_]*|MEMCG|MEMCG_V1|CGROUP_WRITEBACK|PSI)[= ]' | sort; }
if ! diff <(cfg "$old") <(cfg "$new") >/dev/null; then
  echo "RETEST REQUIRED: config-wsl changed a relevant symbol:"; diff <(cfg "$old") <(cfg "$new") || true; retest=1
fi
# The regex goes through ENVIRON: awk -v would eat the backslashes.
# awk exits at the closing brace, so git may die of SIGPIPE: ignore the status;
# an empty result (missing file or function) is reported as RETEST below.
body() { { git -C "$SRC" show "$1:$2" 2>/dev/null | RE="$3" awk '$0 ~ ENVIRON["RE"] { on = 1 } on { print } on && /^}/ { exit }'; } || true; }
for spec in 'mm/filemap.c|^int filemap_add_folio[(]' \
            'mm/filemap.c|^noinline int __filemap_add_folio[(]' \
            'mm/vmscan.c|^struct scan_control [{]' \
            'mm/vmscan.c|^static bool cgroup_reclaim[(]' \
            'mm/vmscan.c|^static bool writeback_throttling_sane[(]' \
            'mm/vmscan.c|^static int sc_swappiness[(]' \
            'mm/vmscan.c|^unsigned long try_to_free_mem_cgroup_pages[(]' \
            'mm/vmscan.c|^static void get_scan_count[(]' \
            'mm/vmscan.c|^static unsigned long do_try_to_free_pages[(]' \
            'mm/vmscan.c|^static void shrink_node_memcgs[(]' \
            'mm/vmscan.c|^static unsigned int shrink_folio_list[(]'; do
  file="${spec%%|*}" re="${spec#*|}"
  a="$(body "$old" "$file" "$re")" b="$(body "$new" "$file" "$re")"
  if [[ -z "$a" || -z "$b" ]]; then
    echo "RETEST REQUIRED: could not find ${re#^} in $file (renamed or moved?)"; retest=1
  elif [[ "$a" != "$b" ]]; then
    echo "RETEST REQUIRED: ${re#^} in $file changed"; retest=1
  fi
done
((retest)) || echo "no relevant changes in config or the functions the patch relies on"
echo "rebuild needed: scripts/build.sh --tag $latest; tests/qemu/run.sh; scripts/install.ps1 -Tag $latest -Apply"
exit 10
