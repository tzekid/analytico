"use strict";

const assert = require("node:assert/strict");
const { chromium } = require("playwright");

const [
  mode,
  cloudioOrigin,
  dashboardOrigin,
  analyticoSession,
  storageStatePath,
] = process.argv.slice(2);

if (
  !mode ||
  !cloudioOrigin ||
  !dashboardOrigin ||
  !analyticoSession ||
  !storageStatePath
) {
  throw new Error(
    "usage: node e2e-m8-cloudio-browser.cjs <mode> <cloudio-origin> " +
      "<dashboard-origin> <analytico-session> <storage-state>",
  );
}

async function launch() {
  const options = {
    headless: true,
    args: [
      "--no-sandbox",
      "--ozone-platform=headless",
      "--use-angle=swiftshader-webgl",
    ],
  };
  if (process.env.ANALYTICO_CHROMIUM_PATH) {
    options.executablePath = process.env.ANALYTICO_CHROMIUM_PATH;
  }
  return chromium.launch(options);
}

async function setup(browser) {
  const setupUrl = process.argv[7];
  assert.ok(setupUrl, "setup mode requires the one-use setup URL");
  const context = await browser.newContext();
  try {
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
    let response = await page.goto(setupUrl, { waitUntil: "load" });
    assert.equal(response.status(), 200);
    response = await Promise.all([
      page.waitForURL(`${cloudioOrigin}/security.html`),
      page.locator("#setup-button").click(),
    ]).then(() => page.waitForLoadState("load").then(() => page));
    assert.equal(page.url(), `${cloudioOrigin}/security.html`);
    assert.equal(await page.locator("#app-shell").count(), 1);
    await context.storageState({ path: storageStatePath });
  } finally {
    await context.close();
  }
}

async function noJavaScriptContext(browser) {
  const context = await browser.newContext({
    javaScriptEnabled: false,
    storageState: storageStatePath,
  });
  await context.addCookies([
    {
      name: "analytico_session",
      value: analyticoSession,
      url: dashboardOrigin,
      httpOnly: true,
      sameSite: "Lax",
    },
  ]);
  return context;
}

async function connected(browser) {
  const context = await noJavaScriptContext(browser);
  try {
    const page = await context.newPage();
    const firstViewRequests = [];
    page.on("request", (request) => firstViewRequests.push(request.url()));
    let response = await page.goto(`${cloudioOrigin}/`, { waitUntil: "load" });
    assert.equal(response.status(), 200);
    assert.equal(await page.locator("#page-title").textContent(), "Dashboard");
    assert.equal(await page.evaluate(() => typeof window.htmx), "undefined");
    const link = page.locator('nav a[rel="external"]', { hasText: "Analytics" });
    assert.equal(await link.count(), 1);
    const expectedPrefix = `${dashboardOrigin}/admin?`;
    assert.ok((await link.getAttribute("href")).startsWith(expectedPrefix));
    assert.equal(
      firstViewRequests.filter((url) => url.startsWith(dashboardOrigin)).length,
      0,
    );
    const cloudioResponseStartMs = await page.evaluate(
      () => performance.getEntriesByType("navigation")[0].responseStart,
    );

    response = await Promise.all([
      page.waitForNavigation({ waitUntil: "load" }),
      link.click(),
    ]).then(([navigation]) => navigation);
    assert.equal(response.status(), 200);
    assert.equal(await page.locator("h1").textContent(), "Analytico");
    assert.equal(
      await page.locator(".metrics li", { hasText: "Page views" }).locator("strong").textContent(),
      "8",
    );
    const analyticoResponseStartMs = await page.evaluate(
      () => performance.getEntriesByType("navigation")[0].responseStart,
    );
    const pagesLink = page.locator('a[href*="report=pages"]').first();
    assert.equal(await pagesLink.count(), 1);
    response = await Promise.all([
      page.waitForNavigation({ waitUntil: "load" }),
      pagesLink.click(),
    ]).then(([navigation]) => navigation);
    assert.equal(response.status(), 200);
    assert.match(page.url(), /report=pages/);

    process.stdout.write(
      JSON.stringify({
        mode: "connected",
        javascript: "disabled",
        cloudio_first_response_ms: Math.round(cloudioResponseStartMs * 10) / 10,
        analytico_first_response_ms:
          Math.round(analyticoResponseStartMs * 10) / 10,
        cloudio_startup_analytico_requests: 0,
        navigation: "ordinary-link",
        dashboard_auth: "passkey-session",
      }) + "\n",
    );
  } finally {
    await context.close();
  }
}

async function cloudioOnly(browser) {
  const context = await noJavaScriptContext(browser);
  try {
    const page = await context.newPage();
    const requests = [];
    page.on("request", (request) => requests.push(request.url()));
    const response = await page.goto(`${cloudioOrigin}/`, { waitUntil: "load" });
    assert.equal(response.status(), 200);
    assert.equal(await page.locator("#page-title").textContent(), "Dashboard");
    assert.equal(
      await page.locator('nav a[rel="external"]', { hasText: "Analytics" }).count(),
      1,
    );
    assert.equal(
      requests.filter((url) => url.startsWith(dashboardOrigin)).length,
      0,
    );
    process.stdout.write(
      JSON.stringify({
        mode: "analytico-unavailable",
        cloudio_status: 200,
        cloudio_response: "complete",
        upstream_requests: 0,
      }) + "\n",
    );
  } finally {
    await context.close();
  }
}

async function rollback(browser) {
  const context = await noJavaScriptContext(browser);
  try {
    const page = await context.newPage();
    let response = await page.goto(`${cloudioOrigin}/`, { waitUntil: "load" });
    assert.equal(response.status(), 200);
    assert.equal(
      await page.locator('nav a[rel="external"]', { hasText: "Analytics" }).count(),
      0,
    );
    response = await page.goto(
      `${dashboardOrigin}/admin?site=example&start=2025-01-01&end=2025-01-02&report=overview`,
      { waitUntil: "load" },
    );
    assert.equal(response.status(), 200);
    assert.equal(await page.locator("h1").textContent(), "Analytico");
    process.stdout.write(
      JSON.stringify({
        mode: "rollback",
        cloudio_link: "removed",
        analytico_standalone_status: 200,
      }) + "\n",
    );
  } finally {
    await context.close();
  }
}

async function main() {
  const browser = await launch();
  try {
    switch (mode) {
      case "setup":
        await setup(browser);
        break;
      case "connected":
        await connected(browser);
        break;
      case "cloudio-only":
        await cloudioOnly(browser);
        break;
      case "rollback":
        await rollback(browser);
        break;
      default:
        throw new Error(`unknown mode: ${mode}`);
    }
  } finally {
    await browser.close();
  }
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
