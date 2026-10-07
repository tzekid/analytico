// Full mode end to end: consent (regional policy, banner, GPC, deny,
// withdraw), geography, SPA routes, errors, ecommerce, site search, outbound
// links, identity across devices and domains, heatmaps with the live overlay,
// form analytics, session replay with masking, deletion — then the workspace
// screens, roles, public links, the read API, the audit log and the
// integrations against stand-in Google, Meta, Slack and webhook endpoints.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { createHmac, randomBytes, randomUUID } from "node:crypto";
import { readdir, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { setTimeout as delay } from "node:timers/promises";
import { gunzipSync, gzipSync } from "node:zlib";
import { journey, signer } from "./harness.mjs";

const snippets = {};
const google = signer();

// Fixture pages. Each proxy plays Caddy for one origin and one visitor
// address: A is a German address, B a US one.
function pages(origin, other) {
  const page = (body, extra = "") => `<!doctype html><html><head><title>Fixture</title>${snippets[origin] || ""}${extra}</head><body>${body}</body></html>`;
  return {
    "/home": page(`<h1 data-analytics-section="hero">Secret heading</h1><p>Visible text for the replay.</p>
      <a id="to-pricing" href="/pricing">Pricing</a> <a id="to-other" href="${other}/welcome">Our other shop</a>
      <a class="ext" href="https://partner.example/offer">Partner</a> <a href="/files/menu.pdf" class="ext">Menu</a>
      <script>document.addEventListener("click", (e) => { if (e.target.closest("a.ext")) e.preventDefault(); });</script>`),
    "/pricing": page(`<h1>Plans</h1><div id="plans"><button id="basic" style="width:200px;height:60px">Basic</button><button data-analytics-action="buy" style="width:200px;height:60px">Buy</button></div>
      <form name="signup" onsubmit="return false"><input name="email" id="email" type="email" required><input name="company" id="company"><button>Sign up</button></form>
      <div style="height:2400px"></div>`),
    "/catalog": page(`<h1>Search</h1><div data-analytics-search-results="0">No results</div>`),
    "/spa": page(`<h1>App</h1><button id="next" onclick="history.pushState({}, '', '/spa/step-2')">Next</button>`),
    "/broken": page(`<h1>Broken</h1><script>setTimeout(() => { undefinedFunction(); }, 50);</script>`),
    "/welcome": page(`<h1>Welcome from the other shop</h1>`),
    "/checkout": page(`<h1>Checkout</h1>`),
  };
}

// Stand-ins for Google (OpenID, Search Console, GA4, Ads), Meta, Slack and a
// webhook receiver. They record what Analytico sends.
const received = { slack: [], hook: [], ads: [], meta: [], tokenGrants: [] };
const codes = new Map();
function fake({ incoming, outgoing, url, base, body, json }) {
  if (url.pathname === "/.well-known/openid-configuration") return json({ issuer: base, authorization_endpoint: `${base}/authorize`, token_endpoint: `${base}/token`, jwks_uri: `${base}/jwks` });
  if (url.pathname === "/jwks") return json(google.jwks);
  if (url.pathname === "/authorize") {
    const code = randomBytes(8).toString("hex");
    codes.set(code, { nonce: url.searchParams.get("nonce"), scope: url.searchParams.get("scope") });
    outgoing.writeHead(302, { location: `${url.searchParams.get("redirect_uri")}?code=${code}&state=${url.searchParams.get("state")}` });
    return outgoing.end();
  }
  if (url.pathname === "/token") {
    const form = new URLSearchParams(body);
    received.tokenGrants.push(form.get("grant_type"));
    if (form.get("grant_type") === "refresh_token") return json({ access_token: "access-2", token_type: "Bearer" });
    const grant = codes.get(form.get("code")) || {};
    if (form.get("redirect_uri").endsWith("/integrations/google/callback")) return json({ access_token: "access-1", refresh_token: "refresh-1", token_type: "Bearer" });
    const claims = { iss: base, aud: "test-client", sub: "google-owner", exp: Math.floor(Date.now() / 1000) + 300, nonce: grant.nonce, email: "owner@example.test", email_verified: true };
    return json({ id_token: google.sign(claims), token_type: "Bearer" });
  }
  if (url.pathname.includes("/searchAnalytics/query")) {
    assert.equal(incoming.headers.authorization, "Bearer access-2");
    const day = new Date(Date.now() - 2 * 86400000).toISOString().slice(0, 10);
    return json({ rows: [
      { keys: [day, "urban garden ideas", "https://shop.example/pricing"], clicks: 82, impressions: 2100, position: 4.2 },
      { keys: [day, "how to start seeds indoors", "https://shop.example/"], clicks: 38, impressions: 1800, position: 8.7 },
    ] });
  }
  if (url.pathname.endsWith(":runReport")) {
    const request = JSON.parse(body);
    const start = new Date(request.dateRanges[0].startDate);
    const second = request.dimensions[1]?.name;
    const rows = [];
    // One day of history per month: 120 views, 40 users.
    const day = start.toISOString().slice(0, 10).replaceAll("-", "");
    const value = { pagePath: "/old-post", sessionSource: "google", countryId: "fr", deviceCategory: "mobile" }[second];
    rows.push({ dimensionValues: [{ value: day }, ...(second ? [{ value }] : [])], metricValues: [{ value: "120" }, { value: "40" }] });
    return json({ rows });
  }
  if (url.pathname.endsWith("googleAds:searchStream")) {
    assert.equal(incoming.headers["developer-token"], "dev-token");
    const day = new Date(Date.now() - 86400000).toISOString().slice(0, 10);
    return json([{ results: [{ segments: { date: day }, campaign: { name: "spring" }, metrics: { costMicros: "12500000" }, customer: { currencyCode: "EUR" } }] }]);
  }
  if (url.pathname.endsWith(":uploadClickConversions")) {
    received.ads.push(JSON.parse(body));
    return json({ results: [] });
  }
  if (url.pathname.endsWith("/insights")) {
    const day = new Date(Date.now() - 86400000).toISOString().slice(0, 10);
    return json({ data: [{ date_start: day, campaign_name: "reels", spend: "40.50", account_currency: "EUR" }] });
  }
  if (url.pathname.endsWith("/events") && url.searchParams.get("access_token")) {
    received.meta.push(JSON.parse(body));
    return json({ events_received: 1 });
  }
  if (url.pathname === "/slack") { received.slack.push(JSON.parse(body)); return json({ ok: true }); }
  if (url.pathname === "/hook") { received.hook.push({ body, signature: incoming.headers["x-analytico-signature"], timestamp: incoming.headers["x-analytico-timestamp"] }); return json({ ok: true }); }
}

await journey("v3", async (t) => {
  // Each proxy plays Caddy for one origin and one visitor address: A is a
  // German address, B a US one.
  const other = {};
  const fixture = (path, origin) => pages(origin, other[origin])[path];
  const originA = `http://localhost:${await t.proxy("198.51.100.42", fixture)}`;
  const originB = `http://127.0.0.1:${await t.proxy("203.0.113.9", fixture)}`;
  other[originA] = originB;
  other[originB] = originA;
  const fakeBase = await t.standIn(fake);

  // A two-range location database: the German address and the US one.
  const csv = [
    "0.0.0.0,198.51.99.255,ZZ,ZZ,,,0,0",
    '198.51.100.0,198.51.100.255,EU,DE,Berlin,"Berlin",52.5,13.4',
    "198.51.101.0,203.0.112.255,ZZ,ZZ,,,0,0",
    "203.0.113.0,203.0.113.255,NA,US,California,San Francisco,37.7,-122.4",
    "203.0.114.0,255.255.255.255,ZZ,ZZ,,,0,0",
    "::,ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff,ZZ,ZZ,,,0,0",
  ].join("\n") + "\n";
  const csvPath = join(t.temporary, "dbip-city-lite.csv.gz");
  await writeFile(csvPath, gzipSync(csv));

  const setupLink = t.init(originA);
  assert.match(t.cli("geo", "import", csvPath), /geo imported ipv4_ranges=\d+/);
  // Full is the default mode; the regional policy asks EU visitors.
  const added = t.cli("site", "add", "shop", originA);
  assert.match(added, /mode=full/);
  const publicId = /public_id=([^ ]+)/.exec(added)[1];
  const internalSecret = /internal_secret=([0-9a-f]+)/.exec(added)[1];
  t.cli("site", "origin-add", "shop", originB);
  t.cli("site", "add", "blog", "https://blog.example", "--mode", "lite");
  t.cli("goal", "add", "shop", "purchased", "event", "purchase");
  for (const origin of [originA, originB]) {
    snippets[origin] = t.cli("site", "snippet", "shop", origin).trim();
  }

  await t.serve();
  assert.match(t.log, /geo=on/);
  const db = t.db();
  const replays = t.db("replays.db");
  const row = (sql, ...args) => db.prepare(sql).get(...args);
  const rows = (sql, ...args) => db.prepare(sql).all(...args);

  // Turn on the banner and recording through the server's own settings path
  // later; the banner is on by default for new websites created in the UI,
  // but CLI-added sites start without it. Recording 100% with triggers.
  t.expectedErrors = /undefinedFunction/;
  const newContext = t.context;

  // ---------------------------------------------------------------- the owner

  const owner = await newContext();
  const page = await t.signUp(owner, setupLink);
  await page.waitForURL(`${originA}/shop`);

  // Consent & privacy: regional policy (default) with the banner on.
  await page.goto(`${originA}/settings/consent?site=shop`);
  await page.getByLabel("Show the Analytico banner (small, accessible, two equal buttons)").check();
  await page.getByRole("button", { name: "Save" }).click();
  await page.locator(".toast", { hasText: "Consent settings saved" }).waitFor();
  // Recording: every consented session, all text masked.
  await page.goto(`${originA}/settings/recording?site=shop`);
  await page.locator("input[name=replay_percent]").fill("100");
  await page.locator("input[name=replay_triggers]").check();
  await page.locator("textarea[name=record_exclude]").fill("/checkout");
  await page.getByRole("button", { name: "Save" }).click();
  await page.locator(".toast", { hasText: "Recording settings saved" }).waitFor();

  // ---------------------------------------------------------------- an EU visitor

  const visitorEU = await newContext();
  const eu = await visitorEU.newPage();
  const decision = (target) => target.waitForResponse((response) => response.url().endsWith("/e") && response.status() === 200);
  let [response] = await Promise.all([decision(eu), eu.goto(`${originA}/home?utm_source=newsletter`)]);
  assert.equal((await response.json()).upgrade, "ask");
  // Nothing is stored before consent; the page view still counts as Lite.
  assert.equal(await eu.evaluate(() => Object.keys(localStorage).length), 0);
  const banner = eu.locator("div >> internal:control=enter-frame").first();
  void banner;
  await eu.getByRole("dialog", { name: "Analytics consent" }).getByRole("button", { name: "Allow" }).click();
  await t.until(() => row("SELECT count(*) n FROM page_views WHERE site_id=1 AND visitor_id IS NOT NULL AND consent_mode='granted'").n === 1, "consent attaches the page view");
  const visitorA = await eu.evaluate((site) => localStorage.getItem(`analytico:${site}:visitor`).split(".")[0], publicId);
  const pv = row("SELECT country,region,city,consent_mode FROM page_views WHERE visitor_id=?", visitorA);
  assert.deepEqual({ ...pv }, { country: "DE", region: "Berlin", city: "Berlin", consent_mode: "granted" });

  // A second page in the same session carries the identity from the start.
  await Promise.all([decision(eu), eu.locator("#to-pricing").click()]);
  const pricing = await t.until(() => row("SELECT visitor_id,session_id FROM page_views WHERE path='/pricing' AND visitor_id=?", visitorA), "identified second page");
  assert.ok(pricing.session_id);
  // Heatmap clicks, a rage click and form fields (never values).
  await eu.locator("#basic").click({ position: { x: 20, y: 20 } });
  for (let index = 0; index < 3; index++) await eu.locator("[data-analytics-action=buy]").click();
  await eu.locator("#email").fill("secret-typed@example.test");
  await eu.locator("#company").fill("Typed Company Ltd");
  await eu.locator("#company").blur();
  await eu.mouse.wheel(0, 1600);
  await delay(1200);
  // Leaving sends the summary with clicks, attention and form fields.
  await Promise.all([decision(eu), eu.goto(`${originA}/catalog?q=Garden+Tools`)]);
  await t.until(() => row("SELECT count(*) n FROM click_cells WHERE path='/pricing'").n >= 2, "click cells");
  assert.ok(row("SELECT sum(rage) n FROM click_cells WHERE path='/pricing'").n >= 1);
  const form = rows("SELECT field,abandons,submits FROM form_fields WHERE form='signup' ORDER BY field");
  assert.deepEqual(form.map((entry) => entry.field), ["", "company", "email"]);
  assert.equal(form.find((entry) => entry.field === "company").abandons, 1);
  assert.ok(row("SELECT attention_json a FROM page_summaries WHERE visitor_id=? AND attention_json IS NOT NULL", visitorA));
  assert.equal(row("SELECT search_term t,search_results r FROM page_views WHERE path='/catalog'").t, "garden tools");
  assert.equal(row("SELECT search_results r FROM page_views WHERE path='/catalog'").r, 0);
  // An email address in the search box is never stored.
  await Promise.all([decision(eu), eu.goto(`${originA}/catalog?q=someone%40example.test`)]);
  assert.equal(row("SELECT count(*) n FROM page_views WHERE search_term LIKE '%@%'").n, 0);

  // Outbound links and downloads keep the host or file name only.
  await Promise.all([decision(eu), eu.goto(`${originA}/home`)]);
  await eu.locator("a.ext", { hasText: "Partner" }).click();
  await eu.locator("a.ext", { hasText: "Menu" }).click();
  // Cross-domain: the link to the other domain carries the visit along.
  await Promise.all([decision(eu), eu.locator("#to-other").click()]);
  await eu.waitForURL(`${originB}/welcome`);
  assert.equal(new URL(eu.url()).searchParams.get("_an"), null);
  await t.until(() => row("SELECT visitor_id v FROM page_views WHERE path='/welcome'")?.v === visitorA, "same visitor on the other domain");
  assert.equal(row("SELECT country c FROM page_views WHERE path='/welcome'").c, "US");
  await t.until(() => row("SELECT count(*) n FROM events WHERE name='outbound_click' AND json_extract(properties_json,'$.host')='partner.example'").n === 1, "outbound host");
  assert.equal(row("SELECT json_extract(properties_json,'$.file') f FROM events WHERE name='file_download'").f, "menu.pdf");

  // The session was recorded (100%), masked in the browser.
  await t.until(() => replays.prepare("SELECT count(*) n FROM replay_chunks WHERE session_id=?").get(pricing.session_id).n > 0, "replay chunks");
  const recorded = replays.prepare("SELECT data FROM replay_chunks WHERE session_id=?").all(pricing.session_id).map((chunk) => (chunk.data[0] === 0x1f && chunk.data[1] === 0x8b ? gunzipSync(chunk.data) : Buffer.from(chunk.data)).toString()).join("");
  assert.ok(recorded.includes('"type":2'), "a full snapshot was recorded");
  for (const secret of ["Secret heading", "secret-typed@example.test", "Typed Company Ltd", "Visible text for the replay"]) assert.ok(!recorded.includes(secret), `${secret} must be masked`);

  // ---------------------------------------------------------------- SPA routes and errors

  await Promise.all([decision(eu), eu.goto(`${originA}/spa`)]);
  await Promise.all([decision(eu), eu.locator("#next").click()]);
  await t.until(() => row("SELECT navigation_type t FROM page_views WHERE path='/spa/step-2'")?.t === "spa", "SPA route counted");
  await t.until(() => row("SELECT count(*) n FROM page_summaries ps JOIN page_views pv ON pv.page_id=ps.page_id WHERE pv.path='/spa'").n === 1, "summary of the previous route");
  await Promise.all([decision(eu), eu.goto(`${originA}/broken`)]);
  await t.until(() => row("SELECT count(*) n FROM errors WHERE path='/broken' AND visitor_id=?", visitorA).n === 1, "error recorded");
  assert.match(row("SELECT message m FROM errors").m, /undefinedFunction/);

  // ---------------------------------------------------------------- ecommerce and identity

  await Promise.all([decision(eu), eu.goto(`${originA}/checkout?gclid=Cj0KEQ-test`)]);
  await eu.evaluate(() => {
    analytico.identify("user-42");
    analytico.track("purchase", {}, { value_minor: 4900, currency: "EUR", order_id: "A-1001", items: [{ id: "seed-kit", name: "Seed starter kit", price_minor: 3900, quantity: 1 }, { id: "guide", name: "Garden guide", price_minor: 1000, quantity: 1 }] });
  });
  await Promise.all([decision(eu), eu.goto(`${originA}/home`)]);
  await t.until(() => row("SELECT count(*) n FROM events WHERE name='purchase'").n === 1, "browser order");
  assert.equal(row("SELECT click_id c FROM page_views WHERE path='/checkout'").c, "gclid:Cj0KEQ-test");
  // The shop's server confirms the same order: counted once, server wins.
  const now = Date.now();
  const server = JSON.stringify({ v: 2, site: publicId, sent_at_ms: now, records: [{ event_id: "9a4f8f8e-1c2b-4d3e-8f00-000000000001", type: "event", occurred_at_ms: now, tracking_mode: "full", consent_mode: "server", tracker_version: "backend", release_id: "", internal: false, name: "purchase", value_minor: 4900, currency: "EUR", order_id: "A-1001", user_id: "user-42", properties: {} }] });
  const stamp = String(Math.floor(now / 1000));
  const signature = createHmac("sha256", Buffer.from(internalSecret, "hex")).update(`${stamp}.${server}`).digest("hex");
  assert.equal((await fetch(`http://127.0.0.1:${t.port}/i`, { method: "POST", headers: { "content-type": "application/json", "x-analytico-timestamp": stamp, "x-analytico-signature": signature }, body: server })).status, 204);
  assert.equal(row("SELECT count(*) n FROM visitor_links WHERE visitor_id=?", visitorA).n, 1);

  // Another device of the same person.
  const phone = await newContext({ viewport: { width: 390, height: 844 }, isMobile: true, userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1" });
  const mobile = await phone.newPage();
  await Promise.all([decision(mobile), mobile.goto(`${originA}/home`)]);
  await mobile.getByRole("dialog", { name: "Analytics consent" }).getByRole("button", { name: "Allow" }).click();
  await t.until(() => mobile.evaluate((site) => !!localStorage.getItem(`analytico:${site}:visitor`), publicId), "phone consented");
  await mobile.evaluate(() => analytico.identify("user-42"));
  const userHash = await t.until(() => row("SELECT user_hash u FROM visitors WHERE visitor_id=?", visitorA)?.u, "linked user");
  await t.until(() => row("SELECT count(*) n FROM visitor_links WHERE user_hash=?", userHash).n === 2, "two devices, one person");

  // ---------------------------------------------------------------- a US visitor, GPC, decline, withdraw

  const visitorUS = await newContext();
  const us = await visitorUS.newPage();
  [response] = await Promise.all([decision(us), us.goto(`${originB}/welcome`)]);
  assert.equal((await response.json()).upgrade, "grant");
  // Outside the EU nobody is asked: identity follows right away, without a banner.
  await t.until(() => us.evaluate((site) => localStorage.getItem(`analytico:${site}:consent`) === "auto", publicId), "not required outside the EU");
  assert.equal(await us.getByRole("dialog", { name: "Analytics consent" }).count(), 0);

  const gpcContext = await newContext({ extraHTTPHeaders: { "Sec-GPC": "1" } });
  await gpcContext.addInitScript(() => Object.defineProperty(Navigator.prototype, "globalPrivacyControl", { get: () => true }));
  const gpc = await gpcContext.newPage();
  [response] = await Promise.all([decision(gpc), gpc.goto(`${originB}/welcome`)]);
  assert.equal((await response.json()).upgrade, "never");
  assert.equal(await gpc.evaluate(() => Object.keys(localStorage).length), 0);
  await t.until(() => row("SELECT count(*) n FROM page_views WHERE consent_mode='gpc'").n === 1, "GPC stays Lite");

  const declined = await newContext();
  const no = await declined.newPage();
  await Promise.all([decision(no), no.goto(`${originA}/home`)]);
  await no.getByRole("dialog", { name: "Analytics consent" }).getByRole("button", { name: "No thanks" }).click();
  await t.until(() => row("SELECT count(*) n FROM page_views WHERE consent_mode='denied'").n === 1, "declined recorded");
  await Promise.all([decision(no), no.goto(`${originA}/pricing`)]);
  assert.equal(await no.getByRole("dialog", { name: "Analytics consent" }).count(), 0);
  assert.equal(await no.evaluate((site) => localStorage.getItem(`analytico:${site}:visitor`), publicId), null);
  // Nothing beyond Lite was stored for them: no visitors, no replays.
  assert.equal(row("SELECT count(*) n FROM visitors").n, 3);

  // A visitor withdraws, then asks to be forgotten.
  await us.evaluate(() => analytico.forget());
  await t.until(() => row("SELECT count(*) n FROM visitors").n === 2, "forgotten visitor removed");
  assert.equal(await us.evaluate((site) => localStorage.getItem(`analytico:${site}:consent`), publicId), "denied");

  // ---------------------------------------------------------------- the heatmap overlay on the live site

  await page.goto(`${originA}/shop/heatmaps`);
  await page.locator(".heat-card", { hasText: "/pricing" }).waitFor();
  const overlayLink = await page.locator(".heat-card", { hasText: "/pricing" }).getByRole("link", { name: "Open on site ↗" }).getAttribute("href");
  const overlayTab = await owner.newPage();
  await overlayTab.goto(`${originA}${overlayLink}`);
  await overlayTab.waitForURL(/#analytico-heatmap=/);
  const note = overlayTab.locator("#analytico-overlay").locator(".note");
  await t.until(async () => /clicks/.test(await note.textContent()), "overlay draws clicks");
  assert.match(await note.textContent(), /^\d+ clicks · \d+ views/);
  await overlayTab.close();

  // ---------------------------------------------------------------- workspace screens

  const visit = async (path, text) => {
    await page.goto(`${originA}${path}`);
    await page.getByText(text, { exact: false }).first().waitFor();
  };
  await visit("/shop", "Returning visitors");
  await page.locator(".country-row", { hasText: "Germany" }).waitFor();
  await page.locator(".product-row", { hasText: "Seed starter kit" }).waitFor();
  assert.match(await page.locator(".sidebar-meta").textContent(), /Full · \d+% consented · UTC/);
  await visit("/shop/revenue", "Orders");
  assert.equal((await page.locator(".metric", { hasText: "Orders" }).locator(".metric-value").textContent()).trim(), "1");
  assert.match(await page.locator(".metric", { hasText: "Revenue" }).locator(".metric-value").textContent(), /€49/);
  // The server's copy of the order wins, but the visit, and so the source, come from the browser's.
  assert.deepEqual(await page.locator(".source-money strong").allTextContents(), ["Newsletter"]);
  await page.locator("td", { hasText: "Garden guide" }).waitFor();
  await visit("/shop/retention", "Weekly cohorts");
  await visit("/shop/audience", "Where they are");
  await page.locator(".country-row", { hasText: "Germany" }).first().waitFor();
  await visit("/shop/pages?tab=outbound", "partner.example");
  await visit("/shop/pages?tab=downloads", "menu.pdf");
  await visit("/shop/search", "garden tools");
  await visit("/shop/errors", "undefinedFunction");
  await visit("/shop/funnels?tab=forms", "signup");
  await page.locator("td.mono", { hasText: "company" }).waitFor();
  await visit("/shop/sessions?signal=recorded", "Sessions & replays");
  await page.locator("tr", { hasText: "Rage click" }).locator("a.btn-replay").first().click();
  await page.waitForURL(/\/shop\/replays\//);
  await page.locator(".player.loaded").waitFor();
  assert.ok(await page.locator(".player-frame iframe").count() >= 1);
  await page.locator("[data-play]").click();
  await page.locator(".tl-seek", { hasText: "Rage click" }).waitFor();

  // People: one person, two devices; then deletion on request.
  await visit("/shop/people?segment=identified", "identified");
  await page.locator("tr", { hasText: "user " }).first().click();
  await page.getByText("2 devices").waitFor();
  const exported = await (await page.request.get(page.url() + "?format=json")).json();
  assert.equal(exported.visitors.length, 2);
  assert.ok(exported.page_views.length >= 5);
  page.once("dialog", (dialog) => dialog.accept());
  await page.getByRole("button", { name: /^Delete user/ }).click();
  await page.locator(".toast", { hasText: "Deleted user" }).waitFor();
  assert.equal(row("SELECT count(*) n FROM page_views WHERE visitor_id=?", visitorA).n, 0);
  assert.equal(row("SELECT count(*) n FROM events WHERE user_hash=?", userHash).n, 0);
  assert.equal(replays.prepare("SELECT count(*) n FROM replays WHERE visitor_id=?").get(visitorA).n, 0);
  // Aggregates without identifiers stay.
  assert.ok(row("SELECT count(*) n FROM click_cells").n >= 2);

  // ---------------------------------------------------------------- teams, public links, API, audit

  await page.goto(`${originA}/settings/team`);
  await page.getByPlaceholder("name@example.com").fill("viewer@example.test");
  await page.locator("form.invite select[name=role]").selectOption("viewer");
  await page.locator("form.invite select[name=site]").selectOption({ label: "Only blog.example" });
  await page.getByRole("button", { name: "Invite" }).click();
  const viewerLink = await page.locator("input[readonly]").inputValue();
  const viewerContext = await newContext();
  const viewer = await viewerContext.newPage();
  await viewer.goto(viewerLink);
  await viewer.getByRole("button", { name: "Other ways to sign in" }).click();
  await viewer.getByRole("link", { name: /Choose a password/ }).click();
  await viewer.getByLabel("Password").fill("correct horse battery");
  await viewer.getByRole("button", { name: "Continue" }).click();
  await viewer.waitForURL(`${originA}/blog`);
  // The shop doesn't exist for them, and settings beyond sign-in are closed.
  assert.equal((await viewer.goto(`${originA}/shop`)).status(), 404);
  assert.equal((await viewer.goto(`${originA}/settings/team`)).status(), 403);
  await viewer.goto(`${originA}/blog`);
  assert.equal(await viewer.locator("#site-menu .menu-item", { hasText: "shop" }).count(), 0);
  await viewerContext.close();

  await page.goto(`${originA}/shop`);
  await page.getByRole("button", { name: "More actions" }).click();
  await page.getByRole("button", { name: "Share publicly…" }).click();
  await page.locator("#share-dialog").getByLabel("Password (optional)").fill("open sesame");
  await page.locator("#share-dialog").getByRole("button", { name: "Create public link" }).click();
  const shareToast = await page.locator(".toast", { hasText: "Public link ready" }).textContent();
  const shareUrl = /(http\S+\/share\/[0-9a-f]{64})/.exec(shareToast)[1];
  const outsider = await newContext();
  const shared = await outsider.newPage();
  await shared.goto(shareUrl);
  await shared.getByLabel("Password").fill("open sesame");
  await shared.getByRole("button", { name: "View" }).click();
  await shared.getByRole("heading", { name: "Last 7 days" }).waitFor();
  await shared.locator(".metric", { hasText: "Page views" }).waitFor();
  await shared.locator(".country-row", { hasText: "United States" }).waitFor();
  await outsider.close();

  await page.goto(`${originA}/settings/api?site=shop`);
  await page.getByLabel("Key name").fill("Looker Studio");
  await page.getByRole("button", { name: "Create key" }).click();
  const key = await page.getByLabel("New API key").inputValue();
  const api = (path) => fetch(`${originA}/api/v1${path}`, { headers: { authorization: `Bearer ${key}` } });
  assert.deepEqual((await (await api("/sites")).json()).sites.map((site) => site.slug).sort(), ["blog", "shop"]);
  const breakdown = await (await api("/sites/shop/breakdown?dimension=country&range=7d")).json();
  assert.ok(breakdown.rows.some((entry) => entry.value === "US"));
  assert.match(await (await api("/sites/shop/breakdown?dimension=page&format=csv")).text(), /^"value","page_views"/);
  assert.equal((await fetch(`${originA}/api/v1/sites`)).status, 401);
  // One engine: the CLI and the read API return the same rows for the same view.
  for (const [name, extra] of [["overview", []], ["pages", []], ["goals", []], ["errors", []], ["breakdown", ["dimension", "country"]]]) {
    const query = extra.length ? `&${extra[0]}=${extra[1]}` : "";
    const fromApi = (await (await api(`/sites/shop/${name}?range=7d${query}`)).json()).rows;
    const fromCli = JSON.parse(t.cli("report", name, "shop", "--range", "7d", ...(extra.length ? [`--${extra[0]}`, extra[1]] : []), "--json"));
    assert.deepEqual(fromCli, fromApi, name);
  }

  await page.goto(`${originA}/settings/audit`);
  for (const text of ["Invited viewer@example.test as Viewer", "Shared", "Created API key", "Session replay at 100%", "user "]) {
    await page.locator("td", { hasText: text }).first().waitFor();
  }

  // ---------------------------------------------------------------- integrations

  await page.goto(`${originA}/settings/signin`);
  await page.locator(".method-row", { hasText: "Google" }).getByRole("link", { name: "Set up" }).click();
  const provider = page.locator("#provider-dialog");
  await provider.getByLabel("Client ID").fill("test-client");
  await provider.getByLabel("Client secret").fill("test-secret");
  await provider.locator("summary").click();
  await provider.getByLabel("Issuer").fill(`${fakeBase}`);
  await provider.getByRole("button", { name: "Save and link Google" }).click();
  await page.waitForURL(/\/settings\/signin$/);

  const integration = (id) => page.locator(`section.integration#${id}`);
  const connect = async (id) => {
    await page.goto(`${originA}/settings/integrations?site=shop`);
    await integration(id).getByRole("link", { name: "Connect with Google" }).click();
    await page.waitForURL(/\/settings\/integrations/);
    await page.locator(".toast", { hasText: "connected" }).waitFor();
  };
  const configure = async (id, fields, button) => {
    const card = integration(id);
    if ((await card.locator("details.integration-form").getAttribute("open")) === null) await card.locator("summary.btn").click();
    for (const [name, value] of Object.entries(fields)) await card.locator(`[name=${name}]`).fill(value);
    await card.locator("details:not(.integration-form) summary").click();
    await card.locator("[name=api]").fill(`${fakeBase}`);
    await page.evaluate(() => document.querySelectorAll(".toast").forEach((toast) => toast.remove()));
    await card.getByRole("button", { name: button }).click();
    await page.locator(".toast").waitFor();
    return page.locator(".toast").textContent();
  };
  await connect("search_console");
  assert.match(await configure("search_console", { property: "sc-domain:shop.example" }, "Sync now"), /2 query rows/);
  await visit("/shop/search", "urban garden ideas");

  await connect("ga4");
  assert.match(await configure("ga4", { property: "318000000" }, "Import history"), /Google Analytics import: \d+ months/);
  const imported = row("SELECT sum(views) v FROM imported_daily WHERE dim='total'").v;
  assert.ok(imported >= 120);
  await page.goto(`${originA}/shop?range=90d`);
  await page.getByText("includes imported Google Analytics history").waitFor();

  // Purchases after ad clicks, from visitors who don't need to be asked (US).
  for (const [param, order] of [["gclid=EAIaIQ-ads", "G-1"], ["fbclid=IwAR-meta", "M-1"]]) {
    const buyer = await (await newContext()).newPage();
    await Promise.all([decision(buyer), buyer.goto(`${originB}/checkout?${param}`)]);
    await t.until(() => buyer.evaluate((site) => !!localStorage.getItem(`analytico:${site}:visitor`), publicId), "buyer remembered");
    await buyer.evaluate((id) => analytico.track("purchase", {}, { value_minor: 1999, currency: "EUR", order_id: id }), order);
    await Promise.all([decision(buyer), buyer.goto(`${originB}/welcome`)]);
    await t.until(() => row("SELECT count(*) n FROM events WHERE order_id=?", order).n === 1, "ad purchase");
  }
  await connect("google_ads");
  assert.match(await configure("google_ads", { customer_id: "123-456-7890", developer_token: "dev-token", conversion_action: "customers/1234567890/conversionActions/1" }, "Sync now"), /1 cost rows in, 1 conversion out/);
  assert.equal(row("SELECT amount_minor a FROM campaign_spend WHERE source='google'").a, 1250);
  assert.deepEqual(received.ads[0].conversions.map((entry) => [entry.gclid, entry.orderId, entry.conversionValue]), [["EAIaIQ-ads", "G-1", 19.99]]);

  await page.goto(`${originA}/settings/integrations?site=shop`);
  assert.match(await configure("meta", { pixel_id: "777", ad_account: "act_888", access_token: "meta-token" }, "Sync now"), /Meta synced: 1 cost rows in, 1 conversion out/);
  assert.equal(row("SELECT amount_minor a FROM campaign_spend WHERE source='meta'").a, 4050);
  const metaEvent = received.meta[0].data[0];
  assert.deepEqual(Object.keys(metaEvent.user_data), ["fbc"]);
  assert.match(metaEvent.user_data.fbc, /^fb\.1\.\d+\.IwAR-meta$/);
  assert.deepEqual(metaEvent.custom_data, { value: 19.99, currency: "EUR" });

  // Slack and a signed webhook: a test message, then a goal as it happens.
  await page.goto(`${originA}/settings/integrations?site=shop`);
  const channels = integration("channels");
  await channels.locator("summary.btn").click();
  await channels.getByRole("textbox", { name: "Name" }).fill("#marketing");
  await channels.getByRole("textbox", { name: "URL" }).fill(`${fakeBase}/slack`);
  await channels.getByRole("button", { name: "Add and send a test" }).click();
  await page.locator(".toast", { hasText: "Slack connected" }).waitFor();
  assert.match(received.slack[0].text, /connected/);
  await page.goto(`${originA}/settings/integrations?site=shop`);
  await integration("channels").locator("summary.btn").click();
  await integration("channels").getByRole("radio", { name: /^Webhook/ }).check();
  await integration("channels").getByRole("textbox", { name: "Name" }).fill("Orders");
  await integration("channels").getByRole("textbox", { name: "URL" }).fill(`${fakeBase}/hook`);
  await integration("channels").getByRole("button", { name: "Add and send a test" }).click();
  const webhookSecret = /secret \(shown once\): ([0-9a-f]{64})/.exec(await page.locator(".toast").textContent())[1];
  const goalVisitor = await (await newContext()).newPage();
  await Promise.all([decision(goalVisitor), goalVisitor.goto(`${originB}/welcome`)]);
  await goalVisitor.evaluate(() => analytico.track("purchase", {}, { value_minor: 2500, currency: "EUR", order_id: "B-7" }));
  await goalVisitor.goto(`${originB}/checkout`);
  const goalHook = await t.until(() => received.hook.find((entry) => entry.body.includes('"goal"')), "goal webhook", 45000);
  assert.equal(createHmac("sha256", Buffer.from(webhookSecret, "hex")).update(`${goalHook.timestamp}.${goalHook.body}`).digest("hex"), goalHook.signature);
  assert.doesNotMatch(goalHook.body, /visitor|session|198\.51/);

  // The daily export writes gzip CSV files next to the database.
  await page.goto(`${originA}/settings/integrations?site=shop`);
  await integration("export").getByRole("button", { name: "Export yesterday now" }).click();
  await page.locator(".toast", { hasText: "Exported 6 files" }).waitFor();
  const day = new Date(Date.now() - 86400000).toISOString().slice(0, 10);
  assert.deepEqual((await readdir(join(t.data, "exports", "shop", day))).sort(), ["events.csv.gz", "order_items.csv.gz", "page_views.csv.gz"]);

  // Rollups: a closed day is summarised once by the background job and reads
  // exactly like its raw rows (25 views by 10 visitor-days from NL).
  const writer = t.db("analytico.db", {});
  const yesterdayAt = Date.now() - Date.now() % 86400000 - 86400000 + 3600000;
  const yesterday = new Date(yesterdayAt).toISOString().slice(0, 10);
  const insert = writer.prepare(`INSERT INTO page_views(site_id,event_id,page_id,occurred_at_ms,received_at_ms,received_date,visitor_day_id,tracking_mode,path,tracker_version,consent_mode,internal,country,browser,operating_system,device,traffic_class)
    VALUES(1,?,?,?,?,?,?,'full','/archive','2','pending',0,'NL','chrome','linux','desktop','human_like')`);
  for (let index = 0; index < 25; index++) insert.run(randomUUID(), randomUUID(), yesterdayAt + index, yesterdayAt + index, yesterday, (index % 10).toString(16).padStart(16, "0"));
  writer.close();
  await t.until(() => row("SELECT count(*) n FROM rollup_days WHERE day=?", yesterday).n === 1, "yesterday summarised", 90000);
  assert.deepEqual({ ...row("SELECT views,visitors FROM rollups WHERE day=? AND dim='country' AND key='NL'", yesterday) }, { views: 25, visitors: 10 });
  const rolledCountries = await (await api("/sites/shop/breakdown?dimension=country&range=7d")).json();
  const netherlands = rolledCountries.rows.find((entry) => entry.value === "NL");
  assert.deepEqual([netherlands.page_views, netherlands.visitor_days], [25, 10]);
  const overview = (await (await api("/sites/shop/overview?range=7d")).json()).rows[0];
  // Live rows (raw today, rolled up yesterday) plus the imported history of the week.
  const weekStart = Date.now() - Date.now() % 86400000 - 6 * 86400000;
  const live = row("SELECT count(*) n FROM page_views WHERE internal=0 AND traffic_class IN ('human_like','unknown') AND received_at_ms>=?", weekStart).n;
  const history = row("SELECT coalesce(sum(views),0) n FROM imported_daily WHERE dim='total' AND day>=?", new Date(weekStart).toISOString().slice(0, 10)).n;
  assert.equal(overview.page_views, live + history);

  // Today is summarised up to a recent cut; raw rows after it count people
  // the summary already saw once. Forget today's summary so the job cuts
  // after the traffic so far, then add one returning and one new visitor-day.
  const today = new Date().toISOString().slice(0, 10);
  const dayStart = Date.now() - Date.now() % 86400000;
  const forgetting = t.db("analytico.db", {});
  forgetting.prepare("DELETE FROM rollup_days WHERE day=?").run(today);
  forgetting.close();
  const forgotAt = Date.now();
  const cut = await t.until(() => row("SELECT until_ms FROM rollup_days WHERE day=? AND until_ms>?", today, forgotAt - 60000)?.until_ms, "today summarised", 90000);
  const seen = row("SELECT visitor_day_id FROM page_views WHERE received_at_ms>=? AND received_at_ms<? AND internal=0 AND traffic_class IN ('human_like','unknown') LIMIT 1", dayStart, cut).visitor_day_id;
  const late = t.db("analytico.db", {});
  const lateInsert = late.prepare(`INSERT INTO page_views(site_id,event_id,page_id,occurred_at_ms,received_at_ms,received_date,visitor_day_id,tracking_mode,path,tracker_version,consent_mode,internal,country,browser,operating_system,device,traffic_class)
    VALUES(1,?,?,?,?,?,?,'full','/late','2','pending',0,'NL','chrome','linux','desktop','human_like')`);
  for (const visitorDay of [seen, "f".repeat(16)]) lateInsert.run(randomUUID(), randomUUID(), Date.now(), Date.now(), today, visitorDay);
  late.close();
  const exact = row("SELECT count(*) views,count(DISTINCT received_date||visitor_day_id) visitors FROM page_views WHERE internal=0 AND traffic_class IN ('human_like','unknown') AND received_at_ms>=?", weekStart);
  const historyVisitors = row("SELECT coalesce(sum(visitors),0) n FROM imported_daily WHERE dim='total' AND day>=?", new Date(weekStart).toISOString().slice(0, 10)).n;
  const afterCut = (await (await api("/sites/shop/overview?range=7d")).json()).rows[0];
  assert.deepEqual([afterCut.page_views, afterCut.visitor_days], [exact.views + history, exact.visitors + historyVisitors]);

  // Backups cover the replay database too.
  const backup = join(t.temporary, "backup.db");
  execFileSync(t.app, ["backup", t.data, backup]);
  execFileSync(t.app, ["restore", backup, join(t.temporary, "restored")]);
  assert.match(execFileSync(t.app, ["doctor", "--data", join(t.temporary, "restored")], { encoding: "utf8" }), /replays=\d+/);

  return "full mode consent (regional, banner, GPC, decline, withdraw, forget), geography, SPA, errors, ecommerce, identity across devices and domains, heatmaps and overlay, forms, masked replay, people deletion, roles, public links, API, audit, Search Console, GA4 import, Ads and Meta, Slack and webhooks, export, backups";
});
