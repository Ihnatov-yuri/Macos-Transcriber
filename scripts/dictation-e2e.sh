#!/bin/zsh
# End-to-end dictation smoke test against a built app.
#   scripts/dictation-e2e.sh [/path/to/Transcriberr.app]
# Plays a sentence through the speakers (TTS), the built-in mic hears it,
# the app recognizes it via the URL scheme session, and the result is read
# back from the log and the knowledge base. Voice processing is disabled
# for the run (its echo canceller would swallow speaker playback) and the
# history entry it creates is removed afterwards.
set -u
APP="${1:-.build/xcode/Build/Products/Release/Transcriberr.app}"
LOG=~/Library/Logs/Transcriberr/transcriberr.log
DEF=nl.ihnatov.Transcriberr
STORE=~/Library/Application\ Support/Transcriberr.store
PHRASE="This is a dictation test comma the quick brown fox jumps over the lazy dog period new paragraph second passage question mark"
EXPECT="the quick brown fox jumps over the lazy dog."

osascript -e "tell application id \"$DEF\" to quit" >/dev/null 2>&1; sleep 2
pkill -f "Transcriberr.app/Contents/MacOS/Transcriberr" 2>/dev/null; sleep 1
PREV_NS=$(defaults read $DEF recorder.noiseSuppression 2>/dev/null || echo 1)
[ "$PREV_NS" = "1" ] && PREV_NS=true || PREV_NS=false
PREV_HIST=$(defaults read $DEF dictation.keepHistory 2>/dev/null || echo unset)
# The phrase is English: pin the recognizer language for the run and put
# the user's own choice back afterwards (exported as a plist, restored 1:1).
PREV_LANG_PLIST=$(mktemp)
defaults export $DEF - > "$PREV_LANG_PLIST" 2>/dev/null
defaults write $DEF dictation.languages -array English
defaults write $DEF recorder.noiseSuppression -bool false
defaults write $DEF dictation.keepHistory -bool true
MARK=$(wc -l < "$LOG")
START_MS=$(python3 -c 'import time; print(int(time.time()*1000))')

open -n "$APP"; sleep 6
open "transcriberr://dictate/pane"; sleep 1.5
open "transcriberr://dictate/start"; sleep 1.5
say -v Samantha -r 170 "$PHRASE"; sleep 1
open "transcriberr://dictate/stop"; sleep 6

echo "=== log"
tail -n +$((MARK+1)) "$LOG" | grep -E "dictation\]|parakeet\] chunk" | cut -c1-160
RESULT=$(sqlite3 "$STORE" "select group_concat(ZTEXT, ' ') from ZSEGMENT where ZRECORDING in (select Z_PK from ZRECORDING where ZCREATEDATMILLIS >= $START_MS and ZAUDIOPATH like '%/Dictation_%');" 2>/dev/null)
echo "=== recognized: $RESULT"

# restore settings, remove the test entry
python3 - "$DEF" "$PREV_LANG_PLIST" <<'PY'
import plistlib, subprocess, sys
domain, path = sys.argv[1], sys.argv[2]
try:
    prev = plistlib.load(open(path, "rb")).get("dictation.languages")
except Exception:
    prev = None
if prev is None:
    subprocess.run(["defaults", "delete", domain, "dictation.languages"], capture_output=True)
else:
    subprocess.run(["defaults", "write", domain, "dictation.languages", "-array", *prev], capture_output=True)
PY
rm -f "$PREV_LANG_PLIST"
defaults write $DEF recorder.noiseSuppression -bool "$PREV_NS"
if [ "$PREV_HIST" = "unset" ]; then
  defaults delete $DEF dictation.keepHistory 2>/dev/null
elif [ "$PREV_HIST" = "1" ]; then
  defaults write $DEF dictation.keepHistory -bool true
else
  defaults write $DEF dictation.keepHistory -bool false
fi
osascript -e "tell application id \"$DEF\" to quit" >/dev/null 2>&1; sleep 2
# Everything the run created (toggle mode may have flushed the passage in
# several pieces) — matched by creation time, not by title.
for PK in $(sqlite3 "$STORE" "select Z_PK from ZRECORDING where ZCREATEDATMILLIS >= $START_MS and ZAUDIOPATH like '%/Dictation_%';"); do
  AUDIO=$(sqlite3 "$STORE" "select ZAUDIOPATH from ZRECORDING where Z_PK=$PK;")
  ID=$(sqlite3 "$STORE" "select hex(ZID) from ZRECORDING where Z_PK=$PK;")
  sqlite3 "$STORE" "delete from ZSEGMENT where ZRECORDING=$PK; delete from ZTRANSCRIPTVERSION where ZRECORDING=$PK; delete from ZRECORDING where Z_PK=$PK;"
  [ -n "$AUDIO" ] && rm -f "$AUDIO"
  UUID=$(echo "$ID" | sed -E 's/(.{8})(.{4})(.{4})(.{4})(.{12})/\1-\2-\3-\4-\5/')
  rm -rf ~/Documents/"Transcriberr Backups"/"$UUID"
done
sqlite3 "$STORE" "delete from ZFOLDER where ZNAME='Dictation' and not exists (select 1 from ZRECORDING where ZFOLDER=ZFOLDER.Z_PK); pragma wal_checkpoint(TRUNCATE);" >/dev/null
open -a "$APP"

# Case-insensitive: the smart pass may recapitalize ("test, the" → "test. The").
case "${RESULT:l}" in
  *"${EXPECT:l}"*) echo "PASS"; exit 0;;
  *) echo "FAIL (expected to contain: $EXPECT)"; exit 1;;
esac
