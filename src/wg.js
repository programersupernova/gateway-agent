import { execFile } from "node:child_process";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

export async function wgSetPeer({ iface, publicKey, allowedIps, persistentKeepalive }) {
  // Build args safely (no shell)
  const args = ["set", iface, "peer", publicKey, "allowed-ips", allowedIps.join(",")];

  if (persistentKeepalive !== undefined && persistentKeepalive > 0) {
    args.push("persistent-keepalive", String(persistentKeepalive));
  }

  await execFileAsync("wg", args, { timeout: 3000 });
}

export async function wgRemovePeer({ iface, publicKey }) {
  const args = ["set", iface, "peer", publicKey, "remove"];
  await execFileAsync("wg", args, { timeout: 3000 });
}

export async function wgShow({ iface }) {
  // `wg show wg0` output for debugging; keep simple
  const { stdout } = await execFileAsync("wg", ["show", iface], { timeout: 3000 });
  return stdout;
}

export async function wgInterfaceUp({ iface }) {
  try {
    await execFileAsync("wg", ["show", iface], { timeout: 1500 });
    return true;
  } catch {
    return false;
  }
}
