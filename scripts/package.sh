#!/bin/zsh
# Package a distributable Transcriberr.app: uniform signature.
# Every embedded dylib/framework (UzuRuntime) is re-signed with the app's
# identity: dyld rejects a main binary and a library signed by different
# Team IDs.
set -e
APP="${1:-.build/xcode/Build/Products/Release/Transcriberr.app}"
# Stable identity if one exists ("Transcriberr Signing" self-signed cert or
# any Apple Development cert) — a STABLE signature means macOS remembers
# permission grants (mic, system audio) across versions instead of
# re-prompting on every update. Falls back to ad-hoc when absent.
# scripts/make-signing-cert.sh creates "Transcriberr Signing"; it wins over
# any other identity so a release is never signed with a stray certificate.
IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null | grep -oE '"[^"]+"' | tr -d '"')"
if print -r -- "$IDENTITIES" | grep -qx "Transcriberr Signing"; then
  IDENTITY="Transcriberr Signing"
else
  IDENTITY="$(print -r -- "$IDENTITIES" | head -1)"
fi
SIGN="${IDENTITY:--}"
if [ "$SIGN" != "-" ]; then
  echo "signing with stable identity: $SIGN"
else
  echo "signing AD-HOC: any binary signed with the same identifier inherits this app's" >&2
  echo "  Microphone/Accessibility grants and Keychain items. Run scripts/make-signing-cert.sh once." >&2
fi
find "$APP/Contents/Frameworks" \( -name "*.dylib" -o -name "*.framework" \) -maxdepth 1 2>/dev/null | while read f; do
  codesign --force -s "$SIGN" "$f"
done
# The Transcriberr Microphone HAL plug-in in Resources: signed before the app,
# whose seal covers it. coreaudiod's driver helper loads it from
# /Library/Audio/Plug-Ins/HAL once Settings installs it.
DRIVER="$APP/Contents/Resources/TranscriberrMic.driver"
[ -d "$DRIVER" ] && codesign --force -s "$SIGN" "$DRIVER"
# Hardened runtime + explicit entitlements. A plain re-sign drops both (Xcode's
# ENABLE_HARDENED_RUNTIME does not survive it), and without the runtime any
# local process could start the app with DYLD_INSERT_LIBRARIES and inherit its
# Microphone / Accessibility / Keychain access.
ENT="$(cd "$(dirname "$0")" && pwd)/release.entitlements"
HARDEN=(--options runtime --entitlements "$ENT")
if [ "$SIGN" = "-" ]; then
  # Ad-hoc: macOS keys TCC grants (Microphone, Accessibility) to the app's
  # DESIGNATED REQUIREMENT, which for an ad-hoc signature defaults to the
  # per-build cdhash — so every rebuild silently invalidated the grants and
  # System Settings showed a ticked-but-dead entry. An explicit identifier-only
  # requirement is stable across builds, so grants made once stay valid.
  BUNDLE_ID="$(defaults read "$PWD/$APP/Contents/Info.plist" CFBundleIdentifier 2>/dev/null || defaults read "$APP/Contents/Info.plist" CFBundleIdentifier)"
  codesign --force -s - "${HARDEN[@]}" -i "$BUNDLE_ID" -r="designated => identifier \"$BUNDLE_ID\"" "$APP"
else
  codesign --force -s "$SIGN" "${HARDEN[@]}" "$APP"
fi
codesign --verify --deep "$APP" && echo "signed OK: $APP"
# The CLI (MCP server) built next to the app gets the same stable requirement:
# with the default cdhash requirement every rebuild re-asked for Documents
# access. No hardened runtime here: it would turn on library validation for
# the UzuRuntime framework it loads from @executable_path.
CLI="$(dirname "$APP")/transcriberrcli"
if [ -f "$CLI" ]; then
  if [ "$SIGN" = "-" ]; then
    CLI_ID="nl.ihnatov.TranscriberrCLI"
    codesign --force -s - -i "$CLI_ID" -r="designated => identifier \"$CLI_ID\"" "$CLI"
  else
    codesign --force -s "$SIGN" "$CLI"
  fi
  codesign --verify "$CLI" && echo "signed OK: $CLI"
fi
