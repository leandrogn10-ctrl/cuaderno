// El Cuaderno service worker — offline-first shell + runtime caches for fonts and exercise media.
// Bump CACHE_NAME to force-refresh clients; FONT/MEDIA caches survive bumps (immutable assets).
const CACHE_NAME = 'cuaderno-v7';
const FONT_CACHE = 'cuaderno-fonts-v1';
const MEDIA_CACHE = 'cuaderno-media-v1';
const KEEP_CACHES = [CACHE_NAME, FONT_CACHE, MEDIA_CACHE];
const APP_SHELL = ['./', './index.html'];
const MEDIA_MAX = 300;   // ~2 frames × 150 exercises

const FONT_HOSTS = ['fonts.googleapis.com', 'fonts.gstatic.com'];
const MEDIA_HOSTS = ['raw.githubusercontent.com', 'i.ytimg.com'];
const PASS_HOSTS = ['api.github.com', 'api.anthropic.com', 'www.youtube-nocookie.com', 'www.youtube.com'];

self.addEventListener('install', e => {
  e.waitUntil(
    caches.open(CACHE_NAME).then(c => c.addAll(APP_SHELL).catch(() => {}))
  );
  self.skipWaiting();
});

self.addEventListener('activate', e => {
  e.waitUntil(
    caches.keys().then(keys =>
      Promise.all(keys.filter(k => !KEEP_CACHES.includes(k)).map(k => caches.delete(k)))
    ).then(() => self.clients.claim())
  );
});

self.addEventListener('message', e => {
  if (e.data?.type === 'SKIP_WAITING') self.skipWaiting();
});

// cache-first for immutable cross-origin assets; opaque responses are cached too
async function cacheFirst(req, cacheName, maxEntries = null) {
  const cache = await caches.open(cacheName);
  const hit = await cache.match(req);
  if (hit) return hit;
  const res = await fetch(req);
  if (res && (res.status === 200 || res.type === 'opaque')) {
    cache.put(req, res.clone()).then(async () => {
      if (maxEntries) {
        const keys = await cache.keys();
        for (let i = 0; i < keys.length - maxEntries; i++) cache.delete(keys[i]);
      }
    }).catch(() => {});
  }
  return res;
}

self.addEventListener('fetch', e => {
  const req = e.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);

  if (PASS_HOSTS.includes(url.hostname)) return;                 // auth'd APIs / streaming — never cache
  if (FONT_HOSTS.includes(url.hostname)) {
    e.respondWith(cacheFirst(req, FONT_CACHE).catch(() => caches.match(req)));
    return;
  }
  if (MEDIA_HOSTS.includes(url.hostname)) {
    e.respondWith(cacheFirst(req, MEDIA_CACHE, MEDIA_MAX).catch(() => caches.match(req)));
    return;
  }
  if (url.origin !== location.origin) return;                    // other cross-origin: browser default

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

  // Other same-origin assets: cache-first
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
