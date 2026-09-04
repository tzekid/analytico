import assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import { mkdtemp, rm } from "node:fs/promises";
import { createServer, request } from "node:http";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { setTimeout as delay } from "node:timers/promises";
import { chromium } from "playwright-core";

const app = resolve(process.argv[2]);
const temporary = await mkdtemp(join(tmpdir(), "analytico-browser-"));
const data = join(temporary, "data");
const cli = (...args) => execFileSync(app, [...args, "--data", data], { encoding: "utf8" });
const report = (kind, site) => JSON.parse(cli("report", kind, site, "--json"));
const snippets = new Map();
snippets.set("/done", "<p>Finished</p>");
let backend;
let backendExit;
let browser;
let backendFailure;
let backendLog = "";
let backendPort;

// Only this fixture proxy supplies the client address; the collector keeps its
// normal mandatory proxy-header and exact-origin validation.
const proxy = createServer((incoming, outgoing) => {
  const snippet = snippets.get(incoming.url);
  if (snippet) {
    outgoing.writeHead(200, { "content-type": "text/html" });
    outgoing.end(`<!doctype html><title>Tracker fixture</title><button data-analytics-action="register">Register</button>${snippet}`);
    return;
  }
  const upstream = request({
    hostname: "127.0.0.1", port: backendPort, path: incoming.url,
    method: incoming.method,
    headers: { ...incoming.headers, "x-forwarded-for": "198.51.100.42", connection: "close" },
  }, (response) => {
    outgoing.writeHead(response.statusCode, response.headers);
    response.pipe(outgoing);
  });
  upstream.on("error", (error) => outgoing.destroy(error));
  incoming.pipe(upstream);
});

try {
  await new Promise((resolve, reject) => {
    proxy.once("error", reject);
    proxy.listen(0, "127.0.0.1", resolve);
  });
  const origin = `http://127.0.0.1:${proxy.address().port}`;
  // Reserve an ephemeral port while preparing the sites, then release it for
  // the real executable. An unexpected bind failure is a test failure.
  const reservation = createServer();
  await new Promise((resolve, reject) => {
    reservation.once("error", reject);
    reservation.listen(0, "127.0.0.1", resolve);
  });
  backendPort = reservation.address().port;
  await new Promise((resolve) => reservation.close(resolve));
  execFileSync(app, ["init", data], { stdio: "pipe" });
  const publicIds = {};
  for (const mode of ["lite", "session"]) {
    const output = cli("site", "add", mode, origin, "--mode", mode);
    publicIds[mode] = /public_id=([^ ]+)/.exec(output)[1];
    snippets.set(`/${mode}`, cli("site", "snippet", mode, origin));
  }
  backend = spawn(app, ["serve", "--data", data, "--listen", `127.0.0.1:${backendPort}`], { stdio: ["ignore", "ignore", "pipe"] });
  backend.on("error", (error) => { backendFailure = error; });
  backend.stderr.on("data", (bytes) => { backendLog = (backendLog + bytes).slice(-8192); });
  backendExit = new Promise((resolve) => backend.once("close", resolve));
  let ready = false;
  for (let attempt = 0; attempt < 50; attempt++) {
    assert.ifError(backendFailure);
    assert.equal(backend.exitCode, null, backendLog);
    try {
      const response = await fetch(`${origin}/readyz`, { signal: AbortSignal.timeout(500) });
      ready = response.ok && (await response.text()).trim() === "ready";
    } catch { /* Startup is polled only until the fixed deadline. */ }
    if (ready) break;
    await delay(100);
  }
  assert.ok(ready, `collector did not start: ${backendLog}`);
  browser = await chromium.launch({ executablePath: process.env.CHROMIUM_PATH || "/usr/bin/chromium", headless: true });
  // Model ordinary desktop traffic. HeadlessChrome is intentionally classified
  // as automation and excluded from human-traffic reports by the product.
  const context = await browser.newContext({ userAgent: `Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/${browser.version()} Safari/537.36` });
  context.setDefaultTimeout(10000);
  const errors = [];
  context.on("page", (page) => page.on("pageerror", (error) => errors.push(error.message)));

  function collected(page, kind) {
    return page.waitForResponse((response) => {
      if (response.url() !== `${origin}/e` || response.request().method() !== "POST") return false;
      return JSON.parse(response.request().postData()).records.some((record) => record.type === kind);
    });
  }

  async function visit(page, path) {
    const [response] = await Promise.all([
      collected(page, "page_view"),
      page.goto(`${origin}${path}`),
    ]);
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

  const session = await context.newPage();
  await visit(session, "/session");
  const sessionId = await session.evaluate((site) => sessionStorage.getItem(`analytico:${site}:session`), publicIds.session);
  assert.match(sessionId, /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
  await visit(session, "/session");
  const sessions = JSON.parse(cli("session", "list", "session", "--json"));
  assert.equal(sessions.length, 1);
  assert.equal(sessions[0].session_id, sessionId);
  assert.equal(sessions[0].page_views, 2);
  await session.getByRole("button", { name: "Register" }).click();
  // Actions intentionally travel with the page summary on navigation.
  await session.goto(`${origin}/done`);
  let actions;
  for (let attempt = 0; attempt < 50; attempt++) {
    actions = report("actions", "session");
    if (actions.length) break;
    await delay(100);
  }
  assert.deepEqual(actions, [{ name: "action_started", action: "register", occurrences: 1 }], backendLog);
  assert.deepEqual(errors, []);
  console.log("browser: Lite persists without storage; Session persists the same identity across navigation");
} finally {
  try {
    await browser?.close();
  } finally {
    if (backend) {
      backend.kill("SIGTERM");
      const timeout = setTimeout(() => backend.kill("SIGKILL"), 5000);
      await backendExit;
      clearTimeout(timeout);
    }
    proxy.closeAllConnections();
    await new Promise((resolve) => proxy.close(resolve));
    await rm(temporary, { recursive: true, force: true });
  }
}
