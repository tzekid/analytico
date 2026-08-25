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
