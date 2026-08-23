"use strict";

const assert = require("node:assert/strict");
const http = require("node:http");
const { chromium } = require("playwright");

const collector = process.argv[2];
const site = process.argv[3];
const fixturePort = Number(process.argv[4]);
if (!collector || !site || !Number.isInteger(fixturePort)) {
  throw new Error(
    "usage: node e2e-tracker-browser.cjs <collector> <site> <fixture-port>",
  );
}

const fixtureOrigin = `http://127.0.0.2:${fixturePort}`;
const tracker = `${collector}/tracker.6de111c9.js`;

function html(mode) {
  let attributes = "";
  if (mode === "spa") attributes = ' data-spa="auto"';
  if (mode === "engagement") attributes = ' data-engagement="true"';
  if (mode === "automatic") {
    attributes = ' data-outbound="true" data-downloads="true"' +
      ' data-forms="true" data-not-found="true"';
  }
  return `<!doctype html>
<html lang="en">
<meta charset="utf-8">
<title>Tracker ${mode}</title>
<script defer src="${tracker}" data-site="${site}"${attributes}></script>
<main style="min-height:4000px">
  <h1>Useful tracked fixture</h1>
  <a id="outbound" href="https://outside.example/private?token=secret">Outside</a>
  <a id="download" href="https://outside.example/files/report.pdf?token=secret" download>PDF</a>
  <form id="signup" action="https://forms.example/submit?token=secret">
    <input name="password" value="supersecret">
    <button>Submit</button>
  </form>
</main>
<script>
document.addEventListener("click", event => {
  if (event.target.closest && event.target.closest("a")) event.preventDefault();
});
document.addEventListener("submit", event => event.preventDefault());
</script>
</html>`;
}

const server = http.createServer((request, response) => {
  const mode = (request.url || "").split("?", 1)[0].slice(1) || "disabled";
  response.writeHead(200, {
    "Content-Type": "text/html; charset=utf-8",
    "Cache-Control": "no-store",
  });
  response.end(html(mode));
});

function launch() {
  const options = {
    headless: true,
    args: [
      "--no-sandbox",
      "--ozone-platform=headless",
      "--use-angle=swiftshader-webgl",
    ],
  };
  if (process.env.ANALYTICO_CHROMIUM_PATH) {
    options.executablePath = process.env.ANALYTICO_CHROMIUM_PATH;
  }
  return chromium.launch(options);
}

function eventBody(request) {
  if (request.url() !== `${collector}/v2/event` || request.method() !== "POST") {
    return null;
  }
  const raw = request.postData() ||
    (request.postDataBuffer() && request.postDataBuffer().toString("utf8"));
  return raw ? JSON.parse(raw) : null;
}

function recordEvents(page) {
  const events = [];
  page.on("request", (request) => {
    const event = eventBody(request);
    if (event) events.push(event);
  });
  return events;
}

function nextEvent(page, predicate) {
  return Promise.all([
    page.waitForRequest((request) => {
      const event = eventBody(request);
      return event !== null && predicate(event);
    }),
    page.waitForResponse((response) => {
      const event = eventBody(response.request());
      return response.status() === 204 && event !== null && predicate(event);
    }),
  ]).then(([request]) => eventBody(request));
}

async function verifySpa(browser) {
  const context = await browser.newContext();
  const page = await context.newPage();
  const events = recordEvents(page);
  let accepted = nextEvent(page, (event) => event.type === "pageview");
  await page.goto(`${fixtureOrigin}/spa?private=initial`, { waitUntil: "load" });
  const initial = await accepted;
  assert.equal(initial.page.path, "/spa");

  accepted = nextEvent(
    page,
    (event) => event.type === "pageview" && event.page.path === "/pricing",
  );
  await page.evaluate(() => {
    document.title = "Pricing";
    history.pushState({}, "", "/pricing?private=first");
  });
  const pricing = await accepted;
  assert.equal(pricing.page.title, "Pricing");
  assert.equal(JSON.stringify(pricing).includes("private"), false);

  const beforeDuplicate = events.filter((event) => event.type === "pageview").length;
  await page.evaluate(() => {
    history.pushState({}, "", "/pricing?private=second");
    history.replaceState({}, "", "/pricing?private=third");
  });
  await page.waitForTimeout(30);
  assert.equal(
    events.filter((event) => event.type === "pageview").length,
    beforeDuplicate,
  );

  accepted = nextEvent(
    page,
    (event) => event.type === "pageview" && event.page.path === "/checkout",
  );
  await page.evaluate(() => {
    document.title = "Checkout";
    history.replaceState({}, "", "/checkout?private=replace");
  });
  const checkout = await accepted;
  assert.equal(checkout.page.title, "Checkout");

  accepted = nextEvent(
    page,
    (event) => event.type === "pageview" && event.page.path === "/pricing",
  );
  await page.goBack();
  const popped = await accepted;
  assert.equal(popped.page.path, "/pricing");
  await context.close();
  return {
    initial: initial.event_id,
    pricing: pricing.event_id,
    checkout: checkout.event_id,
    popped: popped.event_id,
    pageviews: events.filter((event) => event.type === "pageview").length,
  };
}

async function setVisibility(page, state) {
  await page.evaluate((next) => {
    Object.defineProperty(document, "visibilityState", {
      configurable: true,
      get: () => next,
    });
    document.dispatchEvent(new Event("visibilitychange"));
  }, state);
}

async function verifyEngagement(browser) {
  const context = await browser.newContext();
  const page = await context.newPage();
  await page.clock.install({ time: Date.now() });
  const events = recordEvents(page);
  let accepted = nextEvent(page, (event) => event.type === "pageview");
  await page.goto(`${fixtureOrigin}/engagement`, { waitUntil: "load" });
  await accepted;

  accepted = nextEvent(page, (event) => event.type === "engagement");
  await page.clock.fastForward(15_000);
  const first = await accepted;
  assert.ok(first.engagement.active_ms >= 14_900);
  assert.ok(first.engagement.active_ms <= 15_100);
  assert.ok(first.engagement.max_scroll_depth >= 0);
  assert.ok(first.engagement.max_scroll_depth <= 100);
  assert.equal("referrer" in first, false);
  assert.equal("utm" in first, false);

  await page.evaluate(() => window.scrollTo(0, document.documentElement.scrollHeight));
  accepted = nextEvent(
    page,
    (event) => event.type === "engagement" &&
      event.engagement.max_scroll_depth === 100,
  );
  await page.clock.fastForward(15_000);
  const scrolled = await accepted;
  assert.ok(scrolled.engagement.active_ms >= 14_900);
  assert.ok(scrolled.engagement.active_ms <= 15_100);

  const beforeIdleWindow = events.filter(
    (event) => event.type === "engagement",
  ).length;
  await page.clock.fastForward(60_000);
  const afterActiveWindow = events.filter(
    (event) => event.type === "engagement",
  ).length;
  assert.ok(afterActiveWindow >= beforeIdleWindow + 1);
  assert.ok(afterActiveWindow <= beforeIdleWindow + 4);
  await page.clock.fastForward(30_000);
  const afterIdleWindow = events.filter(
    (event) => event.type === "engagement",
  ).length;
  assert.equal(afterIdleWindow, afterActiveWindow);

  await page.clock.fastForward(5_000);
  const beforeHidden = events.filter((event) => event.type === "engagement").length;
  await page.evaluate(() => window.analytico.reset());
  assert.equal(
    events.filter((event) => event.type === "engagement").length,
    beforeHidden,
  );
  await setVisibility(page, "hidden");
  const afterReset = events.filter((event) => event.type === "engagement");
  assert.ok(afterReset.length === beforeHidden || afterReset.length === beforeHidden + 1);
  if (afterReset.length === beforeHidden + 1) {
    const lifecycleAfterReset = afterReset[afterReset.length - 1];
    assert.ok(lifecycleAfterReset.engagement.active_ms <= 100);
    assert.notEqual(lifecycleAfterReset.anonymous_id, first.anonymous_id);
  }
  const beforeHiddenTime = afterReset.length;
  await page.clock.fastForward(45_000);
  assert.equal(
    events.filter((event) => event.type === "engagement").length,
    beforeHiddenTime,
  );

  await setVisibility(page, "visible");
  await page.dispatchEvent("body", "pointerdown");
  accepted = nextEvent(page, (event) => event.type === "engagement");
  await page.clock.fastForward(15_000);
  const resumed = await accepted;
  assert.ok(resumed.engagement.active_ms >= 14_900);
  assert.ok(resumed.engagement.active_ms <= 15_100);
  assert.notEqual(resumed.anonymous_id, first.anonymous_id);

  accepted = nextEvent(page, (event) => event.type === "engagement");
  await page.clock.fastForward(5_000);
  await setVisibility(page, "hidden");
  const lifecycle = await accepted;
  assert.ok(lifecycle.engagement.active_ms >= 4_900);
  assert.ok(lifecycle.engagement.active_ms <= 5_100);
  assert.equal(lifecycle.engagement.max_scroll_depth, 100);
  await context.close();
  return {
    first: first.event_id,
    scrolled: scrolled.event_id,
    resumed: resumed.event_id,
    lifecycle: lifecycle.event_id,
    hidden_network_events: 0,
    idle_network_events: afterIdleWindow - afterActiveWindow,
    active_window_events: afterActiveWindow - beforeIdleWindow,
    requests: events.length,
  };
}

async function verifyAutomaticAndValue(browser) {
  const context = await browser.newContext();
  const page = await context.newPage();
  const events = recordEvents(page);
  const pageview = nextEvent(page, (event) => event.type === "pageview");
  const notFound = nextEvent(
    page,
    (event) => event.type === "event" && event.name === "not_found",
  );
  await page.goto(`${fixtureOrigin}/automatic`, { waitUntil: "load" });
  await pageview;
  const missing = await notFound;

  let accepted = nextEvent(
    page,
    (event) => event.type === "event" && event.name === "outbound_click",
  );
  await page.click("#outbound");
  const outbound = await accepted;
  assert.deepEqual(outbound.properties, { url_host: "outside.example" });
  assert.equal(JSON.stringify(outbound).includes("secret"), false);

  const outboundBeforeDownload = events.filter(
    (event) => event.name === "outbound_click",
  ).length;
  accepted = nextEvent(
    page,
    (event) => event.type === "event" && event.name === "file_download",
  );
  await page.click("#download");
  const download = await accepted;
  assert.deepEqual(download.properties, {
    url_path: "/files/report.pdf",
    extension: "pdf",
  });
  assert.equal(
    events.filter((event) => event.name === "outbound_click").length,
    outboundBeforeDownload,
  );

  accepted = nextEvent(
    page,
    (event) => event.type === "event" && event.name === "form_submit",
  );
  await page.click("#signup button");
  const form = await accepted;
  assert.deepEqual(form.properties, {
    action_path: "/submit",
    action_host: "forms.example",
    form_id: "signup",
  });
  const formJson = JSON.stringify(form);
  assert.equal(formJson.includes("supersecret"), false);
  assert.equal(formJson.includes("password"), false);

  accepted = nextEvent(
    page,
    (event) => event.type === "event" && event.name === "purchase",
  );
  await page.evaluate(() => {
    window.analytico.track("purchase", {
      value: "49.00",
      currency: "EUR",
      plan: "pro",
    });
  });
  const purchase = await accepted;
  assert.deepEqual(purchase.value, { amount: "49.00", currency: "EUR" });
  assert.deepEqual(purchase.properties, { plan: "pro" });

  const beforeInvalidValue = events.length;
  await page.evaluate(() => {
    window.analytico.track("bad_value", { value: "1e2", currency: "EUR" });
    window.analytico.track("incomplete_value", { value: "1.00" });
  });
  await page.waitForTimeout(30);
  assert.equal(events.length, beforeInvalidValue);

  const disabledPage = await context.newPage();
  const disabledEvents = recordEvents(disabledPage);
  accepted = nextEvent(disabledPage, (event) => event.type === "pageview");
  await disabledPage.goto(`${fixtureOrigin}/disabled`, { waitUntil: "load" });
  await accepted;
  await disabledPage.click("#outbound");
  await disabledPage.click("#download");
  await disabledPage.click("#signup button");
  await disabledPage.evaluate(() => history.pushState({}, "", "/disabled-next"));
  await disabledPage.waitForTimeout(30);
  assert.equal(disabledEvents.length, 1);
  await context.close();
  return {
    not_found: missing.event_id,
    outbound: outbound.event_id,
    download: download.event_id,
    form: form.event_id,
    purchase: purchase.event_id,
    automatic_opt_in_only: true,
    form_values_absent: true,
    requests: events.length,
    disabled_requests: disabledEvents.length,
  };
}

async function main() {
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(fixturePort, "0.0.0.0", resolve);
  });
  const browser = await launch();
  try {
    const spa = await verifySpa(browser);
    const engagement = await verifyEngagement(browser);
    const automatic = await verifyAutomaticAndValue(browser);
    process.stdout.write(JSON.stringify({
      engine: "chromium",
      spa,
      engagement,
      automatic,
      stored_events_expected: spa.pageviews + engagement.requests +
        automatic.requests + automatic.disabled_requests,
    }) + "\n");
  } finally {
    await browser.close();
    await new Promise((resolve) => server.close(resolve));
  }
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
