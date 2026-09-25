# La Forja — the training log, as a real app on the phone

A native iOS app (`com.leandro.forja`) that carries **the whole of La Forja**, free-signed, re-signed
nightly so it never costs the $99. Ported from Bitácora's app (`~/Projects/bitacora/ios-bitacora`),
whose README holds the long-form reasoning for every shared piece; this one records what differs.

`../index.html` stays the single source of truth. `build-forja.py` DERIVES the app's payload from it,
every rewrite anchored by an assert that fails loudly if `index.html` moves. Ship to the web app and
it is in the phone app at the next rebuild.

## What is native, and why only this
The engine runs in a WKWebView served from `forja-app://local/` (a stable, port-free origin — the
origin is the key the log is filed under). Everything else exists because a web page **cannot** do it:

- **The debrief mic** (`Speech.swift`). WKWebView has no working Web Speech API — and Chrome on the
  iPhone *is* a WKWebView, which is why the debrief mic went blank. `phone-boot-pre.js` installs a
  class with the Web Speech surface the page uses; iOS's own recognizer does the listening (on-device
  when the model is present: no network needed, no one-minute cap). The page's handler is unchanged.
  iOS re-segments and restarts mid-dictation; the shim turns each boundary into a closed result so
  words already on screen are never overwritten by a shorter partial. `stop()` waits 1.5 s for the
  final result and synthesizes it from the last partial if it never comes. The audio session mixes
  with whatever is playing, so recording a debrief doesn't kill the gym music.
- **Rest that reaches a locked phone.** Every save carries the live workout; native reads
  `activeWorkout.rest/hold.endsAt` and keeps ONE pending notification in step with it (only a change
  touches the notification centre; a past or missing end-time cancels). Suppressed in the foreground,
  where the page already buzzes.
- **A screen that stays lit** for the whole workout (`isIdleTimerDisabled` while one is active).
- **Haptics.** The page already calls `navigator.vibrate` on the 3-2-1 and when rest runs out; a
  WKWebView has no vibrate, so the shim routes those to real haptics, and Done/check get a thud.
- **The vault** (`Vault.swift`) — append-only and monotonic, as in Bitácora; "collapse" is measured in
  LOGGED SETS (a save that drops more than five, or half of a young log, is held for a human).
- **Offline.** Fonts and the catalog's 182 checked demo frames ship inside the app; a basement gym
  with no signal still shows every demo. Coach and gist sync still need the network.

NOT ported on purpose: Bitácora's touchmove lock. Its screens scroll inside panes; La Forja scrolls
the document, so that lock would freeze every screen.

## First run on the phone
The app is a new origin, so it opens empty. Settings → Cloud sync → paste the GitHub token and the
gist ID once; the log comes down from the gist. (The Anthropic key, if used, is entered once too.)
The first Record asks for the microphone and speech recognition; the first rest asks to notify.

## Install
The free Apple ID carries **three** side-loaded apps; this is the third (El Quiosco, Bitácora,
La Forja), so there is no spare slot for experiments. `bash ~/Projects/bitacora/ios-bitacora/check-app-slots.sh`
asks the phone (unlocked) before anything takes one.
```bash
bash ios-forja/setup-xcode.sh      # builds the payload, generates Forja.xcodeproj
bash ios-forja/resign.sh           # build + profile + install over Wi-Fi (Xcode must have the Apple ID signed in)
```
The phone's identifiers live in `~/.leandro-os/forja-device.env`, not here — this repo is public.
Once installed by hand, arm the nightly re-sign (03:50 / 13:20, ten minutes after the other two):
```bash
cp ios-forja/com.leandro-os.forja-resign.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.leandro-os.forja-resign.plist
launchctl print gui/$(id -u)/com.leandro-os.forja-resign   # verify in launchd's view, not the file
```

## The gate
`bash ios-forja/gate.sh` — the only enumeration of it. `test-bridge.js` drives the speech shim
through the page's REAL `setupDebriefMic` (extracted from index.html, asserted declared once) and
re-plants the naive shim as a control that must lose words.

## Verified, and not
**Verified (simulator, iPhone 17 Pro, iOS 26.5):** the app builds and boots; both bundled faces really
load (measured by rendered width against an invented family); the shim is live
(`speech=ForjaSpeechRecognition`); safe areas 62/34; the Exercises screen draws its demos from the
bundle with zero 404s. Gate green: vault 20/20, bridge 16/16.

**Not verified yet:** anything on the real phone. Speech cannot be tested in the simulator (no
on-device model); the rest notification, haptics, keep-awake and the vault pull all need the device.
The first install is blocked on Xcode having an Apple ID signed in (it had none on 2026-09-25).
