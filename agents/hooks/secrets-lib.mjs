/**
 * Secret scan used by the pre-commit hook: refuses to commit files on the secret denylist
 * (credentials.txt, .env*, server-root eqemu_config.json/login.json, keys) or staged content
 * that looks like a live password, connection string, token or private key.
 */
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";

const ALLOWED_ENV_BASENAMES = new Set([
  ".env.example",
  ".env.local.example",
  ".env.development.local.example",
]);

/** Vendored third-party trees may ship example TLS material; do not scan or deny. */
const VENDOR_PATH_PREFIXES = ["Release-NMS-Server/submodules/"];

export const SECRET_CONTENT_PATTERNS = [
  /\bmysql:\/\/[^\s'"]+:[^\s'"]+@/i,
  /"password"\s*:\s*"[A-Za-z0-9\-_=+.]{16,}"/i,
  /\$MariaDbRootPassword\s*=\s*'[A-Za-z0-9\-_=+.]{16,}'/i,
  /-MariaDbRootPassword\s+'[A-Za-z0-9\-_=+.]{16,}'/i,
  /\bPASSWORD=[A-Za-z0-9\-_=+.]{16,}\b/i,
  /\bBearer\s+eyJ[a-zA-Z0-9._\-+/=]{20,}/,
  /\b[A-Z][A-Z0-9_]{0,48}(?:KEY|SECRET|TOKEN|PASSWORD)\s*=\S['"]?[A-Za-z0-9_\-+/=]{20,}/,
  /-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----/,
];

function normalize(filePath) {
  return (filePath ?? "").replace(/\\/g, "/");
}

export function isVendorPath(filePath) {
  const n = normalize(filePath);
  if (!n) return false;
  return VENDOR_PATH_PREFIXES.some(
    (prefix) => n === prefix.slice(0, -1) || n.startsWith(prefix),
  );
}

export function isExampleEnvFile(filePath) {
  if (!filePath) return false;
  const base = path.basename(normalize(filePath));
  return ALLOWED_ENV_BASENAMES.has(base) || /\.example$/i.test(base);
}

export function isDeniedSecretPath(filePath) {
  const n = normalize(filePath);
  if (!n) return false;
  const base = path.basename(n);

  if (isVendorPath(n)) return false;
  if (ALLOWED_ENV_BASENAMES.has(base)) return false;
  if (/^\.env(\.|$)/.test(base)) return true;
  if (/(^|\/)\.env(\.|$)/.test(n)) return true;
  if (/^credentials\.txt$/i.test(base)) return true;
  if (n === "Release-NMS-Server/eqemu_config.json") return true;
  if (n === "Release-NMS-Server/login.json") return true;
  if (/\.(pem|key)$/i.test(base)) return true;
  if (/^id_rsa/i.test(base)) return true;
  return false;
}

export function findSecretInText(text, opts = {}) {
  if (!text) return null;
  const filePath = normalize(opts.filePath);
  if (isExampleEnvFile(filePath)) return null;
  if (isVendorPath(filePath)) return null;
  if (filePath.startsWith("docs/") || filePath.includes("/docs/")) return null;
  for (const pattern of SECRET_CONTENT_PATTERNS) {
    const match = text.match(pattern);
    if (match) return match[0].slice(0, 80);
  }
  return null;
}

function git(cwd, args) {
  return execFileSync("git", args, {
    cwd,
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  }).trim();
}

function listStagedPaths(cwd) {
  try {
    const out = git(cwd, ["diff", "--cached", "--name-only", "--diff-filter=ACMR"]);
    return out ? out.split("\n").filter(Boolean) : [];
  } catch {
    return [];
  }
}

function readStagedContent(cwd, relPath) {
  try {
    return git(cwd, ["show", `:${relPath}`]);
  } catch {
    const abs = path.join(cwd, relPath);
    if (fs.existsSync(abs)) return fs.readFileSync(abs, "utf8");
    return null;
  }
}

/** Returns `{ file, hit }` for the first offending staged file, or null when clean. */
export function auditStagedForPreCommit(cwd = process.cwd()) {
  for (const relPath of listStagedPaths(cwd)) {
    if (isExampleEnvFile(relPath)) continue;
    if (isDeniedSecretPath(relPath)) {
      return { file: relPath, hit: "denied path" };
    }
    const content = readStagedContent(cwd, relPath);
    const hit = findSecretInText(content ?? "", { filePath: relPath });
    if (hit) return { file: relPath, hit };
  }
  return null;
}
