import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";

const [app, data] = process.argv.slice(2);
const report = (kind, ...options) => JSON.parse(execFileSync(app,
  ["report", kind, "example", "--days", "7", "--json", "--data", data, ...options],
  { encoding: "utf8" }));

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
assert.equal(recent.length, 4);
assert.deepEqual(recent.map(({ name }) => name).sort(), ["flow_started", "page_view", "payment_confirmed", "registration_started"]);
for (const row of recent) {
  assert.ok(Number.isInteger(row.received_at_ms) && row.received_at_ms > 0);
  assert.equal(row.session_id, "550e8400-e29b-41d4-a716-446655440002");
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
assert.equal(emptyCoverage.page_views, 0);
assert.equal(emptyCoverage.summaries, 0);
assert.equal(emptyCoverage.rum_samples, 0);
console.log("reports: fixture values, attribution, coverage, and empty results verified");
