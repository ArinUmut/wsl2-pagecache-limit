#!/usr/bin/env bash
# Build the WSL2 kernel with the page cache limit patch.
#
#   scripts/build.sh [--tag TAG] [--variant release|debug] [--jobs N]
#
# TAG defaults to patches/BASE_TAG. The patch series in patches/ is applied
# with `git am` onto BASE_TAG and, when TAG differs, moved with
# `git rebase --onto TAG BASE_TAG`; a conflict stops the build (port the patch,
# re-export it with scripts/export-patch.sh, update BASE_TAG).
#
# Outputs (out/<TAG>-<variant>/):
#   build/                 O= build tree (.config, vmlinux, System.map, bzImage)
#   modules/ headers/ perf/   staged trees (release only)
#   modules.vhdx           Microsoft/scripts/gen_artifacts_vhdx.sh image (release only)
#   diffconfig.txt BUILDINFO SHA256SUMS
#
# The release variant must pass the config gate: every fragment line is
# honoured, and every difference from Microsoft/config-wsl is listed in
# config/allowed-diff.txt (so a silently dropped option fails the build).
set -Eeuo pipefail
IFS=$'\n\t'

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
SRC="${PCLIMIT_SRC:-$ROOT/.cache/kernel}"
BASE_TAG="$(tr -d '[:space:]' < "$ROOT/patches/BASE_TAG")"
TAG="$BASE_TAG"
VARIANT=release
JOBS="$(nproc)"
while (($#)); do
  case "$1" in
    --tag) TAG="${2:?--tag needs a value}"; shift 2 ;;
    --variant) VARIANT="${2:?--variant needs a value}"; shift 2 ;;
    --jobs) JOBS="${2:?--jobs needs a value}"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
[[ "$VARIANT" == release || "$VARIANT" == debug ]] || { echo "variant must be release or debug" >&2; exit 2; }

die() { echo "build.sh: $*" >&2; exit 1; }
for tool in git make gcc flex bison pahole qemu-img mke2fs sha256sum bc; do
  command -v "$tool" >/dev/null 2>&1 || die "missing build tool: $tool"
done
[[ -e "$(gcc -print-file-name=plugin)/include/plugin-version.h" ]] ||
  die "GCC plugin headers missing (apt install gcc-$(gcc -dumpversion | cut -d. -f1)-plugin-dev); RANDSTRUCT/LATENT_ENTROPY need them"
compgen -G "$ROOT/patches/*.patch" >/dev/null || die "no patches in $ROOT/patches"

OUT="$ROOT/out/$TAG-$VARIANT"
LOCALVER_SUFFIX="-pclimit"
[[ "$VARIANT" == debug ]] && LOCALVER_SUFFIX="-pclimit-debug"
# LOCALVERSION= (set but empty) stops setlocalversion from appending "+".
MAKE=(make -C "$SRC" O="$OUT/build" LOCALVERSION=)

echo "== fetch"
bash "$ROOT/scripts/fetch.sh" "$BASE_TAG" "$TAG"

echo "== source: $BASE_TAG + patches -> $TAG"
[[ -z "$(git -C "$SRC" status --porcelain --untracked-files=no)" ]] ||
  die "kernel source $SRC has local changes; commit them or reset before building"
GIT_ID=(-c user.name=wsl2-pagecache-limit -c user.email=wsl2-pagecache-limit@localhost -c advice.detachedHead=false)
git -C "$SRC" "${GIT_ID[@]}" checkout -q -B pclimit/base "refs/tags/$BASE_TAG^{commit}"
git -C "$SRC" "${GIT_ID[@]}" am -q --3way "$ROOT"/patches/*.patch ||
  { git -C "$SRC" am --abort || true; die "patches do not apply to $BASE_TAG"; }
git -C "$SRC" "${GIT_ID[@]}" checkout -q -B "pclimit/$TAG" pclimit/base
if [[ "$TAG" != "$BASE_TAG" ]]; then
  if ! git -C "$SRC" "${GIT_ID[@]}" rebase -q --onto "refs/tags/$TAG^{commit}" "refs/tags/$BASE_TAG^{commit}" "pclimit/$TAG"; then
    git -C "$SRC" rebase --abort || true
    die "patch does not rebase cleanly onto $TAG; port it by hand"
  fi
fi
SOURCE_COMMIT="$(git -C "$SRC" rev-parse HEAD)"
TAG_COMMIT="$(git -C "$SRC" rev-parse "refs/tags/$TAG^{commit}")"
[[ "$(git -C "$SRC" rev-list --count "$TAG_COMMIT..HEAD")" == "$(ls "$ROOT"/patches/*.patch | wc -l)" ]] ||
  die "unexpected commit count on top of $TAG"

echo "== config"
mkdir -p "$OUT/build"
sed "s/^CONFIG_LOCALVERSION=.*/CONFIG_LOCALVERSION=\"-microsoft-standard-WSL2$LOCALVER_SUFFIX\"/" \
  "$SRC/Microsoft/config-wsl" > "$OUT/build/.config"
frags=("$ROOT/config/pclimit.fragment")
[[ "$VARIANT" == debug ]] && frags+=("$ROOT/config/debug.fragment")
(cd "$SRC" && bash scripts/kconfig/merge_config.sh -m -O "$OUT/build" "$OUT/build/.config" "${frags[@]}") >/dev/null
"${MAKE[@]}" -s olddefconfig

# Every fragment line must survive olddefconfig (a missing dependency drops it silently).
for frag in "${frags[@]}"; do
  while IFS= read -r line; do
    case "$line" in
      CONFIG_*=*) grep -qxF -- "$line" "$OUT/build/.config" || die "fragment line not honoured: $line" ;;
      "# CONFIG_"*" is not set")
        sym="${line#\# }"; sym="${sym%% *}"
        ! grep -q "^$sym=" "$OUT/build/.config" || die "fragment line not honoured: $line" ;;
    esac
  done < "$frag"
done
python3 -I "$SRC/scripts/diffconfig" "$SRC/Microsoft/config-wsl" "$OUT/build/.config" > "$OUT/diffconfig.txt"
if [[ "$VARIANT" == release ]]; then
  bad=0
  while IFS= read -r d; do
    sym="$(sed -E 's/^[-+ ]?([A-Za-z0-9_]+).*/\1/' <<<"$d")"
    grep -qxF -- "$sym" <(grep -v '^#' "$ROOT/config/allowed-diff.txt" | sed '/^$/d') || { echo "unexpected config difference: $d" >&2; bad=1; }
  done < "$OUT/diffconfig.txt"
  ((bad == 0)) || die "config gate failed (see $OUT/diffconfig.txt; extend config/allowed-diff.txt only after review)"
fi
echo "config gate: ok ($(wc -l < "$OUT/diffconfig.txt") reviewed differences)"

echo "== build ($JOBS jobs)"
if [[ "$VARIANT" == release ]]; then
  "${MAKE[@]}" -j"$JOBS" bzImage modules
else
  "${MAKE[@]}" -j"$JOBS" bzImage    # QEMU tests boot without modules
fi
RELEASE="$("${MAKE[@]}" -s kernelrelease)"
grep -q ' __pagecache_limit_charge$' "$OUT/build/System.map" || die "__pagecache_limit_charge missing from System.map"

if [[ "$VARIANT" == release ]]; then
  echo "== stage modules/headers/perf"
  rm -rf "$OUT/modules" "$OUT/headers" "$OUT/perf"
  mkdir -p "$OUT/modules" "$OUT/headers" "$OUT/perf" "$OUT/build/tools/perf"
  "${MAKE[@]}" -s INSTALL_MOD_PATH="$OUT/modules" modules_install
  "${MAKE[@]}" -s INSTALL_HDR_PATH="$OUT/headers" headers_install
  make -s -C "$SRC/tools/perf" O="$OUT/build/tools/perf" NO_JEVENTS=1 NO_JVMTI=1 NO_LIBTRACEEVENT=1 \
    install DESTDIR="$OUT/perf" prefix=/ >/dev/null
  [[ -d "$OUT/modules/lib/modules/$RELEASE" ]] || die "modules tree missing for $RELEASE"
  rm -f "$OUT/modules.vhdx"
  "$SRC/Microsoft/scripts/gen_artifacts_vhdx.sh" "$OUT/modules" "$OUT/headers" "$OUT/perf" "$RELEASE" "$OUT/modules.vhdx"
  qemu-img check "$OUT/modules.vhdx" >/dev/null
fi

{
  echo "tag=$TAG"
  echo "tag_commit=$TAG_COMMIT"
  echo "base_tag=$BASE_TAG"
  echo "source_commit=$SOURCE_COMMIT"
  echo "variant=$VARIANT"
  echo "kernel_release=$RELEASE"
  echo "built=$(date -Is)"
  echo "gcc=$(gcc --version | head -1)"
} > "$OUT/BUILDINFO"
sums=(build/arch/x86/boot/bzImage build/.config)
[[ -f "$OUT/modules.vhdx" ]] && sums+=(modules.vhdx)
(cd "$OUT" && sha256sum "${sums[@]}" > SHA256SUMS)
cat "$OUT/BUILDINFO"
cat "$OUT/SHA256SUMS"
