// inject.js — выполняется в КОНТЕКСТЕ СТРАНИЦЫ moedelo.org.
// Перехватывает fetch/XMLHttpRequest к локальному плагину (http://127.0.0.1:1808x)
// и проксирует их через расширение -> нативный код (минуя запрет Safari на mixed content).
(function () {
  if (window.__mdBridgeInstalled) return;
  window.__mdBridgeInstalled = true;

  // Плагин слушает 127.0.0.1:18080. Берём диапазон 18080-18099 на случай иной версии.
  var TARGET = /^https?:\/\/(127\.0\.0\.1|localhost):(1808\d|1809\d)\b/i;

  var seq = 0;
  var pending = new Map();

  window.addEventListener('message', function (event) {
    if (event.source !== window) return;
    var d = event.data;
    if (!d || d.__mdbridge !== 'response') return;
    var p = pending.get(d.id);
    if (!p) return;
    pending.delete(d.id);
    if (d.error) p.reject(new Error(d.error));
    else p.resolve(d.result);
  });

  function bridge(req) {
    return new Promise(function (resolve, reject) {
      var id = 'mdb' + (++seq);
      pending.set(id, { resolve: resolve, reject: reject });
      window.postMessage({ __mdbridge: 'request', id: id, req: req }, '*');
      setTimeout(function () {
        if (pending.has(id)) {
          pending.delete(id);
          reject(new Error('MoeDelo bridge timeout'));
        }
      }, 180000);
    });
  }

  function headersToObject(h) {
    var out = {};
    if (!h) return out;
    try {
      if (typeof Headers !== 'undefined' && h instanceof Headers) {
        h.forEach(function (v, k) { out[k] = v; });
      } else if (Array.isArray(h)) {
        h.forEach(function (pair) { out[pair[0]] = pair[1]; });
      } else if (typeof h === 'object') {
        for (var k in h) { if (Object.prototype.hasOwnProperty.call(h, k)) out[k] = h[k]; }
      }
    } catch (e) {}
    return out;
  }

  function buildResponse(r) {
    var headers = {};
    var ct = null;
    if (r.headers) {
      for (var k in r.headers) {
        if (/^content-type$/i.test(k)) ct = r.headers[k];
      }
    }
    if (ct) headers['Content-Type'] = ct; // только безопасный заголовок, чтобы Response не бросал
    return new Response(r.body != null ? r.body : '', {
      status: r.status || 200,
      statusText: r.statusText || '',
      headers: headers
    });
  }

  // ---- fetch ----
  var origFetch = window.fetch ? window.fetch.bind(window) : null;
  if (origFetch) {
    window.fetch = function (input, init) {
      try {
        var url = (typeof input === 'string') ? input
                : (input && typeof input.url === 'string') ? input.url : null;
        if (url && TARGET.test(url)) {
          var method = (init && init.method)
                     || (input && input.method) || 'GET';
          var headers = headersToObject((init && init.headers) || (input && input.headers));
          var body = (init && init.body != null) ? init.body : null;
          return bridge({
            url: url,
            method: String(method).toUpperCase(),
            headers: headers,
            body: body == null ? null : String(body)
          }).then(buildResponse);
        }
      } catch (e) { /* падаем в оригинал */ }
      return origFetch(input, init);
    };
  }

  // ---- XMLHttpRequest ----
  var OrigXHR = window.XMLHttpRequest;
  function MDXHR() {
    var xhr = new OrigXHR();
    var st = { bridged: false, method: 'GET', url: '', headers: {} };

    var origOpen = xhr.open;
    xhr.open = function (method, url) {
      st.method = String(method || 'GET').toUpperCase();
      st.url = url;
      st.headers = {};
      st.bridged = !!(url && TARGET.test(url));
      if (st.bridged) return; // настоящий open не вызываем
      return origOpen.apply(xhr, arguments);
    };

    var origSetHeader = xhr.setRequestHeader;
    xhr.setRequestHeader = function (k, v) {
      if (st.bridged) { st.headers[k] = v; return; }
      return origSetHeader.apply(xhr, arguments);
    };

    var origSend = xhr.send;
    xhr.send = function (body) {
      if (!st.bridged) return origSend.apply(xhr, arguments);
      bridge({
        url: st.url,
        method: st.method,
        headers: st.headers,
        body: body == null ? null : String(body)
      }).then(function (r) {
        define(xhr, 'readyState', 4);
        define(xhr, 'status', r.status || 200);
        define(xhr, 'statusText', r.statusText || 'OK');
        define(xhr, 'responseText', r.body != null ? r.body : '');
        define(xhr, 'response', r.body != null ? r.body : '');
        define(xhr, 'responseURL', st.url);
        var headerStr = '';
        if (r.headers) {
          for (var k in r.headers) headerStr += k + ': ' + r.headers[k] + '\r\n';
        }
        xhr.__mdHeaders = headerStr;
        if (typeof xhr.onreadystatechange === 'function') xhr.onreadystatechange(new Event('readystatechange'));
        dispatch(xhr, 'readystatechange');
        if (typeof xhr.onload === 'function') xhr.onload(new Event('load'));
        dispatch(xhr, 'load');
        dispatch(xhr, 'loadend');
      }).catch(function () {
        define(xhr, 'readyState', 4);
        define(xhr, 'status', 0);
        if (typeof xhr.onerror === 'function') xhr.onerror(new Event('error'));
        dispatch(xhr, 'error');
        dispatch(xhr, 'loadend');
      });
    };

    var origGetAll = xhr.getAllResponseHeaders;
    xhr.getAllResponseHeaders = function () {
      if (st.bridged && xhr.__mdHeaders != null) return xhr.__mdHeaders;
      return origGetAll.apply(xhr, arguments);
    };
    var origGet = xhr.getResponseHeader;
    xhr.getResponseHeader = function (name) {
      if (st.bridged && xhr.__mdHeaders) {
        var re = new RegExp('^' + name + ':\\s*(.*)$', 'im');
        var m = xhr.__mdHeaders.match(re);
        return m ? m[1].trim() : null;
      }
      return origGet.apply(xhr, arguments);
    };

    return xhr;
  }
  MDXHR.prototype = OrigXHR.prototype;
  MDXHR.UNSENT = 0; MDXHR.OPENED = 1; MDXHR.HEADERS_RECEIVED = 2; MDXHR.LOADING = 3; MDXHR.DONE = 4;

  function define(obj, prop, value) {
    try { Object.defineProperty(obj, prop, { configurable: true, get: function () { return value; } }); }
    catch (e) { try { obj[prop] = value; } catch (e2) {} }
  }
  function dispatch(xhr, type) {
    try { xhr.dispatchEvent(new Event(type)); } catch (e) {}
  }

  window.XMLHttpRequest = MDXHR;

  try { console.log('[MoeDeloBridge] page shim installed'); } catch (e) {}
})();
