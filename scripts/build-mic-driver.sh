#!/bin/zsh
# Build the Transcriberr Microphone HAL plug-in (MicDriver/) into a .driver
# bundle. Usage: scripts/build-mic-driver.sh <output dir> [codesign identity]
# The app embeds it in Contents/Resources (an Xcode build phase calls this);
# Settings → Meetings installs it into /Library/Audio/Plug-Ins/HAL.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:?output dir}"
SIGN="${2:--}"
DRIVER="$OUT/TranscriberrMic.driver"
rm -rf "$DRIVER"
mkdir -p "$DRIVER/Contents/MacOS"
cp "$ROOT/MicDriver/Info.plist" "$DRIVER/Contents/Info.plist"
xcrun clang -std=c17 -O2 -Wall -Wextra -Werror -Wno-unused-parameter \
  -arch arm64 -arch x86_64 -mmacosx-version-min=26.0 \
  -bundle -framework CoreAudio -framework CoreFoundation \
  -o "$DRIVER/Contents/MacOS/TranscriberrMic" "$ROOT/MicDriver/TranscriberrMic.c"
codesign --force -s "$SIGN" "$DRIVER"
echo "built $DRIVER"
