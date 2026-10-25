#!/usr/bin/env bash
# Who wrote the code in this repository, by lines.
#
#   scripts/authorship.sh          # only humans: Claude's commits go to whoever was working then
#   scripts/authorship.sh --raw    # every commit author as recorded
#
# A commit authored by Claude Code is assigned to the human who was working on the project when it
# was made: before MAINTAINER_SINCE that is the original author (who also used Claude, which shows as
# a Co-authored-by trailer on his commits), from then on the RMount maintainer. Claude stays credited
# as co-author in the commit messages; history is not rewritten.
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

# The fork's work starts on 2026-10-14; the original author's last commit is 2026-05-07.
MAINTAINER_SINCE=1791936000   # 2026-10-14 00:00 UTC

AYON="Ayon Pal (original macsh author)"
MAINTAINER="Francisco Perdigon Romero (RMount maintainer)"

# name_of <author e-mail> <author time, unix>
name_of() {
    case "$1" in
        ayoooonpal@gmail.com) echo "$AYON" ;;
        fperdigon88@gmail.com) echo "$MAINTAINER" ;;
        noreply@anthropic.com)
            if [ "$raw" = 1 ]; then echo "Claude"
            elif [ "$2" -lt "$MAINTAINER_SINCE" ]; then echo "$AYON"
            else echo "$MAINTAINER"; fi ;;
        *) echo "$1" ;;
    esac
}

ignore=()
[ -f .git-blame-ignore-revs ] && ignore=(--ignore-revs-file .git-blame-ignore-revs)

echo "Surviving lines at HEAD ($(git rev-parse --short HEAD)):"
git grep -I --name-only -e '' HEAD -- . ':!LICENSE' ':!docs/architecture/architecture.svg' \
  | sed 's/^HEAD://' \
  | while read -r f; do
        git blame -w -M -C "${ignore[@]}" --line-porcelain HEAD -- "$f" 2>/dev/null \
          | awk '/^author-mail / {gsub(/[<>]/, "", $2); mail=$2} /^author-time / {print mail, $2}'
    done \
  | sort | uniq -c | sort -rn \
  | while read -r n mail time; do printf '%s\t%s\n' "$n" "$(name_of "$mail" "$time")"; done \
  | awk -F'\t' '{t[$2]+=$1; s+=$1} END {for (k in t) printf "  %7d  %5.1f%%  %s\n", t[k], 100*t[k]/s, k}' | sort -rn

echo
echo "Lines added / removed over the whole history:"
git log --no-merges --no-use-mailmap --format='@%ae %at' --numstat -- . ':!LICENSE' ':!docs/architecture/architecture.svg' \
  | awk '/^@/ {mail=substr($1,2); time=$2; next} NF==3 && $1 != "-" {k=mail" "time; a[k]+=$1; d[k]+=$2}
         END {for (k in a) printf "%s %d %d\n", k, a[k], d[k]}' \
  | while read -r mail time a d; do printf '%s\t%s\t%s\n' "$(name_of "$mail" "$time")" "$a" "$d"; done \
  | awk -F'\t' '{A[$1]+=$2; D[$1]+=$3} END {for (k in A) printf "  +%-7d -%-7d %s\n", A[k], D[k], k}' | sort -t+ -k2 -rn
