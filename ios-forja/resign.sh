#!/bin/bash
# La Forja — the nightly re-sign (ported from ios-bitacora/resign.sh, where each step's reason is
# written out). Free signing dies every 7 days; this rebuilds with a fresh personal-team profile and
# installs over Wi-Fi to the paired phone, Xcode closed.
# Run by launchd (com.leandro-os.forja-resign) at 03:50 and 13:20 — TEN MINUTES AFTER El Quiosco and
# Bitácora (03:40 / 13:10), on purpose: three xcodebuilds and three device installs at the same
# minute contend for the same phone and the same DerivedData locks.
# By hand: bash ~/Projects/cuaderno/ios-forja/resign.sh
# Logs to ~/.leandro-os/forja-resign.log; failures go to the caja under src `forja`.
#
# WHY THIS TREE LIVES IN ~/Projects: launchd's /bin/bash had no TCC grant for ~/Downloads, so El
# Quiosco's agent exited 126 for seven nights WITHOUT opening its script — and its only alarm lived
# inside the file bash could not open, so the alarm was downstream of its own failure. ~/Projects is
# not a TCC-protected location. Nothing in this script may read from Desktop/Documents/Downloads.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
# Which phone lives in ~/.leandro-os/forja-device.env, NOT here: this repo is public.
[ -f "$HOME/.leandro-os/forja-device.env" ] && . "$HOME/.leandro-os/forja-device.env"
DEV="${FORJA_DEV:-}"; UDID="${FORJA_UDID:-}"
BUNDLE="com.leandro.forja"
DD="/tmp/forja-dev"
LOG="$HOME/.leandro-os/forja-resign.log"
APP="$DD/Build/Products/Debug-iphoneos/Forja.app"
say()  { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG"; }
fail() { say "FAIL $*"; python3 -c "import sys;sys.path.insert(0,'$HOME/.leandro-os');from caja import caja;caja('forja.resign.fail',{'why':'''$*'''[:160]},'error')" 2>/dev/null; exit 1; }
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
say "start"
[ -n "$DEV" ] || fail "no phone configured — ~/.leandro-os/forja-device.env is missing FORJA_DEV"

# Reachability. Match EITHER id: Xcode 27 (devicectl 642.16) flipped the Identifier column from the
# devicectl identifier to the hardware UDID, so a gate grepping only $DEV reads a reachable phone as
# unreachable. «available (paired)» is the table's word for reachable.
xcrun devicectl list devices 2>/dev/null | grep -E "$DEV|$UDID" | grep -q "available (paired)" \
  || fail "phone not reachable (not on this network, or asleep too long)"

# Ship a COMMITTED index.html, never the working tree. An unattended 3am install of a half-edited
# file is how one bad line of JS becomes a phone that boots to an empty log — and the vault is
# designed to hold that save, not to be immune to it. Committing is how you ship.
SHA="$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null)" || fail "not a git repo: $REPO"
if ! git -C "$REPO" diff --quiet -- index.html 2>/dev/null; then
  say "note: index.html has uncommitted changes — shipping HEAD ($SHA), not the working tree"
fi
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
git -C "$REPO" show HEAD:index.html > "$TMP/index.html" 2>/dev/null || fail "cannot read index.html at HEAD"
python3 "$HERE/build-forja.py" --src "$TMP/index.html" >>"$LOG" 2>&1 || fail "web bundle"

# Xcode REUSES a valid profile rather than minting a fresh one, so a nightly rebuild does NOT by
# itself extend the expiry. Under 3 days left, delete it so -allowProvisioningUpdates mints a new
# 7-day one — without this the app dies on schedule while this log prints "ok" every night.
PD="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
for f in "$PD"/*.mobileprovision; do
  [ -f "$f" ] || continue
  security cms -D -i "$f" 2>/dev/null | grep -q "$BUNDLE" || continue
  E=$(security cms -D -i "$f" 2>/dev/null | plutil -extract ExpirationDate raw -o - - 2>/dev/null)
  ES=$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$E" +%s 2>/dev/null || echo 0)
  if [ $(( ES - $(date +%s) )) -lt $(( 3*86400 )) ]; then say "profile $E within 3 days → removing to force a fresh one"; rm -f "$f"; fi
done

cd "$HERE" || fail "cd"
if ! xcodebuild -project Forja.xcodeproj -scheme Forja -sdk iphoneos -configuration Debug \
     -derivedDataPath "$DD" -destination "id=$DEV" -allowProvisioningUpdates build >>"$LOG.build" 2>&1; then
  fail "xcodebuild (see $LOG.build)"
fi

# Pull the vault off the phone BEFORE replacing the app, so the Mac keeps a copy the phone cannot
# erase — and so a bad install is never the only thing standing between him and the log.
# Best-effort by design: a failed pull must not stop a re-sign, or an expiring cert would ride on
# a backup step. It gets its own event so a silently-never-pulling backup can still be noticed.
VDIR="$HOME/.leandro-os/forja-vault"; mkdir -p "$VDIR"
if xcrun devicectl device copy from --device "$DEV" --domain-type appDataContainer \
     --domain-identifier "$BUNDLE" --source Documents/forja-vault.json \
     --destination "$VDIR/vault-$(date +%Y%m%d-%H%M%S).json" >>"$LOG" 2>&1; then
  say "vault pulled to $VDIR"
  ls -1t "$VDIR"/vault-*.json 2>/dev/null | tail -n +31 | xargs -I{} rm -f {}   # keep 30
else
  say "note: vault pull failed (no vault yet on a first run, or the phone refused) — continuing"
  python3 -c "import sys;sys.path.insert(0,'$HOME/.leandro-os');from caja import caja;caja('forja.vault.pullfail',{},'warn')" 2>/dev/null
fi

xcrun devicectl device install app --device "$DEV" "$APP" >>"$LOG" 2>&1 || fail "install"

# The expiry is read back out of the BUILT app, not assumed from the build succeeding: Xcode
# reusing a valid profile and Xcode minting a new one look identical from the outside.
# This line is the LAST statement on purpose — it pairs an expiry with an install that happened.
# The watchdog parses it verbatim: "ok · profile expires <ISO>Z" with a U+00B7 middle dot.
EXP=$(security cms -D -i "$APP/embedded.mobileprovision" 2>/dev/null | plutil -extract ExpirationDate raw -o - - 2>/dev/null)
say "ok · profile expires $EXP"
