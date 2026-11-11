#!/usr/bin/env bash
# Export the commits on top of patches/BASE_TAG in the kernel source into
# patches/*.patch (replacing the old series).
#
#   scripts/export-patch.sh [<rev>]        rev defaults to HEAD
set -Eeuo pipefail
IFS=$'\n\t'

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
SRC="${PCLIMIT_SRC:-$ROOT/.cache/kernel}"
BASE_TAG="$(tr -d '[:space:]' < "$ROOT/patches/BASE_TAG")"
rev="${1:-HEAD}"

base="$(git -C "$SRC" rev-parse "refs/tags/$BASE_TAG^{commit}")"
git -C "$SRC" merge-base --is-ancestor "$base" "$rev" || { echo "$rev is not based on $BASE_TAG" >&2; exit 1; }
n="$(git -C "$SRC" rev-list --count "$base..$rev")"
((n > 0)) || { echo "no commits on top of $BASE_TAG" >&2; exit 1; }

rm -f "$ROOT"/patches/*.patch
git -C "$SRC" format-patch -q --no-signature --zero-commit -o "$ROOT/patches" "$base..$rev"
ls -1 "$ROOT"/patches/*.patch
