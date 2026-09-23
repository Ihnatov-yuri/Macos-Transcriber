#!/bin/zsh
# Score the full pipeline against the private reference set.
#
#   scripts/eval-set.sh <label> [backend] [engineA] [engineB] [slice ...]
#
# The set lives outside the repo (recordings are private):
#   ${TRANSCRIBERR_EVAL:-~/Documents/Transcriberr-eval}/<slice>/{slice.m4a,.mic,.sys,ref.mic.txt,ref.sys.txt}
# Each slice runs through `transcriberrcli run` with its sidecars, so the
# split-track path (echo cancel, echo scrub, diarizer) is exercised. Output
# lines keyed ME are scored against ref.mic.txt, the rest against
# ref.sys.txt, and both together against the two references joined. A
# speaker mix-up therefore costs words on both sides, as it should.
# Runs land in <slice>/runs/<label>/ so a later build can be compared.
set -uo pipefail
LABEL="$1"; BACKEND="${2:-ensemble}"; EA="${3:-whisper-large-v3}"; EB="${4:-parakeet-v3}"
shift $(( $# < 4 ? $# : 4 ))
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI="${TRANSCRIBERR_CLI:-$ROOT/.build/xcode/Build/Products/Debug/transcriberrcli}"
SET="${TRANSCRIBERR_EVAL:-$HOME/Documents/Transcriberr-eval}"
SLICES=("$@"); [ ${#SLICES} -eq 0 ] && SLICES=($(cd "$SET" && ls -d */ | tr -d /))
VOCAB="$(defaults read nl.ihnatov.Transcriberr prompt.vocabulary 2>/dev/null), $(defaults read nl.ihnatov.Transcriberr prompt.vocabulary.byLang 2>/dev/null | python3 -c 'import json,sys; print(", ".join(json.load(sys.stdin).values()))' 2>/dev/null)"
for id in $SLICES; do
  d="$SET/$id"; [ -f "$d/ref.mic.txt" ] || continue
  L=English; [[ $id == uk-* ]] && L=Ukrainian
  out="$d/runs/$LABEL"; mkdir -p "$out"
  if [ ! -s "$out/run.tsv" ]; then
    T0=$(date +%s)
    "$CLI" run "$d/slice.m4a" 0 "$BACKEND" "$EA" "$EB" "$L" > "$out/run.tsv" 2> "$out/run.err" || echo "$id: RUN FAILED (see $out/run.err)"
    echo $(( $(date +%s) - T0 )) > "$out/seconds"
  fi
  sed 1d "$out/run.tsv" | awk -F'\t' '$4=="ME"{print $3}' > "$out/hyp.mic.txt"
  sed 1d "$out/run.tsv" | awk -F'\t' '$4!="ME"{print $3}' > "$out/hyp.sys.txt"
  cat "$out/hyp.mic.txt" "$out/hyp.sys.txt" > "$out/hyp.all.txt"
  cat "$d/ref.mic.txt" "$d/ref.sys.txt" > "$out/ref.all.txt"
  printf "%-6s %-14s %4ss\n" "$id" "$LABEL" "$(cat "$out/seconds")"
  for side in mic sys; do
    printf "   %-4s " "$side"; python3 "$ROOT/scripts/eval_wer.py" "$d/ref.$side.txt" "$out/hyp.$side.txt" --vocab "$VOCAB"
  done
  printf "   %-4s " "all"; python3 "$ROOT/scripts/eval_wer.py" "$out/ref.all.txt" "$out/hyp.all.txt" --vocab "$VOCAB"
done
