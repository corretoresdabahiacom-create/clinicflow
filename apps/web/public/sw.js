// Service worker do ClinicFlow (T11): guarda SOMENTE o "casco" estático do app (HTML, JS/CSS com hash, ícones).
// Nunca guarda respostas da API, de outra origem (Supabase, Turnstile) ou requisições autenticadas:
// nenhum dado de paciente, agendamento ou clínico chega ao cache do dispositivo.
const VERSION = 'cf-shell-v1';
const SHELL = ['/', '/manifest.webmanifest', '/icons/icon-192.png', '/icons/icon-512.png'];

self.addEventListener('install', (e) => {
  e.waitUntil(caches.open(VERSION).then((c) => c.addAll(SHELL)).then(() => self.skipWaiting()));
});

self.addEventListener('activate', (e) => {
  e.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(keys.filter((k) => k !== VERSION).map((k) => caches.delete(k))))
      .then(() => self.clients.claim()),
  );
});

// Ao sair da conta o app pede a limpeza total (defesa em profundidade; o cache já não tem dados pessoais).
self.addEventListener('message', (e) => {
  if (e.data && e.data.type === 'clear-caches') {
    e.waitUntil(caches.keys().then((keys) => Promise.all(keys.map((k) => caches.delete(k)))));
  }
});

self.addEventListener('fetch', (e) => {
  const req = e.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);
  if (url.origin !== self.location.origin) return;
  if (url.pathname.startsWith('/api/') || req.headers.has('authorization')) return;

  if (req.mode === 'navigate') {
    // Sempre a rede primeiro; offline, mostra o casco (que pede login e não contém dados).
    e.respondWith(fetch(req).catch(() => caches.match('/').then((r) => r || Response.error())));
    return;
  }
  if (url.pathname.startsWith('/assets/') || SHELL.includes(url.pathname)) {
    e.respondWith(
      caches.match(req).then((hit) => hit || fetch(req).then((res) => {
        if (res.ok && res.type === 'basic') {
          const copy = res.clone();
          caches.open(VERSION).then((c) => c.put(req, copy));
        }
        return res;
      })),
    );
  }
});

// Push GENÉRICO: o conteúdo do payload é ignorado de propósito; a notificação nunca revela dado de saúde.
self.addEventListener('push', (e) => {
  e.waitUntil(self.registration.showNotification('ClinicFlow', {
    body: 'Você tem uma atualização. Abra o aplicativo para ver.',
    icon: '/icons/icon-192.png',
    tag: 'cf-generic',
  }));
});

self.addEventListener('notificationclick', (e) => {
  e.notification.close();
  e.waitUntil(self.clients.openWindow('/'));
});
