// The command line and the collector without a browser: sites, goals,
// funnels and spend from the CLI; browser and server batches over HTTP
// (no client address, duplicates, a foreign origin, a conflicting replay, a
// signed server event, a refund from both sides); the reports' values; a
// breakdown the summaries leave out; every catalog report alike through the
// CLI and the read API; backup, restore and doctor.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdirSync, readdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { Script } from "node:vm";
import { DatabaseSync } from "node:sqlite";
import { journey } from "./harness.mjs";

await journey("cli", async (t) => {
  t.init();
  const added = t.cli("site", "add", "example", "https://example.test", "--mode", "session");
  const site = /public_id=([^ ]+)/.exec(added)[1];
  t.cli("campaign", "spend-add", "example", new Date().toISOString().slice(0, 10), "search", "launch", "hero", "1000", "EUR");
  t.cli("goal", "add", "example", "registration-start", "event", "registration_started");
  t.cli("goal", "add", "example", "paid", "event", "payment_confirmed");
  t.cli("funnel", "add", "example", "registration-to-paid", "registration-start", "paid");
  // The owner and a read API key, made from the CLI before the server holds the database.
  t.cli("user", "invite", "owner@example.test", "--origin", `http://127.0.0.1:${t.port}`);
  const token = t.cli("user", "key", "owner@example.test", "cli").trim();
  await t.serve();
  const base = `http://127.0.0.1:${t.port}`;

  // The snippet's tracker is served and parses.
  const snippet = t.cli("site", "snippet", "example", base, "--rum");
  const tracker = await fetch(/src="([^"]*)"/.exec(snippet)[1]);
  assert.equal(tracker.status, 200);
  new Script(await tracker.text());

  // ---------------------------------------------------------------- collect

  const now = Date.now();
  const sessionId = "550e8400-e29b-41d4-a716-446655440002";
  const common = { session_id: sessionId, occurred_at_ms: now, tracking_mode: "session", tracker_version: "1", release_id: "test", internal: false };
  const onPage = { ...common, page_id: "550e8400-e29b-41d4-a716-446655440001", consent_mode: "analytics" };
  const records = [
    { ...onPage, event_id: "550e8400-e29b-41d4-a716-446655440000", type: "page_view", path: "/landing", page_type: "landing", utm_source: "search", utm_campaign: "launch", utm_content: "hero", navigation_type: "navigate", viewport_class: "desktop", language: "en" },
    { ...onPage, event_id: "550e8400-e29b-41d4-a716-446655440003", type: "event", name: "registration_started", path: "/register", properties: { flow: "registration" } },
    { ...onPage, event_id: "550e8400-e29b-41d4-a716-446655440006", type: "event", name: "flow_started", path: "/register", properties: { flow: "registration", step: "start" } },
    { ...onPage, event_id: "550e8400-e29b-41d4-a716-446655440004", type: "page_summary", visible_ms: 12000, active_ms: 10000, interaction_count: 2, max_scroll: 75, sections: ["hero"], last_section: "hero", selection_count: 0, copy_count: 0, outbound_clicks: 0, downloads: 0, form_attempts: 1, lcp_ms: 500 },
  ];
  const collect = async (batch, origin, address, v = 1) => (await fetch(`${base}/e`, {
    method: "POST",
    headers: { origin, "content-type": "text/plain;charset=UTF-8", ...(address ? { "x-forwarded-for": address } : {}) },
    body: JSON.stringify({ v, site, sent_at_ms: now, records: batch }),
  })).status;
  assert.equal(await collect(records, "https://example.test"), 400, "no client address");
  assert.equal(await collect(records, "https://example.test", "198.51.100.10"), 204);
  assert.equal(await collect(records, "https://example.test", "198.51.100.10"), 204, "duplicates");
  assert.equal(await collect(records, "https://denied.test", "198.51.100.10"), 403);
  assert.equal(await collect([{ ...records[0], path: "/changed" }, ...records.slice(1)], "https://example.test", "198.51.100.10"), 409);

  const serverBatch = JSON.stringify({ v: 1, site, sent_at_ms: Date.now(), records: [{ ...common, event_id: "550e8400-e29b-41d4-a716-446655440005", type: "event", occurred_at_ms: Date.now(), consent_mode: "server", tracker_version: "backend-1", name: "payment_confirmed", value_minor: 4900, currency: "EUR", properties: { source: "search", campaign: "launch", content: "hero" } }] });
  const signed = await fetch(`${base}/i`, { method: "POST", headers: { "content-type": "application/json", ...t.sign("example", serverBatch) }, body: serverBatch });
  assert.ok(signed.ok, await signed.text());

  // One refund of order A-1 seen by the browser and confirmed by the server,
  // which also refunds shipping: 1000 + 500 come off, not 2500.
  const kit = [{ id: "kit", name: "Kit", price_minor: 1000, quantity: 1 }];
  assert.equal(await collect([{ ...onPage, event_id: "550e8400-e29b-41d4-a716-446655440007", type: "event", name: "refund", path: "/register", order_id: "A-1", value_minor: 1000, currency: "EUR", items: kit }], "https://example.test", "198.51.100.10", 2), 204);
  const confirmed = { ...common, type: "event", occurred_at_ms: Date.now(), consent_mode: "server", tracker_version: "backend-1", name: "refund_confirmed", order_id: "A-1", currency: "EUR" };
  const refundBatch = JSON.stringify({ v: 2, site, sent_at_ms: Date.now(), records: [
    { ...confirmed, event_id: "550e8400-e29b-41d4-a716-446655440008", value_minor: 1000, items: kit },
    { ...confirmed, event_id: "550e8400-e29b-41d4-a716-446655440009", value_minor: 500 },
  ] });
  const refunded = await fetch(`${base}/i`, { method: "POST", headers: { "content-type": "application/json", ...t.sign("example", refundBatch) }, body: refundBatch });
  assert.ok(refunded.ok, await refunded.text());

  // ---------------------------------------------------------------- reports

  const report = (kind, ...options) => JSON.parse(t.cli("report", kind, "example", "--days", "7", "--json", ...options));
  assert.match(t.cli("report", "overview", "example", "--days", "7"), /\t1\t1\t1\t10000\t/);
  assert.match(t.cli("report", "traffic", "example", "--days", "7"), /human_like\t0\t1\t1/);
  assert.match(t.cli("report", "performance", "example", "--days", "7"), /lcp\t1\t500\t500\t500/);
  assert.match(t.cli("session", "show", "example", sessionId), /registration_started/);
  assert.match(t.cli("report", "flow", "example", "registration", "--days", "7"), /flow_started/);
  assert.match(t.cli("funnel", "show", "example", "registration-to-paid", "--days", "7"), /2\tevent\tpayment_confirmed\t1/);
  assert.match(t.cli("report", "campaign-economics", "example", "--days", "7"), /search\tlaunch\thero\t1000\tEUR\t1\t1\t1\t0\t1\t0\t0\t4900/);
  assert.deepEqual(report("pages"), [{
    path: "/landing", page_type: "landing", content_id: "", views: 1, visitors: 1,
    avg_visible_ms: 12000, avg_active_ms: 10000, avg_first_interaction_ms: 0,
    avg_scroll: 75, copies: 0, outbound_clicks: 0, downloads: 0, form_attempts: 1,
  }]);
  assert.deepEqual(report("acquisition"), [{ source: "search", medium: "", views: 1, visitors: 1, label: "Search", channel: "Search" }]);
  // What the workspace's Audience shows, for the apps: engagement, languages and screen sizes.
  const [totals] = report("overview");
  assert.equal(totals.engaged_views, 1);
  assert.equal(totals.previous_engaged_views, 0);
  assert.equal(totals.revenue_minor, 4900 - 1000 - 500);
  assert.deepEqual(report("revenue").map(({ product_id, refunds_minor }) => [product_id, refunds_minor]), [["kit", 1000]]);
  assert.deepEqual(report("breakdown", "--dimension", "language"), [{ value: "en", page_views: 1, visitor_days: 1, previous_page_views: 0, label: "English", channel: null }]);
  assert.deepEqual(report("breakdown", "--dimension", "viewport"), [{ value: "desktop", page_views: 1, visitor_days: 1, previous_page_views: 0, label: "Desktop", channel: null }]);
  assert.deepEqual(report("campaigns"), [{ source: "search", campaign: "launch", content: "hero", views: 1, visitors: 1, sessions: 1 }]);
  assert.deepEqual(report("sections"), [{ section: "hero", exposures: 1, exposure_percent: 100, final_section: 1 }]);
  // The browser journey separately checks an actual click produces an action.
  assert.deepEqual(report("actions"), []);
  assert.deepEqual(report("events"), [
    { name: "refund_confirmed", source: "server", occurrences: 2, sessions: 1, value_minor: 1500, currency: "EUR" },
    { name: "flow_started", source: "browser", occurrences: 1, sessions: 1, value_minor: 0, currency: "" },
    { name: "payment_confirmed", source: "server", occurrences: 1, sessions: 1, value_minor: 4900, currency: "EUR" },
    { name: "refund", source: "browser", occurrences: 1, sessions: 1, value_minor: 1000, currency: "EUR" },
    { name: "registration_started", source: "browser", occurrences: 1, sessions: 1, value_minor: 0, currency: "" },
  ]);
  const recent = report("recent");
  assert.deepEqual(recent.map(({ name }) => name).sort(), ["flow_started", "page_view", "payment_confirmed", "refund", "refund_confirmed", "refund_confirmed", "registration_started"]);
  for (const row of recent) {
    assert.ok(Number.isInteger(row.received_at_ms) && row.received_at_ms > 0);
    assert.equal(row.session_id, sessionId);
    const server = row.name === "payment_confirmed" || row.name === "refund_confirmed";
    assert.equal(row.source, server ? "server" : "browser");
    assert.equal(row.path, row.name === "page_view" ? "/landing" : server ? "" : "/register");
  }
  assert.deepEqual(report("coverage"), [{
    page_views: 1, summaries: 1, summary_percent: 100, unknown_traffic: 0,
    session_identified: 1, internal_page_views: 0, rum_samples: 1,
  }]);
  for (const kind of ["pages", "acquisition", "campaigns", "sections", "actions", "events", "recent"]) {
    assert.deepEqual(report(kind, "--path", "/absent"), [], `${kind}: empty filtered result`);
  }
  // Reports whose query can't filter say so instead of answering unfiltered.
  for (const args of [["sessions"], ["friction"], ["campaign-economics", "--path", "/landing"]]) {
    assert.throws(() => execFileSync(t.app, ["report", args[0], "example", ...(args.length > 1 ? args.slice(1) : ["--path", "/landing"]), "--data", t.data], { stdio: ["ignore", "pipe", "pipe"] }), /UnsupportedFilter/, args[0]);
  }
  const emptyCoverage = report("coverage", "--path", "/absent")[0];
  assert.deepEqual([emptyCoverage.page_views, emptyCoverage.summaries, emptyCoverage.rum_samples], [0, 0, 0]);

  // Every report in the catalog answers the same through the CLI and the API.
  const values = { dimension: "page", name: "registration-to-paid", from_path: "/landing", to_path: "/landing", id: sessionId, flow: "registration" };
  const help = execFileSync(t.app, ["help"], { encoding: "utf8" });
  const catalog = [...help.split("Report names")[1].matchAll(/^ {2}(\w+) .*?(?:<(\w+)>.*)?$/gm)].map(([, name, param]) => ({ name, param }));
  assert.ok(catalog.length >= 20, help);
  const both = async (name, param) => {
    const cli = JSON.parse(t.cli("report", name, "example", ...(param ? [values[param]] : []), "--json"));
    const response = await fetch(`${base}/api/v1/sites/example/${name}?range=7d${param ? `&${param}=${encodeURIComponent(values[param])}` : ""}`, { headers: { authorization: `Bearer ${token}` } });
    assert.equal(response.status, 200, name);
    return [cli, (await response.json()).rows];
  };
  for (const { name, param } of catalog) {
    let [cli, api] = await both(name, param);
    // The last 30 minutes move with the clock: ask again if a minute turned in between.
    if (name === "minutes" && JSON.stringify(cli) !== JSON.stringify(api)) [cli, api] = await both(name, param);
    assert.deepEqual(api, cli, name);
  }
  // Page-view reports take every filter, as the workspace does.
  for (const filter of ["source:direct", "page!:/landing", "country:DE"]) {
    const filtered = await fetch(`${base}/api/v1/sites/example/pages?range=7d&f=${encodeURIComponent(filter)}`, { headers: { authorization: `Bearer ${token}` } });
    assert.equal(filtered.status, 200, filter);
    assert.ok(Array.isArray((await filtered.json()).rows), filter);
  }
  // A breakdown by release, which the daily summaries leave out, still
  // counts the visit once today's summary covers it. A summary cut before
  // the visit (under 30 s old then) is forgotten so the job cuts again.
  const visited = t.db().prepare("SELECT max(received_at_ms) n FROM page_views").get().n;
  await t.until(() => {
    const db = t.db("analytico.db", { timeout: 5000 });
    try {
      const cut = db.prepare("SELECT max(until_ms) n FROM rollup_days").get().n;
      if (cut > visited) return true;
      if (cut !== null) db.exec("DELETE FROM rollup_days");
    } finally {
      db.close();
    }
  }, "today summarised past the visit", 90000);
  const releases = [{ value: "test", page_views: 1, visitor_days: 1, previous_page_views: 0, label: "test", channel: null }];
  assert.deepEqual(report("breakdown", "--dimension", "release"), releases);
  const releaseApi = await fetch(`${base}/api/v1/sites/example/breakdown?range=7d&dimension=release`, { headers: { authorization: `Bearer ${token}` } });
  assert.deepEqual((await releaseApi.json()).rows, releases);
  const minutes = JSON.parse(t.cli("report", "minutes", "example", "--json"));
  assert.equal(minutes.length, 30);
  assert.match(minutes[29].at, /^\d{4}-\d\d-\d\dT\d\d:\d\dZ$/);
  assert.deepEqual(Object.keys(JSON.parse(t.cli("report", "recent", "example", "--json"))[0]), ["received_at_ms", "kind", "name", "path", "source", "session_id", "referrer", "country", "device", "referrer_label"]);

  // ---------------------------------------------------------------- operations

  assert.match(t.cli("stats"), /duplicate_records\t4/);
  const backup = join(t.temporary, "backup.db");
  execFileSync(t.app, ["backup", t.data, backup]);
  t.server.kill("SIGTERM");
  await t.exited;
  assert.match(t.log, /serve_stopped/);
  const restored = join(t.temporary, "restored");
  execFileSync(t.app, ["restore", backup, restored]);
  assert.match(execFileSync(t.app, ["doctor", "--data", restored], { encoding: "utf8" }), /page_views=1 summaries=1 events=6/);
  // An older schema migrates only after a verified backup of the new copy.
  const old = new DatabaseSync(join(restored, "analytico.db"));
  old.exec("DROP TABLE forgotten_visitors; DROP INDEX record_receipts_time; DROP INDEX click_cells_day; DROP INDEX form_fields_day; DROP INDEX rollups_day; DROP INDEX vitals_daily_day; ALTER TABLE visitors DROP COLUMN consent_state; DELETE FROM schema_migrations WHERE version>=12; PRAGMA user_version=11");
  old.close();
  assert.throws(() => execFileSync(t.app, ["doctor", "--data", restored], { stdio: ["ignore", "pipe", "pipe"] }), /MigrationRequired/);
  execFileSync(t.app, ["migrate", "--data", restored, "--backup", join(t.temporary, "before-migrate.db")]);
  const migrated = new DatabaseSync(join(restored, "analytico.db"));
  assert.equal(migrated.prepare("PRAGMA user_version").get().user_version, 13);
  assert.equal(migrated.prepare("SELECT count(*) n FROM forgotten_visitors").get().n, 0);
  migrated.exec("INSERT INTO vitals_daily(site_id,day,metric,path,value,samples) VALUES(1,'2000-01-01','lcp','/old',100,1)");
  migrated.exec("INSERT INTO cache(site_id,name,day,value) VALUES(1,'retention','2000-01-01','{}')");
  migrated.close();
  // The service's quick pre-start check answers like the full one.
  assert.match(execFileSync(t.app, ["doctor", "--quick", "--data", restored], { encoding: "utf8" }), /^ok schema=13 /);
  // Prune takes the daily export's files of those days too.
  mkdirSync(join(restored, "exports", "example", "2019-12-31"), { recursive: true });
  writeFileSync(join(restored, "exports", "example", "2019-12-31", "events.csv.gz"), "");
  mkdirSync(join(restored, "exports", "example", "2020-01-01"), { recursive: true });
  execFileSync(t.app, ["prune", restored, "--before", "2020-01-01", "--backup", join(t.temporary, "before-prune.db")]);
  assert.deepEqual(readdirSync(join(restored, "exports", "example")), ["2020-01-01"]);
  const pruned = new DatabaseSync(join(restored, "analytico.db"));
  assert.equal(pruned.prepare("SELECT count(*) n FROM vitals_daily WHERE day<'2020-01-01'").get().n, 0);
  assert.equal(pruned.prepare("SELECT count(*) n FROM cache").get().n, 0);
  pruned.close();
  return `collector over HTTP, ${catalog.length} catalog reports alike in the CLI and the API, report values, refunds counted once, release breakdown over summaries, backup, restore and doctor`;
});
