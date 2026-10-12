// Session replay recorder glue around the vendored rrweb recorder. Loaded by
// the Full tracker only for consented visitors on sites that record replays.
// Everything is masked in the browser before it leaves: all text and every
// input value, while images,
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

    function mask(text) {
      return text.replace(/\S/g, "*");
    }

    var stopRecording = rrweb.record({
      emit: function (event, isCheckout) {
        if (stopped) return;
        // CSS is stripped from snapshots; declaration events can only leak
        // custom property names and add no useful replay information.
        if (event && event.type === 3 && event.data && event.data.source === 13) return;
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
      maskTextSelector: "*",
      maskTextFn: mask,
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

    // rrweb masks visible text and ordinary inputs, but snapshots can also
    // contain URL credentials, hidden-field values and arbitrary attributes.
    // Strip those classes again at the final serialization boundary.
    function safeUrl(value) {
      try {
        var url = new URL(value, location.href);
        return url.origin + url.pathname;
      } catch (_) {
        return "";
      }
    }

    function privateData(key, value) {
      if (key === "value") return undefined;
      if (key === "isChecked") return undefined;
      if ((key === "text" || key === "textContent") && typeof value === "string") return value ? "****" : "";
      if (key === "rule" || key === "cssText" || key === "style" || key === "replace" || key === "replaceSync") return undefined;
      if ((key === "href" || key === "src" || key === "action" || key === "url") && typeof value === "string") return safeUrl(value);
      if (key === "attributes" && value && typeof value === "object" && !Array.isArray(value)) {
        var kept = {};
        ["role", "type", "disabled"].forEach(function (name) {
          if (Object.prototype.hasOwnProperty.call(value, name)) kept[name] = value[name];
        });
        return kept;
      }
      return value;
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
        json = JSON.stringify(events, privateData);
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
