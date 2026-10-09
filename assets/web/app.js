// Analytico workspace runtime. Pages are complete server-rendered HTML; this
// file makes moving between them instant and adds the few interactions HTML
// cannot express. Everything works without it, just with full page loads.
(() => {
  "use strict";
  const $ = (selector, root = document) => root.querySelector(selector);
  const $$ = (selector, root = document) => Array.from(root.querySelectorAll(selector));
  const number = (value) => Math.round(value).toLocaleString("en-US");
  const duration = (ms) => {
    const seconds = Math.round(Math.max(ms, 0) / 1000);
    if (seconds < 60) return `${seconds}s`;
    const minutes = Math.floor(seconds / 60);
    if (minutes < 60) return `${minutes}m ${String(seconds % 60).padStart(2, "0")}s`;
    return `${Math.floor(minutes / 60)}h ${String(minutes % 60).padStart(2, "0")}m`;
  };
  const debounce = (fn, wait) => {
    let timer;
    return (...args) => { clearTimeout(timer); timer = setTimeout(() => fn(...args), wait); };
  };
  const here = () => location.pathname + location.search;
  // Requests from the workspace's own navigation say so; the server answers
  // them without the parts a full page load needs.
  const getPage = (url) => fetch(url, { headers: { "x-requested-with": "fetch" } });
  const getJson = (url) => fetch(url).then((response) => response.json());

  // ------------------------------------------------------------ navigation

  // Pages fetched ahead of a click (hover, touch, press) are used as they are
  // for 15 seconds. Pages seen in the last five minutes show at once on
  // back/forward or a revisit, then refresh in place.
  const ahead = new Map();
  const seen = new Map();
  const AHEAD_MS = 15000;
  const SEEN_MS = 5 * 60000;
  const sameOrigin = (url) => url.origin === location.origin;
  const navigable = (url) => sameOrigin(url) && !url.pathname.startsWith("/_/") && !/\.(csv|json)$/.test(url.pathname) && !url.pathname.startsWith("/oauth/") && !url.pathname.startsWith("/auth/") && !url.pathname.endsWith("/heatmaps/open") && !url.pathname.endsWith("/stream");
  const reducedMotion = () => matchMedia("(prefers-reduced-motion: reduce)").matches;

  function fetchPage(href) {
    return getPage(href)
      .then(async (response) => ({ ok: response.ok || response.status < 500, url: response.url, html: await response.text(), type: response.headers.get("content-type") || "" }));
  }

  function prefetch(href, warm = false) {
    const cached = ahead.get(href);
    if (cached && Date.now() - cached.at < AHEAD_MS) {
      if (warm) cached.promise.then(warmResources, () => {});
      return cached.promise;
    }
    const promise = fetchPage(href);
    ahead.set(href, { at: Date.now(), promise });
    promise.then((page) => { if (warm) warmResources(page); }, () => ahead.delete(href));
    return promise;
  }

  // A replay page's recording and player load while the pointer is still on
  // the button.
  function warmResources(page) {
    if (!page.type.startsWith("text/html")) return;
    const replay = /data-replay="([^"]+)"/.exec(page.html);
    if (replay) fetch(replay[1].replaceAll("&amp;", "&")).catch(() => {});
    const player = /data-player-src="([^"]+)"/.exec(page.html);
    if (player && !$(`link[rel=prefetch][href="${player[1]}"]`)) {
      const link = document.createElement("link");
      link.rel = "prefetch";
      link.href = player[1];
      document.head.appendChild(link);
    }
  }

  function keep(href, page) {
    if (!page.type.startsWith("text/html") || !page.ok) return;
    seen.delete(href);
    seen.set(href, { ...page, at: Date.now() });
    if (seen.size > 12) seen.delete(seen.keys().next().value);
  }

  function forgetPages() {
    ahead.clear();
    seen.clear();
  }

  // Each website opens with the period it was last viewed in (filters are
  // for the moment and are not brought back). It lives in a cookie the server
  // also reads on full loads.
  const viewKeys = ["range", "from", "to", "cmp"];
  const cookie = (name) => document.cookie.split("; ").find((part) => part.startsWith(`${name}=`))?.slice(name.length + 1);
  function remembered(url) {
    const slug = url.pathname.split("/")[1];
    if (!slug || viewKeys.some((key) => url.searchParams.has(key))) return url;
    // Within a website, links already carry the view.
    if ($("main[data-site]")?.dataset.site === slug && location.pathname.split("/")[1] === slug) return url;
    const saved = cookie(`an_view_${slug}`);
    if (!saved) return url;
    const next = new URL(url);
    for (const [key, value] of new URLSearchParams(decodeURIComponent(saved))) next.searchParams.append(key, value);
    return next;
  }
  function rememberView() {
    const main = $("main[data-site]");
    if (!main || main.dataset.view === undefined || location.pathname.split("/")[1] !== main.dataset.site) return;
    const name = `an_view_${main.dataset.site}`;
    const all = new URLSearchParams(main.dataset.view.replace(/^\?/, ""));
    const view = new URLSearchParams(viewKeys.flatMap((key) => all.getAll(key).map((value) => [key, value]))).toString();
    document.cookie = view ? `${name}=${encodeURIComponent(view)}; path=/; max-age=2592000; samesite=lax` : `${name}=; path=/; max-age=0; samesite=lax`;
    // A full load opened with the remembered view shows it in the address bar.
    const params = new URLSearchParams(location.search);
    if (view && !viewKeys.some((key) => params.has(key))) history.replaceState(history.state, "", `${location.pathname}?${[location.search.slice(1), view].filter(Boolean).join("&")}`);
  }

  // The progress bar appears only when a page takes long enough to notice.
  let loadingTimer = 0;
  function loading(on) {
    clearTimeout(loadingTimer);
    if (on) loadingTimer = setTimeout(() => document.documentElement.classList.add("loading"), 150);
    else document.documentElement.classList.remove("loading");
  }

  // ---- morphing: patch the page in place instead of replacing it, so what
  // did not change (focus, open menus, scroll inside panels) stays put.

  const clientAttributes = new Set(["data-ready", "data-prefetched", "data-dirty", "data-warmed"]);

  function sameKind(a, b) {
    if (a.nodeType !== b.nodeType) return false;
    if (a.nodeType !== 1) return true;
    return a.tagName === b.tagName && (a.id || "") === (b.id || "");
  }

  function syncAttributes(from, to) {
    for (const { name } of Array.from(from.attributes)) {
      if (!to.hasAttribute(name) && !clientAttributes.has(name)) from.removeAttribute(name);
    }
    for (const { name, value } of Array.from(to.attributes)) if (from.getAttribute(name) !== value) from.setAttribute(name, value);
  }

  function sameAttributes(a, b) {
    for (const { name, value } of Array.from(b.attributes)) if (a.getAttribute(name) !== value) return false;
    for (const { name } of Array.from(a.attributes)) if (!clientAttributes.has(name) && !b.hasAttribute(name)) return false;
    return true;
  }

  function syncValue(from, to) {
    if (from === document.activeElement) return;
    if (from instanceof HTMLInputElement) {
      if (from.type === "checkbox" || from.type === "radio") from.checked = to.hasAttribute("checked");
      else if (from.type !== "file") from.value = to.getAttribute("value") ?? "";
    } else if (from instanceof HTMLTextAreaElement) from.value = to.textContent;
    else if (from instanceof HTMLSelectElement) {
      const chosen = to.querySelector("option[selected]") || to.querySelector("option");
      if (chosen) from.value = chosen.getAttribute("value") ?? chosen.textContent;
    }
  }

  function update(from, to) {
    if (from.nodeType !== 1) {
      if (from.nodeValue !== to.nodeValue) {
        if (from.parentElement?.closest(".metric-value")) tweenNumber(from, from.nodeValue, to.nodeValue);
        else from.nodeValue = to.nodeValue;
      }
      return;
    }
    // Elements set up by this script (charts, players) stay as they are, or
    // are replaced whole when their data changed.
    if (from.hasAttribute("data-ready")) {
      if (sameAttributes(from, to)) return;
      const paths = from.matches(".chart") ? $$("path", from).map((path) => path.getAttribute("d")) : null;
      from.replaceWith(to);
      if (paths) tweenPaths(to, paths);
      return;
    }
    if (from.tagName === "DIALOG" && from.open && !to.hasAttribute("open")) from.close();
    syncAttributes(from, to);
    if (from instanceof HTMLInputElement || from instanceof HTMLSelectElement || from instanceof HTMLTextAreaElement) syncValue(from, to);
    if (from.tagName !== "TEXTAREA") morphChildren(from, to);
  }

  function morphChildren(from, to) {
    let current = from.firstChild;
    for (const target of Array.from(to.childNodes)) {
      if (target.nodeType === 1 && target.id) {
        const match = Array.from(from.children).find((child) => child.id === target.id);
        if (match && match !== current) from.insertBefore(match, current);
        if (match) current = match;
      }
      if (current && sameKind(current, target)) {
        const next = current.nextSibling;
        update(current, target);
        current = next;
      } else from.insertBefore(target, current);
    }
    while (current) {
      const next = current.nextSibling;
      if (!(current.nodeType === 1 && current.hasAttribute("data-client"))) current.remove();
      current = next;
    }
  }

  // Headline numbers count from the old value to the new one.
  function tweenNumber(node, before, after) {
    const pattern = /^(\D*?)(-?[\d,]*\.?\d+)(\D*)$/;
    const a = pattern.exec(before.trim());
    const b = pattern.exec(after.trim());
    if (!a || !b || a[1] !== b[1] || a[3] !== b[3] || reducedMotion()) { node.nodeValue = after; return; }
    const from = Number(a[2].replaceAll(",", ""));
    const to = Number(b[2].replaceAll(",", ""));
    const decimals = (b[2].split(".")[1] || "").length;
    const grouped = b[2].includes(",") || Math.abs(to) >= 1000;
    const started = performance.now();
    const step = (time) => {
      const t = Math.min(1, (time - started) / 400);
      const value = from + (to - from) * (1 - Math.pow(1 - t, 3));
      const text = grouped ? value.toLocaleString("en-US", { minimumFractionDigits: decimals, maximumFractionDigits: decimals }) : value.toFixed(decimals);
      node.nodeValue = t < 1 ? `${b[1]}${text}${b[3]}` : after;
      if (t < 1) requestAnimationFrame(step);
    };
    requestAnimationFrame(step);
  }

  // Chart lines move to their new shape when the number of points is the same.
  function tweenPaths(chart, before) {
    if (reducedMotion()) return;
    const numbers = (d) => (d || "").match(/-?\d+(\.\d+)?/g)?.map(Number) || [];
    const skeleton = (d) => (d || "").replace(/-?\d+(\.\d+)?/g, "#");
    $$("path", chart).forEach((path, index) => {
      const after = path.getAttribute("d");
      const old = before[index];
      if (!old || skeleton(old) !== skeleton(after)) return;
      const from = numbers(old);
      const to = numbers(after);
      const started = performance.now();
      const step = (time) => {
        const t = Math.min(1, (time - started) / 450);
        const eased = 1 - Math.pow(1 - t, 3);
        let i = 0;
        path.setAttribute("d", t < 1 ? after.replace(/-?\d+(\.\d+)?/g, () => { const value = from[i] + (to[i] - from[i]) * eased; i++; return value.toFixed(1); }) : after);
        if (t < 1) requestAnimationFrame(step);
      };
      requestAnimationFrame(step);
    });
  }

  function swap(html, url, mode, keepScroll, scrollTo = null) {
    const next = new DOMParser().parseFromString(html, "text/html");
    const openSheet = $("dialog[data-sheet][open]");
    const nextSheet = next.querySelector("dialog[data-sheet]");
    if (openSheet && nextSheet && new URL(url, location.href).pathname === location.pathname) {
      // Tabs inside a sheet: swap its content in place, no close/reopen.
      const focused = openSheet.contains(document.activeElement) ? document.activeElement.getAttribute("href") : null;
      openSheet.innerHTML = nextSheet.innerHTML;
      ($$("a[href]", openSheet).find((link) => focused && link.getAttribute("href") === focused) || openSheet).focus({ preventScroll: true });
      openSheet.dataset.closeHref = nextSheet.dataset.closeHref || "";
      openSheet.scrollTop = 0;
      document.title = next.title;
      // The row whose details are open stays marked, and in sight.
      const shown = new URL(url, location.href).searchParams.get("page");
      $$("tr[data-href]").forEach((row) => row.toggleAttribute("aria-selected", shown !== null && new URL(row.dataset.href, location.href).searchParams.get("page") === shown));
      revealSelected(openSheet);
      if (mode === "push") history.pushState({}, "", url);
      else if (mode === "replace") history.replaceState({}, "", url);
      $$(".chart[data-chart]", openSheet).forEach(setupChart);
      return;
    }
    const apply = () => {
      document.title = next.title;
      morph(document.body, next.body);
      if (mode === "push") history.pushState({}, "", url);
      else if (mode === "replace") history.replaceState({}, "", url);
      if (scrollTo !== null) window.scrollTo(0, scrollTo);
      else if (!keepScroll) window.scrollTo(0, 0);
      init();
    };
    apply();
  }

  function morph(from, to) {
    syncAttributes(from, to);
    morphChildren(from, to);
  }

  async function navigate(href, { mode = "push", keepScroll = false, scrollTo = null } = {}) {
    let url = new URL(href, location.href);
    if (!navigable(url)) { location.href = url.href; return; }
    url = remembered(url);
    flushUndo();
    const key = url.href;
    // Where to come back to on "back".
    if (mode === "push") history.replaceState({ ...(history.state || {}), scroll: scrollY }, "");
    // Opening a sheet from its page: closing it goes back there instead of
    // adding a step, so Back doesn't reopen a sheet just closed.
    if (mode === "push" && !$("dialog[data-sheet][open]")) sheetFrom = location.href;
    // Reloading the current page always fetches fresh.
    if (key === location.href && mode !== "none") { ahead.delete(key); seen.delete(key); }
    const quick = ahead.get(key);
    const known = seen.get(key);
    if (known && Date.now() - known.at < SEEN_MS && !(quick && Date.now() - quick.at < AHEAD_MS)) {
      // Seen recently: show it now, then refresh it in place.
      swap(known.html, known.url, mode, keepScroll, scrollTo);
      document.documentElement.classList.add("refreshing");
      try {
        const page = await fetchPage(key);
        keep(key, page);
        if (page.type.startsWith("text/html") && new URL(page.url).href === location.href) swap(page.html, page.url, "none", true);
      } catch { /* The shown copy stays. */ }
      document.documentElement.classList.remove("refreshing");
      return;
    }
    loading(true);
    try {
      const response = await prefetch(key);
      ahead.delete(key);
      if (!response.type.startsWith("text/html")) { location.href = key; return; }
      keep(response.url, response);
      const samePage = new URL(response.url).pathname === location.pathname;
      swap(response.html, response.url, mode, keepScroll || samePage, scrollTo);
    } catch {
      location.href = key;
    } finally {
      loading(false);
    }
  }

  async function submit(form, submitter) {
    if (form.dataset.confirm && !window.confirm(form.dataset.confirm)) return;
    const method = (submitter?.getAttribute("formmethod") || form.getAttribute("method") || "get").toLowerCase();
    const action = new URL(submitter?.getAttribute("formaction") || form.getAttribute("action") || here(), location.href);
    const body = new FormData(form);
    if (submitter?.name) body.append(submitter.name, submitter.value);
    if (method === "get") {
      const params = new URLSearchParams();
      for (const [key, value] of body) if (value !== "") params.append(key, value);
      action.search = params.toString();
      return navigate(action.href, { mode: form.hasAttribute("data-live-search") ? "replace" : "push", keepScroll: action.pathname === location.pathname });
    }
    if (form.dataset.undo && !form.dataset.undoing) return deferWithUndo(form, submitter);
    if (!body.has("back")) body.append("back", here());
    // Anything fetched before a change may now be stale.
    forgetPages();
    const busy = form.dataset.busy;
    const buttons = $$("button", form);
    // Switches stay usable: the change already shows, the server confirms it.
    const optimistic = form.querySelector("[data-autosubmit]") !== null;
    if (!optimistic) buttons.forEach((button) => { button.disabled = true; });
    if (busy && submitter) submitter.textContent = busy;
    try {
      const response = await fetch(action.href, { method: "POST", body: new URLSearchParams(body), headers: { "x-requested-with": "fetch" } });
      const type = response.headers.get("content-type") || "";
      if (!type.startsWith("text/html")) { location.reload(); return; }
      const html = await response.text();
      const finalUrl = new URL(response.url);
      swap(html, finalUrl.href, response.redirected ? (finalUrl.pathname === location.pathname ? "replace" : "push") : "none", finalUrl.pathname === location.pathname);
    } catch {
      form.submit();
    }
  }

  // ---- undo: a delete waits five seconds behind a toast before it is sent.

  let pendingUndo = null;
  function deferWithUndo(form, submitter) {
    flushUndo();
    form.closest("[popover]")?.hidePopover?.();
    const row = form.closest("tr, .list-row, .chip, li, .rank-row");
    if (row) row.hidden = true;
    const toast = document.createElement("div");
    toast.className = "toast";
    toast.setAttribute("role", "status");
    toast.dataset.client = "";
    toast.innerHTML = '<span></span><button type="button">Undo</button>';
    toast.firstChild.textContent = form.dataset.undo;
    $("#toasts")?.appendChild(toast);
    const commit = () => {
      if (pendingUndo?.form !== form) return;
      pendingUndo = null;
      toast.remove();
      form.dataset.undoing = "1";
      submit(form, submitter).finally(() => { delete form.dataset.undoing; });
    };
    pendingUndo = { form, submitter, timer: setTimeout(commit, 5000), commit };
    toast.querySelector("button").addEventListener("click", () => {
      clearTimeout(pendingUndo?.timer);
      pendingUndo = null;
      toast.remove();
      if (row) row.hidden = false;
    });
  }
  // Leaving the page sends a waiting delete right away.
  function flushUndo() {
    if (!pendingUndo) return;
    const { form, submitter, timer } = pendingUndo;
    clearTimeout(timer);
    pendingUndo = null;
    $$("#toasts .toast[data-client]").forEach((toast) => toast.remove());
    const body = new FormData(form);
    if (submitter?.name) body.append(submitter.name, submitter.value);
    body.append("back", here());
    forgetPages();
    fetch(new URL(submitter?.getAttribute("formaction") || form.getAttribute("action"), location.href).href, { method: "POST", body: new URLSearchParams(body), keepalive: true, headers: { "x-requested-with": "fetch" } }).catch(() => {});
  }
  window.addEventListener("pagehide", flushUndo);

  // ---- clicks and prefetching


  function prefetchTarget(target) {
    const link = target.closest?.("a[href], tr[data-href]");
    if (!link || link.dataset.prefetched || link.target === "_blank" || link.hasAttribute("download")) return null;
    const url = new URL(link.dataset.href || link.href, location.href);
    if (!navigable(url) || url.href === location.href) return null;
    return { link, href: remembered(url).href };
  }

  // Hover: fetch after a short pause, so passing over links costs nothing.
  document.addEventListener("mouseover", (event) => {
    // The date range control: every option at once, so switching is instant.
    const group = event.target.closest(".seg[aria-label='Date range']");
    if (group && !group.dataset.prefetched) {
      group.dataset.prefetched = "1";
      $$("a[href]", group).forEach((option) => { const found = prefetchTarget(option); if (found) { found.link.dataset.prefetched = "1"; prefetch(found.href).catch(() => {}); } });
    }
    const heat = event.target.closest("a[href*='/heatmaps/open']");
    if (heat && !heat.dataset.warmed) {
      heat.dataset.warmed = "1";
      fetch(heat.href.replace("/heatmaps/open", "/heatmaps/warm")).catch(() => {});
    }
    const found = prefetchTarget(event.target);
    if (!found) return;
    found.link.dataset.prefetched = "1";
    const warm = found.link.matches(".btn-replay");
    const timer = setTimeout(() => prefetch(found.href, warm).catch(() => {}), 65);
    found.link.addEventListener("mouseleave", () => clearTimeout(timer), { once: true });
  });

  // Touch and press: there is no hover on phones, and a press comes about
  // 100 ms before the click it turns into.
  const pressed = (event) => {
    const found = prefetchTarget(event.target);
    if (!found) return;
    found.link.dataset.prefetched = "1";
    prefetch(found.href, true).catch(() => {});
  };
  document.addEventListener("touchstart", pressed, { passive: true, capture: true });
  document.addEventListener("pointerdown", (event) => { if (event.pointerType === "mouse" && event.button === 0) pressed(event); }, true);

  document.addEventListener("submit", (event) => {
    const form = event.target;
    if (form.hasAttribute("data-native") || event.defaultPrevented) return;
    event.preventDefault();
    if (form.matches("[data-filter-form]")) encodeConditions(form);
    if (form.matches("[data-ask-form]")) {
      const fields = new FormData(form);
      return ask(form.action, fields.get("q"), fields.get("view"));
    }
    submit(form, event.submitter);
  });

  // A click on an in-app link or a table row navigates without a reload.
  function follow(event) {
    if (event.defaultPrevented || event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
    const link = event.target.closest("a[href]");
    if (link) {
      if (link.target === "_blank" || link.hasAttribute("download") || link.getAttribute("href").startsWith("#")) return;
      const url = new URL(link.href);
      if (!navigable(url)) return;
      event.preventDefault();
      if (link.closest("[popover]")) link.closest("[popover]").hidePopover?.();
      // The tab you're on, tapped again, scrolls back to the top, as on iOS.
      if (link.closest(".tabbar") && link.hasAttribute("aria-current") && url.pathname === location.pathname && scrollY > 0) {
        scrollTo({ top: 0, behavior: "smooth" });
        return;
      }
      const keep = url.pathname === location.pathname && link.closest(".tabs, .sheet, .table, .metrics, .seg, .chips, .rank") !== null;
      const from = location.href;
      // The name the row showed ("Google"), not the key behind it.
      const name = link.title?.startsWith("Filter by ") ? link.title.slice(10) : link.querySelector(".rank-name")?.textContent.trim();
      navigate(url.href, { keepScroll: keep }).then(() => filteredFrom(from, name));
      return;
    }
    const row = event.target.closest("tr[data-href]");
    if (row && !event.target.closest("a, button, input, form")) navigate(row.dataset.href, { keepScroll: true });
  }

  history.scrollRestoration = "manual";
  window.addEventListener("popstate", (event) => navigate(location.href, { mode: "none", keepScroll: true, scrollTo: event.state?.scroll ?? 0 }));

  // ------------------------------------------------------------ dialogs, sheets, popovers

  // Phones: the row whose details a half-height sheet shows scrolls into the
  // part of the list the sheet leaves visible.
  // A filter added from a row further down the page changes everything
  // above it, where its chip is out of sight: say so, with a way back.
  function filteredFrom(before, name) {
    const was = new URL(before).searchParams.getAll("f");
    const now = new URLSearchParams(location.search).getAll("f");
    const added = now.filter((value) => !was.includes(value));
    const chip = $(".chips .chip");
    if (!added.length || !chip || chip.getBoundingClientRect().top >= 0) return;
    $$("#toasts .toast[data-filter]").forEach((old) => old.remove());
    const toast = document.createElement("div");
    toast.className = "toast";
    toast.dataset.filter = "";
    toast.setAttribute("role", "status");
    toast.innerHTML = '<span></span><button type="button">Undo</button>';
    const [dim, ...rest] = added[0].split(":");
    toast.firstChild.textContent = `Every report now shows ${dim.replace(/!$/, "")} ${dim.endsWith("!") ? "is not" : "is"} ${name || rest.join(":")}`;
    $("#toasts")?.appendChild(toast);
    const timer = setTimeout(() => toast.remove(), 5000);
    toast.querySelector("button").addEventListener("click", () => {
      clearTimeout(timer);
      toast.remove();
      navigate(before, { keepScroll: true });
    });
  }

  function revealSelected(sheet) {
    if (!sheet.matches("[data-detents]") || !matchMedia("(max-width: 720px)").matches) return;
    const row = $("tr[aria-selected]");
    if (!row) return;
    const visibleTo = innerHeight - sheet.getBoundingClientRect().height;
    const rect = row.getBoundingClientRect();
    if (rect.top < 80 || rect.bottom > visibleTo - 12) scrollBy({ top: rect.top - Math.max(90, visibleTo * 0.45), behavior: "instant" });
  }

  let sheetFrom = null;
  function closeDialog(dialog) {
    const href = dialog.dataset.closeHref;
    dialog.close();
    if (!href) return;
    const back = sheetFrom && new URL(sheetFrom).href === new URL(href, location.href).href && history.length > 1;
    sheetFrom = null;
    if (back) history.back();
    else navigate(href, { mode: "replace", keepScroll: true });
  }


  // Phones: a bottom sheet follows the finger. Pulled down from the top of
  // its content, it closes past a third of its height or on a flick, and
  // springs back otherwise; a form with unsaved input stays open, as on iOS.
  // Page details have two heights: half the screen, and nearly all of it.
  // At half height any drag moves the sheet (up expands it); expanded, the
  // content scrolls and a pull from its top brings it back to half.
  let pull = null;
  const sheetAt = (node) => node.closest?.("dialog.sheet[open], dialog.dialog[open], [popover].as-sheet:popover-open");
  const dismissSheet = (sheet) => {
    if (sheet.matches("[popover]")) sheet.hidePopover();
    else closeDialog(sheet);
  };
  const heights = () => ({ half: Math.round(innerHeight * 0.56), full: Math.round(innerHeight * 0.92) });
  document.addEventListener("touchstart", (event) => {
    pull = null;
    if (event.touches.length !== 1 || !matchMedia("(max-width: 720px)").matches) return;
    const sheet = sheetAt(event.target);
    if (!sheet || event.target.closest("input, textarea, select, .chart-plot, pre")) return;
    const y = event.touches[0].clientY;
    const detents = sheet.matches("[data-detents]");
    pull = { sheet, detents, expanded: detents && sheet.classList.contains("expanded"), startY: y, lastY: y, lastAt: event.timeStamp, speed: 0, dy: 0, active: false, atTop: sheet.scrollTop <= 0 };
  }, { passive: true });
  document.addEventListener("touchmove", (event) => {
    if (!pull) return;
    const y = event.touches[0].clientY;
    const dy = y - pull.startY;
    if (!pull.active) {
      if (Math.abs(dy) < 6) return;
      // Expanded (or a sheet without heights): only a pull down from the top moves it.
      const resizes = pull.detents && !pull.expanded;
      if (!resizes && (dy < 0 || !pull.atTop || pull.sheet.scrollTop > 0)) return void (pull = null);
      pull.active = true;
      pull.sheet.style.transition = "none";
    }
    event.preventDefault();
    pull.speed = (y - pull.lastY) / Math.max(1, event.timeStamp - pull.lastAt);
    pull.lastY = y;
    pull.lastAt = event.timeStamp;
    pull.dy = dy;
    if (pull.detents) {
      const { half, full } = heights();
      const height = Math.min(full, (pull.expanded ? full : half) - dy);
      if (height >= half) {
        pull.sheet.style.height = `${height}px`;
        pull.sheet.style.transform = "";
      } else {
        pull.sheet.style.height = `${half}px`;
        pull.sheet.style.transform = `translateY(${half - height}px)`;
      }
    } else {
      pull.sheet.style.transform = `translateY(${Math.max(0, dy - 6)}px)`;
    }
  }, { passive: false });
  const letGo = (cancelled) => {
    if (!pull?.active) return void (pull = null);
    const { sheet, dy, speed, detents, expanded } = pull;
    pull = null;
    const { half, full } = heights();
    const flickDown = speed > 0.5 && dy > 30;
    const flickUp = speed < -0.5 && dy < -30;
    // Where the sheet ends up: closed, half, or full.
    let to = detents ? (expanded ? "full" : "half") : "open";
    if (!cancelled) {
      if (!detents) {
        if (!sheet.dataset.dirty && (dy > sheet.offsetHeight / 3 || flickDown)) to = "closed";
      } else if (expanded) {
        if (dy > full - half + half / 3 && !sheet.dataset.dirty) to = "closed";
        else if (dy > 60 || flickDown) to = "half";
      } else if (dy < -40 || flickUp) {
        to = "full";
      } else if ((dy > half / 3 || flickDown) && !sheet.dataset.dirty) {
        to = "closed";
      }
    }
    sheet.style.transition = "transform .2s ease-out, height .22s ease-out";
    if (to === "closed") {
      sheet.style.transform = `translateY(${sheet.offsetHeight}px)`;
    } else {
      sheet.style.transform = "";
      if (detents) {
        sheet.style.height = `${to === "full" ? full : half}px`;
        sheet.classList.toggle("expanded", to === "full");
        if (to === "half") sheet.scrollTop = 0;
      }
    }
    setTimeout(() => {
      sheet.style.transition = "";
      sheet.style.height = "";
      if (to !== "closed") return;
      sheet.style.transform = "";
      sheet.classList.remove("expanded");
      dismissSheet(sheet);
    }, 220);
  };
  document.addEventListener("touchend", () => letGo(false));
  document.addEventListener("touchcancel", () => letGo(true));

  // Autofill pop-ups and drags that end outside a dialog also produce clicks on
  // its backdrop; only a press that starts there counts.
  let pressedBackdrop = null;
  const outsideOf = (dialog, event) => {
    const rect = dialog.getBoundingClientRect();
    return event.clientX < rect.left || event.clientX > rect.right || event.clientY < rect.top || event.clientY > rect.bottom;
  };
  document.addEventListener("pointerdown", (event) => {
    const dialog = event.target.matches?.("dialog.sheet, dialog.dialog") ? event.target : null;
    pressedBackdrop = dialog && outsideOf(dialog, event) ? dialog : null;
  }, true);
  document.addEventListener("input", (event) => {
    const dialog = event.target.closest?.("dialog.dialog, dialog.sheet");
    if (dialog && event.target.closest("form")) dialog.dataset.dirty = "1";
  }, true);
  document.addEventListener("close", (event) => { delete event.target.dataset?.dirty; }, true);

  document.addEventListener("cancel", (event) => {
    if (event.target.dataset.closeHref) {
      event.preventDefault();
      closeDialog(event.target);
    }
  }, true);

  document.addEventListener("toggle", (event) => {
    const pop = event.target;
    if (!(pop instanceof HTMLElement) || !pop.hasAttribute("popover") || event.newState !== "open") return;
    // Phones get popovers as sheets from the bottom of the screen.
    const sheet = matchMedia("(max-width: 720px)").matches;
    pop.classList.toggle("as-sheet", sheet);
    if (sheet) {
      pop.style.left = pop.style.top = "";
      if (pop.matches("#filter-pop")) setupFilter(pop);
      return;
    }
    const anchor = pop.dataset.anchor ? $(pop.dataset.anchor) : null;
    if (!anchor) return;
    const rect = anchor.getBoundingClientRect();
    pop.style.position = "fixed";
    pop.style.margin = "0";
    const width = pop.offsetWidth;
    const height = pop.offsetHeight;
    let left = rect.right - width > 8 && rect.left + width > innerWidth - 8 ? rect.right - width : rect.left;
    left = Math.max(8, Math.min(left, innerWidth - width - 8));
    let top = rect.bottom + 6;
    if (top + height > innerHeight - 8 && rect.top - height - 6 > 8) top = rect.top - height - 6;
    pop.style.left = `${left}px`;
    pop.style.top = `${top}px`;
    if (pop.matches("#filter-pop")) setupFilter(pop);
    $("input:not([type=hidden]), select", pop)?.focus({ preventScroll: true });
  }, true);

  // ------------------------------------------------------------ small behaviours

  document.addEventListener("change", (event) => {
    const target = event.target;
    if (target.matches("[data-autosubmit]")) target.form?.requestSubmit();
    if (target.matches("input[data-file-to]") && target.files[0]) {
      target.files[0].text().then((text) => { const area = $(target.dataset.fileTo); if (area) area.value = text; });
    }
    if (target.closest("[data-funnel-builder]")) funnelChanged(target.closest("form"));
    if (target.closest("[data-alert-form]")) alertPreview(target.closest("dialog"));
  });

  document.addEventListener("input", (event) => {
    const target = event.target;
    if (target.closest("[data-live-search]")) liveSearch(target.form);
    if (target.closest("[data-alert-form]")) alertPreviewSoon(target.closest("dialog"));
    if (target.closest("[data-filter-form]")) matchSoon(target.closest("form"));
  });

  const liveSearch = debounce((form) => form.requestSubmit(), 250);

  document.addEventListener("input", (event) => {
    const range = event.target.closest("input[type=range][data-output]");
    const output = range && $(`output[data-for="${range.name}"]`, range.form);
    if (output) output.textContent = `${range.value}%`;
  });

  // ------------------------------------------------------------ replay player

  const scripts = new Map();
  function loadScript(src) {
    if (!scripts.has(src)) scripts.set(src, new Promise((resolve, reject) => {
      const script = document.createElement("script");
      script.src = src;
      script.onload = resolve;
      script.onerror = reject;
      document.head.appendChild(script);
    }));
    return scripts.get(src);
  }

  const clockText = (ms) => {
    const seconds = Math.floor(Math.max(ms, 0) / 1000);
    return `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, "0")}`;
  };

  // The recording arrives as length-prefixed chunks of rrweb events: gzip,
  // or plain JSON sent while the visitor's page was closing.
  async function recordingEvents(url) {
    const response = await fetch(url);
    if (!response.ok) throw new Error("not recorded");
    const bytes = new Uint8Array(await response.arrayBuffer());
    const events = [];
    for (let offset = 0; offset + 4 <= bytes.length;) {
      const length = new DataView(bytes.buffer, bytes.byteOffset + offset, 4).getUint32(0);
      offset += 4;
      const chunk = bytes.subarray(offset, offset + length);
      offset += length;
      try {
        const gzipped = chunk[0] === 0x1f && chunk[1] === 0x8b;
        const text = gzipped ? await new Response(new Blob([chunk]).stream().pipeThrough(new DecompressionStream("gzip"))).text() : new TextDecoder().decode(chunk);
        const parsed = JSON.parse(text);
        if (Array.isArray(parsed)) events.push(...parsed);
      } catch { /* A damaged chunk is skipped; the rest still plays. */ }
    }
    return events.sort((a, b) => a.timestamp - b.timestamp);
  }

  async function setupPlayer(section) {
    if (section.dataset.ready) return;
    section.dataset.ready = "1";
    const status = $("[data-status]", section);
    const stage = $("[data-stage]", section);
    let replayer;
    try {
      await loadScript(section.dataset.playerSrc);
      const events = await recordingEvents(section.dataset.replay);
      if (events.length < 2) throw new Error("too short");
      replayer = new window.rrwebReplay.Replayer(events, { root: stage, skipInactive: true, mouseTail: false, showWarning: false });
    } catch {
      status.textContent = "This recording couldn’t be loaded.";
      return;
    }
    status.hidden = true;
    section.classList.add("loaded");
    const player = $("iframe", stage);
    if (player) player.title = "Session replay";
    const total = replayer.getMetaData().totalTime;
    const fit = () => {
      const iframe = $("iframe", stage);
      const wrapper = $(".replayer-wrapper", stage);
      if (!iframe || !wrapper) return;
      const width = Number(iframe.width) || iframe.offsetWidth;
      const height = Number(iframe.height) || iframe.offsetHeight;
      const scale = Math.min(stage.clientWidth / width, stage.clientHeight / height, 1);
      wrapper.style.transform = `scale(${scale})`;
      wrapper.style.left = `${(stage.clientWidth - width * scale) / 2}px`;
      wrapper.style.top = `${(stage.clientHeight - height * scale) / 2}px`;
    };
    replayer.on("resize", fit);
    window.addEventListener("resize", fit);
    setTimeout(fit, 50);
    const play = $("[data-play]", section);
    const time = $("[data-time]", section);
    const progress = $("[data-progress]", section);
    let playing = false;
    let frame = 0;
    const paint = () => {
      const now = Math.min(replayer.getCurrentTime(), total);
      time.textContent = `${clockText(now)} / ${clockText(total)}`;
      progress.style.width = `${total ? now / total * 100 : 0}%`;
      if (playing) frame = requestAnimationFrame(paint);
    };
    const setPlaying = (value) => {
      playing = value;
      play.setAttribute("aria-label", value ? "Pause" : "Play");
      play.innerHTML = play.innerHTML.replace(value ? "#play" : "#pause", value ? "#pause" : "#play");
      cancelAnimationFrame(frame);
      paint();
    };
    const seek = (ms) => {
      if (playing) replayer.play(ms); else replayer.pause(ms);
      paint();
    };
    replayer.on("finish", () => setPlaying(false));
    play.addEventListener("click", () => {
      if (playing) {
        replayer.pause();
        setPlaying(false);
      } else {
        const at = replayer.getCurrentTime();
        replayer.play(at >= total ? 0 : at);
        setPlaying(true);
      }
    });
    $("[data-restart]", section).addEventListener("click", () => seek(0));
    $("[data-track]", section).addEventListener("click", (event) => {
      const rect = event.currentTarget.getBoundingClientRect();
      seek((event.clientX - rect.left) / rect.width * total);
    });
    const speed = $("[data-speed]", section);
    speed.addEventListener("click", () => {
      const next = { "1×": 2, "2×": 4, "4×": 1 }[speed.textContent] || 1;
      speed.textContent = `${next}×`;
      replayer.setConfig({ speed: next });
    });
    $("[data-skip]", section).addEventListener("change", (event) => replayer.setConfig({ skipInactive: event.target.checked }));
    // Delegated, so lines added later (the summary) seek too.
    section.closest(".split-player").addEventListener("click", (event) => {
      const button = event.target.closest("[data-seek]");
      if (!button) return;
      seek(Number(button.dataset.seek));
      if (!playing) {
        replayer.play(Number(button.dataset.seek));
        setPlaying(true);
      }
    });
    replayer.pause(0);
    paint();
  }


  // ------------------------------------------------------------ charts

  function setupChart(chart) {
    if (chart.dataset.ready) return;
    chart.dataset.ready = "1";
    let data;
    try { data = JSON.parse(chart.dataset.chart); } catch { return; }
    const plot = $(".chart-plot", chart);
    const hover = $(".chart-hover", chart);
    const dot = $(".chart-dot", chart);
    const tip = $(".chart-tip", chart);
    const why = $(".chart-why", chart);
    const values = data.v;
    if (!values.length) return;
    const max = Math.max(1, ...values, ...(data.p || []));
    const svg = $("svg", plot);
    let index = -1;
    const show = (clientX) => {
      const rect = plot.getBoundingClientRect();
      const ratio = Math.min(1, Math.max(0, (clientX - rect.left) / rect.width));
      index = Math.round(ratio * (values.length - 1));
      const x = values.length === 1 ? rect.width / 2 : (index / (values.length - 1)) * rect.width;
      const top = svg ? niceTop(max) : max;
      const y = rect.height - (values[index] / top) * rect.height;
      // The bucket still running is partial: no dot at a value it hasn't reached.
      const running = data.n === index;
      chart.classList.add("hovering");
      hover.style.left = `${x}px`;
      dot.style.left = `${x}px`;
      dot.style.top = `${y}px`;
      dot.style.visibility = running ? "hidden" : "";
      const value = data.d ? duration(values[index]) : `${number(values[index])} ${data.u}`;
      const against = running ? data.q : data.p?.[index];
      const name = running ? data.ql : data.pl?.[index] || "previous";
      tip.innerHTML = "<small></small><strong></strong>";
      if (against > 0) {
        const delta = ((values[index] - against) / against) * 100;
        const em = document.createElement("em");
        if (delta < 0) em.className = "down";
        em.textContent = `${delta >= 0 ? "+" : "−"}${Math.abs(delta).toFixed(1)}% vs ${name}`;
        tip.append(em);
      }
      const label = data.l[index];
      tip.children[0].textContent = running ? `${label}${/\d\d:\d\d$/.test(label) ? "–now" : ", until now"} · in progress` : label;
      tip.children[1].textContent = running ? `${value} so far` : value;
      const tipWidth = tip.offsetWidth;
      tip.style.left = `${x + 16 + tipWidth > rect.width ? x - tipWidth - 16 : x + 16}px`;
      if (why) { why.style.left = `${x}px`; why.style.top = `${y}px`; }
    };
    // The day a bucket opens: just that day, with the same filters.
    const dayHref = (at) => {
      const url = new URL(location.href);
      url.searchParams.set("range", "custom");
      url.searchParams.set("from", data.k[at]);
      url.searchParams.set("to", data.k[at]);
      return url.href;
    };
    // A mouse hovers and clicks a day to open it. A finger touches to read a
    // value and drags sideways to scrub (up and down still scroll the page);
    // a tap never navigates: the tooltip offers the day instead.
    let pointer = "mouse";
    const touchTip = () => {
      if (pointer === "mouse" || !data.k?.[index] || data.n === index) return;
      const open = document.createElement("a");
      open.className = "chart-open";
      open.href = dayHref(index);
      open.textContent = `Open ${data.l[index]} →`;
      tip.append(open);
    };
    plot.addEventListener("pointermove", (event) => {
      if (event.pointerType === "mouse") return show(event.clientX);
      if (event.buttons && !event.target.closest(".chart-tip, .chart-why, .why")) { show(event.clientX); touchTip(); }
    });
    plot.addEventListener("pointerdown", (event) => {
      pointer = event.pointerType;
      if (pointer === "mouse" || event.target.closest(".chart-tip, .chart-why, .why, .chart-mark")) return;
      $$(".chart.pinned").forEach((other) => other !== chart && other.classList.remove("pinned", "hovering"));
      chart.classList.add("pinned");
      show(event.clientX);
      touchTip();
    });
    if (data.k) {
      chart.classList.add("drillable");
      plot.addEventListener("click", (event) => {
        if (pointer !== "mouse" || event.target.closest(".chart-why, .why, .chart-tip") || index < 0 || !data.k[index]) return;
        navigate(dayHref(index));
      });
    }
    chart.addEventListener("mouseleave", (event) => {
      if (pointer !== "mouse" || event.relatedTarget?.closest?.(".chart-why, .why")) return;
      chart.classList.remove("hovering");
    });
    why?.addEventListener("click", async (event) => {
      event.stopPropagation();
      if (index < 0) return;
      $(".why")?.remove();
      const panel = document.createElement("div");
      panel.className = "why";
      panel.innerHTML = '<div class="ask-thinking"><span class="pulse"></span>Looking at sources, pages and devices…</div>';
      const rect = plot.getBoundingClientRect();
      const x = (index / Math.max(1, values.length - 1)) * rect.width;
      panel.style.left = `${Math.max(0, Math.min(x - 200, rect.width - 400))}px`;
      panel.style.top = "40%";
      plot.appendChild(panel);
      const body = new URLSearchParams({ view: here(), i: String(index) });
      try {
        const response = await fetch(chart.dataset.why, { method: "POST", body });
        panel.innerHTML = await response.text();
      } catch {
        panel.innerHTML = '<p class="hint">Couldn’t load the explanation. Try again.</p>';
      }
    });
  }

  document.addEventListener("keydown", (event) => {
    const sheet = $("dialog.sheet[open]:not(:modal)");
    if (event.key === "Escape" && sheet && !event.defaultPrevented) closeDialog(sheet);
  });

  document.addEventListener("pointerdown", (event) => {
    if (event.pointerType === "mouse") return;
    const tip = event.target.closest?.("[data-tip]");
    $$("[data-tip].tip-on").forEach((other) => other !== tip && other.classList.remove("tip-on"));
    tip?.classList.toggle("tip-on");
    const mark = event.target.closest?.(".chart-mark");
    $$(".chart-mark.open").forEach((other) => other !== mark && other.classList.remove("open"));
    mark?.classList.toggle("open");
    $$(".chart.pinned").forEach((chart) => {
      if (!chart.contains(event.target)) chart.classList.remove("pinned", "hovering");
    });
  }, true);

  function niceTop(value) {
    const target = value * 1.08;
    const magnitude = Math.pow(10, Math.floor(Math.log10(target)));
    for (const step of [1, 2, 2.5, 4, 5, 8, 10]) if (step * magnitude >= target) return step * magnitude;
    return 10 * magnitude;
  }


  // ------------------------------------------------------------ palette and ask

  let paletteItems = null;
  let paletteSource = "";
  let paletteSelected = 0;

  function openPalette(question = "") {
    const palette = $("#palette");
    if (!palette) return;
    const input = $("input", palette);
    input.value = question;
    if (!palette.open) palette.showModal();
    input.focus();
    if (paletteSource !== palette.dataset.source) {
      paletteSource = palette.dataset.source;
      paletteItems = null;
      getJson(paletteSource).then((items) => { paletteItems = items; renderPalette(); }).catch(() => {});
    }
    renderPalette();
  }

  function renderPalette() {
    const palette = $("#palette");
    if (!palette) return;
    const query = $("input", palette).value.trim();
    const list = $(".palette-list", palette);
    const terms = query.toLowerCase().split(/\s+/).filter(Boolean);
    const matches = (paletteItems || []).filter((item) => terms.every((term) => `${item.t} ${item.h} ${item.g}`.toLowerCase().includes(term))).slice(0, 40);
    const rows = [];
    if (query) rows.push({ g: "Ask", i: "sparkles", t: query, h: "Ask your AI provider about this view", ask: true });
    rows.push(...(query ? matches : matches.filter((item) => item.g !== "Pages" && item.g !== "Sources")));
    paletteSelected = Math.min(paletteSelected, Math.max(0, rows.length - 1));
    let group = "";
    list.innerHTML = "";
    rows.forEach((row, position) => {
      if (row.g !== group) {
        group = row.g;
        const heading = document.createElement("div");
        heading.className = "palette-group";
        heading.textContent = group;
        list.appendChild(heading);
      }
      const item = document.createElement(row.ask ? "button" : "a");
      item.className = `palette-item${row.ask ? " ask" : ""}`;
      item.setAttribute("role", "option");
      item.setAttribute("aria-selected", String(position === paletteSelected));
      if (row.ask) { item.type = "button"; item.style.cssText = "width:100%;border:0;background:none;text-align:left"; } else item.href = row.u;
      const badge = document.createElement("span");
      badge.className = "badge";
      badge.style.background = row.ask ? "" : "var(--subtle)";
      badge.innerHTML = `<svg class="i" aria-hidden="true"><use href="${document.querySelector("use")?.getAttribute("href")?.split("#")[0] || ""}#${row.i}"/></svg>`;
      const text = document.createElement("span");
      const title = document.createElement("strong");
      title.textContent = row.ask ? `Ask: “${row.t}”` : row.t;
      const hint = document.createElement("small");
      hint.textContent = row.h;
      text.append(title, hint);
      item.append(badge, text);
      item.addEventListener("click", (event) => { event.preventDefault(); choose(row); });
      item.addEventListener("mousemove", () => { if (paletteSelected !== position) { paletteSelected = position; highlight(); } });
      list.appendChild(item);
    });
    if (!rows.length) list.innerHTML = `<p class="hint" style="padding:12px">${paletteItems ? "Type to search pages, sources and settings — or ask a question." : "Loading…"}</p>`;
  }

  function highlight() {
    $$("#palette .palette-item").forEach((item, position) => item.setAttribute("aria-selected", String(position === paletteSelected)));
    $$("#palette .palette-item")[paletteSelected]?.scrollIntoView({ block: "nearest" });
  }

  function choose(row) {
    const palette = $("#palette");
    palette.close();
    if (row.ask) return ask(palette.dataset.ask, row.t);
    navigate(row.u);
  }

  function showThinking(question) {
    $("#ask-sheet")?.remove();
    const sheet = document.createElement("dialog");
    sheet.className = "sheet";
    sheet.id = "ask-sheet";
    sheet.innerHTML = `<div class="sheet-head" style="padding-bottom:14px;border-bottom:1px solid var(--border)"><h2>Ask</h2></div><div class="sheet-body"><div class="ask-q"></div><div class="ask-thinking"><span class="pulse"></span>Reading your numbers…</div><div class="skeleton" style="height:14px;width:90%"></div><div class="skeleton" style="height:14px;width:70%"></div><div class="skeleton" style="height:120px"></div></div>`;
    $(".ask-q", sheet).textContent = question;
    document.body.appendChild(sheet);
    sheet.showModal();
  }

  // The answer streams in as server-sent events; when it is complete the
  // server-rendered sheet (links, follow-ups) replaces the live one.
  async function ask(action, question, view = here()) {
    showThinking(question);
    const sheet = $("#ask-sheet");
    const status = $(".ask-thinking", sheet);
    const answer = document.createElement("p");
    answer.className = "ask-answer";
    answer.style.whiteSpace = "pre-wrap";
    let text = "";
    try {
      const response = await fetch(action, { method: "POST", body: new URLSearchParams({ q: question, view }), headers: { "x-requested-with": "fetch" } });
      if (!(response.headers.get("content-type") || "").startsWith("text/event-stream")) throw new Error(await response.text());
      const reader = response.body.pipeThrough(new TextDecoderStream()).getReader();
      let buffer = "";
      for (;;) {
        const { value, done } = await reader.read();
        if (done) break;
        buffer += value;
        for (let end = buffer.indexOf("\n\n"); end >= 0; end = buffer.indexOf("\n\n")) {
          const block = buffer.slice(0, end);
          buffer = buffer.slice(end + 2);
          const name = /^event: (.*)$/m.exec(block)?.[1];
          const data = JSON.parse(/^data: (.*)$/m.exec(block)?.[1] ?? "null");
          if (name === "delta") {
            if (!text) { $$(".skeleton", sheet).forEach((node) => node.remove()); status.after(answer); }
            text += data;
            answer.textContent = text.replace(/\s*Follow-ups:[\s\S]*$/, "");
          } else if (name === "tool") {
            status.lastChild.textContent = `Looking at ${data}…`;
          } else if (name === "done") {
            return navigate(data.href, { mode: "push", keepScroll: true });
          } else if (name === "error") {
            return askFailed(sheet, data.message, data.href, data.label);
          }
        }
      }
      throw new Error("The answer stopped early. Try again.");
    } catch (error) {
      askFailed(sheet, error.message || "Couldn’t reach Analytico. Try again.");
    }
  }

  function askFailed(sheet, message, href = "", label = "") {
    const body = $(".sheet-body", sheet);
    const question = $(".ask-q", body);
    body.replaceChildren(question);
    const callout = document.createElement("div");
    callout.className = "callout callout-warn";
    // A spent ChatGPT plan keeps ChatGPT's mark next to its message.
    const sprite = $("svg.i use")?.getAttribute("href").split("#")[0];
    if (href.startsWith("https://chatgpt.com/") && sprite) callout.insertAdjacentHTML("beforeend", `<svg class="i" aria-hidden="true"><use href="${sprite}#chatgpt"/></svg>`);
    const span = document.createElement("span");
    span.textContent = message;
    callout.append(span);
    if (href) {
      const link = document.createElement("a");
      link.className = "btn";
      link.href = href;
      link.textContent = label;
      if (href.startsWith("http")) { link.target = "_blank"; link.rel = "noopener"; }
      callout.append(link);
    }
    body.append(callout);
  }

  // ------------------------------------------------------------ ChatGPT plan sign-in

  // The link opens OpenAI in a new tab; this dialog waits for the loopback
  // callback, or takes the address pasted from that tab.

  document.addEventListener("keydown", (event) => {
    if ((event.metaKey || event.ctrlKey) && (event.key === "k" || event.key === "j")) {
      if (!$("#palette")) return;
      event.preventDefault();
      openPalette();
      return;
    }
    const palette = $("#palette");
    if (!palette?.open) return;
    const items = $$(".palette-item", palette);
    if (event.key === "ArrowDown") { event.preventDefault(); paletteSelected = Math.min(items.length - 1, paletteSelected + 1); highlight(); }
    if (event.key === "ArrowUp") { event.preventDefault(); paletteSelected = Math.max(0, paletteSelected - 1); highlight(); }
    if (event.key === "Enter") { event.preventDefault(); items[paletteSelected]?.click(); }
  });

  document.addEventListener("input", (event) => {
    if (event.target.closest("#palette")) { paletteSelected = 0; renderPalette(); }
  });


  // ------------------------------------------------------------ filter popover

  function setupFilter(pop) {
    if (pop.dataset.ready) return;
    pop.dataset.ready = "1";
    const form = $("form", pop);
    const conditions = $("[data-conditions]", pop);
    const template = $("[data-condition]", conditions).cloneNode(true);
    $("[data-value]", template).value = "";
    pop.addEventListener("click", (event) => {
      if (event.target.closest("[data-add-condition]")) {
        const row = template.cloneNode(true);
        conditions.appendChild(row);
        $("[data-value]", row).focus();
        suggest(form, row);
      }
      const remove = event.target.closest("[data-remove-condition]");
      if (remove) {
        const rows = $$("[data-condition]", conditions);
        if (rows.length > 1) remove.closest("[data-condition]").remove();
        else $("[data-value]", rows[0]).value = "";
        matchSoon(form);
      }
    });
    pop.addEventListener("change", (event) => { if (event.target.matches("[data-dim]")) suggest(form, event.target.closest("[data-condition]")); });
    pop.addEventListener("focusin", (event) => { if (event.target.matches("[data-value]")) suggest(form, event.target.closest("[data-condition]")); });
    $$(".seg input", pop).forEach((radio) => radio.addEventListener("change", () => matchSoon(form)));
    // Plain language: the server turns the description into a view, shown as
    // chips to check before applying.
    const describe = $("[data-describe]", pop);
    const question = $("[data-describe-q]", describe);
    const out = $("[data-describe-out]", describe);
    async function described() {
      if (!question.value.trim()) return;
      out.hidden = false;
      out.innerHTML = `<span class="hint">Reading that…</span>`;
      try {
        const response = await fetch(describe.dataset.describe, { method: "POST", body: new URLSearchParams({ q: question.value, view: here() }), headers: { "x-requested-with": "fetch" } });
        const result = await response.json();
        const node = (tag, className, text) => Object.assign(document.createElement(tag), { className, textContent: text });
        if (result.error) return out.replaceChildren(node("div", "callout callout-warn", result.error));
        const chips = node("div", "row", "");
        chips.append(...result.chips.map((chip) => node("span", "chip chip-plain", chip)));
        const apply = Object.assign(node("a", "btn btn-primary", "Apply"), { href: result.href });
        const box = node("div", "row-between", "");
        box.append(chips, apply);
        out.replaceChildren(box);
      } catch {
        out.textContent = "Couldn’t reach Analytico. Try again.";
      }
    }
    $("[data-describe-go]", describe).addEventListener("click", described);
    question.addEventListener("keydown", (event) => { if (event.key === "Enter") { event.preventDefault(); described(); } });
    matchSoon(form);
  }

  function encodeConditions(form) {
    $$("[data-condition]", form).forEach((row) => {
      const value = $("[data-value]", row).value.trim();
      const hidden = $("[data-encoded]", row);
      hidden.disabled = !value;
      hidden.value = value ? `${$("[data-dim]", row).value}${$("[data-op]", row).value}:${value}` : "";
    });
  }

  const suggestions = new Map();
  function suggest(form, row) {
    const dim = $("[data-dim]", row).value;
    const list = $("#filter-values");
    const base = form.dataset.match.replace("match.json", "values.json");
    const range = new URLSearchParams(location.search).get("range") || "";
    const key = `${base}?dim=${dim}&range=${range}`;
    const fill = (values) => { list.innerHTML = ""; values.forEach((value) => { const option = document.createElement("option"); option.value = value; list.appendChild(option); }); };
    if (suggestions.has(key)) return fill(suggestions.get(key));
    getJson(key).then((values) => { suggestions.set(key, values); fill(values); }).catch(() => {});
  }

  const matchSoon = debounce((form) => {
    if (!form?.dataset.match) return;
    encodeConditions(form);
    const params = new URLSearchParams();
    for (const [key, value] of new FormData(form)) if (value) params.append(key, value);
    const out = $("[data-match-out]", form);
    getJson(`${form.dataset.match}?${params}`).then((result) => {
      const share = result.total ? (result.visitors / result.total) * 100 : 0;
      out.hidden = false;
      out.innerHTML = `<div class="grow"><strong class="num" style="font-size:16px">${number(result.visitors)} visitors match</strong><div class="hint">${share.toFixed(0)}% of all visitors in this period</div></div><span style="width:120px;height:6px;border-radius:3px;background:var(--border);overflow:hidden"><span style="display:block;height:100%;width:${share}%;background:var(--brand)"></span></span>`;
    }).catch(() => {});
  }, 250);

  // ------------------------------------------------------------ alerts preview

  const alertPreviewSoon = debounce((dialog) => alertPreview(dialog), 300);
  function alertPreview(dialog) {
    const form = $("form", dialog);
    if (!form?.dataset.preview) return;
    const params = new URLSearchParams();
    for (const key of ["metric", "direction", "threshold", "filters"]) params.set(key, form.elements[key].value);
    getJson(`${form.dataset.preview}?${params}`).then((result) => {
      const svg = $("[data-alert-preview] svg", dialog);
      const values = result.values;
      const max = Math.max(1, ...values);
      const point = (value, index) => `${(index / (values.length - 1)) * 300},${56 - (value / max) * 50}`;
      svg.innerHTML = `<path d="M${values.map(point).join("L")}" fill="none" stroke="#D64937" stroke-width="1.5" vector-effect="non-scaling-stroke"/>${result.hits.map((hit) => `<circle cx="${(hit.i / (values.length - 1)) * 300}" cy="${56 - (values[hit.i] / max) * 50}" r="3.5" fill="#9F1D20"/>`).join("")}`;
      const verdict = $("[data-alert-verdict]", dialog);
      if (!result.hits.length) verdict.textContent = "Would not have triggered in the last 30 days.";
      else verdict.textContent = `Would have triggered ${result.hits.length === 1 ? "once" : `${result.hits.length} times`} — ${result.hits.slice(-3).map((hit) => `${hit.day} (${hit.change})`).join(", ")}. ${result.hits.length > 4 ? "Consider a higher threshold." : "Not too noisy."}`;
    }).catch(() => {});
  }

  // ------------------------------------------------------------ funnels and dashboards

  let dragged = null;
  document.addEventListener("dragstart", (event) => {
    dragged = event.target.closest("[data-step], .dash-tile[draggable]");
    if (dragged) { event.dataTransfer.effectAllowed = "move"; dragged.style.opacity = ".5"; }
  });
  document.addEventListener("dragend", () => {
    if (!dragged) return;
    dragged.style.opacity = "";
    const builder = dragged.closest("[data-funnel-builder]");
    const tiles = dragged.closest("[data-tiles]");
    dragged = null;
    if (builder) funnelChanged(builder);
    if (tiles) saveDashboard();
  });
  document.addEventListener("dragover", (event) => {
    if (!dragged) return;
    const over = event.target.closest("[data-step], .dash-tile[draggable]");
    if (!over || over === dragged || over.parentElement !== dragged.parentElement) return;
    event.preventDefault();
    const rect = over.getBoundingClientRect();
    const after = dragged.matches("[data-step]") ? event.clientY > rect.top + rect.height / 2 : event.clientX > rect.left + rect.width / 2 || event.clientY > rect.bottom - 10;
    over.parentElement.insertBefore(dragged, after ? over.nextSibling : over);
  });


  function renumber(builder) {
    $$("[data-steps] [data-step]", builder).forEach((row, index) => {
      $(".step-num", row).textContent = String(index + 1);
      const kind = $("select", row).value;
      const input = $("input", row);
      input.setAttribute("list", kind === "path" ? "funnel-paths" : "funnel-events");
      input.placeholder = kind === "path" ? "/pricing" : "signup";
    });
  }

  const autosave = debounce((builder) => {
    const filled = $$("[data-steps] input", builder).filter((input) => input.value.trim()).length;
    if (filled >= 2) builder.requestSubmit();
  }, 700);
  function funnelChanged(builder) {
    renumber(builder);
    if (builder.hasAttribute("data-autosave")) autosave(builder);
  }

  async function saveDashboard() {
    const form = $("form[data-dashboard]");
    if (!form) return;
    const keys = $$("[data-tiles] .dash-tile").map((tile) => tile.dataset.key);
    const body = new URLSearchParams({ widgets: keys.join(",") });
    await fetch(form.action, { method: "POST", body, headers: { accept: "application/json" } });
    const saved = $("[data-saved]");
    if (saved) { saved.hidden = false; setTimeout(() => { saved.hidden = true; }, 2000); }
  }


  // ------------------------------------------------------------ passkeys

  const fromB64 = (value) => {
    const base64 = String(value).replace(/-/g, "+").replace(/_/g, "/");
    const binary = atob(base64 + "=".repeat((4 - (base64.length % 4)) % 4));
    return Uint8Array.from(binary, (char) => char.charCodeAt(0)).buffer;
  };
  const toB64 = (buffer) => btoa(String.fromCharCode(...new Uint8Array(buffer))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  const postJson = (url, body) => fetch(url, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) })
    .then(async (response) => ({ ok: response.ok, body: await response.json().catch(() => ({ error: "Unexpected response." })) }));

  async function passkey(button) {
    const scope = button.closest(".login-card, section, main") || document;
    const problem = $("[data-passkey-error]", scope);
    const show = (text) => { if (problem) { problem.textContent = text; problem.hidden = !text; } };
    show("");
    if (!window.PublicKeyCredential || !window.isSecureContext) return show("This browser can’t use passkeys here. Use another way to sign in.");
    const purpose = button.dataset.passkey;
    const email = button.dataset.email ? $(button.dataset.email)?.value.trim() : "";
    if (purpose === "setup" && !email) { $(button.dataset.email)?.focus(); return show("Enter your email first."); }
    const label = button.innerHTML;
    button.disabled = true;
    try {
      const options = await postJson("/auth/passkey/options", { purpose, token: button.dataset.token || "", email, next: button.dataset.next || "" });
      if (!options.ok) return show(options.body.error);
      const publicKey = options.body.publicKey;
      publicKey.challenge = fromB64(publicKey.challenge);
      let payload;
      if (purpose === "login") {
        const credential = await navigator.credentials.get({ publicKey });
        payload = { credential_id: toB64(credential.rawId), client_data_json: toB64(credential.response.clientDataJSON), authenticator_data: toB64(credential.response.authenticatorData), signature: toB64(credential.response.signature) };
      } else {
        publicKey.user.id = fromB64(publicKey.user.id);
        publicKey.excludeCredentials = (publicKey.excludeCredentials || []).map((item) => ({ ...item, id: fromB64(item.id) }));
        const credential = await navigator.credentials.create({ publicKey });
        const transports = typeof credential.response.getTransports === "function" ? credential.response.getTransports() : [];
        payload = { client_data_json: toB64(credential.response.clientDataJSON), attestation_object: toB64(credential.response.attestationObject), transports: transports.join(",") };
      }
      const result = await postJson("/auth/passkey/verify", { challenge_id: options.body.challenge_id, ...payload });
      if (!result.ok) return show(result.body.error);
      navigate(result.body.redirect || "/");
    } catch (error) {
      show(error && error.name === "NotAllowedError" ? "Cancelled — try again whenever you’re ready." : error && error.name === "InvalidStateError" ? "This device already has a passkey here." : "That didn’t work. Try again or use another way.");
    } finally {
      button.disabled = false;
      button.innerHTML = label;
    }
  }


  // ------------------------------------------------------------ live updates

  // One server-sent event stream per website page: visitors online and the
  // newest page view, pushed when they change.
  let stream = null;
  let lastSeen = null;
  function connectLive() {
    const source = $("[data-stream]");
    const url = source ? new URL(source.dataset.stream, location.href).href : null;
    if (stream && stream.url === url) return;
    stream?.close();
    stream = null;
    // The newest page view the page was drawn with, when it says so.
    lastSeen = source?.dataset.last ? Number(source.dataset.last) : null;
    if (!url) return;
    stream = new EventSource(url);
    stream.onmessage = (event) => {
      let update;
      try { update = JSON.parse(event.data); } catch { return; }
      $$("[data-live]").forEach((badge) => { badge.textContent = `${update.online} online now`; });
      $$("[data-live-count]").forEach((count) => { count.textContent = update.online; count.classList.toggle("quiet", update.online === 0); });
      const setup = $("[data-setup-status]");
      if (setup && !setup.classList.contains("ok") && update.last > 0) setupReceived(setup);
      if (lastSeen !== null && update.last !== lastSeen) $$("[data-refresh-live]").forEach(refreshSection);
      lastSeen = update.last;
    };
  }

  function refreshSection(section) {
    getPage(location.href).then((response) => response.text()).then((html) => {
      const fresh = new DOMParser().parseFromString(html, "text/html").getElementById(section.id);
      if (fresh && section.isConnected) morphChildren(section, fresh);
    }).catch(() => {});
  }

  function setupReceived(setup) {
    getJson(setup.dataset.setupStatus).then((result) => {
      if (!result.received) return;
      setup.classList.add("ok");
      $("[data-status-title]", setup).textContent = "Data received";
      $("[data-status-detail]", setup).textContent = `First page view: ${result.path} — your site is reporting.`;
      $("[data-status-done]", setup).hidden = false;
      $("[data-status-open]", setup).hidden = true;
    }).catch(() => {});
  }

  // ------------------------------------------------------------ lazy sections

  // Below-the-fold cards load when they come near the screen; the page itself
  // never waits for them.
  const lazyObserver = "IntersectionObserver" in window ? new IntersectionObserver((entries) => entries.forEach((entry) => {
    if (!entry.isIntersecting) return;
    lazyObserver.unobserve(entry.target);
    loadLazy(entry.target);
  }), { rootMargin: "400px" }) : null;

  function loadLazy(node) {
    node.dataset.ready = "1";
    getPage(node.dataset.lazy).then((response) => response.text()).then((html) => {
      if (node.isConnected) node.innerHTML = html;
    }).catch(() => { delete node.dataset.ready; });
  }

  // ------------------------------------------------------------ keyboard

  const sections = { o: "", d: "/dashboards", p: "/pages", a: "/acquisition", u: "/audience", e: "/events", f: "/funnels", s: "/sessions", h: "/heatmaps", v: "/revenue", r: "/retention", c: "/people", x: "/errors" };
  let leader = 0;
  let selected = -1;
  const selectable = () => $$("main tr[data-href], main a.rank-row, main a.country-row").filter((row) => row.offsetParent !== null);
  document.addEventListener("keydown", (event) => {
    if (event.defaultPrevented || event.metaKey || event.ctrlKey || event.altKey) return;
    if (event.target.closest?.("input, textarea, select, [contenteditable]") || $("dialog[open]")) return;
    const key = event.key;
    const slug = $("main[data-site]")?.dataset.site;
    if (Date.now() - leader < 1200) {
      leader = 0;
      if (key === ",") { event.preventDefault(); navigate(`/settings${slug ? `?site=${slug}` : ""}`); return; }
      const target = sections[key];
      const link = slug && target !== undefined && $$("a.nav").find((nav) => new URL(nav.href).pathname === `/${slug}${target}`);
      if (link) { event.preventDefault(); navigate(link.href); }
      return;
    }
    if (key === "g") { leader = Date.now(); return; }
    if (key === "[" || key === "]") {
      const options = $$(".seg[aria-label='Date range'] a");
      const current = options.findIndex((option) => option.hasAttribute("aria-current"));
      const next = options[Math.max(0, Math.min(options.length - 1, current + (key === "]" ? 1 : -1)))];
      if (next && current >= 0 && next !== options[current]) { event.preventDefault(); navigate(next.href, { keepScroll: true }); }
      return;
    }
    if (key === "j" || key === "k") {
      const rows = selectable();
      if (!rows.length) return;
      event.preventDefault();
      rows[selected]?.classList.remove("kb-selected");
      selected = Math.max(0, Math.min(rows.length - 1, selected + (key === "j" ? 1 : -1)));
      rows[selected].classList.add("kb-selected");
      rows[selected].scrollIntoView({ block: "nearest" });
      return;
    }
    if (key === "Enter" && selected >= 0) {
      const row = selectable()[selected];
      if (row) { event.preventDefault(); navigate(row.dataset.href || row.href); }
      return;
    }
    if (key === "/") {
      event.preventDefault();
      const search = $("main [data-live-search] input:not([type=hidden])");
      if (search) search.focus(); else openPalette();
      return;
    }
    if (key === "?") { event.preventDefault(); showShortcuts(); }
  });

  function showShortcuts() {
    let dialog = $("#shortcuts");
    if (!dialog) {
      dialog = document.createElement("dialog");
      dialog.id = "shortcuts";
      dialog.className = "dialog";
      dialog.dataset.client = "";
      const rows = [["g then o / p / a / u", "Overview, Pages, Acquisition, Audience"], ["g then e / f / s / h", "Events, Funnels, Sessions, Heatmaps"], ["g then v / r / c / x", "Revenue, Retention, People, Errors"], ["g then d / ,", "Dashboards, Settings"], ["[ and ]", "Shorter or longer date range"], ["j and k, Enter", "Move through rows, open one"], ["/", "Search this page, or everything"], ["⌘K", "Search and ask"], ["?", "This list"]];
      dialog.innerHTML = '<div class="dialog-head"><div><h2>Keyboard shortcuts</h2></div><button class="btn btn-quiet btn-icon close" type="button" data-close aria-label="Close">×</button></div><div class="dialog-body"><dl class="kv shortcuts"></dl></div>';
      const list = $("dl", dialog);
      for (const [keys, what] of rows) {
        const term = document.createElement("dt");
        term.textContent = what;
        const detail = document.createElement("dd");
        detail.innerHTML = keys.split(" ").map((part) => (["then", "and", "/", ","].includes(part) && part.length > 1 ? ` ${part} ` : `<kbd>${part}</kbd>`)).join("");
        list.append(term, detail);
      }
      document.body.appendChild(dialog);
    }
    dialog.showModal();
  }

  function setupConnect(dialog, name) {
    const chatgpt = name === "ChatGPT";
    $$("[data-connect-name]", dialog).forEach((node) => { node.textContent = name; });
    const mark = $("[data-connect-mark]", dialog);
    mark.textContent = chatgpt ? "G" : "C";
    mark.style.background = chatgpt ? "#282421" : "#C96442";
    const open = $("[data-connect-open]", dialog);
    open.href = chatgpt ? "https://chatgpt.com/" : "https://claude.ai/settings/connectors";
    $("[data-connect-help]", dialog).textContent = chatgpt
      ? "Open Plugins → + → Create custom MCP server, paste the URL and choose OAuth. Needs a paid plan; works on the web."
      : "Settings → Connectors → Add custom connector, then paste the URL.";
    const since = Date.now() - 5000;
    const check = () => getJson(`${dialog.dataset.connectStatus}?since=${since}`).then((status) => {
      if (!status.connected) return;
      const waiting = $("[data-connect-waiting]", dialog);
      waiting.classList.add("ok");
      $("[data-connect-title]", dialog).textContent = `Connected to ${status.name}`;
      setTimeout(() => navigate(here(), { mode: "replace", keepScroll: true }), 1500);
    }).catch(() => {});
    const id = setInterval(() => { if (!dialog.open) clearInterval(id); else check(); }, 3000);
  }

  // ---- dates: To can't be before From; Apply waits for a valid range.
  const monthNames = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
  const shortDate = (iso) => { const d = new Date(`${iso}T00:00:00Z`); return `${d.getUTCDate()} ${monthNames[d.getUTCMonth()]}`; };
  function setupRangeForm(form) {
    if (form.dataset.ready) return;
    form.dataset.ready = "1";
    const { from, to } = form.elements;
    const error = $("[data-range-error]", form);
    const apply = $(".btn-primary", form);
    const first = from.min;
    const check = () => {
      to.min = from.value && from.value > first ? from.value : first;
      let message = "";
      if (from.value && to.value && to.value < from.value) message = `To is before From — pick ${shortDate(from.value)} or later.`;
      else if ((from.value && !from.checkValidity()) || (to.value && !to.checkValidity())) message = `Pick dates between ${shortDate(first)} and ${shortDate(from.max)}.`;
      error.textContent = message;
      error.hidden = !message;
      to.setAttribute("aria-invalid", message ? "true" : "false");
      apply.disabled = Boolean(message) || !from.value || !to.value;
      // The button names what it will show.
      if (!apply.disabled) {
        const days = Math.round((Date.parse(to.value) - Date.parse(from.value)) / 86400000) + 1;
        apply.textContent = days === 1 ? `Show ${shortDate(from.value)} · hour by hour` : `Show ${shortDate(from.value)} – ${shortDate(to.value)} · ${days} days`;
      } else apply.textContent = "Show these dates";
    };
    form.addEventListener("input", check);
    check();
  }
  // The toast after a corrected range offers "Change": it opens the dates.
  function openDatesFromHash() {
    if (location.hash !== "#dates") return;
    history.replaceState(history.state, "", location.pathname + location.search);
    $("#range-pop")?.showPopover?.();
  }
  window.addEventListener("hashchange", openDatesFromHash);

  function init() {
    selected = -1;
    $$(".chart[data-chart]").forEach(setupChart);
    $$("[data-range-form]").forEach(setupRangeForm);
    openDatesFromHash();
    $$("dialog[data-sheet], dialog[data-open]").forEach((dialog) => {
      if (dialog.open) return;
      // Focus the dialog itself, not its first link (which drew a focus ring).
      dialog.autofocus = true;
      dialog.tabIndex = -1;
      // Wide screens keep the page beside a sheet usable, as an inspector.
      // Wide screens keep the page beside it usable; on phones, a half-height
      // sheet keeps the list above it usable too.
      const besidePage = matchMedia("(min-width: 1100px)").matches || (dialog.matches("[data-detents]") && matchMedia("(max-width: 720px)").matches);
      if (dialog.matches("[data-sheet]") && besidePage) dialog.show();
      else dialog.showModal();
      revealSelected(dialog);
      // Chrome focuses the first link despite autofocus on the dialog.
      dialog.focus({ preventScroll: true });
    });
    const params = new URLSearchParams(location.search);
    const requested = params.get("dialog");
    if (requested && document.getElementById(requested)) {
      const dialog = document.getElementById(requested);
      dialog.showModal();
      if (dialog.matches("#alert-dialog")) alertPreview(dialog);
      params.delete("dialog");
      history.replaceState({}, "", location.pathname + (params.toString() ? `?${params}` : ""));
    }
    $$(".toast").forEach((toast) => setTimeout(() => toast.remove(), 6000));
    // On phones the settings menu scrolls sideways; keep the current section in view.
    const subnav = $(".subnav");
    const current = subnav && $("[aria-current]", subnav);
    if (current && subnav.scrollWidth > subnav.clientWidth) subnav.scrollLeft += current.getBoundingClientRect().left - subnav.getBoundingClientRect().left - (subnav.clientWidth - current.offsetWidth) / 2;
    connectLive();
    $$("[data-lazy]:not([data-ready])").forEach((node) => lazyObserver ? lazyObserver.observe(node) : loadLazy(node));
    rememberView();
    $$("[data-funnel-builder]").forEach(renumber);
    $$("[data-replay]").forEach(setupPlayer);
  }

  // ------------------------------------------------------------ clicks

  // What a click does, in one place. The first action whose selector matches
  // runs (one returning false passes the click on); a click nothing claims
  // may close a dialog by its backdrop, or follow a link or a table row.
  // A replay's "What happened?": timestamped lines that seek the player.
  async function summarise(button) {
    const card = button.closest("[data-summary]");
    const out = $("[data-summary-out]", card);
    const node = (tag, className, text) => Object.assign(document.createElement(tag), { className, textContent: text });
    button.disabled = true;
    out.hidden = false;
    out.replaceChildren(node("p", "hint", "Reading the session…"));
    try {
      const result = await (await fetch(card.dataset.summary, { method: "POST", headers: { "x-requested-with": "fetch" } })).json();
      if (result.error) return out.replaceChildren(node("div", "callout callout-warn", result.error));
      out.replaceChildren(...result.lines.map((line) => {
        const row = Object.assign(node("button", "tl-row tl-seek", ""), { type: "button" });
        row.dataset.seek = line.at;
        row.append(node("span", "tl-time", line.time), node("span", "tl-dot blue", ""), node("div", "", line.text));
        return row;
      }));
    } catch {
      out.replaceChildren(node("div", "callout callout-warn", "Couldn’t reach Analytico. Try again."));
    } finally {
      button.disabled = false;
    }
  }

  const actions = [
    ["[data-summarize]", (button) => { summarise(button); }],
    ["[data-dialog]", (opener, event) => {
      event.preventDefault();
      const dialog = document.getElementById(opener.dataset.dialog);
      if (!dialog) return;
      opener.closest("[popover]")?.hidePopover?.();
      if (opener.dataset.restore) $$("[data-restore-name]", dialog).forEach((node) => { node.textContent = opener.dataset.restore; });
      if (opener.dataset.noteDay) { const day = $("input[name=day]", dialog); if (day) day.value = opener.dataset.noteDay; }
      if (opener.dataset.connect) setupConnect(dialog, opener.dataset.connect);
      dialog.showModal();
      if (dialog.matches("#alert-dialog")) alertPreview(dialog);
    }],
    ["[data-close]", (closer, event) => {
      const dialog = closer.closest("dialog");
      if (!dialog) return false;
      event.preventDefault();
      closeDialog(dialog);
    }],
    ["[data-print]", () => window.print()],
    ["[data-copy], [data-copy-link]", (copy) => {
      navigator.clipboard?.writeText(copy.dataset.copy ?? location.href).then(() => {
        const label = copy.textContent;
        copy.textContent = "Copied";
        setTimeout(() => { copy.textContent = label; }, 1600);
      });
    }],
    ["[data-close-why]", () => $(".why")?.remove()],
    ["[data-edit]", (edit) => {
      const input = $("input[name=amount]", edit.form);
      edit.hidden = true;
      input.hidden = false;
      input.focus();
      input.select();
      const restore = () => { input.hidden = true; edit.hidden = false; };
      input.addEventListener("keydown", (key) => { if (key.key === "Escape") { key.preventDefault(); restore(); } });
      input.addEventListener("blur", () => setTimeout(restore, 150), { once: true });
    }],
    // ChatGPT sign-in: the link opens OpenAI in a new tab; the dialog waits
    // for the loopback callback, or takes the address pasted from that tab.
    ["[data-chatgpt-start]", () => {
      const dialog = $("#chatgpt-dialog");
      if (!dialog) return;
      dialog.showModal();
      const id = setInterval(() => {
        if (!dialog.open) return clearInterval(id);
        getJson(dialog.dataset.chatgptStatus).then((status) => {
          if (!status.connected || !dialog.open) return;
          clearInterval(id);
          navigate("/settings/ai?chatgpt=connected", { mode: "replace" });
        }).catch(() => {});
      }, 2000);
    }],
    ["[data-paste-address]", (paste) => {
      const input = $("input[name=address]", paste.form);
      navigator.clipboard?.readText().then((value) => {
        input.value = value.trim();
        paste.form.requestSubmit();
      }).catch(() => input.focus());
    }],
    ["[data-palette]", (trigger, event) => {
      event.preventDefault();
      trigger.closest("[popover]")?.hidePopover?.();
      const sheet = trigger.closest("dialog");
      if (sheet && sheet !== $("#palette")) sheet.close();
      openPalette(trigger.dataset.question || "");
    }],
    ["[data-funnel-builder] [data-add-step]", (add) => {
      const builder = add.closest("[data-funnel-builder]");
      const row = $("[data-step-template]", builder).content.firstElementChild.cloneNode(true);
      $("[data-steps]", builder).appendChild(row);
      renumber(builder);
      $("input", row).focus();
    }],
    ["[data-funnel-builder] [data-remove-step]", (remove) => {
      const builder = remove.closest("[data-funnel-builder]");
      if ($$("[data-steps] [data-step]", builder).length > 2) remove.closest("[data-step]").remove();
      funnelChanged(builder);
    }],
    ["[data-remove-tile]", (tile) => { tile.closest(".dash-tile").remove(); saveDashboard(); }],
    ["[data-passkey]", (button, event) => { event.preventDefault(); passkey(button); }],
  ];

  document.addEventListener("click", (event) => {
    for (const [selector, run] of actions) {
      const target = event.target.closest(selector);
      if (target && run(target, event) !== false) return;
    }
    if (event.target.matches("dialog.sheet, dialog.dialog") && pressedBackdrop === event.target && !event.target.dataset.dirty) return closeDialog(event.target);
    follow(event);
  });

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init);
  else init();
})();
