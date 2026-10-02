// DandyRecords kiosk — service worker
// Garde sur l'iPad les pochettes, les polices et la page elle-même :
//  - pochettes : servies depuis l'iPad dès qu'elles y sont (instantané, marche sans réseau)
//  - page : toujours la version en ligne si le réseau répond vite, sinon la copie gardée
// Le Google Sheets et les MP3 ne passent pas par ici (toujours en direct).
const VERSION = 'v1';
const COVERS = 'dandy-covers';          // pas de version : les pochettes survivent aux mises à jour du kiosk
const STATIC = `dandy-static-${VERSION}`;
const PAGE_TIMEOUT_MS = 4000;

self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', e => {
  e.waitUntil((async () => {
    for (const k of await caches.keys()) if (k !== COVERS && k !== STATIC) await caches.delete(k);
    await self.clients.claim();
  })());
});

self.addEventListener('fetch', e => {
  const req = e.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);

  if (req.mode === 'navigate') { e.respondWith(pageNetworkFirst(req)); return; }
  if (/fonts\.(googleapis|gstatic)\.com$/.test(url.hostname)) { e.respondWith(cacheFirst(STATIC, req)); return; }
  if (req.destination === 'image' && url.origin !== location.origin) { e.respondWith(cacheFirst(COVERS, req)); return; }
});

async function cacheFirst(name, req) {
  const cache = await caches.open(name);
  const hit = await cache.match(req, { ignoreVary: true });
  if (hit) return hit;
  const res = await fetch(req);
  if (res.ok || res.type === 'opaque') cache.put(req, res.clone()).catch(() => {});
  return res;
}

async function pageNetworkFirst(req) {
  const cache = await caches.open(STATIC);
  const key = new URL(req.url); key.search = '';     // ?check et autres paramètres → même page
  try {
    const res = await Promise.race([
      fetch(req),
      new Promise((_, rej) => setTimeout(() => rej(new Error('timeout')), PAGE_TIMEOUT_MS)),
    ]);
    if (res.ok) cache.put(key.href, res.clone()).catch(() => {});
    return res;
  } catch (err) {
    const hit = await cache.match(key.href);
    if (hit) return hit;
    throw err;
  }
}

// La page envoie la liste des pochettes du catalogue : on télécharge celles qui manquent
// (3 à la fois, en arrière-plan) et on supprime celles des disques qui ne sont plus en stock.
self.addEventListener('message', e => {
  if (e.data?.type === 'precache-covers') e.waitUntil(precacheCovers(e.data.urls || [], e.source));
});

let running = null;
async function precacheCovers(urls, client) {
  if (running) return running;
  running = (async () => {
    const cache = await caches.open(COVERS);
    const wanted = new Set(urls.map(u => new URL(u, location.href).href));
    for (const req of await cache.keys()) if (!wanted.has(req.url)) await cache.delete(req);
    const have = new Set((await cache.keys()).map(r => r.url));
    const todo = [...wanted].filter(u => !have.has(u));
    let done = wanted.size - todo.length;
    const worker = async () => {
      for (let u; (u = todo.shift()); ) {
        try {
          const res = await fetch(u, { mode: 'no-cors', credentials: 'omit' });
          if (res.ok || res.type === 'opaque') await cache.put(u, res);
        } catch (_) { /* réseau absent : on réessaiera au prochain lancement */ }
        done++;
      }
    };
    await Promise.all([worker(), worker(), worker()]);
    client?.postMessage({ type: 'covers-cached', done, total: wanted.size });
  })();
  try { return await running; } finally { running = null; }
}
