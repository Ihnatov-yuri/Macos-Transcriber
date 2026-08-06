#!/bin/zsh
# Package a distributable Transcriberr.app: uniform ad-hoc signature.
# The LiteRT dylib ships pre-signed by Google (their Team ID); an ad-hoc
# main binary + Google-signed dylib is rejected by dyld ("different Team
# IDs"), so every embedded dylib/framework must be re-signed to match.
set -e
APP="${1:-.build/xcode/Build/Products/Release/Transcriberr.app}"
find "$APP/Contents/Frameworks" \( -name "*.dylib" -o -name "*.framework" \) -maxdepth 1 2>/dev/null | while read f; do
  codesign --force -s - "$f"
done
codesign --force -s - "$APP"
codesign --verify --deep "$APP" && echo "signed OK: $APP"
