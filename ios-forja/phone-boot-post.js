/*  phone-boot-post.js — runs AFTER index.html's script, for things that need the app's DOM and
    globals. Additive: it binds listeners and never redefines app behaviour. Delegated from
    `document`, so it survives every re-render (every screen rebuilds viewRoot wholesale).

    NOT ported from Bitácora on purpose: its touchmove lock. Bitácora is fixed chrome around
    scrolling panes; La Forja scrolls the DOCUMENT, so that lock would freeze every screen. */
(function () {
  function toNative(msg) {
    try { webkit.messageHandlers.forja.postMessage(msg); return true; } catch (e) { return false; }
  }

  /* ── Haptics, by weight ────────────────────────────────────────────────────────────────
     The strike (Done, a checked row, starting the work) is a thud; picking and stepping is a
     tick. The rest-over and hold-done patterns arrive through the vibrate shim instead. */
  function tap(kind) { toNative({ cmd: 'haptic', kind: kind }); }
  document.addEventListener('click', function (e) {
    var t = e.target;
    if (t.closest('[data-act="done-set"], [data-act="finish-hold"], [data-act="lets-go"], [data-act="start-workout"]')) return tap('medium');
    if (t.closest('[data-act="check-row"]')) return tap('medium');
    if (t.closest('[data-act="finish-workout"]')) return tap('success');
    if (t.closest('[data-act="step-w"], [data-act="step-r"], [data-act="rest-bump"], .bottom-tabs .tab, .seg button, [data-act="jump-ex"]')) return tap('selection');
    if (t.closest('button, .pick-row, .feed-card')) return tap('light');
  }, true);

  /* ── The vault talking back ────────────────────────────────────────────────────────────
     A held save is never allowed to be quiet: the whole point of holding is that a human looks.
     `toast` is index.html's own, so the notice wears the app's voice. */
  window.__forjaVaultNotice = function (kind, detail) {
    try {
      if (typeof toast !== 'function') return;
      if (kind === 'shrink') toast('Backup held: this save drops ' + detail + '. Your backup is untouched — answer the alert to accept it.', true);
      else if (kind === 'invalid') toast('Backup refused an unreadable save — your backup is untouched.', true);
    } catch (e) {}
  };

  /* One geometry + font line into the vault log per boot. safe-area insets are 0 in every desktop
     browser, and document.fonts.check() answers true for fonts that do not exist — so measure a
     CONSEQUENCE: the same string in the named family vs an invented one. Equal widths = not loaded. */
  function faceReport() {
    function w(fam) {
      var el = document.createElement('span');
      el.textContent = 'La Forja Hamburgefonstiv 0123';
      el.style.cssText = 'position:absolute;visibility:hidden;white-space:nowrap;font-size:48px;font-family:' + fam;
      document.body.appendChild(el);
      var x = el.getBoundingClientRect().width; el.remove();
      return Math.round(x * 10) / 10;
    }
    var cs = w('"NoSuchFaceXYZ", serif'), s = w('"Instrument Serif", serif');
    var cm = w('"NoSuchFaceXYZ", monospace'), m = w('"JetBrains Mono", monospace');
    return 'serif=' + s + ' vs ' + cs + (s !== cs ? ' LOADED' : ' NOT LOADED') + ' · mono=' + m + ' vs ' + cm + (m !== cm ? ' LOADED' : ' NOT LOADED');
  }
  function geom() {
    var probe = document.createElement('div');
    probe.style.cssText = 'position:fixed;top:0;height:env(safe-area-inset-top);width:env(safe-area-inset-bottom)';
    document.body.appendChild(probe);
    var pr = probe.getBoundingClientRect(); probe.remove();
    toNative({ cmd: 'log', text: 'geom vw=' + innerWidth + ' vh=' + innerHeight + ' safeTop=' + pr.height + ' safeBottom=' + pr.width
      + ' speech=' + (window.SpeechRecognition && window.SpeechRecognition.name) + ' ' + faceReport() });
  }
  if (document.readyState === 'complete') setTimeout(geom, 400);
  else window.addEventListener('load', function () { setTimeout(geom, 400); });

  toNative({ cmd: 'ready' });
})();
