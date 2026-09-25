/*  test-bridge.js — the JS half of the app, run against the REAL mic handler from ../index.html.

      node ios-forja/test-bridge.js

    The failure this exists for: the debrief textarea silently LOSING or DUPLICATING spoken text at
    the seam between iOS's recognizer (which re-segments and restarts) and the page's Web Speech
    handler. So setupDebriefMic is extracted from index.html by name — asserted declared exactly once,
    so the harness runs the definition the page runs — and driven with the callback sequences native
    sends. Each load-bearing check is followed by a CONTROL that re-plants the naive shim and must go red. */
'use strict';
const fs = require('fs'), path = require('path'), vm = require('vm');
const HERE = __dirname;
const PRE = fs.readFileSync(path.join(HERE, 'phone-boot-pre.js'), 'utf8');
const INDEX = fs.readFileSync(path.join(HERE, '..', 'index.html'), 'utf8');

let checks = 0, failures = 0;
function ok(cond, what, extra) { checks++; if (cond) console.log('  ok   ' + what); else { failures++; console.log('  FAIL ' + what + (extra ? '  >> ' + extra : '')); } }

/* ── pull the page's own code by name ── */
function extract(name) {
  const re = new RegExp('^(?:async )?function ' + name + '\\(', 'gm');
  const hits = INDEX.match(re) || [];
  if (hits.length !== 1) throw new Error(name + ' is declared ' + hits.length + ' times in index.html — the harness would not know which one runs');
  const a = INDEX.search(new RegExp('^(?:async )?function ' + name + '\\(', 'm'));
  return INDEX.slice(a, INDEX.indexOf('\n}\n', a) + 2);
}
function extractConst(name) {
  const a = INDEX.indexOf('\nconst ' + name + ' = {');
  if (a < 0 || INDEX.indexOf('\nconst ' + name + ' = {', a + 1) >= 0) throw new Error('const ' + name + ' not found exactly once');
  return INDEX.slice(a + 1, INDEX.indexOf('\n};\n', a) + 3);
}
function extractLine(prefix) {
  const lines = INDEX.split('\n').filter(l => l.startsWith(prefix));
  if (lines.length !== 1) throw new Error(prefix + ' found ' + lines.length + ' times');
  return lines[0].replace(/^const /, 'var ');   // var: it must land on the context's global, like the page's top level
}
const PAGE = [extractLine('const DB_CTX = '), extract('setupDebriefMic'), extract('micStatus'), extractConst('MIC_MSG').replace(/^const /, 'var ')].join('\n');

/* ── a world: window + localStorage + the native bridge, recorded ── */
function world(preSource, vault) {
  const sent = [];
  const store = {};
  function Storage() {}
  Storage.prototype.getItem = function (k) { return Object.prototype.hasOwnProperty.call(store, k) ? store[k] : null; };
  Storage.prototype.setItem = function (k, v) { store[k] = String(v); };
  const el = id => (els[id] = els[id] || { id, value: '', hidden: false, textContent: '', style: {}, onclick: null,
    classList: { _s: new Set(), add(c) { this._s.add(c); }, remove(c) { this._s.delete(c); }, contains(c) { return this._s.has(c); } } });
  const els = {};
  const ctx = {
    console, Array, Object, String, Number, JSON, Math, Date, Promise, Uint8Array, TextDecoder, atob,
    setTimeout: (f) => f && 0, clearTimeout() {},
    localStorage: new Storage(), Storage,
    webkit: { messageHandlers: { forja: { postMessage: m => sent.push(m) } } },
    navigator: { userAgent: 'test' },
    document: { getElementById: el },
    DOMException: class extends Error { constructor(m, n) { super(m); this.name = n; } },
    __FORJA_VAULT__: vault || null,
    state: { settings: { micLang: 'en-US' } },
    renderMicLang() {}, isClaudeEnabled() { return false; }, losWarn() {},
  };
  ctx.window = ctx;
  vm.createContext(ctx);
  vm.runInContext(preSource, ctx);
  vm.runInContext(PAGE, ctx);
  return { ctx, sent, store, els: new Proxy({}, { get: (_, k) => el(k) }) };
}
/* drive one dictation: tap Record, then play native's callbacks */
function dictate(preSource, base, events) {
  const w = world(preSource);
  w.els['db-text'].value = base;
  vm.runInContext('setupDebriefMic()', w.ctx);
  w.els['db-mic'].onclick();
  const start = w.sent.find(m => m.cmd === 'speech' && m.op === 'start');
  for (const [kind, text, fin] of events) w.ctx.__forjaSpeech(start.id, kind, text, fin);
  return { w, start, value: w.els['db-text'].value };
}

console.log('\n── the page\'s mic handler runs on the shim ──');
{
  const w = world(PRE);
  ok(w.ctx.SpeechRecognition && w.ctx.SpeechRecognition.name === 'ForjaSpeechRecognition', 'window.SpeechRecognition is the native-backed shim');
  ok(w.ctx.webkitSpeechRecognition === w.ctx.SpeechRecognition, 'webkitSpeechRecognition is replaced too (WKWebView may define a dead one)');
  const r = dictate(PRE, '', [['start'], ['result', 'felt strong', false], ['result', 'felt strong today', true], ['end']]);
  ok(r.start && r.start.lang === 'en-US' && r.start.continuous === true && r.start.interim === true, 'Record sends start with the page\'s lang/continuous/interim', JSON.stringify(r.start));
  ok(r.value === 'felt strong today', 'partials settle into the final transcript', JSON.stringify(r.value));
  ok(r.w.els['db-mic'].textContent === 'Record', 'the button resets when native ends the session', r.w.els['db-mic'].textContent);
}

console.log('\n── the seam: iOS re-segments mid-dictation (the next partial comes back SHORTER) ──');
const RESEG = [['start'], ['result', 'felt good', false], ['result', 'felt good today, slept eight hours', false],
  ['result', 'the curls', false], ['result', 'the curls were heavy', false], ['result', 'the curls were heavy on the last set', true], ['end']];
{
  const r = dictate(PRE, 'Before.', RESEG);
  ok(r.value === 'Before. felt good today, slept eight hours the curls were heavy on the last set',
     'nothing spoken is lost across a re-segmentation, and text already in the box stays', JSON.stringify(r.value));
  // CONTROL — re-plant the naive shim (one result, always replaced) and prove the check can see the loss.
  const naive = PRE.replace(/if \(prev && t\.length < 0\.6 \* prev\.length && prev\.indexOf\(t\) !== 0\) \{[\s\S]*?\n          \}/, '');
  ok(naive !== PRE, 'CONTROL fixture: the re-segmentation branch was actually removed from the planted copy');
  const n = dictate(naive, 'Before.', RESEG);
  ok(!/slept eight hours/.test(n.value), 'CONTROL: the naive shim DOES drop "slept eight hours" (so the check above can see it)', JSON.stringify(n.value));
}

console.log('\n── the seam: a segment closes on its own (60s cap) and listening carries on ──');
{
  const r = dictate(PRE, '', [['start'], ['result', 'first minute of talking', false], ['result', 'first minute of talking', true],
    ['result', 'and then more', false], ['result', 'and then more', true], ['end']]);
  ok(r.value === 'first minute of talking and then more', 'a closed segment is kept and the next one appends — no duplicate, no loss', JSON.stringify(r.value));
}

console.log('\n── failures say what happened ──');
{
  const r = dictate(PRE, '', [['error', 'not-allowed', 'microphone permission is off'], ['end']]);
  ok(!r.w.els['db-mic-status'].hidden && /blocked/.test(r.w.els['db-mic-status'].textContent), 'a denied mic is reported in the page\'s words', r.w.els['db-mic-status'].textContent);
  const s = dictate(PRE, '', [['start'], ['end']]);
  ok(/isn't hearing/.test(s.w.els['db-mic-status'].textContent), 'a session that heard nothing says so', s.w.els['db-mic-status'].textContent);
}

console.log('\n── the vault hook and restore ──');
{
  const w = world(PRE);
  w.ctx.localStorage.setItem('cuaderno.v1', '{"lastModified":5}');
  w.ctx.localStorage.setItem('cuaderno.exdb.v3', '{}');
  const saves = w.sent.filter(m => m.cmd === 'save');
  ok(saves.length === 1 && saves[0].json === '{"lastModified":5}', 'only the state key is mirrored to the vault', JSON.stringify(saves.map(s => s.json)));

  const newer = world(PRE, { json: '{"lastModified":9,"sessions":[]}', lastModified: 9, sets: 0 });
  ok(newer.store['cuaderno.v1'] === '{"lastModified":9,"sessions":[]}', 'an empty webview restores from the vault');
  const pre2 = 'localStorage.setItem("cuaderno.v1", "{\\"lastModified\\":20}");\n';
  const local = (() => { const x = world(pre2 + PRE, { json: '{"lastModified":9}', lastModified: 9 }); return x.store['cuaderno.v1']; })();
  ok(local === '{"lastModified":20}', 'a NEWER local state is not overwritten by an older vault', local);
  const corrupt = world('localStorage.setItem("cuaderno.v1", "{not json");\n' + PRE, { json: '{"lastModified":9}', lastModified: 9 });
  const q = Object.keys(corrupt.store).find(k => k.startsWith('cuaderno.v1.corrupt.'));
  ok(q && corrupt.store[q] === '{not json' && corrupt.store['cuaderno.v1'] === '{"lastModified":9}', 'a corrupt local copy is quarantined, then the vault restores');
}

console.log('\n── vibrate ──');
{
  const w = world(PRE);
  w.ctx.navigator.vibrate([200, 100, 200]); w.ctx.navigator.vibrate(60);
  const h = w.sent.filter(m => m.cmd === 'haptic').map(m => m.kind);
  ok(h.join() === 'success,light', 'rest-over pattern → success haptic, a count tick → light', h.join());
}

console.log('\n' + (checks - failures) + '/' + checks + ' checks passed');
if (failures) { console.log('BRIDGE GATE RED\n'); process.exit(1); }
console.log('bridge gate green\n');
