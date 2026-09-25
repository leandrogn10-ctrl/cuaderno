#!/usr/bin/env python3
"""Derives the app's web payload from ../index.html — NEVER hand-edited, NEVER a fork.

index.html stays the single source of truth for La Forja (the PWA and the app run the SAME engine).
This script makes the changes an offline, app-hosted copy needs, each anchored by an assert so a
drift in index.html fails LOUDLY here instead of shipping a subtly-broken bundle.

  1. Google Fonts <link>s removed    — a gym basement has no signal; the app must not render in
                                       Times. Replaced by @font-face over BUNDLED ttf in phone.css.
  2. phone-boot-pre.js into <head>   — before the app's script: vault restore, the storage hook,
                                       and the shims (speech, vibrate) must exist before it runs.
  3. phone.css LAST in <head>        — after the app's own <style>, or equal-specificity rules
                                       silently lose the cascade while reading as present.
  4. phone-boot-post.js before </body>.
  5. Service worker registration killed — the bundle IS the cache.
  6. Demo images bundled             — the catalog's checked free-exercise-db frames and a trimmed
                                       index ship inside the app, and the two URL constants are
                                       pointed at them. Downloaded once into .exdb-cache/, so the
                                       3am re-sign never needs the network.

Run:  python3 ios-forja/build-forja.py            # rebuild Resources/app/
      python3 ios-forja/build-forja.py --check    # nonzero if the bundle is stale
"""
import hashlib, io, json, os, re, shutil, sys, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, '..', 'index.html')      # --src overrides: resign.sh ships HEAD, not the tree
DEST = os.path.join(HERE, 'Resources', 'app')
FONT_SRC = os.path.join(HERE, 'Fonts')
CACHE = os.path.join(HERE, '.exdb-cache')
SIDECARS = ['phone.css', 'phone-boot-pre.js', 'phone-boot-post.js']

EXDB_BASE = 'https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/'
GFONT_LINES = [
    '<link rel="preconnect" href="https://fonts.googleapis.com">\n',
    '<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>\n',
]
GFONT_SHEET = re.compile(r'<link href="https://fonts\.googleapis\.com/css2\?[^"]*" rel="stylesheet">')
INJECT_PRE = '<script src="phone-boot-pre.js"></script>   <!-- app build: fonts are bundled (phone.css), not fetched -->'
SW_GUARD = "if ('serviceWorker' in navigator) {"
SW_DEAD = "if (false) {   /* app build: the bundle is the cache — see ios-forja/build-forja.py */"
URL_INDEX = "const EXDB_INDEX_URL = '" + EXDB_BASE + "dist/exercises.json';"
URL_IMGS = "const EXDB_IMG_PREFIX = '" + EXDB_BASE + "exercises/';"
CAT_ROW = re.compile(r"""^\s*\['([\w-]+)',\s*(['"])(?:(?!\2).)*\2,\s*'(?:bw\+?|ext)',\s*'[\w]*',\s*(null|'([^']*)'|"([^"]*)"),""", re.M)


def source():
    return io.open(sys.argv[sys.argv.index('--src') + 1] if '--src' in sys.argv else SRC, encoding='utf-8').read()


def catalog_exdb_names(s):
    """The exact db names CATALOG pins. Counted against the rows themselves, so a row the regex
    fails to read is a build failure, not a quietly missing demo."""
    block = s[s.index('const CATALOG = ['):s.index('].map(([key, name, load, gear, exdb, aliases])')]
    rows = [ln for ln in block.splitlines() if re.match(r"\s*\['", ln)]
    hits = CAT_ROW.findall(block)
    assert len(hits) == len(rows), 'CATALOG: read %d of %d rows — the row format moved' % (len(hits), len(rows))
    return sorted({h[3] or h[4] for h in hits if h[2] != 'null'})


def fetch(rel):
    """A free-exercise-db file, from the cache or (once) from GitHub."""
    p = os.path.join(CACHE, rel)
    if not os.path.exists(p):
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with urllib.request.urlopen(EXDB_BASE + rel, timeout=60) as r:
            data = r.read()
        io.open(p, 'wb').write(data)
    return io.open(p, 'rb').read()


def exdb_bundle(names):
    index = json.loads(fetch('dist/exercises.json'))
    by = {e['name']: e for e in index}
    missing = [n for n in names if n not in by]
    assert not missing, 'CATALOG pins db names the index no longer has: %s' % missing
    out, trimmed = {}, []
    for n in names:
        e = by[n]
        trimmed.append(e)
        for img in e.get('images', [])[:2]:
            out['exdb/' + img] = fetch('exercises/' + img)
    out['exdb/exercises.json'] = json.dumps(trimmed, ensure_ascii=False, sort_keys=True).encode('utf-8')
    return out


def build(s):
    for line in GFONT_LINES:
        assert s.count(line) == 1, 'a Google Fonts preconnect line moved — update build-forja.py'
        s = s.replace(line, '', 1)
    assert len(GFONT_SHEET.findall(s)) == 1, 'the Google Fonts stylesheet link moved — update build-forja.py'
    s = GFONT_SHEET.sub(INJECT_PRE, s, 1)

    assert s.count(SW_GUARD) == 1, 'the service-worker guard moved (or doubled) — update build-forja.py'
    s = s.replace(SW_GUARD, SW_DEAD, 1)

    assert s.count(URL_INDEX) == 1 and s.count(URL_IMGS) == 1, 'the exdb URL constants moved — update build-forja.py'
    s = s.replace(URL_INDEX, "const EXDB_INDEX_URL = 'exdb/exercises.json';   /* app build: bundled */", 1)
    s = s.replace(URL_IMGS, "const EXDB_IMG_PREFIX = 'exdb/';   /* app build: bundled */", 1)

    assert s.count('</head>') == 1 and s.count('</body>') == 1
    s = s.replace('</head>', '<link rel="stylesheet" href="phone.css">\n</head>', 1)
    s = s.replace('</body>', '<script src="phone-boot-post.js"></script>\n</body>', 1)

    assert 'fonts.googleapis.com' not in s and 'fonts.gstatic.com' not in s, 'a Google Fonts reference survived'
    assert 'raw.githubusercontent.com' not in s, 'a network demo URL survived — offline demos would break'
    return s


def files():
    s = source()
    out = {'index.html': build(s).encode('utf-8')}
    for f in SIDECARS:
        out[f] = io.open(os.path.join(HERE, f), 'rb').read()
    for f in sorted(os.listdir(FONT_SRC)):
        if f.endswith('.ttf'):
            out['fonts/' + f] = io.open(os.path.join(FONT_SRC, f), 'rb').read()
    out.update(exdb_bundle(catalog_exdb_names(s)))
    return out


def main():
    want = files()
    if '--check' in sys.argv:
        stale = [p for p, d in want.items() if not os.path.exists(os.path.join(DEST, p)) or io.open(os.path.join(DEST, p), 'rb').read() != d]
        if stale:
            raise SystemExit('bundle STALE (%d files, e.g. %s) — run: python3 ios-forja/build-forja.py' % (len(stale), ', '.join(sorted(stale)[:4])))
        print('bundle current (%d files)' % len(want)); return
    if os.path.isdir(DEST):
        shutil.rmtree(DEST)          # a removed sidecar or image must not linger in the app
    for path, data in want.items():
        p = os.path.join(DEST, path)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        io.open(p, 'wb').write(data)
    imgs = sum(1 for p in want if p.startswith('exdb/') and p.endswith('.jpg'))
    print('bundle: %s (%d files, %d demo frames, %.2f MB)' % (DEST, len(want), imgs, sum(len(d) for d in want.values()) / 1048576))
    print('  index.html sha1 %s' % hashlib.sha1(want['index.html']).hexdigest()[:12])


if __name__ == '__main__':
    main()
