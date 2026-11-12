// Testes do PWA (T11): manifest válido e comportamento REAL do service worker executado em um sandbox (node:vm)
// com cache/fetch simulados. Rodar depois do build: npm run test:pwa -w @clinicflow/web
import assert from 'node:assert/strict';
import { readFileSync, existsSync } from 'node:fs';
import { test } from 'node:test';
import vm from 'node:vm';

const dist = new URL('../dist/', import.meta.url);
const read = (p) => readFileSync(new URL(p, dist), 'utf8');

test('manifest: campos obrigatórios, ícones existentes e pt-BR', () => {
  const m = JSON.parse(read('manifest.webmanifest'));
  assert.equal(m.lang, 'pt-BR'); assert.equal(m.display, 'standalone'); assert.equal(m.start_url, '/'); assert.ok(m.name && m.short_name);
  const sizes = m.icons.map((i) => i.sizes);
  assert.ok(sizes.includes('192x192') && sizes.includes('512x512'));
  for (const i of m.icons) {
    assert.ok(existsSync(new URL(i.src.slice(1), dist)), i.src);
    const b = readFileSync(new URL(i.src.slice(1), dist));
    assert.equal(b.subarray(1, 4).toString(), 'PNG');
    assert.equal(b.readUInt32BE(16), Number(i.sizes.split('x')[0]));
  }
});

test('index.html referencia manifest e theme-color', () => {
  const h = read('index.html');
  assert.match(h, /rel="manifest" href="\/manifest\.webmanifest"/); assert.match(h, /name="theme-color"/);
});

function makeSW() {
  const listeners = {}; const store = new Map(); const shown = []; const puts = []; const opened = []; const fetched = [];
  const cacheApi = {
    async open() { return { async addAll(urls) { urls.forEach((u) => store.set(u, new FakeRes(200, 'basic'))); }, async put(req, res) { puts.push(req.url); store.set(new URL(req.url).pathname, res); } }; },
    async match(req) { const k = typeof req === 'string' ? req : new URL(req.url).pathname; return store.get(k); },
    async keys() { return ['cf-shell-v0', 'cf-shell-v1']; }, async delete(k) { store.delete('del:' + k); return true; },
  };
  class FakeRes { constructor(s, t) { this.status = s; this.type = t; this.ok = s >= 200 && s < 300; } clone() { return this; } static error() { return new FakeRes(0, 'error'); } }
  const self = {
    location: { origin: 'https://app.test' }, addEventListener: (t, f) => { listeners[t] = f; }, skipWaiting: async () => {},
    clients: { claim: async () => {}, openWindow: async (u) => { opened.push(u); } },
    registration: { showNotification: async (title, o) => { shown.push({ title, ...o }); } },
  };
  const ctx = vm.createContext({ self, caches: cacheApi, Response: FakeRes, URL, fetch: async (req) => { fetched.push(req.url); return new FakeRes(200, 'basic'); }, Promise });
  vm.runInContext(readFileSync(new URL('sw.js', dist), 'utf8'), ctx);
  const fire = async (type, ev) => { let p; ev.waitUntil = (x) => { p = x; }; ev.respondWith = (x) => { ev.responded = true; p = x; }; listeners[type](ev); await p; return ev; };
  const req = (path, o = {}) => ({ url: 'https://app.test' + path, method: o.method ?? 'GET', mode: o.mode ?? 'cors', headers: { has: (h) => (o.headers ?? []).includes(h) } });
  return { fire, req, shown, puts, opened, fetched, listeners, store };
}

test('SW: requisições da API, outra origem, autenticadas e não-GET passam direto (nunca respondidas nem guardadas pelo SW)', async () => {
  const sw = makeSW();
  for (const r of [sw.req('/api/portal/orgs/x/patients/y/appointments'), sw.req('/api/me'), { ...sw.req('/x'), url: 'https://abc.supabase.co/auth/v1/token' },
    sw.req('/assets/app.js', { headers: ['authorization'] }), sw.req('/api/org/units', { method: 'POST' })]) {
    const ev = await sw.fire('fetch', { request: r });
    assert.notEqual(ev.responded, true, r.url);
  }
  assert.equal(sw.puts.length, 0);
});

test('SW: estáticos com hash são guardados; navegação offline cai no casco', async () => {
  const sw = makeSW();
  const ev = await sw.fire('fetch', { request: sw.req('/assets/index-abc.js') });
  assert.equal(ev.responded, true); assert.deepEqual(sw.puts, ['https://app.test/assets/index-abc.js']);
  const nav = await sw.fire('fetch', { request: sw.req('/portal', { mode: 'navigate' }) });
  assert.equal(nav.responded, true);
});

test('SW: push é genérico e ignora o conteúdo do payload; clique abre a raiz', async () => {
  const sw = makeSW();
  await sw.fire('push', { data: { text: () => 'Consulta de cardiologia com Dr. João amanhã', json: () => ({ title: 'x' }) } });
  assert.equal(sw.shown.length, 1);
  const txt = JSON.stringify(sw.shown[0]);
  assert.ok(!/cardiolog|Jo[aã]o|consulta|amanh/i.test(txt), txt);
  assert.equal(sw.shown[0].tag, 'cf-generic');
  await sw.fire('notificationclick', { notification: { close() {} } });
  assert.deepEqual(sw.opened, ['/']);
});

test('SW: o código não grava nem lê dados da API/armazenamento do usuário', () => {
  const src = read('sw.js');
  for (const bad of ['localStorage', 'indexedDB', 'Authorization', 'access_token', '/api/']) {
    const hits = src.split('\n').filter((l) => l.includes(bad) && !l.trim().startsWith('//'));
    // '/api/' só aparece na regra que EXCLUI a API do cache
    if (bad === '/api/') assert.ok(hits.every((l) => l.includes("startsWith('/api/')")), hits.join('\n'));
    else assert.equal(hits.length, 0, `${bad}: ${hits.join('\n')}`);
  }
});

test('headers de segurança publicados (CSP, nosniff, sw sem cache, api sem cache)', () => {
  const h = read('_headers');
  assert.match(h, /Content-Security-Policy: default-src 'self'/); assert.match(h, /frame-ancestors 'none'/);
  assert.match(h, /\/sw\.js\n\s+Cache-Control: no-cache/); assert.match(h, /\/api\/\*\n\s+Cache-Control: no-store/);
});
