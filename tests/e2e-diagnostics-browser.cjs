"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { chromium } = require("playwright");

const origin = process.argv[2];
const sessionToken = process.argv[3];
const liveUrl = process.argv[4];
const control = process.argv[5];
if (!origin || !sessionToken || !liveUrl || !control) {
  throw new Error(
    "usage: node e2e-diagnostics-browser.cjs <origin> <session-token> <live-url> <control-dir>",
  );
}

function marker(name) {
  return path.join(control, name);
}

async function waitForMarker(name) {
  for (let index = 0; index < 500; index += 1) {
    if (fs.existsSync(marker(name))) return;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  throw new Error(`timed out waiting for ${name}`);
}

async function launch() {
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

async function addSession(context) {
  await context.addCookies([{
    name: "analytico_session",
    value: sessionToken,
    url: origin,
    httpOnly: true,
    sameSite: "Lax",
  }]);
}

function isLivePoll(request) {
  const headers = request.headers();
  return headers["hx-request"] === "true" &&
    headers["hx-target"] === "section#live-region";
}

async function jsOffAndMobile(browser) {
  const context = await browser.newContext({
    javaScriptEnabled: false,
    viewport: { width: 390, height: 844 },
  });
  try {
    await addSession(context);
    const page = await context.newPage();
    const requests = [];
    page.on("request", (request) => requests.push(request));
    const response = await page.goto(liveUrl, { waitUntil: "load" });
    assert.equal(response.status(), 200);
    assert.equal(await page.locator("#live-region").count(), 1);
    assert.equal(await page.locator("#report").count(), 1);
    assert.equal(await page.getByRole("link", { name: "Refresh Live" }).count(), 1);
    assert.equal(await page.locator("[data-live-pause]").isHidden(), true);
    assert.equal(requests.filter(isLivePoll).length, 0);
    assert.equal(await page.evaluate(() =>
      document.documentElement.scrollWidth <= document.documentElement.clientWidth
    ), true);
    await page.screenshot({ path: marker("live-mobile-js-off.png"), fullPage: true });
  } finally {
    await context.close();
  }
}

async function enhanced(browser) {
  const context = await browser.newContext({ viewport: { width: 1440, height: 1000 } });
  try {
    await addSession(context);
    const page = await context.newPage();
    const polls = [];
    const startupDataRequests = [];
    page.on("request", (request) => {
      if (isLivePoll(request)) polls.push(request.url());
      if ((request.resourceType() === "fetch" || request.resourceType() === "xhr") &&
          polls.length === 0) startupDataRequests.push(request.url());
    });
    const response = await page.goto(liveUrl, { waitUntil: "load" });
    assert.equal(response.status(), 200);
    await page.waitForFunction(() => window.htmx !== undefined);
    assert.equal(polls.length, 0);
    assert.deepEqual(startupDataRequests, []);
    assert.match(
      await page.locator("[data-live-generated]").getAttribute("datetime"),
      /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/,
    );
    const loadedAt = Date.now();
    await page.waitForTimeout(1_000);
    assert.equal(polls.length, 0);
    const firstPoll = await page.waitForResponse((candidate) =>
      isLivePoll(candidate.request()) && candidate.status() === 200,
      { timeout: 6_000 },
    );
    assert.ok(Date.now() - loadedAt >= 4_500);
    assert.equal(firstPoll.status(), 200);
    assert.equal(polls.length, 1);
    assert.equal(await page.locator("#report").count(), 1);

    const pause = page.locator("[data-live-pause]");
    await pause.focus();
    await page.keyboard.press("Space");
    assert.equal(await pause.getAttribute("aria-pressed"), "true");
    await page.waitForTimeout(5_500);
    assert.equal(polls.length, 1);
    await page.keyboard.press("Space");
    assert.equal(await pause.getAttribute("aria-pressed"), "false");
    await page.waitForResponse((candidate) =>
      isLivePoll(candidate.request()) && candidate.status() === 200,
      { timeout: 6_000 },
    );
    assert.equal(polls.length, 2);
    assert.equal(await page.evaluate(() => document.activeElement?.id), "live-pause");

    await page.evaluate(() => {
      Object.defineProperty(document, "hidden", {
        configurable: true,
        get: () => true,
      });
    });
    await page.waitForTimeout(5_500);
    assert.equal(polls.length, 2);
    await page.evaluate(() => delete document.hidden);
    assert.equal(await page.evaluate(() => document.hidden), false);
    await page.waitForResponse((candidate) =>
      isLivePoll(candidate.request()) && candidate.status() === 200,
      { timeout: 6_000 },
    );
    assert.equal(polls.length, 3);
    await page.screenshot({ path: marker("live-desktop.png"), fullPage: true });

    const generatedBeforeFailure = await page.locator("[data-live-generated]").textContent();
    const metricsBeforeFailure = await page.locator("#live-region .metrics").innerText();
    fs.writeFileSync(marker("ready-for-outage"), "ready\n");
    await waitForMarker("server-stopped");
    await page.waitForRequest(isLivePoll, { timeout: 6_000 });
    await page.waitForFunction(() =>
      document.querySelector("[data-live-client-status]")?.textContent.includes("Update failed")
    );
    const failureState = await page.evaluate(() => ({
      status: document.querySelector("[data-live-client-status]")?.textContent,
      metrics: document.querySelector("#live-region .metrics")?.innerText,
      regionCount: document.querySelectorAll("#live-region").length,
      reportCount: document.querySelectorAll("#report").length,
      url: location.href,
    }));
    fs.writeFileSync(
      marker("live-outage.html"),
      await page.content(),
    );
    assert.match(failureState.status, /Update failed; showing snapshot from/);
    assert.ok(failureState.status.includes(generatedBeforeFailure));
    assert.equal(failureState.metrics, metricsBeforeFailure);
    assert.equal(failureState.regionCount, 1);
    assert.equal(failureState.reportCount, 1);
    assert.equal(failureState.url, liveUrl);
    await pause.focus();
    await page.keyboard.press("Space");
    assert.ok((await page.locator("[data-live-client-status]").innerText())
      .includes(generatedBeforeFailure));
    await page.keyboard.press("Space");
    assert.ok((await page.locator("[data-live-client-status]").innerText())
      .includes(generatedBeforeFailure));
    fs.writeFileSync(marker("failure-observed"), "failed\n");

    await waitForMarker("server-restarted");
    await page.waitForResponse((candidate) =>
      isLivePoll(candidate.request()) && candidate.status() === 200,
      { timeout: 6_000 },
    );
    await page.waitForFunction(() =>
      document.querySelector("[data-live-client-status]")?.textContent.startsWith("Updated ") &&
      [...document.querySelectorAll("#live-region dt")].some((node) =>
        node.textContent === "Selected-site retained" &&
        node.nextElementSibling?.textContent === "0"
      )
    );
    assert.equal(await page.locator("#report").count(), 1);
    fs.writeFileSync(marker("recovery-observed"), "recovered\n");
  } finally {
    await context.close();
  }
}

(async () => {
  const browser = await launch();
  try {
    await jsOffAndMobile(browser);
    await enhanced(browser);
    console.log(JSON.stringify({
      live_browser: "pass",
      js_off: true,
      mobile_width: 390,
      initial_poll_delay_ms: 5000,
      pause: "keyboard",
      hidden: "document.hidden branch in pinned headless Chromium",
      hidden_platform_limit: "headless foreground pages do not enter a native hidden state",
      failure: "real server outage",
      recovery: "real restarted process",
    }));
  } finally {
    await browser.close();
  }
})().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
