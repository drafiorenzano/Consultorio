// Guarda só a "casca" do app (HTML, CSS, JS, ícones) para abrir rápido.
// Os dados dos pacientes nunca são guardados aqui: vêm sempre da API.
const VERSAO = "consultorio-v3";
const CASCA = [
  "./",
  "index.html",
  "tema.js",
  "tema.css",
  "estilo.css",
  "fontes/fontes.css",
  "anexos.js",
  "app.js",
  "auth.js",
  "base.js",
  "condicoes.js",
  "config.js",
  "entrada.js",
  "grafico.js",
  "lancar.js",
  "nucleo.js",
  "telas.js",
  "icone.svg",
  "manifest.webmanifest",
];

self.addEventListener("install", (e) => {
  e.waitUntil(caches.open(VERSAO).then((c) => c.addAll(CASCA)).then(() => self.skipWaiting()));
});
self.addEventListener("activate", (e) => {
  e.waitUntil(
    caches.keys().then((ks) => Promise.all(ks.filter((k) => k !== VERSAO).map((k) => caches.delete(k))))
      .then(() => self.clients.claim()),
  );
});
self.addEventListener("fetch", (e) => {
  const url = new URL(e.request.url);
  if (e.request.method !== "GET" || url.origin !== location.origin) return;
  // rede primeiro (versão nova assim que publicada); cache se estiver sem internet
  e.respondWith(
    fetch(e.request).then((r) => {
      const copia = r.clone();
      caches.open(VERSAO).then((c) => c.put(e.request, copia));
      return r;
    }).catch(() => caches.match(e.request).then((r) => r ?? caches.match("index.html"))),
  );
});
