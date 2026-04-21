import express from "express";
import { config } from "./config.js";
import { isValidAllowedIp32, isValidKeepalive, isValidWgPublicKey } from "./validators.js";
import { wgInterfaceUp, wgRemovePeer, wgSetPeer, wgShow } from "./wg.js";
import { registerToBackend } from "./register.js";

const app = express();

// Honor X-Forwarded-For so req.ip reflects client behind reverse proxy / CDN.
// Required for the per-IP rate limiter on /v1/ping.
app.set("trust proxy", true);

// -----------------------------------------------------------------------------
// Public probe endpoint (no auth, no DB, no wg call).
// Kept BEFORE the auth middleware so consumers can measure RTT without a token.
// Response payload is intentionally small (~80 bytes) to minimise amplification.
// -----------------------------------------------------------------------------
const pingWindowMs = 60_000;
const pingMaxPerWindow = 120;
const pingBucket = new Map();
setInterval(() => {
  const cutoff = Date.now() - pingWindowMs;
  for (const [ip, entry] of pingBucket.entries()) {
    if (entry.windowStart < cutoff) pingBucket.delete(ip);
  }
}, pingWindowMs).unref();

function pingRateLimit(req, res, next) {
  const ip = req.ip || "unknown";
  const now = Date.now();
  let entry = pingBucket.get(ip);
  if (!entry || now - entry.windowStart >= pingWindowMs) {
    entry = { count: 0, windowStart: now };
    pingBucket.set(ip, entry);
  }
  entry.count += 1;
  if (entry.count > pingMaxPerWindow) {
    res.setHeader("Retry-After", "60");
    return res.status(429).json({ error: "rate limited" });
  }
  next();
}

app.get("/v1/ping", pingRateLimit, (_req, res) => {
  res.setHeader("Cache-Control", "no-store");
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.json({
    pong: true,
    ts: Date.now(),
    region: config.region || null,
  });
});

// -----------------------------------------------------------------------------
// Authenticated control-plane endpoints below
// -----------------------------------------------------------------------------
app.use(express.json({ limit: "128kb" }));

app.use((req, res, next) => {
  const token = req.header("x-agent-token");
  if (!token || token !== config.agentToken) {
    return res.status(401).json({ error: "unauthorized" });
  }
  next();
});

app.get("/v1/health", async (_req, res) => {
  const up = await wgInterfaceUp({ iface: config.wgInterface });
  res.json({ ok: true, wgInterface: config.wgInterface, wgUp: up });
});

app.get("/v1/wg", async (_req, res) => {
  const out = await wgShow({ iface: config.wgInterface });
  res.type("text/plain").send(out);
});

app.post("/v1/peers", async (req, res) => {
  const { publicKey, allowedIps, persistentKeepalive } = req.body ?? {};

  if (!isValidWgPublicKey(publicKey)) {
    return res.status(400).json({ error: "invalid publicKey" });
  }
  if (!Array.isArray(allowedIps) || allowedIps.length === 0 || allowedIps.length > 8) {
    return res.status(400).json({ error: "allowedIps must be non-empty array" });
  }
  for (const ip of allowedIps) {
    if (!isValidAllowedIp32(ip)) return res.status(400).json({ error: `invalid allowedIp: ${ip}` });
  }
  if (!isValidKeepalive(persistentKeepalive)) {
    return res.status(400).json({ error: "invalid persistentKeepalive" });
  }

  const up = await wgInterfaceUp({ iface: config.wgInterface });
  if (!up) return res.status(503).json({ error: "wg interface down" });

  try {
    await wgSetPeer({
      iface: config.wgInterface,
      publicKey,
      allowedIps,
      persistentKeepalive,
    });
    res.json({ ok: true });
  } catch (e) {
    res.status(500).json({ error: "wg set failed", detail: String(e?.message ?? e) });
  }
});

app.delete("/v1/peers/:publicKey", async (req, res) => {
  const publicKey = req.params.publicKey;
  if (!isValidWgPublicKey(publicKey)) {
    return res.status(400).json({ error: "invalid publicKey" });
  }

  const up = await wgInterfaceUp({ iface: config.wgInterface });
  if (!up) return res.status(503).json({ error: "wg interface down" });

  try {
    await wgRemovePeer({ iface: config.wgInterface, publicKey });
    res.json({ ok: true });
  } catch (e) {
    res.status(500).json({ error: "wg remove failed", detail: String(e?.message ?? e) });
  }
});

app.post("/v1/register", async (_req, res) => {
  try {
    const result = await registerToBackend(config.wgInterface);
    res.json({ ok: true, result });
  } catch (e) {
    res.status(500).json({ ok: false, error: String(e?.message ?? e) });
  }
});

app.listen(config.port, async () => {
  console.log(`Gateway Agent listening on :${config.port}`);
  try {
    const result = await registerToBackend(config.wgInterface);
    console.log("Auto-register:", result);
  } catch (e) {
    console.error("Auto-register failed:", String(e?.message ?? e));
  }
});
