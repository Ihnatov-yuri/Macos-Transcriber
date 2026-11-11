#!/bin/zsh
# Replay real meetings through a build and compare with the last accepted one.
# The stand-in for "use it for a day before tagging": the private reference set
# (scripts/eval-set.sh, four 5-minute split-track slices, English and
# Ukrainian) runs through the candidate CLI, and each slice's word error rate
# and run time are held against a stored baseline.
#
#   scripts/replay-check.sh            # default engine (Parakeet), about a minute
#   scripts/replay-check.sh --super    # also Super (Whisper + Parakeet), about 15 minutes
#   scripts/replay-check.sh --accept   # store this build's numbers as the new baseline
#
# FAIL when a run errors, a transcript comes back empty, or a slice's WER is
# more than TOLERANCE points worse than the baseline (run-to-run noise is
# about 0.2). The WER is over content words; fillers and repeated words are
# counted beside it (scripts/eval_wer.py) and shown with the baseline's
# counts, and a run with more than twice the baseline's repeats (and at least
# 5 more) FAILs: that is an engine looping. A run slower than twice the
# baseline is reported, not failed.
# The first run on a machine stores the baseline and passes, unless
# REQUIRE_BASELINE=1 (the release gate), where a missing baseline FAILs.
#
# Environment: TRANSCRIBERR_CLI (default: the Release CLI in .build/xcode),
# TRANSCRIBERR_EVAL (default ~/Documents/Transcriberr-eval), TOLERANCE (1.0).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
export TRANSCRIBERR_CLI="${TRANSCRIBERR_CLI:-$ROOT/.build/xcode/Build/Products/Release/transcriberrcli}"
SET="${TRANSCRIBERR_EVAL:-$HOME/Documents/Transcriberr-eval}"
TOL="${TOLERANCE:-1.0}"
BASELINE="$SET/gate-baseline.tsv"
SUPER=0; ACCEPT=0
for a in "$@"; do
  case "$a" in
    --super) SUPER=1 ;;
    --accept) ACCEPT=1 ;;
    *) echo "unknown option: $a" >&2; exit 64 ;;
  esac
done
[ -x "$TRANSCRIBERR_CLI" ] || { echo "FAIL  no CLI at $TRANSCRIBERR_CLI (build -scheme TranscriberrCLI -configuration Release)"; exit 1; }
[ -d "$SET" ] || { echo "FAIL  no reference set at $SET"; exit 1; }

# Runs are kept per BINARY, not per commit: eval-set.sh reuses a finished
# run with the same label, and that must never be another build's transcript.
SHA="$(shasum "$TRANSCRIBERR_CLI" | cut -c1-10)"
RESULTS="$(mktemp "${TMPDIR:-/tmp}/replay-check.XXXXXX")"
trap 'rm -f "$RESULTS" "$RESULTS".*' EXIT

# mode, then the eval-set.sh engine arguments
run_mode() {
  local mode="$1"; shift
  local label="gate-$mode-$SHA" id d out wer secs
  echo "== $mode ($label)"
  scripts/eval-set.sh "$label" "$@" > "$RESULTS.$mode.log" 2>&1
  for d in "$SET"/*/; do
    id="${${d%/}:t}"; [ -f "$d/ref.mic.txt" ] || continue
    out="$d/runs/$label"
    wer=""; line=""
    [ -s "$out/hyp.all.txt" ] && line="$(python3 scripts/eval_wer.py "$out/ref.all.txt" "$out/hyp.all.txt" 2>/dev/null)"
    wer="$(print -r -- "$line" | sed -nE 's/^WER +([0-9.]+)%.*/\1/p')"
    fillers="$(print -r -- "$line" | sed -nE 's/.*fillers ([0-9]+) .*/\1/p')"
    repeats="$(print -r -- "$line" | sed -nE 's/.*repeats ([0-9]+) .*/\1/p')"
    if [ -z "$wer" ]; then
      # Not kept: the next attempt must run again, not re-score this failure.
      rm -rf "$out"
      printf "%s\t%s\tFAILED\t0\n" "$id" "$mode" >> "$RESULTS"; continue
    fi
    secs="$(cat "$out/seconds" 2>/dev/null || echo 0)"
    printf "%s\t%s\t%s\t%s\t%s\t%s\n" "$id" "$mode" "$wer" "$secs" "${fillers:-0}" "${repeats:-0}" >> "$RESULTS"
  done
}

# A Mac that sleeps mid-run gives a transcript with words missing and run
# times in hours (it failed the first v5.7.3 gate run): stay awake until done.
caffeinate -i -w $$ &

run_mode fast parakeet-v3
[ "$SUPER" = 1 ] && run_mode super ensemble whisper-large-v3 parakeet-v3

[ -s "$RESULTS" ] || { echo "FAIL  no slice with a reference in $SET: nothing was replayed"; echo "replay: FAIL"; exit 1; }
if [ "$ACCEPT" = 0 ] && [ ! -f "$BASELINE" ] && [ "${REQUIRE_BASELINE:-0}" = 1 ]; then
  echo "FAIL  no baseline at $BASELINE (scripts/replay-check.sh --super --accept on a build you trust)"; echo "replay: FAIL"; exit 1
fi
if [ "$ACCEPT" = 1 ] || [ ! -f "$BASELINE" ]; then
  if grep -q FAILED "$RESULTS"; then echo "FAIL  a run failed; baseline not stored"; cat "$RESULTS"; exit 1; fi
  # Keep baseline rows for modes this run did not cover.
  { [ -f "$BASELINE" ] && awk -F'\t' 'NR==FNR{seen[$1 FS $2]=1; next} !(($1 FS $2) in seen)' "$RESULTS" "$BASELINE"; cat "$RESULTS"; } | sort > "$BASELINE.new"
  mv "$BASELINE.new" "$BASELINE"
  echo "baseline stored: $BASELINE"; column -t "$BASELINE"; exit 0
fi

python3 - "$BASELINE" "$RESULTS" "$TOL" <<'PY'
import sys
def row(l):   # wer, secs, fillers, repeats; old baselines have no counts
    f = l.rstrip("\n").split("\t")[2:]
    return f + [None] * (4 - len(f))
base = {tuple(l.split("\t")[:2]): row(l) for l in open(sys.argv[1]) if l.strip()}
tol, bad = float(sys.argv[3]), 0
print(f"{'slice':6} {'mode':6} {'WER':>6} {'was':>6} {'secs':>5} {'was':>5} {'fill':>5} {'was':>4} {'rep':>4} {'was':>4}")
for l in open(sys.argv[2]):
    sl, mode = l.split("\t")[:2]
    wer, secs, fill, reps = row(l)
    bw, bs, bf, br = base.get((sl, mode), (None, None, None, None))
    note = ""
    if wer == "FAILED":
        note, bad = "FAIL  run failed or empty transcript", bad + 1
    elif bw is None:
        note, bad = "FAIL  no baseline for this slice (--accept stores it)", bad + 1
    else:
        if float(wer) > float(bw) + tol:
            note, bad = f"FAIL  {float(wer) - float(bw):+.1f} points", bad + 1
        elif float(wer) < float(bw) - tol:
            note = f"better {float(wer) - float(bw):+.1f} (--accept to keep)"
        if br is not None and int(reps) > 2 * int(br) and int(reps) >= int(br) + 5:
            note, bad = note + f"  FAIL  repeats {br} -> {reps}", bad + 1
        if int(bs) and int(secs) > 2 * int(bs) + 10:
            note += "  SLOW"
    print(f"{sl:6} {mode:6} {wer:>6} {bw or '-':>6} {secs:>5} {bs or '-':>5} {fill or '-':>5} {bf or '-':>4} {reps or '-':>4} {br or '-':>4}  {note}")
seen = {tuple(l.split("\t")[:2]) for l in open(sys.argv[2]) if l.strip()}
for sl, mode in sorted(base):
    if mode in {m for _, m in seen} and (sl, mode) not in seen:
        print(f"{sl:6} {mode:6} FAIL  in the baseline, not replayed"); bad += 1
print("replay: FAIL" if bad else "replay: PASS")
sys.exit(1 if bad else 0)
PY
