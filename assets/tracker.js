(() => {
  const script = document.currentScript;
  const site = script && script.dataset.site;
  if (!site) return;
  const endpoint = new URL("/v2/event", script.src).href;
  const prefix = "anl:" + site;
  const anonymousKey = prefix + ":a";
  const sessionKey = prefix + ":s";
  const identifiedKey = prefix + ":u";
  const idleLimitMs = 30 * 60 * 1000;

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

  let identityQuality = "persistent";
  let anonymousId = "";
  let session = null;

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

  loadIdentity();

  function send(type, extra) {
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
      const utm = {};
      if (type !== "identify") {
        const params = new URLSearchParams(location.search);
        for (const field of ["source", "medium", "campaign", "term", "content"]) {
          const value = params.get("utm_" + field);
          if (value) utm[field] = value;
        }
      }
      const title = (document.title || "").slice(0, 512);
      const body = JSON.stringify(Object.assign({
        v: 2,
        site,
        event_id: eventId,
        anonymous_id: anonymousId,
        identity_quality: identityQuality,
        session_id: session.id,
        sequence,
        occurred_at_ms: now,
        type,
        page: {
          path: location.pathname,
          title,
          hostname: location.hostname,
        },
        referrer: type === "identify" ? undefined : document.referrer || undefined,
        utm: Object.keys(utm).length ? utm : undefined,
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
    remove(anonymousKey);
    remove(sessionKey);
    remove(identifiedKey);
    anonymousId = "";
    session = null;
    loadIdentity();
  }

  window.analytico = {
    track(name, properties) {
      send("event", { name, properties });
    },
    identify,
    reset,
  };
  send("pageview");
})();
