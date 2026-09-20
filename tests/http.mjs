import assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import { mkdtemp, rm } from "node:fs/promises";
import { createServer, createConnection } from "node:net";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { setTimeout as delay } from "node:timers/promises";

const app = resolve(process.argv[2]);
const temporary = await mkdtemp(join(tmpdir(), "analytico-http-"));
const data = join(temporary, "data");
let server;
let exited;
let log = "";
let socket;
let trickle;

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

try {
  execFileSync(app, ["init", data], { stdio: "pipe" });
  const reservation = createServer();
  await new Promise((resolve, reject) => {
    reservation.once("error", reject);
    reservation.listen(0, "127.0.0.1", resolve);
  });
  const port = reservation.address().port;
  await new Promise((resolve) => reservation.close(resolve));
  server = spawn(app, ["serve", "--data", data, "--listen", `127.0.0.1:${port}`], { stdio: ["ignore", "ignore", "pipe"] });
  server.stderr.on("data", (bytes) => { log = (log + bytes).slice(-8192); });
  exited = new Promise((resolve, reject) => {
    server.once("error", reject);
    server.once("close", resolve);
  });
  const ready = async () => {
    const response = await fetch(`http://127.0.0.1:${port}/readyz`, { signal: AbortSignal.timeout(500) });
    assert.equal(response.status, 200);
    assert.equal(await response.text(), "ready\n");
  };
  for (let attempt = 0; ; attempt++) {
    assert.equal(server.exitCode, null, log);
    try { await ready(); break; } catch (error) {
      if (attempt === 49) throw error;
      await delay(100);
    }
  }

  const head = "POST /e HTTP/1.1\r\nHost: localhost\r\nContent-Length: 100\r\nContent-Type: text/plain\r\n";
  async function connect() {
    socket = createConnection({ host: "127.0.0.1", port });
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

  const { closed } = await connect();
  socket.write(`${head}\r\n{`);
  await delay(100);
  server.kill("SIGTERM");
  assert.equal(await bounded(exited, 2800, "TERM exceeded service shutdown window"), 0, log);
  await closed;
  assert.match(log, /serve_stopped/);
  const doctor = execFileSync(app, ["doctor", "--data", data], { encoding: "utf8" });
  assert.match(doctor, /ok schema=1 sites=0 page_views=0 summaries=0 events=0/);
  assert.doesNotMatch(log, /leaked|panic|segmentation/i);
  console.log("http: stalled heads/bodies and trickled input expire; readiness recovers; TERM checkpoints cleanly");
} finally {
  clearInterval(trickle);
  socket?.destroy();
  if (server && server.exitCode === null && server.signalCode === null) {
    server.kill("SIGKILL");
    await exited;
  }
  await rm(temporary, { recursive: true, force: true });
}
