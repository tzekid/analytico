// The command line and the collector without a browser: sites, goals,
// funnels and spend from the CLI; browser and server batches over HTTP
// (no client address, duplicates, a foreign origin, a conflicting replay, a
// signed server event); the reports' values; every catalog report alike
// through the CLI and the read API; backup, restore and doctor.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { createHash, createHmac } from "node:crypto";
import { join } from "node:path";
import { Script } from "node:vm";
import { journey } from "./harness.mjs";

await journey("cli", async (t) => {
  t.init();
  const added = t.cli("site", "add", "example", "https://example.test", "--mode", "session");
  const site = /public_id=([^ ]+)/.exec(added)[1];
  const secret = /internal_secret=([0-9a-f]+)/.exec(added)[1];
  t.cli("campaign", "spend-add", "example", new Date().toISOString().slice(0, 10), "search", "launch", "hero", "1000", "EUR");
  t.cli("goal", "add", "example", "registration-start", "event", "registration_started");
  t.cli("goal", "add", "example", "paid", "event", "payment_confirmed");
  t.cli("funnel", "add", "example", "registration-to-paid", "registration-start", "paid");
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
  const collect = async (batch, origin, address) => (await fetch(`${base}/e`, {
    method: "POST",
    headers: { origin, "content-type": "text/plain;charset=UTF-8", ...(address ? { "x-forwarded-for": address } : {}) },
    body: JSON.stringify({ v: 1, site, sent_at_ms: now, records: batch }),
  })).status;
  assert.equal(await collect(records, "https://example.test"), 400, "no client address");
  assert.equal(await collect(records, "https://example.test", "198.51.100.10"), 204);
  assert.equal(await collect(records, "https://example.test", "198.51.100.10"), 204, "duplicates");
  assert.equal(await collect(records, "https://denied.test", "198.51.100.10"), 403);
  assert.equal(await collect([{ ...records[0], path: "/changed" }, ...records.slice(1)], "https://example.test", "198.51.100.10"), 409);

  const serverBatch = JSON.stringify({ v: 1, site, sent_at_ms: Date.now(), records: [{ ...common, event_id: "550e8400-e29b-41d4-a716-446655440005", type: "event", occurred_at_ms: Date.now(), consent_mode: "server", tracker_version: "backend-1", name: "payment_confirmed", value_minor: 4900, currency: "EUR", properties: { source: "search", campaign: "launch", content: "hero" } }] });
  const stamp = String(Math.floor(Date.now() / 1000));
  const signature = createHmac("sha256", Buffer.from(secret, "hex")).update(`${stamp}.${serverBatch}`).digest("hex");
  const signed = await fetch(`${base}/i`, { method: "POST", headers: { "content-type": "application/json", "x-analytico-timestamp": stamp, "x-analytico-signature": signature }, body: serverBatch });
  assert.ok(signed.ok, await signed.text());

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
  assert.deepEqual(report("acquisition"), [{ source: "search", medium: "", views: 1, visitors: 1 }]);
  assert.deepEqual(report("campaigns"), [{ source: "search", campaign: "launch", content: "hero", views: 1, visitors: 1, sessions: 1 }]);
  assert.deepEqual(report("sections"), [{ section: "hero", exposures: 1, exposure_percent: 100, final_section: 1 }]);
  // The browser journey separately checks an actual click produces an action.
  assert.deepEqual(report("actions"), []);
  assert.deepEqual(report("events"), [
    { name: "flow_started", source: "browser", occurrences: 1, sessions: 1, value_minor: 0, currency: "" },
    { name: "payment_confirmed", source: "server", occurrences: 1, sessions: 1, value_minor: 4900, currency: "EUR" },
    { name: "registration_started", source: "browser", occurrences: 1, sessions: 1, value_minor: 0, currency: "" },
  ]);
  const recent = report("recent");
  assert.deepEqual(recent.map(({ name }) => name).sort(), ["flow_started", "page_view", "payment_confirmed", "registration_started"]);
  for (const row of recent) {
    assert.ok(Number.isInteger(row.received_at_ms) && row.received_at_ms > 0);
    assert.equal(row.session_id, sessionId);
    assert.equal(row.source, row.name === "payment_confirmed" ? "server" : "browser");
    assert.equal(row.path, row.name === "page_view" ? "/landing" : row.name === "payment_confirmed" ? "" : "/register");
  }
  assert.deepEqual(report("coverage"), [{
    page_views: 1, summaries: 1, summary_percent: 100, unknown_traffic: 0,
    session_identified: 1, internal_page_views: 0, rum_samples: 1,
  }]);
  for (const kind of ["pages", "acquisition", "campaigns", "sections", "actions", "events", "recent"]) {
    assert.deepEqual(report(kind, "--path", "/absent"), [], `${kind}: empty filtered result`);
  }
  const emptyCoverage = report("coverage", "--path", "/absent")[0];
  assert.deepEqual([emptyCoverage.page_views, emptyCoverage.summaries, emptyCoverage.rum_samples], [0, 0, 0]);

  // Every report in the catalog answers the same through the CLI and the API.
  const token = `an_${"d".repeat(64)}`;
  const writer = t.db("analytico.db", {});
  writer.prepare("INSERT INTO users(email,role,created_at_ms) VALUES('owner@example.test','owner',?)").run(now);
  writer.prepare("INSERT INTO api_keys(name,token_hash,prefix,user_id,site_id,created_at_ms) VALUES('cli',?,'dddd',(SELECT min(id) FROM users),NULL,?)").run(createHash("sha256").update(token).digest("hex"), now);
  writer.close();
  const values = { dimension: "page", name: "registration-to-paid", from_path: "/landing", id: sessionId, flow: "registration" };
  const help = execFileSync(t.app, ["help"], { encoding: "utf8" });
  const catalog = [...help.split("Report names")[1].matchAll(/^ {2}(\w+) .*?(?:<(\w+)>)?$/gm)].map(([, name, param]) => ({ name, param }));
  assert.ok(catalog.length >= 20, help);
  for (const { name, param } of catalog) {
    const cli = JSON.parse(t.cli("report", name, "example", ...(param ? [values[param]] : []), "--json"));
    const response = await fetch(`${base}/api/v1/sites/example/${name}?range=7d${param ? `&${param}=${encodeURIComponent(values[param])}` : ""}`, { headers: { authorization: `Bearer ${token}` } });
    assert.equal(response.status, 200, name);
    assert.deepEqual((await response.json()).rows, cli, name);
  }

  // ---------------------------------------------------------------- operations

  assert.match(t.cli("stats"), /duplicate_records\t4/);
  const backup = join(t.temporary, "backup.db");
  execFileSync(t.app, ["backup", t.data, backup]);
  t.server.kill("SIGTERM");
  await t.exited;
  assert.match(t.log, /serve_stopped/);
  const restored = join(t.temporary, "restored");
  execFileSync(t.app, ["restore", backup, restored]);
  assert.match(execFileSync(t.app, ["doctor", "--data", restored], { encoding: "utf8" }), /page_views=1 summaries=1 events=3/);
  return `collector over HTTP, ${catalog.length} catalog reports alike in the CLI and the API, report values, backup, restore and doctor`;
});
