"use strict";

const assert = require("node:assert/strict");
const { chromium } = require("playwright");

async function metric(page, label) {
  const card = page.locator(".overview-metrics .kpi").filter({
    has: page.getByText(label, { exact: true }),
  });
  return (await card.locator("strong").innerText()).trim();
}

async function submit(page, form, button) {
  await Promise.all([
    page.waitForNavigation({ waitUntil: "load" }),
    form.getByRole("button", { name: button, exact: true }).click(),
  ]);
}

async function main() {
  const [origin, session, screenshot] = process.argv.slice(2);
  assert.ok(origin && session && screenshot);
  const executablePath = process.env.ANALYTICO_CHROMIUM_PATH;
  const browser = await chromium.launch({ executablePath, headless: true });
  const cookie = {
    name: "analytico_session",
    value: session,
    url: origin,
    httpOnly: true,
    sameSite: "Strict",
  };
  const range = "v=1&from=2025-01-01&to=2025-01-02&compare=previous&metric=visitors";

  const native = await browser.newContext({ javaScriptEnabled: false });
  await native.addCookies([cookie]);
  const page = await native.newPage();
  let response = await page.goto(
    `${origin}/admin/sites/alpha/overview?${range}`,
    { waitUntil: "load" },
  );
  assert.equal(response.status(), 200);
  assert.equal(await page.locator("#filter-context-heading").innerText(), "Filters");
  assert.equal(await page.locator(".filter-chip").count(), 0);

  const addFilter = page.locator("details.filter-builder");
  await addFilter.locator("summary").click();
  const filterForm = addFilter.locator("form");
  await filterForm.locator("select[name=scope]").selectOption("session");
  await filterForm.locator("select[name=field]").selectOption("landing-page");
  await filterForm.locator("select[name=scalar_type]").selectOption("string");
  await filterForm.locator("select[name=operator]").selectOption("not_contains");
  await filterForm.locator("input[name=search]").fill("/value");
  await filterForm.locator("textarea[name=values]").fill("/draft\n/value");
  await submit(page, filterForm, "Preview values");
  assert.equal(page.url(), `${origin}/admin/filters/suggest`);
  assert.equal(
    await page.locator(".suggestion-results").count(),
    1,
    await page.locator("body").innerText(),
  );
  assert.match(
    await page.locator(".suggestion-results h3").innerText(),
    /Suggested values for session · landing-page · string/,
  );
  const preservedBuilder = page.locator("details.filter-builder form");
  assert.equal(await preservedBuilder.locator("select[name=scope]").inputValue(), "session");
  assert.equal(await preservedBuilder.locator("select[name=field]").inputValue(), "landing-page");
  assert.equal(await preservedBuilder.locator("input[name=property]").inputValue(), "");
  assert.equal(await preservedBuilder.locator("select[name=scalar_type]").inputValue(), "string");
  assert.equal(await preservedBuilder.locator("select[name=operator]").inputValue(), "not_contains");
  assert.equal(await preservedBuilder.locator("input[name=search]").inputValue(), "/value");
  assert.equal(await preservedBuilder.locator("textarea[name=values]").inputValue(), "/draft\n/value");

  await preservedBuilder.locator("select[name=scope]").selectOption("event");
  await preservedBuilder.locator("select[name=field]").selectOption("page");
  await preservedBuilder.locator("select[name=operator]").selectOption("is");
  await preservedBuilder.locator("input[name=search]").fill("");
  await preservedBuilder.locator("textarea[name=values]").fill("");
  await submit(page, preservedBuilder, "Preview values");
  assert.equal(await page.locator(".suggestion-results li").count(), 50);
  const suggestionText = await page.locator(".suggestion-results").innerText();
  assert.match(suggestionText, /Context: event · page · string/);
  assert.match(suggestionText, /More than 50 values matched/);
  assert.doesNotMatch(suggestionText, /beta-secret/);

  const selected = page.locator(".suggestion-results li", { hasText: "/value-00" });
  await Promise.all([
    page.waitForNavigation({ waitUntil: "load" }),
    selected.getByRole("link", { name: "Filter to /value-00", exact: true }).click(),
  ]);
  let filteredUrl = new URL(page.url());
  assert.equal(filteredUrl.searchParams.getAll("f").length, 1);
  assert.equal(await metric(page, "Page views"), "1");
  assert.match(await page.locator(".filter-chip").innerText(), /\/value-00/);

  await Promise.all([
    page.waitForNavigation({ waitUntil: "load" }),
    page.locator(".filter-chip").getByRole("link", { name: /Remove filter/ }).click(),
  ]);
  assert.equal(new URL(page.url()).searchParams.getAll("f").length, 0);

  const builder = page.locator("details.filter-builder");
  await builder.locator("summary").click();
  const builderForm = builder.locator("form");
  await builderForm.locator("select[name=scope]").selectOption("event");
  await builderForm.locator("select[name=field]").selectOption("page");
  await builderForm.locator("select[name=scalar_type]").selectOption("string");
  await builderForm.locator("select[name=operator]").selectOption("is");
  await builderForm.locator("textarea[name=values]").fill("/value-00\n/value-01");
  await submit(page, builderForm, "Apply filter");
  assert.equal(await metric(page, "Page views"), "2");

  const segments = page.locator("details.management", { hasText: "Segments" });
  await segments.locator("summary").click();
  await segments.locator("form[action='/admin/segments'] input[name=name]").fill("Two pages");
  await submit(
    page,
    segments.locator("form[action='/admin/segments']"),
    "Save current filters as segment",
  );
  const savedSegment = page.locator("details.management", { hasText: "Segments" });
  await savedSegment.locator("summary").click();
  await Promise.all([
    page.waitForNavigation({ waitUntil: "load" }),
    savedSegment.getByRole("link", { name: "Two pages", exact: true }).click(),
  ]);
  assert.ok(new URL(page.url()).searchParams.get("segment"));
  assert.equal(await metric(page, "Page views"), "2");
  assert.match(await page.locator(".segment-chip").innerText(), /Two pages/);

  await Promise.all([
    page.waitForNavigation({ waitUntil: "load" }),
    page.locator(".filter-chip:not(.segment-chip)").getByRole("link", { name: /Remove filter/ }).click(),
  ]);
  assert.equal(new URL(page.url()).searchParams.getAll("f").length, 0);
  assert.equal(await metric(page, "Page views"), "2");
  const segmentId = new URL(page.url()).searchParams.get("segment");

  const composedBuilder = page.locator("details.filter-builder");
  await composedBuilder.locator("summary").click();
  const composedForm = composedBuilder.locator("form");
  await composedForm.locator("select[name=scope]").selectOption("event");
  await composedForm.locator("select[name=field]").selectOption("page");
  await composedForm.locator("select[name=scalar_type]").selectOption("string");
  await composedForm.locator("select[name=operator]").selectOption("is");
  await composedForm.locator("textarea[name=values]").fill("/value-00");
  await submit(page, composedForm, "Apply filter");
  assert.equal(new URL(page.url()).searchParams.get("segment"), segmentId);
  assert.equal(new URL(page.url()).searchParams.getAll("f").length, 1);
  assert.equal(await metric(page, "Page views"), "1");
  await Promise.all([
    page.waitForNavigation({ waitUntil: "load" }),
    page.locator(".filter-chip:not(.segment-chip)").getByRole(
      "link",
      { name: /Remove filter/ },
    ).click(),
  ]);
  assert.equal(await metric(page, "Page views"), "2");

  await Promise.all([
    page.waitForNavigation({ waitUntil: "load" }),
    page.locator(".primary-navigation").getByRole(
      "link",
      { name: /Journeys/ },
    ).click(),
  ]);
  assert.equal(new URL(page.url()).pathname, "/admin/sites/alpha/journeys/goals");
  assert.equal(await page.locator("#filter-context-heading").count(), 0);
  await page.goBack({ waitUntil: "load" });
  assert.equal(new URL(page.url()).searchParams.get("segment"), segmentId);
  assert.equal(await metric(page, "Page views"), "2");

  let segmentManagement = page.locator("details.management", { hasText: "Segments" });
  await segmentManagement.locator("summary").click();
  const renameSegment = segmentManagement.locator("form[action='/admin/segments/rename']");
  await renameSegment.locator("input[name=name]").fill("Two pages renamed");
  await submit(page, renameSegment, "Rename segment");
  assert.equal(new URL(page.url()).searchParams.get("segment"), segmentId);
  assert.match(await page.locator(".segment-chip").innerText(), /Two pages renamed/);
  segmentManagement = page.locator("details.management", { hasText: "Segments" });
  await segmentManagement.locator("summary").click();
  assert.match(await segmentManagement.innerText(), /Updated 2026-/);
  const updateSegment = segmentManagement.locator("form[action='/admin/segments/update']");
  const updateResponsePromise = page.waitForResponse((candidate) =>
    new URL(candidate.url()).pathname === "/admin/segments/update" &&
    candidate.request().method() === "POST"
  );
  await updateSegment.getByRole(
    "button",
    { name: "Replace segment with current filters", exact: true },
  ).click();
  assert.equal((await updateResponsePromise).status(), 303);
  await page.waitForLoadState("load");
  segmentManagement = page.locator("details.management", { hasText: "Segments" });
  await segmentManagement.locator("summary").click();
  const duplicateSegment = segmentManagement.locator("form[action='/admin/segments/duplicate']");
  await duplicateSegment.locator("input[name=name]").fill("Two pages copy");
  await submit(page, duplicateSegment, "Duplicate segment");
  assert.equal(new URL(page.url()).searchParams.get("segment"), segmentId);
  assert.match(await page.locator(".segment-chip").innerText(), /Two pages renamed/);
  segmentManagement = page.locator("details.management", { hasText: "Segments" });
  await segmentManagement.locator("summary").click();
  await Promise.all([
    page.waitForNavigation({ waitUntil: "load" }),
    segmentManagement.getByRole("link", { name: "Two pages copy", exact: true }).click(),
  ]);
  segmentManagement = page.locator("details.management", { hasText: "Segments" });
  await segmentManagement.locator("summary").click();
  const copySegment = segmentManagement.locator(
    ".segment-row",
    { hasText: "Two pages copy" },
  );
  const deleteSegment = copySegment.locator("form[action='/admin/segments/delete']");
  await deleteSegment.locator("input[name=name]").fill("Two pages copy");
  await submit(page, deleteSegment, "Delete segment");
  assert.equal(new URL(page.url()).searchParams.get("segment"), null);
  segmentManagement = page.locator("details.management", { hasText: "Segments" });
  await segmentManagement.locator("summary").click();
  await Promise.all([
    page.waitForNavigation({ waitUntil: "load" }),
    segmentManagement.getByRole("link", { name: "Two pages renamed", exact: true }).click(),
  ]);
  assert.equal(new URL(page.url()).searchParams.get("segment"), segmentId);

  await Promise.all([
    page.waitForNavigation({ waitUntil: "load" }),
    page.locator(".primary-navigation").getByRole("link", { name: /Analyze/ }).click(),
  ]);
  assert.equal(new URL(page.url()).searchParams.get("segment"), segmentId);
  assert.equal(new URL(page.url()).searchParams.get("mode"), "trend");

  const rangeForm = page.locator(".desktop-context form.range-filter");
  await rangeForm.locator("input[name=from]").fill("2025-01-01");
  await rangeForm.locator("input[name=to]").fill("2025-01-02");
  await submit(page, rangeForm, "Update context");
  assert.equal(new URL(page.url()).searchParams.get("segment"), segmentId);

  await Promise.all([
    page.waitForNavigation({ waitUntil: "load" }),
    page.getByRole("link", { name: "Open Breakdown", exact: true }).click(),
  ]);
  assert.equal(new URL(page.url()).searchParams.get("mode"), "breakdown");
  assert.equal(new URL(page.url()).searchParams.get("segment"), segmentId);
  assert.equal(await page.locator(".breakdown-table tbody tr").count(), 2);

  const firstRow = page.locator(".breakdown-table tbody tr").first();
  assert.equal(await firstRow.getByRole("link", { name: /^Filter to / }).count(), 1);
  assert.equal(await firstRow.getByRole("link", { name: /^Exclude / }).count(), 1);

  const savedViews = page.locator("details.management", { hasText: "Saved views" });
  await savedViews.locator("summary").click();
  await savedViews.locator("form[action='/admin/saved-views'] input[name=name]").fill("Two-page breakdown");
  await submit(
    page,
    savedViews.locator("form[action='/admin/saved-views']"),
    "Save this view",
  );
  const viewsAfterSave = page.locator("details.management", { hasText: "Saved views" });
  await viewsAfterSave.locator("summary").click();
  const originalView = viewsAfterSave.locator("article.saved-row", { hasText: "Two-page breakdown" });
  assert.equal(await originalView.count(), 1);
  await originalView.locator("form[action='/admin/saved-views/rename'] input[name=name]").fill("Renamed breakdown");
  await submit(
    page,
    originalView.locator("form[action='/admin/saved-views/rename']"),
    "Rename",
  );
  await page.locator("details.management", { hasText: "Saved views" }).locator("summary").click();
  assert.equal(await page.getByRole("link", { name: "Renamed breakdown", exact: true }).count(), 1);
  const renamed = page.locator("article.saved-row", { hasText: "Renamed breakdown" });
  const savedViewHref = await renamed.getByRole("link", { name: "Renamed breakdown", exact: true }).getAttribute("href");
  await renamed.locator("form[action='/admin/saved-views/duplicate'] input[name=name]").fill("Breakdown copy");
  await submit(
    page,
    renamed.locator("form[action='/admin/saved-views/duplicate']"),
    "Duplicate",
  );
  await page.locator("details.management", { hasText: "Saved views" }).locator("summary").click();
  const copy = page.locator("article.saved-row", { hasText: "Breakdown copy" });
  await copy.locator("form[action='/admin/saved-views/delete'] input[name=name]").fill("Breakdown copy");
  await submit(
    page,
    copy.locator("form[action='/admin/saved-views/delete']"),
    "Delete",
  );
  await page.goto(`${origin}${savedViewHref}`, { waitUntil: "load" });
  await page.locator("details.management", { hasText: "Saved views" }).locator("summary").click();
  assert.equal(await page.getByRole("link", { name: "Breakdown copy", exact: true }).count(), 0);

  const siteSwitcher = page.locator(".desktop-context form.site-switcher");
  await siteSwitcher.locator("select[name=site]").selectOption("beta");
  await submit(page, siteSwitcher, "View site");
  assert.equal(new URL(page.url()).pathname, "/admin/sites/beta/overview");
  assert.doesNotMatch(await page.locator("body").innerText(), /Two pages|Renamed breakdown/);
  await native.close();

  const enhanced = await browser.newContext({ viewport: { width: 390, height: 844 } });
  await enhanced.addCookies([cookie]);
  const mobile = await enhanced.newPage();
  const requests = [];
  mobile.on("request", (request) => requests.push(request.url()));
  response = await mobile.goto(
    `${origin}/admin/sites/alpha/overview?${range}&segment=${segmentId}`,
    { waitUntil: "networkidle" },
  );
  assert.equal(response.status(), 200);
  assert.equal(requests.filter((url) => /\/api\/|\.json(?:\?|$)/.test(url)).length, 0);
  assert.equal(
    await mobile.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth),
    true,
  );
  await mobile.screenshot({ path: screenshot, fullPage: true });
  const removeSegment = mobile.locator(".segment-chip").getByRole("link", { name: /Remove selected segment/ });
  await Promise.all([
    mobile.waitForURL((url) => url.searchParams.get("segment") === null),
    removeSegment.click(),
  ]);
  assert.equal(new URL(mobile.url()).searchParams.get("segment"), null);
  await Promise.all([
    mobile.waitForURL((url) => url.searchParams.get("segment") === segmentId),
    mobile.goBack(),
  ]);
  assert.equal(new URL(mobile.url()).searchParams.get("segment"), segmentId);
  await Promise.all([
    mobile.waitForURL((url) => url.searchParams.get("segment") === null),
    mobile.goForward(),
  ]);
  assert.equal(new URL(mobile.url()).searchParams.get("segment"), null);
  await enhanced.close();

  const recovery = await browser.newContext({ javaScriptEnabled: false });
  await recovery.addCookies([cookie]);
  const recoveryPage = await recovery.newPage();
  await recoveryPage.goto(
    `${origin}/admin/sites/alpha/overview?${range}&segment=${segmentId}`,
    { waitUntil: "load" },
  );
  const recoverySegments = recoveryPage.locator("details.management", { hasText: "Segments" });
  await recoverySegments.locator("summary").click();
  const originalSegment = recoverySegments.locator(
    ".segment-row",
    { hasText: "Two pages renamed" },
  );
  const deleteOriginal = originalSegment.locator("form[action='/admin/segments/delete']");
  await deleteOriginal.locator("input[name=name]").fill("Two pages renamed");
  await submit(recoveryPage, deleteOriginal, "Delete segment");
  response = await recoveryPage.goto(`${origin}${savedViewHref}`, { waitUntil: "load" });
  assert.equal(response.status(), 422);
  const recoveryLink = recoveryPage.getByRole("link", { name: "Return to dashboard" });
  assert.equal(
    new URL(await recoveryLink.getAttribute("href"), origin).pathname,
    "/admin/sites/alpha/analyze",
  );
  await Promise.all([
    recoveryPage.waitForNavigation({ waitUntil: "load" }),
    recoveryLink.click(),
  ]);
  const recoveryViews = recoveryPage.locator("details.management", { hasText: "Saved views" });
  await recoveryViews.locator("summary").click();
  const staleView = recoveryViews.locator("article.saved-row", { hasText: "Renamed breakdown" });
  assert.equal(await staleView.count(), 1);
  const deleteStaleView = staleView.locator("form[action='/admin/saved-views/delete']");
  await deleteStaleView.locator("input[name=name]").fill("Renamed breakdown");
  await submit(recoveryPage, deleteStaleView, "Delete");
  assert.equal(await recoveryPage.getByText("Renamed breakdown", { exact: true }).count(), 0);
  await recovery.close();
  await browser.close();

  process.stdout.write(JSON.stringify({
    engine: "chromium",
    javascript_off: "apply-remove-segment-view-crud",
    suggestions: "selection-preserved-50-plus-has-more-site-isolated",
    stale_view_recovery: "analyze-delete",
    native_context: "overview-trend-breakdown",
    row_actions: "filter-and-exclude",
    history: "back-forward",
    startup_api_requests: 0,
    mobile_width: 390,
    mobile_overflow: false,
  }) + "\n");
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
