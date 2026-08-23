"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const { chromium } = require("playwright");

const origin = process.argv[2];
const setupUrl = process.argv[3];
const cookieFile = process.argv[4];
if (!origin || !setupUrl || !cookieFile) {
  throw new Error("usage: e2e-passkey-session <origin> <setup-url> <cookie-file>");
}

async function main() {
  const options = {
    headless: true,
    args: ["--no-sandbox", "--ozone-platform=headless", "--use-angle=swiftshader-webgl"],
  };
  if (process.env.ANALYTICO_CHROMIUM_PATH) {
    options.executablePath = process.env.ANALYTICO_CHROMIUM_PATH;
  }
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
        automaticPresenceSimulation: true,
      },
    });
    await page.goto(setupUrl);
    await page.locator("#setup-button").click();
    try {
      await page.waitForURL(
        (url) =>
          url.origin === origin &&
          /^\/admin\/sites\/[^/]+\/overview$/.test(url.pathname),
        { timeout: 15000 },
      );
    } catch (_) {
      throw new Error("passkey setup failed: " + await page.locator("#setup-error").textContent());
    }
    const session = (await context.cookies(origin)).find(
      (cookie) => cookie.name === "analytico_session",
    );
    assert.ok(session);
    fs.writeFileSync(cookieFile, session.value, { encoding: "utf8", mode: 0o600 });
    await context.close();
  } finally {
    await browser.close();
  }
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
