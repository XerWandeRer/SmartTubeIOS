#!/bin/zsh
# setup-build-keychain.sh — one-time setup of a dedicated signing keychain so deploy.sh
# can sign over plain SSH. Run it ONCE on the build Mac from a GUI-unlocked session
# (Terminal.app, or the "mytube" tmux session): exporting the development key from the
# login keychain shows a macOS dialog that must be approved with the login password.
#
# Result:
#   ~/Library/Keychains/mytube-build.keychain-db   holds only the Apple Development identity
#   ~/Developer/MyTube/.build-keychain/password    random password (0600), unrelated to the login password
# The keychain is added to the user search list and its key partition list allows codesign.
# Re-running is safe: an existing keychain and password are kept; the identity is re-imported.
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

KC=$HOME/Library/Keychains/mytube-build.keychain-db
SECRET_DIR=$HOME/Developer/MyTube/.build-keychain
PASS_FILE=$SECRET_DIR/password
LOGIN_KC=$HOME/Library/Keychains/login.keychain-db
IDENTITY=${MYTUBE_SIGN_IDENTITY:-"Apple Development"}

umask 077
mkdir -p $SECRET_DIR
chmod 700 $SECRET_DIR
if [[ ! -s $PASS_FILE ]]; then
  openssl rand -base64 32 | tr -d '\n' > $PASS_FILE
  chmod 600 $PASS_FILE
  print "created password file $PASS_FILE"
fi
PASS=$(<$PASS_FILE)

if [[ ! -f $KC ]]; then
  security create-keychain -p "$PASS" $KC
  print "created $KC"
fi
security unlock-keychain -p "$PASS" $KC
security set-keychain-settings $KC   # no auto-lock timeout, no lock on sleep

# Add to the user search list once, keeping whatever is already there.
if ! security list-keychains -d user | grep -q mytube-build; then
  existing=(${(f)"$(security list-keychains -d user | tr -d ' "')"})
  security list-keychains -d user -s $existing $KC
  print "added $KC to the user keychain search list"
fi

if security find-identity -v -p codesigning $KC | grep -q "$IDENTITY"; then
  print "identity already present in $KC"
else
  P12=$SECRET_DIR/identity.p12
  P12PASS=$(openssl rand -base64 24)
  trap 'rm -f $P12' EXIT
  print "exporting identities from the login keychain — approve the macOS dialog(s)…"
  security export -k $LOGIN_KC -t identities -f pkcs12 -P "$P12PASS" -o $P12
  security import $P12 -k $KC -P "$P12PASS" \
    -T /usr/bin/codesign -T /usr/bin/security -T /usr/bin/productbuild
  rm -f $P12
fi

# Let codesign use the key without a UI prompt.
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PASS" $KC >/dev/null
security find-identity -v -p codesigning $KC
print "OK — deploy.sh can now sign over SSH."
