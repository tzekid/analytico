// What every journey shares: a work dir and the CLI, the real executable on
// a free port, stand-in services, proxies that play Caddy, browser contexts
// that collect page errors, and the passkey first run.
//   await journey("name", async (t) => { ...; return "summary line"; });
// The journey fails on any page error or failed request in the server log,
// prints the log's tail when it fails, and always cleans up.
import assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import { createSign, generateKeyPairSync, randomBytes } from "node:crypto";
import { mkdtemp, rm } from "node:fs/promises";
import { createServer, request } from "node:http";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { setTimeout as delay } from "node:timers/promises";
import { chromium } from "playwright-core";

export const listen = (server) => new Promise((done, fail) => {
  server.once("error", fail);
  server.listen(0, "127.0.0.1", () => done(server.address().port));
});

export async function freePort() {
  const reservation = createServer();
  const port = await listen(reservation);
  await new Promise((done) => reservation.close(done));
  return port;
}

/** RS256 ID tokens for stand-in identity providers: a fresh key per run, its JWKS document, and a signer. */
export function signer() {
  const { privateKey, publicKey } = generateKeyPairSync("rsa", { modulusLength: 2048 });
  const kid = randomBytes(6).toString("hex");
  const jwk = publicKey.export({ format: "jwk" });
  return {
    jwks: { keys: [{ kty: "RSA", use: "sig", alg: "RS256", kid, n: jwk.n, e: jwk.e }] },
    sign(claims, key = privateKey) {
      const head = Buffer.from(JSON.stringify({ alg: "RS256", typ: "JWT", kid })).toString("base64url");
      const body = Buffer.from(JSON.stringify(claims)).toString("base64url");
      const signature = createSign("RSA-SHA256").update(`${head}.${body}`).sign(key).toString("base64url");
      return `${head}.${body}.${signature}`;
    },
    /** A token signed by a different key, for refusal tests. */
    forged(claims) {
      return this.sign(claims, generateKeyPairSync("rsa", { modulusLength: 2048 }).privateKey);
    },
  };
}

export async function journey(name, story) {
  const app = resolve(process.argv[2]);
  const temporary = await mkdtemp(join(tmpdir(), `analytico-${name}-`));
  const data = join(temporary, "data");
  const closers = [];
  let browser;
  const t = {
    app, temporary, data,
    /** The executable's own port, reserved up front so proxies can point at it. */
    port: await freePort(),
    log: "",
    errors: [],
    /** Page errors matching this are expected by the story. */
    expectedErrors: null,
    cli: (...args) => execFileSync(app, [...args, "--data", data], { encoding: "utf8" }),
    /** Creates the data dir; returns the owner's setup link. */
    init: (origin) => execFileSync(app, ["init", data, ...(origin ? ["--origin", origin] : [])], { encoding: "utf8" }).trim().split("\n").at(-1),
    db: (file = "analytico.db", options = { readOnly: true }) => new DatabaseSync(join(data, file), options),
    async until(check, label, ms = 10000) {
      const started = Date.now();
      for (;;) {
        const value = await check();
        if (value) return value;
        if (Date.now() - started > ms) throw new Error(`timed out: ${label}`);
        await delay(100);
      }
    },
    async listen(server) {
      const port = await listen(server);
      closers.push(async () => {
        server.closeAllConnections();
        await new Promise((done) => server.close(done));
      });
      return port;
    },
    /**
     * A stand-in service. The handler gets { incoming, outgoing, url, base,
     * body, json }; anything it leaves unanswered is a 404. Returns its base.
     */
    async standIn(handler) {
      const server = createServer(async (incoming, outgoing) => {
        const base = `http://127.0.0.1:${server.address().port}`;
        let body = "";
        for await (const chunk of incoming) body += chunk;
        const json = (value, status = 200) => {
          outgoing.writeHead(status, { "content-type": "application/json" });
          outgoing.end(JSON.stringify(value));
        };
        await handler({ incoming, outgoing, url: new URL(incoming.url, base), base, body, json });
        if (!outgoing.headersSent) {
          outgoing.writeHead(404);
          outgoing.end();
        }
      });
      return `http://127.0.0.1:${await t.listen(server)}`;
    },
    /**
     * Plays Caddy for one visitor address: serves the fixture page that
     * `fixture(path, origin)` returns, and forwards everything else.
     */
    async proxy(address, fixture = () => undefined) {
      const server = createServer((incoming, outgoing) => {
        const page = incoming.method === "GET" && fixture(incoming.url.split("?")[0], `http://${incoming.headers.host}`);
        if (page) {
          outgoing.writeHead(200, { "content-type": "text/html" });
          outgoing.end(page);
          return;
        }
        const upstream = request({
          hostname: "127.0.0.1", port: t.port, path: incoming.url, method: incoming.method,
          headers: { ...incoming.headers, "x-forwarded-for": address, connection: "close" },
        }, (response) => { outgoing.writeHead(response.statusCode, response.headers); response.pipe(outgoing); });
        upstream.on("error", (error) => outgoing.destroy(error));
        incoming.pipe(upstream);
      });
      return t.listen(server);
    },
    /** Starts the executable and waits until it is ready. */
    async serve() {
      const server = spawn(app, ["serve", "--data", data, "--listen", `127.0.0.1:${t.port}`], { stdio: ["ignore", "ignore", "pipe"] });
      server.stderr.on("data", (bytes) => { t.log = (t.log + bytes).slice(-30000); });
      t.server = server;
      t.exited = new Promise((done, fail) => {
        server.once("error", fail);
        server.once("close", done);
      });
      closers.push(async () => {
        if (server.exitCode !== null || server.signalCode !== null) return;
        server.kill("SIGTERM");
        const timeout = setTimeout(() => server.kill("SIGKILL"), 5000);
        await t.exited;
        clearTimeout(timeout);
      });
      await t.until(async () => {
        assert.equal(server.exitCode, null, t.log);
        try { return (await fetch(`http://127.0.0.1:${t.port}/readyz`)).ok; } catch { return false; }
      }, "server ready");
    },
    /** A browser context as an ordinary desktop Chrome (HeadlessChrome counts as a bot). */
    async context(options = {}) {
      if (!browser) {
        // Passkeys need a real host name: localhost, which maps to the proxies.
        browser = await chromium.launch({ executablePath: process.env.CHROMIUM_PATH || "/usr/bin/chromium", headless: true, args: ["--host-resolver-rules=MAP localhost 127.0.0.1"] });
        closers.push(() => browser.close());
      }
      const context = await browser.newContext({
        userAgent: `Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/${browser.version()} Safari/537.36`,
        viewport: { width: 1280, height: 900 },
        ...options,
      });
      context.setDefaultTimeout(10000);
      context.on("page", (page) => page.on("pageerror", (error) => {
        if (!t.expectedErrors?.test(error.message)) t.errors.push(error.message);
      }));
      return context;
    },
    /** First run: the owner creates an account with a virtual passkey. */
    async signUp(context, setupLink, email = "owner@example.test") {
      const page = await context.newPage();
      const cdp = await context.newCDPSession(page);
      await cdp.send("WebAuthn.enable");
      await cdp.send("WebAuthn.addVirtualAuthenticator", { options: { protocol: "ctap2", transport: "internal", hasResidentKey: true, hasUserVerification: true, isUserVerified: true, automaticPresenceSimulation: true } });
      await page.goto(setupLink);
      await page.getByLabel("Your email").fill(email);
      await page.getByRole("button", { name: "Create a passkey" }).click();
      return page;
    },
  };
  try {
    const summary = await story(t);
    assert.deepEqual(t.errors, []);
    assert.doesNotMatch(t.log, /web_request_failed|chatgpt_callback_failed|panic/);
    console.log(`${name}: ${summary}`);
  } catch (error) {
    console.error(t.log.split("\n").filter((line) => !line.includes("batch_accepted")).slice(-40).join("\n"));
    throw error;
  } finally {
    for (const close of closers.reverse()) await close().catch((error) => console.error(`cleanup: ${error.message}`));
    await rm(temporary, { recursive: true, force: true });
  }
}
