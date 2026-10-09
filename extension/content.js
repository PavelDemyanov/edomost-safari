// content.js — изолированный мир расширения на moedelo.org.
// 1) как можно раньше вставляет inject.js в контекст страницы;
// 2) ретранслирует запросы страница <-> фоновый скрипт расширения.
(function () {
  var api = (typeof browser !== 'undefined') ? browser : chrome;

  // 1. Вставляем page-world шим (inject.js) синхронно в document_start.
  try {
    var s = document.createElement('script');
    s.src = api.runtime.getURL('inject.js');
    s.async = false;
    (document.head || document.documentElement).appendChild(s);
    s.onload = function () { s.remove(); };
  } catch (e) {
    try { console.error('[MoeDeloBridge] inject error', e); } catch (_) {}
  }

  // 2. Запросы из страницы -> background -> ответ обратно в страницу.
  window.addEventListener('message', function (event) {
    if (event.source !== window) return;
    var d = event.data;
    if (!d || d.__mdbridge !== 'request') return;

    // Один запрос — один вызов плагина. Сообщение может прийти дважды (эхо postMessage
    // скриптами страницы или второй экземпляр content-скрипта у дубля расширения) —
    // тогда плагин подписывал/расшифровывал всё по два раза. Метка на <html> общая для
    // всех изолированных миров кадра, поэтому «застолбить» запрос успевает только первый.
    var root = document.documentElement;
    var claim = 'data-mdbridge-' + String(d.id).replace(/[^\w-]/g, '');
    if (root.hasAttribute(claim)) return;
    root.setAttribute(claim, '');
    setTimeout(function () { root.removeAttribute(claim); }, 600000);

    Promise.resolve(api.runtime.sendMessage({ type: 'mdbridge-request', req: d.req }))
      .then(function (result) {
        window.postMessage({ __mdbridge: 'response', id: d.id, result: result }, '*');
      })
      .catch(function (err) {
        window.postMessage({
          __mdbridge: 'response',
          id: d.id,
          error: String((err && err.message) || err)
        }, '*');
      });
  });
})();
