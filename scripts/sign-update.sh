#!/bin/zsh
# Sign a release zip for in-app updates: writes <zip>.sig next to it, then
# verifies it against the public key compiled into the app, so a release
# can't go out signed with a key the app doesn't trust.
#   scripts/sign-update.sh Transcriberr-v3.14.3-macOS-arm64.zip [version]
set -e
cd "$(dirname "$0")/.."
ZIP="${1:?zip path}"
V="${2:-$(grep -m1 'MARKETING_VERSION:' project.yml | grep -oE '[0-9]+(\.[0-9]+)+')}"
[[ "$(basename "$ZIP")" == "Transcriberr-v$V-macOS-arm64.zip" ]] || { echo "zip must be named Transcriberr-v$V-macOS-arm64.zip" >&2; exit 1; }
KEY="$(security find-generic-password -s nl.ihnatov.Transcriberr.update-signing -a release -w)"
print -r -- "$KEY" | swift scripts/update-signing.swift sign "$ZIP" "$V" > "$ZIP.sig"
PUB="$(grep -m1 'static let publicKey' Transcriberr/App/UpdateInstaller.swift | grep -oE '"[^"]+"' | tr -d '"')"
swift scripts/update-signing.swift verify "$ZIP" "$V" "$ZIP.sig" "$PUB"
echo "wrote $ZIP.sig"
