# Sourced by build-app.sh and install.sh. Sets SIGN to the local identity when it exists, else "-" (ad hoc).
SIGN_NAME="${AFM_SIGN_IDENTITY:-AFM Studio Local Signing}"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$SIGN_NAME\""; then
  SIGN="$SIGN_NAME"
  SIGN_NOTE="with \"$SIGN_NAME\""
else
  SIGN="-"
  SIGN_NOTE="ad hoc (run scripts/make-signing-identity.sh so the Keychain remembers your approvals across rebuilds)"
fi
