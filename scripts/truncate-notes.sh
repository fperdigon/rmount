#!/usr/bin/env bash
# Usage: truncate-notes.sh <file> [max-bytes]
# Truncates <file> in place to at most max-bytes (default 100000; GitHub's release body limit is
# 125000 characters) at a line boundary, so the result stays valid UTF-8 and never cuts a line.
# Reads a file, not a pipe: `head -c` on a pipe exits early and the producer dies of SIGPIPE
# (status 141) under `set -o pipefail` (issue #91).
set -euo pipefail
file="${1:?usage: truncate-notes.sh <file> [max-bytes]}"
max="${2:-100000}"
tmp="$(mktemp "${file}.XXXXXX")"
LC_ALL=C awk -v max="$max" '
  { n += length($0) + 1; if (n > max) { cut = 1; next } if (!cut) print }
' "$file" > "$tmp"
mv "$tmp" "$file"
