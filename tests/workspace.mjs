// Web workspace journeys with the real executable, on-disk SQLite, the real
// tracker, a browser with a virtual passkey authenticator, and stand-ins for
// an OpenAI-compatible AI endpoint and an OpenID provider.
import assert from "node:assert/strict";
import { createDecipheriv, createECDH, createHash, hkdfSync, randomBytes } from "node:crypto";
import { journey, signer } from "./harness.mjs";

const aiRequests = [];
const pushes = [];
const google = signer();

// A minimal chat-completions endpoint and OpenID provider: records what
// Analytico sends and signs the stand-in user in without a prompt.
let callback = "";
const nonces = new Map();
function fakeAi({ incoming, outgoing, url, base, body, json }) {
  if (url.pathname === "/v1/apns") return pushes.push(JSON.parse(body)), json({});
  if (url.pathname === "/.well-known/openid-configuration") return json({ issuer: base, authorization_endpoint: `${base}/authorize`, token_endpoint: `${base}/token`, jwks_uri: `${base}/jwks` });
  if (url.pathname === "/jwks") return json(google.jwks);
  if (url.pathname === "/authorize") {
    const code = randomBytes(8).toString("hex");
    nonces.set(code, url.searchParams.get("nonce"));
    assert.equal(url.searchParams.get("code_challenge_method"), "S256");
    outgoing.writeHead(302, { location: `${url.searchParams.get("redirect_uri")}?code=${code}&state=${url.searchParams.get("state")}` });
    outgoing.end();
    return;
  }
  if (incoming.method === "GET") {
    if (incoming.url.startsWith("/callback")) callback = incoming.url;
    outgoing.end("connected");
    return;
  }
  if (url.pathname === "/token") {
    const form = new URLSearchParams(body);
    assert.equal(incoming.headers.authorization, `Basic ${Buffer.from("test-client:test-secret").toString("base64")}`);
    assert.ok(form.get("code_verifier").length >= 43);
    const claims = { iss: base, aud: "test-client", sub: "google-subject-1", exp: Math.floor(Date.now() / 1000) + 300, nonce: nonces.get(form.get("code")), email: "owner@example.test", email_verified: true };
    return json({ id_token: google.sign(claims), token_type: "Bearer" });
  }
  if (JSON.parse(body).model === "missing-model") return json({ error: { message: "model not found" } }, 404);
  aiRequests.push({ url: incoming.url, authorization: incoming.headers.authorization, body: JSON.parse(body) });
  const asks = aiRequests.at(-1).body.messages.at(-1).content.includes("Question:");
  const content = asks
    ? JSON.stringify({ answer: "Most visits land on /pricing.", highlights: [{ label: "/pricing", value: "2 views" }], followups: ["Which source sends them?"] })
    : "OK";
  json({ choices: [{ message: { role: "assistant", content } }], usage: { prompt_tokens: 120, completion_tokens: 30 } });
}

await journey("workspace", async (t) => {
  let snippet = "";
  // The proxy plays Caddy: it adds the client address and serves a fixture site.
  const origin = `http://localhost:${await t.proxy("198.51.100.42", (path) => ["/pricing", "/checkout"].includes(path) && `<!doctype html><title>Shop</title>${snippet}<h1>${path}</h1>`)}`;
  const aiBase = await t.standIn(fakeAi);
  const setupLink = t.init(origin);
  assert.match(setupLink, /\/welcome\/[0-9a-f]{64}$/);
  t.cli("site", "add", "shop", origin, "--mode", "session");
  snippet = t.cli("site", "snippet", "shop", origin);
  await t.serve();

  const context = await t.context({ viewport: { width: 1440, height: 1000 } });
  context.on("response", (response) => { if (response.status() >= 400 && new URL(response.url()).pathname.startsWith("/_/")) t.errors.push(`${response.status()} ${response.url()}`); });

  // Real visits through the real tracker.
  const visitor = await context.newPage();
  for (const path of ["/pricing", "/checkout", "/pricing"]) {
    await Promise.all([
      visitor.waitForResponse((response) => response.url() === `${origin}/e` && response.status() === 204),
      visitor.goto(`${origin}${path}`),
    ]);
  }
  await visitor.close();

  // First run: create the owner account with a passkey (Face ID stand-in).
  const page = await t.signUp(context, setupLink);
  await page.waitForURL(`${origin}/shop`);
  await page.getByRole("heading", { name: "Overview" }).waitFor();
  const views = page.locator(".metric", { hasText: "Page views" }).locator(".metric-value");
  assert.equal((await views.textContent()).trim(), "3");
  await page.locator(".toast", { hasText: "Welcome" }).waitFor();

  // Pages: the detail sheet opens from a row and closes back to the list.
  await page.locator(".sidebar").getByRole("link", { name: "Pages" }).click();
  await page.waitForURL(/\/shop\/pages$/);
  await page.locator("tr", { hasText: "/pricing" }).click();
  await page.locator("dialog.sheet[open]").getByText("Views by day").waitFor();
  await page.keyboard.press("Escape");
  await page.waitForURL(/\/shop\/pages$/);

  // Goals and funnels.
  await page.goto(`${origin}/shop/events?goal=%2B`);
  const goalDialog = page.locator("#goal-dialog");
  await goalDialog.getByLabel("Goal name").fill("Checkout reached");
  await goalDialog.getByText("Page visit").click();
  await goalDialog.getByLabel("Matches").fill("/checkout");
  await goalDialog.getByRole("button", { name: "Track goal" }).click();
  await page.locator(".toast", { hasText: "Tracking" }).waitFor();
  await page.locator("td", { hasText: "Checkout reached" }).waitFor();

  await page.goto(`${origin}/shop/funnels`);
  await page.locator("[data-funnel-builder] input[name=name]").fill("Pricing to checkout");
  const steps = page.locator("[data-steps] [data-step]");
  await steps.nth(0).locator("select").selectOption("path");
  await steps.nth(0).locator("input").fill("/pricing");
  await steps.nth(1).locator("select").selectOption("path");
  await steps.nth(1).locator("input").fill("/checkout");
  await page.getByRole("button", { name: "Create funnel" }).click();
  await page.waitForURL(/\/shop\/funnels\/\d+$/);
  await page.getByText("100.0% end to end").waitFor();

  // A filter becomes URL state and a removable chip.
  await page.goto(`${origin}/shop`);
  await page.getByRole("button", { name: "Filter" }).click();
  const filter = page.locator("#filter-pop");
  await filter.locator("[data-dim]").selectOption("page");
  await filter.locator("[data-value]").fill("/checkout");
  await filter.getByRole("button", { name: "Apply" }).click();
  await page.waitForURL(/f=page%3A%2Fcheckout/);
  assert.equal((await views.textContent()).trim(), "1");
  await page.locator(".chips .chip", { hasText: "Page is /checkout" }).waitFor();

  // Alerts and notes from the actions menu, with an undo.
  await page.getByRole("button", { name: "More actions" }).click();
  await page.getByRole("button", { name: "Create alert…" }).click();
  await page.locator("[data-alert-verdict]", { hasText: "Would" }).waitFor();
  await page.locator("#alert-dialog").getByRole("button", { name: "Create alert" }).click();
  await page.locator(".toast", { hasText: "Alert created" }).waitFor();
  await page.getByRole("button", { name: "More actions" }).click();
  await page.getByRole("button", { name: "Add a note…" }).click();
  await page.locator("#note-dialog").getByLabel("Note").fill("Launch");
  await page.locator("#note-dialog").getByRole("button", { name: "Add note" }).click();
  await page.locator(".chart-mark", { hasText: "Launch" }).waitFor();
  await page.locator(".toast").getByRole("button", { name: "Undo" }).click();
  await page.locator(".toast", { hasText: "Note removed" }).waitFor();
  assert.equal(await page.locator(".chart-mark").count(), 0);

  // Bring your own AI: an OpenAI-compatible endpoint, then Ask from ⌘K.
  await page.goto(`${origin}/settings/ai?site=shop&key=compatible`);
  const keyDialog = page.locator("#key-dialog");
  await keyDialog.getByLabel("Base URL").fill(`${aiBase}/v1`);
  await keyDialog.getByLabel("API key (optional)").fill("test-key-123");
  // A failed check keeps everything typed so far.
  await keyDialog.getByLabel("Model").fill("missing-model");
  await keyDialog.getByRole("button", { name: "Check and save" }).click();
  await keyDialog.locator(".callout-bad").waitFor();
  assert.equal(await keyDialog.getByLabel("API key (optional)").inputValue(), "test-key-123");
  assert.equal(await keyDialog.getByLabel("Base URL").inputValue(), `${aiBase}/v1`);
  assert.equal(await keyDialog.getByLabel("Model").inputValue(), "missing-model");
  await keyDialog.getByLabel("Model").fill("fake-model");
  await keyDialog.getByRole("button", { name: "Check and save" }).click();
  await page.locator(".toast", { hasText: "Works" }).waitFor();
  assert.equal(aiRequests[0].authorization, "Bearer test-key-123");

  await page.goto(`${origin}/shop`);
  await page.keyboard.press("Control+k");
  await page.locator("#palette input").fill("Which page do visitors land on?");
  await page.keyboard.press("Enter");
  const answer = page.locator("#ask-sheet");
  await answer.getByText("Most visits land on /pricing.").waitFor();
  await answer.getByText("Which source sends them?").waitFor();
  const sent = aiRequests.at(-1).body.messages.at(-1).content;
  assert.match(sent, /Question: Which page do visitors land on\?/);
  assert.match(sent, /\/pricing/);
  assert.doesNotMatch(sent, /198\.51\.100/);
  await answer.getByRole("link", { name: "See what was sent" }).click();
  await page.getByText("Sent to the model").waitFor();

  // Analytico as a connector: register, consent in the browser, exchange, call.
  // The callback lands on the stand-in server, like a real client's would.
  const redirectUri = `${aiBase}/callback`;
  const registration = await (await fetch(`${origin}/oauth/register`, {
    method: "POST", headers: { "content-type": "application/json" },
    body: JSON.stringify({ client_name: "Claude", redirect_uris: [redirectUri] }),
  })).json();
  const verifier = randomBytes(32).toString("base64url");
  const challenge = createHash("sha256").update(verifier).digest("base64url");
  await page.goto(`${origin}/oauth/authorize?response_type=code&client_id=${registration.client_id}&redirect_uri=${encodeURIComponent(redirectUri)}&code_challenge=${challenge}&code_challenge_method=S256&state=s1`);
  await page.getByRole("button", { name: "Allow read access" }).click();
  await page.waitForURL((url) => url.pathname === "/callback");
  const code = new URL(callback, redirectUri).searchParams.get("code");
  assert.match(code ?? "", /^[0-9a-f]{64}$/, callback);
  const tokens = await (await fetch(`${origin}/oauth/token`, {
    method: "POST",
    body: new URLSearchParams({ grant_type: "authorization_code", code, client_id: registration.client_id, redirect_uri: redirectUri, code_verifier: verifier }),
  })).json();
  const mcp = (body) => fetch(`${origin}/mcp`, { method: "POST", headers: { authorization: `Bearer ${tokens.access_token}`, "content-type": "application/json" }, body: JSON.stringify(body) }).then((response) => response.json());
  assert.equal((await mcp({ jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2025-06-18" } })).result.serverInfo.name, "analytico");
  const overview = await mcp({ jsonrpc: "2.0", id: 2, method: "tools/call", params: { name: "site_overview", arguments: { site: "shop" } } });
  assert.match(overview.result.content[0].text, /page views 3/);
  // Every catalog report is a tool, and a report call returns its table.
  const tools = (await mcp({ jsonrpc: "2.0", id: 3, method: "tools/list" })).result.tools.map((tool) => tool.name);
  for (const name of ["list_sites", "site_overview", "overview", "pages", "goals", "funnel", "errors", "performance"]) assert.ok(tools.includes(name), name);
  const pages = await mcp({ jsonrpc: "2.0", id: 4, method: "tools/call", params: { name: "pages", arguments: { site: "shop", range: "7d" } } });
  assert.match(pages.result.content[0].text, /^Pages for .*\npath \| page_type/);
  assert.equal((await fetch(`${origin}/mcp`, { method: "POST", body: "{}" })).status, 401);

  // The connected app shows up.
  await page.goto(`${origin}/settings/ai?site=shop`);
  await page.getByText("Claude subscription").waitFor();

  // The Mac and iPhone app: discovery, sign-in through the browser with its
  // own client and scheme, then the read API, notes and the live stream.
  const discovery = await (await fetch(`${origin}/.well-known/analytico`)).json();
  assert.deepEqual([discovery.product, discovery.api.level, discovery.setup_complete, discovery.oauth.token_endpoint], ["analytico", 1, true, `${origin}/oauth/token`]);
  assert.ok(discovery.sign_in.includes("passkey"), discovery.sign_in);
  const appVerifier = randomBytes(32).toString("base64url");
  const appChallenge = createHash("sha256").update(appVerifier).digest("base64url");
  await page.goto(`${origin}/oauth/authorize?response_type=code&client_id=analytico-apple&redirect_uri=${encodeURIComponent("analytico://oauth")}&code_challenge=${appChallenge}&code_challenge_method=S256&state=a1&device_name=${encodeURIComponent("Test iPhone")}`);
  await page.getByRole("heading", { name: "Sign in to the Analytico app on Test iPhone" }).waitFor();
  // Chromium won't follow analytico://, so post the consent form's own fields
  // with the browser's session and read where the server sends the app.
  const consentFields = await page.locator("form[action='/oauth/authorize']").evaluate((form) => Object.fromEntries(new FormData(form)));
  const consent = await page.context().request.post(`${origin}/oauth/authorize`, { form: { ...consentFields, decision: "allow" }, headers: { origin }, maxRedirects: 0 });
  const appReturn = new URL(consent.headers().location);
  assert.deepEqual([appReturn.protocol, appReturn.searchParams.get("state")], ["analytico:", "a1"]);
  const exchange = (body) => fetch(`${origin}/oauth/token`, { method: "POST", body: new URLSearchParams(body) }).then((response) => response.json());
  const appTokens = await exchange({ grant_type: "authorization_code", code: appReturn.searchParams.get("code"), client_id: "analytico-apple", redirect_uri: "analytico://oauth", code_verifier: appVerifier });
  assert.equal(appTokens.scope, "app:read app:notes");
  const app = (path, init = {}) => fetch(`${origin}/api/v1${path}`, { ...init, headers: { authorization: `Bearer ${appTokens.access_token}`, ...init.headers } });
  const appSites = (await (await app("/sites")).json()).sites;
  const shopSite = appSites.find((site) => site.slug === "shop");
  assert.ok(shopSite && Number.isInteger(shopSite.today.visitors) && shopSite.today.page_views >= 3, JSON.stringify(appSites));
  assert.ok((await (await app("/catalog")).json()).reports.some((report) => report.name === "overview"));
  assert.equal((await (await app("/sites/shop/overview?range=7d")).json()).report, "overview");
  // Separate scopes: app tokens don't open the connector, and the reverse.
  assert.equal((await fetch(`${origin}/mcp`, { method: "POST", headers: { authorization: `Bearer ${appTokens.access_token}`, "content-type": "application/json" }, body: "{}" })).status, 401);
  assert.equal((await fetch(`${origin}/api/v1/sites`, { headers: { authorization: `Bearer ${tokens.access_token}` } })).status, 401);
  const today = new Date().toISOString().slice(0, 10);
  const added = await app("/sites/shop/notes", { method: "POST", headers: { "content-type": "application/x-www-form-urlencoded" }, body: new URLSearchParams({ day: today, label: "Sent from the app" }) });
  assert.equal(added.status, 201);
  const noteId = (await added.json()).id;
  assert.ok((await (await app("/sites/shop/notes?range=7d")).json()).notes.some((note) => note.id === noteId && note.label === "Sent from the app" && !note.draft));
  assert.equal((await app(`/sites/shop/notes/${noteId}`, { method: "DELETE" })).status, 204);
  assert.equal((await app("/sites/shop/notes", { method: "POST", body: new URLSearchParams({ day: "yesterday", label: "x" }) })).status, 400);
  const stream = new AbortController();
  const live = await app("/sites/shop/live", { signal: stream.signal });
  assert.equal(live.headers.get("content-type"), "text/event-stream");
  const firstEvent = new TextDecoder().decode((await live.body.getReader().read()).value);
  stream.abort();
  assert.match(firstEvent, /retry: 5000/);
  // Refresh rotates the tokens and keeps the device.
  const rotated = await exchange({ grant_type: "refresh_token", refresh_token: appTokens.refresh_token, client_id: "analytico-apple" });
  assert.equal((await exchange({ grant_type: "refresh_token", refresh_token: appTokens.refresh_token, client_id: "analytico-apple" })).error, "invalid_grant");
  appTokens.access_token = rotated.access_token;
  assert.equal((await app("/sites")).status, 200);
  // Push: the app registers its key; a goal reaches the relay as ciphertext
  // that only that key opens (RFC 8291, decrypted here independently).
  const deviceKey = createECDH("prime256v1");
  deviceKey.generateKeys();
  const authSecret = randomBytes(16);
  const register = (fields) => app("/device", { method: "POST", body: new URLSearchParams({ platform: "apns", environment: "development", token: "ab".repeat(32), public_key: deviceKey.getPublicKey().toString("base64url"), auth_secret: authSecret.toString("base64url"), kinds: "alert,goal,note", ...fields }) });
  assert.equal((await register({ public_key: "AAAA" })).status, 400);
  assert.equal((await register({ kinds: "alert,gossip" })).status, 400);
  assert.equal((await register({})).status, 204);
  const settingsDb = t.db("analytico.db", { readOnly: false });
  settingsDb.prepare("INSERT OR REPLACE INTO settings(name,value) VALUES('push.relay',?)").run(aiBase);
  settingsDb.prepare("INSERT INTO goals(site_id,name,kind,match_value,created_at_ms) SELECT id,'Signed up','event','signup',0 FROM sites WHERE slug='shop'").run();
  settingsDb.close();
  const signup = await (await t.context()).newPage();
  await signup.goto(`${origin}/pricing`);
  await signup.evaluate(() => analytico.track("signup"));
  await signup.goto(`${origin}/checkout`);
  const delivered = await t.until(() => pushes[0], "goal push", 45000);
  await signup.close();
  assert.deepEqual([delivered.token, delivered.environment], ["ab".repeat(32), "development"]);
  const sealed = Buffer.from(delivered.payload, "base64");
  const senderKey = sealed.subarray(21, 21 + sealed[20]);
  const ikm = hkdfSync("sha256", deviceKey.computeSecret(senderKey), authSecret, Buffer.concat([Buffer.from("WebPush: info\0"), deviceKey.getPublicKey(), senderKey]), 32);
  const contentKey = (info, length) => Buffer.from(hkdfSync("sha256", ikm, sealed.subarray(0, 16), Buffer.from(`Content-Encoding: ${info}\0`), length));
  const decipher = createDecipheriv("aes-128-gcm", contentKey("aes128gcm", 16), contentKey("nonce", 12));
  decipher.setAuthTag(sealed.subarray(-16));
  const opened = Buffer.concat([decipher.update(sealed.subarray(21 + sealed[20], -16)), decipher.final()]);
  assert.equal(opened.at(-1), 2);
  assert.deepEqual(JSON.parse(opened.subarray(0, -1)), { title: shopSite.name, body: "Goal reached: Signed up", site: "shop", kind: "goal" });
  assert.doesNotMatch(JSON.stringify(delivered), /Signed up|shop/);
  // The app is a device under Settings → Sign-in, not an AI connector; signing it out ends its access.
  await page.goto(`${origin}/settings/ai?site=shop`);
  assert.equal(await page.getByText("Analytico for Mac, iPhone and iPad").count(), 0);
  await page.goto(`${origin}/settings/signin`);
  const deviceRow = page.locator("[data-devices] .method-row", { hasText: "Test iPhone" });
  await deviceRow.waitFor();
  page.once("dialog", (dialog) => dialog.accept());
  await deviceRow.getByRole("button", { name: "Sign out" }).click();
  await page.locator(".toast", { hasText: "Signed out" }).waitFor();
  assert.equal((await app("/sites")).status, 401);
  assert.equal(t.db().prepare("SELECT count(*) AS n FROM devices").get().n, 0);

  // Settings → Sign-in: the passkey is listed; set up Google and link it.
  await page.goto(`${origin}/settings/signin`);
  await page.locator(".method-row", { hasText: "Linux · Passkey" }).waitFor();
  await page.locator(".method-row", { hasText: "Google" }).getByRole("link", { name: "Set up" }).click();
  const provider = page.locator("#provider-dialog");
  await provider.getByLabel("Client ID").fill("test-client");
  await provider.getByLabel("Client secret").fill("test-secret");
  await provider.locator("summary").click();
  await provider.getByLabel("Issuer").fill(`${aiBase}`);
  await provider.getByRole("button", { name: "Save and link Google" }).click();
  await page.waitForURL(/\/settings\/signin$/);
  await page.locator(".method-row", { hasText: "Google · owner@example.test" }).waitFor();

  // A teammate joins with a password from the invite's other ways.
  await page.goto(`${origin}/settings/team`);
  // The owner signed up with a passkey only, and still counts as joined.
  await page.locator("tr", { hasText: "owner@example.test" }).getByText("You · passkey + google").waitFor();
  await page.locator("tr", { hasText: "owner@example.test" }).getByText("Owner", { exact: true }).waitFor();
  await page.getByPlaceholder("name@example.com").fill("ana@example.test");
  await page.getByRole("button", { name: "Invite" }).click();
  const teammateLink = await page.locator("input[readonly]").inputValue();
  const teammateContext = await t.context();
  const teammate = await teammateContext.newPage();
  await teammate.goto(teammateLink);
  await teammate.getByRole("button", { name: "Other ways to sign in" }).click();
  await teammate.getByRole("link", { name: /Choose a password/ }).click();
  await teammate.getByLabel("Password").fill("correct horse battery");
  await teammate.getByRole("button", { name: "Continue" }).click();
  await teammate.waitForURL(`${origin}/shop`);
  await teammateContext.close();

  // Turning passwords off would strand the teammate, so it is refused.
  await page.goto(`${origin}/settings/signin`);
  await page.locator(".method-row", { hasText: "Email and password" }).locator("input[type=checkbox]").click();
  await page.locator(".toast", { hasText: "only sign in with Email and password" }).waitFor();

  // Sign out; the passkey is the main way back in, Google is one of the others.
  await page.getByRole("button", { name: "Sign out" }).click();
  await page.waitForURL(/\/login$/);
  await page.getByRole("button", { name: "Other ways to sign in" }).click();
  await page.getByRole("link", { name: /Continue with Google/ }).click();
  await page.waitForURL(`${origin}/shop`);
  await page.goto(`${origin}/settings/signin`);
  await page.getByRole("button", { name: "Sign out" }).click();
  await page.waitForURL(/\/login$/);
  await page.goto(`${origin}/shop`);
  await page.waitForURL(/\/login\?next=/);
  await page.getByRole("button", { name: "Sign in with passkey" }).click();
  await page.waitForURL(/\/shop$/);

  // Phones get the tab bar.
  await page.setViewportSize({ width: 375, height: 812 });
  await page.locator(".tabbar").getByRole("link", { name: "Pages" }).click();
  await page.waitForURL(/\/shop\/pages$/);

  return "passkey first run, pages, goals, funnels, filters, alerts, notes, BYOK ask, MCP connector, app sign-in and API, encrypted push, Google linking and sign-in, teammate invite";
});
