#!/usr/bin/env bash
# Fetch one or more microsoft/WSL2-Linux-Kernel tags into the local source
# cache (.cache/kernel by default).
#
#   scripts/fetch.sh <tag> [<tag> ...]
#
# The cache is a blobless, depth-1-per-tag partial clone: every requested tag
# brings its commit and trees, blobs are downloaded on demand by checkout and
# by 3-way merges. build.sh fetches both the patch base tag (patches/BASE_TAG)
# and the target tag, so `git rebase --onto` always has the merge-base blobs.
set -Eeuo pipefail
IFS=$'\n\t'

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
URL="${PCLIMIT_KERNEL_URL:-https://github.com/microsoft/WSL2-Linux-Kernel.git}"
SRC="${PCLIMIT_SRC:-$ROOT/.cache/kernel}"

(($#)) || { echo "usage: fetch.sh <tag> [<tag> ...]" >&2; exit 2; }
for tag in "$@"; do
  [[ "$tag" =~ ^linux-msft-wsl-[0-9]+(\.[0-9]+)+$ ]] || { echo "refusing unexpected tag name: $tag" >&2; exit 2; }
done

mkdir -p "$(dirname -- "$SRC")"
fstype="$(findmnt -T "$(dirname -- "$SRC")" -no FSTYPE | tr -d '[:space:]')"
[[ "$fstype" == ext4 ]] || { echo "kernel source must live on ext4 (got $fstype)" >&2; exit 1; }

if [[ ! -d "$SRC/.git" ]]; then
  first="$1"
  git clone --filter=blob:none --depth 1 --no-checkout --branch "$first" "$URL" "$SRC"
fi

for tag in "$@"; do
  if ! git -C "$SRC" rev-parse -q --verify "refs/tags/$tag^{commit}" >/dev/null; then
    git -C "$SRC" fetch --depth 1 --filter=blob:none origin "refs/tags/$tag:refs/tags/$tag"
  fi
  commit="$(git -C "$SRC" rev-parse "refs/tags/$tag^{commit}")"
  echo "tag=$tag commit=$commit"
done
