// The HTTP server under hostile clients: stalled heads and bodies, trickled
// input, malformed redirect state, and a clean shutdown mid-request.
import assert from "node:assert/strict";
import { request } from "node:http";
import { createConnection } from "node:net";
import { setTimeout as delay } from "node:timers/promises";
import { journey } from "./harness.mjs";

async function bounded(promise, milliseconds, label) {
  let timer;
  try {
    return await Promise.race([promise, new Promise((_, reject) => {
      timer = setTimeout(() => reject(new Error(label)), milliseconds);
    })]);
  } finally {
    clearTimeout(timer);
  }
}

await journey("http", async (t) => {
  let socket;
  let trickle;
  const setupLink = t.init(`http://127.0.0.1:${t.port}`);
  const siteOrigin = "https://hostile.example";
  const siteId = /public_id=([^ ]+)/.exec(t.cli("site", "add", "hostile", siteOrigin, "--mode", "session"))[1];
  await t.serve();
  // Nesting past what a batch ever holds is refused, and the process that
  // refused it keeps collecting (a deep value once stopped it).
  const event = (properties) => `{"v":1,"site":"${siteId}","sent_at_ms":${Date.now()},"records":[{"event_id":"${crypto.randomUUID()}","type":"event","session_id":"${crypto.randomUUID()}","page_id":"${crypto.randomUUID()}","occurred_at_ms":${Date.now()},"tracking_mode":"session","consent_mode":"analytics","tracker_version":"1","release_id":"","internal":false,"name":"nested","path":"/x","properties":${properties}}]}`;
  const collect = (body) => fetch(`http://127.0.0.1:${t.port}/e`, { method: "POST", headers: { origin: siteOrigin, "content-type": "text/plain", "x-forwarded-for": "198.51.100.7" }, body });
  assert.equal((await collect(event(`{"a":${"[".repeat(300)}${"]".repeat(300)}}`))).status, 422);
  assert.equal((await collect(event(`{"a":1}`))).status, 204);
  const ready = async () => {
    const response = await fetch(`http://127.0.0.1:${t.port}/readyz`, { signal: AbortSignal.timeout(500) });
    assert.equal(response.status, 200);
    assert.equal(await response.text(), "ready\n");
  };
  // Probes and snippet checkers that send HEAD get the GET answer's status.
  for (const path of ["/healthz", "/readyz"]) assert.equal((await fetch(`http://127.0.0.1:${t.port}${path}`, { method: "HEAD" })).status, 200, path);
  // One client (an IPv6 /64 counts as one) can't fill the table of sign-ins
  // being started for everyone else.
  const instance = `http://127.0.0.1:${t.port}`;
  const startSignIn = (ip) => fetch(`${instance}/auth/passkey/options`, { method: "POST", headers: { origin: instance, "content-type": "application/json", "x-forwarded-for": ip }, body: JSON.stringify({ purpose: "login" }) });
  for (let attempt = 0; attempt < 30; attempt++) assert.equal((await startSignIn("2001:db8:1:2::7")).status, 200, `attempt ${attempt}`);
  assert.equal((await startSignIn("2001:db8:1:2::99")).status, 429);
  assert.equal((await startSignIn("198.51.100.8")).status, 200);
  try {
    const head = "POST /e HTTP/1.1\r\nHost: localhost\r\nContent-Length: 100\r\nContent-Type: text/plain\r\n";
    async function connect() {
      socket = createConnection({ host: "127.0.0.1", port: t.port });
      // A reset is an acceptable way to close an incomplete request.
      socket.on("error", () => {});
      const closed = new Promise((resolve) => socket.once("close", resolve));
      await bounded(new Promise((resolve, reject) => {
        socket.once("connect", resolve);
        socket.once("error", reject);
      }), 1000, "fixture connection failed");
      return { closed };
    }

    // A legitimate fragmented request must still receive a complete response.
    {
      const { closed } = await connect();
      let response = "";
      socket.on("data", (bytes) => { response += bytes; });
      socket.write("GET /rea");
      await delay(100);
      socket.write("dyz HTTP/1.1\r\nHost: localhost\r\n");
      await delay(100);
      socket.write("\r\n");
      await bounded(closed, 1000, "fragmented request failed");
      assert.match(response, /^HTTP\/1\.1 200 /);
      assert.ok(response.endsWith("\r\n\r\nready\n"));
    }

    for (const kind of ["head", "body", "trickle"]) {
      const { closed } = await connect();
      const started = performance.now();
      socket.write(kind === "body" ? `${head}\r\n{` : head);
      if (kind === "trickle") {
        await delay(1200);
        socket.write("\r\n{");
        trickle = setInterval(() => socket.write(" "), 100);
      }
      await bounded(closed, 2800 - (performance.now() - started), `${kind}: connection deadline exceeded`);
      clearInterval(trickle);
      await ready();
    }

    // Hostile but cheap requests get an answer, never a crash.
    const base = `http://127.0.0.1:${t.port}`;
    assert.equal((await fetch(`${base}/`, { method: "POST", headers: { origin: "http://evil.test" } })).status, 401);
    const client = await (await fetch(`${base}/oauth/register`, { method: "POST", body: JSON.stringify({ client_name: "Claude", redirect_uris: ["https://x.test/cb"] }) })).json();
    const bad = await fetch(`${base}/oauth/authorize?client_id=${client.client_id}&redirect_uri=${encodeURIComponent("https://x.test/cb")}&state=%0d%0ainvalid`, { redirect: "manual" });
    assert.equal(bad.status, 303);
    assert.doesNotMatch(bad.headers.get("location"), /[\r\n]/);
    await ready();

    // An oversized account form is refused without putting its link in logs.
    const setupPath = new URL(setupLink).pathname;
    const refused = await new Promise((resolve, reject) => {
      const upload = request(`${base}${setupPath}`, { method: "POST", headers: { origin: base, expect: "100-continue", "content-length": 2 * 1024 * 1024 + 1 } }, (response) => {
        response.resume();
        response.once("end", () => resolve(response.statusCode));
      });
      upload.once("error", reject);
      upload.once("continue", () => upload.destroy(new Error("oversized form must be refused before upload")));
      upload.flushHeaders();
    });
    assert.equal(refused, 413);
    assert.ok(!t.log.includes(setupPath.split("/").at(-1)));
    await ready();

    const { closed } = await connect();
    socket.write(`${head}\r\n{`);
    await delay(100);
    t.server.kill("SIGTERM");
    assert.equal(await bounded(t.exited, 2800, "TERM exceeded service shutdown window"), 0, t.log);
    await closed;
    assert.match(t.log, /serve_stopped/);
    const doctor = t.cli("doctor");
    // The one site and the one event accepted after the refused batch above.
    assert.match(doctor, /ok schema=\d+ sites=1 page_views=0 summaries=0 events=1 /);
    assert.doesNotMatch(t.log, /leaked|panic|segmentation/i);
  } finally {
    clearInterval(trickle);
    socket?.destroy();
  }
  return "stalled heads/bodies and trickled input expire; hostile requests answered; readiness recovers; TERM checkpoints cleanly";
});
