// The workspace's speed and smoothness features end to end: group commit
// under concurrent batches, engagement on page views, Server-Timing, API
// revalidation, live updates over server-sent events, the lazy insights
// card, hover/touch/range prefetching, instant back/forward with scroll
// restore, in-place page morphing, remembered views, undoable deletes,
// keyboard shortcuts and chart drill-down.
import assert from "node:assert/strict";
import { createHash, randomUUID } from "node:crypto";
import { setTimeout as delay } from "node:timers/promises";
import { journey } from "./harness.mjs";

await journey("ux", async (t) => {
  const siteOrigin = "https://ux.example";
  const base = `http://localhost:${t.port}`;
  const setupLink = t.init(base);
  const added = t.cli("site", "add", "ux", siteOrigin, "--mode", "session");
  const site = /public_id=([^ ]+)/.exec(added)[1];
  t.cli("goal", "add", "ux", "signed-up", "event", "signup");

  // Another website: two steady weeks, then a spike from Hacker News
  // yesterday, written straight into SQLite before the server starts.
  t.cli("site", "add", "spike", "https://spike.example", "--mode", "session");
  t.cli("site", "add", "fresh", "https://fresh.example", "--mode", "session");
  {
    const seed = t.db("analytico.db", {});
    const insert = seed.prepare(`INSERT INTO page_views(site_id,event_id,page_id,session_id,occurred_at_ms,received_at_ms,received_date,visitor_day_id,tracking_mode,path,referrer_host,
      viewport_class,language,tracker_version,consent_mode,internal,country,browser,operating_system,device,traffic_class) VALUES((SELECT id FROM sites WHERE slug='spike'),?,?,?,?,?,?,?,'session',?,?,'desktop','en','1','analytics',0,'DE','chrome','linux','desktop','human_like')`);
    const today = Date.now() - Date.now() % 86_400_000;
    for (let day = 1; day <= 15; day++) {
      const views = day === 1 ? 150 : 20;
      for (let index = 0; index < views; index++) {
        const at = today - day * 86_400_000 + 3_600_000 + index * 1000;
        const spike = day === 1;
        insert.run(randomUUID(), randomUUID(), randomUUID(), at, at, new Date(at).toISOString().slice(0, 10), randomUUID().replaceAll("-", "").slice(0, 16), spike ? "/blog/x" : "/", spike ? "news.ycombinator.com" : "www.google.com");
      }
    }
    seed.close();
  }
  await t.serve();
  const db = t.db();
  const row = (sql, ...args) => db.prepare(sql).get(...args);

  // ---------------------------------------------------------------- ingest

  const record = (type, page, session, extra) => ({ event_id: randomUUID(), type, page_id: page, session_id: session, occurred_at_ms: Date.now(), tracking_mode: "session", consent_mode: "analytics", tracker_version: "1", release_id: "", internal: false, ...extra });
  const pageView = (page, session, path, extra = {}) => record("page_view", page, session, { path, navigation_type: "navigate", viewport_class: "desktop", language: "en", ...extra });
  const summary = (page, session, active) => record("page_summary", page, session, { visible_ms: active + 2000, active_ms: active, interaction_count: 2, max_scroll: 80, sections: [], selection_count: 0, copy_count: 0, outbound_clicks: 0, downloads: 0, form_attempts: 0 });
  const send = (records, ip = "198.51.100.7", origin = siteOrigin) => fetch(`${base}/e`, {
    method: "POST",
    body: JSON.stringify({ v: 1, site, sent_at_ms: Date.now(), records }),
    headers: { origin, "content-type": "text/plain", "x-forwarded-for": ip, "user-agent": "Mozilla/5.0 (X11; Linux x86_64) Chrome/140 Safari/537.36" },
  });

  // Group commit: concurrent batches all land, a bad one is refused alone,
  // and a repeated batch counts as duplicates.
  const batches = Array.from({ length: 40 }, (_, index) => {
    const page = randomUUID();
    const session = randomUUID();
    return [pageView(page, session, ["/", "/pricing", "/docs", "/blog"][index % 4]), summary(page, session, 4000 + index * 100)];
  });
  const statuses = await Promise.all([
    ...batches.map((records, index) => send(records, `198.51.100.${index + 10}`).then((response) => response.status)),
    send([pageView(randomUUID(), randomUUID(), "/evil")], "198.51.100.200", "https://evil.example").then((response) => response.status),
  ]);
  assert.deepEqual(statuses.slice(0, 40), Array(40).fill(204));
  assert.equal(statuses[40], 403);
  assert.equal(row("SELECT count(*) n FROM page_views WHERE site_id=(SELECT id FROM sites WHERE slug='ux')").n, 40);
  assert.equal((await send(batches[0])).status, 204);
  assert.equal(row("SELECT count(*) n FROM page_views WHERE site_id=(SELECT id FROM sites WHERE slug='ux')").n, 40);
  assert.equal(row("SELECT value FROM ingest_counters WHERE name='duplicate_records'").value, 2);
  assert.equal(row("SELECT value FROM ingest_counters WHERE name='invalid_origins'").value, 1);

  // Engagement lands on the page view, whichever arrives first.
  assert.equal(row("SELECT count(*) n FROM page_views WHERE site_id=(SELECT id FROM sites WHERE slug='ux') AND active_ms IS NOT NULL").n, 40);
  const late = randomUUID();
  const lateSession = randomUUID();
  assert.equal((await send([summary(late, lateSession, 9000)])).status, 204);
  assert.equal((await send([pageView(late, lateSession, "/late")])).status, 204);
  assert.deepEqual({ ...row("SELECT active_ms,max_scroll,interaction_count FROM page_views WHERE page_id=?", late) }, { active_ms: 9000, max_scroll: 80, interaction_count: 2 });

  // ---------------------------------------------------------------- the owner

  const context = await t.context();
  const page = await t.signUp(context, setupLink);
  await page.waitForURL(`${base}/ux`);
  // ---------------------------------------------------------------- headers

  const apiToken = `an_${"c".repeat(64)}`;
  const writer = t.db("analytico.db", {});
  writer.prepare("INSERT INTO api_keys(name,token_hash,prefix,user_id,site_id,created_at_ms) VALUES('ux',?,'cccc',(SELECT min(id) FROM users),NULL,?)").run(createHash("sha256").update(apiToken).digest("hex"), Date.now());
  writer.close();
  const bearer = { authorization: `Bearer ${apiToken}` };
  const first = await fetch(`${base}/api/v1/sites/ux/overview?range=7d`, { headers: bearer });
  assert.equal(first.status, 200);
  const tag = first.headers.get("etag");
  assert.ok(tag);
  assert.equal(first.headers.get("cache-control"), "private, no-cache");
  const again = await fetch(`${base}/api/v1/sites/ux/overview?range=7d`, { headers: { ...bearer, "if-none-match": tag } });
  assert.equal(again.status, 304);
  assert.equal((await again.text()).length, 0);
  assert.match(first.headers.get("server-timing"), /db;dur=[\d.]+;desc="\d+ statements", prefetch;dur=[\d.]+.*app;dur=[\d.]+/);

  const requests = [];
  page.on("request", (request) => requests.push(request.url()));
  const requested = (fragment) => requests.some((url) => url.includes(fragment));

  // The overview's queries ran in parallel, and the page says how long they took.
  const overview = await page.request.get(`${base}/ux`);
  assert.match(overview.headers()["server-timing"], /prefetch;dur=/);

  // Live updates: a new visitor shows in the badge without a reload.
  await page.goto(`${base}/ux`);
  const badge = page.locator("[data-live]");
  await badge.waitFor();
  await page.evaluate(() => { window.sameDocument = true; });
  const online = Number((await badge.textContent()).split(" ")[0]);
  await send([pageView(randomUUID(), randomUUID(), "/fresh")], "198.51.100.250");
  await t.until(async () => Number((await badge.textContent()).split(" ")[0]) === online + 1, "badge updated live");
  assert.equal(await page.evaluate(() => window.sameDocument), true);

  // The Live page counts people as they arrive and lists their page views,
  // without a reload; the old Sessions tab leads there.
  await page.goto(`${base}/ux/sessions?tab=live`);
  await page.waitForURL(`${base}/ux/live`);
  await page.evaluate(() => { window.sameDocument = true; });
  const liveCount = page.locator(".live-count");
  const present = Number(await liveCount.textContent());
  await send([pageView(randomUUID(), randomUUID(), "/arriving")], "198.51.100.251");
  await t.until(async () => Number(await liveCount.textContent()) === present + 1, "live page updated");
  await page.locator(".feed-path", { hasText: "/arriving" }).waitFor();
  await page.locator("#live-now .rank", { hasText: "/arriving" }).waitFor();
  assert.equal(await page.locator(".sidebar [data-live-count]").textContent(), String(present + 1));
  assert.equal(await page.evaluate(() => window.sameDocument), true);

  // The insights card loads on its own, after the page.
  await page.goto(`${base}/ux`);
  await page.locator("[data-lazy][data-ready]").waitFor({ state: "attached" });
  assert.ok(requested("part=insights"));

  // Hover prefetches; the click then needs no request of its own.
  const pagesLink = page.locator("a.nav", { hasText: "Pages" });
  await pagesLink.hover();
  await t.until(() => requested("/ux/pages"), "hover prefetch");
  const before = requests.filter((url) => url.includes("/ux/pages")).length;
  // Morphing keeps unchanged elements: the sidebar node survives navigation.
  await page.evaluate(() => { document.querySelector(".sidebar").marker = "kept"; });
  await pagesLink.click();
  await page.waitForURL(/\/ux\/pages/);
  await page.locator("h1", { hasText: "Pages" }).waitFor();
  assert.equal(requests.filter((url) => url.includes("/ux/pages")).length, before);
  assert.equal(await page.evaluate(() => document.querySelector(".sidebar").marker), "kept");

  // Live search keeps focus while results update in place.
  const search = page.locator("[data-live-search] input[name=q]");
  await search.fill("doc");
  await page.locator("td", { hasText: "/docs" }).first().waitFor();
  await t.until(async () => !(await page.locator("td", { hasText: "/pricing" }).count()), "search filtered");
  assert.equal(await page.evaluate(() => document.activeElement?.getAttribute("name")), "q");

  // Hovering the date range fetches every option.
  await page.locator(".seg[aria-label='Date range']").hover();
  await t.until(() => requested("range=30d") && requested("range=90d") && requested("range=24h"), "range options prefetched");

  // Back is instant and restores the scroll position.
  await page.setViewportSize({ width: 1280, height: 320 });
  await page.goto(`${base}/ux/pages?range=30d`);
  await page.evaluate(() => window.scrollTo(0, 400));
  const scrolled = await page.evaluate(() => scrollY);
  assert.ok(scrolled > 100);
  await page.locator("a.nav", { hasText: "Audience" }).click();
  await page.locator("h1", { hasText: "Audience" }).waitFor();
  const backAt = Date.now();
  await page.goBack();
  await page.locator("h1", { hasText: "Pages" }).waitFor();
  assert.ok(Date.now() - backAt < 1500);
  await t.until(async () => Math.abs((await page.evaluate(() => scrollY)) - scrolled) < 5, "scroll restored");
  await page.setViewportSize({ width: 1280, height: 900 });

  // Each website opens the way it was last viewed (30 days here), also on a
  // full load; going back to the default forgets it.
  await page.goto(`${base}/settings/sites?site=ux`);
  await page.locator("a.nav", { hasText: "Overview" }).click();
  await page.waitForURL(/\/ux\?.*range=30d/);
  await page.goto(`${base}/ux/audience`);
  await page.waitForURL(/range=30d/);
  assert.equal(await page.locator(".seg[aria-label='Date range'] a[aria-current]").textContent(), "30d");
  await page.locator(".seg[aria-label='Date range'] a", { hasText: "7d" }).click();
  await t.until(async () => (await page.locator(".seg[aria-label='Date range'] a[aria-current]").textContent()) === "7d", "back to 7 days");
  await page.goto(`${base}/ux/audience`);
  assert.equal(await page.locator(".seg[aria-label='Date range'] a[aria-current]").textContent(), "7d");
  assert.doesNotMatch(page.url(), /range=/);

  // Touch: the press itself starts the fetch.
  const touchContext = await t.context({ hasTouch: true, viewport: { width: 390, height: 844 }, storageState: await context.storageState() });
  const phone = await touchContext.newPage();
  const phoneRequests = [];
  phone.on("request", (request) => phoneRequests.push(request.url()));
  await phone.goto(`${base}/ux`);
  await phone.locator("a[href^='/ux/sessions']").first().dispatchEvent("touchstart");
  await t.until(() => phoneRequests.some((url) => url.includes("/ux/sessions")), "touch prefetch");

  // Phones: the site switcher and the period open as bottom sheets, and
  // every section without a tab is under More.
  await phone.getByRole("button", { name: "Switch website" }).locator("visible=true").click();
  await phone.locator("#site-menu.as-sheet").getByRole("link", { name: /Add a website/ }).waitFor();
  await phone.keyboard.press("Escape");
  await phone.getByRole("button", { name: "Choose dates" }).click();
  assert.equal(await phone.locator("[popover].as-sheet:popover-open").count(), 1);
  await phone.keyboard.press("Escape");
  await phone.locator(".tabbar").getByRole("link", { name: "More" }).click();
  await phone.waitForURL(`${base}/ux/more`);
  assert.equal(await phone.locator(".tabbar [aria-current]").textContent(), "More");
  await phone.locator(".more-list").getByRole("link", { name: "Funnels" }).click();
  await phone.waitForURL(/\/ux\/funnels/);
  assert.equal(await phone.locator(".tabbar [aria-current]").textContent(), "More");
  await phone.locator(".tabbar").getByRole("link", { name: "Live" }).click();
  await phone.waitForURL(`${base}/ux/live`);
  const overflow = await phone.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
  assert.equal(overflow, 0);

  {
    // A finger reads the chart instead of opening a day: a tap shows the value
    // and offers the day, a sideways drag scrubs, and a pull closes a sheet.
    const cdp = await touchContext.newCDPSession(phone);
    const touch = (type, points) => cdp.send("Input.dispatchTouchEvent", { type, touchPoints: points.map(([x, y]) => ({ x, y })) });
    const drag = async (from, to, steps = 12) => {
      await touch("touchStart", [from]);
      for (let i = 1; i <= steps; i++) {
        await touch("touchMove", [[from[0] + ((to[0] - from[0]) * i) / steps, from[1] + ((to[1] - from[1]) * i) / steps]]);
        await delay(16);
      }
      await touch("touchEnd", []);
    };
    await phone.goto(`${base}/spike?range=30d`);
    const plot = phone.locator(".chart-card .chart-plot");
    await plot.scrollIntoViewIfNeeded();
    const area = await plot.boundingBox();
    await touch("touchStart", [[area.x + area.width * 0.3, area.y + area.height / 2]]);
    await touch("touchEnd", []);
    await phone.locator(".chart-card .chart.pinned .chart-open").waitFor();
    assert.equal(new URL(phone.url()).searchParams.get("range"), "30d");
    const before = await phone.locator(".chart-card .chart-tip small").textContent();
    await drag([area.x + area.width * 0.3, area.y + area.height / 2], [area.x + area.width * 0.8, area.y + area.height / 2]);
    assert.notEqual(await phone.locator(".chart-card .chart-tip small").textContent(), before);
    const open = await phone.locator(".chart-card .chart-open").boundingBox();
    await touch("touchStart", [[open.x + open.width / 2, open.y + open.height / 2]]);
    await touch("touchEnd", []);
    await phone.waitForURL(/range=custom/);
    await phone.goto(`${base}/spike/pages?range=30d`);
    await phone.locator("tbody tr a").first().click();
    const sheet = phone.locator("dialog.sheet[open]");
    await sheet.waitFor();
    // Page details open at half height over the list, which stays usable.
    const height = async () => (await sheet.boundingBox()).height / 844;
    assert.ok(Math.abs((await height()) - 0.56) < 0.03, String(await height()));
    assert.equal(await sheet.evaluate((node) => node.matches(":modal")), false);
    const head = await phone.locator("dialog.sheet .sheet-head").boundingBox();
    await drag([head.x + head.width / 2, head.y + 20], [head.x + head.width / 2, head.y + 60], 4);
    await delay(300);
    assert.equal(await sheet.isVisible(), true);
    await drag([head.x + head.width / 2, head.y + 30], [head.x + head.width / 2, head.y - 220], 10);
    await t.until(async () => Math.abs((await height()) - 0.92) < 0.03, "sheet expanded");
    const top = await phone.locator("dialog.sheet .sheet-head").boundingBox();
    await drag([top.x + top.width / 2, top.y + 20], [top.x + top.width / 2, top.y + 180], 8);
    await t.until(async () => Math.abs((await height()) - 0.56) < 0.03, "sheet back to half");
    await drag([head.x + head.width / 2, head.y + 20], [head.x + head.width / 2, head.y + 560]);
    await phone.waitForURL((url) => !url.searchParams.has("page"));
    assert.equal(await phone.locator("dialog.sheet[open]").count(), 0);
    // Closing went back a step: Back now leaves Pages instead of reopening the sheet.
    await phone.goBack();
    await phone.waitForURL((url) => !url.pathname.endsWith("/pages"));
    assert.equal(await phone.locator("dialog.sheet[open]").count(), 0);
    // A filter from a row out of sight of its chip says so, and Undo takes it back.
    await phone.goto(`${base}/spike?range=30d`);
    const source = phone.locator(".rank-row").first();
    await source.scrollIntoViewIfNeeded();
    await phone.evaluate(() => scrollBy(0, 200));
    const spot = await source.boundingBox();
    await touch("touchStart", [[spot.x + spot.width / 2, spot.y + spot.height / 2]]);
    await touch("touchEnd", []);
    const notice = phone.locator("#toasts .toast[data-filter]");
    await notice.waitFor();
    assert.match(await notice.textContent(), /^Every report now shows source is /);
    await notice.getByRole("button", { name: "Undo" }).click();
    await phone.waitForURL((url) => !url.searchParams.has("f"));
    // The tab you're on, tapped again, scrolls to the top.
    await phone.goto(`${base}/spike/pages?range=30d`);
    await phone.evaluate(() => scrollTo(0, 600));
    await phone.locator(".tabbar a[aria-current]").click();
    await t.until(() => phone.evaluate(() => scrollY === 0), "scrolled to the top");
  }
  await touchContext.close();

  // The daily check drafted a note for the spike; kept, it joins the chart.
  await t.until(() => row("SELECT count(*) n FROM annotations WHERE draft=1").n === 1, "anomaly drafted", 20000);
  await page.goto(`${base}/spike?range=30d`);
  const draft = page.locator("[data-draft-note]");
  await draft.getByText("Traffic 7.5× usual, mostly from Hacker News").waitFor();
  await draft.getByRole("button", { name: "Keep as a note" }).click();
  await page.locator(".toast", { hasText: "Note kept on the chart." }).waitFor();
  await t.until(async () => (await draft.count()) === 0, "draft gone");
  assert.equal(row("SELECT count(*) n FROM annotations WHERE draft=0").n, 1);

  // Undo: a deleted goal comes back; left alone, the delete goes through.
  await page.goto(`${base}/ux/events?tab=goals`);
  const goalRow = page.locator("tr", { hasText: "signed-up" });
  await goalRow.getByRole("button", { name: /Delete/ }).click();
  await page.locator(".toast", { hasText: "Goal deleted" }).getByRole("button", { name: "Undo" }).click();
  await goalRow.waitFor();
  await delay(5500);
  assert.equal(row("SELECT count(*) n FROM goals").n, 1);
  await goalRow.getByRole("button", { name: /Delete/ }).click();
  await page.locator(".toast", { hasText: "Goal deleted" }).waitFor();
  await t.until(() => row("SELECT count(*) n FROM goals").n === 0, "goal deleted after the undo window", 9000);

  // Keyboard: g then p opens Pages, [ shortens the range, ? lists the keys.
  await page.goto(`${base}/ux?range=30d`);
  await page.keyboard.press("g");
  await page.keyboard.press("p");
  await page.waitForURL(/\/ux\/pages/);
  await page.keyboard.press("[");
  await t.until(async () => (await page.locator(".seg[aria-label='Date range'] a[aria-current]").textContent()) === "7d", "range shortened");
  await page.keyboard.press("?");
  await page.locator("#shortcuts", { hasText: "Keyboard shortcuts" }).waitFor();
  await page.keyboard.press("Escape");

  // Clicking a day on the trend chart opens that day.
  await page.goto(`${base}/ux`);
  const plot = page.locator(".chart-card .chart-plot");
  const box = await plot.boundingBox();
  await page.mouse.move(box.x + box.width - 2, box.y + box.height / 2);
  await page.mouse.down();
  await page.mouse.up();
  await page.waitForURL(/range=custom&from=\d{4}-\d{2}-\d{2}&to=\d{4}-\d{2}-\d{2}/);
  // That day is today: hour by hour, the running hour a "now" band, and
  // every label says what it is.
  const today = new Date().toISOString().slice(0, 10);
  assert.match(page.url(), new RegExp(`from=${today}&to=${today}`));
  const todayChart = JSON.parse(await page.locator(".chart-card .chart").getAttribute("data-chart"));
  assert.equal(todayChart.v.length, 24);
  assert.equal(todayChart.n, new Date().getUTCHours());
  assert.equal(await page.locator(".chart-card .now-band").count(), 1);
  assert.match(await page.locator(".subtitle").first().textContent(), /^Today so far, until \d\d:\d\d/);
  assert.equal((await page.locator(".seg .range-dates").textContent()).trim(), "Today");
  assert.deepEqual(await page.locator(".chart-card .legend span").allTextContents(), ["Today", "Yesterday"]);
  assert.equal((await page.locator(".metric-label").first().textContent()).trim(), "Visitors");

  // A past day: hourly, named, against the day before.
  const day = (offset) => new Date(Date.now() - offset * 86_400_000).toISOString().slice(0, 10);
  await page.goto(`${base}/spike?range=custom&from=${day(1)}&to=${day(1)}`);
  const pastChart = JSON.parse(await page.locator(".chart-card .chart").getAttribute("data-chart"));
  assert.deepEqual([pastChart.v.length, pastChart.n, pastChart.pl.length], [24, undefined, 24]);
  assert.match(await page.locator(".subtitle").first().textContent(), /, hour by hour · compared with \w{3} \d+ \w{3}$/);
  assert.match(await page.locator(".metric-delta").first().textContent(), /[%×]vs [\d,]+$/);
  assert.match(await page.locator(".chart-card .insight").textContent(), /^\d\d:00 was the busiest hour/);
  assert.equal(await page.getByRole("button", { name: "Comparing" }).getAttribute("aria-pressed"), "true");

  // Reversed dates are swapped and said so, not silently replaced.
  await page.goto(`${base}/spike?range=custom&from=${day(3)}&to=${day(10)}`);
  await page.waitForURL(new RegExp(`from=${day(10)}&to=${day(3)}`));
  await page.locator(".toast", { hasText: "wrong way round" }).waitFor();

  // A period before tracking started, and filters that match nothing.
  await page.goto(`${base}/spike?range=custom&from=2025-01-01&to=2025-01-31`);
  assert.equal(await page.locator("[data-stage=calendar] h2").textContent(), "No visits between 1 and 31 Jan 2025");
  assert.match(await page.locator("[data-stage=calendar]").textContent(), /before tracking started/);
  assert.equal(await page.locator(".metrics").count(), 0);
  await page.goto(`${base}/spike?range=30d&f=country:ZZ`);
  assert.equal(await page.locator("[data-stage=filter] h2").textContent(), "No visits match these filters");
  assert.equal(await page.locator(".controls .btn-label", { hasText: "Filter · 1" }).count(), 1);
  await page.locator("[data-stage=filter]").getByRole("link", { name: "Clear filters" }).click();
  await page.locator(".metrics").waitFor();

  // The date form refuses To before From.
  await page.getByRole("button", { name: "Choose dates" }).click();
  await page.locator("[data-range-form] input[name=from]").fill(day(2));
  await page.locator("[data-range-form] input[name=to]").fill(day(5));
  assert.match(await page.locator("[data-range-error]").textContent(), /To is before From/);
  assert.equal(await page.locator("[data-range-form] .btn-primary").isDisabled(), true);
  await page.keyboard.press("Escape");

  // Retention covers its own period; a site without visits waits on every page.
  await page.goto(`${base}/spike/retention`);
  assert.equal(await page.locator(".period-tag").textContent(), "Last 8 weeks · updated daily");
  assert.equal(await page.locator(".seg").count(), 0);
  await page.goto(`${base}/fresh/pages`);
  assert.equal(await page.locator("[data-stage=waiting] h2").textContent(), "Waiting for your first visit");
  assert.equal(await page.locator(".seg").count(), 0);

  // The heatmap overlay's data can be computed ahead of opening the page.
  assert.equal((await page.request.get(`${base}/ux/heatmaps/warm?path=%2F`)).status(), 204);

  return "group commit, engagement on page views, Server-Timing, API revalidation, live updates, the Live page, phone sheets and More, lazy card, hover/touch/range prefetch, instant back with scroll, morphing, remembered views, undo, keyboard, chart drill-down to an hourly day, dated comparisons, corrected ranges, empty and waiting states, heatmap warm, anomaly note kept";
});
