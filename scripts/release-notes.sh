#!/bin/zsh
# Print the user-facing notes for a version from ReleaseNotes.md, for the
# "What changed" part of `gh release create`. Fails when there is no entry.
#   scripts/release-notes.sh            # MARKETING_VERSION from project.yml
#   scripts/release-notes.sh 3.14.0
set -e
cd "$(dirname "$0")/.."
V="${1:-$(grep -m1 'MARKETING_VERSION:' project.yml | grep -oE '[0-9]+(\.[0-9]+)+')}"
OUT="$(awk -v v="$V" '/^## /{ if (s) exit; s = ($2 == v); next } s && NF' Transcriberr/Resources/ReleaseNotes.md)"
[ -n "$OUT" ] || { echo "no release notes for $V in Transcriberr/Resources/ReleaseNotes.md" >&2; exit 1; }
print -r -- "$OUT"
