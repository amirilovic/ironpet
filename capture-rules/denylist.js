// Apps and hosts lookback never stores. To change the lists, copy this file to
// "<data dir>/rules/denylist.js", edit it, and run `lookback reload`.
//
// check() gets { bundle_id, name, url, host } and returns null to allow, or
// { app: "<bundle id>" } or { host: "<host>" } to deny. A denylist rule that throws, or
// runs past its limits, denies the capture.
export const meta = { api: 1, kind: "denylist" };

// Exact bundle ids, or "*fragment" for a case-insensitive substring of the bundle id.
const APPS = [
  // Password managers.
  "com.1password.1password",
  "com.agilebits.onepassword7",
  "*1password",
  "*onepassword",
  "com.bitwarden.desktop",
  "*bitwarden",
  "com.lastpass.lastpass-electron",
  "*lastpass",
  "*dashlane",
  "*keepersecurity",
  "*keepassxc",
  "*enpass",
  "me.proton.pass.electron",
  "com.apple.keychainaccess",
  "com.apple.Passwords",
  // Sign-in, lock screen and authenticator prompts.
  "com.apple.loginwindow",
  "com.apple.SecurityAgent",
  // System permission prompts: Screen Recording, Accessibility and the like.
  "com.apple.accessibility.universalAccessAuthWarn",
  "com.apple.UserNotificationCenter",
  "com.apple.systempreferences",
  "com.okta.mobile",
  "*authy",
  // HTTP debugging proxies: raw requests carry tokens and cookies.
  "com.proxyman.NSProxy",
  "com.xk72.Charles",
];

// "example.com", ".example.com" (hosts below it) or "*.example.com" (both).
const HOSTS = [
  "*.1password.com",
  "*.bitwarden.com",
  "*.lastpass.com",
  "*.dashlane.com",
  "*.keepersecurity.com",
  "pass.proton.me",
];

export function check(target, ctx) {
  const bundle = target.bundle_id;
  const lower = bundle.toLowerCase();
  for (const entry of APPS) {
    const hit = entry.startsWith("*") ? lower.includes(entry.slice(1).toLowerCase()) : entry === bundle;
    if (hit) return { app: bundle };
  }
  if (target.host && HOSTS.some((p) => ctx.url.hostMatches(target.host, p))) {
    return { host: target.host };
  }
  return null;
}
