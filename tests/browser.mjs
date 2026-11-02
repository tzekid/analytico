// The tracker in a real browser: Lite never touches storage; Session keeps
// one identity across navigation; marked actions travel with the summary.
import assert from "node:assert/strict";
import { journey } from "./harness.mjs";

await journey("browser", async (t) => {
  const snippets = new Map([["/done", "<p>Finished</p>"]]);
  // Only this fixture proxy supplies the client address; the collector keeps
  // its normal mandatory proxy-header and exact-origin validation.
  const origin = `http://127.0.0.1:${await t.proxy("198.51.100.42", (path) => snippets.has(path) && `<!doctype html><title>Tracker fixture</title><button data-analytics-action="register">Register</button><a id="again" href="${path}">Again</a>${snippets.get(path)}`)}`;
  const report = (kind, site) => JSON.parse(t.cli("report", kind, site, "--json"));
  t.init();
  const publicIds = {};
  for (const mode of ["lite", "session"]) {
    publicIds[mode] = /public_id=([^ ]+)/.exec(t.cli("site", "add", mode, origin, "--mode", mode))[1];
    snippets.set(`/${mode}`, t.cli("site", "snippet", mode, origin));
  }
  await t.serve();
  const context = await t.context();

  const collected = (page, kind) => page.waitForResponse((response) => {
    if (response.url() !== `${origin}/e` || response.request().method() !== "POST") return false;
    return JSON.parse(response.request().postData()).records.some((record) => record.type === kind);
  });
  async function visit(page, path) {
    const [response] = await Promise.all([collected(page, "page_view"), page.goto(`${origin}${path}`)]);
    assert.equal(response.status(), 204, await response.text());
  }

  const lite = await context.newPage();
  await lite.addInitScript(() => {
    window.storageAccesses = 0;
    const denied = () => { window.storageAccesses++; throw new DOMException("Storage disabled", "SecurityError"); };
    for (const name of ["localStorage", "sessionStorage"]) Object.defineProperty(window, name, { get: denied });
    Object.defineProperty(document, "cookie", { get: denied, set: denied });
  });
  await visit(lite, "/lite");
  assert.equal(await lite.evaluate(() => window.storageAccesses), 0);
  assert.equal(report("overview", "lite")[0].page_views, 1);
  assert.equal(report("overview", "lite")[0].sessions, 0);
  assert.equal(report("pages", "lite")[0].path, "/lite");
  // A page reached from the site itself has no source of its own in Lite,
  // which keeps nothing between pages: it is filed as within the site.
  await Promise.all([collected(lite, "page_view"), lite.locator("#again").click()]);
  assert.deepEqual(report("acquisition", "lite").map(({ source, views }) => [source, views]).sort(), [["(self)", 1], ["direct", 1]]);

  const session = await context.newPage();
  await visit(session, "/session?utm_source=newsletter");
  const sessionId = await session.evaluate((site) => sessionStorage.getItem(`analytico:${site}:session`), publicIds.session);
  assert.match(sessionId, /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
  // The next page, reached by a link, carries the visit's source.
  await Promise.all([collected(session, "page_view"), session.locator("#again").click()]);
  assert.deepEqual(report("acquisition", "session").map(({ source, views }) => [source, views]), [["newsletter", 2]]);
  const sessions = JSON.parse(t.cli("session", "list", "session", "--json"));
  assert.equal(sessions.length, 1);
  assert.equal(sessions[0].session_id, sessionId);
  assert.equal(sessions[0].page_views, 2);
  await session.getByRole("button", { name: "Register" }).click();
  // Actions intentionally travel with the page summary on navigation.
  await session.goto(`${origin}/done`);
  const actions = await t.until(() => { const rows = report("actions", "session"); return rows.length && rows; }, "action reported", 5000);
  assert.deepEqual(actions, [{ name: "action_started", action: "register", occurrences: 1 }]);

  // Within the collector's bounds: a long non-ASCII campaign is cut to whole
  // characters within 128 bytes; a section name with a space, and sections
  // past 32, are left out, so the summary and its queued event still land.
  const db = t.db();
  snippets.set("/bounds", snippets.get("/session") + `<h2 data-analytics-section="our team">Team</h2>${Array.from({ length: 40 }, (_, index) => `<span data-analytics-section="part-${index}">${index}</span>`).join(" ")}`);
  const bounded = await context.newPage();
  await visit(bounded, `/bounds?utm_campaign=${encodeURIComponent("春".repeat(60))}`);
  await bounded.evaluate(() => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done))));
  await bounded.evaluate(() => analytico.track("signup_started"));
  await bounded.goto(`${origin}/done`);
  const stored = await t.until(() => db.prepare("SELECT pv.utm_campaign c,ps.sections_json s FROM page_views pv JOIN page_summaries ps ON ps.page_id=pv.page_id WHERE pv.path='/bounds'").get(), "bounded summary");
  assert.equal(stored.c, "春".repeat(42));
  assert.deepEqual([JSON.parse(stored.s).length, JSON.parse(stored.s).includes("our team")], [32, false]);
  assert.equal(db.prepare("SELECT count(*) n FROM events WHERE name='signup_started'").get().n, 1);
  // A busy page keeps every event past fifteen; an outcome only the backend
  // may report is refused here (the server would refuse the whole batch);
  // a data: download sends its name, never its content.
  const busy = await context.newPage();
  await visit(busy, "/session");
  const refusedOutcome = await busy.evaluate(() => {
    for (let index = 0; index < 20; index++) analytico.track("busy_click", { n: index });
    const link = document.createElement("a");
    link.id = "export";
    link.textContent = "Export";
    link.download = "export.json";
    link.href = "data:application/json;charset=utf-8," + encodeURIComponent(JSON.stringify({ name: "Jane Doe", phone: "+49 30 1234567" }));
    link.addEventListener("click", (event) => event.preventDefault());
    document.body.append(link);
    return analytico.track("payment_confirmed", {});
  });
  assert.equal(refusedOutcome, "");
  await busy.locator("#export").click();
  await busy.goto(`${origin}/done`);
  await t.until(() => db.prepare("SELECT count(*) n FROM events WHERE name='busy_click'").get().n === 20, "every event stored");
  assert.deepEqual(db.prepare("SELECT json_extract(properties_json,'$.file') f FROM events WHERE name='file_download'").all().map((row) => row.f), ["export.json"]);

  // Back to a page kept in the back/forward cache: a new view with the
  // visit's source, and what it tracks still goes out. (Playwright runs
  // Chromium without that cache, so the page gets the same two events.)
  const restored = await context.newPage();
  await visit(restored, "/session?utm_source=podcast");
  await Promise.all([collected(restored, "page_view"), restored.evaluate(() => {
    dispatchEvent(new PageTransitionEvent("pagehide", { persisted: true }));
    dispatchEvent(new PageTransitionEvent("pageshow", { persisted: true }));
  })]);
  await restored.evaluate(() => analytico.track("restored_click"));
  await restored.goto(`${origin}/done`);
  await t.until(() => db.prepare("SELECT count(*) n FROM events WHERE name='restored_click'").get().n === 1, "event tracked after the restore");
  assert.deepEqual({ ...db.prepare("SELECT utm_source,count(*) n FROM page_views WHERE navigation_type='back_forward'").get() }, { utm_source: "podcast", n: 1 });
  return "Lite persists without storage; Session persists the same identity and the visit's source across navigation; Lite files internal pages as within the site; values past the collector's bounds are trimmed; a back/forward restore is a new view";
});
