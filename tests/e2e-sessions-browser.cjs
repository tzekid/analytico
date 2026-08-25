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
  const [origin, session, goalId, segmentId, today, desktopShot, mobileShot] =
    process.argv.slice(2);
  assert.ok(origin && session && goalId && segmentId && today && desktopShot && mobileShot);
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
  const route = (query) => `${origin}/admin/sites/quality/sessions?${query}`;
  const historical = "v=1&from=2026-01-03&to=2026-01-03&compare=none";

  const native = await browser.newContext({ javaScriptEnabled: false });
  await native.addCookies([cookie]);
  const page = await native.newPage();
  const startupRequests = [];
  page.on("request", (request) => startupRequests.push(request.resourceType()));
  let response = await page.goto(route(historical), { waitUntil: "load" });
  assert.equal(response.status(), 200);
  assert.equal(await page.evaluate(() => window.htmx), undefined);
  assert.equal(await page.getByRole("heading", { name: "Session list", exact: true }).count(), 1);
  assert.equal(await page.locator("article.session-record").count(), 5);
  const initialText = await page.locator("main").innerText();
  assert.match(initialText, /No page view/);
  assert.match(initialText, /Direct \/ Unknown/);
  assert.match(initialText, /CUSTOM EVENTS\s*1/i);
  assert.match(initialText, /Identified user/);
  assert.match(initialText, /Persistent anonymous/);
  assert.match(initialText, /Ephemeral anonymous/);
  assert.match(initialText, /Legacy daily anonymous/);
  assert.match(initialText, /user-a/);
  assert.doesNotMatch(initialText, /00000000-0000-4000-8000-0000000000a2/);
  assert.doesNotMatch(initialText, /beta-secret/);
  assert.equal(await page.locator('a[href*="/sessions/"]').count(), 0);
  assert.equal(
    startupRequests.filter((kind) => kind === "fetch" || kind === "xhr").length,
    0,
  );

  response = await page.goto(
    `${origin}/admin/sites/beta/sessions?${historical}`,
    { waitUntil: "load" },
  );
  assert.equal(response.status(), 200);
  assert.equal(await page.locator("article.session-record").count(), 1);
  assert.match(await page.locator("main").innerText(), /\/beta-secret/);
  assert.match(await page.locator("main").innerText(), /UTC\+01:00/);
  response = await page.goto(route(historical), { waitUntil: "load" });
  assert.equal(response.status(), 200);
  assert.doesNotMatch(await page.locator("main").innerText(), /beta-secret/);

  let goalForm = page.locator("form.session-goal-filter");
  await goalForm.locator('select[name="goal"]').selectOption(goalId);
  response = await nativeSubmit(page, goalForm, "Apply Goal");
  assert.equal(response.status(), 200);
  assert.equal(new URL(page.url()).searchParams.get("goal"), goalId);
  assert.equal(await page.locator("article.session-record").count(), 1);
  assert.match(await page.locator("main").innerText(), /Paid Search · google · winter/);
  assert.match(await page.locator("main").innerText(), /EUR 12\.500000/);
  assert.match(await page.locator("main").innerText(), /USD 7\.500000/);
  assert.equal(
    (await page.locator("main").innerText()).match(/1 value/g).length,
    2,
  );

  const rangeForm = page.locator("form.range-filter").first();
  await rangeForm.locator('input[name="to"]').fill("2026-01-04");
  response = await nativeSubmit(page, rangeForm, "Update context");
  assert.equal(response.status(), 200);
  assert.equal(new URL(page.url()).searchParams.get("goal"), goalId);
  assert.equal(new URL(page.url()).searchParams.get("page"), null);

  await page.locator("details.management", { hasText: "Segments" })
    .locator("summary").click();
  await Promise.all([
    page.waitForNavigation({ waitUntil: "load" }),
    page.locator(`a[href*="segment=${segmentId}"]`).click(),
  ]);
  assert.equal(new URL(page.url()).searchParams.get("segment"), segmentId);
  assert.equal(new URL(page.url()).searchParams.get("goal"), goalId);
  assert.equal(await page.locator("article.session-record").count(), 1);

  await page.locator("details.filter-builder").locator("summary").click();
  const filterForm = page.locator('form[action="/admin/filters/apply"]');
  await filterForm.locator('select[name="scope"]').selectOption("event");
  await filterForm.locator('select[name="field"]').selectOption("event-name");
  await filterForm.locator('select[name="scalar_type"]').selectOption("string");
  await filterForm.locator('select[name="operator"]').selectOption("is");
  await filterForm.locator('textarea[name="values"]').fill("purchase");
  response = await nativeSubmit(page, filterForm, "Apply filter");
  assert.equal(response.status(), 200);
  const filteredUrl = new URL(page.url());
  assert.equal(filteredUrl.searchParams.get("goal"), goalId);
  assert.equal(filteredUrl.searchParams.get("segment"), segmentId);
  assert.equal(filteredUrl.searchParams.getAll("f").length, 1);
  assert.equal(filteredUrl.searchParams.get("page"), null);
  assert.equal(await page.locator("article.session-record").count(), 1);

  response = await page.goto(
    route(`${historical}&f=session~device~is~string~mobile`),
    { waitUntil: "load" },
  );
  assert.equal(response.status(), 200);
  assert.equal(await page.locator("article.session-record").count(), 1);
  assert.match(await page.locator("main").innerText(), /mobile · Firefox/);

  response = await page.goto(
    route(`${historical}&f=person~identity-state~is~string~identified`),
    { waitUntil: "load" },
  );
  assert.equal(response.status(), 200);
  assert.equal(await page.locator("article.session-record").count(), 2);
  assert.equal(
    await page.getByText("Identified user", { exact: true }).count(),
    2,
  );

  response = await page.goto(route(historical), { waitUntil: "load" });
  assert.equal(response.status(), 200);
  goalForm = page.locator("form.session-goal-filter");
  await goalForm.locator('select[name="goal"]').selectOption("");
  response = await nativeSubmit(page, goalForm, "Apply Goal");
  assert.equal(response.status(), 200);
  assert.equal(new URL(page.url()).searchParams.get("goal"), null);

  response = await page.goto(
    route("v=1&from=2026-01-03&to=2026-01-04&compare=none"),
    { waitUntil: "load" },
  );
  assert.equal(response.status(), 200);
  const firstPageIds = await page.locator("article.session-record h3").allTextContents();
  assert.equal(firstPageIds.length, 25);
  await Promise.all([
    page.waitForNavigation({ waitUntil: "load" }),
    page.getByRole("link", { name: "Next", exact: true }).click(),
  ]);
  assert.equal(new URL(page.url()).searchParams.get("page"), "2");
  const secondPageIds = await page.locator("article.session-record h3").allTextContents();
  assert.equal(secondPageIds.length, 7);
  assert.equal(await page.getByRole("link", { name: "Previous", exact: true }).count(), 1);
  assert.equal(firstPageIds.filter((id) => secondPageIds.includes(id)).length, 0);

  response = await page.goto(
    route(`v=1&from=${today}&to=${today}&compare=none`),
    { waitUntil: "load" },
  );
  assert.equal(response.status(), 200);
  assert.equal(await page.locator("article.session-record").count(), 1);
  assert.equal(
    await page.getByText("Current · activity received within 30 minutes", {
      exact: true,
    }).count(),
    1,
  );
  assert.match(await page.locator("main").innerText(), /\/current/);

  await page.goto(route(historical), { waitUntil: "load" });
  await page.screenshot({ path: desktopShot, fullPage: true });
  await page.keyboard.press("Tab");
  assert.ok(await page.evaluate(() => document.activeElement !== document.body));
  await native.close();

  const mobile = await browser.newContext({
    javaScriptEnabled: false,
    viewport: { width: 390, height: 844 },
  });
  await mobile.addCookies([cookie]);
  const mobilePage = await mobile.newPage();
  response = await mobilePage.goto(route(historical), { waitUntil: "load" });
  assert.equal(response.status(), 200);
  assert.equal(await mobilePage.locator("article.session-record").count(), 5);
  assert.equal(
    await mobilePage.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth),
    true,
  );
  assert.equal(
    await mobilePage.locator('.mobile-navigation a[aria-current="page"]').innerText(),
    "Sessions",
  );
  await mobilePage.screenshot({ path: mobileShot, fullPage: true });
  await mobile.close();
  await browser.close();

  process.stdout.write(`${JSON.stringify({
    js_off_full_summary: true,
    goal_filter_native: true,
    date_context_preserved: true,
    universal_filter_native: true,
    person_filter_native: true,
    segment_native: true,
    stable_pagination: true,
    current_session: true,
    site_isolation: true,
    startup_data_requests: 0,
    mobile_width: 390,
    mobile_overflow: false,
    keyboard_focus: true,
  })}\n`);
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
