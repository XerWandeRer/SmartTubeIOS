## MyTube build-Mac tooling (fork only)

Scripts for the build Mac (X-in-Black). Copy them to `~/Developer/MyTube/` after a sync:

```sh
cp ~/Developer/MyTube/SmartTubeIOS/scripts/mytube/{mytube-sim.sh,deploy.sh,setup-build-keychain.sh} ~/Developer/MyTube/
```

### Simulator (`mytube-sim.sh`)

No signing and no keychain, so it works over plain SSH. `MyTube-Golden` (iOS 27.0, iPhone Air)
keeps the signed-in state; every test run uses a throwaway clone of it.

| Command | What it does |
|---|---|
| `build` | Unsigned Debug build into `DD-sim` |
| `golden` / `golden-done` | Boot Golden with the GUI for the one-time device-code sign-in, then shut it down |
| `play <id> [--client m]` | One probe on a fresh clone: result, client, itag, ms, screenshot |
| `regress [--client m]` | Run `regress-list.tsv`, print a pass/fail table (Markdown report in `sim-out/`) |
| `fixtures [--clients "…"]` | Record scrubbed `/player` responses per client for the offline tests |
| `unit [Suite]` | Package unit tests on a fresh clone (`swift test` does not build on macOS) |
| `up`, `open`, `logs`, `shot`, `record`, `ui`, `down` | Step-by-step control of one clone |
| `status`, `reset` | Disk usage (warns above 5 GB) and cleanup; never touches Golden |

Pass/fail comes from the Debug-only `PlaybackProbe` log category:
`PROBE event=start|ready|error video=<id> …`. `--client` maps to
`--uitesting-force-stream-method` (`visionos`, `ios`, `android-vr`, `tvauth`, …).

### Device (`deploy.sh`)

`deploy.sh` signs with `~/Library/Keychains/mytube-build.keychain-db`, whose random password
sits in `~/Developer/MyTube/.build-keychain/password`, so it runs over plain SSH. Set that keychain up
once with `setup-build-keychain.sh` from a GUI-unlocked session, because exporting the key from the
login keychain needs a dialog to be approved. The free-team provisioning profile lasts 7 days. Renew it with
`deploy.sh --renew` from the tmux session, because the Xcode account lives in the login keychain.
