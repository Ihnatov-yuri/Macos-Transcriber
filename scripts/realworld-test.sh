#!/bin/zsh
# Real-world regression check: cut a slice out of an actual recording (with
# its .mic/.sys sidecars, so the split-track path runs), transcribe it
# headlessly through the full pipeline, and report the defect counts this
# project has actually been bitten by — next to the same counts for the
# transcript the app stored for that time window (the "before").
#
#   scripts/realworld-test.sh <recording.m4a> <start-sec> <duration-sec> <Language> [backend] [engineA] [engineB]
#
# Nothing is written into the repo or the Recordings folder: the slice and
# the outputs live under $TMPDIR. Recordings are private — never commit them.
set -euo pipefail
REC="$1"; START="$2"; DUR="$3"; LANG_NAME="$4"
BACKEND="${5:-ensemble}"; EA="${6:-whisper-large-v3}"; EB="${7:-parakeet-v3}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI="$ROOT/.build/xcode/Build/Products/Debug/transcriberrcli"
[ -x "$CLI" ] || { echo "build the CLI first: xcodebuild -scheme TranscriberrCLI -derivedDataPath .build/xcode build"; exit 1; }
OUT="$(mktemp -d "${TMPDIR:-/tmp}/transcriberr-realworld.XXXXXX")"
BASE="${REC%.m4a}"
for kind in "" .mic .sys; do
  [ -f "$BASE$kind.m4a" ] && ffmpeg -v error -y -ss "$START" -t "$DUR" -i "$BASE$kind.m4a" -c:a aac -b:a 96k "$OUT/slice$kind.m4a"
done
T0=$(date +%s)
"$CLI" run "$OUT/slice.m4a" 2 "$BACKEND" "$EA" "$EB" "$LANG_NAME" > "$OUT/after.tsv" 2> "$OUT/run.err" || { echo "RUN FAILED — see $OUT/run.err"; exit 1; }
ELAPSED=$(( $(date +%s) - T0 ))
sed 1d "$OUT/after.tsv" | cut -f3 > "$OUT/after.txt"
python3 "$ROOT/scripts/realworld_metrics.py" "$BASE.srt" "$START" "$DUR" "$OUT/after.txt" "$ELAPSED"
echo "outputs: $OUT"
