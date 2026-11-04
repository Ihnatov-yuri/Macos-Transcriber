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
# Through `security -i`'s stdin, not `-w "$KEY"`: an argument is readable by
# every local user (ps, process accounting) while the command runs. The key
# is base64 and the service name is fixed, so neither needs quoting.
print -r -- "add-generic-password -s $SERVICE -a release -l \"Transcriberr update signing key\" -w $KEY" | security -i >/dev/null
security find-generic-password -s "$SERVICE" -a release >/dev/null 2>&1 \
  || { echo "could not store the signing key in the Keychain" >&2; exit 1; }
print -r -- "$KEY" | swift scripts/update-signing.swift pubkey
