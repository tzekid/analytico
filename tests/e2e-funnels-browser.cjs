"use strict";

const assert = require("node:assert/strict");
const { chromium } = require("playwright");

async function nativeClick(page, button) {
  return Promise.all([
    page.waitForNavigation({ waitUntil: "load" }),
    button.click(),
  ]).then(([response]) => response);
}

async function assertExactFunnelGeometry(section) {
  const percent = (numerator, denominator) => {
    const basisPoints = denominator === 0
      ? 0
      : Math.min(10000, Math.floor((numerator * 10000) / denominator));
    return `${Math.floor(basisPoints / 100)}.${String(basisPoints % 100).padStart(2, "0")}%`;
  };
  const currentCounts = (await section
    .locator('td[data-label="Current count"]')
    .allTextContents()).map(Number);
  const currentDropoffs = (await section
    .locator('td[data-label="Current drop-off before step"]')
    .allTextContents()).map(Number);
  const currentDropoffRates = await section
    .locator('td[data-label="Current drop-off rate before step"]')
    .allTextContents();
  const currentWidths = await section.locator("svg .funnel-bar").evaluateAll(
    (bars) => bars.map((bar) => Number(bar.getAttribute("width"))),
  );
  const currentLabels = await section.locator("svg .chart-value").allTextContents();
  assert.ok(currentCounts.length >= 2);
  assert.equal(currentWidths.length, currentCounts.length);
  assert.equal(currentLabels.length, currentCounts.length);
  for (let index = 0; index < currentCounts.length; index += 1) {
    const prior = index === 0 ? currentCounts[0] : currentCounts[index - 1];
    const expectedWidth = currentCounts[0] === 0
      ? 0
      : Math.floor((currentCounts[index] * 620) / currentCounts[0]);
    assert.equal(currentWidths[index], expectedWidth);
    assert.equal(currentDropoffs[index], prior - currentCounts[index]);
    assert.equal(
      currentDropoffRates[index],
      percent(prior - currentCounts[index], prior),
    );
    assert.match(currentLabels[index], new RegExp(`^${currentCounts[index]} · `));
  }

  const comparisonCells = section.locator('td[data-label="Comparison count"]');
  const comparisonCount = await comparisonCells.count();
  if (comparisonCount === 0) return;
  const comparisonCounts = (await comparisonCells.allTextContents()).map(Number);
  const comparisonDropoffs = (await section
    .locator('td[data-label="Comparison drop-off before step"]')
    .allTextContents()).map(Number);
  const comparisonDropoffRates = await section
    .locator('td[data-label="Comparison drop-off rate before step"]')
    .allTextContents();
  const comparisonWidths = await section
    .locator("svg .funnel-comparison-bar")
    .evaluateAll((bars) => bars.map((bar) => Number(bar.getAttribute("width"))));
  assert.equal(comparisonCounts.length, currentCounts.length);
  assert.equal(comparisonWidths.length, comparisonCounts.length);
  for (let index = 0; index < comparisonCounts.length; index += 1) {
    const prior = index === 0 ? comparisonCounts[0] : comparisonCounts[index - 1];
    const expectedWidth = comparisonCounts[0] === 0
      ? 0
      : Math.floor((comparisonCounts[index] * 620) / comparisonCounts[0]);
    assert.equal(comparisonWidths[index], expectedWidth);
    assert.equal(comparisonDropoffs[index], prior - comparisonCounts[index]);
    assert.equal(
      comparisonDropoffRates[index],
      percent(prior - comparisonCounts[index], prior),
    );
  }
}

async function main() {
  const [origin, session, goalId, segmentId, staleSegmentId, desktopShot, mobileShot] =
    process.argv.slice(2);
  assert.ok(
    origin && session && goalId && segmentId && staleSegmentId &&
      desktopShot && mobileShot,
  );
  const browser = await chromium.launch({
    executablePath: process.env.ANALYTICO_CHROMIUM_PATH,
    headless: true,
  });
  const cookie = {
    name: "analytico_session",
    value: session,
    url: origin,
    httpOnly: true,
    sameSite: "Strict",
  };
  const baseContext = "from=2025-01-01&to=2025-01-02&compare=none";
  const filter = "event~device~is~string~desktop";
  const contextual = `${baseContext}&segment=${segmentId}&f=${encodeURIComponent(filter)}`;
  const funnelRoute = (suffix = "", query = baseContext, site = "alpha") =>
    `${origin}/admin/sites/${site}/journeys/funnels${suffix}?${query}`;
  const goalRoute = (suffix = "", query = baseContext) =>
    `${origin}/admin/sites/alpha/journeys/goals${suffix}?${query}`;

  const native = await browser.newContext({ javaScriptEnabled: false });
  await native.addCookies([cookie]);
  const page = await native.newPage();
  const startupRequests = [];
  page.on("request", (request) => startupRequests.push(request.resourceType()));
  let response = await page.goto(funnelRoute(), { waitUntil: "load" });
  assert.equal(response.status(), 200, await page.locator("body").innerText());
  const responseBytes = [(await response.body()).length];
  assert.equal(await page.evaluate(() => window.htmx), undefined);
  assert.equal(await page.getByRole("heading", { name: "Funnels", exact: true }).count(), 1);
  assert.equal(
    startupRequests.filter((kind) => kind === "fetch" || kind === "xhr").length,
    0,
  );

  response = await page.goto(funnelRoute("/new", contextual), {
    waitUntil: "load",
  });
  assert.equal(response.status(), 200);
  responseBytes.push((await response.body()).length);
  assert.match(await page.locator("main").innerText(), /segment Germany plus 1 ad-hoc filter/);
  let form = page.locator('form.funnel-builder[action^="/admin/funnels?"]');
  assert.equal(await form.locator(".funnel-step").count(), 2);
  assert.equal(await form.getByRole("button", { name: "Remove", exact: true }).count(), 0);
  for (let count = 3; count <= 8; count += 1) {
    response = await nativeClick(
      page,
      form.getByRole("button", { name: "Add step", exact: true }),
    );
    assert.equal(response.status(), 200);
    form = page.locator("form.funnel-builder");
    assert.equal(await form.locator(".funnel-step").count(), count);
  }
  assert.equal(await form.getByRole("button", { name: "Add step", exact: true }).count(), 0);
  await form.locator('input[name="name"]').fill("Oversized draft must not save");
  const maximumPath = "/" + "x".repeat(1023);
  for (let index = 1; index <= 8; index += 1) {
    await form.locator(`select[name="step_kind_${index}"]`).selectOption("page");
    await form.locator(`input[name="step_value_${index}"]`).fill(maximumPath);
  }
  response = await nativeClick(
    page,
    form.getByRole("button", { name: "Preview funnel", exact: true }),
  );
  assert.equal(response.status(), 422);
  assert.doesNotMatch(await page.locator("body").innerText(), /Internal Server Error/i);
  assert.match(await page.locator('[role="alert"]').innerText(), /exceeds the 8 KiB stored limit/);
  assert.equal(
    await page.locator('input[name="name"]').inputValue(),
    "Oversized draft must not save",
  );
  assert.equal(await page.locator('input[name="step_value_8"]').inputValue(), maximumPath);
  form = page.locator("form.funnel-builder");
  for (let count = 7; count >= 3; count -= 1) {
    response = await nativeClick(
      page,
      form.getByRole("button", { name: "Remove", exact: true }).last(),
    );
    assert.equal(response.status(), 200);
    form = page.locator("form.funnel-builder");
    assert.equal(await form.locator(".funnel-step").count(), count);
  }

  await form.locator('input[name="name"]').fill("Checkout journey");
  await form.locator('select[name="order"]').selectOption("consecutive");
  await form.locator('select[name="scope"]').selectOption("visitors");
  await form.locator('select[name="window_seconds"]').selectOption("86400");
  await form.locator('select[name="step_kind_1"]').selectOption("page");
  await form.locator('input[name="step_value_1"]').fill("/pricing");
  await form.locator('input[name="step_property_1_1"]').fill("plan");
  await form.locator('select[name="step_rule_1_1"]').selectOption("string:is");
  await form.locator('input[name="step_predicate_value_1_1"]').fill("pro");
  await form.locator('select[name="step_kind_2"]').selectOption("event");
  await form.locator('input[name="step_value_2"]').fill("purchase");
  await form.locator('input[name="step_property_2_1"]').fill("plan");
  await form.locator('select[name="step_rule_2_1"]').selectOption("string:is");
  await form.locator('input[name="step_predicate_value_2_1"]').fill("pro");
  await form.locator('select[name="step_kind_3"]').selectOption("goal");
  response = await nativeClick(
    page,
    form.getByRole("button", { name: "Update step controls", exact: true }),
  );
  assert.equal(response.status(), 200);
  form = page.locator("form.funnel-builder");
  assert.equal(await form.locator('select[name="step_goal_3"]').count(), 1);
  await form.locator('select[name="step_goal_3"]').selectOption(goalId);
  assert.equal(await form.locator('input[name="name"]').inputValue(), "Checkout journey");
  assert.equal(await form.locator('select[name="scope"]').inputValue(), "visitors");

  response = await nativeClick(
    page,
    form.locator(".funnel-step").nth(2)
      .getByRole("button", { name: "Move up", exact: true }),
  );
  assert.equal(response.status(), 200);
  form = page.locator("form.funnel-builder");
  assert.equal(await form.locator('select[name="step_kind_2"]').inputValue(), "goal");
  response = await nativeClick(
    page,
    form.locator(".funnel-step").nth(1)
      .getByRole("button", { name: "Move down", exact: true }),
  );
  assert.equal(response.status(), 200);
  form = page.locator("form.funnel-builder");
  assert.equal(await form.locator('select[name="step_kind_3"]').inputValue(), "goal");

  response = await nativeClick(
    page,
    form.getByRole("button", { name: "Add step", exact: true }),
  );
  assert.equal(response.status(), 200);
  form = page.locator("form.funnel-builder");
  await form.locator('select[name="step_kind_4"]').selectOption("event");
  await form.locator('input[name="step_value_4"]').fill("never");
  response = await nativeClick(
    page,
    form.getByRole("button", { name: "Preview funnel", exact: true }),
  );
  assert.equal(response.status(), 200);
  responseBytes.push((await response.body()).length);
  form = page.locator("form.funnel-builder");
  const availability = await form.locator(".selector-availability").allTextContents();
  assert.equal(availability.length, 4);
  assert.match(availability[0], /1 matching event/);
  assert.match(availability[1], /2 matching event/);
  assert.match(availability[2], /0 matching event.*Zero matches/);
  assert.match(availability[3], /0 matching event.*Zero matches/);
  assert.ok(availability.every((value) => /not funnel progression/i.test(value)));
  let orderedResult = page.locator("section.funnel-ordered-result");
  assert.equal(
    await orderedResult.getByRole("heading", { name: "Ordered funnel result", exact: true }).count(),
    1,
  );
  assert.match(await orderedResult.innerText(), /Persistent visitors.*consecutive/is);
  assert.match(await orderedResult.innerText(), /none completed every step/i);
  const previewExact = orderedResult.locator("details.chart-data");
  await previewExact.locator("summary").click();
  assert.match(await previewExact.innerText(), /CURRENT PERSISTENT VISITORS/i);
  assert.match(await previewExact.innerText(), /CURRENT MEDIAN FROM PRIOR/i);
  await assertExactFunnelGeometry(orderedResult);

  response = await nativeClick(
    page,
    form.getByRole("button", { name: "Save funnel", exact: true }),
  );
  assert.equal(response.status(), 200);
  assert.match(page.url(), /notice=funnel-added/);
  const createdHref = await page
    .getByRole("link", { name: "Checkout journey", exact: true })
    .getAttribute("href");
  assert.match(createdHref, /\/journeys\/funnels\/[0-9a-f-]{36}\?/);
  const createdId = createdHref.match(/\/funnels\/([0-9a-f-]{36})\?/)[1];
  assert.equal(new URL(createdHref, origin).searchParams.get("segment"), segmentId);
  assert.deepEqual(new URL(createdHref, origin).searchParams.getAll("f"), [filter]);

  response = await page.goto(funnelRoute("/new", contextual), { waitUntil: "load" });
  assert.equal(response.status(), 200);
  form = page.locator("form.funnel-builder");
  await form.locator('input[name="name"]').fill("Checkout journey");
  response = await nativeClick(
    page,
    form.getByRole("button", { name: "Save funnel", exact: true }),
  );
  assert.equal(response.status(), 422);
  assert.match(await page.locator('[role="alert"]').innerText(), /already has a funnel/);
  assert.equal(await page.locator('input[name="name"]').inputValue(), "Checkout journey");

  response = await page.goto(`${origin}${createdHref}`, { waitUntil: "load" });
  assert.equal(response.status(), 200);
  const detailText = await page.locator("main").innerText();
  assert.match(detailText, /consecutive.*visitors.*1 day/is);
  assert.match(detailText, /plan.*string:is.*pro/is);
  orderedResult = page.locator("section.funnel-ordered-result");
  assert.equal(await orderedResult.count(), 1);
  assert.match(await orderedResult.innerText(), /Ordered funnel result/);
  const editHref = await page.getByRole("link", { name: "Edit funnel" }).getAttribute("href");
  const comparisonUrl = new URL(createdHref, origin);
  comparisonUrl.searchParams.set("compare", "previous");
  response = await page.goto(comparisonUrl.href, { waitUntil: "load" });
  assert.equal(response.status(), 200);
  orderedResult = page.locator("section.funnel-ordered-result");
  assert.match(
    await orderedResult.innerText(),
    /Comparison summary · \d{4}-\d{2}-\d{2} through \d{4}-\d{2}-\d{2}/,
  );
  assert.match(
    await orderedResult.innerText(),
    /Comparison persistent visitor step-one identities/i,
  );
  const comparisonExact = orderedResult.locator("details.chart-data");
  await comparisonExact.locator("summary").click();
  assert.match(await comparisonExact.innerText(), /COMPARISON PERSISTENT VISITORS/i);
  await assertExactFunnelGeometry(orderedResult);
  response = await page.goto(`${origin}${createdHref}`, { waitUntil: "load" });
  assert.equal(response.status(), 200);
  const staleEditPage = await native.newPage();
  response = await staleEditPage.goto(`${origin}${editHref}`, { waitUntil: "load" });
  assert.equal(response.status(), 200);
  response = await page.goto(`${origin}${editHref}`, { waitUntil: "load" });
  assert.equal(response.status(), 200);
  responseBytes.push((await response.body()).length);
  form = page.locator('form.funnel-builder[action^="/admin/funnels/edit"]');
  await form.locator('input[name="name"]').fill("Checkout journey renamed");
  response = await nativeClick(
    page,
    form.getByRole("button", { name: "Save funnel", exact: true }),
  );
  assert.equal(
    response.status(),
    200,
    `${page.url()}\n${await page.locator("body").innerText()}`,
  );
  const renamedHref = await page
    .getByRole("link", { name: "Checkout journey renamed", exact: true })
    .getAttribute("href");
  assert.ok(renamedHref.includes(createdId));
  const staleEditForm = staleEditPage.locator("form.funnel-builder");
  response = await nativeClick(
    staleEditPage,
    staleEditForm.getByRole("button", { name: "Add step", exact: true }),
  );
  assert.equal(response.status(), 422);
  assert.match(await staleEditPage.locator('[role="alert"]').innerText(), /changed after this form loaded/);
  assert.equal(
    await staleEditPage.locator('input[name="name"]').inputValue(),
    "Checkout journey",
  );
  await staleEditPage.close();

  response = await page.goto(goalRoute(`/${goalId}`), { waitUntil: "load" });
  assert.equal(response.status(), 200);
  let deleteGoal = page.locator('form[action="/admin/goals/delete"]');
  await deleteGoal.locator('input[name="name"]').fill("Active Signup");
  response = await nativeClick(
    page,
    deleteGoal.getByRole("button", { name: "Delete permanently", exact: true }),
  );
  assert.equal(response.status(), 409);
  assert.match(await page.locator('[role="alert"]').innerText(), /saved view or funnel/);
  response = await nativeClick(
    page,
    page.locator('form[action="/admin/goals/archive"]')
      .getByRole("button", { name: "Archive", exact: true }),
  );
  assert.equal(response.status(), 200);

  response = await page.goto(`${origin}${renamedHref}`, { waitUntil: "load" });
  assert.equal(response.status(), 200);
  assert.match(await page.locator("main").innerText(), /stale Goal reference/);
  const staleEdit = await page.getByRole("link", { name: "Edit funnel" }).getAttribute("href");
  response = await page.goto(`${origin}${staleEdit}`, { waitUntil: "load" });
  form = page.locator("form.funnel-builder");
  response = await nativeClick(
    page,
    form.getByRole("button", { name: "Preview funnel", exact: true }),
  );
  assert.equal(response.status(), 422);
  assert.match(await page.locator('[role="alert"]').innerText(), /archived or unavailable/);
  assert.equal(await page.locator('input[name="name"]').inputValue(), "Checkout journey renamed");
  response = await page.goto(goalRoute(`/${goalId}`), { waitUntil: "load" });
  response = await nativeClick(
    page,
    page.locator('form[action="/admin/goals/reactivate"]')
      .getByRole("button", { name: "Reactivate", exact: true }),
  );
  assert.equal(response.status(), 200);

  response = await page.goto(`${origin}${renamedHref}`, { waitUntil: "load" });
  response = await nativeClick(
    page,
    page.locator('form[action^="/admin/funnels/archive"]')
      .getByRole("button", { name: "Archive", exact: true }),
  );
  assert.equal(response.status(), 200);
  await page.getByRole("link", { name: "Checkout journey renamed", exact: true }).click();
  assert.match(await page.locator("main").innerText(), /Archived/);
  response = await nativeClick(
    page,
    page.locator('form[action^="/admin/funnels/reactivate"]')
      .getByRole("button", { name: "Reactivate", exact: true }),
  );
  assert.equal(response.status(), 200);

  const staleQuery = `${baseContext}&segment=${staleSegmentId}&f=${encodeURIComponent(filter)}`;
  response = await page.goto(funnelRoute("/new", staleQuery), { waitUntil: "load" });
  form = page.locator("form.funnel-builder");
  await form.locator('input[name="name"]').fill("Stale segment must not save");
  await form.locator('input[name="step_value_1"]').fill("/pricing");
  await form.locator('input[name="step_value_2"]').fill("signup");
  const staleStructuralPage = await native.newPage();
  response = await staleStructuralPage.goto(funnelRoute("/new", staleQuery), {
    waitUntil: "load",
  });
  assert.equal(response.status(), 200);
  let staleStructuralForm = staleStructuralPage.locator("form.funnel-builder");
  await staleStructuralForm.locator('input[name="name"]').fill("Stale structural draft");
  const deletePage = await native.newPage();
  response = await deletePage.goto(
    `${origin}/admin/sites/alpha/overview?${baseContext}&segment=${staleSegmentId}`,
    { waitUntil: "load" },
  );
  assert.equal(response.status(), 200);
  const management = deletePage.locator("details.management", { hasText: "Segments" });
  await management.locator("summary").click();
  const row = management.locator(".segment-row", { hasText: "Stale funnel race" });
  const deleteForm = row.locator('form[action="/admin/segments/delete"]');
  await deleteForm.locator('input[name="name"]').fill("Stale funnel race");
  response = await nativeClick(
    deletePage,
    deleteForm.getByRole("button", { name: "Delete segment", exact: true }),
  );
  assert.equal(response.status(), 200);
  await deletePage.close();

  response = await nativeClick(
    staleStructuralPage,
    staleStructuralForm.getByRole("button", { name: "Add step", exact: true }),
  );
  assert.equal(response.status(), 422);
  assert.doesNotMatch(
    await staleStructuralPage.locator("body").innerText(),
    /Internal Server Error/i,
  );
  staleStructuralForm = staleStructuralPage.locator("form.funnel-builder");
  assert.equal(
    await staleStructuralForm.locator('input[name="name"]').inputValue(),
    "Stale structural draft",
  );
  assert.equal(
    new URL(await staleStructuralForm.getAttribute("action"), origin)
      .searchParams.get("segment"),
    null,
  );
  await staleStructuralPage.close();

  response = await nativeClick(
    page,
    form.getByRole("button", { name: "Save funnel", exact: true }),
  );
  assert.equal(response.status(), 422);
  assert.doesNotMatch(await page.locator("body").innerText(), /Internal Server Error/i);
  assert.match(await page.locator('[role="alert"]').innerText(), /segment became stale/i);
  form = page.locator("form.funnel-builder");
  assert.equal(await form.locator('input[name="name"]').inputValue(), "Stale segment must not save");
  assert.equal(await form.locator('input[name="step_value_1"]').inputValue(), "/pricing");
  assert.equal(await form.locator('input[name="step_value_2"]').inputValue(), "signup");
  const recoveredAction = new URL(await form.getAttribute("action"), origin);
  assert.equal(recoveredAction.searchParams.get("segment"), null);
  assert.deepEqual(recoveredAction.searchParams.getAll("f"), [filter]);
  for (const label of ["All funnels", "New funnel"]) {
    const href = await page.getByRole("link", { name: label, exact: true }).getAttribute("href");
    const recovered = new URL(href, origin);
    assert.equal(recovered.searchParams.get("segment"), null);
    assert.deepEqual(recovered.searchParams.getAll("f"), [filter]);
  }
  assert.match(await page.locator("main").innerText(), /1 ad-hoc filter/);
  assert.doesNotMatch(await page.locator("main").innerText(), /Stale funnel race/);

  response = await page.goto(funnelRoute("", baseContext, "beta"), { waitUntil: "load" });
  assert.equal(response.status(), 200);
  assert.doesNotMatch(await page.locator("main").innerText(), /Checkout journey/);
  response = await page.goto(funnelRoute(), { waitUntil: "load" });
  await page.screenshot({ path: desktopShot, fullPage: true });
  await native.close();

  const enhanced = await browser.newContext({ viewport: { width: 390, height: 844 } });
  await enhanced.addCookies([cookie]);
  const mobile = await enhanced.newPage();
  const enhancedRequests = [];
  mobile.on("request", (request) => enhancedRequests.push({
    type: request.resourceType(),
    method: request.method(),
    htmx: request.headers()["hx-request"] === "true",
  }));
  response = await mobile.goto(funnelRoute("/new"), { waitUntil: "load" });
  assert.equal(response.status(), 200);
  await mobile.waitForFunction(() => window.htmx !== undefined);
  assert.equal(
    enhancedRequests.filter((request) =>
      request.type === "fetch" || request.type === "xhr").length,
    0,
  );
  assert.equal(
    await mobile.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth),
    true,
  );
  await mobile.keyboard.press("Tab");
  assert.equal(await mobile.evaluate(() => document.activeElement?.textContent), "Skip to main content");
  const mobileForm = mobile.locator("form.funnel-builder");
  await mobileForm.getByRole("button", { name: "Add step", exact: true }).click();
  await mobile.waitForFunction(() => document.querySelectorAll(".funnel-step").length === 3);
  assert.equal(
    enhancedRequests.some((request) => request.htmx && request.method === "POST"),
    true,
  );
  response = await mobile.goto(`${origin}${renamedHref}`, { waitUntil: "load" });
  assert.equal(response.status(), 200);
  assert.equal(await mobile.locator("section.funnel-ordered-result").count(), 1);
  await mobile.locator("section.funnel-ordered-result details.chart-data summary").click();
  assert.match(
    await mobile.locator("section.funnel-ordered-result details.chart-data").innerText(),
    /CURRENT PERSISTENT VISITORS/i,
  );
  assert.equal(
    await mobile.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth),
    true,
  );
  await mobile.screenshot({ path: mobileShot, fullPage: true });
  await enhanced.close();
  await browser.close();

  process.stdout.write(JSON.stringify({
    native_builder: true,
    step_bounds: "2-8",
    oversized_definition_recovery: true,
    settings_and_reorder: true,
    predicate_goal_and_zero_preview: true,
    ordered_result: true,
    stable_id_after_edit: createdId,
    goal_reference_conflict: true,
    stale_goal_recovery: true,
    archive_reactivate: true,
    stale_context_recovery: true,
    site_isolation: true,
    enhanced_equivalent: true,
    mobile_width: 390,
    mobile_overflow: false,
    startup_data_requests: 0,
    maximum_response_bytes: Math.max(...responseBytes),
  }) + "\n");
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
