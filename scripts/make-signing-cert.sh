#!/bin/zsh
# One-time, on the release Mac: create the self-signed code-signing identity
# "Transcriberr Signing" in the login Keychain, which scripts/package.sh then
# signs every release with instead of ad hoc.
#
# Why: an ad-hoc release is held only to `identifier "nl.ihnatov.Transcriberr"`,
# so ANY binary ad-hoc signed with that identifier inherits the user's
# Microphone and Accessibility grants and the Keychain items (API keys). With
# a certificate the designated requirement pins the certificate itself, so
# only code signed with this private key qualifies. The mic driver and its
# installer pin the same certificate.
#
# Once, on switching: macOS asks for Microphone / Accessibility again and the
# Keychain asks once for the API keys, because the signature changed. Updates
# keep working (they are checked by identifier and by the Ed25519 update key).
#
# Keep the identity: export it (Keychain Access -> My Certificates ->
# "Transcriberr Signing" -> Export, .p12) into the password manager next to
# the update-signing key. A new certificate means one more round of prompts.
set -euo pipefail
NAME="Transcriberr Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "\"$NAME\""; then
  echo "\"$NAME\" already exists in the login Keychain; not creating another" >&2
  exit 1
fi

WORK="$(mktemp -d)"
chmod 700 "$WORK"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/cert.cnf" <<EOF
[req]
distinguished_name = dn
prompt = no
x509_extensions = ext
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF

/usr/bin/openssl req -x509 -newkey rsa:3072 -sha256 -days 3650 -nodes \
  -config "$WORK/cert.cnf" -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
# A random transport password: the .p12 only exists inside $WORK.
PASS="$(/usr/bin/openssl rand -hex 24)"
/usr/bin/openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -name "$NAME" -out "$WORK/id.p12" -passout "pass:$PASS"
security import "$WORK/id.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign
# Trusted for code signing only (asks for the login password once).
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"

if ! security find-identity -v -p codesigning "$KEYCHAIN" | grep -q "\"$NAME\""; then
  echo "created, but codesign does not list \"$NAME\" as valid; check its trust in Keychain Access" >&2
  exit 1
fi
SHA1="$(/usr/bin/openssl x509 -in "$WORK/cert.pem" -noout -fingerprint -sha1 | sed 's/.*=//; s/://g')"
echo "created \"$NAME\" (SHA-1 $SHA1)"
echo "scripts/package.sh signs with it from now on. Export it to the password manager (see the top of this script)."
