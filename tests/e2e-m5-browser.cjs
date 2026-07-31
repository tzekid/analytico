"use strict";

const assert = require("node:assert/strict");
const http = require("node:http");
const { chromium } = require("playwright");

const collector = process.argv[2];
const site = process.argv[3];
const fixturePort = Number(process.argv[4]);
if (!collector || !site || !Number.isInteger(fixturePort)) {
  throw new Error(
    "usage: node e2e-m5-browser.cjs <collector-origin> <site-id> <fixture-port>",
  );
}

const fixtureOrigin = `http://127.0.0.1:${fixturePort}`;
const csp = [
  "default-src 'self'",
  `script-src 'self' ${collector}`,
  `connect-src 'self' ${collector}`,
  `img-src 'self' data: ${collector}`,
  "style-src 'self'",
  "base-uri 'none'",
  "form-action 'self'",
].join("; ");

function html(path) {
  return `<!doctype html>
<html lang="en">
<meta charset="utf-8">
<title>Analytico cutover fixture</title>
<main><h1>Useful server-rendered ${path}</h1></main>
<script defer src="${collector}/tracker.aef65945.js" data-site="${site}"></script>
<noscript>
  <img alt="" width="1" height="1" src="${collector}/v1/p.gif?site=${site}&amp;path=%2F">
</noscript>
</html>`;
}

const server = http.createServer((request, response) => {
  response.writeHead(200, {
    "Content-Type": "text/html; charset=utf-8",
    "Content-Security-Policy": csp,
    "Cache-Control": "no-store",
  });
  response.end(html(new URL(request.url || "/", fixtureOrigin).pathname));
});

async function main() {
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(fixturePort, "127.0.0.1", resolve);
  });
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
  const browser = await chromium.launch(options);
  try {
    const context = await browser.newContext();
    const page = await context.newPage();
    const failures = [];
    page.on("console", (message) => {
      if (message.type() === "error") failures.push(message.text());
    });

    let accepted = page.waitForResponse(
      (response) =>
        response.url() === `${collector}/v1/event` &&
        response.status() === 204,
    );
    await page.goto(
      `${fixtureOrigin}/landing?utm_source=newsletter&utm_medium=email&utm_campaign=cutover`,
      {
        waitUntil: "load",
        referer: "https://search.example/results?q=private",
      },
    );
    await accepted;

    accepted = page.waitForResponse(
      (response) =>
        response.url() === `${collector}/v1/event` &&
        response.status() === 204,
    );
    await page.goto(`${fixtureOrigin}/pricing`, { waitUntil: "load" });
    await accepted;

    accepted = page.waitForResponse(
      (response) =>
        response.url() === `${collector}/v1/event` &&
        response.status() === 204,
    );
    await page.evaluate(() => window.analytico.event("signup", { plan: "basic" }));
    await accepted;
    await page.waitForTimeout(100);

    assert.deepEqual(failures, []);
    assert.equal(await page.evaluate(() => localStorage.length), 0);
    assert.equal(await page.evaluate(() => sessionStorage.length), 0);
    await context.close();
  } finally {
    await browser.close();
    await new Promise((resolve) => server.close(resolve));
  }
  process.stdout.write(
    JSON.stringify({
      engine: "chromium",
      accepted_events: 3,
      csp: "enforced",
      persistent_storage_entries: 0,
    }) + "\n",
  );
}

main().catch(async (error) => {
  console.error(error);
  await new Promise((resolve) => server.close(resolve));
  process.exitCode = 1;
});
