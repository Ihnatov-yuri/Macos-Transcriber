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
if [ "$SIGN" = "-" ]; then
  # Ad-hoc: macOS keys TCC grants (Microphone, Accessibility) to the app's
  # DESIGNATED REQUIREMENT, which for an ad-hoc signature defaults to the
  # per-build cdhash — so every rebuild silently invalidated the grants and
  # System Settings showed a ticked-but-dead entry. An explicit identifier-only
  # requirement is stable across builds, so grants made once stay valid.
  BUNDLE_ID="$(defaults read "$PWD/$APP/Contents/Info.plist" CFBundleIdentifier 2>/dev/null || defaults read "$APP/Contents/Info.plist" CFBundleIdentifier)"
  codesign --force -s - -i "$BUNDLE_ID" -r="designated => identifier \"$BUNDLE_ID\"" "$APP"
else
  codesign --force -s "$SIGN" "$APP"
fi
codesign --verify --deep "$APP" && echo "signed OK: $APP"
