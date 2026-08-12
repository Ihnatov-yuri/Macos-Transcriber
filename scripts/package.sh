#!/bin/zsh
# Package a distributable Transcriberr.app: uniform ad-hoc signature.
# The LiteRT dylib ships pre-signed by Google (their Team ID); an ad-hoc
# main binary + Google-signed dylib is rejected by dyld ("different Team
# IDs"), so every embedded dylib/framework must be re-signed to match.
set -e
APP="${1:-.build/xcode/Build/Products/Release/Transcriberr.app}"
# Stable identity if one exists ("Transcriberr Signing" self-signed cert or
# any Apple Development cert) — a STABLE signature means macOS remembers
# permission grants (mic, system audio) across versions instead of
# re-prompting on every update. Falls back to ad-hoc when absent.
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | grep -oE '"[^"]+"' | head -1 | tr -d '"')"
SIGN="${IDENTITY:--}"
[ "$SIGN" != "-" ] && echo "signing with stable identity: $SIGN" || echo "signing ad-hoc (no identity found — permissions re-prompt each version)"
find "$APP/Contents/Frameworks" \( -name "*.dylib" -o -name "*.framework" \) -maxdepth 1 2>/dev/null | while read f; do
  codesign --force -s "$SIGN" "$f"
done
codesign --force -s "$SIGN" "$APP"
codesign --verify --deep "$APP" && echo "signed OK: $APP"
