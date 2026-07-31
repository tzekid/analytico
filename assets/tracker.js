(() => {
  const script = document.currentScript;
  const site = script?.dataset.site;
  if (!site) return;
  const endpoint = new URL("/v1/event", script.src).href;

  function send(type, name, properties) {
    const query = new URLSearchParams(location.search);
    const utm = {};
    for (const field of ["source", "medium", "campaign", "term", "content"]) {
      const value = query.get(`utm_${field}`);
      if (value) utm[field] = value;
    }
    const payload = {
      v: 1,
      site,
      type,
      path: location.pathname,
      referrer: document.referrer || undefined,
      utm: Object.keys(utm).length ? utm : undefined,
      name,
      properties,
    };
    const body = JSON.stringify(payload);
    try {
      if (navigator.sendBeacon(
        endpoint,
        new Blob([body], { type: "text/plain;charset=UTF-8" }),
      )) return;
      fetch(endpoint, {
        method: "POST",
        body,
        headers: { "Content-Type": "text/plain;charset=UTF-8" },
        keepalive: true,
        credentials: "omit",
      }).catch(() => {});
    } catch (_) {}
  }

  window.analytico = {
    event(name, properties) {
      send("event", name, properties);
    },
  };
  send("pageview");
})();
