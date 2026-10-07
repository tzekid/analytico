(function () {
  "use strict";

  var script = document.currentScript;
  var site = script && script.dataset.site;
  if (!script || !site) return;

  var origin = new URL(script.src).origin;
  var endpoint = origin + "/e";
  var mode = "__MODE__";
  var trackerVersion = "2";
  var configuredConsent = clean(script.dataset.consent || "unspecified", 32) || "unspecified";
  var releaseId = clean(script.dataset.release || "", 64);
  var pageType = clean(script.dataset.pageType || "", 64) || null;
  var contentId = clean(script.dataset.contentId || "", 128) || null;
  var internal = script.dataset.internal === "true";
  var spa = script.dataset.spa !== "false";
  var searchParams = (script.dataset.search || "q,s,search,query").split(",").map(function (name) { return name.trim(); }).filter(Boolean).slice(0, 8);
  var sessionId = __SESSION_ID__;
  /* @sessiononly-begin */
  if (!sessionId) return;
  /* @sessiononly-end */
  var pageId = "";
  var spaNavigation = false;
  var currentPath = location.pathname;

  var startedAt, lastTick, lastActivity, visibleMs, activeMs, firstInteractionMs, interactions;
  var maxScroll, scrollScheduled = false, sectionOrder, sectionSeen, lastSection;
  var selectionCount, copyCount, outboundClicks, downloads, formAttempts, errorsSent;
  var queued = [];
  var sentSummary = true;
  /* @session-begin */
  var actionTimers = new Map();
  var recentAction = { id: "", times: [] };
  /* @session-end */
  /* @full-begin */
  var consent = "pending";
  var visitorId = null;
  var storagePrefix = "analytico:" + site + ":";
  // Global Privacy Control and Do Not Track both keep the visitor in Lite.
  var gpc = navigator.globalPrivacyControl === true || navigator.doNotTrack === "1";
  var excluded = [];
  var linkToken = null;
  var linkDomains = [];
  var replayConfig = null;
  var replay = null;
  var replayRequested = false;
  var bannerHost = null;
  var clickCells, clickCount, recentClicks, attention, forms, lastAttention;
  var arrivedClickId = null;
  /* @full-end */
  /* @rum-begin */
  var rum = {
    ttfb_ms: null,
    fcp_ms: null,
    lcp_ms: null,
    inp_ms: null,
    cls_milli: null,
    long_frame_count: null,
    blocking_ms: null
  };
  /* @rum-end */

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

  function isUuid(value) {
    return typeof value === "string" && /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(value);
  }

  /* @sessiononly-begin */
  function loadSession() {
    var key = "analytico:" + site + ":session";
    try {
      var current = sessionStorage.getItem(key);
      if (current && /^[0-9a-f-]{36}$/.test(current)) return current;
      current = uuid();
      if (!current) return "";
      sessionStorage.setItem(key, current);
      return current;
    } catch (_) {
      return uuid();
    }
  }
  /* @sessiononly-end */

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

  // Site search: the term only, lowercased; anything that looks like an email
  // address or a long number (phone, card, order) is dropped.
  function searchTerm() {
    try {
      var query = new URLSearchParams(location.search);
      for (var i = 0; i < searchParams.length; i++) {
        var value = query.get(searchParams[i]);
        if (value == null) continue;
        value = clean(value.trim().toLowerCase().replace(/\s+/g, " "), 100);
        if (!value || value.indexOf("@") >= 0 || /\d{6,}/.test(value.replace(/[\s-]/g, ""))) return null;
        return value;
      }
    } catch (_) {}
    return null;
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

  // Where this visit came from: the landing page's referrer and campaign,
  // kept for the rest of the visit so every page view carries it. A page
  // reached from the site itself with nothing kept (Lite, or Full before
  // consent) names the site as its referrer; the server files it as internal.
  var arrivalKeys = ["referrer_host", "utm_source", "utm_medium", "utm_campaign", "utm_content", "utm_term"];
  var arrival = null;

  function cleanArrival(object) {
    var out = {};
    arrivalKeys.forEach(function (key) {
      var value = object && typeof object[key] === "string" ? clean(object[key], key === "referrer_host" ? 253 : 128) : "";
      if (value) out[key] = value;
    });
    return out;
  }

  function cameFromSite() {
    try {
      return !!document.referrer && new URL(document.referrer).hostname.toLowerCase() === location.hostname.toLowerCase();
    } catch (_) {
      return false;
    }
  }

  function visitSource() {
    if (spaNavigation && arrival) return arrival;
    var fields = campaign();
    var host = referrerHost();
    if (host) fields.referrer_host = host;
    if (!cameFromSite() || Object.keys(fields).length) {
      arrival = fields;
      remember(arrival);
    } else {
      arrival = recalled() || { referrer_host: clean(location.hostname.toLowerCase(), 253) };
    }
    return arrival;
  }

  function remember(fields) {
    /* @sessiononly-begin */
    try { sessionStorage.setItem("analytico:" + site + ":arrival", JSON.stringify(fields)); } catch (_) {}
    /* @sessiononly-end */
    /* @full-begin */
    if (visitorId && sessionId) save("arrival", sessionId + " " + JSON.stringify(fields));
    /* @full-end */
  }

  function recalled() {
    /* @sessiononly-begin */
    try {
      var kept = JSON.parse(sessionStorage.getItem("analytico:" + site + ":arrival") || "null");
      if (kept && typeof kept === "object") return cleanArrival(kept);
    } catch (_) {}
    /* @sessiononly-end */
    /* @full-begin */
    var saved = load("arrival") || "";
    var space = saved.indexOf(" ");
    if (visitorId && sessionId && space > 0 && saved.slice(0, space) === sessionId) {
      try { return cleanArrival(JSON.parse(saved.slice(space + 1))); } catch (_) {}
    }
    /* @full-end */
    return null;
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

  function consentMode() {
    /* @full-begin */
    return gpc ? "gpc" : consent;
    /* @full-end */
    return configuredConsent;
  }

  function base(id, type) {
    var record = {
      event_id: id,
      type: type,
      page_id: pageId,
      session_id: sessionId,
      occurred_at_ms: Date.now(),
      tracking_mode: mode,
      consent_mode: consentMode(),
      tracker_version: trackerVersion,
      release_id: releaseId,
      internal: internal
    };
    /* @full-begin */
    if (visitorId) {
      sessionId = currentSession();
      record.session_id = sessionId;
      record.visitor_id = visitorId;
    } else {
      record.session_id = null;
    }
    /* @full-end */
    return record;
  }

  function byteLength(text) {
    try {
      return new TextEncoder().encode(text).length;
    } catch (_) {
      return text.length * 3;
    }
  }

  function post(body, onResponse) {
    if (onResponse) {
      try {
        fetch(endpoint, {
          method: "POST",
          body: body,
          credentials: "omit",
          keepalive: true,
          headers: { "Content-Type": "text/plain;charset=UTF-8" }
        }).then(function (response) {
          return response.status === 200 ? response.json() : null;
        }).then(onResponse, function () {});
        return;
      } catch (_) {}
    }
    try {
      if (navigator.sendBeacon(endpoint, body)) return;
    } catch (_) {}
    try {
      fetch(endpoint, {
        method: "POST",
        body: body,
        credentials: "omit",
        keepalive: true,
        headers: { "Content-Type": "text/plain;charset=UTF-8" }
      }).catch(function () {});
    } catch (_) {}
  }

  // Packs records into batches of at most 16 records and 8 KB.
  function send(records, onResponse) {
    var batch = [];
    var size = 0;
    function flush(last) {
      if (!batch.length) return;
      post(JSON.stringify({ v: 2, site: site, sent_at_ms: Date.now(), records: batch }), last ? onResponse : null);
      batch = [];
      size = 0;
    }
    records.forEach(function (record) {
      var length = byteLength(JSON.stringify(record));
      if (length > 7600) return;
      if (batch.length === 16 || size + length > 7600) flush(false);
      batch.push(record);
      size += length + 1;
    });
    flush(true);
  }

  function pageView() {
    var record = Object.assign(base(uuid(), "page_view"), visitSource(), {
      path: currentPath,
      page_type: pageType,
      content_id: contentId,
      navigation_type: spaNavigation ? "spa" : navigationType(),
      viewport_class: viewportClass(),
      language: clean(navigator.language || "", 32) || null
    });
    var term = searchTerm();
    if (term) {
      record.search_term = term;
      var results = document.querySelector("[data-analytics-search-results]");
      var count = results && parseInt(results.getAttribute("data-analytics-search-results"), 10);
      if (count >= 0) record.search_results = count;
    }
    /* @full-begin */
    if (linkArrival) record.link = linkArrival;
    if (visitorId && arrivedClickId) {
      record.click_id = arrivedClickId;
      arrivedClickId = null;
    }
    send([record], decision);
    return;
    /* @full-end */
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

  function safeItems(items) {
    if (!Array.isArray(items) || !items.length || items.length > 32) return null;
    var out = [];
    for (var i = 0; i < items.length; i++) {
      var item = items[i] || {};
      var id = clean(String(item.id == null ? "" : item.id), 64);
      var name = clean(String(item.name == null ? id : item.name), 128);
      if (!id || !name) return null;
      var entry = { id: id, name: name, quantity: Number.isSafeInteger(item.quantity) && item.quantity > 0 ? item.quantity : 1 };
      if (item.category) entry.category = clean(String(item.category), 64);
      if (Number.isSafeInteger(item.price_minor)) entry.price_minor = item.price_minor;
      out.push(entry);
    }
    return out;
  }

  // track(name, properties, details): details may carry money
  // ({ value_minor, currency }), an order_id and ecommerce items.
  function track(name, properties, details) {
    name = clean(name, 64);
    var safe = safeProperties(properties);
    if (!name || !/^[A-Za-z0-9_.:-]+$/.test(name) || safe === null) return "";
    var id = uuid();
    if (!id) return "";
    var record = Object.assign(base(id, "event"), {
      name: name,
      path: currentPath,
      properties: safe
    });
    if (details != null) {
      if (details.value_minor != null || details.currency != null) {
        if (!Number.isSafeInteger(details.value_minor) || !/^[A-Z]{3}$/.test(details.currency || "")) return "";
        record.value_minor = details.value_minor;
        record.currency = details.currency;
      }
      if (details.order_id != null) record.order_id = clean(String(details.order_id), 64) || undefined;
      if (details.items != null) {
        var items = safeItems(details.items);
        if (!items) return "";
        record.items = items;
      }
    }
    if (queued.length < 15) queued.push(record);
    /* @full-begin */
    if (replayConfig && replayConfig.goals && replayConfig.goals.indexOf(name) >= 0) triggerReplay();
    /* @full-end */
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

  function documentHeight() {
    var root = document.documentElement;
    return Math.max(root.scrollHeight, document.body && document.body.scrollHeight || 0);
  }

  // Deepest point reached, in 5% steps.
  function scrollBucket() {
    var root = document.documentElement;
    var height = documentHeight() - window.innerHeight;
    if (height <= 0) return 100;
    var percent = 100 * Math.max(0, window.scrollY || root.scrollTop || 0) / height;
    if (percent >= 95) return 100;
    return Math.min(100, Math.round(percent / 5) * 5);
  }

  /* @session-begin */
  function actionElement(target) {
    return target && target.closest && target.closest("[data-analytics-action]");
  }
  /* @session-end */

  function onClick(event) {
    interact(event);
    var link = event.target && event.target.closest && event.target.closest("a[href]");
    if (link) {
      try {
        var url = new URL(link.href, location.href);
        var file = /\.(pdf|zip|csv|docx?|xlsx?|pptx?|ics|dmg|exe|msi|apk|mp3|mp4|epub)$/i.exec(url.pathname);
        if (link.hasAttribute("download") || file) {
          downloads++;
          var fileName = clean(decodeURIComponent(url.pathname.split("/").pop() || "download"), 100);
          track("file_download", { file: fileName, ext: (file ? file[1] : "").toLowerCase() || null });
        } else if (url.origin !== location.origin && /^https?:$/.test(url.protocol)) {
          outboundClicks++;
          track("outbound_click", { host: clean(url.hostname.toLowerCase(), 253) });
        }
      } catch (_) {}
    }
    /* @session-begin */
    var action = actionElement(event.target);
    if (action) {
      var id = clean(action.dataset.analyticsAction || "", 64);
      if (id) {
        track("action_started", { action: id });
        var now = Date.now();
        if (recentAction.id !== id) recentAction = { id: id, times: [] };
        recentAction.times = recentAction.times.filter(function (time) { return now - time <= 1200; });
        recentAction.times.push(now);
        if (recentAction.times.length === 3) track("rage_click", { action: id, click_bucket: 3 });
        if (actionTimers.size < 8 && !actionTimers.has(id)) {
          var timer = setTimeout(function () {
            actionTimers.delete(id);
            track("action_unresponsive", { action: id, duration_bucket: "10s+" });
          }, 10000);
          actionTimers.set(id, { timer: timer, started: now });
        }
      }
    }
    /* @session-end */
    /* @full-begin */
    if (visitorId && event.isTrusted !== false) recordClick(event);
    /* @full-end */
  }

  /* @session-begin */
  function finishAction(id, outcome, properties) {
    id = clean(id, 64);
    if (!id) return "";
    var duration = null;
    if (actionTimers.has(id)) {
      var state = actionTimers.get(id);
      clearTimeout(state.timer);
      duration = Date.now() - state.started;
      actionTimers.delete(id);
    }
    var safe = safeProperties(properties) || {};
    safe.action = id;
    if (duration !== null) safe.duration_bucket = duration < 100 ? "under-100ms" : duration < 500 ? "100-499ms" : duration < 2000 ? "500-1999ms" : "2-9s";
    return track("action_" + outcome, safe);
  }
  /* @session-end */

  /* @full-begin */
  // ---------------------------------------------------------- heatmaps

  // A stable CSS selector for the clicked element: the marked action, or a
  // short path of tag:nth-of-type steps up to the nearest stable id.
  function elementKey(target) {
    var element = target.closest && target.closest("[data-analytics-action],a,button,input,select,textarea,label,summary,[role=button]") || target;
    if (!element || element.nodeType !== 1) return null;
    var action = element.getAttribute("data-analytics-action");
    if (action && /^[A-Za-z0-9_.:-]{1,64}$/.test(action)) return "[data-analytics-action=\"" + action + "\"]";
    var steps = [];
    for (var node = element; node && node.nodeType === 1 && node !== document.documentElement && steps.length < 6; node = node.parentElement) {
      var tag = node.tagName.toLowerCase();
      if (node.id && /^[A-Za-z][A-Za-z0-9_-]{0,40}$/.test(node.id) && !/\d{3,}/.test(node.id)) {
        steps.unshift("#" + node.id);
        break;
      }
      if (tag === "body") {
        steps.unshift("body");
        break;
      }
      var index = 1;
      for (var sibling = node.previousElementSibling; sibling; sibling = sibling.previousElementSibling) {
        if (sibling.tagName === node.tagName) index++;
      }
      steps.unshift(tag + ":nth-of-type(" + index + ")");
    }
    var key = steps.join(">");
    return key.length <= 160 ? key : null;
  }

  // Operator-listed pages ("/account/*") are never recorded or heat-mapped.
  function isExcluded(path) {
    return excluded.some(function (pattern) {
      if (typeof pattern !== "string" || !pattern) return false;
      var regex = new RegExp("^" + pattern.replace(/[.+?^${}()|[\]\\]/g, "\\$&").replace(/\*/g, ".*") + "$");
      return regex.test(path);
    });
  }

  function recordClick(event) {
    if (isExcluded(currentPath)) return;
    var key = elementKey(event.target);
    if (!key) return;
    var element;
    try {
      element = document.querySelector(key);
    } catch (_) {
      return;
    }
    if (!element) return;
    var rect = element.getBoundingClientRect();
    if (!rect.width || !rect.height) return;
    var x = Math.max(0, Math.min(100, Math.round((event.clientX - rect.left) / rect.width * 20) * 5));
    var y = Math.max(0, Math.min(100, Math.round((event.clientY - rect.top) / rect.height * 20) * 5));
    var now = Date.now();
    recentClicks = recentClicks.filter(function (click) { return now - click.at < 1000 && click.key === key; });
    recentClicks.push({ key: key, at: now });
    var rage = recentClicks.length === 3;
    var cell = key + "|" + x + "|" + y;
    if (!clickCells[cell]) {
      if (clickCount >= 24) return;
      clickCount++;
      clickCells[cell] = { el: key, x: x, y: y, n: 0, rage: 0 };
    }
    clickCells[cell].n = Math.min(1000, clickCells[cell].n + 1);
    if (rage) {
      clickCells[cell].rage = Math.min(clickCells[cell].n, clickCells[cell].rage + 1);
      // Marked actions report their own rage clicks.
      if (key.indexOf("[data-analytics-action") !== 0) track("rage_click", { element: key.slice(0, 256) });
      triggerReplay();
    }
  }

  // Attention: visible time per tenth of the page height.
  function tickAttention() {
    var now = Date.now();
    var elapsed = Math.min(2000, now - lastAttention);
    lastAttention = now;
    if (document.hidden || now - lastActivity > 30000) return;
    var height = documentHeight();
    if (height <= 0) return;
    var top = (window.scrollY || 0) / height;
    var bottom = Math.min(1, ((window.scrollY || 0) + window.innerHeight) / height);
    for (var band = 0; band < 10; band++) {
      if (bottom > band / 10 && top < (band + 1) / 10) attention[band] = Math.min(86400000, attention[band] + elapsed);
    }
  }

  // ---------------------------------------------------------- forms

  function formKey(form) {
    var name = form.getAttribute("name") || form.id || form.getAttribute("data-analytics-form");
    if (name) return clean(name, 64);
    var index = Array.prototype.indexOf.call(document.forms, form);
    return "form-" + (index + 1);
  }

  function fieldKey(field) {
    return clean(field.getAttribute("name") || field.id || field.getAttribute("type") || field.tagName.toLowerCase(), 64);
  }

  function formField(target) {
    if (!target || !target.form || !/^(INPUT|SELECT|TEXTAREA)$/.test(target.tagName)) return null;
    if (/^(hidden|submit|button|reset|image)$/i.test(target.type || "")) return null;
    var form = formKey(target.form);
    var field = fieldKey(target);
    if (!form || !field) return null;
    var state = forms[form] || (forms[form] = { fields: {}, order: [], submitted: false });
    if (!state.fields[field]) {
      if (state.order.length >= 16) return null;
      state.fields[field] = { ms: 0, errors: 0, since: 0 };
      state.order.push(field);
    }
    state.last = field;
    return state.fields[field];
  }

  function formSummary() {
    var out = [];
    Object.keys(forms).forEach(function (form) {
      var state = forms[form];
      state.order.forEach(function (field) {
        var entry = state.fields[field];
        if (entry.since) entry.ms += Date.now() - entry.since;
        out.push({
          form: form,
          field: field,
          ms: Math.min(86400000, Math.round(entry.ms)),
          errors: Math.min(1000, entry.errors),
          abandoned: !state.submitted && state.last === field,
          submitted: state.submitted
        });
      });
    });
    return out.slice(0, 32);
  }
  /* @full-end */

  function summary() {
    if (sentSummary) return;
    sentSummary = true;
    settle(Date.now());
    /* @session-begin */
    actionTimers.forEach(function (state) { clearTimeout(state.timer); });
    actionTimers.clear();
    /* @session-end */
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
    /* @rum-begin */
    Object.keys(rum).forEach(function (key) { if (rum[key] !== null) record[key] = Math.round(rum[key]); });
    /* @rum-end */
    /* @full-begin */
    if (visitorId) {
      var cells = Object.keys(clickCells).map(function (key) { return clickCells[key]; });
      if (cells.length) record.clicks = cells;
      if (attention.some(function (value) { return value > 0; })) record.attention = attention.map(Math.round);
      var fields = formSummary();
      if (fields.length) record.form_fields = fields;
    }
    if (replay) replay.flush(true);
    /* @full-end */
    send([record].concat(queued));
    queued.length = 0;
  }

  // Per-page state, reset on every page view (full loads and SPA routes).
  function begin() {
    pageId = uuid();
    startedAt = Date.now();
    lastTick = startedAt;
    lastActivity = startedAt;
    visibleMs = 0;
    activeMs = 0;
    firstInteractionMs = null;
    interactions = 0;
    maxScroll = scrollBucket();
    sectionOrder = [];
    sectionSeen = Object.create(null);
    lastSection = null;
    selectionCount = 0;
    copyCount = 0;
    outboundClicks = 0;
    downloads = 0;
    formAttempts = 0;
    errorsSent = Object.create(null);
    sentSummary = false;
    /* @full-begin */
    clickCells = Object.create(null);
    clickCount = 0;
    recentClicks = [];
    attention = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
    lastAttention = startedAt;
    forms = Object.create(null);
    /* @full-end */
  }

  // Errors: message (query strings and long numbers removed), file name,
  // line and column. At most five distinct errors per page.
  function reportError(message, file, line, column) {
    if (!pageId) return;
    message = clean(String(message || "Error").replace(/https?:\/\/[^\s?#]*[?#][^\s]*/g, function (url) {
      return url.split(/[?#]/)[0];
    }).replace(/\d{5,}/g, "…"), 300);
    if (!message || errorsSent[message] || Object.keys(errorsSent).length >= 5) return;
    errorsSent[message] = true;
    var record = Object.assign(base(uuid(), "error"), { path: currentPath, message: message });
    if (file) {
      try {
        var name = new URL(file, location.href).pathname.split("/").pop();
        if (name) record.file = clean(name, 200);
      } catch (_) {}
    }
    if (Number.isSafeInteger(line) && line >= 0) record.line = line;
    if (Number.isSafeInteger(column) && column >= 0) record.column = column;
    send([record]);
    /* @full-begin */
    triggerReplay();
    /* @full-end */
  }

  addEventListener("error", function (event) {
    if (event.target && event.target !== window) return;
    reportError(event.message, event.filename, event.lineno, event.colno);
  });
  addEventListener("unhandledrejection", function (event) {
    var reason = event.reason;
    reportError(reason && reason.message ? reason.message : "Unhandled rejection: " + String(reason).slice(0, 120), reason && reason.fileName, null, null);
  });

  document.addEventListener("click", onClick, true);
  document.addEventListener("submit", function (event) {
    formAttempts++;
    interact(event);
    /* @full-begin */
    var form = event.target && event.target.tagName === "FORM" && forms[formKey(event.target)];
    if (form) form.submitted = true;
    /* @full-end */
  }, true);
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
  document.addEventListener("visibilitychange", function () {
    settle(Date.now());
    /* @full-begin */
    if (document.hidden && replay) replay.flush(true);
    /* @full-end */
  }, false);
  addEventListener("pagehide", summary, false);
  /* @full-begin */
  document.addEventListener("focusin", function (event) {
    if (!visitorId) return;
    var entry = formField(event.target);
    if (entry) entry.since = Date.now();
  }, true);
  document.addEventListener("focusout", function (event) {
    if (!visitorId) return;
    var entry = formField(event.target);
    if (entry && entry.since) {
      entry.ms += Date.now() - entry.since;
      entry.since = 0;
    }
  }, true);
  document.addEventListener("invalid", function (event) {
    if (!visitorId) return;
    var entry = formField(event.target);
    if (entry) entry.errors++;
  }, true);
  setInterval(tickAttention, 1000);
  /* @full-end */

  var observer = "IntersectionObserver" in window ? new IntersectionObserver(function (entries) {
    entries.forEach(function (entry) {
      if (!entry.isIntersecting || entry.intersectionRatio < 0.5) return;
      var id = clean(entry.target.dataset.analyticsSection || "", 64);
      if (!id || sectionSeen[id]) return;
      sectionSeen[id] = true;
      sectionOrder.push(id);
      lastSection = id;
    });
  }, { threshold: [0.5] }) : null;

  function observeSections() {
    if (!observer) return;
    observer.disconnect();
    document.querySelectorAll("[data-analytics-section]").forEach(function (element) { observer.observe(element); });
  }

  // Single-page apps: each route change ends the previous page with its
  // summary and starts a new page view. Opt out with data-spa="false".
  function routeChanged() {
    if (location.pathname === currentPath) return;
    summary();
    currentPath = location.pathname;
    begin();
    spaNavigation = true;
    pageView();
    /* @full-begin */
    if (replay && isExcluded(currentPath)) {
      replay.stop();
      replay = null;
    }
    /* @full-end */
    setTimeout(observeSections, 400);
  }

  if (spa && window.history && history.pushState) {
    ["pushState", "replaceState"].forEach(function (name) {
      var original = history[name];
      history[name] = function () {
        var result = original.apply(this, arguments);
        setTimeout(routeChanged, 0);
        return result;
      };
    });
    addEventListener("popstate", function () { setTimeout(routeChanged, 0); });
  }

  /* @rum-begin */
  if ("PerformanceObserver" in window) {
    try {
      var nav = performance.getEntriesByType("navigation")[0];
      if (nav) rum.ttfb_ms = Math.max(0, nav.responseStart);
    } catch (_) {}
    try { new PerformanceObserver(function (list) {
      list.getEntries().forEach(function (entry) { if (entry.name === "first-contentful-paint") rum.fcp_ms = entry.startTime; });
    }).observe({ type: "paint", buffered: true }); } catch (_) {}
    try { new PerformanceObserver(function (list) {
      var entries = list.getEntries();
      if (entries.length) rum.lcp_ms = entries[entries.length - 1].startTime;
    }).observe({ type: "largest-contentful-paint", buffered: true }); } catch (_) {}
    try { var cls = 0; new PerformanceObserver(function (list) {
      list.getEntries().forEach(function (entry) { if (!entry.hadRecentInput) cls += entry.value; });
      rum.cls_milli = cls * 1000;
    }).observe({ type: "layout-shift", buffered: true }); } catch (_) {}
    try { new PerformanceObserver(function (list) {
      list.getEntries().forEach(function (entry) { if (entry.interactionId) rum.inp_ms = Math.max(rum.inp_ms || 0, entry.duration); });
    }).observe({ type: "event", buffered: true, durationThreshold: 40 }); } catch (_) {}
    try { var frames = 0, blocking = 0; new PerformanceObserver(function (list) {
      list.getEntries().forEach(function (entry) { frames++; blocking += Math.max(0, entry.duration - 50); });
      rum.long_frame_count = frames;
      rum.blocking_ms = blocking;
    }).observe({ type: "long-animation-frame", buffered: true }); } catch (_) {}
  }
  /* @rum-end */

  /* @full-begin */
  // ---------------------------------------------------------- consent

  // Every visit starts as Lite. Identity exists only once consent is known
  // (granted, or not required by the site's policy for this visitor) and is
  // dropped the moment consent is withdrawn or Global Privacy Control is on.
  function load(name) {
    try {
      return localStorage.getItem(storagePrefix + name);
    } catch (_) {
      return null;
    }
  }

  function save(name, value) {
    try {
      if (value == null) localStorage.removeItem(storagePrefix + name);
      else localStorage.setItem(storagePrefix + name, value);
    } catch (_) {}
  }

  // Visitor IDs live 13 months.
  function storedVisitor() {
    var parts = (load("visitor") || "").split(".");
    if (!isUuid(parts[0]) || !(Date.now() - Number(parts[1]) < 395 * 86400000)) return null;
    return parts[0];
  }

  // A session ends after 30 minutes without activity.
  function currentSession() {
    var now = Date.now();
    var parts = (load("session") || "").split(".");
    var id = isUuid(parts[0]) && now - Number(parts[1]) < 1800000 ? parts[0] : uuid();
    save("session", id + "." + now);
    return id;
  }

  function establish(state, adopted) {
    visitorId = adopted ? adopted.visitor : storedVisitor();
    if (!visitorId) {
      visitorId = uuid();
      save("visitor", visitorId + "." + Date.now());
    } else if (adopted) {
      save("visitor", visitorId + "." + Date.now());
    }
    if (adopted) save("session", adopted.session + "." + Date.now());
    sessionId = currentSession();
    consent = state;
    save("consent", state === "granted" ? "granted" : "auto");
    if (arrivedClickId) save("click", arrivedClickId + "." + sessionId);
    if (arrival) remember(arrival);
  }

  function clearIdentity(state) {
    visitorId = null;
    sessionId = null;
    linkToken = null;
    save("visitor", null);
    save("session", null);
    save("click", null);
    save("arrival", null);
    save("replay", null);
    save("consent", state === "denied" ? "denied" : null);
    consent = state;
    if (replay) {
      replay.stop();
      replay = null;
    }
  }

  function restore() {
    if (gpc) {
      consent = "gpc";
      save("visitor", null);
      save("session", null);
      return;
    }
    var decided = load("consent");
    if (decided === "denied") {
      consent = "denied";
      return;
    }
    if (decided !== "granted" && decided !== "auto") return;
    visitorId = storedVisitor();
    if (!visitorId) return;
    consent = decided === "granted" ? "granted" : "not_required";
    sessionId = currentSession();
    var click = (load("click") || "").split(".");
    if (click[1] === sessionId && click[0]) arrivedClickId = click[0];
    save("click", null);
  }

  function sendConsent() {
    send([Object.assign(base(uuid(), "consent"), { state: consent === "granted" ? "granted" : "not_required" })], decision);
  }

  function setConsent(value) {
    if (value === "granted") {
      hideBanner();
      if (gpc || consent === "granted") return;
      establish("granted");
      sendConsent();
    } else if (value === "denied") {
      hideBanner();
      if (consent === "denied") return;
      clearIdentity("denied");
      send([Object.assign(base(uuid(), "consent"), { state: "denied" })]);
    }
  }

  // The server's answer to a page view or consent record.
  function decision(response) {
    if (!response) return;
    if (response.upgrade === "never") {
      if (visitorId || consent !== "gpc") clearIdentity("gpc");
      return;
    }
    if (response.drop) clearIdentity("pending");
    linkToken = response.link || null;
    excluded = Array.isArray(response.exclude) ? response.exclude : [];
    linkDomains = Array.isArray(response.domains) ? response.domains : [];
    replayConfig = response.replay || null;
    if (response.upgrade === "grant" && !visitorId && !gpc && consent !== "denied") {
      establish("not_required");
      sendConsent();
      return;
    }
    if (response.upgrade === "ask" && consent === "pending" && response.banner) showBanner(response.banner);
    if (visitorId) startReplay();
  }

  // Google Consent Mode: gtag('consent', 'default' | 'update', { analytics_storage }).
  function watchConsentMode() {
    var layer = window.dataLayer;
    if (!Array.isArray(layer)) return;
    function inspect(entry) {
      if (!entry || entry[0] !== "consent" || !entry[2] || typeof entry[2].analytics_storage !== "string") return;
      var granted = entry[2].analytics_storage === "granted";
      if (granted) setConsent("granted");
      else if (entry[1] === "update") setConsent("denied");
    }
    for (var i = 0; i < layer.length; i++) inspect(layer[i]);
    var push = layer.push;
    layer.push = function () {
      var result = push.apply(layer, arguments);
      for (var j = 0; j < arguments.length; j++) inspect(arguments[j]);
      return result;
    };
  }

  function hideBanner() {
    if (bannerHost) bannerHost.remove();
    bannerHost = null;
  }

  // The built-in banner: one sentence, two equal buttons, no dark patterns.
  function showBanner(config) {
    // The operator looking at the heatmap overlay is not a visitor to ask.
    if (overlay) return;
    if (bannerHost || !document.body) return;
    bannerHost = document.createElement("div");
    var root = bannerHost.attachShadow ? bannerHost.attachShadow({ mode: "open" }) : bannerHost;
    var text = clean(config.text || "", 400) || "This site would like to measure how visitors use it, to improve it. Nothing is stored on your device unless you allow it.";
    root.innerHTML = "<style>" +
      ".b{position:fixed;z-index:2147483646;left:16px;right:16px;bottom:16px;max-width:520px;margin:0 auto;background:#fff;color:#282421;" +
      "border:1px solid #e9e4e1;border-radius:12px;box-shadow:0 16px 40px -8px #28242133;padding:16px 18px;font:14px/20px system-ui,-apple-system,sans-serif}" +
      ".b p{margin:0 0 12px}.b a{color:inherit}.r{display:flex;gap:8px;justify-content:flex-end;flex-wrap:wrap}" +
      "button{font:inherit;font-weight:600;padding:8px 16px;border-radius:8px;border:1px solid #ddd5d1;background:#fff;color:#282421;cursor:pointer}" +
      "button:focus-visible{outline:2px solid #282421;outline-offset:2px}</style>" +
      "<div class=\"b\" role=\"dialog\" aria-live=\"polite\" aria-label=\"Analytics consent\"><p></p><div class=\"r\">" +
      "<button type=\"button\" data-choice=\"denied\">No thanks</button><button type=\"button\" data-choice=\"granted\">Allow</button></div></div>";
    root.querySelector("p").textContent = text + " ";
    if (config.privacy_url && /^https?:\/\//.test(config.privacy_url)) {
      var link = document.createElement("a");
      link.href = config.privacy_url;
      link.textContent = "Privacy policy";
      link.rel = "noopener";
      root.querySelector("p").appendChild(link);
    }
    root.querySelectorAll("button").forEach(function (button) {
      button.addEventListener("click", function () { setConsent(button.getAttribute("data-choice")); });
    });
    document.body.appendChild(bannerHost);
  }

  // ---------------------------------------------------------- cross-domain

  // Links to the site's other domains carry a short-lived signed token so
  // the visit continues there as the same visitor and session.
  var linkArrival = null;
  function readLink() {
    try {
      var url = new URL(location.href);
      var token = url.searchParams.get("_an");
      if (!token) return;
      url.searchParams.delete("_an");
      history.replaceState(history.state, "", url.pathname + url.search + url.hash);
      var parts = token.split(".")[0].split("~");
      if (gpc || consent === "denied" || parts[0] !== site || !isUuid(parts[1]) || !isUuid(parts[2])) return;
      linkArrival = clean(token, 300);
      establish("granted", { visitor: parts[1], session: parts[2] });
    } catch (_) {}
  }

  function decorate(event) {
    if (!linkToken || !visitorId) return;
    var link = event.target && event.target.closest && event.target.closest("a[href]");
    if (!link) return;
    try {
      var url = new URL(link.href, location.href);
      if (url.origin === location.origin || linkDomains.indexOf(url.origin) < 0) return;
      url.searchParams.set("_an", linkToken);
      link.href = url.href;
    } catch (_) {}
  }
  document.addEventListener("mousedown", decorate, true);
  document.addEventListener("keydown", function (event) { if (event.key === "Enter") decorate(event); }, true);
  document.addEventListener("click", decorate, true);

  // ---------------------------------------------------------- replay

  // Replays load only for consented visitors on sites that record them:
  // sampled sessions stream; with triggers on, others keep a short buffer
  // that is sent only after a rage click, an error or a goal.
  function sampled(id) {
    var hash = 0;
    for (var i = 0; i < id.length; i++) hash = (hash * 31 + id.charCodeAt(i)) >>> 0;
    return hash % 100 < replayConfig.rate;
  }

  function startReplay() {
    if (!replayConfig || !visitorId || replay || replayRequested || !window.CompressionStream || isExcluded(currentPath)) return;
    var stream = sampled(sessionId) || load("replay") === sessionId;
    if (!stream && !replayConfig.triggers) return;
    replayRequested = true;
    var loader = document.createElement("script");
    loader.src = origin + "__REPLAY_PATH__";
    loader.async = true;
    loader.onload = function () {
      if (!visitorId || !window.__analyticoRecorder) return;
      replay = window.__analyticoRecorder({
        endpoint: origin + "/r",
        site: site,
        visitor: visitorId,
        session: sessionId,
        page: function () { return pageId; },
        stream: stream,
        maskText: replayConfig.mask_text !== false
      });
    };
    document.head.appendChild(loader);
  }

  function triggerReplay() {
    if (!visitorId || !replayConfig || !replayConfig.triggers) return;
    save("replay", sessionId);
    if (replay) replay.trigger();
  }

  restore();
  if (!gpc) readLink();
  try {
    var clickQuery = new URLSearchParams(location.search);
    ["gclid", "gbraid", "wbraid", "fbclid", "msclkid"].some(function (name) {
      var value = clickQuery.get(name);
      if (value && /^[A-Za-z0-9_.-]{1,190}$/.test(value)) {
        arrivedClickId = name + ":" + value;
        return true;
      }
      return false;
    });
  } catch (_) {}
  /* @full-end */

  // ---------------------------------------------------------- heatmap overlay

  // "Open on site" from the workspace: #analytico-heatmap=<token> loads the
  // overlay. The operator's own view is marked internal.
  var overlay = /[#&]analytico-heatmap=([A-Za-z0-9~._-]{40,300})/.exec(location.hash);
  if (overlay) {
    internal = true;
    var overlayScript = document.createElement("script");
    overlayScript.src = origin + "__OVERLAY_PATH__";
    overlayScript.onload = function () {
      if (window.__analyticoOverlay) window.__analyticoOverlay({ origin: origin, site: site, token: overlay[1] });
    };
    document.head.appendChild(overlayScript);
  }

  var api = window.analytico && Array.isArray(window.analytico.q) ? window.analytico.q : [];
  window.analytico = { track: track };
  /* @session-begin */
  window.analytico.actionSucceeded = function (id, properties) { return finishAction(id, "succeeded", properties); };
  window.analytico.actionFailed = function (id, properties) { return finishAction(id, "failed", properties); };
  window.analytico.flow = function (name, properties) { return track(name, properties); };
  /* @session-end */
  /* @full-begin */
  window.analytico.consent = function (value) { setConsent(value); };
  window.analytico.identify = function (userId) {
    userId = clean(userId == null ? "" : String(userId), 128);
    if (!userId || !visitorId) return false;
    send([Object.assign(base(uuid(), "identify"), { user_id: userId })]);
    return true;
  };
  // A new visitor ID for the next person on a shared device.
  window.analytico.reset = function () {
    if (!visitorId) return;
    visitorId = uuid();
    save("visitor", visitorId + "." + Date.now());
    save("session", null);
    sessionId = currentSession();
    if (replay) {
      replay.stop();
      replay = null;
      replayRequested = false;
    }
  };
  // Erases everything stored about this visitor and stops tracking them.
  window.analytico.forget = function () {
    if (visitorId) send([base(uuid(), "forget")]);
    clearIdentity("denied");
  };
  window.analytico.variant = function (experiment, variant) {
    return track("experiment_viewed", { experiment: clean(String(experiment), 64), variant: clean(String(variant), 64) });
  };
  window.analytico.replay = function () { triggerReplay(); };
  /* @full-end */

  begin();
  observeSections();
  pageView();
  if (pageType === "404") track("page_not_found", {});
  /* @full-begin */
  watchConsentMode();
  /* @full-end */
  api.forEach(function (call) {
    var name = call && call[0];
    if (typeof window.analytico[name] === "function") window.analytico[name].apply(null, Array.prototype.slice.call(call, 1));
  });
}());
