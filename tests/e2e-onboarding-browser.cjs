"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const zlib = require("node:zlib");
const { chromium } = require("playwright");

const origin = process.argv[2];
const setupUrl = process.argv[3];
const serverPid = process.argv[4];
const eventPath = process.argv[5];
if (!origin || !setupUrl || !serverPid || !eventPath) {
  throw new Error(
    "usage: node e2e-onboarding-browser.cjs " +
      "<origin> <setup-url> <server-pid> <event-path>",
  );
}

function rssKiB() {
  const status = fs.readFileSync(`/proc/${serverPid}/status`, "utf8");
  const match = status.match(/^VmRSS:\s+(\d+)\s+kB$/m);
  assert.ok(match);
  return Number(match[1]);
}

async function main() {
  const eventPathAway = `${eventPath}.away`;
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
    const setupContext = await browser.newContext();
    const setupPage = await setupContext.newPage();
    const cdp = await setupContext.newCDPSession(setupPage);
    await cdp.send("WebAuthn.enable");
    await cdp.send("WebAuthn.addVirtualAuthenticator", {
      options: {
        protocol: "ctap2",
        transport: "internal",
        hasResidentKey: true,
        hasUserVerification: true,
        isUserVerified: true,
        automaticPresenceSimulation: true,
      },
    });
    let response = await setupPage.goto(setupUrl, { waitUntil: "load" });
    assert.equal(response.status(), 200);
    await setupPage.locator("#passkey-label").fill("Onboarding fixture passkey");
    await setupPage.locator("#setup-button").click();
    await setupPage.waitForURL(`${origin}/admin`, { timeout: 15000 });
    assert.equal(
      await setupPage.getByRole("heading", {
        name: "Turn visits into useful answers",
      }).count(),
      1,
    );
    const session = (await setupContext.cookies(origin)).find(
      (cookie) => cookie.name === "analytico_session",
    );
    assert.ok(session);

    const context = await browser.newContext({
      javaScriptEnabled: false,
      colorScheme: "light",
    });
    await context.addCookies([session]);
    const page = await context.newPage();
    await page.setViewportSize({ width: 360, height: 800 });
    const firstRequests = [];
    page.on("request", (request) => firstRequests.push(request.resourceType()));
    response = await page.goto(`${origin}/admin`, { waitUntil: "load" });
    assert.equal(response.status(), 200);
    assert.equal(await page.locator("script").count(), 0);
    assert.equal(await page.locator(".primary-navigation").count(), 0);
    assert.equal(await page.getByText("Ready · schema 10").count(), 1);
    assert.equal(await page.getByText("Ready · schema 7").count(), 1);
    assert.deepEqual([...new Set(firstRequests)].sort(), ["document", "stylesheet"]);
    assert.equal(firstRequests.filter((kind) => kind === "fetch").length, 0);
    assert.equal(firstRequests.filter((kind) => kind === "xhr").length, 0);
    fs.renameSync(eventPath, eventPathAway);
    try {
      response = await page.reload({ waitUntil: "load" });
      assert.equal(response.status(), 200);
      assert.equal(await page.getByText(/Check readiness/).count(), 2);
      assert.equal(await page.getByText(/Collection unavailable/).count(), 1);
      assert.equal(await page.getByText(/Ready/).count(), 0);
    } finally {
      fs.renameSync(eventPathAway, eventPath);
    }
    response = await page.reload({ waitUntil: "load" });
    assert.equal(response.status(), 200);
    assert.equal(await page.getByText("Ready · schema 10").count(), 1);
    assert.equal(await page.getByText("Ready · schema 7").count(), 1);
    assert.ok(
      await page.evaluate(
        () => document.documentElement.scrollWidth <= window.innerWidth,
      ),
    );
    await page.keyboard.press("Tab");
    assert.equal(await page.evaluate(() => document.activeElement?.textContent), "Skip to main content");
    await page.keyboard.press("Enter");
    assert.equal(await page.evaluate(() => document.activeElement?.id), "main");
    if (process.env.ANALYTICO_ONBOARDING_MOBILE_SCREENSHOT) {
      await page.screenshot({
        path: process.env.ANALYTICO_ONBOARDING_MOBILE_SCREENSHOT,
        fullPage: true,
      });
    }

    const htmlBytes = zlib.gzipSync(await page.content()).length;
    const stylesheetPath = await page.locator('link[rel="stylesheet"]').getAttribute("href");
    const stylesheetResponse = await context.request.get(`${origin}${stylesheetPath}`);
    assert.equal(stylesheetResponse.status(), 200);
    const cssBytes = zlib.gzipSync(await stylesheetResponse.body()).length;
    assert.ok(htmlBytes <= 32768);
    assert.ok(cssBytes <= 12288);

    await page.getByRole("link", { name: "Create site" }).click();
    await page.waitForURL(`${origin}/admin/sites/new`);
    assert.equal(await page.locator("script").count(), 0);
    assert.equal(
      await page.locator("input:not([type=hidden]), button, a.button").evaluateAll((elements) =>
        elements.every((element) => element.getBoundingClientRect().height >= 44),
      ),
      true,
    );
    await page.setViewportSize({ width: 1280, height: 900 });
    if (process.env.ANALYTICO_ONBOARDING_DESKTOP_SCREENSHOT) {
      await page.screenshot({
        path: process.env.ANALYTICO_ONBOARDING_DESKTOP_SCREENSHOT,
        fullPage: true,
      });
    }
    await page.locator('#site-name').fill("Browser Site");
    await page.locator('#site-origin').fill("http://example.com");
    await page.locator('#site-timezone').fill("Missing/Zone");
    await page.locator('#site-currency').fill("EUR");
    response = await Promise.all([
      page.waitForNavigation(),
      page.getByRole("button", { name: "Create site" }).click(),
    ]).then(([navigation]) => navigation);
    assert.equal(response.status(), 422);
    assert.equal(await page.evaluate(() => document.activeElement?.id), "site-form-errors");
    assert.equal(await page.locator('#site-name').inputValue(), "Browser Site");
    assert.equal(await page.locator('#site-slug').inputValue(), "");
    assert.equal(await page.locator('#site-origin').inputValue(), "http://example.com");
    assert.equal(await page.locator('#site-timezone').inputValue(), "Missing/Zone");
    assert.equal(await page.locator('#site-currency').inputValue(), "EUR");
    assert.equal(await page.locator('#site-origin').getAttribute("aria-invalid"), "true");
    assert.equal(await page.locator('#site-timezone').getAttribute("aria-invalid"), "true");

    await page.locator('#site-origin').fill("https://browser.example");
    await page.locator('#site-timezone').fill("Europe/Berlin");
    const csrf = await page.locator('input[name="csrf"]').inputValue();
    let modifyingOrigin = "";
    page.on("request", async (request) => {
      if (request.url() === `${origin}/admin/sites` && request.method() === "POST") {
        modifyingOrigin = (await request.allHeaders()).origin || "";
      }
    });
    await Promise.all([
      page.waitForURL((url) =>
        url.origin === origin &&
        url.pathname === "/admin/sites/browser-site/install" &&
        url.searchParams.has("started") &&
        url.searchParams.has("sig")
      ),
      page.getByRole("button", { name: "Create site" }).click(),
    ]);
    assert.equal(modifyingOrigin, origin);
    assert.equal(await page.getByRole("heading", { name: "Install tracker" }).count(), 1);
    assert.equal(
      await page.getByText(
        "The site is stored and its collection policy is active without a restart.",
        { exact: true },
      ).count(),
      1,
    );
    assert.equal(await page.getByText("Browser Site", { exact: true }).count(), 1);
    assert.equal(await page.getByText("Europe/Berlin", { exact: true }).count(), 1);
    assert.equal(await page.getByText("EUR", { exact: true }).count(), 1);
    assert.equal(
      await page.locator('script[src^="/admin/install."]').count(),
      1,
    );
    const siteId = await page.locator(".configuration-list code").first().textContent();
    assert.match(siteId, /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);

    const exact = new URLSearchParams({
      csrf,
      name: "Browser Site",
      slug: "browser-site",
      origin: "https://browser.example",
      timezone: "Europe/Berlin",
      currency: "EUR",
    });
    response = await context.request.post(`${origin}/admin/sites`, {
      headers: {
        "Content-Type": "application/x-www-form-urlencoded",
        Origin: origin,
      },
      data: exact.toString(),
      maxRedirects: 0,
    });
    assert.equal(response.status(), 303);
    assert.equal(response.headers().location, "/admin/sites/browser-site/install");

    async function expectFieldConflict(fields, text) {
      const body = new URLSearchParams({
        csrf,
        name: "Browser Site",
        slug: "browser-site",
        origin: "https://browser.example",
        timezone: "Europe/Berlin",
        currency: "EUR",
        ...fields,
      });
      const conflict = await context.request.post(`${origin}/admin/sites`, {
        headers: {
          "Content-Type": "application/x-www-form-urlencoded",
          Origin: origin,
        },
        data: body.toString(),
      });
      assert.equal(conflict.status(), 422);
      const conflictBody = await conflict.text();
      assert.ok(conflictBody.includes(text), conflictBody);
    }
    await expectFieldConflict(
      { origin: "https://changed.example" },
      "That exact origin already belongs to another site or outcome.",
    );
    await expectFieldConflict(
      { timezone: "UTC" },
      "That site already has a different reporting timezone.",
    );
    await expectFieldConflict(
      { currency: "USD" },
      "That site already has a different default currency.",
    );
    await expectFieldConflict(
      { name: "Different Site" },
      "That slug already belongs to a different site configuration.",
    );
    await expectFieldConflict(
      { name: "Other Site", slug: "other-site" },
      "That exact origin already belongs to another site or outcome.",
    );

    const crossOrigin = await context.request.post(`${origin}/admin/sites`, {
      headers: {
        "Content-Type": "application/x-www-form-urlencoded",
        Origin: "https://attacker.example",
      },
      data: exact.toString(),
    });
    assert.equal(crossOrigin.status(), 403);
    const staleCsrf = new URLSearchParams(exact);
    staleCsrf.set("csrf", "stale");
    const rejectedCsrf = await context.request.post(`${origin}/admin/sites`, {
      headers: {
        "Content-Type": "application/x-www-form-urlencoded",
        Origin: origin,
      },
      data: staleCsrf.toString(),
    });
    assert.equal(rejectedCsrf.status(), 403);

    response = await page.goto(`${origin}/admin/sites/browser-site/overview`, {
      waitUntil: "load",
    });
    assert.equal(response.status(), 200);
    assert.equal(await page.locator('a[href="/admin/sites/new"]').count(), 2);
    for (let index = 0; index < 10; index += 1) {
      const warmup = await context.request.get(
        `${origin}/admin/sites/browser-site/install`,
      );
      assert.equal(warmup.status(), 200);
    }
    const rssBefore = rssKiB();
    for (let index = 0; index < 100; index += 1) {
      const view = await context.request.get(
        `${origin}/admin/sites/browser-site/install`,
      );
      assert.equal(view.status(), 200);
    }
    const rssGrowthKiB = rssKiB() - rssBefore;
    assert.ok(rssGrowthKiB <= 8192);

    fs.renameSync(eventPath, eventPathAway);
    try {
      const unavailable = await context.request.get(
        `${origin}/admin/sites/browser-site/install`,
      );
      assert.equal(unavailable.status(), 200);
      assert.ok(
        (await unavailable.text()).includes(
          "Collection unavailable:</strong> collector storage is not ready",
        ),
      );
    } finally {
      fs.renameSync(eventPathAway, eventPath);
    }

    const anonymous = await browser.newContext({ javaScriptEnabled: false });
    const anonymousPage = await anonymous.newPage();
    await anonymousPage.goto(`${origin}/admin/sites/browser-site/install`);
    assert.equal(new URL(anonymousPage.url()).pathname, "/admin/login");
    assert.equal((await anonymousPage.locator("body").innerText()).includes(siteId), false);
    await anonymous.close();

    await context.close();
    await setupContext.close();
    process.stdout.write(
      JSON.stringify({
        engine: "chromium",
        passkey_bootstrap: "real-virtual-authenticator",
        site_creation_javascript: "disabled",
        metadata_schema: 10,
        event_schema: 7,
        site_id: siteId,
        exact_retry: "existing-outcome",
        unavailable_store_honest: true,
        conflict_fields: ["slug", "origin", "timezone", "currency"],
        initial_requests: ["document", "stylesheet"],
        startup_data_requests: 0,
        mobile_width: 360,
        html_gzip_bytes: htmlBytes,
        css_gzip_bytes: cssBytes,
        warm_100_view_rss_growth_kib: rssGrowthKiB,
        keyboard_skip: "main",
        security: ["passkey", "csrf", "exact-origin"],
      }) + "\n",
    );
  } finally {
    await browser.close();
  }
}

main().catch((error) => {
  process.stderr.write(`${error.stack || error}\n`);
  process.exitCode = 1;
});
