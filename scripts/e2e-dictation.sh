#!/bin/zsh
# End-to-end dictation check against a built app: URL-scheme start → text
# spoken by macOS TTS through the speakers (picked up by the built-in mic)
# → URL-scheme stop → the recognized passage must land in the log.
#
#   scripts/e2e-dictation.sh [/path/to/Transcriberr.app]   (default: /Applications)
#
# Voice processing (echo cancellation) suppresses speaker playback, so it is
# switched off for the run and restored afterwards. Quit other copies of the
# app first — the URL is routed to whichever instance is registered.
set -u
APP="${1:-/Applications/Transcriberr.app}"
LOG=~/Library/Logs/Transcriberr/transcriberr.log
DOMAIN=nl.ihnatov.Transcriberr
PHRASE="This is a dictation test comma the quick brown fox jumps over the lazy dog period new paragraph second passage question mark"

prev_ns="$(defaults read $DOMAIN recorder.noiseSuppression 2>/dev/null || echo 1)"
defaults write $DOMAIN recorder.noiseSuppression -bool false
restore() { defaults write $DOMAIN recorder.noiseSuppression -bool "$prev_ns"; }
trap restore EXIT

pkill -f "Transcriberr.app/Contents/MacOS/Transcriberr" 2>/dev/null; sleep 2
MARK=$(wc -l < "$LOG" 2>/dev/null || echo 0)
open -n "$APP"; sleep 6
open "transcriberr://dictate/pane"; sleep 1.5
open "transcriberr://dictate/start"; sleep 1.5
say -v Samantha -r 170 "$PHRASE"
sleep 1
open "transcriberr://dictate/stop"; sleep 6

echo "=== dictation log since launch"
tail -n +$((MARK+1)) "$LOG" | grep -E "dictation|parakeet\] chunk" | cut -c1-200
if tail -n +$((MARK+1)) "$LOG" | grep -qE "recognized [0-9.]+s → [0-9]{2,} chars"; then
  echo "E2E OK"; exit 0
else
  echo "E2E FAILED — no passage recognized"; exit 1
fi
