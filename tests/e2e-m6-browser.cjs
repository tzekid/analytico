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

const dates = "from=2025-01-01&to=2025-01-02&compare=previous";

function route(site, destination, query = "") {
  let state = query;
  if (destination === "analyze") {
    if (!state.includes("report=")) state += "&report=pages";
    if (!state.includes("sort=")) state += "&sort=count";
    if (!state.includes("limit=")) state += "&limit=25";
    if (!state.includes("page=")) state += "&page=1";
  }
  return `${origin}/admin/sites/${site}/${destination}?${dates}${state}`;
}

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
      colorScheme: "light",
    });
    await addSession(context);
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
      route("example", "overview"),
      { waitUntil: "load" },
    );
    assert.equal(response.status(), 200);
    assert.equal(await page.locator("h1").textContent(), "Overview");
    assert.equal(
      await page.locator('.primary-navigation a[aria-current="page"] .nav-label').textContent(),
      "Overview",
    );
    await assertMetric(page, "Page views", "8");
    await assertMetric(page, "Visitor-days", "4");
    await assertMetric(page, "Distinct people", "4");
    await assertMetric(page, "Sessions", "5");
    await assertMetric(page, "Custom events", "5");
    await assertMetric(page, "Persistent coverage", "0.00%");
    assert.equal(
      await page.getByRole("heading", { name: "Traffic quality" }).count(),
      1,
    );
    assert.equal((await page.locator("body").innerText()).includes(
      "Stored classes plus reversible query-classifier v1 diagnostics",
    ), true);
    assert.equal((await page.locator("body").innerText()).includes(
      "Compatibility report: the values below still use UTC calendar dates.",
    ), true);
    await assertVisualTheme(page, "light", "44px");
    if (process.env.ANALYTICO_MOBILE_SCREENSHOT_PATH) {
      await page.screenshot({
        path: process.env.ANALYTICO_MOBILE_SCREENSHOT_PATH,
        fullPage: true,
      });
    }
    assert.deepEqual(
      [...new Set(firstViewRequests)].sort(),
      ["document", "stylesheet"],
    );
    assert.equal(firstViewRequests.filter((kind) => kind === "script").length, 0);
    assert.equal(firstViewRequests.filter((kind) => kind === "fetch").length, 0);
    assert.equal(firstViewRequests.filter((kind) => kind === "xhr").length, 0);
    assert.equal(await page.locator("script").count(), 2);
    assert.equal(await page.evaluate(() => typeof window.htmx), "undefined");
    assert.equal(await page.locator("#loading-region").isVisible(), false);
    assert.equal(await page.evaluate(() => localStorage.length), 0);
    assert.equal(await page.evaluate(() => sessionStorage.length), 0);
    assert.deepEqual(failures, []);
    await assertMobileNavigation(page);
    const mobileContext = page.locator(".mobile-context");
    const mobileCalendarUrl = page.url();
    await mobileContext.locator(":scope > summary").click();
    assert.equal(await mobileContext.locator("form.site-switcher").isVisible(), true);
    assert.equal(await mobileContext.getByText("All visitors", { exact: true }).isVisible(), true);
    await assertMobileContext(page);
    if (process.env.ANALYTICO_MOBILE_CONTEXT_SCREENSHOT_PATH) {
      await page.screenshot({
        path: process.env.ANALYTICO_MOBILE_CONTEXT_SCREENSHOT_PATH,
        fullPage: true,
      });
    }
    response = await Promise.all([
      page.waitForNavigation({ waitUntil: "load" }),
      mobileContext.getByRole("link", { name: "Yesterday", exact: true }).click(),
    ]).then(([navigation]) => navigation);
    assert.equal(response.status(), 200);
    assert.equal(
      await page.locator(".mobile-context details.date-presets > summary").textContent(),
      "Yesterday",
    );
    await page.goBack({ waitUntil: "load" });
    assert.equal(page.url(), mobileCalendarUrl);
    response = await page.goto(
      route("example", "analyze", "&report=pages"),
      { waitUntil: "load" },
    );
    assert.equal(response.status(), 200);
    const mobileTable = page.locator(".mobile-records table").first();
    assert.equal(await mobileTable.locator("caption").count(), 1);
    assert.equal(
      await mobileTable.locator('thead th[scope="col"]').count(),
      3,
    );
    const mobileRows = await mobileTable.locator("tbody tr").count();
    assert.ok(mobileRows > 0);
    assert.equal(
      await mobileTable.locator('tbody th[scope="row"]').count(),
      mobileRows,
    );
    assert.equal(
      await mobileTable.locator("tbody tr").first().evaluate((element) =>
        getComputedStyle(element).display),
      "block",
    );
    assert.equal(
      await mobileTable.locator("progress.cell-bar").count(),
      mobileRows,
    );
    response = await page.goto(
      route("example", "journeys/funnels", "&subject=Journey"),
      { waitUntil: "load" },
    );
    assert.equal(response.status(), 200);
    await page.locator(".funnel-figure .chart-data > summary").click();
    await assertFunnelFigure(page, true);
    if (process.env.ANALYTICO_COMPONENT_MOBILE_SCREENSHOT_PATH) {
      await page.screenshot({
        path: process.env.ANALYTICO_COMPONENT_MOBILE_SCREENSHOT_PATH,
        fullPage: true,
      });
    }
    await cdp.send("Network.emulateNetworkConditions", {
      offline: false,
      latency: 0,
      downloadThroughput: -1,
      uploadThroughput: -1,
      connectionType: "none",
    });
    await page.setViewportSize({ width: 1440, height: 900 });
    response = await page.goto(
      route("example", "journeys/funnels", "&subject=Journey"),
      { waitUntil: "load" },
    );
    assert.equal(response.status(), 200);
    await page.locator(".funnel-figure .chart-data > summary").click();
    await assertFunnelFigure(page, false);
    if (process.env.ANALYTICO_COMPONENT_SCREENSHOT_PATH) {
      await page.screenshot({
        path: process.env.ANALYTICO_COMPONENT_SCREENSHOT_PATH,
        fullPage: true,
      });
    }
    response = await page.goto(route("example", "overview"), {
      waitUntil: "load",
    });
    assert.equal(response.status(), 200);
    if (process.env.ANALYTICO_SCREENSHOT_PATH) {
      await page.screenshot({
        path: process.env.ANALYTICO_SCREENSHOT_PATH,
        fullPage: true,
      });
    }
    const fixedCalendarUrl = page.url();
    const presetDisclosure = page.locator(".desktop-context details.date-presets");
    const presetSummary = presetDisclosure.locator(":scope > summary");
    await presetSummary.focus();
    await page.keyboard.press("Enter");
    assert.equal(await presetDisclosure.getAttribute("open"), "");
    await page.keyboard.press("Enter");
    assert.equal(await presetDisclosure.getAttribute("open"), null);
    await presetSummary.click();
    response = await Promise.all([
      page.waitForNavigation({ waitUntil: "load" }),
      presetDisclosure.getByRole("link", { name: "Today", exact: true }).click(),
    ]).then(([navigation]) => navigation);
    assert.equal(response.status(), 200);
    assert.match(page.url(), /from=\d{4}-\d{2}-\d{2}&to=\d{4}-\d{2}-\d{2}&compare=previous/);
    assert.equal(
      await page.locator(".desktop-context details.date-presets > summary").textContent(),
      "Today",
    );
    assert.equal(
      await page.locator(".desktop-context .context-state div", { hasText: "Range status" }).locator("dd").textContent(),
      "Today is incomplete",
    );
    await page.goBack({ waitUntil: "load" });
    assert.equal(page.url(), fixedCalendarUrl);

    await page.keyboard.press("Tab");
    assert.equal(await page.evaluate(() => document.activeElement?.className), "skip-link");
    await page.keyboard.press("Enter");
    assert.equal(await page.evaluate(() => document.activeElement?.id), "main");

    await assertDestinations(page);

    const siteForm = page.locator(".desktop-context form.site-switcher");
    await siteForm.locator('select[name="site"]').selectOption("second");
    response = await Promise.all([
      page.waitForNavigation({ waitUntil: "load" }),
      siteForm.getByRole("button", { name: "View site" }).click(),
    ]).then(([navigation]) => navigation);
    assert.equal(response.status(), 200);
    assert.match(page.url(), /\/admin\/sites\/second\/overview/);
    assert.doesNotMatch(page.url(), /[?&]site=/);
    assert.equal(
      await page.locator('.desktop-context select[name="site"]').inputValue(),
      "second",
    );
    assert.equal(
      await page.locator(".desktop-context .context-state div", { hasText: "Timezone" }).locator("dd").textContent(),
      "Europe/Berlin",
    );
    await assertMetric(page, "Page views", "2");
    await page.locator('.primary-navigation a:has-text("Analyze")').click();
    assert.match(page.url(), /\/admin\/sites\/second\/analyze/);
    assert.match(page.url(), /report=pages/);

    response = await page.goto(
      `${origin}/admin/sites/second/overview?from=1970-01-01&to=1970-01-01&compare=previous`,
      { waitUntil: "load" },
    );
    assert.equal(response.status(), 200);
    assert.equal(
      await page.locator(".desktop-context .context-state div", { hasText: "Comparison period" }).locator("dd").textContent(),
      "Previous period unavailable before 1970",
    );
    await page.goto(route("second", "analyze"), { waitUntil: "load" });
    const rangeForm = page.locator(".desktop-context form.range-filter");
    await rangeForm.locator('input[name="from"]').fill("2025-01-02");
    await rangeForm.locator('select[name="compare"]').selectOption("previous-year");
    response = await Promise.all([
      page.waitForNavigation({ waitUntil: "load" }),
      rangeForm.getByRole("button", { name: "Update context" }).click(),
    ]).then(([navigation]) => navigation);
    assert.equal(response.status(), 200);
    assert.equal(response.request().redirectedFrom(), null);
    assert.match(page.url(), /\/admin\/sites\/second\/analyze/);
    assert.match(page.url(), /from=2025-01-02/);
    assert.match(page.url(), /compare=previous-year/);
    assert.match(page.url(), /report=pages/);

    await page.goto(
      route("example", "journeys/goals", "&subject=Signup"),
      { waitUntil: "load" },
    );
    await page
      .locator(".desktop-context form.site-switcher select[name=site]")
      .selectOption("second");
    response = await Promise.all([
      page.waitForNavigation({ waitUntil: "load" }),
      page
        .locator(".desktop-context form.site-switcher")
        .getByRole("button", { name: "View site" })
        .click(),
    ]).then(([navigation]) => navigation);
    assert.equal(response.status(), 200);
    assert.match(page.url(), /\/admin\/sites\/second\/overview/);
    assert.doesNotMatch(page.url(), /subject=/);
    assert.equal(
      await page.locator('.primary-navigation a[aria-current="page"] .nav-label').textContent(),
      "Overview",
    );

    await page
      .locator(".desktop-context form.site-switcher select[name=site]")
      .selectOption("example");
    await Promise.all([
      page.waitForNavigation({ waitUntil: "load" }),
      page
        .locator(".desktop-context form.site-switcher")
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
      "traffic-quality",
      "goal&subject=Signup",
      "funnel&subject=Journey",
    ];
    for (const report of reports) {
      const reportUrl = report === "traffic-quality"
        ? route("example", "live")
        : report.startsWith("goal")
          ? route("example", "journeys/goals", "&subject=Signup")
          : report.startsWith("funnel")
            ? route("example", "journeys/funnels", "&subject=Journey")
            : route("example", "analyze", `&report=${report}`);
      response = await page.goto(reportUrl, { waitUntil: "load" });
      assert.equal(response.status(), 200, report);
      assert.equal(await page.locator("#report").count(), 1, report);
    }

    response = await page.goto(
      route("example", "analyze", "&report=pages&sort=count&limit=1&page=1"),
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

    await page.goto(route("example", "journeys/goals"), {
      waitUntil: "load",
    });
    const unsafeText = "<script>alert(1)</script> \"&";
    assert.equal(await page.locator("script").count(), 2);
    assert.match(
      await page.locator("script").first().getAttribute("src"),
      /\/admin\/htmx\.[a-f0-9]+\.js$/,
    );
    assert.ok((await page.locator("body").innerText()).includes(unsafeText));

    await page.locator(
      'details.management:has(form[action="/admin/goals"]) > summary',
    ).click();
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
      await page.evaluate(() => document.activeElement?.id),
      "form-error-summary",
    );
    assert.equal(
      await page
        .locator('form[action="/admin/goals"] input[name="name"]')
        .getAttribute("aria-describedby"),
      "form-error-summary",
    );
    assert.equal(
      await page
        .locator('form[action="/admin/goals"] input[name="name"]')
        .getAttribute("aria-invalid"),
      "true",
    );
    assert.equal(
      await page
        .locator('form[action="/admin/funnels"] input[name="name"]')
        .getAttribute("aria-invalid"),
      null,
    );
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
    assert.equal(
      await page.locator('.notice[role="status"]').textContent(),
      "Goal added.",
    );
    assert.match(page.url(), /from=2025-01-01/);
    assert.match(page.url(), /to=2025-01-02/);
    assert.match(page.url(), /compare=previous/);

    const purchaseItem = page.locator("li", { hasText: "Purchase" });
    response = await Promise.all([
      page.waitForNavigation({ waitUntil: "load" }),
      purchaseItem.locator("button", { hasText: "Delete" }).click(),
    ]).then(([navigation]) => navigation);
    assert.equal(response.status(), 200);
    assert.equal(
      await page.locator('.notice[role="status"]').textContent(),
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
      await page.locator('.notice[role="status"]').textContent(),
      "Funnel added.",
    );

    const checkoutItem = page.locator("li", { hasText: "Checkout" });
    response = await Promise.all([
      page.waitForNavigation({ waitUntil: "load" }),
      checkoutItem.locator("button", { hasText: "Delete" }).click(),
    ]).then(([navigation]) => navigation);
    assert.equal(response.status(), 200);
    assert.equal(
      await page.locator('.notice[role="status"]').textContent(),
      "Funnel deleted.",
    );

    response = await page.goto(route("example", "settings/general"), {
      waitUntil: "load",
    });
    assert.equal(response.status(), 200);
    const policyForm = page.locator('form[action="/admin/traffic-policy"]');
    await policyForm.locator("xpath=ancestor::details/summary").click();
    await policyForm.locator('input[name="strict"]').check();
    await policyForm.locator('input[name="daily_event_ceiling"]').evaluate(
      (input) => input.min = "0",
    );
    await policyForm.locator('input[name="daily_event_ceiling"]').fill("0");
    response = await Promise.all([
      page.waitForResponse(
        (candidate) =>
          candidate.url() === `${origin}/admin/traffic-policy` &&
          candidate.request().method() === "POST",
      ),
      policyForm.locator('button[type="submit"]').click(),
    ]).then(([post]) => post);
    assert.equal(response.status(), 422);
    assert.equal(await page.evaluate(() => document.activeElement?.id), "form-error-summary");
    assert.equal(await policyForm.locator('input[name="strict"]').isChecked(), true);
    assert.equal(
      await policyForm.locator('input[name="daily_event_ceiling"]').inputValue(),
      "0",
    );
    assert.equal(
      await policyForm.locator('input[name="daily_event_ceiling"]').getAttribute("aria-invalid"),
      "true",
    );
    assert.equal(await policyForm.locator("xpath=ancestor::details").getAttribute("open"), "");

    await assertTextSpacingAndNarrowReflow(page, cdp);

    await context.close();

    const darkContext = await browser.newContext({
      javaScriptEnabled: false,
      colorScheme: "dark",
    });
    await addSession(darkContext);
    const darkPage = await darkContext.newPage();
    await darkPage.setViewportSize({ width: 1440, height: 900 });
    response = await darkPage.goto(
      route("example", "overview"),
      { waitUntil: "load" },
    );
    assert.equal(response.status(), 200);
    await assertMetric(darkPage, "Page views", "8");
    await assertVisualTheme(darkPage, "dark", "40px");
    await darkPage.emulateMedia({ reducedMotion: "reduce" });
    assert.equal(
      await darkPage.locator(".desktop-context .range-filter button").evaluate((element) =>
        getComputedStyle(element).transitionDuration),
      "0s",
    );
    if (process.env.ANALYTICO_DARK_SCREENSHOT_PATH) {
      await darkPage.screenshot({
        path: process.env.ANALYTICO_DARK_SCREENSHOT_PATH,
        fullPage: true,
      });
    }
    await darkPage.emulateMedia({
      colorScheme: "dark",
      reducedMotion: "reduce",
      forcedColors: "active",
    });
    response = await darkPage.goto(
      route("example", "journeys/funnels", "&subject=Journey"),
      { waitUntil: "load" },
    );
    assert.equal(response.status(), 200);
    assert.equal(
      await darkPage.evaluate(() => matchMedia("(forced-colors: active)").matches),
      true,
    );
    const forcedColors = await darkPage.locator(".funnel-figure").evaluate((figure) => ({
      bar: getComputedStyle(figure.querySelector(".funnel-bar")).fill,
      track: getComputedStyle(figure.querySelector(".funnel-track")).fill,
    }));
    assert.notEqual(forcedColors.bar, forcedColors.track);
    await darkContext.close();
  } finally {
    await browser.close();
  }
  process.stdout.write(
    JSON.stringify({
      engine: "chromium",
      javascript: "disabled",
      report_families: 13,
      native_form_mutations: 6,
      startup_api_requests: 0,
      persistent_storage_entries: 0,
      canonical_destinations: 6,
      calendar_presets: 6,
      custom_comparison: "previous-year",
      unavailable_comparison: "explicit-not-zero",
      timezone_context: "UTC-and-Europe/Berlin",
      native_calendar_history: "back",
      keyboard_skip_link: "main",
      keyboard_preset_disclosure: "native-details",
      mobile_primary_navigation: "unclipped",
      mobile_calendar_controls: "unclipped-44px-targets",
      mobile_preset_navigation: "native-history",
      mobile_record_table: "stacked-labeled-records",
      funnel_figure: "svg-plus-exact-table",
      form_error_focus: "summary",
      reduced_motion: "zero-duration",
      forced_colors: "distinct-funnel-bar-and-track",
      narrow_reflow: "720-css-pixels-with-text-spacing",
      first_view: "useful-over-64KiBps-link",
      visual_themes: ["light", "dark"],
      contrast: "wcag-aa",
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

async function assertMobileNavigation(page) {
  const links = page.locator(".mobile-navigation a");
  assert.equal(await links.count(), 6);
  const bounds = await links.evaluateAll((elements) => elements.map((element) => {
    const rect = element.getBoundingClientRect();
    return {
      left: rect.left,
      right: rect.right,
      height: rect.height,
      viewport: document.documentElement.clientWidth,
      clipped: element.scrollWidth > element.clientWidth,
    };
  }));
  for (const bound of bounds) {
    assert.ok(bound.left >= 0);
    assert.ok(bound.right <= bound.viewport + 0.5);
    assert.ok(bound.height >= 44);
    assert.equal(bound.clipped, false);
  }
}

async function assertMobileContext(page) {
  const presets = page.locator(".mobile-context details.date-presets");
  await presets.locator(":scope > summary").click();
  assert.equal(await presets.getAttribute("open"), "");
  assert.equal(await presets.locator(".preset-list a").count(), 6);
  const controls = page.locator(
    ".mobile-context input:not([type=hidden]), .mobile-context select, " +
      ".mobile-context button, " +
      ".mobile-context details.date-presets > summary, " +
      ".mobile-context .preset-list a",
  );
  const bounds = await controls.evaluateAll((elements) => elements.map((element) => {
    const rect = element.getBoundingClientRect();
    return {
      tag: element.tagName,
      left: rect.left,
      right: rect.right,
      height: rect.height,
      viewport: document.documentElement.clientWidth,
      clipped: element.scrollWidth > element.clientWidth + 1,
    };
  }));
  assert.ok(bounds.length >= 14);
  for (const bound of bounds) {
    assert.ok(bound.left >= 0, `${bound.tag} starts outside the viewport`);
    assert.ok(
      bound.right <= bound.viewport + 0.5,
      `${bound.tag} ends outside the viewport`,
    );
    assert.ok(bound.height >= 44, `${bound.tag} is shorter than 44px`);
    assert.equal(bound.clipped, false, `${bound.tag} clips its contents`);
  }
  assert.equal(
    await page.evaluate(() =>
      document.documentElement.scrollWidth > document.documentElement.clientWidth + 1),
    false,
  );
}

async function assertDestinations(page) {
  const destinations = [
    ["overview", "Overview"],
    ["analyze", "Analyze"],
    ["journeys/goals", "Journeys"],
    ["sessions", "Sessions"],
    ["live", "Live"],
    ["settings/general", "Settings"],
  ];
  for (const [path, label] of destinations) {
    const response = await page.goto(route("example", path), { waitUntil: "load" });
    assert.equal(response.status(), 200, path);
    assert.equal(await page.locator("h1").textContent(), label, path);
    assert.equal(
      await page.locator('.primary-navigation a[aria-current="page"] .nav-label').textContent(),
      label,
      path,
    );
    assert.equal(await page.locator("#main").count(), 1, path);
  }
}

async function assertMetric(page, label, expected) {
  const item = page.locator(".metrics li").filter({
    has: page.getByText(label, { exact: true }),
  });
  assert.equal(await item.locator("strong").textContent(), expected);
}

async function assertFunnelFigure(page, mobile) {
  const figure = page.locator("figure.funnel-figure");
  assert.equal(await figure.count(), 1);
  assert.equal(await figure.getAttribute("aria-labelledby"), "funnel-result-title");
  assert.equal(await figure.getAttribute("aria-describedby"), "funnel-result-summary");
  assert.equal(
    await figure.locator('svg[role="img"][focusable="false"]').count(),
    1,
  );
  assert.equal(
    await figure.locator("svg").evaluate((element) => getComputedStyle(element).display),
    mobile ? "none" : "block",
  );
  assert.equal(
    await figure.locator("table caption").textContent(),
    "Funnel result — exact values",
  );
  if (mobile) {
    const widths = await figure.locator("table caption").evaluate((caption) => ({
      caption: caption.getBoundingClientRect().width,
      table: caption.parentElement.getBoundingClientRect().width,
    }));
    assert.ok(
      widths.caption >= widths.table - 1,
      `mobile caption ${widths.caption}px did not fill ${widths.table}px table`,
    );
  }
  assert.equal(await figure.locator('thead th[scope="col"]').count(), 6);
  assert.equal(await figure.locator('tbody th[scope="row"]').count(), 3);
  assert.equal(
    await figure.locator('tbody tr').last().locator('td[data-label="Sessions"]').textContent(),
    "2",
  );
  assert.equal(await figure.locator("[onclick]").count(), 0);
  assert.equal(
    await page.getByRole("figure", { name: "Funnel result" }).count(),
    1,
  );
  assert.equal(
    await page.getByRole("table", {
      name: "Funnel result — exact values",
      includeHidden: true,
    }).count(),
    1,
  );
}

async function assertTextSpacingAndNarrowReflow(page, cdp) {
  await page.setViewportSize({ width: 720, height: 900 });
  const response = await page.goto(
    route("example", "journeys/funnels", "&subject=Journey"),
    { waitUntil: "load" },
  );
  assert.equal(response.status(), 200);
  await cdp.send("DOM.enable");
  await cdp.send("CSS.enable");
  const frameTree = await cdp.send("Page.getFrameTree");
  const inspector = await cdp.send("CSS.createStyleSheet", {
    frameId: frameTree.frameTree.frame.id,
  });
  await cdp.send("CSS.setStyleSheetText", {
    styleSheetId: inspector.styleSheetId,
    text: `
    * {
      letter-spacing: .12em !important;
      line-height: 1.5 !important;
      word-spacing: .16em !important;
    }
    p { margin-block: 2em !important; }
  `,
  });
  await page.locator(".funnel-figure .chart-data > summary").click();
  const reflow = await page.evaluate(() => {
    const clipped = [...document.querySelectorAll(
      "h1, figcaption, .chart-summary, .chart-data > summary, button, a",
    )].filter((element) => {
      const style = getComputedStyle(element);
      if (style.display === "none" || style.visibility === "hidden") return false;
      return element.scrollWidth > element.clientWidth + 1 ||
        element.scrollHeight > element.clientHeight + 1;
    }).map((element) => element.textContent.trim());
    return {
      documentOverflow: document.documentElement.scrollWidth >
        document.documentElement.clientWidth + 1,
      clipped,
    };
  });
  assert.equal(reflow.documentOverflow, false);
  assert.deepEqual(reflow.clipped, []);
}

async function assertVisualTheme(page, theme, expectedControlHeight) {
  const actual = await page.evaluate(() => {
    const root = getComputedStyle(document.documentElement);
    const styles = (selector) => getComputedStyle(document.querySelector(selector));
    const link = styles(".account-nav > a");
    const action = styles(".range-filter button");
    const active = styles('.primary-navigation a[aria-current="page"]');
    const metric = styles(".metrics strong");
    const metricLabel = styles(".metrics span");
    const brand = styles(".brand");
    const input = styles('.range-filter input[type="date"]');
    return {
      bodyColor: root.color,
      bodyBackground: root.backgroundColor,
      linkColor: link.color,
      actionColor: action.color,
      actionBackground: action.backgroundColor,
      activeColor: active.color,
      activeBackground: active.backgroundColor,
      metricVariant: metric.fontVariantNumeric,
      metricLabelColor: metricLabel.color,
      metricSurface: styles(".metrics li").backgroundColor,
      brandFamily: brand.fontFamily,
      controlHeight: input.minHeight,
      controlBorder: input.borderColor,
      controlSurface: input.backgroundColor,
    };
  });
  const expected = theme === "light" ? {
    bodyColor: "rgb(33, 31, 29)",
    bodyBackground: "rgb(251, 250, 248)",
    linkColor: "rgb(169, 50, 38)",
    actionColor: "rgb(251, 250, 248)",
    actionBackground: "rgb(169, 50, 38)",
    activeColor: "rgb(169, 50, 38)",
    activeBackground: "rgb(250, 232, 229)",
    metricLabelColor: "rgb(117, 110, 104)",
    metricSurface: "rgb(255, 255, 255)",
    controlBorder: "rgb(117, 110, 104)",
    controlSurface: "rgb(255, 255, 255)",
  } : {
    bodyColor: "rgb(240, 238, 238)",
    bodyBackground: "rgb(21, 21, 21)",
    linkColor: "rgb(255, 111, 97)",
    actionColor: "rgb(21, 21, 21)",
    actionBackground: "rgb(255, 111, 97)",
    activeColor: "rgb(255, 170, 162)",
    activeBackground: "rgb(59, 35, 33)",
    metricLabelColor: "rgb(167, 160, 155)",
    metricSurface: "rgb(29, 29, 29)",
    controlBorder: "rgb(167, 160, 155)",
    controlSurface: "rgb(29, 29, 29)",
  };
  assert.equal(actual.bodyColor, expected.bodyColor);
  assert.equal(actual.bodyBackground, expected.bodyBackground);
  assert.equal(actual.linkColor, expected.linkColor);
  assert.equal(actual.actionColor, expected.actionColor);
  assert.equal(actual.actionBackground, expected.actionBackground);
  assert.equal(actual.activeColor, expected.activeColor);
  assert.equal(actual.activeBackground, expected.activeBackground);
  assert.equal(actual.metricLabelColor, expected.metricLabelColor);
  assert.equal(actual.metricSurface, expected.metricSurface);
  assert.equal(actual.controlBorder, expected.controlBorder);
  assert.equal(actual.controlSurface, expected.controlSurface);
  assert.match(actual.metricVariant, /tabular-nums/);
  assert.match(actual.metricVariant, /lining-nums/);
  assert.match(actual.brandFamily, /Georgia/);
  assert.equal(actual.controlHeight, expectedControlHeight);
  assert.ok(contrast(actual.bodyColor, actual.bodyBackground) >= 4.5);
  assert.ok(contrast(actual.linkColor, actual.bodyBackground) >= 4.5);
  assert.ok(contrast(actual.actionColor, actual.actionBackground) >= 4.5);
  assert.ok(contrast(actual.activeColor, actual.activeBackground) >= 4.5);
  assert.ok(contrast(actual.metricLabelColor, actual.metricSurface) >= 4.5);
  assert.ok(contrast(actual.controlBorder, actual.controlSurface) >= 3);
}

function contrast(first, second) {
  const luminances = [first, second].map((value) => {
    const channels = value.match(/[\d.]+/g).slice(0, 3).map((channel) => {
      const encoded = Number(channel) / 255;
      return encoded <= 0.04045
        ? encoded / 12.92
        : ((encoded + 0.055) / 1.055) ** 2.4;
    });
    return 0.2126 * channels[0] + 0.7152 * channels[1] +
      0.0722 * channels[2];
  }).sort((a, b) => b - a);
  return (luminances[0] + 0.05) / (luminances[1] + 0.05);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
