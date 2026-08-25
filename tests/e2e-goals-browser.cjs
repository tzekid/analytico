"use strict";

const assert = require("node:assert/strict");
const { chromium } = require("playwright");

async function nativeSubmit(page, form, label) {
  return Promise.all([
    page.waitForNavigation({ waitUntil: "load" }),
    form.getByRole("button", { name: label, exact: true }).click(),
  ]).then(([navigation]) => navigation);
}

async function main() {
  const [origin, session, archivedGoalId, referenceGoalId, desktopShot, mobileShot] =
    process.argv.slice(2);
  assert.ok(
    origin && session && archivedGoalId && referenceGoalId && desktopShot && mobileShot,
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
  const contextQuery = "from=2025-01-01&to=2025-01-02&compare=none";
  const goalRoute = (suffix = "", query = contextQuery) =>
    `${origin}/admin/sites/alpha/journeys/goals${suffix}?${query}`;

  const native = await browser.newContext({ javaScriptEnabled: false });
  await native.addCookies([cookie]);
  const page = await native.newPage();
  const startupRequests = [];
  page.on("request", (request) => startupRequests.push(request.resourceType()));
  let response = await page.goto(goalRoute(), { waitUntil: "load" });
  assert.equal(response.status(), 200);
  assert.equal(await page.evaluate(() => window.htmx), undefined);
  assert.equal(await page.getByRole("heading", { name: "Goals", exact: true }).count(), 1);
  assert.equal(await page.locator('input[name="kind"]').count(), 0);
  assert.equal(await page.getByText("Archived Purchase", { exact: true }).count(), 1);
  assert.equal(
    startupRequests.filter((kind) => kind === "fetch" || kind === "xhr").length,
    0,
  );
  response = await page.goto(goalRoute(`/${archivedGoalId}`), {
    waitUntil: "load",
  });
  assert.equal(response.status(), 200);
  assert.equal(await page.getByText("Archived", { exact: true }).count(), 1);
  assert.equal(await page.getByRole("button", { name: "Reactivate", exact: true }).count(), 1);

  response = await page.goto(goalRoute("/new", `${contextQuery}&entity=page`), {
    waitUntil: "load",
  });
  assert.equal(response.status(), 200);
  assert.equal(await page.getByRole("heading", { name: "New goal", exact: true }).count(), 1);
  let discovered = page.locator('table:has(caption:text("Observed values")) tbody tr');
  assert.equal(await discovered.count(), 50);
  const counts = await discovered.locator('td[data-label="Eligible events"]').allTextContents();
  const labels = await discovered.locator('th[data-label="Value"] code').allTextContents();
  for (let index = 1; index < counts.length; index += 1) {
    const current = Number(counts[index]);
    const prior = Number(counts[index - 1]);
    assert.ok(current <= prior);
    if (current === prior) assert.ok(labels[index].localeCompare(labels[index - 1]) >= 0);
  }
  assert.equal(
    await page.getByRole("link", { name: "Next observed values", exact: true }).count(),
    1,
  );
  await Promise.all([
    page.waitForNavigation({ waitUntil: "load" }),
    page.getByRole("link", { name: "Next observed values", exact: true }).click(),
  ]);
  assert.equal(new URL(page.url()).searchParams.get("entity-page"), "2");
  assert.ok(await discovered.count() > 0);
  assert.equal(
    await page.getByRole("link", { name: "Previous observed values", exact: true }).count(),
    1,
  );

  const discoveryForm = page.locator("form.filter-builder");
  await discoveryForm.locator('select[name="entity"]').selectOption("event");
  await discoveryForm.locator('input[name="search"]').fill("sign");
  response = await nativeSubmit(page, discoveryForm, "Search observed values");
  assert.equal(response.status(), 200);
  assert.equal(new URL(page.url()).searchParams.get("entity"), "event");
  assert.equal(new URL(page.url()).searchParams.get("search"), "sign");
  discovered = page.locator('table:has(caption:text("Observed values")) tbody tr');
  assert.equal(await discovered.count(), 1);
  assert.match(await discovered.first().innerText(), /signup/i);
  assert.doesNotMatch(await page.locator("main").innerText(), /beta-secret/);

  const segmentId = "00000000-0000-4000-8000-000000000392";
  const predicateContext = `${contextQuery}&entity=event&search=purchase&segment=${segmentId}&f=event%7Edevice%7Eis%7Estring%7Edesktop`;
  response = await page.goto(goalRoute("/new", predicateContext), {
    waitUntil: "load",
  });
  assert.equal(response.status(), 200);
  assert.match(await page.locator("main").innerText(), /segment Germany plus 1 ad-hoc filter/);
  let predicateForm = page.locator('form[action^="/admin/goals?"]');
  await predicateForm.locator('select[name="entity"]').selectOption("event");
  await predicateForm.locator('input[name="value"]').fill("purchase");
  await predicateForm.locator('input[name="name"]').fill("Pro purchases");
  await predicateForm.locator('input[name="property_1"]').fill("plan");
  await predicateForm.locator('select[name="rule_1"]').selectOption("integer:gt");
  await predicateForm.locator('input[name="predicate_value_1"]').fill("pro");
  response = await nativeSubmit(page, predicateForm, "Preview result");
  assert.equal(response.status(), 422);
  assert.match(await page.locator('[role="alert"]').innerText(), /definition was not saved/i);
  predicateForm = page.locator('form[action^="/admin/goals?"]');
  assert.equal(
    await predicateForm.locator('input[name="predicate_value_1"]').inputValue(),
    "pro",
  );
  await predicateForm.locator('select[name="rule_1"]').selectOption("string:is");
  response = await nativeSubmit(page, predicateForm, "Preview result");
  assert.equal(response.status(), 200);
  assert.match(await page.locator("main").innerText(), /has not been saved/);
  assert.equal(
    await page.locator('li.kpi:has-text("Matching events") strong').innerText(),
    "2",
  );
  assert.match(
    await page.locator("main").innerText(),
    /Legacy coverage counts daily identities only/,
  );
  assert.match(
    await page.locator('li.kpi:has-text("Converting visitors") strong').innerText(),
    /^1\/2 · 50\.00%$/,
  );
  assert.match(await page.locator("main").innerText(), /12\.500000/);
  assert.match(await page.locator("main").innerText(), /7\.500000/);
  const propertiesDisclosure = page.locator("details", {
    has: page.getByText("Observed properties for this selector", { exact: true }),
  });
  await propertiesDisclosure.locator("summary").click();
  assert.match(await propertiesDisclosure.innerText(), /plan[\s\S]*string/i);
  assert.match(await propertiesDisclosure.innerText(), /amount[\s\S]*decimal/i);
  const amountTypes = propertiesDisclosure.locator("tbody tr", {
    has: page.getByText("amount", { exact: true }),
  });
  assert.equal(await amountTypes.count(), 2);
  assert.match(await amountTypes.nth(0).innerText(), /decimal|string/);
  assert.match(await amountTypes.nth(1).innerText(), /decimal|string/);
  assert.notEqual(
    await amountTypes.nth(0).innerText(),
    await amountTypes.nth(1).innerText(),
  );
  predicateForm = page.locator('form[action^="/admin/goals?"]');
  response = await nativeSubmit(page, predicateForm, "Create goal");
  assert.equal(response.status(), 200);
  const predicateHref = await page
    .getByRole("link", { name: "Pro purchases", exact: true })
    .getAttribute("href");
  assert.equal(new URL(`${origin}${predicateHref}`).searchParams.get("segment"), segmentId);
  assert.equal(new URL(`${origin}${predicateHref}`).searchParams.getAll("f").length, 1);
  response = await page.goto(`${origin}${predicateHref}`, { waitUntil: "load" });
  assert.equal(response.status(), 200);
  assert.match(await page.locator("main").innerText(), /plan · string · is · pro/);
  assert.equal(
    await page.locator('li.kpi:has-text("Matching events") strong').innerText(),
    "2",
  );
  const predicateAnalyzeHref = await page
    .getByRole("link", { name: "Open this goal in Analyze", exact: true })
    .getAttribute("href");
  const predicateAnalyzeUrl = new URL(`${origin}${predicateAnalyzeHref}`);
  assert.equal(predicateAnalyzeUrl.searchParams.get("segment"), segmentId);
  assert.equal(predicateAnalyzeUrl.searchParams.getAll("f").length, 1);
  let predicateEditHref = await page
    .getByRole("link", { name: "Edit goal", exact: true })
    .getAttribute("href");
  response = await page.goto(predicateAnalyzeUrl.toString(), { waitUntil: "load" });
  assert.equal(response.status(), 200);
  assert.equal(
    await page
      .getByRole("heading", {
        name: "Conversions · goal Pro purchases",
        exact: true,
      })
      .count(),
    1,
  );
  response = await page.goto(`${origin}${predicateEditHref}`, { waitUntil: "load" });
  assert.equal(response.status(), 200);
  predicateForm = page.locator('form[action^="/admin/goals/edit?"]');
  assert.equal(await predicateForm.locator('input[name="property_1"]').inputValue(), "plan");
  assert.equal(await predicateForm.locator('input[name="predicate_value_1"]').inputValue(), "pro");
  await predicateForm.locator('input[name="predicate_value_1"]').fill("free");
  response = await nativeSubmit(page, predicateForm, "Preview result");
  assert.equal(response.status(), 200);
  assert.equal(
    await page.locator('li.kpi:has-text("Matching events") strong').innerText(),
    "0",
  );
  assert.equal(
    await page
      .locator('li.kpi:has-text("Persistent identity coverage") strong')
      .innerText(),
    "unavailable",
  );
  predicateForm = page.locator('form[action^="/admin/goals/edit?"]');
  await predicateForm.locator('input[name="predicate_value_1"]').fill("pro");
  response = await nativeSubmit(page, predicateForm, "Save goal");
  assert.equal(response.status(), 200);
  await page.getByRole("link", { name: "Pro purchases", exact: true }).click();
  let predicateDuplicate = page.locator('form[action^="/admin/goals/duplicate?"]');
  await predicateDuplicate.locator('input[name="name"]').fill("Pro purchases copy");
  response = await nativeSubmit(page, predicateDuplicate, "Duplicate");
  assert.equal(response.status(), 200);
  await page.getByRole("link", { name: "Pro purchases copy", exact: true }).click();
  assert.match(await page.locator("main").innerText(), /plan · string · is · pro/);

  response = await page.goto(goalRoute("/new", `${contextQuery}&entity=event&search=signup`), {
    waitUntil: "load",
  });
  assert.equal(response.status(), 200);
  let trapForm = page.locator('form[action="/admin/goals"]');
  await trapForm.locator('select[name="entity"]').selectOption("event");
  await trapForm.locator('input[name="value"]').fill("signup");
  await trapForm.locator('input[name="name"]').fill("Same-session trap");
  await trapForm.locator('input[name="property_1"]').fill("page_only");
  await trapForm.locator('select[name="rule_1"]').selectOption("string:is");
  await trapForm.locator('input[name="predicate_value_1"]').fill("yes");
  response = await nativeSubmit(page, trapForm, "Preview result");
  assert.equal(response.status(), 200);
  assert.equal(
    await page.locator('li.kpi:has-text("Matching events") strong').innerText(),
    "0",
  );

  const staleSegmentId = "00000000-0000-4000-8000-000000000393";
  const retainedFilter = "event~device~is~string~desktop";
  const retainedFilterParameter = encodeURIComponent(retainedFilter);
  response = await page.goto(
    goalRoute(
      "/new",
      `${contextQuery}&entity=event&search=signup&segment=${staleSegmentId}&f=${retainedFilterParameter}`,
    ),
    { waitUntil: "load" },
  );
  assert.equal(response.status(), 200);
  let staleContextForm = page.locator('form[action^="/admin/goals?"]');
  await staleContextForm.locator('select[name="entity"]').selectOption("event");
  await staleContextForm.locator('input[name="value"]').fill("signup");
  await staleContextForm.locator('input[name="name"]').fill("Stale segment must not save");
  await staleContextForm.locator('input[name="property_1"]').fill("plan");
  await staleContextForm.locator('select[name="rule_1"]').selectOption("string:is");
  await staleContextForm.locator('input[name="predicate_value_1"]').fill("pro");

  const segmentDeletePage = await native.newPage();
  response = await segmentDeletePage.goto(
    `${origin}/admin/sites/alpha/overview?${contextQuery}&segment=${staleSegmentId}`,
    { waitUntil: "load" },
  );
  assert.equal(response.status(), 200);
  const segmentManagement = segmentDeletePage.locator("details.management", {
    hasText: "Segments",
  });
  await segmentManagement.locator("summary").click();
  const staleSegmentRow = segmentManagement.locator(".segment-row", {
    hasText: "Stale goal race",
  });
  const segmentDeleteForm = staleSegmentRow.locator(
    'form[action="/admin/segments/delete"]',
  );
  await segmentDeleteForm.locator('input[name="name"]').fill("Stale goal race");
  response = await nativeSubmit(segmentDeletePage, segmentDeleteForm, "Delete segment");
  assert.equal(response.status(), 200);
  await segmentDeletePage.close();

  response = await nativeSubmit(page, staleContextForm, "Create goal");
  assert.equal(response.status(), 422);
  assert.match(await page.locator('[role="alert"]').innerText(), /segment became stale/i);
  assert.doesNotMatch(await page.locator("body").innerText(), /Internal Server Error/i);
  staleContextForm = page.locator('form[action^="/admin/goals?"]');
  assert.equal(
    await staleContextForm.locator('input[name="name"]').inputValue(),
    "Stale segment must not save",
  );
  assert.equal(
    await staleContextForm.locator('select[name="entity"]').inputValue(),
    "event",
  );
  assert.equal(
    await staleContextForm.locator('input[name="value"]').inputValue(),
    "signup",
  );
  assert.equal(
    await staleContextForm.locator('input[name="property_1"]').inputValue(),
    "plan",
  );
  assert.equal(
    await staleContextForm.locator('select[name="rule_1"]').inputValue(),
    "string:is",
  );
  assert.equal(
    await staleContextForm.locator('input[name="predicate_value_1"]').inputValue(),
    "pro",
  );
  const recoveredAction = new URL(await staleContextForm.getAttribute("action"), origin);
  assert.equal(recoveredAction.searchParams.get("segment"), null);
  assert.deepEqual(recoveredAction.searchParams.getAll("f"), [retainedFilter]);
  for (const label of ["All goals", "New goal"]) {
    const href = await page
      .getByRole("link", { name: label, exact: true })
      .getAttribute("href");
    const recovered = new URL(href, origin);
    assert.equal(recovered.searchParams.get("segment"), null);
    assert.deepEqual(recovered.searchParams.getAll("f"), [retainedFilter]);
  }
  assert.match(await page.locator("main").innerText(), /1 ad-hoc filter/);
  assert.doesNotMatch(await page.locator("main").innerText(), /Stale goal race/);

  response = await page.goto(goalRoute("/new", `${contextQuery}&entity=event&search=sign`), {
    waitUntil: "load",
  });
  assert.equal(response.status(), 200);
  let createForm = page.locator('form[action="/admin/goals"]');
  await createForm.locator('select[name="entity"]').selectOption("event");
  await createForm.locator('select[name="match"]').selectOption("exact");
  await createForm.locator('input[name="value"]').fill("signup");
  await createForm.locator('input[name="name"]').fill("Browser signup");
  response = await nativeSubmit(page, createForm, "Create goal");
  assert.equal(response.status(), 200);
  assert.match(page.url(), /notice=goal-added/);
  const createdHref = await page
    .getByRole("link", { name: "Browser signup", exact: true })
    .getAttribute("href");
  assert.match(createdHref, /\/journeys\/goals\/[0-9a-f-]{36}\?/);
  const createdId = createdHref.match(/\/goals\/([0-9a-f-]{36})\?/)[1];

  await page.goto(goalRoute("/new", `${contextQuery}&entity=event`), {
    waitUntil: "load",
  });
  createForm = page.locator('form[action="/admin/goals"]');
  await createForm.locator('select[name="entity"]').selectOption("event");
  await createForm.locator('input[name="value"]').fill("signup");
  await createForm.locator('input[name="name"]').fill("Browser signup");
  response = await nativeSubmit(page, createForm, "Create goal");
  assert.equal(response.status(), 422);
  assert.match(await page.locator('[role="alert"]').innerText(), /already has a goal/);
  assert.equal(
    await page.locator('form[action="/admin/goals"] input[name="name"]').inputValue(),
    "Browser signup",
  );
  const preservedDiscovery = page.locator("form.filter-builder");
  await preservedDiscovery.locator('select[name="entity"]').selectOption("event");
  await preservedDiscovery.locator('input[name="search"]').fill("down");
  response = await nativeSubmit(
    page,
    preservedDiscovery,
    "Search observed values",
  );
  assert.equal(response.status(), 200);
  assert.match(page.url(), /\/journeys\/goals\/new\?/);
  assert.equal(new URL(page.url()).searchParams.get("search"), "down");

  await page.goto(goalRoute("/new", `${contextQuery}&entity=page`), {
    waitUntil: "load",
  });
  createForm = page.locator('form[action="/admin/goals"]');
  await createForm.locator('input[name="value"]').fill("/future");
  await createForm.locator('input[name="name"]').fill("Future page");
  response = await nativeSubmit(page, createForm, "Create goal");
  assert.equal(response.status(), 422);
  assert.match(await page.locator('[role="alert"]').innerText(), /zero-seen definition/);
  createForm = page.locator('form[action="/admin/goals"]');
  assert.equal(await createForm.locator('input[name="value"]').inputValue(), "/future");
  await createForm.locator('input[name="confirm_unseen"]').check();
  response = await nativeSubmit(page, createForm, "Create goal");
  assert.equal(response.status(), 200);
  assert.equal(await page.getByRole("link", { name: "Future page", exact: true }).count(), 1);

  response = await page.goto(`${origin}${createdHref}`, { waitUntil: "load" });
  assert.equal(response.status(), 200);
  assert.equal(page.url().includes(createdId), true);
  const staleDeletePage = await native.newPage();
  response = await staleDeletePage.goto(`${origin}${createdHref}`, {
    waitUntil: "load",
  });
  assert.equal(response.status(), 200);
  let editHref = await page
    .getByRole("link", { name: "Edit goal", exact: true })
    .getAttribute("href");
  response = await page.goto(`${origin}${editHref}&search=sign`, {
    waitUntil: "load",
  });
  assert.equal(response.status(), 200);
  assert.match(page.url(), new RegExp(`/goals/${createdId}/edit`));
  let editForm = page.locator('form[action="/admin/goals/edit"]');
  assert.equal(await editForm.locator('select[name="entity"]').inputValue(), "event");
  await editForm.locator('input[name="value"]').fill("download");
  response = await nativeSubmit(page, editForm, "Save goal");
  assert.equal(response.status(), 200);

  let staleDeleteForm = staleDeletePage.locator('form[action="/admin/goals/delete"]');
  await staleDeleteForm.locator('input[name="name"]').fill("Browser signup");
  response = await nativeSubmit(staleDeletePage, staleDeleteForm, "Delete permanently");
  assert.equal(response.status(), 422);
  assert.match(
    await staleDeletePage.locator('[role="alert"]').innerText(),
    /changed after this form loaded/,
  );
  await staleDeletePage.close();

  response = await page.goto(`${origin}${createdHref}`, { waitUntil: "load" });
  assert.equal(response.status(), 200);
  editHref = await page
    .getByRole("link", { name: "Edit goal", exact: true })
    .getAttribute("href");
  response = await page.goto(`${origin}${editHref}&search=sign`, {
    waitUntil: "load",
  });
  assert.equal(response.status(), 200);
  editForm = page.locator('form[action="/admin/goals/edit"]');
  await editForm.locator('input[name="name"]').fill("Browser signup renamed");
  response = await nativeSubmit(page, editForm, "Save goal");
  assert.equal(
    response.status(),
    200,
    `${page.url()}\n${await page.locator("body").innerText()}`,
  );
  assert.equal(
    await page.getByRole("link", { name: "Browser signup renamed", exact: true }).count(),
    1,
  );
  assert.equal(
    await page.getByRole("link", { name: "Browser signup renamed", exact: true })
      .getAttribute("href")
      .then((href) => href.includes(createdId)),
    true,
  );

  await page.getByRole("link", { name: "Browser signup renamed", exact: true }).click();
  let duplicateForm = page.locator('form[action="/admin/goals/duplicate"]');
  await duplicateForm.locator('input[name="name"]').fill("Browser signup renamed");
  response = await nativeSubmit(page, duplicateForm, "Duplicate");
  assert.equal(response.status(), 422);
  duplicateForm = page.locator('form[action="/admin/goals/duplicate"]');
  assert.equal(
    await duplicateForm.locator('input[name="name"]').inputValue(),
    "Browser signup renamed",
  );
  await duplicateForm.locator('input[name="name"]').fill("Browser signup copy");
  response = await nativeSubmit(page, duplicateForm, "Duplicate");
  assert.equal(response.status(), 200);
  assert.equal(
    await page.getByRole("link", { name: "Browser signup copy", exact: true }).count(),
    1,
  );

  await page.getByRole("link", { name: "Browser signup renamed", exact: true }).click();
  response = await nativeSubmit(
    page,
    page.locator('form[action="/admin/goals/archive"]'),
    "Archive",
  );
  assert.equal(response.status(), 200);
  await page.getByRole("link", { name: "Browser signup renamed", exact: true }).click();
  assert.match(await page.locator("main").innerText(), /Archived/);
  response = await nativeSubmit(
    page,
    page.locator('form[action="/admin/goals/reactivate"]'),
    "Reactivate",
  );
  assert.equal(response.status(), 200);

  await page.getByRole("link", { name: "Browser signup copy", exact: true }).click();
  let deleteForm = page.locator('form[action="/admin/goals/delete"]');
  await deleteForm.locator('input[name="name"]').fill("Wrong confirmation");
  response = await nativeSubmit(page, deleteForm, "Delete permanently");
  assert.equal(response.status(), 422);
  assert.match(await page.locator('[role="alert"]').innerText(), /did not exactly match/);
  deleteForm = page.locator('form[action="/admin/goals/delete"]');
  await deleteForm.locator('input[name="name"]').fill("Browser signup copy");
  response = await nativeSubmit(page, deleteForm, "Delete permanently");
  assert.equal(response.status(), 200);
  assert.equal(
    await page.getByRole("link", { name: "Browser signup copy", exact: true }).count(),
    0,
  );

  response = await page.goto(goalRoute(`/${referenceGoalId}`), { waitUntil: "load" });
  assert.equal(response.status(), 200);
  deleteForm = page.locator('form[action="/admin/goals/delete"]');
  await deleteForm.locator('input[name="name"]').fill("Referenced goal");
  response = await nativeSubmit(page, deleteForm, "Delete permanently");
  assert.equal(response.status(), 409);
  assert.match(await page.locator('[role="alert"]').innerText(), /used by a saved view/);
  assert.equal(await page.getByRole("button", { name: "Archive", exact: true }).count(), 1);

  response = await page.goto(
    `${origin}/admin/sites/alpha/journeys/goals?${contextQuery}&subject=Referenced%20goal`,
    { waitUntil: "load" },
  );
  assert.equal(response.status(), 200);
  assert.match(page.url(), new RegExp(`/goals/${referenceGoalId}\\?`));

  const trend = `${origin}/admin/sites/alpha/analyze?v=1&from=2025-01-01&to=2025-01-02&compare=none&mode=trend&interval=day&series=conversions~visitor~goal~${archivedGoalId}`;
  response = await page.goto(trend, { waitUntil: "load" });
  assert.equal(response.status(), 200);
  assert.equal(
    await page.getByRole("heading", { name: "Conversions · goal Archived Purchase", exact: true }).count(),
    1,
  );
  const breakdown = `${origin}/admin/sites/alpha/analyze?v=1&from=2025-01-01&to=2025-01-02&compare=none&mode=breakdown&metric=conversions&conversion-basis=visitor&selector=goal&selector-value=${archivedGoalId}&dimension=page&interval=auto&sort=value-desc&page=1&limit=25`;
  response = await page.goto(breakdown, { waitUntil: "load" });
  assert.equal(response.status(), 200);
  assert.match(await page.locator("main").innerText(), /Archived Purchase/);

  response = await page.goto(
    `${origin}/admin/sites/alpha/overview?v=1&from=2025-01-01&to=2025-01-02&compare=none&metric=visitors`,
    { waitUntil: "load" },
  );
  assert.equal(response.status(), 200);
  const conversions = page.locator("article.answer-panel", {
    has: page.getByRole("heading", { name: "Conversions", exact: true }),
  });
  assert.match(await conversions.innerText(), /Active Signup/i);
  assert.doesNotMatch(await conversions.innerText(), /Archived Purchase/i);

  response = await page.goto(
    `${origin}/admin/sites/beta/journeys/goals?${contextQuery}`,
    { waitUntil: "load" },
  );
  assert.equal(response.status(), 200);
  assert.doesNotMatch(await page.locator("main").innerText(), /Browser signup|Referenced goal/);
  assert.match(await page.locator("main").innerText(), /32 of 32 active goals/);
  await page.getByRole("link", { name: "New goal", exact: true }).click();
  createForm = page.locator('form[action="/admin/goals"]');
  await createForm.locator('input[name="value"]').fill("/beta-secret");
  await createForm.locator('input[name="name"]').fill("Over capacity");
  response = await nativeSubmit(page, createForm, "Create goal");
  assert.equal(response.status(), 422);
  assert.match(await page.locator('[role="alert"]').innerText(), /32 active goals/);
  assert.equal(
    await createForm.locator('input[name="name"]').inputValue(),
    "Over capacity",
  );
  await page.goto(goalRoute(), { waitUntil: "load" });
  await page.screenshot({ path: desktopShot, fullPage: true });
  await native.close();

  const enhanced = await browser.newContext({ viewport: { width: 390, height: 844 } });
  await enhanced.addCookies([cookie]);
  const mobile = await enhanced.newPage();
  const enhancedRequests = [];
  mobile.on("request", (request) => enhancedRequests.push({
    type: request.resourceType(),
    method: request.method(),
    url: request.url(),
    htmx: request.headers()["hx-request"] === "true",
  }));
  response = await mobile.goto(goalRoute("/new", `${contextQuery}&entity=event`), {
    waitUntil: "load",
  });
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
  assert.equal(
    await mobile.evaluate(() => document.activeElement?.textContent),
    "Skip to main content",
  );
  createForm = mobile.locator('form[action="/admin/goals"]');
  await createForm.locator('select[name="entity"]').selectOption("event");
  await createForm.locator('input[name="value"]').fill("signup");
  await createForm.locator('input[name="name"]').fill("Enhanced double submit");
  const beforePosts = enhancedRequests.filter((request) =>
    request.method === "POST" && request.url === `${origin}/admin/goals`).length;
  await createForm.getByRole("button", { name: "Create goal", exact: true }).dblclick();
  await mobile.waitForFunction(() =>
    document.querySelector('.notice[role="status"]')?.textContent === "Goal added.",
  );
  const afterPosts = enhancedRequests.filter((request) =>
    request.method === "POST" && request.url === `${origin}/admin/goals`).length;
  assert.equal(afterPosts - beforePosts, 1);
  assert.equal(
    enhancedRequests.some((request) => request.htmx && request.method === "POST"),
    true,
  );
  await mobile.screenshot({ path: mobileShot, fullPage: true });
  await enhanced.close();
  await browser.close();

  process.stdout.write(JSON.stringify({
    native_crud: true,
    discovered_page_size: 50,
    discovery_order: "count-desc-label-asc",
    zero_seen_confirmation: true,
    typed_predicate_preview: true,
    predicate_context_preserved: true,
    predicate_event_row_semantics: true,
    exact_goal_result: true,
    predicate_edit_and_duplicate: true,
    stale_context_recovery: true,
    stable_id_after_rename: createdId,
    reference_conflict_status: 409,
    archived_trend_and_breakdown: true,
    default_active_isolation: true,
    site_isolation: true,
    active_cap_recovery: true,
    enhanced_double_submit_requests: 1,
    mobile_width: 390,
    mobile_overflow: false,
    startup_data_requests: 0,
  }) + "\n");
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
