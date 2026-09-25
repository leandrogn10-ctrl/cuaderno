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
  [free-exercise-db](https://github.com/yuhonas/free-exercise-db) (Unlicense) — by **exact name
  only**, via `CATALOG[].exdb`. Every pinned name was checked BY EYE against its two frames. Never
  reintroduce fuzzy matching: it shipped plausible, wrong pictures. No entry → a video search.

## The gym and the catalog (schema 2)
- `GEAR_DEFAULTS` is the building gym (from photos, 2026-09-25); `state.gear` overlays it per device
  choice (have / unit / step). Coach programs only `have:true` gear, and `acceptPlan`/`planWarnings`
  re-check that in CODE — the prompt is the ask, the code is the gate.
- `CATALOG` = most-common name + aliases + load (`bw` no weight · `bw+` added weight · `ext`) + gear.
  Coach/user names resolve to it by alias, so "DB Row" and "Dumbbell Row" are one exercise.
- Weights are STORED in canonical lbs (LeandroOS and the gist readers depend on that). Each set also
  carries `u` = the unit its number was read in (the gear's). A unit relabel keeps the number on the
  pin and changes what it means; past sets are only rewritten on confirmation, and only since `GYM_SINCE`.
- `schemaMigrate` runs on every load AND every gist pull, so it must stay idempotent: an old build on
  another device can push u-less 45-lb push-ups back. `u` is the per-set "already migrated" mark.
  The first upgrade leaves a `cuaderno.v1.pre-schema2` snapshot in localStorage.
- Declaration order: the catalog constants sit ABOVE `let state = load()` — migrate reads them on the
  first line that runs; a `const` below it is a TDZ throw and an empty app.

## The load-bearing rules
- **Deploy gate = the headless-Chrome harness.** Every `HARNESS:` line in `test-harness.html` must
  PASS before pushing. Run it headless; don't eyeball.
- **Shipping `index.html` means bumping `CACHE_NAME` in `sw.js`, same commit.** `APP_SHELL` caches
  `index.html` offline-first, so an installed copy keeps serving the old shell and a correct fix
  reads as NOT APPLIED — indistinguishable from never having pushed. And a green harness on
  `localhost` is a fact about YOUR server: the deploy isn't verified until you `curl` the Pages URL
  and grep the SERVED bytes for the string you just added. (11-sep: the coach's Max-plan gate was
  fixed, verified on `localhost:8731`, and left uncommitted — Leandro kept getting "add your API key
  in settings first" from a deploy nobody had touched.)
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
