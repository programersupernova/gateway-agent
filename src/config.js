export const config = {
  port: Number(process.env.PORT ?? "8080"),
  agentToken: process.env.AGENT_TOKEN ?? "",
  wgInterface: process.env.WG_INTERFACE ?? "wg0",

  backendUrl: process.env.BACKEND_URL ?? "",
  bootstrapToken: process.env.BOOTSTRAP_TOKEN ?? "",
  region: process.env.REGION ?? "",
  vpnCidr: process.env.VPN_CIDR ?? "",
  wgPort: Number(process.env.WG_PORT ?? "51820"),
  agentBaseUrl: process.env.AGENT_BASE_URL ?? ""
};

if (!config.agentToken) {
  console.error("Missing AGENT_TOKEN");
  process.exit(1);
}
