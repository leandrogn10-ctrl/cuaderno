#!/bin/bash
# Fetches XcodeGen (no brew, no sudo) and generates Forja.xcodeproj from project.yml (ported from ios-bitacora).
# Run:  bash ~/Projects/cuaderno/ios-forja/setup-xcode.sh
set -u
cd "$(dirname "$0")" || { echo "cannot cd"; exit 1; }
echo "[1/4] building the web payload from ../index.html (+ bundled demo frames)..."
python3 build-forja.py || { echo "BUNDLE FAILED"; exit 1; }
if [ ! -x /tmp/xg/bin/xcodegen ] && [ -z "$(find /tmp/xg -name xcodegen -type f 2>/dev/null | head -1)" ]; then
  echo "[2/4] downloading XcodeGen..."
  curl -fL --max-time 120 -o /tmp/xg.zip "https://github.com/yonaskolb/XcodeGen/releases/latest/download/xcodegen.zip" \
    || { echo "DOWNLOAD FAILED"; exit 1; }
  rm -rf /tmp/xg && unzip -oq /tmp/xg.zip -d /tmp/xg || { echo "UNZIP FAILED"; exit 1; }
else
  echo "[2/4] XcodeGen already in /tmp/xg — reusing"
fi
BIN="$(find /tmp/xg -name xcodegen -type f | head -1)"
[ -n "$BIN" ] || { echo "XCODEGEN NOT FOUND"; exit 1; }
chmod +x "$BIN" 2>/dev/null
echo "[3/4] generating Forja.xcodeproj..."
"$BIN" generate --spec project.yml || { echo "GENERATE FAILED"; exit 1; }
echo "[4/4] result:"
ls -ld Forja.xcodeproj && echo "" && echo "SUCCESS."
echo "In Xcode: Signing & Capabilities -> Team = your Apple ID, plug in the iPhone, press Run."
