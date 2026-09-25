#!/bin/bash
# The whole gate for La Forja's iOS app. This file is the ONLY enumeration of it — no other doc
# restates the list. Run: bash ios-forja/gate.sh   (ported from ios-bitacora/gate.sh)
set -u
cd "$(dirname "$0")" || exit 1
RED=0
step() { printf '\n\033[1m── %s\033[0m\n' "$1"; }
fail() { echo "   ✗ $1"; RED=1; }

step "vault rule (Swift, pure Foundation — no simulator, no signing)"
swiftc -o /tmp/forja-vaultgate Vault.swift test-vault.swift 2>/dev/null && /tmp/forja-vaultgate || fail "vault gate"

step "bridge: the speech shim against the page's REAL mic handler, the vault hook, restore, vibrate"
node test-bridge.js || fail "bridge gate"

step "web payload is current with ../index.html"
python3 build-forja.py --check || fail "bundle is stale — run: python3 ios-forja/build-forja.py"

step "the app compiles"
xcodebuild -project Forja.xcodeproj -scheme Forja -sdk iphonesimulator -configuration Debug \
  -derivedDataPath /tmp/forja-gate CODE_SIGNING_ALLOWED=NO build >/tmp/forja-gate.log 2>&1 \
  && echo "  ok   build succeeded" || fail "xcodebuild (see /tmp/forja-gate.log)"

step "the served bytes really carry the app-only rewrites"
cd Resources/app || exit 1
export LC_ALL=C
[ "$(grep -c 'fonts.googleapis\|fonts.gstatic' index.html)" = "0" ] && echo "  ok   no Google Fonts reference survives" || fail "a Google Fonts link survived"
[ "$(grep -c 'raw.githubusercontent.com' index.html)" = "0" ] && echo "  ok   demos point at the bundle, not the network" || fail "a network demo URL survived"
grep -F -q "if ('serviceWorker' in navigator) {" index.html && fail "the service worker registration is still live" || echo "  ok   service worker registration is dead in the app build"
S=$(grep -n '</style>' index.html | tail -1 | cut -d: -f1); P=$(grep -n 'href="phone.css"' index.html | tail -1 | cut -d: -f1)
[ -n "$S" ] && [ -n "$P" ] && [ "$P" -gt "$S" ] && echo "  ok   phone.css comes after the app's <style> ($P > $S)" || fail "phone.css is NOT after the app's <style>"
B=$(grep -n 'phone-boot-pre.js' index.html | head -1 | cut -d: -f1); A=$(grep -n "^'use strict';" index.html | head -1 | cut -d: -f1)
[ -n "$B" ] && [ -n "$A" ] && [ "$B" -lt "$A" ] && echo "  ok   phone-boot-pre.js loads before the app's script ($B < $A)" || fail "phone-boot-pre.js must load before the app's script"
N=$(find exdb -name '*.jpg' | wc -l | tr -d ' '); [ "$N" -gt 150 ] && echo "  ok   $N demo frames bundled" || fail "only $N demo frames bundled"
cd ../..

echo
[ $RED -eq 0 ] && echo "GATE GREEN" || { echo "GATE RED"; exit 1; }
