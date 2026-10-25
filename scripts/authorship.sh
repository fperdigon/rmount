#!/usr/bin/env bash
# Who wrote the code in this repository, by lines.
#
#   scripts/authorship.sh          # Claude's commits counted as the maintainer's (the default)
#   scripts/authorship.sh --raw    # every commit author as recorded
#
# Two views:
#   * Surviving lines: `git blame` of the text files at HEAD. Whitespace changes, moved lines and the
#     commits listed in .git-blame-ignore-revs (the mechanical macsh -> RMount rename) do not take a
#     line away from whoever wrote it.
#   * Lines added and removed over the whole history (merge commits excluded).
# Excluded: binary files, LICENSE, and generated files (docs/architecture/architecture.svg).
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

raw=0; [ "${1:-}" = "--raw" ] && raw=1

# author e-mail -> display name
name_of() {
    case "$1" in
        ayoooonpal@gmail.com) echo "Ayon Pal (original macsh author)" ;;
        fperdigon88@gmail.com) echo "Francisco Perdigon Romero (RMount maintainer)" ;;
        noreply@anthropic.com) if [ "$raw" = 1 ]; then echo "Claude"; else echo "Francisco Perdigon Romero (RMount maintainer)"; fi ;;
        *) echo "$1" ;;
    esac
}

ignore=()
[ -f .git-blame-ignore-revs ] && ignore=(--ignore-revs-file .git-blame-ignore-revs)

echo "Surviving lines at HEAD ($(git rev-parse --short HEAD)):"
git grep -I --name-only -e '' HEAD -- . ':!LICENSE' ':!docs/architecture/architecture.svg' \
  | sed 's/^HEAD://' \
  | while read -r f; do
        git blame -w -M -C "${ignore[@]}" --line-porcelain HEAD -- "$f" 2>/dev/null | sed -n 's/^author-mail <\(.*\)>$/\1/p'
    done \
  | sort | uniq -c | sort -rn \
  | while read -r n mail; do printf '%s\t%s\n' "$n" "$(name_of "$mail")"; done \
  | awk -F'\t' '{t[$2]+=$1; s+=$1} END {for (k in t) printf "  %7d  %5.1f%%  %s\n", t[k], 100*t[k]/s, k}' | sort -rn

echo
echo "Lines added / removed over the whole history:"
git log --no-merges --format='@%ae' --numstat -- . ':!LICENSE' ':!docs/architecture/architecture.svg' \
  | awk '/^@/ {mail=substr($0,2); next} NF==3 && $1 != "-" {a[mail]+=$1; d[mail]+=$2}
         END {for (m in a) printf "%s\t%d\t%d\n", m, a[m], d[m]}' \
  | while IFS=$'\t' read -r mail a d; do printf '%s\t%s\t%s\n' "$(name_of "$mail")" "$a" "$d"; done \
  | awk -F'\t' '{A[$1]+=$2; D[$1]+=$3} END {for (k in A) printf "  +%-7d -%-7d %s\n", A[k], D[k], k}' | sort -t+ -k2 -rn
