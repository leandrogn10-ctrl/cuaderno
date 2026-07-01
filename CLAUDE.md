# El Cuaderno — project guide

**Phone-first training-log PWA.** Single-file (`index.html`), offline-first, GitHub Pages.
Built from the **app-shell template (C3)** — see `~/Projects/app-shell/CLAUDE.md` for the shared
plumbing (gist sync, theme system, `callClaude`, `looksLikeMyState`) and the manual-backport policy.

## What this is (don't drift from this)
- The whole app is **`index.html`** — HTML + CSS + vanilla JS, **no build, no dependencies**.
  `sw.js` is the service worker. State syncs to a private GitHub gist (`cuaderno.json`),
  last-write-wins, credentials stripped before every write.
- **Phone-first**: thumb-reachable targets, mobile bottom-sheet UI, A2HS / iOS standalone safe-areas.
- Exercise demo images + form instructions come from the public-domain
  [free-exercise-db](https://github.com/yuhonas/free-exercise-db) (Unlicense).

## The load-bearing rules
- **Deploy gate = the headless-Chrome harness.** Every `HARNESS:` line in `test-harness.html` must
  PASS before pushing. Run it headless; don't eyeball.
- **Shell plumbing fixes are backported by hand** from `app-shell/shell.html` — keep the sync/SW/
  Claude/settings blocks structurally identical so the diffs stay small.
- **Persistence discipline**: a schema change is invisible to a returning user unless stale
  `localStorage` is gated — version the state and migrate in `appMigrate`. Smoke-test reload after
  any persistence change.

## Dev loop
```bash
python3 -m http.server 8000   # http://localhost:8000/
```
Serve over HTTP, never `file://`. **Bump the port when verifying** — a reused port can serve a stale
service-worker copy of the app.
