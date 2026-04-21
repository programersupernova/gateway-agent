import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { config } from "./config.js";

const execFileAsync = promisify(execFile);

async function getPublicIp() {
  // simple; you can replace by metadata service in AWS/GCP
  const res = await fetch("https://api.ipify.org?format=json", { method: "GET" });
  if (!res.ok) throw new Error(`ipify failed: ${res.status}`);
  const data = await res.json();
  return data.ip;
}

async function getServerWgPublicKey(iface) {
  // For server public key: use wg pubkey < /etc/wireguard/privatekey
  // But MVP: assume server private key stored at /etc/wireguard/server.key
  // If you store elsewhere, adjust.
  const { stdout } = await execFileAsync("wg", ["show", iface, "public-key"], { timeout: 1500 });
  // NOTE: `wg show wg0 public-key` works on recent wireguard-tools. If not, use wg pubkey < file.
  return stdout.trim();
}

export async function registerToBackend(iface) {
  if (!config.backendUrl || !config.bootstrapToken) {
    return { skipped: true, reason: "BACKEND_URL or BOOTSTRAP_TOKEN missing" };
  }
  if (!config.region || !config.vpnCidr || !config.agentBaseUrl) {
    return { skipped: true, reason: "REGION/VPN_CIDR/AGENT_BASE_URL missing" };
  }

  const publicHost = await getPublicIp();
  const wgPublicKey = await getServerWgPublicKey(iface);

  const payload = {
    region: config.region,
    publicHost,
    wgPort: config.wgPort,
    wgPublicKey,
    vpnCidr: config.vpnCidr,
    agentBaseUrl: config.agentBaseUrl
  };

  const url = `${config.backendUrl.replace(/\/+$/, "")}/v1/servers/register`;
  const res = await fetch(url, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "authorization": `Bearer ${config.bootstrapToken}`
    },
    body: JSON.stringify(payload)
  });

  if (!res.ok) {
    const text = await res.text().catch(() => "");
    throw new Error(`register failed: ${res.status} ${text}`);
  }

  return { ok: true, publicHost, wgPublicKey };
}
