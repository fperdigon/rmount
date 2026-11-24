#!/usr/bin/env bash
# Downloads the pinned arm64 (Apple Silicon) rclone macOS binary into
# App/rmount/Resources/rclone. Run from the repo root before opening the
# Xcode project (and in CI before xcodebuild archive).
#
# rmount ships Apple Silicon only — no Intel builds.
#
# The version and the SHA-256 of its zip are pinned below, so a build always
# bundles the same, verified binary and a compromised download host cannot
# swap it. The build fails if the download does not match.
#
# To bump rclone:
#   1. Pick the new version at https://rclone.org/downloads/ (vX.Y.Z).
#   2. Read its zip hash from https://downloads.rclone.org/vX.Y.Z/SHA256SUMS
#      (the rclone-vX.Y.Z-osx-arm64.zip line). That file is GPG-clearsigned by
#      rclone; check it with `gpg --verify` against the key published at
#      https://rclone.org/downloads/ when you bump. The build itself does not
#      run gpg (not installed on the macOS runners); the committed hash is the
#      trust anchor and changes only through code review.
#   3. Update RCLONE_VERSION and RCLONE_SHA256 below, build, and run the tests.
#
# `fetch-rclone.sh --verify <file> <sha256>` only checks a file (used by tests).
set -euo pipefail

RCLONE_VERSION="v1.76.0"
RCLONE_SHA256="e72dc90b70f4947a7b72b61bde4a4fbba5777b2874fb448951ffdde67ebd0ab7"

# Returns non-zero unless the SHA-256 of $1 equals $2.
verify_sha256() {
  local file="$1" expected="$2" actual
  actual="$(shasum -a 256 "$file" | awk '{print $1}')"
  if [ "$actual" != "$expected" ]; then
    echo "error: SHA-256 mismatch for $file" >&2
    echo "  expected: $expected" >&2
    echo "  actual:   $actual" >&2
    return 1
  fi
}

if [ "${1:-}" = "--verify" ]; then
  [ $# -eq 3 ] || { echo "usage: $0 --verify <file> <sha256>" >&2; exit 2; }
  verify_sha256 "$2" "$3"
  exit $?
fi

cd "$(dirname "$0")/.."

DEST_DIR="App/rmount/Resources"
DEST="$DEST_DIR/rclone"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$DEST_DIR"

ZIP="rclone-$RCLONE_VERSION-osx-arm64.zip"
echo "Fetching rclone $RCLONE_VERSION for arm64..."
curl -fsSL -o "$TMP/arm64.zip" "https://downloads.rclone.org/$RCLONE_VERSION/$ZIP"
verify_sha256 "$TMP/arm64.zip" "$RCLONE_SHA256"
unzip -j -q "$TMP/arm64.zip" '*/rclone' -d "$TMP/arm64"

cp "$TMP/arm64/rclone" "$DEST"
chmod +x "$DEST"

echo "Done: $DEST"
file "$DEST" 2>/dev/null || true
