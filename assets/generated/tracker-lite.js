(function () {
  "use strict";

  var script = document.currentScript;
  var site = script && script.dataset.site;
  if (!script || !site) return;

  var endpoint = new URL("/e", script.src).href;
  var mode = "lite";
  var trackerVersion = "1";
  var consentMode = clean(script.dataset.consent || "unspecified", 32) || "unspecified";
  var releaseId = clean(script.dataset.release || "", 64);
  var pageType = clean(script.dataset.pageType || "", 64) || null;
  var contentId = clean(script.dataset.contentId || "", 128) || null;
  var internal = script.dataset.internal === "true";
  var pageId = uuid();
  var sessionId = null;
  if (!pageId) return;

  var startedAt = Date.now();
  var lastTick = startedAt;
  var lastActivity = startedAt;
  var visibleMs = 0;
  var activeMs = 0;
  var firstInteractionMs = null;
  var interactions = 0;
  var maxScroll = scrollBucket();
  var scrollScheduled = false;
  var sectionOrder = [];
  var sectionSeen = Object.create(null);
  var lastSection = null;
  var selectionCount = 0;
  var copyCount = 0;
  var outboundClicks = 0;
  var downloads = 0;
  var formAttempts = 0;
  var queued = [];
  var sentSummary = false;

  function uuid() {
    try {
      if (crypto.randomUUID) return crypto.randomUUID();
      var bytes = new Uint8Array(16);
      crypto.getRandomValues(bytes);
      bytes[6] = bytes[6] & 15 | 64;
      bytes[8] = bytes[8] & 63 | 128;
      var hex = "";
      for (var i = 0; i < bytes.length; i++) hex += (bytes[i] + 256).toString(16).slice(1);
      return hex.slice(0, 8) + "-" + hex.slice(8, 12) + "-" + hex.slice(12, 16) + "-" + hex.slice(16, 20) + "-" + hex.slice(20);
    } catch (_) {
      return "";
    }
  }


  function clean(value, limit) {
    if (typeof value !== "string") return "";
    value = value.slice(0, limit);
    return /[\u0000-\u001f\u007f]/.test(value) ? "" : value;
  }

  function campaign() {
    var out = {};
    try {
      var query = new URLSearchParams(location.search);
      ["source", "medium", "campaign", "content", "term"].forEach(function (name) {
        var value = clean(query.get("utm_" + name) || "", 128);
        if (value) out["utm_" + name] = value;
      });
    } catch (_) {}
    return out;
  }

  function referrerHost() {
    if (!document.referrer) return null;
    try {
      var host = new URL(document.referrer).hostname.toLowerCase();
      return host === location.hostname.toLowerCase() ? null : clean(host, 253) || null;
    } catch (_) {
      return null;
    }
  }

  function navigationType() {
    try {
      var entry = performance.getEntriesByType("navigation")[0];
      return clean(entry && entry.type || "navigate", 24) || "navigate";
    } catch (_) {
      return "navigate";
    }
  }

  function viewportClass() {
    var width = Math.min(window.innerWidth || 0, screen.width || window.innerWidth || 0);
    if (width < 600) return "phone";
    if (width < 1024) return "tablet";
    return "desktop";
  }

  function base(id, type) {
    return {
      event_id: id,
      type: type,
      page_id: pageId,
      session_id: sessionId,
      occurred_at_ms: Date.now(),
      tracking_mode: mode,
      consent_mode: consentMode,
      tracker_version: trackerVersion,
      release_id: releaseId,
      internal: internal
    };
  }

  function send(records) {
    if (!records.length || records.length > 16) return false;
    var body;
    try {
      body = JSON.stringify({ v: 1, site: site, sent_at_ms: Date.now(), records: records });
      if (new TextEncoder().encode(body).length > 8192) return false;
    } catch (_) {
      return false;
    }
    try {
      if (navigator.sendBeacon(endpoint, body)) return true;
    } catch (_) {}
    try {
      fetch(endpoint, {
        method: "POST",
        body: body,
        credentials: "omit",
        keepalive: true,
        headers: { "Content-Type": "text/plain;charset=UTF-8" }
      }).catch(function () {});
      return true;
    } catch (_) {
      return false;
    }
  }

  function pageView() {
    var record = Object.assign(base(uuid(), "page_view"), campaign(), {
      path: location.pathname,
      page_type: pageType,
      content_id: contentId,
      referrer_host: referrerHost(),
      navigation_type: navigationType(),
      viewport_class: viewportClass(),
      language: clean(navigator.language || "", 32) || null
    });
    send([record]);
  }

  function safeProperties(properties) {
    if (properties == null) return {};
    if (typeof properties !== "object" || Array.isArray(properties)) return null;
    var out = Object.create(null);
    var keys = Object.keys(properties);
    if (keys.length > 8) return null;
    for (var i = 0; i < keys.length; i++) {
      var key = keys[i];
      if (!/^[A-Za-z0-9_.:-]{1,64}$/.test(key)) return null;
      var value = properties[key];
      if (value === null || typeof value === "boolean" || Number.isSafeInteger(value)) {
        out[key] = value;
      } else if (typeof value === "string" && clean(value, 256) === value) {
        out[key] = value;
      } else {
        return null;
      }
    }
    return out;
  }

  function track(name, properties, money) {
    name = clean(name, 64);
    var safe = safeProperties(properties);
    if (!name || !/^[A-Za-z0-9_.:-]+$/.test(name) || safe === null) return "";
    var id = uuid();
    if (!id) return "";
    var record = Object.assign(base(id, "event"), {
      name: name,
      path: location.pathname,
      properties: safe
    });
    if (money != null) {
      if (!Number.isSafeInteger(money.value_minor) || !/^[A-Z]{3}$/.test(money.currency || "")) return "";
      record.value_minor = money.value_minor;
      record.currency = money.currency;
    }
    if (queued.length < 15) queued.push(record);
    return id;
  }

  function settle(now) {
    var elapsed = Math.max(0, now - lastTick);
    if (!document.hidden) {
      visibleMs += elapsed;
      activeMs += Math.max(0, Math.min(now, lastActivity + 30000) - lastTick);
    }
    lastTick = now;
  }

  function interact(event) {
    if (event && event.isTrusted === false) return;
    var now = Date.now();
    settle(now);
    lastActivity = now;
    interactions++;
    if (firstInteractionMs === null) firstInteractionMs = Math.max(0, now - startedAt);
  }

  function scrollBucket() {
    var root = document.documentElement;
    var height = Math.max(root.scrollHeight, document.body && document.body.scrollHeight || 0) - window.innerHeight;
    if (height <= 0) return 100;
    var percent = Math.round(100 * Math.max(0, window.scrollY || root.scrollTop || 0) / height);
    if (percent >= 90) return 100;
    if (percent >= 65) return 75;
    if (percent >= 40) return 50;
    if (percent >= 15) return 25;
    return 0;
  }


  function onClick(event) {
    interact(event);
    var link = event.target && event.target.closest && event.target.closest("a[href]");
    if (link) {
      try {
        var url = new URL(link.href, location.href);
        if (url.origin !== location.origin) outboundClicks++;
        if (link.hasAttribute("download") || /\.(pdf|zip|csv|docx?|xlsx?|ics)$/i.test(url.pathname)) downloads++;
      } catch (_) {}
    }
  }


  function summary() {
    if (sentSummary) return;
    sentSummary = true;
    settle(Date.now());
    var record = Object.assign(base(uuid(), "page_summary"), {
      visible_ms: Math.round(visibleMs),
      active_ms: Math.round(activeMs),
      first_interaction_ms: firstInteractionMs,
      interaction_count: interactions,
      max_scroll: maxScroll,
      sections: sectionOrder,
      last_section: lastSection,
      selection_count: selectionCount,
      copy_count: copyCount,
      outbound_clicks: outboundClicks,
      downloads: downloads,
      form_attempts: formAttempts
    });
    send([record].concat(queued));
    queued.length = 0;
  }

  document.addEventListener("click", onClick, false);
  document.addEventListener("submit", function (event) { formAttempts++; interact(event); }, false);
  document.addEventListener("copy", function (event) {
    var selection = window.getSelection && window.getSelection();
    var anchor = selection && selection.anchorNode;
    var element = anchor && (anchor.nodeType === 1 ? anchor : anchor.parentElement);
    var section = element && element.closest && element.closest("[data-analytics-section]");
    if (section && selection && selection.toString().length > 0) {
      var selectedLength = selection.toString().length;
      var selectedBucket = selectedLength < 40 ? "under-40" : selectedLength < 160 ? "40-159" : selectedLength < 640 ? "160-639" : "640-plus";
      selectionCount++;
      copyCount++;
      track("content_copied", { section: clean(section.dataset.analyticsSection || "", 64), selection_length_bucket: selectedBucket });
      interact(event);
    }
  }, false);
  addEventListener("scroll", function () {
    if (scrollScheduled) return;
    scrollScheduled = true;
    requestAnimationFrame(function () {
      scrollScheduled = false;
      maxScroll = Math.max(maxScroll, scrollBucket());
      settle(Date.now());
      lastActivity = Date.now();
    });
  }, { passive: true });
  document.addEventListener("visibilitychange", function () { settle(Date.now()); }, false);
  addEventListener("pagehide", summary, false);

  if ("IntersectionObserver" in window) {
    var observer = new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) {
        if (!entry.isIntersecting || entry.intersectionRatio < 0.5) return;
        var id = clean(entry.target.dataset.analyticsSection || "", 64);
        if (!id || sectionSeen[id]) return;
        sectionSeen[id] = true;
        sectionOrder.push(id);
        lastSection = id;
      });
    }, { threshold: [0.5] });
    document.querySelectorAll("[data-analytics-section]").forEach(function (element) { observer.observe(element); });
  }


  window.analytico = { track: track };

  pageView();
  if (pageType === "404") track("page_not_found", {});
}());
