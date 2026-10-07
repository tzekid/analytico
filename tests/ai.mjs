// AI on a ChatGPT plan, end to end: the real executable, a browser, and a
// stand-in for OpenAI (sign-in, JWKS, tokens, models, streamed Responses)
// and for Anthropic (the instance key a teammate falls back to).
import assert from "node:assert/strict";
import { createHash, randomBytes, randomUUID } from "node:crypto";
import { setTimeout as delay } from "node:timers/promises";
import { journey, signer } from "./harness.mjs";

const openai = signer();
const issued = "oaiapp_test";
const plan = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct";

// What the stand-in saw, and how it should answer next.
const seen = { authorize: [], tokens: [], revoked: [], responses: [], anthropic: [] };
const mode = { forged: false, scope: plan };
const attempts = new Map();
let serial = 0;
const live = new Map();

const sse = (outgoing, events) => {
  outgoing.writeHead(200, { "content-type": "text/event-stream" });
  for (const event of events) outgoing.write(`event: ${event.type}\ndata: ${JSON.stringify(event)}\n\n`);
  outgoing.end();
};

function stand({ incoming, outgoing, url, base, body, json }) {
  switch (url.pathname) {
    case "/.well-known/openid-configuration":
      return json({ issuer: base, authorization_endpoint: `${base}/authorize`, token_endpoint: `${base}/token`, jwks_uri: `${base}/jwks`, revocation_endpoint: `${base}/revoke` });
    case "/jwks":
      return json(openai.jwks);
    case "/authorize": {
      const query = Object.fromEntries(url.searchParams);
      seen.authorize.push(query);
      const code = randomBytes(8).toString("hex");
      attempts.set(code, query);
      const back = new URL(query.redirect_uri);
      back.search = new URLSearchParams({ code, state: query.state, scope: mode.scope, ...(query.client_id === "dynamic_agent_client" ? { client_id: issued } : {}) });
      outgoing.writeHead(302, { location: back.href });
      return outgoing.end();
    }
    case "/token": {
      const form = Object.fromEntries(new URLSearchParams(body));
      seen.tokens.push(form);
      serial += 1;
      if (form.grant_type === "authorization_code") {
        const attempt = attempts.get(form.code);
        assert.equal(createHash("sha256").update(form.code_verifier).digest("base64url"), attempt.code_challenge);
        assert.equal(form.redirect_uri, attempt.redirect_uri);
        const claims = { iss: base, aud: form.client_id, sub: "chatgpt-user-1", exp: Math.floor(Date.now() / 1000) + 300, nonce: attempt.nonce, email: "owner@chatgpt.test", email_verified: true };
        // A minute left: the first use refreshes.
        live.set(`access-${serial}`, true);
        live.set(`refresh-${serial}`, true);
        return json({ access_token: `access-${serial}`, refresh_token: `refresh-${serial}`, id_token: mode.forged ? openai.forged(claims) : openai.sign(claims), token_type: "Bearer", expires_in: 60, scope: mode.scope });
      }
      if (!live.has(form.refresh_token)) return json({ error: "refresh_token_reused" }, 400);
      live.delete(form.refresh_token);
      live.set(`refresh-${serial}`, true);
      live.set(`access-${serial}`, true);
      return json({ access_token: `access-${serial}`, refresh_token: `refresh-${serial}`, token_type: "Bearer", expires_in: 3600 });
    }
    case "/revoke":
      seen.revoked.push(Object.fromEntries(new URLSearchParams(body)));
      return json({});
    case "/v1/models":
      assert.ok(live.has(incoming.headers.authorization.slice(7)), incoming.headers.authorization);
      // Without a client version the catalog leaves newer models out.
      assert.equal(url.searchParams.get("client_version"), "99.0.0");
      return json({ models: [
        { slug: "gpt-test", display_name: "GPT Test", visibility: "list", supported_in_api: true },
        { slug: "gpt-hidden", display_name: "Hidden", visibility: "hide", supported_in_api: true },
        { slug: "gpt-codex-only", display_name: "Codex only", visibility: "list", supported_in_api: false },
      ] });
    case "/v1/responses": {
      const request = JSON.parse(body);
      seen.responses.push({ authorization: incoming.headers.authorization, request });
      const question = request.input[0].content;
      if (request.instructions.startsWith("You summarise one visit")) {
        assert.equal(question, "0:00 opened /pricing\n0:05 rage click\n0:09 JavaScript error: TypeError: x is undefined\n");
        return sse(outgoing, [{ type: "response.output_text.delta", delta: "0:00 — Opened the pricing page.\n0:05 — Rage-clicked, then hit an error at 0:09." }, { type: "response.completed", response: { usage: { input_tokens: 80, output_tokens: 25 } } }]);
      }
      if (request.instructions.startsWith("You turn a description")) {
        assert.equal(request.tools, undefined);
        const view = question.includes("Germany") ? { range: "30d", filters: [{ dim: "device", value: "mobile" }, { dim: "country", value: "DE" }, { dim: "planet", value: "Mars" }] } : {};
        return sse(outgoing, [{ type: "response.output_text.delta", delta: JSON.stringify(view) }, { type: "response.completed", response: { usage: { input_tokens: 90, output_tokens: 20 } } }]);
      }
      if (/Question: .*limit/.test(question)) {
        return sse(outgoing, [{ type: "response.created" }, { type: "response.failed", response: { error: { code: "subscription_sharing_usage_limit_exceeded", message: "limit" } } }]);
      }
      const result = request.input.find((item) => item.type === "function_call_output");
      if (!result) {
        return sse(outgoing, [
          { type: "response.created" },
          { type: "response.output_item.done", item: { type: "function_call", id: "fc_1", call_id: "call_1", namespace: "analytico", name: "pages", arguments: JSON.stringify({ range: "7d" }), status: "completed" } },
          { type: "response.completed", response: { usage: { input_tokens: 400, output_tokens: 20 } } },
        ]);
      }
      return sse(outgoing, [
        { type: "response.output_text.delta", delta: "Most visits land on " },
        { type: "response.output_text.delta", delta: "[Pages](/shop/pages?range=7d), and [elsewhere](https://evil.test).\n" },
        { type: "response.output_text.delta", delta: "Follow-ups: Which source sends them? | What converts?" },
        { type: "response.completed", response: { usage: { input_tokens: 500, output_tokens: 30 } } },
      ]);
    }
    case "/anthropic/messages": {
      const request = JSON.parse(body);
      seen.anthropic.push(request);
      const last = request.messages.at(-1);
      if (typeof last.content === "string") {
        return sse(outgoing, [
          { type: "message_start", message: { usage: { input_tokens: 300 } } },
          { type: "content_block_start", index: 0, content_block: { type: "tool_use", id: "toolu_1", name: "acquisition", input: {} } },
          { type: "content_block_delta", index: 0, delta: { type: "input_json_delta", partial_json: "{\"range\":" } },
          { type: "content_block_delta", index: 0, delta: { type: "input_json_delta", partial_json: "\"30d\"}" } },
          { type: "content_block_stop", index: 0 },
          { type: "message_delta", delta: { stop_reason: "tool_use" }, usage: { output_tokens: 12 } },
          { type: "message_stop" },
        ]);
      }
      return sse(outgoing, [
        { type: "message_start", message: { usage: { input_tokens: 350 } } },
        { type: "content_block_start", index: 0, content_block: { type: "text", text: "" } },
        { type: "content_block_delta", index: 0, delta: { type: "text_delta", text: "Search sends the most visitors." } },
        { type: "content_block_stop", index: 0 },
        { type: "message_delta", delta: { stop_reason: "end_turn" }, usage: { output_tokens: 9 } },
        { type: "message_stop" },
      ]);
    }
  }
}

await journey("ai", async (t) => {
  const base = await t.standIn(stand);
  const origin = `http://localhost:${t.port}`;
  const setupLink = t.init(origin);
  const shopId = /public_id=([^ ]+)/.exec(t.cli("site", "add", "shop", origin, "--mode", "session"))[1];
  // OpenAI's addresses point at the stand-in; so does the instance's Anthropic key.
  const db = t.db("analytico.db", {});
  const put = db.prepare("INSERT INTO settings(name,value) VALUES(?,?)");
  for (const [name, value] of [["chatgpt.auth_origin", base], ["chatgpt.api_base", `${base}/v1`], ["ai.provider", "anthropic"], ["ai.model", "claude-test"], ["ai.base_url", `${base}/anthropic`]]) put.run(name, value);
  db.close();
  await t.serve();

  const context = await t.context();
  context.on("page", (page) => page.on("dialog", (dialog) => dialog.accept()));
  const page = await t.signUp(context, setupLink);
  await page.waitForURL(`${origin}/shop`);

  // Starts a sign-in; the consent page (the stand-in) redirects at once.
  const continueWith = async (name = "Continue with ChatGPT") => {
    const [popup] = await Promise.all([context.waitForEvent("page"), page.getByRole("link", { name }).click()]);
    await page.locator("#chatgpt-dialog[open]").waitFor();
    return popup;
  };

  // A forged ID token, then an account without plan sharing: refused, nothing saved.
  await page.goto(`${origin}/settings/ai`);
  // OpenAI's approved button: black, with the ChatGPT logo.
  const logo = page.locator("a.btn-chatgpt svg");
  assert.match(await logo.locator("use").getAttribute("href"), /#chatgpt$/);
  assert.equal((await logo.boundingBox()).width, 18);
  mode.forged = true;
  let popup = await continueWith();
  await popup.getByText("couldn’t be verified").waitFor();
  await popup.close();
  mode.forged = false;
  mode.scope = "openid profile email offline_access";
  await page.goto(`${origin}/settings/ai`);
  popup = await continueWith();
  await popup.getByText("can’t share its plan").waitFor();
  await popup.close();
  mode.scope = plan;
  const first = seen.authorize[0];
  assert.equal(first.client_id, "dynamic_agent_client");
  assert.equal(first.agent_name_hint, "Analytico");
  assert.match(first.ext_agent_host_id, /^urn:uuid:[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
  assert.equal(first.scope, plan);
  assert.equal(first.resource, "https://api.openai.com/v1");
  assert.equal(first.code_challenge_method, "S256");
  assert.match(first.redirect_uri, /^http:\/\/127\.0\.0\.1:\d+\/auth\/callback$/);

  // A remote server: the browser can't reach the loopback address, so the
  // address is pasted into the waiting dialog.
  await page.goto(`${origin}/settings/ai`);
  let blocked = "";
  // Routing never sees a redirect's next hop: the start is taken, the
  // consent page asked directly, and the browser stops there, as if the
  // loopback address can't be reached.
  await context.route((url) => url.pathname === "/settings/ai/chatgpt/start", async (route) => {
    const consent = (await route.fetch({ maxRedirects: 0 })).headers().location;
    blocked = (await fetch(consent, { redirect: "manual" })).headers.get("location");
    await route.fulfill({ status: 502, body: "This site can't be reached" });
  });
  popup = await continueWith();
  for (let attempt = 0; attempt < 50 && !blocked; attempt++) await delay(100);
  await popup.close();
  await context.unrouteAll();
  const dialog = page.locator("#chatgpt-dialog");
  await dialog.getByLabel("Address from the tab").fill(blocked);
  await dialog.getByRole("button", { name: "Continue", exact: true }).click();
  await page.getByText("You’re using your ChatGPT plan").waitFor();
  await page.getByRole("button", { name: "Got it" }).click();
  await page.getByText("Using ChatGPT plan").waitFor();
  await page.getByText("owner@chatgpt.test").waitFor();
  const exchange = seen.tokens.at(-1);
  assert.equal(exchange.grant_type, "authorization_code");
  assert.equal(exchange.client_id, issued);
  assert.equal(exchange.resource, "https://api.openai.com/v1");
  // Only listed models are offered.
  assert.deepEqual(await page.locator("select[name=model] option").allTextContents(), ["GPT Test"]);
  // Tokens stay sealed on the server.
  const html = await page.content();
  assert.doesNotMatch(html, /access-\d|refresh-\d/);
  const reader = t.db();
  const stored = reader.prepare("SELECT client_id,subject,tokens FROM chatgpt_accounts").all();
  assert.equal(stored.length, 1);
  assert.equal(stored[0].client_id, issued);
  assert.equal(stored[0].subject, "chatgpt-user-1");
  assert.doesNotMatch(stored[0].tokens, /access|refresh/);
  reader.close();

  // Sign out revokes; signing in again reuses the issued client and
  // completes through the loopback listener by itself.
  const pastedRefresh = `refresh-${serial}`;
  await page.locator("form[action='/settings/ai/chatgpt/sign-out'] button").click();
  await page.getByText("Use your ChatGPT plan").waitFor();
  assert.deepEqual(seen.revoked.at(-1), { token_type_hint: "refresh_token", token: pastedRefresh, client_id: issued });
  popup = await continueWith();
  assert.equal(seen.authorize.at(-1).client_id, issued);
  await page.getByText("Using ChatGPT plan").waitFor();
  await popup.close();

  // Ask: the near-expired token is refreshed (rotating the refresh token),
  // the model reads a report through a tool, and the answer streams in.
  const signedIn = `refresh-${serial}`;
  await page.goto(`${origin}/shop`);
  await page.keyboard.press("Control+k");
  await page.locator("#palette input").fill("Which page do visitors land on?");
  await page.keyboard.press("Enter");
  const sheet = page.locator("#ask-sheet");
  await sheet.getByText("Which source sends them?").waitFor();
  const refresh = seen.tokens.find((form) => form.grant_type === "refresh_token");
  assert.deepEqual(refresh, { grant_type: "refresh_token", client_id: issued, refresh_token: signedIn, resource: "https://api.openai.com/v1" });
  const [call, answer] = seen.responses.slice(-2);
  assert.equal(call.authorization, `Bearer access-${serial}`);
  assert.equal(call.request.model, "gpt-test");
  assert.equal(call.request.store, false);
  assert.equal(call.request.stream, true);
  assert.equal(call.request.max_output_tokens, undefined);
  assert.equal(call.request.tools[0].type, "namespace");
  assert.ok(call.request.tools[0].tools.some((tool) => tool.name === "pages" && !("site" in tool.parameters.properties)));
  assert.match(call.request.input[0].content, /\nScreen: overview\nQuestion: Which page do visitors land on\?/);
  const output = answer.request.input.find((item) => item.type === "function_call_output");
  assert.equal(output.call_id, "call_1");
  assert.match(output.output, /^Pages for /);
  assert.equal(answer.request.input.find((item) => item.type === "function_call").namespace, "analytico");
  // Links stay inside the website; the plan is named next to the answer.
  assert.equal(await sheet.getByRole("link", { name: "Pages" }).getAttribute("href"), "/shop/pages?range=7d");
  assert.equal(await sheet.getByRole("link", { name: "elsewhere" }).count(), 0);
  await sheet.getByText("Using ChatGPT plan").waitFor();
  await sheet.getByRole("link", { name: "Manage usage" }).waitFor();

  // A spent plan stops with its own message, never falling back to the key.
  const anthropicBefore = seen.anthropic.length;
  await sheet.getByPlaceholder("Ask a follow-up…").fill("Have I hit the limit?");
  await sheet.getByRole("button", { name: "Ask", exact: true }).click();
  await page.locator("#ask-sheet").getByText("Usage limit reached").waitFor();
  assert.equal(await page.locator("#ask-sheet").getByRole("link", { name: "Manage usage" }).getAttribute("href"), "https://chatgpt.com/settings/usage");
  assert.match(await page.locator("#ask-sheet .callout use").getAttribute("href"), /#chatgpt$/);
  assert.equal(seen.anthropic.length, anthropicBefore);

  // Plain-language filters: the description becomes chips, then the view.
  await page.keyboard.press("Escape");
  await page.goto(`${origin}/shop/pages`);
  await page.getByRole("button", { name: "Filter" }).click();
  const describe = page.getByLabel("Describe the visitors");
  await describe.fill("mobile visitors from Germany last month");
  await describe.press("Enter");
  const described = page.locator("[data-describe-out]");
  await described.getByText("Device is mobile").waitFor();
  await described.getByText("Country is DE").waitFor();
  assert.equal(await described.locator(".chip").count(), 3);
  await described.getByRole("link", { name: "Apply" }).click();
  await page.waitForURL(/\/shop\/pages\?range=30d&f=device:mobile&f=country:DE$/);
  await page.getByRole("button", { name: "Filter" }).click();
  await describe.fill("something vague");
  await describe.press("Enter");
  await described.getByText("Couldn’t turn that into filters").waitFor();
  await page.keyboard.press("Escape");

  // A session's summary: its moments (never anything typed) become lines
  // that seek the replay.
  const sessionId = randomUUID();
  const pageId = randomUUID();
  const at = Date.now() - 60_000;
  const moment = (offset, extra) => ({ event_id: randomUUID(), page_id: pageId, session_id: sessionId, occurred_at_ms: at + offset, tracking_mode: "session", consent_mode: "analytics", tracker_version: "1", release_id: "", internal: false, path: "/pricing", ...extra });
  const collected = await fetch(`http://127.0.0.1:${t.port}/e`, {
    method: "POST",
    headers: { origin, "content-type": "text/plain", "x-forwarded-for": "198.51.100.9", "user-agent": "Mozilla/5.0 (X11; Linux x86_64) Chrome/140 Safari/537.36" },
    body: JSON.stringify({ v: 2, site: shopId, sent_at_ms: Date.now(), records: [
      moment(0, { type: "page_view", navigation_type: "navigate", viewport_class: "desktop", language: "en" }),
      moment(5000, { type: "event", name: "rage_click", properties: { element: "button" } }),
      moment(9000, { type: "error", message: "TypeError: x is undefined", file: "/app.js", line: 3, column: 1 }),
    ] }),
  });
  assert.equal(collected.status, 204, await collected.text());
  await page.goto(`${origin}/shop/replays/${sessionId}`);
  await page.getByRole("button", { name: "Summarise" }).click();
  const summary = page.locator("[data-summary-out]");
  await summary.getByText("Rage-clicked, then hit an error at 0:09.").waitFor();
  assert.deepEqual(await summary.locator("[data-seek]").evaluateAll((rows) => rows.map((row) => row.dataset.seek)), ["0", "5000"]);

  // A teammate can't use the owner's plan: their Ask runs on the instance's
  // key (Anthropic, with a tool call), and Settings → AI shows only their own plan.
  await page.goto(`${origin}/settings/team`);
  await page.getByPlaceholder("name@example.com").fill("ana@example.test");
  await page.locator("form.invite select[name=role]").selectOption("viewer");
  await page.getByRole("button", { name: "Invite" }).click();
  const invite = await page.locator("input[readonly]").inputValue();
  const teammateContext = await t.context();
  const teammate = await teammateContext.newPage();
  await teammate.goto(invite);
  await teammate.getByRole("button", { name: "Other ways to sign in" }).click();
  await teammate.getByRole("link", { name: /Choose a password/ }).click();
  await teammate.getByLabel("Password").fill("correct horse battery");
  await teammate.getByRole("button", { name: "Continue" }).click();
  await teammate.waitForURL(`${origin}/shop`);
  const responsesBefore = seen.responses.length;
  await teammate.keyboard.press("Control+k");
  await teammate.locator("#palette input").fill("Where do visitors come from?");
  await teammate.keyboard.press("Enter");
  await teammate.locator("#ask-sheet").getByText("Search sends the most visitors.").waitFor();
  assert.equal(seen.responses.length, responsesBefore);
  const [toolTurn, finalTurn] = seen.anthropic.slice(-2);
  assert.equal(toolTurn.model, "claude-test");
  assert.equal(toolTurn.stream, true);
  assert.ok(toolTurn.tools.some((tool) => tool.name === "acquisition" && tool.input_schema.type === "object"));
  assert.deepEqual(finalTurn.messages[1].content[0], { type: "tool_use", id: "toolu_1", name: "acquisition", input: { range: "30d" } });
  assert.equal(finalTurn.messages[2].content[0].tool_use_id, "toolu_1");
  assert.match(finalTurn.messages[2].content[0].content, /^Acquisition for /);
  await teammate.goto(`${origin}/settings/ai`);
  await teammate.getByText("Use your ChatGPT plan").waitFor();
  assert.equal(await teammate.getByText("For the whole team").count(), 0);
  await teammateContext.close();

  return "ChatGPT plan sign-in (forged token, scope, paste, loopback, reuse), revoke, refresh rotation, streamed Ask with tools and the screen, usage limit, plain-language filters, session summary, teammate on the instance key (Anthropic tools)";
});
