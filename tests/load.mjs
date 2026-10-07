// Load measurement, run by hand (not part of `zig build e2e`):
//   node tests/load.mjs zig-out/bin/analytico <work-dir> [page-views] [--reads-only]
// 1. Ingest: concurrent browser batches through /e for 20 seconds.
// 2. Reads: a month of page views seeded straight into SQLite (10 million by
//    default), with remembered visitors, campaigns, Core Web Vitals, orders
//    and errors, then every heavy page timed through the workspace and the
//    read API. --reads-only times the reads again on a
//    work dir seeded by an earlier run.
import assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import { createHash, randomUUID } from "node:crypto";
import { rm } from "node:fs/promises";
import { createServer } from "node:http";
import { join, resolve } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { setTimeout as delay } from "node:timers/promises";

const app = resolve(process.argv[2]);
const work = resolve(process.argv[3]);
const seedViews = Number(process.argv[4] || 10_000_000);
const readsOnly = process.argv.includes("--reads-only");
const data = join(work, "data");
const origin = "https://load.example";

const now = Date.now();
const sessionToken = "a".repeat(64);
const apiToken = `an_${"b".repeat(64)}`;
const reservation = createServer();
await new Promise((done) => reservation.listen(0, "127.0.0.1", done));
const port = reservation.address().port;
await new Promise((done) => reservation.close(done));
let server;
const start = async () => {
  server = spawn(app, ["serve", "--data", data, "--listen", `127.0.0.1:${port}`], { stdio: ["ignore", "ignore", "pipe"] });
  server.stderr.on("data", (bytes) => { const text = String(bytes); if (!text.includes("batch_accepted")) process.stderr.write(text); });
  for (;;) {
    try { if ((await fetch(`http://127.0.0.1:${port}/readyz`)).ok) return; } catch { /* starting */ }
    await delay(100);
  }
};
const stop = async () => {
  server.kill("SIGTERM");
  await new Promise((done) => server.once("close", done));
};

// ---------------------------------------------------------------- ingest

if (!readsOnly) {
  await rm(work, { recursive: true, force: true });
  execFileSync("mkdir", ["-p", work]);
  execFileSync(app, ["init", data]);
  const added = execFileSync(app, ["site", "add", "load", origin, "--data", data], { encoding: "utf8" });
  const site = /public_id=([^ ]+)/.exec(added)[1];
  await start();
  const paths = ["/", "/pricing", "/blog/a", "/blog/b", "/checkout", "/about"];
  const latencies = [];
  let records = 0;
  const deadline = Date.now() + 20_000;
  async function client(index) {
    while (Date.now() < deadline) {
      const now = Date.now();
      const page = randomUUID();
      const common = { page_id: page, session_id: null, occurred_at_ms: now, tracking_mode: "full", consent_mode: "pending", tracker_version: "2", release_id: "", internal: false };
      const body = JSON.stringify({ v: 2, site, sent_at_ms: now, records: [
        { event_id: randomUUID(), type: "page_view", ...common, path: paths[index % paths.length], referrer_host: "www.google.com", viewport_class: "desktop", language: "en" },
        { event_id: randomUUID(), type: "page_summary", ...common, visible_ms: 12000, active_ms: 9000, interaction_count: 3, max_scroll: 75, sections: [], selection_count: 0, copy_count: 0, outbound_clicks: 0, downloads: 0, form_attempts: 0 },
      ] });
      const started = performance.now();
      const response = await fetch(`http://127.0.0.1:${port}/e`, { method: "POST", body, headers: { origin, "content-type": "text/plain", "x-forwarded-for": `198.51.100.${index % 250}`, "user-agent": "Mozilla/5.0 (X11; Linux x86_64) Chrome/140 Safari/537.36" } });
      const text = await response.text();
      assert.equal(response.status, 200, text);
      latencies.push(performance.now() - started);
      records += 2;
    }
  }
  await Promise.all(Array.from({ length: 32 }, (_, index) => client(index)));
  latencies.sort((a, b) => a - b);
  const percentile = (p) => latencies[Math.min(latencies.length - 1, Math.floor(latencies.length * p))].toFixed(1);
  console.log(`ingest: ${(records / 20).toFixed(0)} records/s (${(latencies.length / 20).toFixed(0)} batches/s, 32 clients), latency p50 ${percentile(0.5)} ms, p99 ${percentile(0.99)} ms`);
  console.log(`        = ${(latencies.length / 20 * 86400 * 30 / 1e6).toFixed(0)} million page views a month at that rate, sustained`);
  await stop();

  // Seed the reads: a month of page views written straight into SQLite.
  const db = new DatabaseSync(join(data, "analytico.db"));
  db.exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=OFF;");
  const sources = ["www.google.com", "news.ycombinator.com", "t.co", null, null, "duckduckgo.com", "newsletter"];
  const countries = ["DE", "US", "FR", "GB", "NL", "ES", "IT", "PL", "SE", "US"];
  const devices = ["desktop", "mobile", "mobile", "tablet"];
  const insertView = db.prepare(`INSERT INTO page_views(site_id,event_id,page_id,session_id,occurred_at_ms,received_at_ms,received_date,visitor_day_id,tracking_mode,path,referrer_host,
    viewport_class,language,tracker_version,consent_mode,internal,country,browser,operating_system,device,traffic_class,visitor_id,active_ms,max_scroll,interaction_count,utm_source,utm_campaign) VALUES(1,?,?,?,?,?,?,?,'full',?,?,'desktop','en','2',?,0,?,'chrome','linux',?,'human_like',?,?,?,?,?,?)`);
  const insertSummary = db.prepare(`INSERT INTO page_summaries(site_id,event_id,page_id,session_id,occurred_at_ms,received_at_ms,tracking_mode,visible_ms,active_ms,interaction_count,max_scroll,sections_json,
    selection_count,copy_count,outbound_clicks,downloads,form_attempts,tracker_version,consent_mode,internal,ttfb_ms,fcp_ms,lcp_ms,inp_ms,cls_milli) VALUES(1,?,?,?,?,?,'full',15000,9000,2,50,'[]',0,0,0,0,0,'2','granted',0,?,?,?,?,?)`);
  const insertEvent = db.prepare(`INSERT INTO events(site_id,event_id,page_id,session_id,source,occurred_at_ms,received_at_ms,received_date,tracking_mode,name,path,release_id,tracker_version,consent_mode,internal,value_minor,currency,properties_json,visitor_id,order_id)
    VALUES(1,?,?,?,'browser',?,?,?,'full',?,?,'','2','granted',0,?,?,'{}',?,?)`);
  const insertError = db.prepare(`INSERT INTO errors(site_id,event_id,page_id,session_id,visitor_id,occurred_at_ms,received_at_ms,path,release_id,fingerprint,message,file,line,col,browser,internal)
    VALUES(1,?,?,?,?,?,?,?,'',?,?,'https://load.example/app.js',?,1,'chrome',0)`);
  const seedStarted = performance.now();
  let id = 0;
  const uuid = () => { id++; const hex = id.toString(16).padStart(12, "0"); return `00000000-0000-4000-8000-${hex}`; };
  db.exec("BEGIN");
  for (let index = 0; index < seedViews; index++) {
    const at = now - Math.floor(Math.random() * 30 * 86_400_000);
    const day = new Date(at).toISOString().slice(0, 10);
    const visitor = Math.floor(Math.random() * seedViews / 3);
    const consented = visitor % 4 !== 0;
    const page = uuid();
    const session = consented ? `10000000-0000-4000-8000-${(visitor * 7 + Math.floor(at / 1_800_000) % 7).toString(16).padStart(12, "0")}` : null;
    const visitorId = consented ? `20000000-0000-4000-8000-${visitor.toString(16).padStart(12, "0")}` : null;
    const path = paths[index % paths.length] + (index % 50 ? "" : `/${index % 4000}`);
    const campaign = index % 20 === 0 ? ["google", ["spring", "autumn", "brand"][index % 3]] : [null, null];
    insertView.run(uuid(), page, session, at, at, day, (visitor % 1_000_000).toString(16).padStart(16, "0"), path, sources[index % sources.length], consented ? "granted" : "pending", countries[visitor % countries.length], devices[index % devices.length], visitorId, ...(index % 7 !== 0 ? [9000, 50, 2] : [null, null, null]), ...campaign);
    if (index % 7 !== 0) insertSummary.run(uuid(), page, session, at, at, ...(index % 3 === 0 ? [180 + index % 400, 900 + index % 900, 1400 + index % 2600, 80 + index % 300, index % 200] : [null, null, null, null, null]));
    if (index % 100 === 0) insertEvent.run(uuid(), page, session, at, at, day, "purchase", path, 1500 + index % 9000, "EUR", visitorId, `L-${index}`);
    if (index % 500 === 0) insertError.run(uuid(), page, session, visitorId, at, at, path, (index % 12).toString(16).padStart(16, "0"), `TypeError: load error ${index % 12}`, 10 + index % 12);
    if (index % 500_000 === 499_999) { db.exec("COMMIT"); db.exec("BEGIN"); }
  }
  db.exec("COMMIT");
  db.exec(`INSERT INTO visitors(site_id,visitor_id,first_seen_ms,last_seen_ms,first_source,country)
    SELECT 1,visitor_id,min(received_at_ms),max(received_at_ms),'direct',max(country) FROM page_views WHERE visitor_id IS NOT NULL GROUP BY visitor_id`);
  const spend = db.prepare("INSERT INTO campaign_spend(site_id,spend_date,source,campaign,content,amount_minor,currency,created_at_ms) VALUES(1,?,'google',?,'',?,'EUR',?)");
  for (let day = 0; day < 30; day++) for (const name of ["spring", "autumn", "brand"]) spend.run(new Date(now - day * 86_400_000).toISOString().slice(0, 10), name, 5000 + day * 37, now);
  db.exec("PRAGMA wal_checkpoint(TRUNCATE)");
  db.close();
  console.log(`seeded ${seedViews.toLocaleString("en-US")} page views over 30 days in ${((performance.now() - seedStarted) / 1000).toFixed(0)} s`);
}

// ---------------------------------------------------------------- reads

// The workspace session and an API key, as the workspace would create them.
const sha = (value) => createHash("sha256").update(value).digest("hex");
const auth = new DatabaseSync(join(data, "analytico.db"));
auth.prepare("INSERT OR IGNORE INTO users(id,email,role,created_at_ms) VALUES(1,'owner@load.example','owner',?)").run(now);
auth.prepare("INSERT OR REPLACE INTO web_sessions(token_hash,user_id,created_at_ms,expires_at_ms) VALUES(?,1,?,?)").run(sha(sessionToken), now, now + 86_400_000);
auth.prepare("INSERT OR IGNORE INTO api_keys(name,token_hash,prefix,user_id,site_id,created_at_ms) VALUES('load',?,'bbbb',1,NULL,?)").run(sha(apiToken), now);
auth.close();

await start();
// The background job summarises closed days and today up to a recent cut,
// as it keeps doing while the server runs; wait for both.
const rolling = performance.now();
const reader = new DatabaseSync(join(data, "analytico.db"), { readOnly: true });
const today = Date.now() - Date.now() % 86_400_000;
const closedDays = Number(reader.prepare("SELECT count(DISTINCT received_date) n FROM page_views WHERE received_at_ms<?").get(today).n);
const todayRows = Number(reader.prepare("SELECT count(*) n FROM page_views WHERE received_at_ms>=?").get(today).n);
for (;;) {
  const done = Number(reader.prepare("SELECT count(*) n FROM rollup_days WHERE until_ms%86400000=0").get().n);
  const partial = Number(reader.prepare("SELECT count(*) n FROM rollup_days WHERE until_ms>?").get(today).n);
  // After 03:00 the first run also backs up and prunes, which competes with reads.
  const nightly = Number(reader.prepare("SELECT coalesce((SELECT value FROM settings WHERE name='jobs.nightly_at'),'0') v").get().v);
  const nightlyDone = Date.now() < today + 3 * 3_600_000 || nightly >= today + 3 * 3_600_000;
  if (done >= closedDays && (todayRows === 0 || partial > 0) && nightlyDone) break;
  await delay(2000);
}
reader.close();
console.log(`rolled up ${closedDays} closed days and ${todayRows.toLocaleString("en-US")} rows of today in ${((performance.now() - rolling) / 1000).toFixed(0)} s (background job, 10 s of work every 30 s, plus the nightly backup)`);
const timed = async (label, url, headers) => {
  const times = [];
  for (let attempt = 0; attempt < 3; attempt++) {
    const started = performance.now();
    const response = await fetch(`http://127.0.0.1:${port}${url}`, { headers });
    assert.equal(response.status, 200, `${label}: ${response.status}`);
    await response.arrayBuffer();
    times.push(performance.now() - started);
  }
  times.sort((a, b) => a - b);
  console.log(`  ${label.padEnd(34)} ${times[1].toFixed(0).padStart(6)} ms (median of 3)`);
};
const cookie = { cookie: `an_s=${sessionToken}` };
const bearer = { authorization: `Bearer ${apiToken}` };
console.log("reads at that size:");
await timed("workspace overview, 30 days", "/load?range=30d", cookie);
await timed("workspace overview, 7 days", "/load", cookie);
await timed("workspace pages, 30 days", "/load/pages?range=30d", cookie);
await timed("workspace audience, 30 days", "/load/audience?range=30d", cookie);
await timed("workspace retention", "/load/retention", cookie);
await timed("workspace people, 30 days", "/load/people?range=30d", cookie);
await timed("workspace sessions, 7 days", "/load/sessions?range=7d", cookie);
await timed("workspace paths, 30 days", "/load/sessions?tab=paths&range=30d", cookie);
await timed("workspace revenue, 30 days", "/load/revenue?range=30d", cookie);
await timed("workspace performance, 30 days", "/load/performance?range=30d", cookie);
await timed("workspace errors, 30 days", "/load/errors?range=30d", cookie);
await timed("workspace events, 30 days", "/load/events?range=30d", cookie);
await timed("workspace campaigns, 30 days", "/load/acquisition?tab=campaigns&range=30d", cookie);
await timed("API overview, 30 days", "/api/v1/sites/load/overview?range=30d", bearer);
await timed("API breakdown by country, 30 days", "/api/v1/sites/load/breakdown?dimension=country&range=30d", bearer);
await timed("API time series, 30 days", "/api/v1/sites/load/timeseries?metric=visitors&range=30d", bearer);
await stop();
