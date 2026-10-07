// A realistic Analytico demo for the tour: "Field Notes", a balcony-gardening
// blog with a small shop (Full mode), and "Seed Library" (Lite mode).
// 88 days of history go through the real collector over HTTP with their
// intended times in occurred_at_ms; receipt times are then set from them
// with the server stopped, and the rollups rebuild on the next start.
// The morning of the last day is real Chromium visits through the real
// tracker (consent banner, replays, heatmaps, forms, errors). Run by
// tests/tour.mjs:
//   node tests/tour-seed.mjs <analytico> <data-dir> <dbip-city-lite.csv.gz> <state.json>
import { execFileSync, spawn } from "node:child_process";
import { createHmac, randomUUID } from "node:crypto";
import { createReadStream, rmSync, writeFileSync } from "node:fs";
import { createServer, request } from "node:http";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { DatabaseSync } from "node:sqlite";
import { setTimeout as delay } from "node:timers/promises";
import { createGunzip } from "node:zlib";
import { chromium } from "playwright-core";

const [binary, dir, geoCsv, statePath] = process.argv.slice(2);
const PORT = 4401;
const PROXY = 4402;
const DAY = 86_400_000;
const HOUR = 3_600_000;
const workspace = `http://localhost:${PORT}`;
const siteOrigin = "http://fieldnotes.example";
const libraryOrigin = "https://seedlibrary.example";
const started = Date.now();
const today = started - (started % DAY);
const HISTORY = 88;

// Deterministic randomness, so a re-run tells the same story.
let state = 20261007;
const rand = () => { state = (Math.imul(state, 1664525) + 1013904223) >>> 0; return state / 4294967296; };
const pick = (list) => list[Math.floor(rand() * list.length)];
const weighted = (entries) => {
  let r = rand() * entries.reduce((sum, entry) => sum + entry[1], 0);
  for (const entry of entries) if ((r -= entry[1]) < 0) return entry[0];
  return entries.at(-1)[0];
};
const gauss = () => { let u = 0; while (!u) u = rand(); return Math.sqrt(-2 * Math.log(u)) * Math.cos(2 * Math.PI * rand()); };
const logn = (median, spread) => Math.max(1, Math.round(median * Math.exp(gauss() * spread)));
const chance = (p) => rand() < p;
const clamp = (value, low, high) => Math.min(high, Math.max(low, value));

const cli = (...args) => execFileSync(binary, [...args, "--data", dir], { encoding: "utf8" });
rmSync(dir, { recursive: true, force: true });
const setupLink = execFileSync(binary, ["init", dir, "--origin", workspace], { encoding: "utf8" }).trim().split("\n").at(-1);
cli("geo", "import", geoCsv);
const added = cli("site", "add", "fieldnotes", siteOrigin);
const publicId = /public_id=(\S+)/.exec(added)[1];
const secret = /internal_secret=([0-9a-f]+)/.exec(added)[1];
const libraryId = /public_id=(\S+)/.exec(cli("site", "add", "seedlibrary", libraryOrigin, "--mode", "lite"))[1];
for (const [name, kind, match] of [["newsletter-signup", "event", "newsletter_signup"], ["purchase", "event", "purchase"], ["workshop-page", "path", "/workshops"]]) cli("goal", "add", "fieldnotes", name, kind, match);
cli("funnel", "add", "fieldnotes", "shop-to-purchase", "path:/shop", "event:add_to_cart", "event:begin_checkout", "event:purchase");
cli("goal", "add", "seedlibrary", "catalogue", "path", "/catalogue");
{
  const db = new DatabaseSync(join(dir, "analytico.db"));
  db.exec(`UPDATE sites SET name='Field Notes',consent_banner=1,privacy_url='https://fieldnotes.example/privacy',replay_percent=40,replay_triggers=1 WHERE slug='fieldnotes';
    UPDATE sites SET name='Seed Library' WHERE slug='seedlibrary';
    UPDATE goals SET name='Newsletter signup' WHERE name='newsletter-signup';
    UPDATE goals SET name='Purchase' WHERE name='purchase';
    UPDATE goals SET name='Visited workshops' WHERE name='workshop-page';
    UPDATE goals SET name='Opened the catalogue' WHERE name='catalogue';
    UPDATE funnels SET name='Shop to purchase' WHERE name='shop-to-purchase';
    INSERT INTO settings(name,value) VALUES('collector_origin','https://analytics.fieldnotes.example');`);
  db.close();
}
// Ad spend, so campaign economics has something to divide by.
for (let ago = HISTORY; ago >= 1; ago--) {
  const date = new Date(today - ago * DAY).toISOString().slice(0, 10);
  cli("campaign", "spend-add", "fieldnotes", date, "google", ago > 30 ? "spring-seeds" : "autumn-bulbs", "search-ad", String(1600 + Math.round(rand() * 900)), "EUR");
  if (ago <= 40) cli("campaign", "spend-add", "fieldnotes", date, "instagram", "workshops", "reel", String(900 + Math.round(rand() * 700)), "EUR");
}

let server;
let serverLog = "";
const serve = async () => {
  server = spawn(binary, ["serve", "--data", dir, "--listen", `127.0.0.1:${PORT}`], { stdio: ["ignore", "ignore", "pipe"] });
  server.stderr.on("data", (bytes) => { serverLog = (serverLog + bytes).slice(-20000); });
  for (let i = 0; i < 100; i++) { try { if ((await fetch(`${workspace}/readyz`)).ok) return; } catch {} await delay(100); }
  throw new Error(`server did not start\n${serverLog}`);
};
const stop = async () => { server.kill("SIGTERM"); await new Promise((done) => server.once("close", done)); };
process.on("exit", () => server?.kill("SIGKILL"));
await serve();

// The owner signs up with a passkey; the session is kept for the tour.
const browser = await chromium.launch({ executablePath: process.env.CHROMIUM_PATH || "/usr/bin/chromium", headless: true, args: [`--host-resolver-rules=MAP fieldnotes.example 127.0.0.1:${PROXY}`] });
{
  const context = await browser.newContext({ viewport: { width: 1440, height: 1000 } });
  const page = await context.newPage();
  const cdp = await context.newCDPSession(page);
  await cdp.send("WebAuthn.enable");
  await cdp.send("WebAuthn.addVirtualAuthenticator", { options: { protocol: "ctap2", transport: "internal", hasResidentKey: true, hasUserVerification: true, isUserVerified: true, automaticPresenceSimulation: true } });
  await page.goto(setupLink);
  await page.getByLabel("Your email").fill("mira@fieldnotes.example");
  await page.getByRole("button", { name: "Create a passkey" }).click();
  await page.waitForURL(/\/fieldnotes|\/seedlibrary|\/settings/);
  await context.storageState({ path: statePath });
  await context.close();
}

// What people click on each demo page, named the way the tracker names
// elements, so the history carries heatmap cells the overlay can draw.
const clickables = {};
{
  const context = await browser.newContext({ viewport: { width: 1440, height: 1000 }, javaScriptEnabled: false });
  const page = await context.newPage();
  for (const [path, html] of Object.entries((await import("./tour-fixture.mjs")).pages(""))) {
    await page.setContent(html);
    clickables[path] = await page.$$eval("[data-analytics-action],a,button,input,select,textarea", (elements) => elements.map((element) => {
      const action = element.getAttribute("data-analytics-action");
      let key = action ? `[data-analytics-action="${action}"]` : "";
      for (let node = element, steps = []; !key; node = node.parentElement) {
        if (node.id) { steps.unshift(`#${node.id}`); key = steps.join(">"); break; }
        if (node.tagName === "BODY") { steps.unshift("body"); key = steps.join(">"); break; }
        let index = 1;
        for (let sibling = node.previousElementSibling; sibling; sibling = sibling.previousElementSibling) if (sibling.tagName === node.tagName) index++;
        steps.unshift(`${node.tagName.toLowerCase()}:nth-of-type(${index})`);
        if (steps.length === 6) { key = steps.join(">"); break; }
      }
      const box = element.getBoundingClientRect();
      const weight = action || element.tagName === "BUTTON" ? 6 : element.closest("header") ? 1 : element.matches("input,select,textarea") ? 2 : 3;
      return [key, weight * (box.top < 700 ? 2 : 1)];
    }));
  }
  await context.close();
}
// Attention per tenth of the page, down to how far the visitor scrolled.
const heat = (path, bounce, active, scroll) => {
  const reached = Math.max(1, Math.ceil(scroll / 10));
  const attention = Array.from({ length: 10 }, (_, band) => band < reached ? Math.round(active / reached * (1.4 - band / reached)) : 0);
  return { attention, ...(!bounce && chance(0.55) ? { clicks: clicksOn(path, false) } : {}) };
};
const clicksOn = (path, rage) => {
  const keys = clickables[path];
  if (!keys?.length) return [];
  const cells = new Map();
  for (let count = 1 + Math.floor(rand() * 3); count > 0; count--) {
    const el = weighted(keys);
    const x = clamp(Math.round((50 + gauss() * 18) / 5) * 5, 0, 100), y = clamp(Math.round((50 + gauss() * 18) / 5) * 5, 0, 100);
    const cell = cells.get(`${el}|${x}|${y}`) || { el, x, y, n: 0, rage: 0 };
    cell.n++;
    cells.set(`${el}|${x}|${y}`, cell);
  }
  if (rage) { const cell = [...cells.values()][0]; cell.n += 3; cell.rage = 1; }
  return [...cells.values()];
};

// ---------------------------------------------------------------- the world

// Whole /24 blocks with a known region, sampled from the location database,
// so every visitor's address places them in a real city.
const pools = {};
{
  let row = 0;
  for await (const line of createInterface({ input: createReadStream(geoCsv).pipe(createGunzip()) })) {
    const [start, end, , country, region] = line.split(",", 5);
    if (++row % 13 || !region || !start.endsWith(".0") || !end.endsWith(".255") || (pools[country]?.length ?? 0) >= 400) continue;
    (pools[country] ||= []).push(start.slice(0, -2));
  }
}
const countryMix = [["DE", 21], ["US", 16], ["GB", 9], ["NL", 7], ["FR", 6], ["CH", 3], ["SE", 3], ["CA", 4], ["AU", 2], ["ES", 3], ["IT", 3], ["PL", 2], ["IE", 2], ["NO", 1.5], ["BR", 1.5], ["IN", 2], ["JP", 1], ["ZA", 1], ["MX", 1], ["DK", 1], ["FI", 1], ["NZ", 1]].filter(([country]) => pools[country]?.length);
const asked = new Set(["DE", "GB", "NL", "FR", "CH", "SE", "ES", "IT", "PL", "IE", "NO", "DK", "FI", "AT", "BE"]);
const languages = { DE: "de", NL: "nl", FR: "fr", ES: "es", IT: "it", SE: "sv", PL: "pl", NO: "nb", BR: "pt", JP: "ja", DK: "da", FI: "fi", MX: "es", CH: "de" };
const agents = [
  ["phone", 29, "Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.6 Mobile/15E148 Safari/604.1"],
  ["phone", 20, "Mozilla/5.0 (Linux; Android 15; Pixel 9) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Mobile Safari/537.36"],
  ["phone", 4, "Mozilla/5.0 (Linux; Android 14; SM-S921B) AppleWebKit/537.36 (KHTML, like Gecko) SamsungBrowser/27.0 Chrome/138.0.0.0 Mobile Safari/537.36"],
  ["tablet", 4, "Mozilla/5.0 (iPad; CPU OS 18_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.6 Mobile/15E148 Safari/604.1"],
  ["desktop", 14, "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36"],
  ["desktop", 8, "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.6 Safari/605.1.15"],
  ["desktop", 11, "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36"],
  ["desktop", 4, "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36 Edg/140.0.0.0"],
  ["desktop", 4, "Mozilla/5.0 (Macintosh; Intel Mac OS X 14.6; rv:143.0) Gecko/20100101 Firefox/143.0"],
  ["desktop", 2, "Mozilla/5.0 (X11; Linux x86_64; rv:143.0) Gecko/20100101 Firefox/143.0"],
];
const bots = ["Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)", "Mozilla/5.0 (compatible; bingbot/2.0; +http://www.bing.com/bingbot.htm)", "Mozilla/5.0 (compatible; AhrefsBot/7.0; +http://ahrefs.com/robot/)"];

const products = [
  { id: "seed-starter-kit", name: "Seed starter kit", category: "Kits", price: 3800, weight: 34 },
  { id: "terracotta-planter", name: "Terracotta planter, 30 cm", category: "Planters", price: 3500, weight: 22 },
  { id: "urban-garden-guide", name: "Urban garden guide (PDF)", category: "Guides", price: 900, weight: 24 },
  { id: "balcony-worm-bin", name: "Balcony worm bin", category: "Compost", price: 6900, weight: 9 },
  { id: "workshop-seed-saving", name: "Workshop: seed saving", category: "Workshops", price: 4500, weight: 11 },
];
const guides = [["/guides/urban-gardens", 30], ["/guides/balcony-tomatoes", 26], ["/guides/composting-small-spaces", 15], ["/guides/herbs-in-shade", 12], ["/guides/watering-while-away", 9]];
const journal = ["/journal/the-balcony-that-feeds-us", "/journal/slow-weekends", "/journal/seed-swap-diary", "/journal/first-frost"];
const searches = [["tomatoes", 9], ["seed kit", 6], ["compost", 5], ["balcony herbs", 5], ["terracotta", 3], ["worm bin", 3], ["chilli", 2], ["shade plants", 2], ["drip irrigation", 2], ["strawberries", 2]];
const kind = (path) => path === "/" ? "home" : path.startsWith("/guides/") ? "guide" : path.startsWith("/journal/") ? "journal" : path.startsWith("/shop/") ? "product" : path.slice(1).split("/")[0];
const sectionsFor = { home: ["hero", "latest", "newsletter-cta"], guide: ["intro", "materials", "steps", "newsletter-cta"], journal: ["story", "photos", "newsletter-cta"], product: ["gallery", "details", "reviews"], shop: ["products"], workshops: ["dates", "faq"] };
const release = (ago) => ago > 45 ? "2026.08.4" : ago > 31 ? "2026.09.1" : ago > 18 ? "2026.09.2" : ago > 6 ? "2026.09.3" : "2026.10.1";
const hourWeights = [2, 1.2, 0.8, 0.6, 0.6, 0.9, 1.8, 3, 4, 4.2, 4.4, 4.6, 4.8, 4.6, 4.4, 4.5, 4.8, 5.4, 6.2, 6.8, 6.6, 5.6, 4.2, 3];
const hourOfDay = () => weighted(hourWeights.map((weight, hour) => [hour, weight]));

const people = [];
let personSeq = 0;
function person() {
  const country = weighted(countryMix);
  const [device, ua] = weighted(agents.map(([device, weight, ua]) => [[device, ua], weight]));
  const gpc = chance(0.04);
  const consent = gpc ? "gpc" : asked.has(country) ? (chance(0.71) ? "granted" : "denied") : "not_required";
  const entry = { visitor: randomUUID(), seq: personSeq++, prefix: pick(pools[country]), country, device, ua, gpc, consent, language: chance(0.75) ? (languages[country] || "en") : "en", seen: false, loyalty: rand() };
  people.push(entry);
  return entry;
}
const identified = (p) => p.consent === "granted" || p.consent === "not_required";

// ---------------------------------------------------------------- sending

let sent = 0;
let failed = 0;
async function post(path, body, client, headers = {}) {
  for (let attempt = 0; attempt < 3; attempt++) {
    try {
      const response = await fetch(`${workspace}${path}`, { method: "POST", body, headers: { "content-type": "text/plain;charset=UTF-8", "x-forwarded-for": client.ip, "user-agent": client.ua, ...headers } });
      await response.arrayBuffer();
      if (response.ok) { sent++; return; }
      if (response.status < 500) { failed++; if (failed < 6) console.error(path, response.status, body.slice(0, 300)); return; }
    } catch {}
    await delay(200);
  }
  failed++;
}
const browserBatch = (site, origin, records, client) => post("/e", JSON.stringify({ v: 2, site, sent_at_ms: Date.now(), records }), client, { origin, ...(client.gpc ? { "sec-gpc": "1" } : {}) });
async function serverBatch(records) {
  const body = JSON.stringify({ v: 2, site: publicId, sent_at_ms: Date.now(), records });
  const stamp = String(Math.floor(Date.now() / 1000));
  const signature = createHmac("sha256", Buffer.from(secret, "hex")).update(`${stamp}.${body}`).digest("hex");
  await post("/i", body, { ip: "127.0.0.1", ua: "fieldnotes-shop/1.4" }, { "content-type": "application/json", "x-analytico-timestamp": stamp, "x-analytico-signature": signature });
}

// ---------------------------------------------------------------- visits

let orderSeq = 10_240;
let customerSeq = 300;
function landing(source, ago) {
  switch (source) {
    case "hn": return "/journal/the-balcony-that-feeds-us";
    case "reddit": return ago <= 2 ? "/guides/herbs-in-shade" : weighted(guides);
    case "newsletter": return weighted([[journal[ago > 50 ? 3 : ago > 25 ? 2 : ago > 12 ? 0 : 1], 5], ["/", 3], ["/shop/seed-starter-kit", 2]]);
    case "paid-google": return weighted([["/shop/seed-starter-kit", 5], ["/shop", 3], ["/shop/terracotta-planter", 2]]);
    case "paid-meta": return weighted([["/workshops", 6], ["/shop/workshop-seed-saving", 4]]);
    case "instagram": return weighted([["/shop", 4], ["/", 3], ["/shop/terracotta-planter", 2], ["/journal/slow-weekends", 2]]);
    case "pinterest": return weighted([["/guides/balcony-tomatoes", 5], ["/guides/herbs-in-shade", 3], ["/guides/urban-gardens", 2]]);
    case "ai": return weighted([["/guides/composting-small-spaces", 4], ["/guides/balcony-tomatoes", 3], ["/guides/watering-while-away", 3]]);
    case "direct": return weighted([["/", 6], ["/shop", 2], ["/guides/urban-gardens", 2], ["/workshops", 1]]);
    default: return weighted([...guides, ["/", 8], ["/shop/seed-starter-kit", 6], ["/journal/slow-weekends", 4]]);
  }
}
function next(path) {
  const k = kind(path);
  if (k === "product") return weighted([["/shop", 3], ["/shop/" + pick(products).id, 2], ["/", 1]]);
  if (k === "shop") return weighted([...products.map((product) => ["/shop/" + product.id, product.weight / 10]), ["/search", 1.5]]);
  if (k === "home") return weighted([...guides, ["/shop", 18], ["/newsletter", 6], ["/about", 4], ["/workshops", 5], [journal[1], 6]]);
  if (k === "search") return "/shop/" + weighted(products.map((product) => [product.id, product.weight]));
  if (k === "workshops") return weighted([["/shop/workshop-seed-saving", 6], ["/", 2]]);
  return weighted([...guides.map(([p, w]) => [p, w / 3]), ["/", 10], ["/shop", 14], ["/newsletter", 7], [pick(journal), 6], ["/shop/" + pick(products).id, 8]]);
}
function sourceFields(source, ago, consented) {
  switch (source) {
    case "google": return { referrer_host: "www.google.com" };
    case "duckduckgo": return { referrer_host: "duckduckgo.com" };
    case "ecosia": return { referrer_host: "www.ecosia.org" };
    case "bing": return { referrer_host: "www.bing.com" };
    case "instagram": return { referrer_host: "l.instagram.com" };
    case "pinterest": return { referrer_host: "www.pinterest.com" };
    case "reddit": return { referrer_host: "www.reddit.com" };
    case "twitter": return { referrer_host: "t.co" };
    case "mastodon": return { referrer_host: "mastodon.social" };
    case "hn": return { referrer_host: "news.ycombinator.com" };
    case "ai": return { referrer_host: chance(0.75) ? "chatgpt.com" : "www.perplexity.ai" };
    case "newsletter": return { utm_source: "newsletter", utm_medium: "email", utm_campaign: `issue-${52 - Math.floor(ago / 7)}` };
    case "paid-google": return { utm_source: "google", utm_medium: "cpc", utm_campaign: ago > 30 ? "spring-seeds" : "autumn-bulbs", utm_content: "search-ad", ...(consented ? { click_id: `gclid:Cj0KCQjw${randomUUID().replaceAll("-", "").slice(0, 20)}` } : {}) };
    case "paid-meta": return { utm_source: "instagram", utm_medium: "paid_social", utm_campaign: "workshops", utm_content: "reel", ...(consented ? { click_id: `fbclid:IwAR${randomUUID().replaceAll("-", "").slice(0, 20)}` } : {}) };
    default: return {};
  }
}

async function visit(p, source, at, ago, ip) {
  const client = { ip, ua: p.ua, gpc: p.gpc };
  const session = randomUUID();
  const viewport = p.device;
  const hn = source === "hn";
  let ids = identified(p) && p.seen;
  const records = (page, base) => ({ page_id: page, tracking_mode: "full", tracker_version: "2", release_id: release(ago), internal: false, ...(ids ? { session_id: session, visitor_id: p.visitor } : {}), consent_mode: p.gpc ? "gpc" : ids ? p.consent : p.consent === "denied" && p.seen ? "denied" : "pending", ...base });
  let path = landing(source, ago);
  let time = at;
  const pages = hn ? (chance(0.85) ? 1 : 2) : clamp(1 + Math.floor(-Math.log(1 - rand()) / 0.75), 1, 7);
  let cart = null;
  let arrival = {};
  for (let index = 0; index < pages; index++) {
    const page = randomUUID();
    const k = kind(path);
    const batch = [];
    const query = k === "search" ? weighted(searches) : null;
    if (index === 0) arrival = sourceFields(source, ago, ids);
    // As the tracker does: a visit with a kept identity repeats where it came
    // from; otherwise a page reached from the site names the site.
    const { click_id, ...kept } = arrival;
    const fields = index === 0 ? arrival : ids ? kept : { referrer_host: "fieldnotes.example" };
    batch.push({ event_id: randomUUID(), type: "page_view", occurred_at_ms: time, ...records(page, {}), path, page_type: k, ...fields, navigation_type: "navigate", viewport_class: viewport, language: p.language, ...(query ? { search_term: query, search_results: query === "chilli" || query === "drip irrigation" ? 0 : 2 + Math.floor(rand() * 9) } : {}) });
    // First visit from a country that asks: the banner answer attaches this page.
    // First visit: the page view goes out pending; the banner answer (or, outside
    // the consent region, the server's "grant") attaches it to the visitor.
    if (index === 0 && !p.seen) {
      p.seen = true;
      if (!p.gpc) {
        if (identified(p)) ids = true;
        batch.push({ event_id: randomUUID(), type: "consent", occurred_at_ms: time + 2500, ...records(page, {}), state: p.consent });
      }
    }
    // A third of one-page visits bounce: a few seconds, little scroll, no interaction.
    const bounce = pages === 1 && chance(hn ? 0.5 : 0.35);
    const active = bounce ? logn(3500, 0.5) : logn(k === "guide" || k === "journal" ? (hn ? 38_000 : 72_000) : k === "product" ? 31_000 : k === "checkout" ? 58_000 : 14_000, 0.7);
    const scroll = bounce ? clamp(Math.round(18 + gauss() * 10), 3, 45) : clamp(Math.round((k === "guide" || k === "journal" ? (hn ? 48 : 66) : 52) + gauss() * 22), 5, 100);
    const sections = (sectionsFor[k] || ["main"]).slice(0, Math.max(1, Math.ceil(scroll / 100 * (sectionsFor[k] || ["main"]).length)));
    const phone = viewport !== "desktop";
    const vitals = index === 0 && chance(0.72) ? { ttfb_ms: logn(phone ? 260 : 170, 0.5), fcp_ms: logn(phone ? 1250 : 820, 0.4), lcp_ms: logn((k === "product" || k === "shop" ? 2350 : 1500) * (phone ? 1.3 : 1), 0.42), inp_ms: logn(phone ? 160 : 90, 0.6), cls_milli: Math.min(logn(k === "shop" ? 140 : 30, 0.9), 900), long_frame_count: Math.floor(rand() * 4), blocking_ms: logn(60, 0.9) } : {};
    batch.push({ event_id: randomUUID(), type: "page_summary", occurred_at_ms: time + active + 4000, ...records(page, {}), visible_ms: Math.round(active * 1.5) + 2000, active_ms: active, first_interaction_ms: bounce ? 0 : logn(1800, 0.6), interaction_count: bounce ? 0 : logn(4, 0.7), max_scroll: scroll, sections, last_section: sections.at(-1), selection_count: chance(0.1) ? 1 : 0, copy_count: k === "guide" && chance(0.04) ? 1 : 0, outbound_clicks: (k === "guide" || k === "journal") && chance(0.06) ? 1 : 0, downloads: path === "/guides/urban-gardens" && chance(0.09) ? 1 : 0, form_attempts: k === "newsletter" || k === "checkout" ? 1 : 0, ...vitals, ...(ids ? heat(path, bounce, active, scroll) : {}) });
    const event = (name, extra = {}) => batch.push({ event_id: randomUUID(), type: "event", occurred_at_ms: time + Math.round(active * 0.6), ...records(page, {}), name, path, ...extra });
    if (k === "product") {
      const product = products.find((item) => path.endsWith(item.id));
      const item = { id: product.id, name: product.name, category: product.category, price_minor: product.price, quantity: 1 };
      event("view_item", { value_minor: product.price, currency: "EUR", items: [item] });
      if (chance(product.id === "workshop-seed-saving" ? 0.2 : 0.15)) { event("add_to_cart", { value_minor: product.price, currency: "EUR", items: [item] }); cart = item; }
    }
    if (k === "newsletter" && chance(0.36)) event("newsletter_signup", { properties: { placement: "page" } });
    if ((k === "guide" || k === "journal") && scroll > 85 && chance(0.05)) event("newsletter_signup", { properties: { placement: "article-footer" } });
    if (k === "checkout" && cart) {
      event("begin_checkout", { value_minor: cart.price_minor, currency: "EUR", items: [cart] });
      const buggy = ago <= 31 && ago > 18;
      if (buggy && chance(0.11)) batch.push({ event_id: randomUUID(), type: "error", occurred_at_ms: time + 9000, ...records(page, {}), path, message: "TypeError: Cannot read properties of undefined (reading 'total')", file: "https://fieldnotes.example/assets/checkout.4f9c2e.js", line: 212, column: 18 });
      if (chance(0.72)) {
        event("add_shipping_info", { value_minor: cart.price_minor, currency: "EUR", items: [cart] });
        if (chance(buggy ? 0.48 : 0.66)) {
          const order = `FN-${orderSeq++}`;
          event("purchase", { value_minor: cart.price_minor + 490, currency: "EUR", order_id: order, items: [cart] });
          if (ids && chance(0.5)) batch.push({ event_id: randomUUID(), type: "identify", occurred_at_ms: time + 40_000, ...records(page, {}), user_id: `cust_${customerSeq++}` });
          if (chance(0.93)) run(serverBatch([{ event_id: randomUUID(), type: "event", occurred_at_ms: time + 70_000, tracking_mode: "full", consent_mode: "server", tracker_version: "fieldnotes-shop/1.4", release_id: "", internal: false, ...(ids ? { session_id: session } : {}), name: "payment_confirmed", value_minor: cart.price_minor + 490, currency: "EUR", order_id: order, items: [cart] }, ...(chance(0.03) ? [{ event_id: randomUUID(), type: "event", occurred_at_ms: Math.min(time + 3 * HOUR, nowCut), tracking_mode: "full", consent_mode: "server", tracker_version: "fieldnotes-shop/1.4", release_id: "", internal: false, name: "refund", value_minor: cart.price_minor, currency: "EUR", order_id: order, items: [cart] }] : [])]));
          cart = null;
        }
      }
    }
    if (chance(0.0025)) batch.push({ event_id: randomUUID(), type: "error", occurred_at_ms: time + 3000, ...records(page, {}), path, message: "ResizeObserver loop completed with undelivered notifications.", file: "", line: 0, column: 0 });
    if (k === "product" && p.ua.includes("Version/18") && chance(0.012)) batch.push({ event_id: randomUUID(), type: "error", occurred_at_ms: time + 5000, ...records(page, {}), path, message: "Unhandled Promise Rejection: TypeError: Load failed", file: "https://fieldnotes.example/assets/gallery.91ab0c.js", line: 48, column: 7 });
    await browserBatch(publicId, siteOrigin, batch, client);
    time += active + logn(9000, 0.6);
    path = cart && chance(0.5) ? "/checkout" : next(path);
  }
}

// Server-only orders: shoppers whose browsers blocked the tracker.
async function blockedOrder(at) {
  const product = weighted(products.map((item) => [item, item.weight]));
  await serverBatch([{ event_id: randomUUID(), type: "event", occurred_at_ms: at, tracking_mode: "full", consent_mode: "server", tracker_version: "fieldnotes-shop/1.4", release_id: "", internal: false, name: "payment_confirmed", value_minor: product.price + 490, currency: "EUR", order_id: `FN-${orderSeq++}`, items: [{ id: product.id, name: product.name, category: product.category, price_minor: product.price, quantity: 1 }] }]);
}

async function libraryVisit(at, ip, ua, device) {
  const client = { ip, ua, gpc: false };
  const source = weighted([["google", 45], ["direct", 25], ["mastodon", 12], ["duckduckgo", 8], ["fieldnotes", 10]]);
  let path = weighted([["/", 4], ["/catalogue", 3], ["/catalogue/tomatoes", 2], ["/swap", 1]]);
  let time = at;
  for (let index = 0; index < 1 + Math.floor(rand() * 2.4); index++) {
    const page = randomUUID();
    const active = logn(40_000, 0.7);
    const base = { page_id: page, tracking_mode: "lite", tracker_version: "2", release_id: "", internal: false, consent_mode: "unspecified" };
    const referrer = index ? { referrer_host: "seedlibrary.example" } : source === "google" ? { referrer_host: "www.google.com" } : source === "mastodon" ? { referrer_host: "mastodon.social" } : source === "duckduckgo" ? { referrer_host: "duckduckgo.com" } : source === "fieldnotes" ? { referrer_host: "fieldnotes.example" } : {};
    await browserBatch(libraryId, libraryOrigin, [
      { event_id: randomUUID(), type: "page_view", occurred_at_ms: time, ...base, path, page_type: path === "/" ? "home" : "catalogue", ...referrer, navigation_type: "navigate", viewport_class: device, language: "en" },
      { event_id: randomUUID(), type: "page_summary", occurred_at_ms: time + active, ...base, visible_ms: active + 3000, active_ms: active, interaction_count: logn(3, 0.6), max_scroll: clamp(Math.round(55 + gauss() * 20), 5, 100), sections: [], selection_count: 0, copy_count: 0, outbound_clicks: 0, downloads: 0, form_attempts: 0 },
    ], client);
    time += active + 8000;
    path = weighted([["/catalogue", 3], ["/catalogue/beans", 2], ["/catalogue/tomatoes", 2], ["/swap", 1]]);
  }
}

// ---------------------------------------------------------------- history

const ingestStart = Date.now();
const nowCut = started - 25 * 60_000;
const pool = [];
async function drain(limit) { while (pool.length > limit) await Promise.race(pool); }
const run = (promise) => { const tracked = promise.finally(() => pool.splice(pool.indexOf(tracked), 1)); pool.push(tracked); };
const recent = [];
for (let ago = HISTORY; ago >= 0; ago--) {
  const dayStart = today - ago * DAY;
  const weekday = new Date(dayStart).getUTCDay();
  const base = (500 + 520 * (HISTORY - ago) / HISTORY) * [1.24, 0.92, 0.95, 1, 1.05, 0.97, 1.18][weekday] * (1 + 0.07 * gauss());
  const extra = [];
  if (weekday === 4) extra.push(["newsletter", base * 0.22]);
  if (weekday === 5) extra.push(["newsletter", base * 0.08]);
  if (ago === 22) extra.push(["hn", 4200], ["twitter", 260]);
  if (ago === 21) extra.push(["hn", 900]);
  if (ago === 51) extra.push(["reddit", 380]);
  if (ago === 1) extra.push(["reddit", base * 1.55], ["pinterest", base * 0.2]);
  const plan = [["organic", Math.round(base)], ...extra.map(([source, count]) => [source, Math.round(count)])];
  for (const [kindOfTraffic, count] of plan) {
    for (let index = 0; index < count; index++) {
      const at = dayStart + hourOfDay() * HOUR + Math.floor(rand() * HOUR);
      if (ago === 0 && at > nowCut) continue;
      const source = kindOfTraffic !== "organic" ? kindOfTraffic : weighted([["google", 32], ["direct", 21], ["instagram", 8], ["pinterest", 6], ["duckduckgo", 5], ["bing", 3], ["ecosia", 2], ["ai", ago < 40 ? 4 : 2], ["mastodon", 2], ["twitter", 1.5], ["reddit", 1], ["paid-google", 3], ...(ago <= 40 ? [["paid-meta", 2.5]] : [])]);
      const returning = recent.length > 50 && kindOfTraffic === "organic" && chance(0.28);
      const p = returning ? recent[recent.length - 1 - Math.floor(Math.pow(rand(), 1.4) * recent.length)] : person();
      if (!returning) { recent.push(p); if (recent.length > 40000) recent.shift(); }
      const ip = `${p.prefix}.${2 + ((p.seq * 7 + ago * 13) % 250)}`;
      if (chance(0.02)) { const bot = pick(bots); run(browserBatch(publicId, siteOrigin, [{ event_id: randomUUID(), type: "page_view", page_id: randomUUID(), occurred_at_ms: at, tracking_mode: "full", consent_mode: "pending", tracker_version: "2", release_id: release(ago), internal: false, path: pick(guides)[0], page_type: "guide", navigation_type: "navigate", viewport_class: "desktop", language: "en" }], { ip: `66.249.${64 + Math.floor(rand() * 15)}.${Math.floor(rand() * 250)}`, ua: bot })); }
      run(visit(p, source, at, ago, ip));
      await drain(48);
    }
  }
  const blocked = Math.round(base * 0.004);
  for (let index = 0; index < blocked; index++) { const at = dayStart + hourOfDay() * HOUR; if (ago === 0 && at > nowCut) continue; run(blockedOrder(at)); }
  const library = Math.round((140 + 110 * (HISTORY - ago) / HISTORY) * (1 + 0.1 * gauss()));
  for (let index = 0; index < library; index++) {
    const at = dayStart + hourOfDay() * HOUR + Math.floor(rand() * HOUR);
    if (ago === 0 && at > nowCut) continue;
    const [device, ua] = weighted(agents.map(([device, weight, ua]) => [[device, ua], weight]));
    run(libraryVisit(at, `${pick(pools[weighted(countryMix)])}.${2 + Math.floor(rand() * 250)}`, ua, device));
    await drain(48);
  }
  if (ago % 10 === 0) console.log(`day -${ago}: ${sent} batches sent, ${failed} refused, ${people.length} people, ${((Date.now() - ingestStart) / 1000).toFixed(0)} s`);
}
await drain(0);
await delay(1500);
await drain(0);
console.log(`history: ${sent} batches, ${failed} refused`);
if (failed > sent * 0.002) throw new Error(`too many refused batches\n${serverLog.slice(-3000)}`);

// ---------------------------------------------------------------- real browsers

const snippet = cli("site", "snippet", "fieldnotes", siteOrigin, "--rum").trim();
const fixture = (await import("./tour-fixture.mjs")).pages(snippet);
const proxy = createServer((incoming, outgoing) => {
  const path = incoming.url.split("?")[0];
  if (incoming.method === "GET" && fixture[path]) { outgoing.writeHead(200, { "content-type": "text/html; charset=utf-8" }); return outgoing.end(fixture[path]); }
  if (path.endsWith(".pdf")) { outgoing.writeHead(200, { "content-type": "application/pdf" }); return outgoing.end("%PDF-1.4"); }
  const upstream = request({ hostname: "127.0.0.1", port: PORT, path: incoming.url, method: incoming.method, headers: { ...incoming.headers, "x-forwarded-for": incoming.headers["x-demo-ip"] || "81.169.145.105", connection: "close" } }, (response) => { outgoing.writeHead(response.statusCode, response.headers); response.pipe(outgoing); });
  upstream.on("error", (error) => outgoing.destroy(error));
  incoming.pipe(upstream);
});
await new Promise((done) => proxy.listen(PROXY, "127.0.0.1", done));
const origin = siteOrigin;
// A person, not a script: pauses, scrolling in steps, the mouse moving,
// typing one key at a time.
const pause = (low, high) => delay(low + Math.floor(rand() * (high - low)));
async function browse(page, viewport) {
  for (let step = 0; step < 2 + Math.floor(rand() * 4); step++) {
    await page.mouse.move(40 + rand() * (viewport.width - 80), 80 + rand() * (viewport.height - 160), { steps: 8 });
    await page.mouse.wheel(0, 220 + rand() * 520);
    await pause(700, 2200);
  }
}
async function realVisit(index) {
  const p = person();
  const ip = `${p.prefix}.${2 + (index % 250)}`;
  const viewport = p.device === "desktop" ? { width: 1366, height: 860 } : p.device === "tablet" ? { width: 820, height: 1180 } : { width: 390, height: 844 };
  const context = await browser.newContext({ viewport, userAgent: p.ua, hasTouch: p.device !== "desktop", extraHTTPHeaders: { "x-demo-ip": ip, ...(p.gpc ? { "Sec-GPC": "1" } : {}) } });
  const page = await context.newPage();
  page.on("pageerror", () => {});
  const go = async (path) => { await page.goto(origin + path); await pause(900, 2400); };
  try {
    const source = weighted([["https://www.google.com/", 4], ["", 3], ["https://l.instagram.com/", 1], ["https://www.reddit.com/", 1]]);
    await page.goto(origin + weighted([["/", 4], ["/guides/balcony-tomatoes", 3], ["/shop", 2], ["/shop/seed-starter-kit", 2], ["/workshops", 1], ["/?utm_source=newsletter&utm_medium=email&utm_campaign=issue-52", 1]]), { referer: source || undefined });
    await pause(1200, 2600);
    const banner = page.getByRole("dialog");
    if (await banner.count()) await banner.getByRole("button", { name: p.consent === "denied" ? /No thanks|Decline|Reject/i : /Allow|Accept/i }).first().click().catch(() => {});
    await browse(page, viewport);
    for (let step = 0; step < 1 + Math.floor(rand() * 3); step++) {
      const choice = rand();
      if (choice < 0.3) {
        const link = page.locator("main a[href^='/']").nth(Math.floor(rand() * 4));
        if (await link.count()) { await link.click().catch(() => {}); await pause(900, 2000); await browse(page, viewport); }
      } else if (choice < 0.4) {
        await go("/shop");
        await page.locator("input[name=q]").pressSequentially(weighted(searches), { delay: 90 + rand() * 80 });
        await page.locator("input[name=q]").press("Enter");
        await pause(1500, 3000);
      } else if (choice < 0.5) {
        await go("/workshops");
        await page.locator("#basics").click();
        if (chance(0.4)) for (let n = 0; n < 4; n++) await page.locator("#basics").click({ delay: 40 });
        await pause(800, 2000);
      } else if (choice < 0.75) {
        const product = weighted(products.map((item) => [item, item.weight]));
        await go(`/shop/${product.id}`);
        await page.evaluate((product) => analytico.track("view_item", {}, { value_minor: product.price, currency: "EUR", items: [{ id: product.id, name: product.name, category: product.category, price_minor: product.price, quantity: 1 }] }), product);
        await browse(page, viewport);
        if (chance(0.55)) {
          await page.getByRole("button", { name: "Add to cart" }).click();
          await page.waitForURL(/checkout/);
          await pause(800, 1600);
          await page.evaluate((product) => analytico.track("begin_checkout", {}, { value_minor: product.price, currency: "EUR", items: [{ id: product.id, name: product.name, category: product.category, price_minor: product.price, quantity: 1 }] }), product);
          await page.locator("input[name=email]").pressSequentially("someone@example.test", { delay: 70 + rand() * 60 });
          await page.locator("input[name=address]").pressSequentially("Gartenstraße 12", { delay: 70 + rand() * 60 });
          if (chance(0.3)) {
            await page.locator("input[name=postcode]").pressSequentially("12", { delay: 120 });
            await page.locator("#pay").click();
            await pause(900, 1600);
            await page.locator("#pay").click();
            await pause(1500, 3000);
          } else if (chance(0.15)) {
            await page.evaluate(() => { setTimeout(() => window.shipping.total(), 5); });
            await pause(1500, 3000);
          } else {
            await page.locator("input[name=postcode]").pressSequentially("10115", { delay: 110 });
            await page.evaluate((product) => analytico.track("add_shipping_info", {}, { value_minor: product.price, currency: "EUR", items: [{ id: product.id, name: product.name, category: product.category, price_minor: product.price, quantity: 1 }] }), product);
            await page.locator("#pay").click();
            await page.evaluate(([product, order]) => analytico.track("purchase", {}, { value_minor: product.price + 490, currency: "EUR", order_id: order, items: [{ id: product.id, name: product.name, category: product.category, price_minor: product.price, quantity: 1 }] }), [product, `FN-${orderSeq++}`]);
            await pause(1500, 3000);
          }
        }
      } else if (choice < 0.87) {
        await go("/newsletter");
        await page.locator("input[name=email]").pressSequentially("reader@example.test", { delay: 80 + rand() * 60 });
        if (chance(0.6)) await page.getByRole("button", { name: "Subscribe" }).click();
        await pause(1200, 2500);
      } else await page.locator("a.ext").first().click({ modifiers: ["Meta"] }).catch(() => {});
    }
    await go("/");
  } catch (error) { if (index < 5) console.error("visit", index, error.message.split("\n")[0]); }
  await context.close();
}
const real = 96;
for (let index = 0; index < real; index += 8) await Promise.all(Array.from({ length: Math.min(8, real - index) }, (_, offset) => realVisit(index + offset)));
console.log(`real visits: ${real}`);
proxy.close();
await browser.close();
await delay(2000);
await stop();

// ---------------------------------------------------------------- back in time

{
  const db = new DatabaseSync(join(dir, "analytico.db"));
  db.exec("PRAGMA busy_timeout=5000");
  const since = ingestStart - 60_000;
  db.exec("BEGIN");
  for (const table of ["page_views", "events"]) db.prepare(`UPDATE ${table} SET received_at_ms=occurred_at_ms+700,received_date=strftime('%Y-%m-%d',(occurred_at_ms+700)/1000,'unixepoch') WHERE received_at_ms>=? AND occurred_at_ms<?`).run(since, ingestStart);
  for (const table of ["page_summaries", "errors"]) db.prepare(`UPDATE ${table} SET received_at_ms=occurred_at_ms+700 WHERE received_at_ms>=? AND occurred_at_ms<?`).run(since, ingestStart);
  db.exec(`UPDATE visitors SET first_seen_ms=coalesce((SELECT min(received_at_ms) FROM page_views pv WHERE pv.site_id=visitors.site_id AND pv.visitor_id=visitors.visitor_id),first_seen_ms),
    last_seen_ms=coalesce((SELECT max(received_at_ms) FROM page_views pv WHERE pv.site_id=visitors.site_id AND pv.visitor_id=visitors.visitor_id),last_seen_ms);
    DELETE FROM rollups; DELETE FROM rollup_days; DELETE FROM visitor_weeks; DELETE FROM settings WHERE name='anomalies.day';`);
  db.exec("COMMIT");
  const count = (sql) => Object.values(db.prepare(sql).get())[0];
  console.log(`page views ${count("SELECT count(*) FROM page_views")}, events ${count("SELECT count(*) FROM events")}, orders ${count("SELECT count(DISTINCT order_id) FROM events WHERE name IN ('purchase','payment_confirmed')")}, errors ${count("SELECT count(*) FROM errors")}, people ${count("SELECT count(*) FROM visitors")}, oldest ${count("SELECT min(received_date) FROM page_views")}`);
  db.close();
}
writeFileSync(join(dir, "port"), String(PORT));
console.log(`seeded in ${((Date.now() - started) / 1000).toFixed(0)} s`);
process.exit(0);
