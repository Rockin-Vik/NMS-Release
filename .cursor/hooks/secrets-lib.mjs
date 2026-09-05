import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";

export const ALLOWED_ENV_BASENAMES = new Set([
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

export async function readHookInput() {
  const chunks = [];
  for await (const chunk of process.stdin) chunks.push(chunk);
  const raw = Buffer.concat(chunks).toString("utf8").trim();
  if (!raw) return null;
  return JSON.parse(raw);
}

export function extractShellCommand(input) {
  if (typeof input.command === "string") return input.command;
  if (
    input.tool_input &&
    typeof input.tool_input === "object" &&
    typeof input.tool_input.command === "string"
  ) {
    return input.tool_input.command;
  }
  return "";
}

export function isVendorPath(filePath) {
  if (!filePath) return false;
  const normalized = filePath.replace(/\\/g, "/");
  return VENDOR_PATH_PREFIXES.some(
    (prefix) =>
      normalized === prefix.slice(0, -1) || normalized.startsWith(prefix),
  );
}

export function isExampleEnvFile(filePath) {
  if (!filePath) return false;
  const base = path.basename(filePath.replace(/\\/g, "/"));
  if (ALLOWED_ENV_BASENAMES.has(base)) return true;
  return /\.example$/i.test(base);
}

export function isDeniedEqEmuServerRootConfig(filePath) {
  const normalized = filePath.replace(/\\/g, "/");
  if (normalized === "Release-NMS-Server/eqemu_config.json") return true;
  if (normalized === "Release-NMS-Server/login.json") return true;
  return false;
}

export function isDeniedSecretPath(filePath) {
  if (!filePath) return false;
  const normalized = filePath.replace(/\\/g, "/");
  const base = path.basename(normalized);

  if (isVendorPath(normalized)) return false;
  if (ALLOWED_ENV_BASENAMES.has(base)) return false;
  if (/^\.env(\.|$)/.test(base)) return true;
  if (/(^|\/)\.env(\.|$)/.test(normalized)) return true;
  if (/^credentials\.txt$/i.test(base)) return true;
  if (isDeniedEqEmuServerRootConfig(normalized)) return true;
  if (/\.(pem|key)$/i.test(base)) return true;
  if (/^id_rsa/i.test(base)) return true;
  return false;
}

export function findSecretInText(text, opts = {}) {
  if (!text) return null;
  const filePath = opts.filePath?.replace(/\\/g, "/") ?? "";
  if (isExampleEnvFile(filePath)) return null;
  if (isVendorPath(filePath)) return null;
  if (filePath.startsWith("docs/") || filePath.includes("/docs/")) return null;
  for (const pattern of SECRET_CONTENT_PATTERNS) {
    const match = text.match(pattern);
    if (match) return match[0].slice(0, 80);
  }
  return null;
}

export function git(cwd, args) {
  return execFileSync("git", args, {
    cwd,
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  }).trim();
}

export function listStagedPaths(cwd) {
  try {
    const out = git(cwd, [
      "diff",
      "--cached",
      "--name-only",
      "--diff-filter=ACMR",
    ]);
    return out ? out.split("\n").filter(Boolean) : [];
  } catch {
    return [];
  }
}

export function listWorkingTreeCandidates(cwd) {
  try {
    const out = git(cwd, ["status", "--porcelain", "-u", "--no-renames"]);
    if (!out) return [];
    return out
      .split("\n")
      .filter(Boolean)
      .map((line) => line.slice(3).trim())
      .filter(Boolean);
  } catch {
    return [];
  }
}

export function listPushRangePaths(cwd) {
  try {
    const upstream = git(cwd, [
      "rev-parse",
      "--abbrev-ref",
      "--symbolic-full-name",
      "@{u}",
    ]);
    const out = git(cwd, ["diff", "--name-only", `${upstream}..HEAD`]);
    return out ? out.split("\n").filter(Boolean) : [];
  } catch {
    try {
      const out = git(cwd, [
        "log",
        "--name-only",
        "--pretty=format:",
        "origin/main..HEAD",
      ]);
      return [...new Set(out.split("\n").filter(Boolean))];
    } catch {
      return listStagedPaths(cwd);
    }
  }
}

export function readStagedContent(cwd, relPath) {
  try {
    return git(cwd, ["show", `:${relPath}`]);
  } catch {
    const abs = path.join(cwd, relPath);
    if (fs.existsSync(abs)) return fs.readFileSync(abs, "utf8");
    return null;
  }
}

export function deny(reason, detail) {
  return { permission: "deny", user_message: reason, agent_message: detail };
}

export function emit(result) {
  process.stdout.write(JSON.stringify(result) + "\n");
}

export function auditPaths(cwd, paths) {
  for (const relPath of paths) {
    if (isDeniedSecretPath(relPath)) {
      return deny(
        `Blocked: "${relPath}" matches the secret denylist (credentials.txt, .env*, eqemu_config.json/login.json at server root, *.pem, *.key, id_rsa*). Use tracked templates under .devcontainer/base/ or loginserver/login_util/ for placeholders only.`,
        `Refusing git operation: denied path ${relPath}`,
      );
    }
    const content = readStagedContent(cwd, relPath);
    const hit = findSecretInText(content ?? "", { filePath: relPath });
    if (hit) {
      return deny(
        `Blocked: staged content in "${relPath}" looks like a live secret (${hit}…). Remove it before committing.`,
        `Refusing git operation: secret pattern in ${relPath}`,
      );
    }
  }
  return null;
}

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
