// The tour: every screen of a seeded demo shop, driven the way a person
// would, with a screenshot, page errors, failed requests, Server-Timing,
// horizontal overflow and axe accessibility findings per step. Run by hand
// before a release (docs/TOUR.md); not part of `zig build e2e`.
//   node tests/tour.mjs <analytico> <work-dir> <dbip-city-lite.csv.gz>
// The first run seeds <work-dir>/pristine (about 20 minutes); every run
// starts from a copy of it and writes <work-dir>/out.
import { execFileSync, spawn } from "node:child_process";
import { cpSync, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { createServer, request } from "node:http";
import { createRequire } from "node:module";
import { join, resolve } from "node:path";
import { setTimeout as delay } from "node:timers/promises";
import { chromium } from "playwright-core";

const [binary, work, geoCsv] = process.argv.slice(2).map((arg) => resolve(arg));
const pristine = join(work, "pristine");
const dir = join(work, "data");
const statePath = join(work, "state.json");
const out = join(work, "out");
mkdirSync(work, { recursive: true });
if (!existsSync(pristine)) execFileSync("node", [join(import.meta.dirname, "tour-seed.mjs"), binary, pristine, geoCsv, statePath], { stdio: "inherit" });
rmSync(dir, { recursive: true, force: true });
cpSync(pristine, dir, { recursive: true });
rmSync(out, { recursive: true, force: true });
const PORT = 4401;
const PROXY = 4402;
const base = `http://localhost:${PORT}`;
const axe = readFileSync(createRequire(import.meta.url).resolve("axe-core/axe.min.js"), "utf8");
mkdirSync(join(out, "shots"), { recursive: true });
const cli = (...args) => execFileSync(binary, [...args, "--data", dir], { encoding: "utf8" });

const server = spawn(binary, ["serve", "--data", dir, "--listen", `127.0.0.1:${PORT}`], { stdio: ["ignore", "ignore", "pipe"] });
let serverLog = "";
server.stderr.on("data", (bytes) => { serverLog += bytes; });
process.on("exit", () => server.kill("SIGKILL"));
// The first start rebuilds every rollup, which takes a while.
for (let i = 0; i < 1200; i++) { try { if ((await fetch(`${base}/readyz`)).ok) break; } catch {} await delay(100); }
// Let the start-up work (rollups, the daily anomaly check) finish first.
for (let i = 0; i < 120; i++) { if (/anomaly_noted|jobs_/.test(serverLog) && i > 20) break; await delay(500); }
await delay(3000);

// The demo site, served again so the heatmap overlay has a page to draw on.
const snippet = cli("site", "snippet", "fieldnotes", "http://fieldnotes.example", "--rum").trim();
const fixture = (await import("./tour-fixture.mjs")).pages(snippet);
const proxy = createServer((incoming, outgoing) => {
  const path = incoming.url.split("?")[0];
  if (incoming.method === "GET" && fixture[path]) { outgoing.writeHead(200, { "content-type": "text/html; charset=utf-8" }); return outgoing.end(fixture[path]); }
  const upstream = request({ hostname: "127.0.0.1", port: PORT, path: incoming.url, method: incoming.method, headers: { ...incoming.headers, "x-forwarded-for": "81.169.145.105", connection: "close" } }, (response) => { outgoing.writeHead(response.statusCode, response.headers); response.pipe(outgoing); });
  upstream.on("error", (error) => outgoing.destroy(error));
  incoming.pipe(upstream);
});
await new Promise((done) => proxy.listen(PROXY, "127.0.0.1", done));

const browser = await chromium.launch({ executablePath: process.env.CHROMIUM_PATH || "/usr/bin/chromium", headless: true, args: [`--host-resolver-rules=MAP fieldnotes.example 127.0.0.1:${PROXY}`] });
const desktop = await browser.newContext({ viewport: { width: 1440, height: 960 }, deviceScaleFactor: 2, storageState: statePath, reducedMotion: "reduce" });
desktop.setDefaultTimeout(15000);
const page = await desktop.newPage();

let current = null;
const watch = (target) => {
  target.on("console", (message) => { if (message.type() === "error" && current) current.console.push(message.text().slice(0, 300)); });
  target.on("pageerror", (error) => { if (current) current.console.push(`pageerror: ${error.message.slice(0, 300)}`); });
  target.on("response", (response) => { if (current && response.status() >= 400 && !response.url().includes("favicon")) current.failed.push(`${response.status()} ${response.url().replace(base, "").slice(0, 160)}`); });
  target.on("requestfailed", (failure) => { const text = failure.failure()?.errorText || ""; if (current && !/ERR_ABORTED/.test(text)) current.failed.push(`${text} ${failure.url().replace(base, "").slice(0, 160)}`); });
};
watch(page);

const results = [];
async function audit(target) {
  // Evaluated over the debugging channel: the page's CSP rightly refuses inline scripts.
  await target.evaluate(axe).catch(() => {});
  return target.evaluate(async () => {
    if (!window.axe) return null;
    const result = await window.axe.run(document, { runOnly: { type: "tag", values: ["wcag2a", "wcag2aa"] }, resultTypes: ["violations"] });
    return result.violations.map((v) => ({
      id: v.id, impact: v.impact, nodes: v.nodes.length, help: v.help,
      samples: v.nodes.slice(0, 3).map((n) => {
        const data = n.any[0]?.data;
        const contrast = data?.contrastRatio ? ` (${data.fgColor} on ${data.bgColor}, ${data.contrastRatio}:1)` : "";
        return `${n.target.join(" ").slice(0, 100)}${contrast}`;
      }),
    }));
  }).catch(() => null);
}
async function step(id, title, section, run, options = {}) {
  current = { id, title, section, ok: true, error: "", console: [], failed: [], timing: "", ms: 0, overflow: false, axe: null, notes: [] };
  const started = Date.now();
  const target = options.page || page;
  try {
    const response = await run(target, current);
    if (response?.headers) current.timing = response.headers()["server-timing"] || "";
    await target.waitForLoadState("networkidle", { timeout: 4000 }).catch(() => {});
    await delay(options.settle ?? 350);
    current.overflow = await target.evaluate(() => document.documentElement.scrollWidth > window.innerWidth + 1).catch(() => false);
    if (options.audit !== false) current.axe = await audit(target);
    await target.screenshot({ path: join(out, "shots", `${id}.png`), fullPage: options.full !== false, ...(options.clip ? { clip: options.clip } : {}) });
  } catch (error) {
    current.ok = false;
    current.error = error.message.split("\n")[0].slice(0, 300);
    await target.screenshot({ path: join(out, "shots", `${id}.png`), fullPage: false }).catch(() => {});
  }
  current.ms = Date.now() - started;
  results.push(current);
  console.log(`${current.ok ? "ok  " : "FAIL"} ${id.padEnd(30)} ${current.ms}ms ${current.timing.slice(0, 60)} ${current.console.length ? `console:${current.console.length}` : ""} ${current.failed.length ? `failed:${current.failed.length}` : ""} ${current.error}`);
  current = null;
}
const go = (path) => (target) => target.goto(`${base}${path}`);
const expectText = async (target, text) => { await target.getByText(text, { exact: false }).first().waitFor({ timeout: 8000 }); };

// ---------------------------------------------------------------- overview and traffic

await step("01-overview", "Overview, last 30 days", "Overview", async (p, s) => {
  const response = await p.goto(`${base}/fieldnotes?range=30d`);
  await p.getByRole("heading", { name: "Overview" }).waitFor();
  const note = p.locator("[data-draft-note]");
  if (await note.count()) s.notes.push(`Draft anomaly note: ${(await note.first().textContent()).replace(/\s+/g, " ").trim()}`);
  else s.notes.push("No draft anomaly note shown");
  return response;
});
await step("02-overview-7d-compare", "Overview, 7 days, compared with the week before", "Overview", go("/fieldnotes?range=7d"));
await step("03-overview-90d", "Overview, 90 days", "Overview", go("/fieldnotes?range=90d"));
await step("04-insights", "What stood out (insights card, loads lazily)", "Overview", async (p) => {
  const response = await p.goto(`${base}/fieldnotes?range=30d`);
  await p.locator("[data-lazy][data-ready]").waitFor({ state: "attached", timeout: 10000 });
  await p.locator("[data-lazy]").scrollIntoViewIfNeeded();
  return response;
});
await step("05-filter-popover", "Filter popover: Country is DE", "Filters", async (p) => {
  await p.goto(`${base}/fieldnotes?range=30d`);
  await p.getByRole("button", { name: "Filter" }).click();
  const filter = p.locator("#filter-pop");
  await filter.locator("[data-dim]").first().selectOption("country");
  await filter.locator("[data-value]").first().fill("DE");
  await p.locator("[data-match-out]").waitFor({ state: "visible", timeout: 8000 }).catch(() => {});
  await delay(600);
}, { full: false });
await step("06-filtered", "Overview filtered to Germany", "Filters", async (p) => {
  await p.locator("#filter-pop").getByRole("button", { name: "Apply" }).click();
  await p.waitForURL(/f=country/);
  await p.locator(".chips .chip").first().waitFor();
});
await step("07-source-drilldown", "Click a source: Hacker News", "Filters", async (p) => {
  await p.goto(`${base}/fieldnotes?range=30d`);
  await p.locator("a.rank-row", { hasText: "Hacker News" }).first().click();
  await p.waitForURL(/source/);
});
await step("08-pages", "Pages, 30 days", "Traffic", go("/fieldnotes/pages?range=30d"));
await step("09-page-sheet", "A page's detail sheet", "Traffic", async (p) => {
  await p.goto(`${base}/fieldnotes/pages?range=30d`);
  await p.locator("tr", { hasText: "/guides/urban-gardens" }).first().click();
  await p.locator("dialog.sheet[open]").waitFor();
  await delay(500);
}, { full: false });
await step("10-page-sections", "Page sheet: sections seen", "Traffic", go("/fieldnotes/pages?range=30d&page=%2Fguides%2Furban-gardens&pt=sections"), { full: false });
await step("11-page-paths", "Page sheet: where visitors went next", "Traffic", go("/fieldnotes/pages?range=30d&page=%2Fguides%2Furban-gardens&pt=paths"), { full: false });
await step("12-outbound", "Pages: outbound links and downloads", "Traffic", go("/fieldnotes/pages?tab=outbound&range=30d"));
await step("13-acquisition", "Acquisition: sources", "Traffic", go("/fieldnotes/acquisition?range=30d"));
await step("14-campaigns", "Acquisition: campaigns with ad spend", "Traffic", go("/fieldnotes/acquisition?tab=campaigns&range=30d"));
await step("15-channels", "Acquisition: channels", "Traffic", go("/fieldnotes/acquisition?tab=channels&range=30d"));
await step("16-search", "Site search terms", "Traffic", go("/fieldnotes/search?range=30d"));
await step("17-audience", "Audience: places, devices, browsers", "Traffic", go("/fieldnotes/audience?range=30d"));

// ---------------------------------------------------------------- behaviour

await step("18-events", "Events", "Behaviour", go("/fieldnotes/events?range=30d"));
await step("19-goals", "Goals", "Behaviour", go("/fieldnotes/events?tab=goals&range=30d"));
await step("20-goal-dialog", "Track a new goal", "Behaviour", async (p) => {
  await p.goto(`${base}/fieldnotes/events?goal=%2B`);
  const dialog = p.locator("#goal-dialog");
  await dialog.getByLabel("Goal name").fill("Read the tomato guide");
  await dialog.getByText("Page visit").click();
  await dialog.getByLabel("Matches").fill("/guides/balcony-tomatoes");
  await delay(400);
}, { full: false });
await step("21-goal-created", "Goal tracked", "Behaviour", async (p) => {
  await p.locator("#goal-dialog").getByRole("button", { name: "Track goal" }).click();
  await p.locator(".toast", { hasText: "Tracking" }).waitFor();
});
await step("22-funnels", "Funnels", "Behaviour", go("/fieldnotes/funnels?range=30d"));
await step("23-funnel", "Funnel: shop to purchase", "Behaviour", async (p) => {
  await p.goto(`${base}/fieldnotes/funnels?range=30d`);
  const link = p.locator("a[href*='/fieldnotes/funnels/']").first();
  return p.goto(`${base}${await link.getAttribute("href")}${(await link.getAttribute("href")).includes("?") ? "&" : "?"}range=30d`);
});
await step("24-forms", "Form analytics", "Behaviour", go("/fieldnotes/funnels?tab=forms&range=7d"));
await step("25-sessions", "Sessions", "Behaviour", go("/fieldnotes/sessions"));
await step("26-sessions-recorded", "Sessions with a replay", "Behaviour", go("/fieldnotes/sessions?signal=recorded"));
await step("27-replay", "Session replay", "Behaviour", async (p) => {
  await p.goto(`${base}/fieldnotes/sessions?signal=recorded`);
  await p.locator("a.btn-replay").first().click();
  await p.waitForURL(/\/replays\//);
  await p.locator(".player.loaded").waitFor({ timeout: 15000 });
  await p.locator("[data-play]").click();
  await delay(2500);
}, { full: false, settle: 800 });
await step("28-paths", "Paths through the site", "Behaviour", go("/fieldnotes/sessions?tab=paths&range=30d"));
await step("29-live", "Live sessions", "Behaviour", go("/fieldnotes/sessions?tab=live"));
await step("30-heatmaps", "Heatmaps", "Behaviour", go("/fieldnotes/heatmaps?range=7d"));
const overlayPage = await desktop.newPage();
watch(overlayPage);
await step("31-overlay", "Heatmap overlay on the live page", "Behaviour", async (p) => {
  await page.goto(`${base}/fieldnotes/heatmaps?range=7d`);
  const card = page.locator(".heat-card").first();
  const href = await card.getByRole("link", { name: /Open on site/ }).getAttribute("href");
  await p.goto(`${base}${href}`);
  await p.waitForURL(/#analytico-heatmap=/);
  await p.locator("#analytico-overlay .note").waitFor({ timeout: 10000 });
  await delay(1200);
}, { page: overlayPage, full: false, audit: false });
await overlayPage.close();

// ---------------------------------------------------------------- customers and quality

await step("32-errors", "Errors", "Quality", go("/fieldnotes/errors?range=30d"));
await step("33-error-sheet", "An error's detail", "Quality", async (p) => {
  await p.goto(`${base}/fieldnotes/errors?range=30d`);
  await p.locator("tr", { hasText: "reading 'total'" }).first().locator("a").first().click();
  await p.locator(".error-detail", { hasText: "reading 'total'" }).waitFor();
  await delay(400);
}, { full: false });
await step("34-revenue", "Revenue", "Customers", go("/fieldnotes/revenue?range=30d"));
await step("35-retention", "Retention cohorts", "Customers", go("/fieldnotes/retention"));
await step("36-people", "People", "Customers", go("/fieldnotes/people?range=30d"));
await step("37-person", "One person", "Customers", async (p) => {
  await p.goto(`${base}/fieldnotes/people?segment=identified&range=90d`);
  return p.goto(`${base}${await p.locator("tr[data-href]").first().getAttribute("data-href")}`);
});
await step("38-performance", "Performance (Core Web Vitals)", "Quality", go("/fieldnotes/performance?range=30d"));
await step("39-health", "Data health", "Quality", go("/fieldnotes/health"));

// ---------------------------------------------------------------- working with it

await step("40-palette", "Command palette (⌘K)", "Workspace", async (p) => {
  await p.goto(`${base}/fieldnotes?range=30d`);
  await p.keyboard.press("Control+k");
  await p.locator("#palette input").fill("tomato");
  await delay(700);
}, { full: false });
await step("41-shortcuts", "Keyboard shortcuts (?)", "Workspace", async (p) => {
  await p.goto(`${base}/fieldnotes`);
  await p.keyboard.press("?");
  await p.locator("#shortcuts").waitFor();
}, { full: false });
await step("42-note", "Add a chart note", "Workspace", async (p) => {
  await p.goto(`${base}/fieldnotes?range=30d`);
  await p.getByRole("button", { name: "More actions" }).click();
  await p.getByRole("button", { name: "Add a note…" }).click();
  await p.locator("#note-dialog").getByLabel("Note").fill("Autumn bulbs campaign");
  await p.locator("#note-dialog").getByRole("button", { name: "Add note" }).click();
  await p.locator(".chart-mark", { hasText: "Autumn bulbs" }).waitFor();
});
await step("43-keep-draft", "Keep the drafted anomaly note", "Workspace", async (p, s) => {
  await p.goto(`${base}/fieldnotes?range=30d`);
  const note = p.locator("[data-draft-note]").first();
  if (!(await note.count())) { s.notes.push("No draft to keep"); return; }
  await note.getByRole("button", { name: "Keep as a note" }).click();
  await p.locator(".toast", { hasText: "Note kept" }).waitFor();
});
await step("44-alert", "Create an alert (with a 30-day preview)", "Workspace", async (p) => {
  await p.goto(`${base}/fieldnotes?range=30d`);
  await p.getByRole("button", { name: "More actions" }).click();
  await p.getByRole("button", { name: "Create alert…" }).click();
  await p.locator("[data-alert-verdict]", { hasText: "Would" }).waitFor();
  await delay(400);
}, { full: false });
await step("45-alert-created", "Alert created", "Workspace", async (p) => {
  await p.locator("#alert-dialog").getByRole("button", { name: "Create alert" }).click();
  await p.locator(".toast", { hasText: "Alert created" }).waitFor();
});
await step("46-reports", "Reports & alerts", "Workspace", go("/fieldnotes/reports?tab=alerts"));
await step("47-dashboards", "Dashboards", "Workspace", go("/fieldnotes/dashboards"));
let shareUrl = "";
await step("48-share", "Share a public link", "Workspace", async (p) => {
  await p.goto(`${base}/fieldnotes?range=30d`);
  await p.getByRole("button", { name: "More actions" }).click();
  await p.getByRole("button", { name: "Share publicly…" }).click();
  await p.locator("#share-dialog").getByRole("button", { name: "Create public link" }).click();
  const toast = await p.locator(".toast", { hasText: "Public link ready" }).textContent();
  shareUrl = /(http\S+\/share\/[0-9a-f]{64})/.exec(toast)[1];
}, { full: false });
const outsider = await browser.newContext({ viewport: { width: 1440, height: 960 }, deviceScaleFactor: 2 });
const shared = await outsider.newPage();
watch(shared);
await step("49-public-link", "The public link, logged out", "Workspace", (p) => p.goto(shareUrl.replace(/^https?:\/\/[^/]+/, base)), { page: shared });
await outsider.close();
await step("50-export", "Export CSV", "Workspace", async (p, s) => {
  const response = await p.request.get(`${base}/fieldnotes/export.csv?range=30d`);
  s.notes.push(`export.csv: ${response.status()} ${response.headers()["content-type"]} ${(await response.body()).length} bytes`);
  return p.goto(`${base}/fieldnotes?range=30d`);
}, { full: false, audit: false });

// ---------------------------------------------------------------- settings

for (const [index, [slug, title]] of [["sites", "Website & tracking"], ["consent", "Consent & privacy"], ["recording", "Recording"], ["team", "Team & roles"], ["signin", "Sign-in"], ["integrations", "Integrations"], ["api", "API & public links"], ["email", "Email delivery"], ["backups", "Backups"], ["retention", "Data retention"], ["audit", "Audit log"], ["diagnostics", "Diagnostics"], ["ai", "AI"]].entries()) {
  await step(`${51 + index}-settings-${slug}`, `Settings: ${title}`, "Settings", go(`/settings/${slug}?site=fieldnotes`));
}
await step("64-setup", "Setup: the snippet", "Settings", go("/fieldnotes/setup"));
await step("65-api-key", "Create an API key and call the read API", "Settings", async (p, s) => {
  await p.goto(`${base}/settings/api?site=fieldnotes`);
  await p.getByLabel("Key name").fill("Tour");
  await p.getByRole("button", { name: "Create key" }).click();
  const key = await p.getByLabel("New API key").inputValue();
  const json = await (await fetch(`${base}/api/v1/sites/fieldnotes/overview?range=30d`, { headers: { authorization: `Bearer ${key}` } })).json();
  writeFileSync(join(out, "api-overview.json"), JSON.stringify(json, null, 2));
  s.notes.push(`GET /api/v1/sites/fieldnotes/overview → ${JSON.stringify(json).slice(0, 200)}`);
}, { full: false });
let invite = "";
await step("66-invite", "Invite a teammate", "Settings", async (p) => {
  await p.goto(`${base}/settings/team?site=fieldnotes`);
  await p.getByPlaceholder("name@example.com").fill("sam@fieldnotes.example");
  await p.locator("form.invite select[name=role]").selectOption("viewer");
  await p.getByRole("button", { name: "Invite" }).click();
  invite = await p.locator("input[readonly]").first().inputValue();
});
const teammate = await browser.newContext({ viewport: { width: 1440, height: 960 }, deviceScaleFactor: 2 });
const sam = await teammate.newPage();
watch(sam);
await step("67-invite-accept", "The invite, from the teammate's side", "Settings", (p) => p.goto(invite.replace(/^https?:\/\/[^/]+/, base)), { page: sam, full: false });
await step("68-teammate", "Teammate signs up with a password and lands in the workspace", "Settings", async (p) => {
  await p.getByRole("button", { name: "Other ways to sign in" }).click();
  await p.getByRole("link", { name: /Choose a password/ }).click();
  await p.getByLabel("Password").fill("a long garden password");
  await p.getByRole("button", { name: "Continue" }).click();
  await p.waitForURL(/\/fieldnotes|\/seedlibrary/);
}, { page: sam });
await teammate.close();

// ---------------------------------------------------------------- Lite mode, phone, signed out

await step("69-lite-overview", "Seed Library: a Lite-mode site", "Lite mode", go("/seedlibrary?range=30d"));
await step("70-lite-sessions", "Lite mode: sessions need Session mode", "Lite mode", go("/seedlibrary/sessions"));
const phone = await browser.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 3, isMobile: true, hasTouch: true, storageState: statePath, userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.6 Mobile/15E148 Safari/604.1" });
const mobile = await phone.newPage();
watch(mobile);
await step("71-phone-overview", "Phone: overview", "Phone", go("/fieldnotes?range=30d"), { page: mobile });
await step("72-phone-pages", "Phone: pages", "Phone", go("/fieldnotes/pages?range=30d"), { page: mobile });
await step("73-phone-revenue", "Phone: revenue", "Phone", go("/fieldnotes/revenue?range=30d"), { page: mobile });
await step("74-phone-replay", "Phone: a replay", "Phone", async (p) => {
  await p.goto(`${base}/fieldnotes/sessions?signal=recorded`);
  await p.locator("a.btn-replay").first().click();
  await p.locator(".player.loaded").waitFor({ timeout: 15000 });
}, { page: mobile });
await step("75-phone-more", "Phone: the More menu", "Phone", async (p) => {
  await p.goto(`${base}/fieldnotes`);
  await p.locator(".tabbar").getByRole("link", { name: /More/ }).click();
  await p.waitForURL(/\/settings/);
  await delay(400);
}, { page: mobile, full: false });
await phone.close();
const anonymous = await browser.newContext({ viewport: { width: 1440, height: 960 }, deviceScaleFactor: 2 });
const visitor = await anonymous.newPage();
watch(visitor);
await step("76-login", "Sign-in page", "Signed out", go("/login"), { page: visitor });
await step("77-blocked", "A workspace page, signed out", "Signed out", go("/fieldnotes"), { page: visitor });
await anonymous.close();

// ---------------------------------------------------------------- the command line

const commands = [["report", "overview", "fieldnotes", "--days", "30"], ["report", "pages", "fieldnotes", "--days", "30", "--limit", "8"], ["report", "acquisition", "fieldnotes", "--days", "30", "--limit", "8"], ["report", "campaign-economics", "fieldnotes", "--days", "30"], ["report", "performance", "fieldnotes", "--days", "30"], ["stats"], ["doctor"]];
const cliOut = commands.map((args) => { let text; try { text = cli(...args); } catch (error) { text = `ERROR ${error.message}`; } return { command: `analytico ${args.join(" ")}`, text }; });
writeFileSync(join(out, "cli.json"), JSON.stringify(cliOut, null, 2));

await browser.close();
proxy.close();
server.kill("SIGTERM");
writeFileSync(join(out, "results.json"), JSON.stringify(results, null, 2));
writeFileSync(join(out, "server.log"), serverLog.split("\n").filter((line) => !line.includes("batch_accepted")).join("\n"));
console.log(`tour: ${results.filter((r) => r.ok).length}/${results.length} steps passed`);
process.exit(0);
