// Session replay recorder glue around the vendored rrweb recorder. Loaded by
// the Full tracker only for consented visitors on sites that record replays.
// Everything is masked in the browser before it leaves: all text unless an
// ancestor has data-analytico-unmask, every input value always, and images,
// media, canvases and frames are replaced by placeholders.
(function () {
  "use strict";

  var chunkBytes = 48 * 1024;
  var flushMs = 5000;
  var maximumMs = 30 * 60 * 1000;

  window.__analyticoRecorder = function (options) {
    var rrweb = window.rrwebRecord;
    if (!rrweb || !rrweb.record || !window.CompressionStream) return null;
    var streaming = !!options.stream;
    var previous = [];
    var current = [];
    var pending = [];
    var pendingBytes = 0;
    var seq = 0;
    var started = Date.now();
    var stopped = false;
    var timer = null;

    function mask(text, element) {
      if (element && element.closest && element.closest("[data-analytico-unmask]")) return text;
      return text.replace(/\S/g, "*");
    }
    // "Mask inputs only" sites show page text; inputs are masked either way.
    var maskText = options.maskText !== false;

    var stopRecording = rrweb.record({
      emit: function (event, isCheckout) {
        if (stopped) return;
        if (Date.now() - started > maximumMs) return stop();
        if (streaming) {
          pending.push(event);
          pendingBytes += estimate(event);
          if (pendingBytes >= chunkBytes) flush(false);
          return;
        }
        // Not streaming: keep the last two checkouts only (about two minutes).
        if (isCheckout) {
          previous = current;
          current = [];
        }
        current.push(event);
      },
      checkoutEveryNms: 60000,
      maskAllInputs: true,
      maskInputFn: function (text) { return text ? "****" : ""; },
      maskTextSelector: maskText ? "*" : null,
      maskTextFn: maskText ? mask : undefined,
      blockSelector: "img,picture,video,audio,iframe,canvas,embed,object,[data-analytico-block]",
      inlineImages: false,
      collectFonts: false,
      recordCanvas: false,
      recordCrossOriginIframes: false,
      inlineStylesheet: true,
      slimDOMOptions: "all",
      sampling: { mousemove: 100, scroll: 150, media: 800, input: "last" }
    });

    function estimate(event) {
      try {
        return JSON.stringify(event).length;
      } catch (_) {
        return 1024;
      }
    }

    function query(events) {
      return "?site=" + encodeURIComponent(options.site) + "&session=" + options.session + "&visitor=" + options.visitor +
        "&page=" + options.page() + "&seq=" + (seq++) + "&first=" + events[0].timestamp + "&last=" + events[events.length - 1].timestamp;
    }

    function send(url, body, keepalive) {
      return fetch(url, { method: "POST", body: body, credentials: "omit", keepalive: keepalive, headers: { "Content-Type": "text/plain" } })
        .then(function (response) {
          // Over the size or length cap: recording stops for this session.
          if (response.status === 413) stop();
        }).catch(function () {});
    }

    function upload(events, last) {
      if (!events.length) return;
      var json;
      try {
        json = JSON.stringify(events);
      } catch (_) {
        return;
      }
      var url = options.endpoint + query(events);
      // Leaving the page: there is no time to compress, so small chunks go
      // as plain JSON (already masked) on a keepalive request.
      if (last && json.length < 60000) return send(url, json, true);
      var body;
      try {
        body = new Blob([json]).stream().pipeThrough(new CompressionStream("gzip"));
      } catch (_) {
        return;
      }
      new Response(body).arrayBuffer().then(function (bytes) { send(url, bytes, last && bytes.byteLength < 60000); });
    }

    function flush(last) {
      if (!streaming || !pending.length) return;
      var events = pending;
      pending = [];
      pendingBytes = 0;
      upload(events, last);
    }

    function stop() {
      if (stopped) return;
      flush(true);
      stopped = true;
      clearInterval(timer);
      if (stopRecording) stopRecording();
    }

    timer = setInterval(function () { flush(false); }, flushMs);
    // The first full snapshot goes out quickly, so short visits still play.
    setTimeout(function () { flush(false); }, 1500);

    return {
      // A rage click, an error or a goal: send the buffer and keep streaming.
      trigger: function () {
        if (streaming || stopped) return;
        streaming = true;
        pending = previous.concat(current);
        previous = [];
        current = [];
        pendingBytes = 0;
        flush(false);
      },
      flush: flush,
      stop: stop
    };
  };
}());
