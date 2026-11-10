#!/bin/zsh
# What the installed app logged while it was used normally: the warnings and
# errors in ~/Library/Logs/Transcriberr/transcriberr.log, grouped, plus crash
# reports. Read before every release instead of a manual test round: a bug
# met in real use usually leaves a line here first (v5.7.2's "could not select
# input" was logged six times before anyone reported it).
#
#   scripts/field-report.sh            # the last 7 days
#   scripts/field-report.sh 2          # the last 2 days
#   scripts/field-report.sh --strict   # exit 1 when a line outside KNOWN is found
#
# Routine lines the pipeline logs on healthy runs are listed in KNOWN and
# counted in one row. Transcript text never leaves this Mac: the report is
# printed, nothing is uploaded.
set -uo pipefail
DAYS=7; STRICT=0
for a in "$@"; do
  case "$a" in
    --strict) STRICT=1 ;;
    <->) DAYS="$a" ;;
    *) echo "usage: $0 [days] [--strict]" >&2; exit 64 ;;
  esac
done
DIR="$HOME/Library/Logs/Transcriberr"
SINCE="$(date -u -v-"${DAYS}"d +%Y-%m-%dT%H:%M:%S)"
# Healthy-run noise: quality guards doing their job, and user actions.
KNOWN='chunk N produced no parsed segments|chunk N low confidence|dropping (near-duplicate )?segment|\[job\] cancelled|target app changed'

echo "== field report: last $DAYS days (since $SINCE UTC)"
[ -r "$DIR/transcriberr.log" ] || { echo "no readable log at $DIR/transcriberr.log"; exit 1; }
TMP="$(mktemp "${TMPDIR:-/tmp}/field-report.XXXXXX")"; trap 'rm -f "$TMP"' EXIT
cat "$DIR"/transcriberr.log.1(N) "$DIR"/transcriberr.log | awk -v s="$SINCE" '$1 >= s' > "$TMP"
echo "launches: $(grep -c ' BOOT ' "$TMP")   versions: $(grep ' BOOT ' "$TMP" | grep -oE 'Transcriberr [0-9.]+' | sort -u | tr '\n' ' ')"
GROUPED="$(grep -E '^[^ ]+ (WARN|ERR|ERROR) ' "$TMP" \
  | sed -E 's/^[^ ]+ //; s/[0-9]+(\.[0-9]+)?/N/g; s/_N_[0-9A-FN]+\.mNa/<file>/g' \
  | sed -E "s/'[^']*'/'…'/g; s/\"[^\"]*\"/\"…\"/g; s/\([^)]*\)/(…)/g" | cut -c1-110 | sort | uniq -c | sort -rn)"
ROUTINE="$(print -r -- "$GROUPED" | grep -E "$KNOWN" | awk '{n+=$1} END{print n+0}')"
REST="$(print -r -- "$GROUPED" | grep -vE "$KNOWN" | grep -v '^$')"
echo "routine guard lines: $ROUTINE"
echo "-- needs a look:"
if [ -n "$REST" ]; then print -r -- "$REST"; else echo "   nothing"; fi
echo "-- crash and hang reports:"
CR="$(find "$HOME/Library/Logs/DiagnosticReports" -maxdepth 1 -iname '*transcriberr*' -mtime -"$DAYS" 2>/dev/null)"
if [ -n "$CR" ]; then print -r -- "$CR"; else echo "   none"; fi
if [ "$STRICT" = 1 ] && { [ -n "$REST" ] || [ -n "$CR" ]; }; then exit 1; fi
exit 0
