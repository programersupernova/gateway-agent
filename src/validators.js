// WireGuard public key is base64 32 bytes => usually 44 chars with '=' padding
export function isValidWgPublicKey(s) {
  return typeof s === "string" && /^[A-Za-z0-9+/]{43}=$/.test(s);
}

// Only allow x.x.x.x/32 for MVP
export function isValidAllowedIp32(s) {
  if (typeof s !== "string") return false;
  const m = s.match(/^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})\/32$/);
  if (!m) return false;
  const nums = m.slice(1).map((x) => Number(x));
  return nums.every((n) => Number.isInteger(n) && n >= 0 && n <= 255);
}

export function isValidKeepalive(n) {
  if (n === undefined) return true;
  if (typeof n !== "number" || !Number.isInteger(n)) return false;
  return n >= 0 && n <= 300;
}
