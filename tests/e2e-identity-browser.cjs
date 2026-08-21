"use strict";

const assert = require("node:assert/strict");
const http = require("node:http");
const { chromium } = require("playwright");

const collector = process.argv[2];
const siteA = process.argv[3];
const siteB = process.argv[4];
const fixturePort = Number(process.argv[5]);
if (!collector || !siteA || !siteB || !Number.isInteger(fixturePort)) {
  throw new Error(
    "usage: node e2e-identity-browser.cjs <collector> <site-a> <site-b> <fixture-port>",
  );
}

const UUID =
  /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const fixtureOrigin = `http://127.0.0.1:${fixturePort}`;

function html(site) {
  return `<!doctype html>
<html lang="en">
<meta charset="utf-8">
<title>Analytico identity fixture</title>
<main><h1>Useful server-rendered state</h1><p>${site}</p></main>
<script defer src="${collector}/tracker.78135195.js" data-site="${site}"></script>
</html>`;
}

const server = http.createServer((request, response) => {
  const site = (request.url || "").startsWith("/b") ? siteB : siteA;
  response.writeHead(200, {
    "Content-Type": "text/html; charset=utf-8",
    "Cache-Control": "no-store",
  });
  response.end(html(site));
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
  const raw = request.postData() ||
    (request.postDataBuffer() && request.postDataBuffer().toString("utf8"));
  assert.ok(raw, "v2 event body present");
  return JSON.parse(raw);
}

function nextV2(page) {
  return Promise.all([
    page.waitForRequest(
      (request) =>
        request.url() === `${collector}/v2/event` && request.method() === "POST",
    ),
    page.waitForResponse(
      (response) =>
        response.url() === `${collector}/v2/event` && response.status() === 204,
    ),
  ]).then(([request]) => eventBody(request));
}

function assertUuid(value, label) {
  assert.match(value, UUID, `${label} is a UUID v4`);
}

async function storageKeys(page, site) {
  return page.evaluate((id) => {
    const prefix = `anl:${id}`;
    const raw = localStorage.getItem(`${prefix}:s`);
    let session = null;
    let sequence = null;
    let lastActivity = null;
    if (raw) {
      const parsed = JSON.parse(raw);
      session = parsed.id;
      sequence = parsed.sequence;
      lastActivity = parsed.last_activity_ms;
    }
    return {
      anonymous: localStorage.getItem(`${prefix}:a`),
      session,
      sequence,
      lastActivity,
      identified: localStorage.getItem(`${prefix}:u`),
      keys: Object.keys(localStorage).sort(),
    };
  }, site);
}

async function verifyPersistenceAndReset() {
  const browser = await launch();
  try {
    const context = await browser.newContext();
    const page = await context.newPage();
    let accepted = nextV2(page);
    await page.goto(`${fixtureOrigin}/a`, { waitUntil: "load" });
    const first = await accepted;
    assert.equal(first.v, 2);
    assert.equal(first.site, siteA);
    assert.equal(first.type, "pageview");
    assert.equal(first.identity_quality, "persistent");
    assertUuid(first.anonymous_id, "anonymous_id");
    assertUuid(first.session_id, "session_id");
    assert.equal(first.sequence, 0);
    const stored = await storageKeys(page, siteA);
    assert.equal(stored.anonymous, first.anonymous_id);
    assert.equal(stored.session, first.session_id);
    assert.equal(stored.sequence, 1);
    assert.equal(stored.identified, null);
    assert.deepEqual(stored.keys, [`anl:${siteA}:a`, `anl:${siteA}:s`]);
    assert.equal(await page.evaluate(() => document.cookie), "");
    assert.equal(
      await page.locator("h1").textContent(),
      "Useful server-rendered state",
    );

    accepted = nextV2(page);
    await page.reload({ waitUntil: "load" });
    const reloaded = await accepted;
    assert.equal(reloaded.anonymous_id, first.anonymous_id);
    assert.equal(reloaded.session_id, first.session_id);
    assert.equal(reloaded.sequence, 1);
    assert.equal(reloaded.identity_quality, "persistent");
    assert.notEqual(reloaded.event_id, first.event_id);

    const state = await context.storageState();
    await context.close();
    await browser.close();

    const restoredBrowser = await launch();
    try {
      const restoredContext = await restoredBrowser.newContext({
        storageState: state,
      });
      const restoredPage = await restoredContext.newPage();
      accepted = nextV2(restoredPage);
      await restoredPage.goto(`${fixtureOrigin}/a?day=2`, { waitUntil: "load" });
      const nextDay = await accepted;
      assert.equal(nextDay.anonymous_id, first.anonymous_id);
      assert.equal(nextDay.session_id, first.session_id);
      assert.equal(nextDay.identity_quality, "persistent");

      await restoredPage.evaluate(
        (key) => localStorage.setItem(key, "prior-user"),
        `anl:${siteA}:u`,
      );
      await restoredPage.evaluate(() => window.analytico.reset());
      const afterReset = await storageKeys(restoredPage, siteA);
      assertUuid(afterReset.anonymous, "reset anonymous");
      assertUuid(afterReset.session, "reset session");
      assert.notEqual(afterReset.anonymous, first.anonymous_id);
      assert.notEqual(afterReset.session, first.session_id);
      assert.equal(afterReset.sequence, 0);
      assert.equal(afterReset.identified, null);
      assert.deepEqual(afterReset.keys, [`anl:${siteA}:a`, `anl:${siteA}:s`]);

      accepted = nextV2(restoredPage);
      await restoredPage.evaluate(() => window.analytico.track("after-reset"));
      const tracked = await accepted;
      assert.equal(tracked.type, "event");
      assert.equal(tracked.name, "after-reset");
      assert.equal(tracked.anonymous_id, afterReset.anonymous);
      assert.equal(tracked.session_id, afterReset.session);
      assert.equal(tracked.sequence, 0);
      assert.equal(tracked.identity_quality, "persistent");

      accepted = nextV2(restoredPage);
      await restoredPage.goto(`${fixtureOrigin}/b`, { waitUntil: "load" });
      const otherSite = await accepted;
      assert.equal(otherSite.site, siteB);
      assert.equal(otherSite.identity_quality, "persistent");
      assert.notEqual(otherSite.anonymous_id, afterReset.anonymous);
      const both = await restoredPage.evaluate(
        ([a, b]) => ({
          a: [`anl:${a}:a`, `anl:${a}:s`],
          b: [`anl:${b}:a`, `anl:${b}:s`],
          keys: Object.keys(localStorage).sort(),
        }),
        [siteA, siteB],
      );
      assert.deepEqual(both.keys, [...both.a, ...both.b].sort());
      await restoredContext.close();
    } finally {
      await restoredBrowser.close();
    }
  } catch (error) {
    await browser.close().catch(() => {});
    throw error;
  }
}

async function verifySessionRotation() {
  const browser = await launch();
  try {
    const context = await browser.newContext();
    const page = await context.newPage();
    let accepted = nextV2(page);
    await page.goto(`${fixtureOrigin}/a-session`, { waitUntil: "load" });
    const first = await accepted;
    assert.equal(first.sequence, 0);
    const initial = await storageKeys(page, siteA);

    await page.evaluate(
      ({ key, last }) => {
        const parsed = JSON.parse(localStorage.getItem(key));
        parsed.last_activity_ms = last;
        localStorage.setItem(key, JSON.stringify(parsed));
      },
      { key: `anl:${siteA}:s`, last: Date.now() - 29 * 60 * 1000 },
    );
    accepted = nextV2(page);
    await page.reload({ waitUntil: "load" });
    const atThreshold = await accepted;
    assert.equal(atThreshold.session_id, first.session_id);
    assert.equal(atThreshold.anonymous_id, first.anonymous_id);

    await page.evaluate(
      ({ key, last }) => {
        const parsed = JSON.parse(localStorage.getItem(key));
        parsed.last_activity_ms = last;
        localStorage.setItem(key, JSON.stringify(parsed));
      },
      { key: `anl:${siteA}:s`, last: Date.now() - 31 * 60 * 1000 },
    );
    accepted = nextV2(page);
    await page.reload({ waitUntil: "load" });
    const rotated = await accepted;
    assert.equal(rotated.anonymous_id, first.anonymous_id);
    assert.notEqual(rotated.session_id, first.session_id);
    assert.equal(rotated.sequence, 0);

    const midnight = Math.floor(Date.now() / 86400000) * 86400000;
    const beforeMidnight = midnight - 10 * 60 * 1000;
    const afterMidnight = midnight + 10 * 60 * 1000;
    const midnightContext = await browser.newContext();
    await midnightContext.addInitScript(
      ({ anonymousKey, sessionKey, anonymous, record, frozen }) => {
        Object.defineProperty(Date, "now", { value: () => frozen });
        localStorage.setItem(anonymousKey, anonymous);
        localStorage.setItem(sessionKey, JSON.stringify(record));
      },
      {
        anonymousKey: `anl:${siteA}:a`,
        sessionKey: `anl:${siteA}:s`,
        anonymous: first.anonymous_id,
        record: {
          id: rotated.session_id,
          last_activity_ms: beforeMidnight,
          sequence: 1,
        },
        frozen: afterMidnight,
      },
    );
    const midnightPage = await midnightContext.newPage();
    accepted = nextV2(midnightPage);
    await midnightPage.goto(`${fixtureOrigin}/a-midnight`, { waitUntil: "load" });
    const crossedMidnight = await accepted;
    assert.equal(crossedMidnight.anonymous_id, first.anonymous_id);
    assert.equal(crossedMidnight.session_id, rotated.session_id);
    assert.equal(crossedMidnight.occurred_at_ms, afterMidnight);
    assert.equal(initial.session, first.session_id);
    await midnightContext.close();
    await context.close();
  } finally {
    await browser.close();
  }
}

async function verifyStorageException() {
  const browser = await launch();
  try {
    const context = await browser.newContext();
    await context.addInitScript(() => {
      Object.defineProperty(window, "localStorage", {
        get() {
          throw new Error("blocked");
        },
      });
    });
    const page = await context.newPage();
    const accepted = nextV2(page);
    await page.goto(`${fixtureOrigin}/a-ephemeral`, { waitUntil: "load" });
    const event = await accepted;
    assert.equal(event.identity_quality, "ephemeral");
    assertUuid(event.anonymous_id, "ephemeral anonymous");
    assertUuid(event.session_id, "ephemeral session");
    assert.equal(
      await page.locator("h1").textContent(),
      "Useful server-rendered state",
    );
    assert.equal(
      await page.evaluate(() => typeof window.analytico.reset),
      "function",
    );
    await context.close();
  } finally {
    await browser.close();
  }
}

async function verifyRandomValuesFallback() {
  const browser = await launch();
  try {
    const context = await browser.newContext();
    await context.addInitScript(() => {
      Object.defineProperty(crypto, "randomUUID", { value: undefined });
    });
    const page = await context.newPage();
    const accepted = nextV2(page);
    await page.goto(`${fixtureOrigin}/a-fallback`, { waitUntil: "load" });
    const event = await accepted;
    assert.equal(event.identity_quality, "persistent");
    assertUuid(event.anonymous_id, "fallback anonymous");
    assertUuid(event.session_id, "fallback session");
    await context.close();
  } finally {
    await browser.close();
  }
}

async function main() {
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(fixturePort, "127.0.0.1", resolve);
  });
  try {
    await verifyPersistenceAndReset();
    await verifySessionRotation();
    await verifyStorageException();
    await verifyRandomValuesFallback();
    process.stdout.write(
      JSON.stringify({
        engine: "chromium",
        persistent_anonymous_after_reload: true,
        persistent_anonymous_after_storage_restore: true,
        storage_exception_ephemeral: true,
        storage_exception_host_survived: true,
        reset_new_anonymous_and_session: true,
        reset_cleared_identified_key: true,
        distinct_site_keys: true,
        uuid_getRandomValues_fallback: true,
        session_reused_at_30_minutes: true,
        session_rotates_after_30_minutes: true,
        session_survives_utc_midnight: true,
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
