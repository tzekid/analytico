"use strict";

const assert = require("node:assert/strict");
const { spawn } = require("node:child_process");
const fs = require("node:fs");
const http = require("node:http");
const { chromium } = require("playwright");

const dashboard = process.argv[2];
const sessionToken = process.argv[3];
const collector = process.argv[4];
const selfSite = process.argv[5];
const ephemeralSite = process.argv[6];
const prerenderSite = process.argv[7];
const realPrerenderSite = process.argv[8];
const realPrerenderOrigin = process.argv[9];
const fixturePort = Number(process.argv[10]);
if (!dashboard || !sessionToken || !collector || !selfSite || !ephemeralSite ||
    !prerenderSite || !realPrerenderSite || !realPrerenderOrigin ||
    !Number.isInteger(fixturePort)) {
  throw new Error(
    "usage: e2e-exclusion-browser <dashboard> <session> <collector> " +
      "<self-site> <ephemeral-site> <prerender-site> " +
      "<real-prerender-site> <real-prerender-origin> <fixture-port>",
  );
}

const siteOrigin = `http://127.0.0.2:${fixturePort}`;
const localhostOrigin = `http://127.0.0.1:${fixturePort}`;
const speculativeRequests = [];
const fixtureRequests = [];
const fixtureUrls = [];

function siteFor(path) {
  if (path.startsWith("/ephemeral")) return ephemeralSite;
  if (path.startsWith("/prerender")) return prerenderSite;
  if (path.startsWith("/real-prerender")) return realPrerenderSite;
  return selfSite;
}

const fixture = http.createServer((request, response) => {
  const requestUrl = request.url || "/";
  const path = requestUrl.split("?", 1)[0];
  fixtureRequests.push(path);
  fixtureUrls.push(requestUrl);
  if ((request.headers["sec-purpose"] || "").includes("prerender")) {
    speculativeRequests.push({
      path,
      purpose: request.headers["sec-purpose"],
    });
  }
  if (path === "/speculation-activate" || path === "/speculation-never") {
    const target = path === "/speculation-activate" ?
      "/real-prerender-activated" : "/real-prerender-never";
    const activation = path === "/speculation-activate" ? `
<script>
async function activateWhenReady() {
  const response = await fetch("/prerender-ready-activated", { cache: "no-store" });
  if (response.ok) location.assign("${target}");
  else setTimeout(activateWhenReady, 20);
}
setTimeout(activateWhenReady, 20);
</script>` : "";
    response.writeHead(200, {
      "Content-Type": "text/html; charset=utf-8",
      "Cache-Control": "no-store",
    });
    response.end(`<!doctype html>
<html lang="en"><meta charset="utf-8"><title>Speculation trigger</title>
<script type="speculationrules">{"prerender":[{"source":"list","urls":["${target}"],"eagerness":"immediate"}]}</script>
<main><h1>Real prerender trigger</h1><a id="activate" href="${target}">Activate</a></main>
${activation}
</html>`);
    return;
  }
  if (path === "/prerender-ready-activated") {
    const ready = fixtureRequests.includes("/prerender-probe-activated-true");
    response.writeHead(ready ? 204 : 425, { "Cache-Control": "no-store" });
    response.end();
    return;
  }
  const site = siteFor(path);
  const realCandidate = path === "/real-prerender-activated" ? "activated" :
    path === "/real-prerender-never" ? "never" : "";
  const prerenderProbe = realCandidate ?
    `<script>
const analyticoWasPrerendering = document.prerendering;
new Image().src = "/prerender-probe-${realCandidate}-" + analyticoWasPrerendering;
function analyticoReportActivation() {
  const navigation = performance.getEntriesByType("navigation")[0];
  new Image().src = "/prerender-activation-${realCandidate}?was=" +
    analyticoWasPrerendering + "&start=" + navigation.activationStart;
}
if (analyticoWasPrerendering) {
  document.addEventListener("prerenderingchange", analyticoReportActivation, { once: true });
} else {
  analyticoReportActivation();
}
</script>` : "";
  response.writeHead(200, {
    "Content-Type": "text/html; charset=utf-8",
    "Cache-Control": "no-store",
  });
  const trackerOrigin = realCandidate ? realPrerenderOrigin : collector;
  response.end(`<!doctype html>
<html lang="en"><meta charset="utf-8"><title>Exclusion ${path}</title>
<main><h1>Useful measured-site state</h1></main>
${prerenderProbe}
<script defer src="${trackerOrigin}/tracker.bc506cfe.js" data-site="${site}"></script>
</html>`);
});

function launch() {
  const options = {
    headless: true,
    args: [
      "--no-sandbox",
      "--no-proxy-server",
      `--host-resolver-rules=MAP prerender.test 127.0.0.1`,
      "--ignore-certificate-errors",
      "--enable-features=Prerender2",
      "--disable-blink-features=AutomationControlled",
      "--user-agent=Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " +
        "(KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36",
      "--ozone-platform=headless",
      "--use-angle=swiftshader-webgl",
    ],
  };
  if (process.env.ANALYTICO_CHROMIUM_PATH) {
    options.executablePath = process.env.ANALYTICO_CHROMIUM_PATH;
  }
  return chromium.launch(options);
}

function startUnattachedChromium(url) {
  const chromiumPath = process.env.ANALYTICO_CHROMIUM_PATH;
  assert.ok(chromiumPath, "ANALYTICO_CHROMIUM_PATH is required");
  const base = process.env.TMPDIR || "/tmp";
  const profile = fs.mkdtempSync(`${base}/analytico-prerender-profile-`);
  const child = spawn(chromiumPath, [
    "--headless=new",
    "--no-sandbox",
    "--no-proxy-server",
    "--no-first-run",
    "--no-default-browser-check",
    "--ignore-certificate-errors",
    "--enable-features=Prerender2",
    "--user-agent=Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " +
      "(KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36",
    "--ozone-platform=headless",
    "--use-angle=swiftshader-webgl",
    "--host-resolver-rules=MAP prerender.test 127.0.0.1",
    `--user-data-dir=${profile}`,
    url,
  ], { stdio: ["ignore", "ignore", "pipe"] });
  let stderr = "";
  child.stderr.on("data", (chunk) => {
    stderr = (stderr + chunk.toString("utf8")).slice(-16_384);
  });
  return { child, profile, stderr: () => stderr };
}

async function stopUnattachedChromium(process) {
  if (process.child.exitCode === null) {
    await new Promise((resolve) => {
      const timeout = setTimeout(() => process.child.kill("SIGKILL"), 1_000);
      process.child.once("exit", () => {
        clearTimeout(timeout);
        resolve();
      });
      process.child.kill("SIGTERM");
    });
  }
  fs.rmSync(process.profile, { recursive: true, force: true });
}

function waitUntil(predicate, label) {
  return new Promise((resolve, reject) => {
    const started = Date.now();
    const timer = setInterval(() => {
      if (predicate()) {
        clearInterval(timer);
        resolve();
      } else if (Date.now() - started > 10_000) {
        clearInterval(timer);
        reject(new Error(`timed out waiting for ${label}`));
      }
    }, 20);
  });
}

function bodyFor(request) {
  if ((request.url() !== `${collector}/v2/event` &&
      request.url() !== `${realPrerenderOrigin}/v2/event`) ||
      request.method() !== "POST") {
    return null;
  }
  const raw = request.postData() ||
    (request.postDataBuffer() && request.postDataBuffer().toString("utf8"));
  return raw ? JSON.parse(raw) : null;
}

async function nextAccepted(page, predicate) {
  const [request] = await Promise.all([
    page.waitForRequest((candidate) => {
      const body = bodyFor(candidate);
      return body !== null && predicate(body);
    }),
    page.waitForResponse((response) => {
      const body = bodyFor(response.request());
      return response.status() === 204 && body !== null && predicate(body);
    }),
  ]);
  return bodyFor(request);
}

async function storage(page, site) {
  return page.evaluate((siteId) => ({
    excluded: localStorage.getItem(`anl:${siteId}:x`),
    keys: Object.keys(localStorage).filter((key) => key.startsWith(`anl:${siteId}:`)),
  }), site);
}

async function selfExclusion(browser) {
  const context = await browser.newContext();
  await context.addCookies([{
    name: "analytico_session",
    value: sessionToken,
    url: dashboard,
  }]);
  const admin = await context.newPage();
  await admin.goto(`${dashboard}/admin?site=self`, { waitUntil: "load" });
  const management = admin.locator("details.management", {
    hasText: "Self-visit exclusion",
  });
  await management.locator("summary").click();
  assert.equal(
    await management.locator('a[data-self-exclusion="on"]').count(),
    2,
  );

  let eventPromise;
  eventPromise = context.waitForEvent("request", {
    predicate(request) {
      const body = bodyFor(request);
      return body && body.site === selfSite && body.self_excluded === true;
    },
  });
  const popupPromise = context.waitForEvent("page");
  await management.locator(
    `a[data-self-exclusion="on"][data-origin="${siteOrigin}"]`,
  ).click();
  const enabledPopup = await popupPromise;
  const enabledRequest = await eventPromise;
  const enabled = bodyFor(enabledRequest);
  assert.equal((await enabledRequest.response()).status(), 204);
  await enabledPopup.waitForLoadState("load");
  await enabledPopup.waitForFunction(
    ([site]) => localStorage.getItem(`anl:${site}:x`) === "1",
    [selfSite],
  );
  assert.equal((await storage(enabledPopup, selfSite)).excluded, "1");

  const flagged = await context.newPage();
  eventPromise = nextAccepted(
    flagged,
    (body) => body.site === selfSite && body.page.path === "/flagged",
  );
  await flagged.goto(`${siteOrigin}/flagged`, { waitUntil: "load" });
  const flaggedEvent = await eventPromise;
  assert.equal(flaggedEvent.self_excluded, true);

  eventPromise = context.waitForEvent("request", {
    predicate(request) {
      const body = bodyFor(request);
      return body && body.site === selfSite && body.self_excluded === true &&
        body.page.path === "/";
    },
  });
  const disabledPopupPromise = context.waitForEvent("page");
  await management.locator(
    `a[data-self-exclusion="off"][data-origin="${siteOrigin}"]`,
  ).click();
  const disabledPopup = await disabledPopupPromise;
  const disabledRequest = await eventPromise;
  const disabled = bodyFor(disabledRequest);
  assert.equal((await disabledRequest.response()).status(), 204);
  await disabledPopup.waitForLoadState("load");
  await disabledPopup.waitForFunction(
    ([site]) => localStorage.getItem(`anl:${site}:x`) === null,
    [selfSite],
  );

  const included = await context.newPage();
  eventPromise = nextAccepted(
    included,
    (body) => body.site === selfSite && body.page.path === "/included",
  );
  await included.goto(`${siteOrigin}/included`, { waitUntil: "load" });
  const includedEvent = await eventPromise;
  assert.equal("self_excluded" in includedEvent, false);

  await context.close();
  return {
    excluded_event_ids: [enabled.event_id, flaggedEvent.event_id, disabled.event_id],
    included_event_id: includedEvent.event_id,
    first_party_flag_set_and_cleared: true,
  };
}

async function localhostSilence(browser) {
  const context = await browser.newContext();
  const page = await context.newPage();
  let requests = 0;
  page.on("request", (request) => {
    if (bodyFor(request)) requests += 1;
  });
  await page.goto(`${localhostOrigin}/localhost`, { waitUntil: "load" });
  await page.waitForTimeout(100);
  assert.equal(requests, 0);
  assert.equal(await page.evaluate(() => localStorage.length), 0);
  assert.equal(await page.evaluate(() => typeof window.analytico.track), "function");
  await context.close();
  return { requests: 0, storage_entries: 0 };
}

async function prerender(browser) {
  const context = await browser.newContext();
  await context.addInitScript(() => {
    window.__analytico_prerendering = true;
    Object.defineProperty(Document.prototype, "prerendering", {
      configurable: true,
      get() { return window.__analytico_prerendering; },
    });
  });

  const never = await context.newPage();
  let neverRequests = 0;
  never.on("request", (request) => {
    const body = bodyFor(request);
    if (body && body.site === prerenderSite) neverRequests += 1;
  });
  await never.goto(`${siteOrigin}/prerender-never`, { waitUntil: "load" });
  await never.waitForTimeout(100);
  assert.equal(neverRequests, 0);
  assert.equal((await storage(never, prerenderSite)).keys.length, 0);
  await never.close();

  const activated = await context.newPage();
  await activated.goto(`${siteOrigin}/prerender-activated`, { waitUntil: "load" });
  await activated.waitForTimeout(100);
  assert.equal((await storage(activated, prerenderSite)).keys.length, 0);
  const accepted = nextAccepted(
    activated,
    (body) => body.site === prerenderSite &&
      body.page.path === "/prerender-activated",
  );
  await activated.evaluate(() => {
    window.__analytico_prerendering = false;
    document.dispatchEvent(new Event("prerenderingchange"));
  });
  const event = await accepted;
  assert.equal(event.type, "pageview");
  assert.equal((await storage(activated, prerenderSite)).keys.length, 2);
  await context.close();
  return { never_activated_requests: 0, activated_event_id: event.event_id };
}

async function realPrerender() {
  const activated = startUnattachedChromium(
    `${realPrerenderOrigin}/speculation-activate`,
  );
  let activation;
  try {
    await waitUntil(
      () => speculativeRequests.some((entry) =>
        entry.path === "/real-prerender-activated" &&
        entry.purpose.includes("prerender")),
      "real activated candidate request",
    );
    await waitUntil(
      () => fixtureRequests.includes("/prerender-probe-activated-true"),
      "activated candidate script executing while prerendering",
    );
    await waitUntil(
      () => fixtureUrls.some((url) =>
        url.startsWith("/prerender-activation-activated?")),
      "real prerender activation",
    );
    activation = fixtureUrls.find((url) =>
      url.startsWith("/prerender-activation-activated?"));
    await new Promise((resolve) => setTimeout(resolve, 200));
  } catch (error) {
    throw new Error(`${error.message}; Chromium stderr: ${activated.stderr()}`);
  } finally {
    await stopUnattachedChromium(activated);
  }
  const activationUrl = new URL(activation, realPrerenderOrigin);
  assert.equal(activationUrl.searchParams.get("was"), "true");
  assert.ok(
    Number(activationUrl.searchParams.get("start")) > 0,
    "real prerender activationStart is positive",
  );

  const never = startUnattachedChromium(
    `${realPrerenderOrigin}/speculation-never`,
  );
  try {
    await waitUntil(
      () => speculativeRequests.some((entry) =>
        entry.path === "/real-prerender-never" &&
        entry.purpose.includes("prerender")),
      "real never-activated candidate request",
    );
    await waitUntil(
      () => fixtureRequests.includes("/prerender-probe-never-true"),
      "never-activated candidate script executing while prerendering",
    );
    await new Promise((resolve) => setTimeout(resolve, 200));
    assert.equal(
      fixtureRequests.includes("/prerender-activation-never"),
      false,
    );
  } catch (error) {
    throw new Error(`${error.message}; Chromium stderr: ${never.stderr()}`);
  } finally {
    await stopUnattachedChromium(never);
  }
  return {
    activation_start_positive: true,
    candidate_executed_while_prerendering: true,
    activated_speculative_request: true,
    never_activated_speculative_request: true,
    never_candidate_remained_unactivated: true,
  };
}

async function storageBlocked(browser) {
  const context = await browser.newContext();
  await context.addInitScript(() => {
    Object.defineProperty(window, "localStorage", {
      get() { throw new Error("blocked"); },
    });
  });
  const events = [];
  for (const suffix of ["one", "two"]) {
    const page = await context.newPage();
    const accepted = nextAccepted(
      page,
      (body) => body.site === ephemeralSite &&
        body.page.path === `/ephemeral-${suffix}`,
    );
    await page.goto(`${siteOrigin}/ephemeral-${suffix}`, { waitUntil: "load" });
    events.push(await accepted);
    await page.close();
  }
  assert.equal(events[0].identity_quality, "ephemeral");
  assert.equal(events[1].identity_quality, "ephemeral");
  assert.notEqual(events[0].anonymous_id, events[1].anonymous_id);
  assert.notEqual(events[0].session_id, events[1].session_id);
  await context.close();
  return { event_ids: events.map((event) => event.event_id), page_loads: 2 };
}

async function main() {
  await new Promise((resolve, reject) => {
    fixture.once("error", reject);
    fixture.listen(fixturePort, "0.0.0.0", resolve);
  });
  const browser = await launch();
  try {
    const self = await selfExclusion(browser);
    const localhost = await localhostSilence(browser);
    const prerenderResult = await prerender(browser);
    const realPrerenderResult = await realPrerender();
    const ephemeral = await storageBlocked(browser);
    process.stdout.write(JSON.stringify({
      engine: "chromium",
      self,
      localhost,
      simulated_prerender_api_path: prerenderResult,
      real_prerender: realPrerenderResult,
      ephemeral,
    }) + "\n");
  } finally {
    await browser.close();
    await new Promise((resolve) => fixture.close(resolve));
  }
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
