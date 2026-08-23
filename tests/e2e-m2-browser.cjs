"use strict";

const assert = require("node:assert/strict");
const http = require("node:http");
const { chromium, firefox, webkit } = require("playwright");

const collector = process.argv[2];
const site = process.argv[3];
const fixturePort = Number(process.argv[4]);
if (!collector || !site || !Number.isInteger(fixturePort)) {
  throw new Error("usage: node e2e-m2-browser.cjs <collector> <site-id> <fixture-port>");
}

const fixtureOrigin = `http://127.0.0.2:${fixturePort}`;
const html = (javaScriptPath, trackerPath) => `<!doctype html>
<html lang="en">
<meta charset="utf-8">
<title>Analytico browser fixture</title>
<main><h1>Useful server-rendered state</h1><p>${javaScriptPath}</p></main>
<script defer src="${collector}${trackerPath}" data-site="${site}"></script>
<noscript><img alt="" src="${collector}/v1/p.gif?site=${site}&path=%2Fnoscript&utm_source=noscript"></noscript>
</html>`;

const server = http.createServer((request, response) => {
  const requestPath = request.url || "/";
  const trackerPath = requestPath.startsWith("/v2-browser-")
    ? "/tracker.bc506cfe.js"
    : "/tracker.aef65945.js";
  response.writeHead(200, {
    "Content-Type": "text/html; charset=utf-8",
    "Cache-Control": "no-store",
  });
  response.end(html(requestPath, trackerPath));
});

async function listen() {
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(fixturePort, "0.0.0.0", resolve);
  });
}

async function verifyTracker(name, browserType) {
  const browser = await launch(name, browserType);
  try {
    const context = await browser.newContext();
    const page = await context.newPage();
    let eventRequests = 0;
    page.on("request", (request) => {
      if (request.url() === `${collector}/v1/event`) eventRequests += 1;
    });
    const accepted = page.waitForResponse(
      (response) =>
        response.url() === `${collector}/v1/event` &&
        response.status() === 204,
    );
    await page.goto(`${fixtureOrigin}/browser-${name}?utm_source=${name}`, {
      waitUntil: "load",
    });
    await accepted;
    await page.waitForTimeout(100);
    assert.equal(eventRequests, 1, `${name} sent exactly one page view`);
    assert.equal(await page.evaluate(() => localStorage.length), 0);
    assert.equal(await page.evaluate(() => sessionStorage.length), 0);
    assert.deepEqual(await page.evaluate(() => caches.keys()), []);
    assert.deepEqual(
      await page.evaluate(async () =>
        typeof indexedDB.databases === "function"
          ? (await indexedDB.databases()).map((entry) => entry.name)
          : [],
      ),
      [],
    );
    assert.equal(
      await page.evaluate(async () =>
        "serviceWorker" in navigator
          ? (await navigator.serviceWorker.getRegistrations()).length
          : 0,
      ),
      0,
    );
    await context.close();
  } finally {
    await browser.close();
  }
}

async function verifyTrackerV2(name, browserType) {
  const browser = await launch(name, browserType);
  try {
    const context = await browser.newContext();
    const page = await context.newPage();
    let eventRequests = 0;
    page.on("request", (request) => {
      if (request.url() === `${collector}/v2/event`) eventRequests += 1;
    });
    const accepted = page.waitForResponse(
      (response) =>
        response.url() === `${collector}/v2/event` &&
        response.status() === 204,
    );
    await page.goto(`${fixtureOrigin}/v2-browser-${name}?private=${name}`, {
      waitUntil: "load",
    });
    await accepted;
    await page.waitForTimeout(100);
    assert.equal(eventRequests, 1, `${name} v2 sent exactly one page view`);
    assert.equal(await page.evaluate(() => localStorage.length), 2);
    assert.equal(await page.evaluate(() => sessionStorage.length), 0);
    assert.deepEqual(await page.evaluate(() => caches.keys()), []);
    assert.equal(
      await page.evaluate(async () =>
        "serviceWorker" in navigator
          ? (await navigator.serviceWorker.getRegistrations()).length
          : 0,
      ),
      0,
    );
    await context.close();
  } finally {
    await browser.close();
  }
}

async function verifyNoScript(name, browserType) {
  const browser = await launch(name, browserType);
  try {
    const context = await browser.newContext({ javaScriptEnabled: false });
    const page = await context.newPage();
    let postRequests = 0;
    page.on("request", (request) => {
      if (request.url() === `${collector}/v1/event`) postRequests += 1;
    });
    const accepted = page.waitForResponse(
      (response) =>
        response.url().startsWith(`${collector}/v1/p.gif?`) &&
        response.status() === 200,
    );
    await page.goto(`${fixtureOrigin}/noscript-${name}`, {
      waitUntil: "load",
    });
    await accepted;
    assert.equal(postRequests, 0, `${name} used the pixel with JavaScript off`);
    await context.close();
  } finally {
    await browser.close();
  }
}

function launch(name, browserType) {
  const options = { headless: true };
  if (name === "chromium") {
    if (process.env.ANALYTICO_CHROMIUM_PATH) {
      options.executablePath = process.env.ANALYTICO_CHROMIUM_PATH;
    }
    options.args = [
      "--no-sandbox",
      "--ozone-platform=headless",
      "--use-angle=swiftshader-webgl",
    ];
  }
  return browserType.launch(options);
}

async function main() {
  await listen();
  try {
    const engines = [
      ["chromium", chromium],
      ["firefox", firefox],
      ["webkit", webkit],
    ];
    for (const [name, browserType] of engines) {
      await verifyTracker(name, browserType);
      await verifyTrackerV2(name, browserType);
      await verifyNoScript(name, browserType);
    }
    process.stdout.write(
      JSON.stringify({
        engines: engines.map(([name]) => name),
        tracker_pageviews: engines.length,
        v2_tracker_pageviews: engines.length,
        noscript_pageviews: engines.length,
        persistent_storage_entries: 0,
        v2_local_storage_entries_per_site: 2,
      }) + "\n",
    );
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
