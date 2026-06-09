// background.js — service worker расширения.
// Принимает запрос от content-script и сам делает HTTP-вызов к локальному
// плагину. Запрос идёт из контекста расширения (host_permissions на 127.0.0.1),
// поэтому запрет Safari на mixed content со страницы https не действует.
var api = (typeof browser !== 'undefined') ? browser : chrome;

api.runtime.onMessage.addListener(function (message, sender) {
  if (!message || message.type !== 'mdbridge-request') return;

  var req = message.req || {};
  var method = (req.method || 'GET').toUpperCase();
  var init = {
    method: method,
    headers: req.headers || {},
    cache: 'no-store',
    credentials: 'omit'
  };
  if (req.body != null && method !== 'GET' && method !== 'HEAD') {
    init.body = req.body;
  }

  return fetch(req.url, init)
    .then(function (r) {
      var headers = {};
      try { r.headers.forEach(function (v, k) { headers[k] = v; }); } catch (e) {}
      return r.text().then(function (body) {
        return {
          status: r.status,
          statusText: r.statusText || '',
          headers: headers,
          body: body
        };
      });
    })
    .catch(function (err) {
      return { error: String((err && err.message) || err) };
    });
});
