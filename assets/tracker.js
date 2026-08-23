(() => {
  const script = document.currentScript;
  const site = script && script.dataset.site;
  if (!site) return;
  const endpoint = new URL("/v2/event", script.src).href;
  const collectorOrigin = new URL(script.src).origin;
  const host = location.hostname.toLowerCase();
  if (host === "localhost" || host.endsWith(".localhost") ||
      host === "127.0.0.1" || host === "::1" || host === "[::1]") {
    window.analytico = { track() {}, identify() {}, reset() {} };
    return;
  }
  const prefix = "anl:" + site;
  const anonymousKey = prefix + ":a";
  const sessionKey = prefix + ":s";
  const identifiedKey = prefix + ":u";
  const exclusionKey = prefix + ":x";
  const idleLimitMs = 30 * 60 * 1000;
  const activeLimitMs = 60 * 1000;
  const engagementIntervalMs = 15 * 1000;
  const spaEnabled = script.dataset.spa === "auto";
  const engagementEnabled = script.dataset.engagement === "true";
  const outboundEnabled = script.dataset.outbound === "true";
  const downloadsEnabled = script.dataset.downloads === "true";
  const formsEnabled = script.dataset.forms === "true";
  const notFoundEnabled = script.dataset.notFound === "true";
  const downloadPattern = /\.(pdf|csv|docx?|xlsx?|zip|rar|7z|gz|mp3|mp4|mov|dmg|pkg|exe)$/i;

  function uuid() {
    try {
      if (crypto.randomUUID) return crypto.randomUUID();
      const bytes = new Uint8Array(16);
      crypto.getRandomValues(bytes);
      bytes[6] = bytes[6] & 15 | 64;
      bytes[8] = bytes[8] & 63 | 128;
      let hex = "";
      for (let i = 0; i < 16; i++) hex += (bytes[i] + 256).toString(16).slice(1);
      return hex.slice(0, 8) + "-" + hex.slice(8, 12) + "-" + hex.slice(12, 16) +
        "-" + hex.slice(16, 20) + "-" + hex.slice(20);
    } catch (_) {
      return "";
    }
  }

  function read(key) {
    try {
      return localStorage.getItem(key);
    } catch (_) {
      return null;
    }
  }

  function write(key, value) {
    try {
      localStorage.setItem(key, value);
      return 1;
    } catch (_) {
      return 0;
    }
  }

  function remove(key) {
    try {
      localStorage.removeItem(key);
    } catch (_) {}
  }

  const controlPrefix = "#analytico-self-exclusion=";
  let controlAction = "";
  if (location.hash.startsWith(controlPrefix)) {
    const parts = location.hash.slice(controlPrefix.length).split(":");
    if (parts.length === 2 && parts[1] === site &&
        (parts[0] === "on" || parts[0] === "off")) {
      controlAction = parts[0];
    }
  }
  let selfExcluded = controlAction !== "" || read(exclusionKey) === "1";

  if (controlAction && window.opener) {
    addEventListener("message", (event) => {
      try {
        const data = event.data;
        if (event.origin !== collectorOrigin || event.source !== window.opener ||
            !data || data.analytico !== "self-exclusion-apply" ||
            data.site !== site || data.action !== controlAction) return;
        if (controlAction === "on") {
          write(exclusionKey, "1");
        } else {
          remove(exclusionKey);
        }
        history.replaceState(history.state, "", location.pathname + location.search);
        window.opener.postMessage({
          analytico: "self-exclusion-applied",
          site,
          action: controlAction,
        }, collectorOrigin);
      } catch (_) {}
    });
    try {
      window.opener.postMessage({
        analytico: "self-exclusion-ready",
        site,
        action: controlAction,
      }, collectorOrigin);
    } catch (_) {}
  }

  function validText(value, maximum, allowEmpty) {
    if (typeof value !== "string" || (!allowEmpty && !value) ||
        value.length > maximum ||
        /[\u0000-\u001f\u007f-\u009f]/.test(value)) return 0;
    try {
      return new TextEncoder().encode(value).length <= maximum;
    } catch (_) {
      return 0;
    }
  }

  function boundedTraits(value) {
    if (!value || typeof value !== "object" || Array.isArray(value)) return null;
    const result = Object.create(null);
    let count = 0;
    try {
      for (const key in value) {
        if (!Object.prototype.hasOwnProperty.call(value, key)) continue;
        if (++count > 16 || !/^[A-Za-z0-9_.:-]{1,64}$/.test(key)) return null;
        const item = value[key];
        if (item === null || typeof item === "boolean" ||
            (typeof item === "number" && Number.isSafeInteger(item)) ||
            validText(item, 512, 1)) {
          result[key] = item;
        } else {
          return null;
        }
      }
      return result;
    } catch (_) {
      return null;
    }
  }

  function currentPage() {
    return {
      path: location.pathname,
      title: (document.title || "").slice(0, 512),
      hostname: location.hostname,
    };
  }

  function eventExtra(properties) {
    if (!properties || typeof properties !== "object" || Array.isArray(properties)) {
      return { properties };
    }
    const hasValue = Object.prototype.hasOwnProperty.call(properties, "value");
    const hasCurrency = Object.prototype.hasOwnProperty.call(properties, "currency");
    if (!hasValue && !hasCurrency) return { properties };
    if (!hasValue || !hasCurrency ||
        typeof properties.value !== "string" ||
        !/^-?(0|[1-9][0-9]{0,11})(\.[0-9]{1,6})?$/.test(properties.value) ||
        typeof properties.currency !== "string" ||
        !/^[A-Z]{3}$/.test(properties.currency)) return null;
    const ordinary = Object.create(null);
    for (const key in properties) {
      if (!Object.prototype.hasOwnProperty.call(properties, key) ||
          key === "value" || key === "currency") continue;
      ordinary[key] = properties[key];
    }
    return {
      properties: Object.keys(ordinary).length ? ordinary : undefined,
      value: { amount: properties.value, currency: properties.currency },
    };
  }

  let identityQuality = "persistent";
  let anonymousId = "";
  let session = null;
  let activated = document.prerendering !== true;

  function persistSession() {
    if (!session) return 0;
    return write(sessionKey, JSON.stringify(session));
  }

  function createSession(now) {
    const id = uuid();
    if (!id) return null;
    return { id, last_activity_ms: now, sequence: 0 };
  }

  function loadSession(now) {
    const raw = read(sessionKey);
    if (raw) {
      try {
        const parsed = JSON.parse(raw);
        if (parsed && parsed.id &&
            typeof parsed.last_activity_ms === "number" &&
            typeof parsed.sequence === "number" &&
            now - parsed.last_activity_ms <= idleLimitMs) {
          return parsed;
        }
      } catch (_) {}
    }
    const created = createSession(now);
    if (!created) return null;
    if (!write(sessionKey, JSON.stringify(created))) identityQuality = "ephemeral";
    return created;
  }

  function loadIdentity() {
    const now = Date.now();
    identityQuality = "persistent";
    anonymousId = read(anonymousKey);
    if (!anonymousId) {
      const next = uuid();
      if (!next) {
        identityQuality = "ephemeral";
        return;
      }
      anonymousId = next;
      if (!write(anonymousKey, next)) identityQuality = "ephemeral";
    }
    session = loadSession(now);
    if (!session) {
      identityQuality = "ephemeral";
      return;
    }
  }

  if (activated) loadIdentity();

  function send(type, extra, page) {
    if (!activated) return "";
    if (!anonymousId || !session) loadIdentity();
    if (!anonymousId || !session) return "";
    const eventId = uuid();
    if (!eventId) return "";
    try {
      const now = Date.now();
      if (now - session.last_activity_ms > idleLimitMs) {
        session = loadSession(now);
        if (!session) return "";
      }
      const sequence = session.sequence;
      session.sequence = sequence + 1;
      session.last_activity_ms = now;
      if (!persistSession()) identityQuality = "ephemeral";
      const attributed = type === "pageview" || type === "event";
      const utm = {};
      if (attributed) {
        const params = new URLSearchParams(location.search);
        for (const field of ["source", "medium", "campaign", "term", "content"]) {
          const value = params.get("utm_" + field);
          if (value) utm[field] = value;
        }
      }
      const body = JSON.stringify(Object.assign({
        v: 2,
        site,
        event_id: eventId,
        anonymous_id: anonymousId,
        identity_quality: identityQuality,
        session_id: session.id,
        sequence,
        occurred_at_ms: now,
        self_excluded: selfExcluded || undefined,
        type,
        page: page || currentPage(),
        referrer: attributed ? document.referrer || undefined : undefined,
        utm: attributed && Object.keys(utm).length ? utm : undefined,
      }, extra));
      try {
        if (navigator.sendBeacon(endpoint, body)) return eventId;
      } catch (_) {}
      fetch(endpoint, {
        method: "POST",
        body,
        keepalive: true,
        credentials: "omit",
      }).catch(() => {});
      return eventId;
    } catch (_) {
      return "";
    }
  }

  function identify(userId, traits) {
    if (identityQuality !== "persistent" ||
        !validText(userId, 160, 0)) return;
    const safeTraits = traits === undefined ? undefined : boundedTraits(traits);
    if (traits !== undefined && safeTraits === null) return;
    if (!send("identify", {
      user: { id: userId, traits: safeTraits },
    })) return;
    const current = read(identifiedKey);
    if (!current || current === userId) write(identifiedKey, userId);
  }

  function reset() {
    if (engagementEnabled) resetPageEngagement();
    remove(anonymousKey);
    remove(sessionKey);
    remove(identifiedKey);
    anonymousId = "";
    session = null;
    loadIdentity();
  }

  let trackedPage = currentPage();
  let visible = document.visibilityState !== "hidden";
  let activityAt = Date.now();
  let sampledAt = activityAt;
  let pendingActiveMs = 0;
  let maxScrollDepth = 0;

  function scrollDepth() {
    const root = document.documentElement;
    const body = document.body;
    const height = Math.max(
      root ? root.scrollHeight : 0,
      root ? root.offsetHeight : 0,
      body ? body.scrollHeight : 0,
      body ? body.offsetHeight : 0,
    );
    if (!height) return 0;
    return Math.max(0, Math.min(100,
      Math.floor(((window.scrollY + window.innerHeight) * 100) / height)));
  }

  function captureActive(now) {
    if (now < sampledAt) {
      sampledAt = now;
      return;
    }
    if (visible) {
      const activeEnd = Math.min(now, activityAt + activeLimitMs);
      if (activeEnd > sampledAt) pendingActiveMs += activeEnd - sampledAt;
    }
    sampledAt = now;
  }

  function emitEngagement(page) {
    const now = Date.now();
    captureActive(now);
    const activeMs = Math.min(60_000, Math.floor(pendingActiveMs));
    if (activeMs <= 0) return;
    if (send("engagement", {
      engagement: { active_ms: activeMs, max_scroll_depth: maxScrollDepth },
    }, page)) pendingActiveMs -= activeMs;
  }

  function resetPageEngagement() {
    const now = Date.now();
    activityAt = now;
    sampledAt = now;
    pendingActiveMs = 0;
    maxScrollDepth = scrollDepth();
  }

  function navigation() {
    const next = currentPage();
    if (next.path === trackedPage.path) return;
    if (engagementEnabled) emitEngagement(trackedPage);
    trackedPage = next;
    if (engagementEnabled) resetPageEngagement();
    if (activated) send("pageview", undefined, trackedPage);
  }

  if (spaEnabled) {
    for (const name of ["pushState", "replaceState"]) {
      const original = history[name];
      history[name] = function () {
        const result = original.apply(this, arguments);
        try {
          navigation();
        } catch (_) {}
        return result;
      };
    }
    addEventListener("popstate", () => {
      try {
        navigation();
      } catch (_) {}
    });
  }

  if (engagementEnabled) {
    maxScrollDepth = scrollDepth();
    const activity = (event) => {
      try {
        const now = Date.now();
        captureActive(now);
        activityAt = now;
        if (event.type === "scroll") {
          maxScrollDepth = Math.max(maxScrollDepth, scrollDepth());
        }
      } catch (_) {}
    };
    for (const name of ["scroll", "pointerdown", "touchstart", "keydown"]) {
      addEventListener(name, activity, { passive: true });
    }
    document.addEventListener("visibilitychange", () => {
      try {
        const now = Date.now();
        captureActive(now);
        visible = document.visibilityState !== "hidden";
        sampledAt = now;
        if (!visible) emitEngagement(trackedPage);
      } catch (_) {}
    });
    addEventListener("pagehide", () => {
      try {
        emitEngagement(trackedPage);
        visible = false;
        sampledAt = Date.now();
      } catch (_) {}
    });
    setInterval(() => {
      try {
        emitEngagement(trackedPage);
      } catch (_) {}
    }, engagementIntervalMs);
  }

  if (outboundEnabled || downloadsEnabled) {
    document.addEventListener("click", (event) => {
      try {
        const target = event.target;
        const link = target && typeof target.closest === "function" ?
          target.closest("a[href]") : null;
        if (!link) return;
        const url = new URL(link.href, location.href);
        if (url.protocol !== "http:" && url.protocol !== "https:") return;
        const extensionMatch = url.pathname.match(downloadPattern);
        if (downloadsEnabled &&
            (link.hasAttribute("download") || extensionMatch)) {
          const properties = { url_path: url.pathname.slice(0, 512) };
          if (extensionMatch) properties.extension = extensionMatch[1].toLowerCase();
          send("event", { name: "file_download", properties });
        } else if (outboundEnabled && url.origin !== location.origin) {
          send("event", {
            name: "outbound_click",
            properties: { url_host: url.hostname.slice(0, 253) },
          });
        }
      } catch (_) {}
    }, { passive: true });
  }

  if (formsEnabled) {
    document.addEventListener("submit", (event) => {
      try {
        const form = event.target;
        if (!form || form.tagName !== "FORM") return;
        const action = new URL(form.getAttribute("action") || location.href, location.href);
        const properties = {
          action_path: action.pathname.slice(0, 512),
          action_host: action.hostname.slice(0, 253),
        };
        const formId = form.id || form.getAttribute("name") || "";
        if (validText(formId, 128, 0)) properties.form_id = formId;
        send("event", { name: "form_submit", properties });
      } catch (_) {}
    }, { passive: true });
  }

  window.analytico = {
    track(name, properties) {
      try {
        const extra = eventExtra(properties);
        if (extra) send("event", Object.assign({ name }, extra));
      } catch (_) {}
    },
    identify,
    reset,
  };
  function initialEvents() {
    if (!activated) return;
    send("pageview", undefined, trackedPage);
    if (notFoundEnabled) send("event", { name: "not_found" }, trackedPage);
  }

  if (activated) {
    initialEvents();
  } else {
    document.addEventListener("prerenderingchange", () => {
      try {
        if (document.prerendering === true) return;
        activated = true;
        loadIdentity();
        trackedPage = currentPage();
        visible = document.visibilityState !== "hidden";
        if (engagementEnabled) resetPageEngagement();
        initialEvents();
      } catch (_) {}
    }, { once: true });
  }
})();
