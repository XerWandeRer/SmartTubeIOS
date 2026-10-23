#!/bin/zsh
# deploy.sh — build, sign and install MyTube on the iPhone. Works over plain SSH:
# signing uses the dedicated build keychain from setup-build-keychain.sh, not the
# login keychain, so no tmux/GUI session is needed.
# Installed on the build Mac as ~/Developer/MyTube/deploy.sh. Writes ~/Developer/MyTube/build.log
# and always ends it with DEPLOY_EXIT=<rc>.
#
#   deploy.sh            build with the cached provisioning profile, install, print expiry
#   deploy.sh --renew    also pass -allowProvisioningUpdates (needs the Xcode Apple ID account,
#                        which lives in the login keychain: run this one from the tmux session)
#   deploy.sh --no-install   build and sign only
set -o pipefail
export PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin

DEV=00008150-000A0C493A84401C
BUNDLE=com.xerwanderer.mytube
ROOT=$HOME/Developer/MyTube
LOG=$ROOT/build.log
KC=$HOME/Library/Keychains/mytube-build.keychain-db
PASS_FILE=$ROOT/.build-keychain/password
PROFILES="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"

renew=0 install=1
for arg in "$@"; do
  case $arg in
    --renew) renew=1 ;;
    --no-install) install=0 ;;
    *) print -u2 "unknown option $arg"; exit 2 ;;
  esac
done

finish() {
  print "DEPLOY_EXIT=$1" >> $LOG
  tail -1 $LOG
  exit $1
}

: > $LOG
cd $ROOT/SmartTubeIOS || finish 1

# Prints "<days left> <expiry>" for the app's newest team profile.
profile_expiry() {
  local f best=0 now=$(date +%s) exp
  for f in "$PROFILES"/*.mobileprovision(N); do
    security cms -D -i "$f" 2>/dev/null | plutil -extract Entitlements.application-identifier raw -o - - 2>/dev/null \
      | grep -qx "398CWQ7N6L.$BUNDLE" || continue
    exp=$(security cms -D -i "$f" 2>/dev/null | plutil -extract ExpirationDate raw -o - -)
    exp=$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "$exp" +%s 2>/dev/null) || continue
    ((exp > best)) && best=$exp
  done
  ((best > 0)) && print "$(((best - now) / 86400)) $(date -r $best '+%Y-%m-%d %H:%M')"
}

signing_flags=()
if [[ -f $KC && -s $PASS_FILE ]]; then
  security unlock-keychain -p "$(<$PASS_FILE)" $KC >> $LOG 2>&1 || { print "unlock of $KC failed" >> $LOG; finish 1 }
  # Make codesign take the key from the build keychain even though the same identity
  # also sits in the (locked) login keychain.
  signing_flags=(OTHER_CODE_SIGN_FLAGS="--keychain $KC")
  print "signing with $KC" >> $LOG
else
  print "no build keychain — falling back to the login keychain (works only in an unlocked GUI/tmux session)" >> $LOG
fi

provisioning=()
((renew)) && provisioning=(-allowProvisioningUpdates)

xcodebuild -workspace SmartTube.xcworkspace -scheme SmartTube -configuration Debug \
  -destination "id=$DEV" -derivedDataPath $ROOT/DD $provisioning build $signing_flags >> $LOG 2>&1
rc=$?
if ((rc != 0)); then
  grep -E "error:|No profiles|expired|errSec" $LOG | tail -5
  finish $rc
fi

if read -r days expiry <<< "$(profile_expiry)"; then
  print "provisioning profile expires $expiry (${days} days left)" | tee -a $LOG
  ((days < 2)) && print "WARNING: renew soon with 'deploy.sh --renew' from the tmux session" | tee -a $LOG
fi

if ((install)); then
  xcrun devicectl device install app --device $DEV $ROOT/DD/Build/Products/Debug-iphoneos/SmartTube.app >> $LOG 2>&1
  rc=$?
fi
finish $rc
