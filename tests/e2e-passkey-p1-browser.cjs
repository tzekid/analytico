"use strict";

const assert = require("node:assert/strict");
const { chromium } = require("playwright");

const origin = process.argv[2];
const setupUrl = process.argv[3];
const mode = process.argv[4] || "accept";
if (!origin || !setupUrl) throw new Error("usage: browser <origin> <setup-url>");

async function main() {
  const options = {
    headless: true,
    args: ["--no-sandbox", "--ozone-platform=headless", "--use-angle=swiftshader-webgl"]
  };
  if (process.env.ANALYTICO_CHROMIUM_PATH) options.executablePath = process.env.ANALYTICO_CHROMIUM_PATH;
  const browser = await chromium.launch(options);
  try {
    const context = await browser.newContext();
    const page = await context.newPage();
    const cdp = await context.newCDPSession(page);
    await cdp.send("WebAuthn.enable");
    await cdp.send("WebAuthn.addVirtualAuthenticator", {
      options: {
        protocol: "ctap2",
        transport: "internal",
        hasResidentKey: true,
        hasUserVerification: true,
        isUserVerified: true,
        automaticPresenceSimulation: true
      }
    });
    const requested = [];
    const failures = [];
    let verifyBody = "";
    page.on("request", (request) => requested.push(request.url()));
    page.on("console", (message) => {
      if (message.type() === "error") failures.push(message.text());
    });
    page.on("pageerror", (error) => failures.push(error.message));
    page.on("request", (request) => {
      if (request.url() === `${origin}/admin/auth/setup/verify`) {
        verifyBody = request.postData() || "";
      }
    });
    let response = await page.goto(setupUrl, { waitUntil: "load" });
    assert.equal(response.status(), 200);
    assert.equal(new URL(page.url()).hash, "");
    assert.equal(await page.locator("h1").textContent(), "Set up Analytico");
    await page.locator("#passkey-label").fill("Virtual owner passkey");
    await page.locator("#setup-button").click();
    if (mode === "reject-origin") {
      await page.locator("#setup-error").filter({ hasText: "invalid_passkey_response" }).waitFor();
      assert.ok(verifyBody);
      const token = new URL(setupUrl).hash.slice("#token=".length);
      const replayStatus = await page.evaluate(async ({ body, bootstrap }) => {
        const response = await fetch("/admin/auth/setup/verify", {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            "X-Analytico-Bootstrap": bootstrap
          },
          body
        });
        return response.status;
      }, { body: verifyBody, bootstrap: token });
      assert.equal(replayStatus, 401);
      await context.close();
      process.stdout.write(JSON.stringify({ wrong_origin: "rejected", challenge_replay: "rejected" }) + "\n");
      return;
    }
    try {
      await page.waitForURL(`${origin}/admin`, { timeout: 15000 });
    } catch (_) {
      throw new Error(
        "setup failed: " + await page.locator("#setup-error").textContent() +
        " console=" + failures.join(" | ")
      );
    }
    assert.equal(await page.locator("h1").textContent(), "Analytico");
    assert.ok(requested.every((url) => !url.includes("#token=")));
    const cookies = await context.cookies(origin);
    const session = cookies.find((cookie) => cookie.name === "analytico_session");
    assert.ok(session);
    assert.equal(session.httpOnly, true);
    assert.equal(session.sameSite, "Strict");
    assert.equal(session.path, "/");
    await context.close();
  } finally {
    await browser.close();
  }
  process.stdout.write(JSON.stringify({ setup: "ok", virtual_authenticator: "ctap2", fragment_leaked: false }) + "\n");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
