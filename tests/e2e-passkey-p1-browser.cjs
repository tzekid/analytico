"use strict";

const assert = require("node:assert/strict");
const { chromium } = require("playwright");

const origin = process.argv[2];
const setupUrl = process.argv[3];
const mode = process.argv[4] || "accept";
if (!origin || !setupUrl) throw new Error("usage: browser <origin> <setup-url>");

async function main() {
  const loginDurations = [];
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
    const authenticator = await cdp.send("WebAuthn.addVirtualAuthenticator", {
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
    let renameRequest = null;
    page.on("request", (request) => requested.push(request.url()));
    page.on("console", (message) => {
      if (message.type() === "error") failures.push(message.text());
    });
    page.on("pageerror", (error) => failures.push(error.message));
    page.on("request", (request) => {
      if (request.url() === `${origin}/admin/auth/setup/verify`) {
        verifyBody = request.postData() || "";
      }
      if (request.url() === `${origin}/admin/security/passkeys/rename`) {
        renameRequest = request;
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

    const anonymous = await browser.newContext();
    const anonymousPage = await anonymous.newPage();
    response = await anonymousPage.goto(`${origin}/admin?site=example&report=overview`);
    assert.equal(response.status(), 200);
    assert.equal(await anonymousPage.locator("h1").textContent(), "Analytico");
    assert.equal(await anonymousPage.locator("#login-button").count(), 1);
    assert.equal(await anonymousPage.locator("#login-error").isVisible(), false);
    assert.equal(
      await anonymousPage.locator("body").getAttribute("data-return"),
      "/admin?site=example&report=overview"
    );
    assert.equal(await anonymousPage.locator("#report").count(), 0);
    await anonymous.close();

    await page.goto(`${origin}/admin/security`);
    const firstCredentials = await cdp.send("WebAuthn.getCredentials", {
      authenticatorId: authenticator.authenticatorId
    });
    assert.equal(firstCredentials.credentials.length, 1);
    const firstCredential = firstCredentials.credentials[0];
    await cdp.send("WebAuthn.setAutomaticPresenceSimulation", {
      authenticatorId: authenticator.authenticatorId,
      enabled: false
    });
    const backupAuthenticator = await cdp.send("WebAuthn.addVirtualAuthenticator", {
      options: {
        protocol: "ctap2",
        transport: "usb",
        hasResidentKey: true,
        hasUserVerification: true,
        isUserVerified: true,
        automaticPresenceSimulation: true
      }
    });
    await page.locator("#add-passkey-label").fill("Backup passkey");
    await page.locator("#add-passkey-button").click();
    try {
      await page.waitForURL(`${origin}/admin/security?notice=passkey-added`, { timeout: 15000 });
    } catch (_) {
      throw new Error(
        "add passkey failed: " + await page.locator("#add-passkey-error").textContent() +
        " console=" + failures.join(" | ") + " requested=" + requested.slice(-8).join(" | ")
      );
    }
    const backupCredentials = await cdp.send("WebAuthn.getCredentials", {
      authenticatorId: backupAuthenticator.authenticatorId
    });
    assert.equal(backupCredentials.credentials.length, 1);
    const secondCredential = backupCredentials.credentials[0];
    assert.notEqual(secondCredential.credentialId, firstCredential.credentialId);
    const backupItem = page.locator("li").filter({ hasText: "Backup passkey" });
    await backupItem.locator('form[action="/admin/security/passkeys/rename"] input[name="label"]').fill("Phone passkey");
    await backupItem.locator('form[action="/admin/security/passkeys/rename"] button').click();
    await page.waitForTimeout(500);
    if (!page.url().includes("/admin/security?")) {
      const headers = renameRequest ? await renameRequest.allHeaders() : {};
      const posted = renameRequest ? renameRequest.postData() || "" : "";
      throw new Error("rename did not navigate: " + page.url() + " body=" + await page.locator("body").textContent() +
        " origin=" + headers.origin + " content-type=" + headers["content-type"] +
        " fields=" + posted.split("&").map((field) => field.split("=")[0]).join(",") +
        " requested=" + requested.slice(-5).join(" | "));
    }
    assert.equal(page.url(), `${origin}/admin/security?notice=passkey-renamed`);
    assert.equal(await page.locator("li strong", { hasText: "Phone passkey" }).count(), 1);

    await cdp.send("WebAuthn.setAutomaticPresenceSimulation", {
      authenticatorId: authenticator.authenticatorId,
      enabled: true
    });
    await cdp.send("WebAuthn.setAutomaticPresenceSimulation", {
      authenticatorId: backupAuthenticator.authenticatorId,
      enabled: false
    });
    await context.clearCookies();
    await page.goto(`${origin}/admin/login`);
    let loginStarted = Date.now();
    await page.locator("#login-button").click();
    await page.waitForURL(`${origin}/admin`);
    loginDurations.push(Date.now() - loginStarted);
    const firstLoginSession = (await context.cookies(origin)).find(
      (cookie) => cookie.name === "analytico_session"
    );
    assert.ok(firstLoginSession);

    await cdp.send("WebAuthn.setAutomaticPresenceSimulation", {
      authenticatorId: authenticator.authenticatorId,
      enabled: false
    });
    await cdp.send("WebAuthn.setAutomaticPresenceSimulation", {
      authenticatorId: backupAuthenticator.authenticatorId,
      enabled: true
    });
    await context.clearCookies();
    await page.goto(`${origin}/admin/login`);
    loginStarted = Date.now();
    await page.locator("#login-button").click();
    await page.waitForURL(`${origin}/admin`);
    loginDurations.push(Date.now() - loginStarted);
    const secondLoginSession = (await context.cookies(origin)).find(
      (cookie) => cookie.name === "analytico_session"
    );
    assert.ok(secondLoginSession);
    assert.notEqual(firstLoginSession.value, secondLoginSession.value);

    const csrf = await page.locator('input[name="csrf"]').first().getAttribute("value");
    assert.ok(csrf && csrf.length >= 32);
    const crossOrigin = await context.request.post(`${origin}/admin/goals`, {
      headers: {
        Cookie: `analytico_session=${secondLoginSession.value}`,
        "Content-Type": "application/x-www-form-urlencoded",
        Origin: "https://attacker.example"
      },
      data: `csrf=${encodeURIComponent(csrf)}&site=example&name=Cross&kind=event&value=cross`
    });
    assert.equal(crossOrigin.status(), 403);

    await page.goto(`${origin}/admin/security`);
    while (await page.locator('form[action="/admin/security/sessions/revoke"] button').count()) {
      await page.locator('form[action="/admin/security/sessions/revoke"] button').first().click();
      await page.waitForURL(`${origin}/admin/security?notice=session-revoked`);
    }
    const revokedSession = await browser.newContext({ javaScriptEnabled: false });
    await revokedSession.addCookies([firstLoginSession]);
    const revokedPage = await revokedSession.newPage();
    await revokedPage.goto(`${origin}/admin`);
    assert.equal(await revokedPage.locator("#login-button").count(), 1);
    await revokedSession.close();

    const firstPasskeyItem = page.locator("li").filter({ hasText: "Virtual owner passkey" });
    await firstPasskeyItem.locator('form[action="/admin/security/passkeys/revoke"] button').click();
    await page.waitForURL(`${origin}/admin/security?notice=passkey-revoked`);
    const lastPasskeyItem = page.locator("li").filter({ hasText: "Phone passkey" });
    await lastPasskeyItem.locator('form[action="/admin/security/passkeys/revoke"] button').click();
    await page.waitForURL(`${origin}/admin/security?error=last-passkey`);
    assert.equal(await page.getByText("The last active passkey cannot be revoked.").count(), 1);

    const noScript = await browser.newContext({ javaScriptEnabled: false });
    await noScript.addCookies([secondLoginSession]);
    const noScriptPage = await noScript.newPage();
    response = await noScriptPage.goto(`${origin}/admin`);
    assert.equal(response.status(), 200);
    assert.equal(await noScriptPage.locator("#report").count(), 1);
    await noScriptPage.locator(
      'details.management:has(form[action="/admin/goals"]) > summary',
    ).click();
    const goalForm = noScriptPage.locator('form[action="/admin/goals"]');
    await goalForm.locator('input[name="name"]').fill("Signup");
    await goalForm.locator('select[name="kind"]').selectOption("event");
    await goalForm.locator('input[name="value"]').fill("signup");
    await goalForm.locator('button[type="submit"]').click();
    await noScriptPage.waitForURL(/notice=goal-added/);
    assert.equal(await noScriptPage.locator("li strong", { hasText: "Signup" }).count(), 1);
    const funnelForm = noScriptPage.locator('form[action="/admin/funnels"]');
    await funnelForm.locator('input[name="name"]').fill("Signup journey");
    await funnelForm.locator('textarea[name="steps"]').fill("path=/\nevent=signup");
    await funnelForm.locator('button[type="submit"]').click();
    await noScriptPage.waitForURL(/notice=funnel-added/);
    assert.equal(await noScriptPage.locator("li strong", { hasText: "Signup journey" }).count(), 1);
    await noScriptPage.locator('form[action="/admin/logout"] button').click();
    await noScriptPage.waitForURL(`${origin}/admin/login`);
    await noScript.close();

    response = await page.goto(`${origin}/admin`);
    assert.equal(response.status(), 200);
    assert.equal(await page.locator("#login-button").count(), 1);
    loginStarted = Date.now();
    await page.locator("#login-button").click();
    try {
      await page.waitForURL(`${origin}/admin`, { timeout: 15000 });
    } catch (_) {
      throw new Error("final login failed: " + await page.locator("#login-error").textContent());
    }
    loginDurations.push(Date.now() - loginStarted);
    assert.equal(await page.locator("#report").count(), 1);

    const malicious = await browser.newContext();
    const maliciousPage = await malicious.newPage();
    await maliciousPage.goto(`${origin}/admin/login?return=${encodeURIComponent("//attacker.example/")}`);
    assert.equal(await maliciousPage.locator("body").getAttribute("data-return"), "/admin");
    await malicious.close();
    await context.close();
  } finally {
    await browser.close();
  }
  process.stdout.write(JSON.stringify({
    setup: "ok",
    both_passkeys_login: "ok",
    rename: "ok",
    credential_revoke: "ok",
    last_passkey: "protected",
    other_sessions: "revoked",
    logout: "revoked",
    no_javascript_dashboard: "ok",
    csrf_origin: "enforced",
    return_path: "bounded",
    virtual_authenticator: "ctap2",
    fragment_leaked: false,
    max_virtual_login_ms: Math.max(...loginDurations)
  }) + "\n");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
