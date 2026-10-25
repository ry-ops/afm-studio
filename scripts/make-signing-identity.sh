#!/usr/bin/env bash
# Creates a local code-signing identity so macOS sees each rebuild of AFM Studio as the same app.
#
# Ad-hoc signatures change with every build, so the Keychain asks again for your Anthropic and
# GitHub tokens after each rebuild. A build signed with this identity keeps one stable identity,
# so "Always Allow" sticks. build-app.sh and install.sh use it automatically when it exists.
#
#   bash scripts/make-signing-identity.sh           create it (asks for your password once, to trust it)
#   bash scripts/make-signing-identity.sh --remove  delete it
#
# The certificate is self-signed and trusted only on this Mac, only for code signing. It can't
# notarize or publish apps. The private key stays in your login keychain, and only codesign may use it.
set -euo pipefail

NAME="${AFM_SIGN_IDENTITY:-AFM Studio Local Signing}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if [ "${1:-}" = "--remove" ]; then
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
  if security find-certificate -c "$NAME" -p "$KEYCHAIN" > "$TMP/cert.pem" 2>/dev/null; then
    security remove-trusted-cert "$TMP/cert.pem" 2>/dev/null || true
    security delete-identity -c "$NAME" "$KEYCHAIN" >/dev/null
    echo "✓ Removed \"$NAME\". New builds will be signed ad hoc."
  else
    echo "There's no \"$NAME\" identity to remove."
  fi
  exit 0
fi

if security find-identity -v -p codesigning "$KEYCHAIN" | grep -q "\"$NAME\""; then
  echo "✓ \"$NAME\" is already set up. Run bash scripts/build-app.sh --install to use it."
  exit 0
fi

TMP=$(mktemp -d); chmod 700 "$TMP"; trap 'rm -rf "$TMP"' EXIT

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  # Created before but never trusted (for example, the password prompt was cancelled).
  security find-certificate -c "$NAME" -p "$KEYCHAIN" > "$TMP/cert.pem"
else
  echo "→ Creating \"$NAME\""
  cat > "$TMP/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
CNF
  /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cert.cnf" \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
  PASS=$(/usr/bin/openssl rand -hex 16)
  /usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
    -out "$TMP/id.p12" -passout "pass:$PASS" 2>/dev/null
  security import "$TMP/id.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign >/dev/null
fi

echo "→ Trusting it for code signing. macOS will ask for your password."
security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"

if security find-identity -v -p codesigning "$KEYCHAIN" | grep -q "\"$NAME\""; then
  echo "✓ \"$NAME\" is ready."
  echo "  Rebuild with: bash scripts/build-app.sh --install"
  echo "  The Keychain asks once more for each token. Choose Always Allow, and it won't ask again after updates."
else
  echo "The certificate was created but isn't trusted yet. Run this script again to retry." >&2
  exit 1
fi
