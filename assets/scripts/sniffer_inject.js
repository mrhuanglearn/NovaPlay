// Injected into a page loaded by the Web Sniffer (flutter_inappwebview). Written from scratch for this
// project. Observed interface of the original: a `snifferReport` JS handler, the page flag `__uznSniffer`,
// and an on-demand `window.__uznSnifferScan()`.
(function () {
  'use strict';
  if (window.__uzvSniffer) return;
  window.__uzvSniffer = true;

  var MEDIA_RE = /\.(m3u8|mp4|mkv|flv|mpd|webm|mov|ts)(\?|#|$)/i;
  var MEDIA_TYPE_RE = /^(video\/|audio\/|application\/(vnd\.apple\.mpegurl|x-mpegurl|dash\+xml))/i;
  var seen = {};
  var queue = [];
  var bridgeReady = false;

  function absolute(url) {
    try { return new URL(url, location.href).href; } catch (e) { return null; }
  }

  function kindOf(url, type) {
    if (/\.m3u8(\?|#|$)/i.test(url) || /mpegurl/i.test(type || '')) return 'hls';
    if (/\.mpd(\?|#|$)/i.test(url) || /dash\+xml/i.test(type || '')) return 'dash';
    return 'file';
  }

  function emit(report) {
    var json = JSON.stringify(report);
    if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
      bridgeReady = true;
      window.flutter_inappwebview.callHandler('snifferReport', report);
    } else {
      queue.push(json);
      if (queue.length > 50) queue.shift();
    }
  }

  function consider(url, source, type, size) {
    if (!url || /^(blob|data|javascript):/i.test(url)) return;
    var abs = absolute(url);
    if (!abs || seen[abs]) return;
    if (!MEDIA_RE.test(abs) && !MEDIA_TYPE_RE.test(type || '')) return;
    if (/\.ts(\?|#|$)/i.test(abs)) return; // individual HLS segments are not interesting
    seen[abs] = true;
    emit({ url: abs, source: source, kind: kindOf(abs, type), contentType: type || '', size: size || 0,
      page: location.href, title: document.title, referer: location.href, userAgent: navigator.userAgent });
  }

  // fetch()
  var origFetch = window.fetch;
  if (origFetch) {
    window.fetch = function (input, init) {
      var url = typeof input === 'string' ? input : input && input.url;
      var p = origFetch.apply(this, arguments);
      p.then(function (res) {
        try { consider(res.url || url, 'fetch', res.headers.get('content-type'), parseInt(res.headers.get('content-length') || '0', 10)); } catch (e) {}
      }).catch(function () {});
      return p;
    };
  }

  // XMLHttpRequest
  var origOpen = XMLHttpRequest.prototype.open;
  XMLHttpRequest.prototype.open = function (method, url) {
    var xhr = this;
    xhr.addEventListener('readystatechange', function () {
      if (xhr.readyState === 2) {
        try { consider(xhr.responseURL || url, 'xhr', xhr.getResponseHeader('content-type'), parseInt(xhr.getResponseHeader('content-length') || '0', 10)); } catch (e) {}
      }
    });
    return origOpen.apply(this, arguments);
  };

  // <video>/<source>/<audio> elements, including ones added later
  function scan() {
    var nodes = document.querySelectorAll('video,audio,source');
    for (var i = 0; i < nodes.length; i++) {
      var n = nodes[i];
      consider(n.currentSrc || n.src || n.getAttribute('src'), 'element', n.type || '', 0);
    }
    var entries = (performance.getEntriesByType && performance.getEntriesByType('resource')) || [];
    for (var j = 0; j < entries.length; j++) consider(entries[j].name, 'resource-timing', '', entries[j].transferSize || 0);
    if (!bridgeReady && queue.length && window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
      bridgeReady = true;
      queue.splice(0).forEach(function (j2) { window.flutter_inappwebview.callHandler('snifferReport', JSON.parse(j2)); });
    }
  }
  window.__uzvSnifferScan = scan;

  new MutationObserver(scan).observe(document.documentElement, { childList: true, subtree: true, attributes: true, attributeFilter: ['src'] });
  setInterval(scan, 1500);
  document.addEventListener('DOMContentLoaded', scan);
  scan();
})();
