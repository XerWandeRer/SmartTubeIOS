#!/bin/zsh
# mytube-sim.sh — drive MyTube on a dedicated iOS Simulator over plain SSH (no keychain).
# Installed on the build Mac as ~/Developer/MyTube/mytube-sim.sh. Run without args for usage.
#
# Simulators: "MyTube-Golden" holds the signed-in state and is never used for tests.
# Tests run on a throwaway clone "MyTube-Work-<ts>". At most one clone per worker prefix.
# `play` and `regress` delete their clone on exit; `up` keeps one alive for the
# step-by-step commands (open/logs/shot/record/ui) until `down` or `reset`.
set -o pipefail
export PATH=/opt/homebrew/bin:$HOME/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin

ROOT=$HOME/Developer/MyTube
SRC=${MYTUBE_SRC:-$ROOT/SmartTubeIOS}
DD=${MYTUBE_DD:-$ROOT/DD-sim}
OUT=${MYTUBE_OUT:-$ROOT/sim-out}
APP=$DD/Build/Products/Debug-iphonesimulator/SmartTube.app
BUNDLE=com.xerwanderer.mytube
GOLDEN=MyTube-Golden
# Parallel sessions: give each its own MYTUBE_WORKER_PREFIX (e.g. MyTube-WkA, not a
# prefix of another session's), MYTUBE_OUT, MYTUBE_SRC and MYTUBE_DD. At most 3 at once.
WORKER_PREFIX=${MYTUBE_WORKER_PREFIX:-MyTube-Work}
RUNTIME=${MYTUBE_RUNTIME:-com.apple.CoreSimulator.SimRuntime.iOS-27-0}   # matches the iPhone (iOS 27.0.x)
DEVTYPE="iPhone Air"
YTDLP=$ROOT/yt-dlp-nightly
LIST=${MYTUBE_REGRESS_LIST:-$SRC/scripts/mytube/regress-list.tsv}
DU_LIMIT_KB=$((5 * 1024 * 1024))
LOG_PREDICATE='subsystem == "com.xerwanderer.mytube" OR subsystem == "com.void.smarttube.app"'
DEVICES_DIR=$HOME/Library/Developer/CoreSimulator/Devices
typeset -a EXTRA_ARGS   # extra launch arguments for probe_one
WARM_SECS=0             # probe_one: >0 = launch idle, wait, then open the video by URL

mkdir -p $OUT

die() { print -u2 "mytube-sim: $*"; exit 1 }
note() { print -u2 "mytube-sim: $*" }

# --- simulator bookkeeping -------------------------------------------------

# Prints "<udid> <state> <name>" for every MyTube simulator.
sims() {
  xcrun simctl list devices -j | python3 -c '
import json, sys
for devs in json.load(sys.stdin)["devices"].values():
    for d in devs:
        if not d.get("isAvailable", False):
            continue
        if d["name"] == "'$GOLDEN'" or d["name"].startswith("'$WORKER_PREFIX'"):
            print(d["udid"], d["state"], d["name"])'
}
golden_udid() { sims | awk -v n=$GOLDEN '$3 == n { print $1; exit }' }
worker_udid() { sims | awk -v p=$WORKER_PREFIX 'index($3, p) == 1 { print $1; exit }' }
sim_state() { sims | awk -v u=$1 '$1 == u { print $2 }' }

ensure_golden() {
  local g=$(golden_udid)
  if [[ -z $g ]]; then
    g=$(xcrun simctl create $GOLDEN "$DEVTYPE" $RUNTIME) || die "cannot create $GOLDEN"
    note "created $GOLDEN $g"
  fi
  print $g
}

# Clones are APFS copy-on-write, so `du` of golden + worker double-counts shared blocks.
# Warn when the golden device itself exceeds the limit, or a worker has grown more than
# 1 GB beyond the golden device it was cloned from.
du_check() {
  local g=$(golden_udid) w=$(worker_udid) gkb=0 wkb=0
  [[ -n $g && -d $DEVICES_DIR/$g ]] && gkb=$(du -sk $DEVICES_DIR/$g | awk '{ print $1 }')
  [[ -n $w && -d $DEVICES_DIR/$w ]] && wkb=$(du -sk $DEVICES_DIR/$w | awk '{ print $1 }')
  if ((gkb > DU_LIMIT_KB)); then
    note "WARNING: $GOLDEN uses $((gkb / 1024)) MB (> $((DU_LIMIT_KB / 1024)) MB)."
  fi
  if ((wkb - gkb > 1024 * 1024)); then
    note "WARNING: worker grew $(((wkb - gkb) / 1024)) MB beyond $GOLDEN. Run 'down' or 'reset'."
  fi
}

worker_down() {
  local u
  for u in $(sims | awk -v p=$WORKER_PREFIX 'index($3, p) == 1 { print $1 }'); do
    xcrun simctl shutdown $u 2>/dev/null
    xcrun simctl delete $u && note "deleted worker $u"
  done
}

# Replaces any existing worker with a fresh clone of the golden device.
worker_up() {
  local g=$(ensure_golden) w
  worker_down
  [[ $(sim_state $g) == Shutdown ]] || xcrun simctl shutdown $g
  w=$(xcrun simctl clone $g "$WORKER_PREFIX-$(date +%m%d-%H%M%S)") || die "clone failed"
  xcrun simctl boot $w || die "boot failed"
  xcrun simctl bootstatus $w -b >/dev/null || die "bootstatus failed"
  note "worker $w booted"
  du_check
  print $w
}

# Prints the live worker, or fails with a hint.
need_worker() {
  local w=$(worker_udid)
  [[ -n $w ]] || die "no worker; run '$0 up' first"
  [[ $(sim_state $w) == Booted ]] || xcrun simctl boot $w
  print $w
}

need_app() { [[ -d $APP ]] || die "no build at $APP; run '$0 build' first" }

# --- commands --------------------------------------------------------------

# Ad-hoc ("Sign to Run Locally") signing needs no keychain but still embeds the simulated
# entitlements. Without application-identifier 398CWQ7N6L.<bundle> the app lands in a
# different keychain access group and cannot read the Golden device's sign-in tokens.
cmd_build() {
  local log=$OUT/build.log
  # Generic destination: building against the golden device can boot and modify it.
  note "building $SRC → $DD (log: $log)"
  (cd $SRC && xcodebuild build -workspace SmartTube.xcworkspace -scheme SmartTube -configuration Debug \
    -destination "generic/platform=iOS Simulator" ARCHS=arm64 -derivedDataPath $DD \
    CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual PROVISIONING_PROFILE_SPECIFIER= DEVELOPMENT_TEAM=398CWQ7N6L) > $log 2>&1
  local rc=$?
  grep -E "error:|\*\* BUILD" $log | tail -20
  print "BUILD_EXIT=$rc"
  return $rc
}

cmd_install() {
  need_app
  local target
  target=$(need_worker) || exit 1
  [[ $1 == --golden ]] && target=$(ensure_golden) && xcrun simctl boot $target 2>/dev/null
  xcrun simctl install $target $APP && print "installed on $target"
}

# Boots the golden device with the GUI so the owner can sign in once.
cmd_golden() {
  need_app
  local g=$(ensure_golden)
  worker_down   # clone/boot of the golden device is exclusive
  xcrun simctl boot $g 2>/dev/null
  xcrun simctl bootstatus $g -b >/dev/null
  xcrun simctl install $g $APP
  open -a Simulator --args -CurrentDeviceUDID $g
  xcrun simctl launch $g $BUNDLE >/dev/null
  print "Golden $g is booted with MyTube. Sign in (Settings → Account → device code),"
  print "then run '$0 golden-done' to shut it down so it can be cloned."
}

cmd_golden_done() {
  local g=$(golden_udid)
  [[ -n $g ]] || die "no golden device"
  xcrun simctl terminate $g $BUNDLE 2>/dev/null
  xcrun simctl shutdown $g 2>/dev/null
  du_check
  print "golden $g shut down"
}

cmd_up() {
  need_app
  local w
  w=$(worker_up) || exit 1
  xcrun simctl install $w $APP || die "install failed"
  print $w
}

# open <videoId> [--client <method>]
cmd_open() {
  local vid=$1; shift
  [[ -n $vid ]] || die "usage: open <videoId> [--client <method>]"
  local w; w=$(need_worker) || exit 1
  # Cold launch with the deep-link argument: `simctl openurl` raises an
  # "Open in SmartTube?" system prompt that blocks unattended runs.
  local -a args=("--uitesting-deeplink-video=$vid")
  [[ $1 == --client ]] && args+=("--uitesting-force-stream-method=$2")
  xcrun simctl launch --terminate-running-process $w $BUNDLE "${args[@]}" >/dev/null || die "launch failed"
  print "opened $vid on $w"
}

# logs [seconds] [--probe] — streams app logs to stdout for N seconds (default 30).
cmd_logs() {
  local secs=30 pred=$LOG_PREDICATE
  [[ $1 == <-> ]] && { secs=$1; shift }
  [[ $1 == --probe ]] && pred='category == "PlaybackProbe"'
  local w; w=$(need_worker) || exit 1
  xcrun simctl spawn $w log stream --level debug --style compact --predicate "$pred" &
  local pid=$!
  sleep $secs
  kill $pid 2>/dev/null
  wait $pid 2>/dev/null
}

cmd_shot() {
  local w f=${1:-$OUT/shot-$(date +%H%M%S).png}; w=$(need_worker) || exit 1
  xcrun simctl io $w screenshot $f >/dev/null && print $f
}

# record [seconds] [file]
cmd_record() {
  local secs=${1:-10} f=${2:-$OUT/rec-$(date +%H%M%S).mp4} w; w=$(need_worker) || exit 1
  xcrun simctl io $w recordVideo --codec h264 --force $f 2>/dev/null &
  local pid=$!
  sleep $secs
  kill -INT $pid
  wait $pid 2>/dev/null
  print $f
}

# ui tap X Y | ui swipe X1 Y1 X2 Y2 | ui text "..." | ui tree | ui <any idb ui args>
cmd_ui() {
  local w; w=$(need_worker) || exit 1
  case $1 in
    tree) idb ui describe-all --udid $w --json ;;
    "") die "usage: ui tap X Y | swipe X1 Y1 X2 Y2 | text STR | tree" ;;
    *) idb ui "$@" --udid $w ;;
  esac
}

# Resolves dynamic regression IDs: live:<channel path> / upcoming:<channel path>.
resolve_video() {
  local spec=$1 want chan  # not "path": zsh ties it to $PATH
  case $spec in
    live:*) want=is_live; chan=${spec#live:} ;;
    upcoming:*) want=is_upcoming; chan=${spec#upcoming:} ;;
    *) print $spec; return ;;
  esac
  $YTDLP --flat-playlist --no-warnings -I 1:20 --print "%(id)s %(live_status)s" \
    "https://www.youtube.com/$chan" 2>/dev/null | awk -v s=$want '$2 == s { print $1; exit }'
}

# Waits for the PROBE outcome of one video in a log file. Prints "ready <fields>",
# "error <fields>" or "timeout".
await_probe() {
  local file=$1 vid=$2 timeout=$3 t=0 line
  while ((t < timeout * 2)); do
    line=$(grep -a "PROBE event=ready video=$vid " $file | head -1)
    [[ -n $line ]] && { print "ready ${line#*PROBE event=ready }"; return }
    line=$(grep -a "PROBE event=error video=$vid " $file | head -1)
    if [[ -n $line ]]; then
      # A non-fatal error can precede a later success; give the chain a moment.
      sleep 3
      local ok=$(grep -a "PROBE event=ready video=$vid " $file | head -1)
      [[ -n $ok ]] && { print "ready ${ok#*PROBE event=ready }"; return }
      print "error ${line#*PROBE event=error }"
      return
    fi
    sleep 0.5
    t=$((t + 1))
  done
  print timeout
}

field() { print -r -- "$1" | grep -oE "(^| )$2=[^ ]*" | head -1 | sed -E "s/^ ?$2=//" }

# Taps "Open" on the "Open in “SmartTube”?" prompt that `simctl openurl` raises.
tap_open_prompt() {
  local w=$1 i xy
  for i in {1..40}; do
    xy=$(idb ui describe-all --udid $w --json 2>/dev/null | python3 -I -c '
import json, sys
for e in json.load(sys.stdin):
    if e.get("type") == "Button" and e.get("AXLabel") == "Open":
        f = e["frame"]
        print(int(f["x"] + f["width"] / 2), int(f["y"] + f["height"] / 2))
        break' 2>/dev/null)
    [[ -n $xy ]] && { idb ui tap ${=xy} --udid $w >/dev/null; return 0 }
    sleep 0.25
  done
  return 1
}

# Cold-launches one video on worker $w and records the outcome. With WARM_SECS > 0 the
# app launches to Home, idles WARM_SECS (feed, prefetch, launch-time warm-ups), and the
# video then opens through its URL — the usual "app open, tap a video" case.
# probe_one <worker> <case> <videoId> <client|""> <timeout> → prints a TSV row.
probe_one() {
  local w=$1 name=$2 vid=$3 client=$4 timeout=$5
  local tag=$OUT/$name-$vid
  local -a args=("--uitesting-deeplink-video=$vid")
  [[ -n $client ]] && args+=("--uitesting-force-stream-method=$client")
  args+=("${EXTRA_ARGS[@]}")
  xcrun simctl terminate $w $BUNDLE 2>/dev/null
  xcrun simctl spawn $w log stream --level debug --style compact --predicate "$LOG_PREDICATE" > $tag.log 2>&1 &
  local lpid=$!
  sleep 1
  if ((WARM_SECS > 0)); then
    xcrun simctl launch $w $BUNDLE "${EXTRA_ARGS[@]}" >/dev/null
    sleep $WARM_SECS
    xcrun simctl openurl $w "smarttube://video/$vid" &
    local upid=$!
    tap_open_prompt $w || note "no Open prompt for $vid"
    wait $upid 2>/dev/null
  else
    xcrun simctl launch $w $BUNDLE "${args[@]}" >/dev/null
  fi
  local res=$(await_probe $tag.log $vid $timeout)
  [[ $res == ready* ]] && sleep 4   # let the first frames render before the screenshot
  xcrun simctl io $w screenshot $tag.png >/dev/null 2>&1
  kill $lpid 2>/dev/null
  wait $lpid 2>/dev/null
  local outcome=${res%% *} msg=
  [[ $res == *'message="'* ]] && msg=${${res#*message=\"}%%\"*}
  print -r -- "$name	$vid	$outcome	$(field "$res" client)	$(field "$res" itag)	$(field "$res" kind)	$(field "$res" ms)	$msg	$tag.png"
}

# play <videoId> [--client <method>] [--timeout <s>] — one isolated probe on a fresh worker.
cmd_play() {
  local vid=$1 client= timeout=60; shift
  [[ -n $vid ]] || die "usage: play <videoId> [--client <method>] [--timeout <s>]"
  while (($#)); do
    case $1 in
      --client) client=$2; shift 2 ;;
      --timeout) timeout=$2; shift 2 ;;
      *) die "unknown option $1" ;;
    esac
  done
  need_app
  local w
  w=$(worker_up) || exit 1
  trap worker_down EXIT
  xcrun simctl install $w $APP || die "install failed"
  print "case\tvideo\tresult\tclient\titag\tkind\tms\terror\tscreenshot"
  probe_one $w play $(resolve_video $vid) "$client" $timeout
}

# regress [--client <method>] [--list <tsv>] [--timeout <s>]
cmd_regress() {
  local client= timeout=60 list=$LIST
  while (($#)); do
    case $1 in
      --client) client=$2; shift 2 ;;
      --list) list=$2; shift 2 ;;
      --timeout) timeout=$2; shift 2 ;;
      *) die "unknown option $1" ;;
    esac
  done
  [[ -f $list ]] || die "no list at $list"
  need_app
  local w
  w=$(worker_up) || exit 1
  trap worker_down EXIT
  xcrun simctl install $w $APP || die "install failed"
  local report=$OUT/regress-$(date +%Y%m%d-%H%M%S).md pass=0 fail=0
  local name spec expect vid row outcome verdict
  {
    print "| case | video | expect | result | verdict | client | itag | kind | ms | error |"
    print "|---|---|---|---|---|---|---|---|---|---|"
  } > $report
  while IFS=$'\t' read -r name spec expect; do
    [[ -z $name || $name == \#* ]] && continue
    vid=$(resolve_video $spec)
    if [[ -z $vid ]]; then
      print "| $name | ($spec unresolved) | $expect | skip | SKIP | | | | | |" >> $report
      continue
    fi
    row=$(probe_one $w $name $vid "$client" $timeout)
    local -a f=("${(@s:	:)row}")
    outcome=$f[3]
    if [[ $outcome == $expect ]]; then verdict=PASS; pass=$((pass + 1)); else verdict=FAIL; fail=$((fail + 1)); fi
    print "| $name | $vid | $expect | $outcome | $verdict | $f[4] | $f[5] | $f[6] | $f[7] | $f[8] |" >> $report
  done < $list
  print "\nclient override: ${client:-none} · pass=$pass fail=$fail · artifacts: $OUT" >> $report
  cat $report
  print "REPORT=$report"
  ((fail == 0))
}

# bench [--list tsv] [--rounds n] [--timeout s] [--warm secs] — startup timing per step.
# Every round launches the app afresh for each video of the list on one worker (round 1
# is the app's first launch): by deep link (cold), or with --warm idle on Home first and
# then by URL. Summarises the PlaybackProbe stage records with bench-stages.py.
cmd_bench() {
  local timeout=60 list=${MYTUBE_BENCH_LIST:-$SRC/scripts/mytube/bench-list.tsv} rounds=3
  while (($#)); do
    case $1 in
      --list) list=$2; shift 2 ;;
      --rounds) rounds=$2; shift 2 ;;
      --timeout) timeout=$2; shift 2 ;;
      --warm) WARM_SECS=$2; shift 2 ;;
      *) die "unknown option $1" ;;
    esac
  done
  [[ -f $list ]] || die "no list at $list"
  need_app
  local w
  w=$(worker_up) || exit 1
  trap worker_down EXIT
  xcrun simctl install $w $APP || die "install failed"
  local mode=cold
  ((WARM_SECS > 0)) && mode=warm$WARM_SECS
  local report=$OUT/bench-$mode-$(date +%Y%m%d-%H%M%S).tsv r name vid
  python3 -I $SRC/scripts/mytube/bench-stages.py --header > $report
  for r in $(seq 1 $rounds); do
    while IFS=$'\t' read -r name vid; do
      [[ -z $name || $name == \#* ]] && continue
      probe_one $w bench-r$r-$name $vid "" $timeout > /dev/null
      python3 -I $SRC/scripts/mytube/bench-stages.py $OUT/bench-r$r-$name-$vid.log $vid r$r-$name >> $report
    done < $list
  done
  column -t -s $'\t' $report
  print "REPORT=$report"
}

# fixtures [--clients "m1 m2 …"] [--list f] [--timeout s] — records the raw /player
# response of every client for every list entry (Debug build only), then copies the
# scrubbed JSON files to $OUT/fixtures-<ts>/.
cmd_fixtures() {
  local clients="visionos ios android-vr android tvembedded websafari mweb tvauth ios-auth web-auth web-creator"
  local timeout=30 list=$LIST
  while (($#)); do
    case $1 in
      --clients) clients=$2; shift 2 ;;
      --list) list=$2; shift 2 ;;
      --timeout) timeout=$2; shift 2 ;;
      *) die "unknown option $1" ;;
    esac
  done
  [[ -f $list ]] || die "no list at $list"
  need_app
  local w
  w=$(worker_up) || exit 1
  trap worker_down EXIT
  xcrun simctl install $w $APP || die "install failed"
  EXTRA_ARGS=(--uitesting-record-player-responses)
  local name spec expect vid m
  while IFS=$'\t' read -r name spec expect; do
    [[ -z $name || $name == \#* ]] && continue
    vid=$(resolve_video $spec)
    [[ -n $vid ]] || continue
    for m in ${=clients}; do
      probe_one $w $name-$m $vid $m $timeout
    done
  done < $list
  local dest=$OUT/fixtures-$(date +%Y%m%d-%H%M%S)
  mkdir -p $dest
  cp $(xcrun simctl get_app_container $w $BUNDLE data)/Documents/PlayerResponses/*.json $dest/ 2>/dev/null
  ls $dest
  print "FIXTURES=$dest"
}

# unit [Suite[/test]] — package unit tests (Swift Testing) on a throwaway worker.
# `swift test` on macOS does not build (see AGENTS.md), so this runs them on the Simulator.
cmd_unit() {
  local w log=$OUT/unit.log
  local -a only=()
  [[ -n $1 ]] && only=("-only-testing:SmartTubeIOSTests/$1")
  w=$(worker_up) || exit 1
  trap worker_down EXIT
  (cd $SRC/SmartTubeIOS && xcodebuild test -scheme SmartTubeIOS-Package -destination "id=$w" \
    -derivedDataPath ${MYTUBE_DD_UNIT:-$ROOT/DD-unit} CODE_SIGNING_ALLOWED=NO $only) > $log 2>&1
  local rc=$?
  grep -E "error:|✘|Test run with|\*\* TEST" $log | tail -40
  print "UNIT_EXIT=$rc (log: $log)"
  return $rc
}

cmd_status() {
  sims
  local u
  for u in $(sims | awk '{ print $1 }'); do du -sh $DEVICES_DIR/$u 2>/dev/null; done
  du_check
  [[ -d $APP ]] && print "build: $APP ($(stat -f %Sm $APP))"
}

# Deletes the worker and old artifacts. Never touches the golden device.
cmd_reset() {
  worker_down
  find $OUT -type f -mtime +3 -delete 2>/dev/null
  du_check
}

usage() {
  cat <<EOF
usage: mytube-sim.sh <command>
  build                      ad-hoc signed simulator build of \$MYTUBE_SRC (default $SRC)
  golden | golden-done       boot $GOLDEN with GUI for the one-time sign-in / shut it down
  up | down                  fresh worker clone (with app installed) / delete it
  install [--golden]         reinstall the current build on the worker (or golden)
  open <id> [--client m]     cold-launch a video (optionally forcing one client)
  logs [secs] [--probe]      stream app logs (default 30 s)
  shot [file] | record [secs] [file]
  ui tap X Y | swipe X1 Y1 X2 Y2 | text STR | tree
  play <id> [--client m] [--timeout s]     one probe on a throwaway worker
  regress [--client m] [--list f] [--timeout s]   run the regression list, print table
  fixtures [--clients "m …"] [--list f]   record scrubbed /player responses per client
  bench [--list f] [--rounds n] [--warm s] startup timing per step (cold or warm launches)
  unit [Suite[/test]]        package unit tests on a throwaway worker
  status | reset
client methods: ios ios-auth tvembedded tvauth websafari mweb android android-vr visionos
                web-creator web-auth wkwebview-hls
EOF
}

cmd=$1; shift 2>/dev/null
case $cmd in
  build) cmd_build "$@" ;;
  install) cmd_install "$@" ;;
  golden) cmd_golden ;;
  golden-done) cmd_golden_done ;;
  up) cmd_up ;;
  down) worker_down ;;
  open) cmd_open "$@" ;;
  logs) cmd_logs "$@" ;;
  shot) cmd_shot "$@" ;;
  record) cmd_record "$@" ;;
  ui) cmd_ui "$@" ;;
  play) cmd_play "$@" ;;
  regress) cmd_regress "$@" ;;
  bench) cmd_bench "$@" ;;
  fixtures) cmd_fixtures "$@" ;;
  unit) cmd_unit "$@" ;;
  status) cmd_status ;;
  reset) cmd_reset ;;
  *) usage; [[ -z $cmd ]] ;;
esac
