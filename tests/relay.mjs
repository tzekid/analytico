// The push relay against a stand-in APNs (HTTP/2 without TLS): it signs
// Apple's provider token with the publisher's key, forwards the ciphertext
// untouched and reports devices Apple no longer knows.
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { generateKeyPairSync, verify } from "node:crypto";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { createServer } from "node:http2";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { freePort, listen } from "./harness.mjs";

const relayBinary = join(dirname(resolve(process.argv[2])), "analytico-relay");
const temporary = await mkdtemp(join(tmpdir(), "analytico-relay-"));
const { privateKey, publicKey } = generateKeyPairSync("ec", { namedCurve: "P-256" });
await writeFile(join(temporary, "AuthKey.p8"), privateKey.export({ type: "pkcs8", format: "pem" }));

const received = [];
const apple = createServer((request, response) => {
  let body = "";
  request.on("data", (chunk) => (body += chunk));
  request.on("end", () => {
    received.push({ headers: request.headers, body });
    const gone = request.headers[":path"].endsWith("/" + "de".repeat(32));
    response.writeHead(gone ? 410 : 200, { "content-type": "application/json", "apns-id": "test" });
    response.end(gone ? JSON.stringify({ reason: "Unregistered" }) : "");
  });
});
const applePort = await listen(apple);
const port = await freePort();
let log = "";
const relay = spawn(relayBinary, ["--listen", `127.0.0.1:${port}`, "--key", join(temporary, "AuthKey.p8"), "--key-id", "KEY1234567", "--team", "TEAM123456", "--topic", "ru.plosca.analytico", "--apns", `http://127.0.0.1:${applePort}`]);
relay.stderr.on("data", (chunk) => (log += chunk));

try {
  const base = `http://127.0.0.1:${port}`;
  for (let tries = 0; ; tries++) {
    if ((await fetch(`${base}/healthz`).catch(() => null))?.ok) break;
    if (tries > 50) throw new Error(`relay did not start\n${log}`);
    await new Promise((done) => setTimeout(done, 100));
  }
  const payload = Buffer.from("ciphertext only the device opens").toString("base64");
  const send = (fields) => fetch(`${base}/v1/apns`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ token: "ab".repeat(32), environment: "production", payload, ...fields }) });

  assert.equal((await send({})).status, 200);
  const [forwarded] = received;
  assert.equal(forwarded.headers[":path"], `/3/device/${"ab".repeat(32)}`);
  assert.deepEqual([forwarded.headers["apns-topic"], forwarded.headers["apns-push-type"], forwarded.headers["apns-priority"]], ["ru.plosca.analytico", "alert", "10"]);
  const jwt = forwarded.headers.authorization.replace(/^bearer /, "").split(".");
  assert.deepEqual(JSON.parse(Buffer.from(jwt[0], "base64url")), { alg: "ES256", kid: "KEY1234567" });
  const claims = JSON.parse(Buffer.from(jwt[1], "base64url"));
  assert.equal(claims.iss, "TEAM123456");
  assert.ok(Math.abs(claims.iat - Date.now() / 1000) < 60);
  assert.ok(verify("sha256", Buffer.from(`${jwt[0]}.${jwt[1]}`), { key: publicKey, dsaEncoding: "ieee-p1363" }, Buffer.from(jwt[2], "base64url")));
  const notification = JSON.parse(forwarded.body);
  assert.deepEqual([notification.aps["mutable-content"], notification.p], [1, payload]);

  // The provider token is reused rather than signed per push.
  assert.equal((await send({ environment: "development" })).status, 200);
  assert.equal(received[1].headers.authorization, forwarded.headers.authorization);

  assert.equal((await send({ token: "de".repeat(32) })).status, 410);
  assert.equal((await send({ token: "not-hex" })).status, 400);
  assert.equal((await send({ environment: "staging" })).status, 400);
  assert.equal((await send({ payload: "<script>" })).status, 400);
  assert.equal(received.length, 3);
  assert.doesNotMatch(log, new RegExp(payload.slice(0, 12)));
  console.log("relay: provider token, HTTP/2 forwarding, gone devices, validation");
} finally {
  relay.kill();
  apple.close();
  await rm(temporary, { recursive: true, force: true });
}
