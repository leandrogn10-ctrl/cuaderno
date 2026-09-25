/*  phone-boot-pre.js — runs BEFORE index.html's own script, which matters for every job here:
    the vault must restore before the app reads localStorage, and the shims must exist before the
    app tests for them (setupDebriefMic reads window.SpeechRecognition when a sheet opens).

    Additive only. index.html is never edited for the app's benefit; everything here fills a hole a
    WKWebView has (no Web Speech, no vibrate) or protects data the webview can lose. */
(function () {
  var KEY = 'cuaderno.v1';

  function toNative(msg) {
    try { webkit.messageHandlers.forja.postMessage(msg); return true; }
    catch (e) { return false; }           // a plain browser: everything below no-ops
  }
  var inApp = (function () { try { return !!webkit.messageHandlers.forja; } catch (e) { return false; } })();

  /* ── 1. Restore ────────────────────────────────────────────────────────────────────────
     Native injected window.__FORJA_VAULT__ at document-start. NEWEST VALID WINS, and a local copy
     that will not parse is QUARANTINED under its own key, never overwritten — the one thing worse
     than a corrupt log is a corrupt log we destroyed while replacing it. */
  try {
    var v = window.__FORJA_VAULT__ || null;
    var raw = null;
    try { raw = localStorage.getItem(KEY); } catch (e) { raw = null; }
    var localMod = -1;                     // -1 = nothing usable here (missing OR corrupt)
    if (raw != null) {
      try {
        var parsed = JSON.parse(raw);
        localMod = (parsed && typeof parsed.lastModified === 'number') ? parsed.lastModified : 0;
      } catch (e) {
        try { localStorage.setItem(KEY + '.corrupt.' + Date.now(), raw); } catch (e2) {}
        toNative({ cmd: 'log', text: 'local state failed to parse — quarantined, not overwritten' });
        localMod = -1;
      }
    }
    if (v && v.json) {
      var vaultMod = (typeof v.lastModified === 'number') ? v.lastModified : 0;
      if (localMod < 0 || vaultMod > localMod) {
        localStorage.setItem(KEY, v.json);
        toNative({ cmd: 'log', text: 'restored from vault (local=' + localMod + ' vault=' + vaultMod + ', ' + (v.sets || '?') + ' sets)' });
      }
    }
  } catch (e) {
    toNative({ cmd: 'log', text: 'restore threw: ' + e });
  }

  /* ── 2. Mirror every write to the vault ────────────────────────────────────────────────
     Hooked at the STORAGE boundary, not at the app's save(): the runner, the gist pull, the
     importer and the schema migration all end at this one call. Native also reads the live
     workout out of each save to arm the rest notification and keep the screen awake. */
  try {
    var proto = Object.getPrototypeOf(localStorage) || window.Storage.prototype;
    var orig = proto.setItem;
    proto.setItem = function (k, val) {
      var r = orig.apply(this, arguments);
      if (k === KEY) toNative({ cmd: 'save', json: String(val) });
      return r;
    };
  } catch (e) {
    toNative({ cmd: 'log', text: 'could not hook setItem: ' + e });
  }

  if (!inApp) return;

  /* ── 3. Speech ─────────────────────────────────────────────────────────────────────────
     WKWebView ships no working Web Speech API — which is why the debrief mic went blank in Chrome
     on the iPhone (Chrome there IS a WKWebView). This class speaks the slice of the Web Speech
     surface the app uses, and iOS's own recognizer does the listening (Speech.swift).
     iOS hands back the whole transcript-so-far on every callback, so it is exposed as ONE result
     that keeps being replaced: the app's handler (base + finals + interim) stays correct as-is. */
  var seq = 0, live = {};
  window.__forjaSpeech = function (id, kind, text, isFinal) {
    var r = live[id]; if (!r) return;
    try {
      if (kind === 'start') { r.onstart && r.onstart({ type: 'start' }); return; }
      if (kind === 'result') {
        var t = String(text || ''), rs = r._results, cur = rs[rs.length - 1];
        if (!cur || cur.isFinal) { cur = [{ transcript: '', confidence: 1 }]; cur.isFinal = false; rs.push(cur); }
        else {
          var prev = cur[0].transcript;
          // iOS re-segmented: the new partial is much shorter and not a continuation of what's on
          // screen. Freeze what we had as final instead of letting it be overwritten.
          if (prev && t.length < 0.6 * prev.length && prev.indexOf(t) !== 0) {
            cur.isFinal = true; cur = [{ transcript: '', confidence: 1 }]; cur.isFinal = false; rs.push(cur);
          }
        }
        cur[0].transcript = t; cur.isFinal = !!isFinal;
        r.onresult && r.onresult({ type: 'result', resultIndex: rs.length - 1, results: rs });
        return;
      }
      if (kind === 'error') { r.onerror && r.onerror({ type: 'error', error: String(text || 'unknown'), message: String(isFinal || '') }); return; }
      if (kind === 'end') { delete live[id]; r._id = 0; r.onend && r.onend({ type: 'end' }); }
    } catch (e) { toNative({ cmd: 'log', text: 'speech handler threw: ' + e }); }
  };
  function ForjaSpeechRecognition() {
    this.lang = 'en-US'; this.continuous = false; this.interimResults = false; this.maxAlternatives = 1;
    this.onstart = this.onresult = this.onerror = this.onend = null;
    this._id = 0;
  }
  ForjaSpeechRecognition.prototype.start = function () {
    if (this._id) throw new DOMException('recognition has already started', 'InvalidStateError');
    var id = ++seq; this._id = id; this._results = []; live[id] = this;
    toNative({ cmd: 'speech', op: 'start', id: id, lang: String(this.lang || 'en-US'), interim: !!this.interimResults, continuous: !!this.continuous });
  };
  ForjaSpeechRecognition.prototype.stop = function () { if (this._id) toNative({ cmd: 'speech', op: 'stop', id: this._id }); };
  ForjaSpeechRecognition.prototype.abort = function () { if (this._id) toNative({ cmd: 'speech', op: 'abort', id: this._id }); };
  try {
    window.SpeechRecognition = ForjaSpeechRecognition;
    window.webkitSpeechRecognition = ForjaSpeechRecognition;
  } catch (e) {}

  /* ── 4. Vibrate ────────────────────────────────────────────────────────────────────────
     The runner already calls navigator.vibrate on the 3-2-1 ticks and when rest runs out; a
     WKWebView has no vibrate, so those calls were silent. A pattern (rest over, hold done) is the
     success haptic; a single pulse (a count tick) is a light tap. */
  try {
    navigator.vibrate = function (p) {
      var n = Array.isArray(p) ? p.filter(function (x, i) { return i % 2 === 0 && x > 0; }).length : (p > 0 ? 1 : 0);
      if (n) toNative({ cmd: 'haptic', kind: n > 1 ? 'success' : 'light' });
      return true;
    };
  } catch (e) {}
})();
