#!/usr/bin/env bash
# Points the Homebrew casks in fperdigon/homebrew-rmount at a freshly built release: rewrites
# `version` and `sha256` in Casks/rmount.rb and Casks/rmount-lite.rb from the DMGs in dist/.
# Usage: scripts/update-cask.sh <version>        (version without the leading "v")
# Needs HOMEBREW_TAP_TOKEN (a token that can push to the tap), or TAP_URL to push somewhere else.
set -euo pipefail
cd "$(dirname "$0")/.."

version="${1:?usage: update-cask.sh <version>}"
version="${version#v}"
dist="${DIST:-dist}"
tap_url="${TAP_URL:-}"
if [ -z "$tap_url" ]; then
    : "${HOMEBREW_TAP_TOKEN:?set HOMEBREW_TAP_TOKEN or TAP_URL}"
    tap_url="https://x-access-token:${HOMEBREW_TAP_TOKEN}@github.com/fperdigon/homebrew-rmount.git"
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
git clone --quiet --depth 1 "$tap_url" "$work/tap"

update() {
    local cask="$1" dmg="$dist/$2-$version.dmg"
    [ -f "$dmg" ] || { echo "error: $dmg not found" >&2; exit 1; }
    local sum; sum="$(shasum -a 256 "$dmg" | cut -d' ' -f1)"
    local file="$work/tap/Casks/$cask.rb"
    [ -f "$file" ] || { echo "error: $file not found in the tap" >&2; exit 1; }
    VERSION="$version" SUM="$sum" perl -pi -e 's/^(  version ")[^"]*(")/$1$ENV{VERSION}$2/; s/^(  sha256 ")[^"]*(")/$1$ENV{SUM}$2/' "$file"
    echo "==> $cask: $version $sum"
}

update rmount rmount
update rmount-lite rmount-lite

cd "$work/tap"
if git diff --quiet; then
    echo "casks already up to date"
    exit 0
fi
git -c user.name="github-actions[bot]" -c user.email="41898282+github-actions[bot]@users.noreply.github.com" \
    commit --quiet -am "Update RMount casks to ${version}"
git push --quiet origin HEAD
echo "pushed the cask update for ${version}"
