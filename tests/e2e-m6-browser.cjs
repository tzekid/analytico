"use strict";

const assert = require("node:assert/strict");
const { chromium } = require("playwright");

const origin = process.argv[2];
const sessionToken = process.argv[3];
if (!origin || !sessionToken) {
  throw new Error(
    "usage: node e2e-m6-browser.cjs <dashboard-origin> <session-token>",
  );
}

const range =
  "site=example&start=2025-01-01&end=2025-01-02";

async function main() {
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
    const context = await browser.newContext({
      javaScriptEnabled: false,
    });
    await context.addCookies([{
      name: "analytico_session",
      value: sessionToken,
      url: origin,
      httpOnly: true,
      sameSite: "Strict",
    }]);
    const page = await context.newPage();
    await page.setViewportSize({ width: 360, height: 640 });
    const cdp = await context.newCDPSession(page);
    await cdp.send("Network.enable");
    await cdp.send("Network.emulateNetworkConditions", {
      offline: false,
      latency: 180,
      downloadThroughput: 64 * 1024,
      uploadThroughput: 32 * 1024,
      connectionType: "cellular3g",
    });
    const firstViewRequests = [];
    let modifyingOrigin = "";
    page.on("request", (request) => firstViewRequests.push(request.resourceType()));
    page.on("request", (request) => {
      if (
        request.method() === "POST" &&
        request.url().startsWith(`${origin}/admin/`)
      ) {
        modifyingOrigin = request.headers().origin || "";
      }
    });
    const failures = [];
    page.on("console", (message) => {
      if (message.type() === "error") failures.push(message.text());
    });

    let response = await page.goto(
      `${origin}/admin?${range}&report=overview`,
      { waitUntil: "load" },
    );
    assert.equal(response.status(), 200);
    assert.equal(await page.locator("h1").textContent(), "Analytico");
    await assertMetric(page, "Page views", "8");
    await assertMetric(page, "Daily visitors", "4");
    await assertMetric(page, "Sessions", "5");
    await assertMetric(page, "Custom events", "5");
    assert.deepEqual(
      [...new Set(firstViewRequests)].sort(),
      ["document", "stylesheet"],
    );
    assert.equal(firstViewRequests.filter((kind) => kind === "script").length, 0);
    assert.equal(firstViewRequests.filter((kind) => kind === "fetch").length, 0);
    assert.equal(firstViewRequests.filter((kind) => kind === "xhr").length, 0);
    assert.equal(await page.locator("script").count(), 2);
    assert.equal(await page.evaluate(() => typeof window.htmx), "undefined");
    assert.equal(await page.evaluate(() => localStorage.length), 0);
    assert.equal(await page.evaluate(() => sessionStorage.length), 0);
    assert.deepEqual(failures, []);
    await cdp.send("Network.emulateNetworkConditions", {
      offline: false,
      latency: 0,
      downloadThroughput: -1,
      uploadThroughput: -1,
      connectionType: "none",
    });
    if (process.env.ANALYTICO_SCREENSHOT_PATH) {
      await page.setViewportSize({ width: 1440, height: 900 });
      await page.screenshot({
        path: process.env.ANALYTICO_SCREENSHOT_PATH,
        fullPage: true,
      });
    }

    const siteForm = page.locator("form.site-switcher");
    await siteForm.locator('select[name="site"]').selectOption("second");
    response = await Promise.all([
      page.waitForNavigation({ waitUntil: "load" }),
      siteForm.getByRole("button", { name: "View site" }).click(),
    ]).then(([navigation]) => navigation);
    assert.equal(response.status(), 200);
    assert.match(page.url(), /site=second/);
    assert.equal(
      await page.locator('select[name="site"]').inputValue(),
      "second",
    );
    await assertMetric(page, "Page views", "2");
    await page.getByRole("link", { name: "Pages", exact: true }).click();
    assert.match(page.url(), /site=second/);
    assert.match(page.url(), /report=pages/);
    const rangeForm = page.locator("form.range-filter");
    await rangeForm.locator('input[name="start"]').fill("2025-01-02");
    response = await Promise.all([
      page.waitForNavigation({ waitUntil: "load" }),
      rangeForm.getByRole("button", { name: "Update dates" }).click(),
    ]).then(([navigation]) => navigation);
    assert.equal(response.status(), 200);
    assert.match(page.url(), /site=second/);
    assert.match(page.url(), /start=2025-01-02/);
    assert.match(page.url(), /report=pages/);

    await page.goto(
      `${origin}/admin?${range}&report=goal&subject=Signup`,
      { waitUntil: "load" },
    );
    await page
      .locator("form.site-switcher select[name=site]")
      .selectOption("second");
    response = await Promise.all([
      page.waitForNavigation({ waitUntil: "load" }),
      page
        .locator("form.site-switcher")
        .getByRole("button", { name: "View site" })
        .click(),
    ]).then(([navigation]) => navigation);
    assert.equal(response.status(), 200);
    assert.match(page.url(), /site=second/);
    assert.doesNotMatch(page.url(), /subject=/);
    assert.equal(
      await page.locator('a[aria-current="page"]').textContent(),
      "Overview",
    );

    await page
      .locator("form.site-switcher select[name=site]")
      .selectOption("example");
    await Promise.all([
      page.waitForNavigation({ waitUntil: "load" }),
      page
        .locator("form.site-switcher")
        .getByRole("button", { name: "View site" })
        .click(),
    ]);
    await assertMetric(page, "Page views", "8");

    const reports = [
      "pages",
      "entries",
      "exits",
      "sources",
      "campaigns&campaign=source",
      "countries",
      "browsers",
      "operating-systems",
      "devices",
      "events",
      "goal&subject=Signup",
      "funnel&subject=Journey",
    ];
    for (const report of reports) {
      response = await page.goto(
        `${origin}/admin?${range}&report=${report}`,
        { waitUntil: "load" },
      );
      assert.equal(response.status(), 200, report);
      assert.equal(await page.locator("#report").count(), 1, report);
    }

    response = await page.goto(
      `${origin}/admin?${range}&report=pages&sort=count&limit=1&page=1`,
      { waitUntil: "load" },
    );
    assert.equal(response.status(), 200);
    assert.equal(await page.locator("tbody tr").count(), 1);
    const next = page.locator('a[rel="next"]');
    assert.equal(await next.count(), 1);
    response = await Promise.all([
      page.waitForNavigation({ waitUntil: "load" }),
      next.click(),
    ]).then(([navigation]) => navigation);
    assert.equal(response.status(), 200);
    assert.match(page.url(), /page=2/);

    await page.goto(`${origin}/admin?${range}&report=overview`, {
      waitUntil: "load",
    });
    const unsafeText = "<script>alert(1)</script> \"&";
    assert.equal(await page.locator("script").count(), 2);
    assert.match(
      await page.locator("script").first().getAttribute("src"),
      /\/admin\/htmx\.[a-f0-9]+\.js$/,
    );
    assert.ok((await page.locator("body").innerText()).includes(unsafeText));

    await page.locator("details.management > summary").click();
    const goalForm = page.locator('form[action="/admin/goals"]');
    await goalForm.locator('input[name="name"]').fill("kept goal");
    await goalForm.locator('select[name="kind"]').selectOption("event");
    await goalForm.locator('input[name="value"]').fill("bad value");
    response = await Promise.all([
      page.waitForResponse(
        (candidate) =>
          candidate.url() === `${origin}/admin/goals` &&
          candidate.request().method() === "POST",
      ),
      goalForm.locator('button[type="submit"]').click(),
    ]).then(([post]) => post);
    assert.equal(
      response.status(),
      422,
      `${await page.locator("body").innerText()}\norigin=${modifyingOrigin}`,
    );
    assert.equal(modifyingOrigin, origin);
    assert.equal(await page.locator('[role="alert"]').count(), 1);
    assert.equal(
      await page
        .locator('form[action="/admin/goals"] input[name="name"]')
        .inputValue(),
      "kept goal",
    );
    assert.equal(
      await page
        .locator('form[action="/admin/goals"] input[name="value"]')
        .inputValue(),
      "bad value",
    );

    await page
      .locator('form[action="/admin/goals"] input[name="name"]')
      .fill("Purchase");
    await page
      .locator('form[action="/admin/goals"] input[name="value"]')
      .fill("purchase");
    response = await Promise.all([
      page.waitForNavigation({ waitUntil: "load" }),
      page
        .locator('form[action="/admin/goals"] button[type="submit"]')
        .click(),
    ]).then(([navigation]) => navigation);
    assert.equal(response.status(), 200);
    assert.equal(await page.locator('[role="status"]').textContent(), "Goal added.");
    assert.match(page.url(), /start=2025-01-01/);
    assert.match(page.url(), /end=2025-01-02/);

    const purchaseItem = page.locator("li", { hasText: "Purchase" });
    response = await Promise.all([
      page.waitForNavigation({ waitUntil: "load" }),
      purchaseItem.locator("button", { hasText: "Delete" }).click(),
    ]).then(([navigation]) => navigation);
    assert.equal(response.status(), 200);
    assert.equal(
      await page.locator('[role="status"]').textContent(),
      "Goal deleted.",
    );

    const funnelForm = page.locator('form[action="/admin/funnels"]');
    await funnelForm.locator('input[name="name"]').fill("Checkout");
    await funnelForm
      .locator('textarea[name="steps"]')
      .fill("path=/pricing\nevent=signup");
    response = await Promise.all([
      page.waitForNavigation({ waitUntil: "load" }),
      funnelForm.locator('button[type="submit"]').click(),
    ]).then(([navigation]) => navigation);
    assert.equal(response.status(), 200);
    assert.equal(
      await page.locator('[role="status"]').textContent(),
      "Funnel added.",
    );

    const checkoutItem = page.locator("li", { hasText: "Checkout" });
    response = await Promise.all([
      page.waitForNavigation({ waitUntil: "load" }),
      checkoutItem.locator("button", { hasText: "Delete" }).click(),
    ]).then(([navigation]) => navigation);
    assert.equal(response.status(), 200);
    assert.equal(
      await page.locator('[role="status"]').textContent(),
      "Funnel deleted.",
    );

    await context.close();
  } finally {
    await browser.close();
  }
  process.stdout.write(
    JSON.stringify({
      engine: "chromium",
      javascript: "disabled",
      report_families: 13,
      native_form_mutations: 5,
      startup_api_requests: 0,
      persistent_storage_entries: 0,
      first_view: "useful-over-64KiBps-link",
    }) + "\n",
  );
}

async function assertMetric(page, label, expected) {
  const item = page.locator(".metrics li", { hasText: label });
  assert.equal(await item.locator("strong").textContent(), expected);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
