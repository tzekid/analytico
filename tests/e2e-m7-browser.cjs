"use strict";

const assert = require("node:assert/strict");
const { chromium } = require("playwright");

const origin = process.argv[2];
const sessionToken = process.argv[3];
const mode = process.argv[4] || "normal";
if (!origin || !sessionToken) {
  throw new Error(
    "usage: node e2e-m7-browser.cjs <origin> <session-token> [normal|timeout]",
  );
}

const range = "site=example&start=2025-01-01&end=2025-01-02";

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

async function normal() {
  const browser = await launch();
  try {
    const context = await browser.newContext();
    await addSession(context);
    const page = await context.newPage();
    const startup = [];
    const enhanced = [];
    const expectedConsoleErrors = [];
    page.on("request", (request) => {
      if (startup.length < 4) startup.push(request.resourceType());
      if (request.headers()["hx-request"] === "true") {
        enhanced.push({
          method: request.method(),
          url: request.url(),
          type: request.headers()["hx-request-type"],
        });
      }
    });
    page.on("console", (message) => {
      if (message.type() === "error") expectedConsoleErrors.push(message.text());
    });

    let response = await page.goto(
      `${origin}/admin?${range}&report=overview`,
      { waitUntil: "load" },
    );
    assert.equal(response.status(), 200);
    await page.waitForFunction(() => window.htmx !== undefined);
    assert.match(await page.evaluate(() => window.htmx.version), /^4\.0\.0-beta6/);
    assert.deepEqual([...new Set(startup)].sort(), [
      "document",
      "script",
      "stylesheet",
    ]);
    assert.equal(
      startup.filter((kind) => kind === "fetch" || kind === "xhr").length,
      0,
    );

    let siteResponse = page.waitForResponse(
      (candidate) =>
        candidate.url().includes("site=second") &&
        candidate.request().headers()["hx-request"] === "true",
    );
    await page
      .locator("form.site-switcher select[name=site]")
      .selectOption("second");
    response = await siteResponse;
    assert.equal(response.status(), 200);
    await page.waitForFunction(() =>
      document.querySelector('form.site-switcher select[name="site"]')?.value ===
      "second",
    );
    assert.match(page.url(), /site=second/);
    assert.equal(
      await page.locator(".metrics li", { hasText: "Page views" }).locator("strong").textContent(),
      "2",
    );

    siteResponse = page.waitForResponse(
      (candidate) =>
        candidate.url().includes("site=example") &&
        candidate.request().headers()["hx-request"] === "true",
    );
    await page
      .locator("form.site-switcher select[name=site]")
      .selectOption("example");
    response = await siteResponse;
    assert.equal(response.status(), 200);
    await page.waitForFunction(() =>
      document.querySelector('form.site-switcher select[name="site"]')?.value ===
      "example",
    );

    await page.route("**/admin?*report=pages*", async (route) => {
      if (route.request().headers()["hx-request"] === "true") {
        await new Promise((resolve) => setTimeout(resolve, 250));
      }
      await route.continue();
    });
    const pagesLink = page.getByRole("link", { name: "Pages", exact: true });
    await pagesLink.focus();
    const pagesResponse = page.waitForResponse(
      (candidate) =>
        candidate.url().includes("report=pages") &&
        candidate.request().headers()["hx-request"] === "true",
      { timeout: 5000 },
    );
    const pagesMarkup = await pagesLink.evaluate((element) => element.outerHTML);
    await pagesLink.click({ noWaitAfter: true });
    await page.waitForTimeout(50);
    const loadingCount = await page.locator(".htmx-request").count();
    response = await pagesResponse.catch((error) => {
      throw new Error(
        `${error.message}\nurl=${page.url()}\nlink=${pagesMarkup}\nconsole=${JSON.stringify(expectedConsoleErrors)}`,
      );
    });
    assert.equal(response.status(), 200);
    assert.ok(loadingCount >= 1);
    await page.waitForFunction(() =>
      document.querySelector('a[aria-current="page"]')?.textContent === "Pages",
    );
    assert.match(page.url(), /report=pages/);
    assert.equal(
      await page.evaluate(() => document.activeElement?.id),
      "report-nav-pages",
    );
    assert.equal(enhanced.at(-1).method, "GET");
    assert.equal(enhanced.at(-1).type, "full");

    const eventsLink = page.getByRole("link", { name: "Events", exact: true });
    await page.evaluate(() => window.scrollTo(0, document.body.scrollHeight));
    await eventsLink.evaluate((element) => element.click());
    await page.waitForFunction(() =>
      document.querySelector('a[aria-current="page"]')?.textContent === "Events",
    );
    assert.match(page.url(), /report=events/);
    assert.equal(await page.evaluate(() => localStorage.length), 0);
    assert.equal(await page.evaluate(() => sessionStorage.length), 0);
    assert.equal(await page.evaluate(() => window.scrollY), 0);

    await page.goBack();
    await page.waitForFunction(() =>
      document.querySelector('a[aria-current="page"]')?.textContent === "Pages",
    );
    assert.match(page.url(), /report=pages/);
    await page.goForward();
    await page.waitForFunction(() =>
      document.querySelector('a[aria-current="page"]')?.textContent === "Events",
    );
    assert.match(page.url(), /report=events/);

    await page.goto(`${origin}/admin?${range}&report=overview`, {
      waitUntil: "load",
    });
    await page.waitForFunction(() => window.htmx !== undefined);
    await page.locator(
      'details.management:has(form[action="/admin/goals"]) > summary',
    ).click();
    const goalForm = page.locator('form[action="/admin/goals"]');
    const postCountBeforeValidation = enhanced.filter(
      (entry) => entry.method === "POST",
    ).length;
    await goalForm.locator('input[name="name"]').fill("");
    await goalForm.locator('button[type="submit"]').click();
    assert.equal(
      enhanced.filter((entry) => entry.method === "POST").length,
      postCountBeforeValidation,
    );
    assert.equal(
      await goalForm.locator('input[name="name"]').evaluate((element) =>
        element.matches(":invalid")), true);

    await goalForm.locator('input[name="name"]').fill("kept enhanced");
    await goalForm.locator('input[name="value"]').fill("bad value");
    response = await Promise.all([
      page.waitForResponse(
        (candidate) =>
          candidate.url() === `${origin}/admin/goals` &&
          candidate.request().headers()["hx-request"] === "true",
      ),
      goalForm.locator('button[type="submit"]').click(),
    ]).then(([post]) => post);
    assert.equal(response.status(), 422);
    await page.waitForFunction(() =>
      document.querySelector('[role="alert"]')?.textContent.includes(
        "definition was not saved",
      ),
    );
    assert.equal(
      await page
        .locator('form[action="/admin/goals"] input[name="name"]')
        .inputValue(),
      "kept enhanced",
    );

    const doubleForm = page.locator('form[action="/admin/goals"]');
    await doubleForm.locator('input[name="name"]').fill("Double");
    await doubleForm.locator('input[name="value"]').fill("double");
    const doubleBefore = enhanced.filter(
      (entry) => entry.url === `${origin}/admin/goals`,
    ).length;
    await doubleForm.locator('button[type="submit"]').dblclick();
    await page.waitForFunction(() =>
      document.querySelector('[role="status"]')?.textContent === "Goal added.",
    );
    const doubleAfter = enhanced.filter(
      (entry) => entry.url === `${origin}/admin/goals`,
    ).length;
    assert.equal(doubleAfter - doubleBefore, 1);

    await context.setOffline(true);
    const titleBeforeOffline = await page.locator("#report h2").textContent();
    await page.getByRole("link", { name: "Sources", exact: true }).click({
      noWaitAfter: true,
    });
    await page.waitForTimeout(300);
    assert.equal(await page.locator("#report h2").textContent(), titleBeforeOffline);
    await context.setOffline(false);
    await page.getByRole("link", { name: "Sources", exact: true }).click();
    await page.waitForFunction(() =>
      document.querySelector('a[aria-current="page"]')?.textContent === "Sources",
    );
    assert.match(page.url(), /report=sources/);
    assert.ok(expectedConsoleErrors.length >= 1);

    await context.close();

    await fallbackContext(browser, "abort");
    await fallbackContext(browser, "corrupt");
  } finally {
    await browser.close();
  }
  process.stdout.write(
    JSON.stringify({
      htmx: "4.0.0-beta6",
      enhanced_navigation: true,
      history: "back-forward",
      loading_state: "visible",
      html5_validation: "native",
      server_validation: "swapped-422",
      double_submit_requests: 1,
      offline_state: "preserved",
      blocked_asset_fallback: "native",
      corrupt_asset_fallback: "native",
    }) + "\n",
  );
}

async function fallbackContext(browser, behavior) {
  const context = await browser.newContext();
  await addSession(context);
  const page = await context.newPage();
  await page.route("**/admin/htmx.*.js", async (route) => {
    if (behavior === "abort") {
      await route.abort();
    } else {
      await route.fulfill({
        status: 200,
        contentType: "text/javascript",
        body: "this is not valid javascript {{{",
      });
    }
  });
  const documents = [];
  page.on("request", (request) => {
    if (request.resourceType() === "document") documents.push(request.url());
  });
  await page.goto(`${origin}/admin?${range}&report=overview`, {
    waitUntil: "load",
  });
  await page.getByRole("link", { name: "Pages", exact: true }).click();
  await page.waitForLoadState("load");
  assert.match(page.url(), /report=pages/);
  assert.equal(documents.length, 2);
  await context.close();
}

async function timeout() {
  const browser = await launch();
  try {
    const context = await browser.newContext();
    await addSession(context);
    const page = await context.newPage();
    let response = await page.goto(
      `${origin}/admin?${range}&report=overview`,
      { waitUntil: "load" },
    );
    assert.equal(response.status(), 503);
    await page.waitForFunction(() => window.htmx !== undefined);
    assert.equal(
      await page.locator('[role="alert"]').textContent(),
      "The report exceeded its server deadline. Narrow the UTC date range and retry.",
    );
    response = await Promise.all([
      page.waitForResponse(
        (candidate) =>
          candidate.status() === 503 &&
          candidate.request().headers()["hx-request"] === "true",
      ),
      page.getByRole("link", { name: "Return to dashboard" }).click(),
    ]).then(([retry]) => retry);
    assert.equal(response.status(), 503);
    await page.waitForFunction(() =>
      document.querySelector('[role="alert"]')?.textContent.includes(
        "report exceeded",
      ),
    );
    assert.match(page.url(), /start=2025-01-01/);
    await context.close();
  } finally {
    await browser.close();
  }
  process.stdout.write(
    JSON.stringify({
      enhanced_server_error: "swapped-503",
      retry: "preserved-deep-link",
    }) + "\n",
  );
}

async function addSession(context) {
  await context.addCookies([{
    name: "analytico_session",
    value: sessionToken,
    url: origin,
    httpOnly: true,
    sameSite: "Strict",
  }]);
}

(mode === "timeout" ? timeout() : normal()).catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
