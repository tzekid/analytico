"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const http = require("node:http");
const zlib = require("node:zlib");
const { chromium } = require("playwright");

const dashboard = process.argv[2];
const sessionToken = process.argv[3];
const site = process.argv[4];
const fixturePort = Number(process.argv[5]);
const oldOccurredMs = Number(process.argv[6]);
if (!dashboard || !sessionToken || !site || !Number.isInteger(fixturePort) ||
    !Number.isSafeInteger(oldOccurredMs)) {
  throw new Error(
    "usage: node e2e-installation-browser.cjs " +
      "<dashboard-origin> <session-token> <site-id> <fixture-port> <old-occurred-ms>",
  );
}

const fixtureOrigin = `http://127.0.0.2:${fixturePort}`;
const installPath = "/admin/sites/install-fixture/install";
let trackerSnippet = "";

const fixtureServer = http.createServer((request, response) => {
  if (!trackerSnippet) {
    response.writeHead(503, { "Content-Type": "text/plain" });
    response.end("snippet unavailable\n");
    return;
  }
  response.writeHead(200, {
    "Cache-Control": "no-store",
    "Content-Type": "text/html; charset=utf-8",
  });
  response.end(`<!doctype html>
<html lang="en">
<meta charset="utf-8">
<title>Installation fixture</title>
${trackerSnippet}
<main><h1>Tracked installation page</h1></main>
</html>`);
});

function listen() {
  return new Promise((resolve, reject) => {
    fixtureServer.once("error", reject);
    fixtureServer.listen(fixturePort, "127.0.0.2", resolve);
  });
}

function closeFixture() {
  return new Promise((resolve, reject) => {
    fixtureServer.close((error) => error ? reject(error) : resolve());
  });
}

function eventBody(eventId, sequence, overrides = {}) {
  return JSON.stringify({
    v: 2,
    site,
    event_id: eventId,
    anonymous_id: "00000000-0000-4000-8000-000000002001",
    identity_quality: "persistent",
    session_id: "00000000-0000-4000-8000-000000002002",
    sequence,
    occurred_at_ms: Date.now(),
    type: "pageview",
    page: {
      path: `/manual-${sequence}`,
      hostname: "127.0.0.2",
    },
    ...overrides,
  });
}

function signedInstall(urlText) {
  const url = new URL(urlText);
  assert.equal(url.pathname, installPath);
  for (const field of ["started", "count", "after", "event", "sig"]) {
    assert.ok(url.searchParams.get(field), `${field} missing from ${url}`);
  }
  assert.equal(url.searchParams.get("fragment"), null);
  return url;
}

async function requestEvent(context, body, origin = fixtureOrigin) {
  return context.request.post(`${dashboard}/v2/event`, {
    data: body,
    headers: {
      "Content-Type": "text/plain;charset=UTF-8",
      Origin: origin,
      "User-Agent":
        "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " +
        "(KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36",
    },
  });
}

async function main() {
  await listen();
  const options = {
    headless: true,
    args: [
      "--no-sandbox",
      "--disable-blink-features=AutomationControlled",
      "--ozone-platform=headless",
      "--use-angle=swiftshader-webgl",
    ],
  };
  if (process.env.ANALYTICO_CHROMIUM_PATH) {
    options.executablePath = process.env.ANALYTICO_CHROMIUM_PATH;
  }
  const browser = await chromium.launch(options);
  try {
    const cookie = {
      name: "analytico_session",
      value: sessionToken,
      url: dashboard,
    };
    const jsOff = await browser.newContext({
      javaScriptEnabled: false,
      viewport: { width: 360, height: 844 },
    });
    await jsOff.addCookies([cookie]);
    const nativePage = await jsOff.newPage();
    const nativeRequests = [];
    nativePage.on("request", (request) => nativeRequests.push({
      type: request.resourceType(),
      url: request.url(),
    }));
    let response = await nativePage.goto(`${dashboard}${installPath}`, {
      waitUntil: "load",
    });
    assert.equal(response.status(), 200);
    assert.equal(response.headers()["referrer-policy"], "no-referrer");
    const waitingUrl = signedInstall(nativePage.url());
    assert.equal(
      await nativePage.getByText("Waiting for a new committed event.", {
        exact: false,
      }).count(),
      1,
    );
    assert.equal(
      await nativePage.getByText("Tracker verified.", { exact: false }).count(),
      0,
    );
    trackerSnippet = await nativePage.locator("#tracker-snippet").inputValue();
    assert.ok(trackerSnippet.includes(`${dashboard}/tracker.bc506cfe.js`));
    assert.ok(trackerSnippet.includes(`data-site="${site}"`));
    assert.ok(trackerSnippet.includes("data-spa=\"auto\""));
    assert.ok(trackerSnippet.includes("data-engagement=\"true\""));
    assert.ok(trackerSnippet.includes("<noscript>"));
    assert.equal(await nativePage.locator("#tracker-snippet").getAttribute("readonly"), "");
    assert.equal(
      nativeRequests.some((request) => request.url.includes("/admin/install.")),
      false,
    );
    await nativePage.keyboard.press("Tab");
    assert.equal(
      await nativePage.evaluate(() => document.activeElement?.textContent),
      "Skip to main content",
    );
    await nativePage.keyboard.press("Enter");
    assert.equal(await nativePage.evaluate(() => document.activeElement?.id), "main");
    assert.ok(
      await nativePage.evaluate(
        () => document.documentElement.scrollWidth <= window.innerWidth,
      ),
    );

    const tampered = new URL(waitingUrl);
    tampered.searchParams.set("after", "0");
    response = await jsOff.request.get(tampered.toString(), { maxRedirects: 0 });
    assert.equal(response.status(), 400);
    response = await jsOff.request.get(`${waitingUrl}&started=1`, {
      maxRedirects: 0,
    });
    assert.equal(response.status(), 400);
    response = await jsOff.request.get(`${waitingUrl}&private=yes`, {
      maxRedirects: 0,
    });
    assert.equal(response.status(), 400);

    response = await requestEvent(
      jsOff,
      JSON.stringify({
        v: 2,
        site,
        event_id: "00000000-0000-4000-8000-000000002010",
        anonymous_id: "00000000-0000-4000-8000-000000002001",
        identity_quality: "persistent",
        session_id: "00000000-0000-4000-8000-000000002002",
        sequence: 0,
        occurred_at_ms: oldOccurredMs,
        type: "pageview",
        page: { path: "/old-event", hostname: "127.0.0.2" },
      }),
    );
    assert.equal(response.status(), 204);
    await Promise.all([
      nativePage.waitForNavigation(),
      nativePage.getByRole("button", { name: "Check again" }).click(),
    ]);
    assert.equal(
      await nativePage.getByText("Waiting for a new committed event.", {
        exact: false,
      }).count(),
      1,
    );
    assert.equal(
      await nativePage.getByText("Recent attempt since process restart: Duplicate event.", {
        exact: false,
      }).count(),
      1,
    );

    response = await requestEvent(
      jsOff,
      eventBody("00000000-0000-4000-8000-000000002011", 1),
      "https://attacker.example",
    );
    assert.equal(response.status(), 403);
    await Promise.all([
      nativePage.waitForNavigation(),
      nativePage.getByRole("button", { name: "Check again" }).click(),
    ]);
    assert.equal(
      await nativePage.getByText("Recent attempt since process restart: Origin not allowed.", {
        exact: false,
      }).count(),
      1,
    );

    response = await requestEvent(
      jsOff,
      eventBody("00000000-0000-4000-8000-000000002012", 2, {
        type: "event",
        name: "invalid_properties",
        properties: { nested: { secret: true } },
      }),
    );
    assert.equal(response.status(), 400);
    await Promise.all([
      nativePage.waitForNavigation(),
      nativePage.getByRole("button", { name: "Check again" }).click(),
    ]);
    assert.equal(
      await nativePage.getByText("Recent attempt since process restart: Invalid properties.", {
        exact: false,
      }).count(),
      1,
    );
    await nativePage.getByText("Common rejection corrections").click();
    assert.equal(
      await nativePage.getByText("Malformed or oversized attempts", {
        exact: false,
      }).count(),
      1,
    );

    const v1 = JSON.stringify({
      v: 1,
      site,
      type: "pageview",
      path: "/v1-confirmed",
    });
    response = await jsOff.request.post(`${dashboard}/v1/event`, {
      data: v1,
      headers: {
        "Content-Type": "text/plain",
        Origin: fixtureOrigin,
        "User-Agent": "Mozilla/5.0 Chrome/151.0.0.0 Safari/537.36",
      },
    });
    assert.equal(response.status(), 204);
    await Promise.all([
      nativePage.waitForNavigation(),
      nativePage.getByRole("button", { name: "Check again" }).click(),
    ]);
    assert.equal(
      await nativePage.getByText("Tracker verified.", { exact: false }).count(),
      1,
    );
    assert.equal(
      await nativePage.getByText("Protocol v1 compatibility:", {
        exact: false,
      }).count(),
      1,
    );
    assert.equal(await nativePage.getByText("/v1-confirmed", { exact: true }).count(), 1);
    assert.equal(await nativePage.getByText("Page view", { exact: true }).count(), 1);
    assert.match(
      await nativePage.locator("#installation-verification").innerText(),
      /Received\s+\d{4}-\d{2}-\d{2} \d{2}:\d{2} UTC/,
    );
    assert.equal(await nativePage.getByRole("link", { name: "Open Overview" }).count(), 1);
    assert.equal(await nativePage.getByRole("link", { name: "View Live diagnostics" }).count(), 1);

    response = await nativePage.goto(`${dashboard}${installPath}`, {
      waitUntil: "load",
    });
    assert.equal(response.status(), 200);
    response = await requestEvent(
      jsOff,
      eventBody("00000000-0000-4000-8000-000000002013", 3, {
        self_excluded: true,
        page: {
          path: "/<install>&attack",
          hostname: "127.0.0.2",
        },
      }),
    );
    assert.equal(response.status(), 204);
    await Promise.all([
      nativePage.waitForNavigation(),
      nativePage.getByRole("button", { name: "Check again" }).click(),
    ]);
    assert.equal(
      await nativePage.getByText("Tracker verified.", { exact: false }).count(),
      1,
    );
    assert.equal(
      await nativePage.getByText("/<install>&attack", { exact: true }).count(),
      1,
    );
    assert.equal(await nativePage.locator("script").count(), 1);
    assert.equal(await nativePage.getByText("Page view", { exact: true }).count(), 1);

    response = await nativePage.goto(`${dashboard}${installPath}`, {
      waitUntil: "load",
    });
    assert.equal(response.status(), 200);
    const automaticUrl = signedInstall(nativePage.url()).toString();
    assert.equal(
      await nativePage.getByText("Waiting for a new committed event.", {
        exact: false,
      }).count(),
      1,
    );
    await jsOff.close();

    const context = await browser.newContext({
      permissions: ["clipboard-read", "clipboard-write"],
      viewport: { width: 1280, height: 900 },
    });
    await context.addCookies([cookie]);
    const page = await context.newPage();
    await page.clock.install({ time: Date.now() });
    const requests = [];
    page.on("request", (request) => requests.push({
      type: request.resourceType(),
      url: request.url(),
      referer: request.headers().referer || "",
    }));
    response = await page.goto(automaticUrl, { waitUntil: "load" });
    assert.equal(response.status(), 200);
    assert.equal(response.headers()["referrer-policy"], "no-referrer");
    assert.equal(
      requests.filter((request) => request.url.includes("fragment=verification")).length,
      0,
    );
    const installAsset = requests.find((request) =>
      request.url.includes("/admin/install.fe0cc47b.js"),
    );
    assert.ok(installAsset);
    assert.equal(installAsset.referer, "");
    assert.deepEqual(
      [...new Set(requests.map((request) => request.type))].sort(),
      ["document", "script", "stylesheet"],
    );

    await page.getByRole("button", { name: "Copy snippet" }).click();
    await page.getByText("Snippet copied.", { exact: true }).waitFor();
    assert.equal(
      await page.evaluate(() => navigator.clipboard.readText()),
      trackerSnippet,
    );
    await page.evaluate(() => {
      Object.defineProperty(navigator, "clipboard", {
        configurable: true,
        value: { writeText: () => Promise.reject(new Error("fixture denial")) },
      });
    });
    await page.getByRole("button", { name: "Copy snippet" }).click();
    await page.getByText("Clipboard unavailable. The snippet is selected for manual copy.", {
      exact: true,
    }).waitFor();
    assert.deepEqual(
      await page.locator("#tracker-snippet").evaluate((field) => [
        field.selectionStart,
        field.selectionEnd,
        field.value.length,
      ]),
      [0, trackerSnippet.length, trackerSnippet.length],
    );

    const fragmentCount = () => requests.filter((request) =>
      request.url.includes("fragment=verification"),
    ).length;
    await page.getByRole("button", { name: "Pause automatic checks" }).click();
    await page.clock.fastForward(10_000);
    await page.waitForTimeout(0);
    assert.equal(fragmentCount(), 0);
    const resumed = page.waitForResponse((candidate) =>
      candidate.url().includes("fragment=verification") && candidate.status() === 200,
    );
    await page.getByRole("button", { name: "Resume automatic checks" }).click();
    await page.clock.fastForward(5_000);
    await resumed;
    assert.equal(fragmentCount(), 1);

    await page.evaluate(() => {
      Object.defineProperty(document, "hidden", {
        configurable: true,
        get: () => true,
      });
      Object.defineProperty(document, "visibilityState", {
        configurable: true,
        get: () => "hidden",
      });
      document.dispatchEvent(new Event("visibilitychange"));
    });
    await page.clock.fastForward(10_000);
    await page.waitForTimeout(0);
    assert.equal(fragmentCount(), 1);
    const visiblePoll = page.waitForResponse((candidate) =>
      candidate.url().includes("fragment=verification") && candidate.status() === 200,
    );
    await page.evaluate(() => {
      Object.defineProperty(document, "hidden", {
        configurable: true,
        get: () => false,
      });
      Object.defineProperty(document, "visibilityState", {
        configurable: true,
        get: () => "visible",
      });
      document.dispatchEvent(new Event("visibilitychange"));
    });
    await page.clock.fastForward(5_000);
    await visiblePoll;
    assert.equal(fragmentCount(), 2);

    const tracked = await browser.newContext();
    const trackedPage = await tracked.newPage();
    const accepted = trackedPage.waitForResponse((candidate) =>
      candidate.url() === `${dashboard}/v2/event` && candidate.status() === 204,
    );
    await trackedPage.goto(`${fixtureOrigin}/first-event`, { waitUntil: "load" });
    await accepted;
    const successPoll = page.waitForResponse((candidate) =>
      candidate.url().includes("fragment=verification") && candidate.status() === 200,
    );
    await page.clock.fastForward(5_000);
    await successPoll;
    await page.getByText("Tracker verified.", { exact: false }).waitFor();
    assert.equal(await page.getByText("/first-event", { exact: true }).count(), 1);
    assert.equal(
      await page.locator("#installation-verification").getByText("v2", {
        exact: true,
      }).count(),
      1,
    );
    assert.equal(await page.getByText("Page view", { exact: true }).count(), 1);
    assert.match(
      await page.locator("#installation-verification").innerText(),
      /Received\s+\d{4}-\d{2}-\d{2} \d{2}:\d{2} UTC/,
    );
    const successCount = fragmentCount();
    await page.clock.fastForward(15_000);
    await page.waitForTimeout(0);
    assert.equal(fragmentCount(), successCount);
    if (process.env.ANALYTICO_INSTALL_SIGNED_PATH_FILE) {
      const signedPath = new URL(automaticUrl);
      fs.writeFileSync(
        process.env.ANALYTICO_INSTALL_SIGNED_PATH_FILE,
        `${signedPath.pathname}${signedPath.search}\n`,
        { mode: 0o600 },
      );
    }

    if (process.env.ANALYTICO_INSTALL_DESKTOP_SCREENSHOT) {
      await page.screenshot({
        path: process.env.ANALYTICO_INSTALL_DESKTOP_SCREENSHOT,
        fullPage: true,
      });
    }
    await page.setViewportSize({ width: 360, height: 844 });
    assert.ok(
      await page.evaluate(
        () => document.documentElement.scrollWidth <= window.innerWidth,
      ),
    );
    if (process.env.ANALYTICO_INSTALL_MOBILE_SCREENSHOT) {
      await page.screenshot({
        path: process.env.ANALYTICO_INSTALL_MOBILE_SCREENSHOT,
        fullPage: true,
      });
    }
    const htmlGzipBytes = zlib.gzipSync(await page.content()).length;
    const scriptResponse = await context.request.get(`${dashboard}/admin/install.fe0cc47b.js`);
    assert.equal(scriptResponse.status(), 200);
    const scriptBody = await scriptResponse.body();
    assert.equal(scriptBody.length, 3891);
    assert.ok(zlib.gzipSync(scriptBody).length <= 2048);

    await tracked.close();
    await context.close();
    process.stdout.write(JSON.stringify({
      engine: "chromium",
      old_event_rejected_as_new: true,
      tampered_query_status: 400,
      native_refresh: true,
      v1_compatibility: true,
      v2_tracker_page: true,
      clipboard: ["write", "manual-selection"],
      polling: ["five-seconds", "pause", "hidden", "resume", "stop-success"],
      initial_requests: ["document", "script", "stylesheet"],
      startup_data_requests: 0,
      mobile_width: 360,
      html_gzip_bytes: htmlGzipBytes,
      install_js_raw_bytes: scriptBody.length,
      install_js_gzip_bytes: zlib.gzipSync(scriptBody).length,
    }) + "\n");
  } finally {
    await browser.close();
    await closeFixture();
  }
}

main().catch((error) => {
  process.stderr.write(`${error.stack || error}\n`);
  process.exitCode = 1;
});
