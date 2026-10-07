// The HTTP server under hostile clients: stalled heads and bodies, trickled
// input, header injection attempts, and a clean shutdown mid-request.
import assert from "node:assert/strict";
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
  t.init();
  await t.serve();
  const ready = async () => {
    const response = await fetch(`http://127.0.0.1:${t.port}/readyz`, { signal: AbortSignal.timeout(500) });
    assert.equal(response.status, 200);
    assert.equal(await response.text(), "ready\n");
  };
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
    const registration = await (await fetch(`${base}/oauth/register`, { method: "POST", body: JSON.stringify({ redirect_uris: ["https://x.test/\r\nset-cookie: a=b"] }) })).json();
    assert.equal(registration.error, "invalid_redirect_uri");
    const client = await (await fetch(`${base}/oauth/register`, { method: "POST", body: JSON.stringify({ client_name: "Claude", redirect_uris: ["https://x.test/cb"] }) })).json();
    const bad = await fetch(`${base}/oauth/authorize?client_id=${client.client_id}&redirect_uri=${encodeURIComponent("https://x.test/cb")}&state=%0d%0aset-cookie:a`, { redirect: "manual" });
    assert.equal(bad.status, 303);
    assert.doesNotMatch(bad.headers.get("location"), /[\r\n]/);
    await ready();

    const { closed } = await connect();
    socket.write(`${head}\r\n{`);
    await delay(100);
    t.server.kill("SIGTERM");
    assert.equal(await bounded(t.exited, 2800, "TERM exceeded service shutdown window"), 0, t.log);
    await closed;
    assert.match(t.log, /serve_stopped/);
    const doctor = t.cli("doctor");
    assert.match(doctor, /ok schema=\d+ sites=0 page_views=0 summaries=0 events=0/);
    assert.doesNotMatch(t.log, /leaked|panic|segmentation/i);
  } finally {
    clearInterval(trickle);
    socket?.destroy();
  }
  return "stalled heads/bodies and trickled input expire; hostile requests answered; readiness recovers; TERM checkpoints cleanly";
});
