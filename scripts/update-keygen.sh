#!/bin/zsh
# One-time: create the update-signing key in the login Keychain and print
# the public key to paste into UpdateSignature.publicKey. Refuses to replace
# an existing key: every installed copy trusts only the key it shipped with.
# Back the private key up (password manager):
#   security find-generic-password -s nl.ihnatov.Transcriberr.update-signing -a release -w
set -e
cd "$(dirname "$0")/.."
SERVICE=nl.ihnatov.Transcriberr.update-signing
if security find-generic-password -s "$SERVICE" -a release >/dev/null 2>&1; then
  echo "a signing key already exists in the Keychain ($SERVICE); not replacing it" >&2; exit 1
fi
KEY="$(swift scripts/update-signing.swift keygen)"
security add-generic-password -s "$SERVICE" -a release -l "Transcriberr update signing key" -w "$KEY"
print -r -- "$KEY" | swift scripts/update-signing.swift pubkey
