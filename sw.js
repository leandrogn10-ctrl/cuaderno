// App-shell service worker — offline-first for the app shell, pass-through for APIs.
// SLOT: rename CACHE_NAME per app (e.g. 'cuaderno-v4') and bump the suffix to force-refresh clients.
const CACHE_NAME = 'cuaderno-v4';
const APP_SHELL = ['./', './index.html'];

self.addEventListener('install', e => {
  e.waitUntil(
    caches.open(CACHE_NAME).then(c => c.addAll(APP_SHELL).catch(() => {}))
  );
  self.skipWaiting();
});

self.addEventListener('activate', e => {
  e.waitUntil(
    caches.keys().then(keys =>
      Promise.all(keys.filter(k => k !== CACHE_NAME).map(k => caches.delete(k)))
    ).then(() => self.clients.claim())
  );
});

self.addEventListener('message', e => {
  if (e.data?.type === 'SKIP_WAITING') self.skipWaiting();
});

self.addEventListener('fetch', e => {
  const req = e.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);

  // Pass-through for API calls — never cache
  if (url.hostname === 'api.github.com' || url.hostname === 'api.anthropic.com') return;
  // Cross-origin (Google Fonts, etc.) — let the browser/HTTP cache handle it
  if (url.origin !== location.origin) return;

  // HTML / navigation: network-first so a fresh push is seen immediately, fallback to cache when offline
  const isHTML = req.mode === 'navigate' || (req.headers.get('Accept') || '').includes('text/html') || url.pathname.endsWith('/') || url.pathname.endsWith('.html');
  if (isHTML) {
    e.respondWith(
      fetch(req).then(res => {
        if (res && res.status === 200) {
          const clone = res.clone();
          caches.open(CACHE_NAME).then(c => c.put(req, clone));
        }
        return res;
      }).catch(() => caches.match(req).then(c => c || caches.match('./index.html')))
    );
    return;
  }

  // Other same-origin assets (sw.js itself, future files): cache-first
  e.respondWith(
    caches.match(req).then(cached => cached || fetch(req).then(res => {
      if (res && res.status === 200) {
        const clone = res.clone();
        caches.open(CACHE_NAME).then(c => c.put(req, clone));
      }
      return res;
    }).catch(() => cached))
  );
});
