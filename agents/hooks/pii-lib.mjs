import { execFileSync, spawnSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";

/** Paths that legitimately carry upstream author emails or personal upstream data. */
const PII_SKIP_PATH_PREFIXES = [
  "Release-NMS-Server/submodules/",
  "Release-NMS-Server/libs/",
  "Release-NMS-Server/utils/",
  "Release-NMS-Quests/",
  "Release-NMS-Client/",
];

const PII_SKIP_EXACT_PATHS = new Set([
  "Release-NMS-Server/changelog.txt",
]);

export const PII_PATTERNS = [
  {
    kind: "windows-user-profile-path",
    re: /[A-Za-z]:[\\/]+Users[\\/]+[^\\/\s"'<>|]+/,
  },
  {
    kind: "unix-home-path",
    re: /\/home\/(?!eqemu\/)[^/\s"'<>|]+\//,
  },
  {
    kind: "mac-user-path",
    re: /\/Users\/[^/\s"'<>|]+\//,
  },
  {
    kind: "email",
    re: /[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}/,
    isAllowed: (match) => {
      const lower = match.toLowerCase();
      if (lower.endsWith("@users.noreply.github.com")) return true;
      if (lower === "noreply@anthropic.com") return true;
      if (lower.endsWith("@example.com")) return true;
      return false;
    },
  },
];

export function isPiiSkippedPath(filePath) {
  if (!filePath) return false;
  const normalized = filePath.replace(/\\/g, "/");
  if (PII_SKIP_EXACT_PATHS.has(normalized)) return true;
  return PII_SKIP_PATH_PREFIXES.some(
    (prefix) =>
      normalized === prefix.slice(0, -1) || normalized.startsWith(prefix),
  );
}

export function maskHit(raw) {
  if (!raw) return "***";
  const visible = String(raw).slice(0, 2);
  return `${visible}***`;
}

export function loadLocalTerms() {
  const result = spawnSync(
    "git",
    ["config", "--global", "--get-all", "pii.term"],
    { encoding: "utf8" },
  );
  if (result.status !== 0 && !result.stdout) return [];
  return result.stdout
    .split("\n")
    .map((line) => line.trim().toLowerCase())
    .filter(Boolean);
}

let cachedTerms = null;

export function getLocalTerms() {
  if (cachedTerms === null) cachedTerms = loadLocalTerms();
  return cachedTerms;
}

export function resetLocalTermsCache() {
  cachedTerms = null;
}

export function findPiiInText(text, opts = {}) {
  if (!text) return null;
  const filePath = opts.filePath?.replace(/\\/g, "/") ?? "";
  if (filePath && isPiiSkippedPath(filePath)) return null;

  for (const { kind, re, isAllowed } of PII_PATTERNS) {
    const match = text.match(re);
    if (match) {
      const hit = match[0];
      if (typeof isAllowed === "function" && isAllowed(hit)) continue;
      return { kind, hit, masked: maskHit(hit) };
    }
  }

  const lowerText = text.toLowerCase();
  for (const term of getLocalTerms()) {
    const idx = lowerText.indexOf(term);
    if (idx !== -1) {
      return {
        kind: "local-term",
        hit: text.slice(idx, idx + term.length),
        masked: maskHit(term),
      };
    }
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

export function gitBuffer(cwd, args) {
  return execFileSync("git", args, {
    cwd,
    encoding: "buffer",
    stdio: ["ignore", "pipe", "pipe"],
  });
}

export function isBinaryBuffer(buf) {
  if (!buf || buf.length === 0) return false;
  const sample = buf.subarray(0, Math.min(buf.length, 8192));
  return sample.includes(0);
}

export function listStagedPathsZ(cwd) {
  try {
    const out = gitBuffer(cwd, [
      "diff",
      "--cached",
      "--name-only",
      "--diff-filter=ACM",
      "-z",
    ]);
    if (!out.length) return [];
    return out
      .toString("utf8")
      .split("\0")
      .filter(Boolean);
  } catch {
    return [];
  }
}

export function readStagedContent(cwd, relPath) {
  try {
    return gitBuffer(cwd, ["show", `:${relPath}`]);
  } catch {
    const abs = path.join(cwd, relPath);
    if (fs.existsSync(abs)) return fs.readFileSync(abs);
    return null;
  }
}

export function auditStagedForPii(cwd = process.cwd()) {
  for (const relPath of listStagedPathsZ(cwd)) {
    const pathHit = findPiiInText(relPath, { filePath: relPath });
    if (pathHit) {
      return { file: relPath, kind: pathHit.kind, hit: pathHit.masked };
    }

    if (isPiiSkippedPath(relPath)) continue;

    const content = readStagedContent(cwd, relPath);
    if (content === null) continue;
    if (isBinaryBuffer(content)) continue;

    const textHit = findPiiInText(content.toString("utf8"), {
      filePath: relPath,
    });
    if (textHit) {
      return { file: relPath, kind: textHit.kind, hit: textHit.masked };
    }
  }
  return null;
}

export function auditTextForPii(text, label = "text") {
  const hit = findPiiInText(text ?? "", { filePath: "" });
  if (!hit) return null;
  return { label, kind: hit.kind, hit: hit.masked };
}

export function parseCommitRange(range) {
  const trimmed = range.trim();
  if (!trimmed.includes("..")) {
    throw new Error(`invalid range (expected base..head): ${range}`);
  }
  const [base, head] = trimmed.split("..", 2);
  return { base: base.trim(), head: head.trim() };
}

export function listCommitsInRange(cwd, base, head) {
  try {
    const out = git(cwd, [
      "rev-list",
      "--reverse",
      `${base}..${head}`,
    ]);
    return out ? out.split("\n").filter(Boolean) : [];
  } catch {
    return [];
  }
}

export function readCommitMessage(cwd, sha) {
  try {
    return git(cwd, ["log", "-1", "--format=%B", sha]);
  } catch {
    return "";
  }
}

export function listChangedPathsInRange(cwd, base, head) {
  try {
    const out = git(cwd, ["diff", "--name-only", `${base}..${head}`]);
    return out ? out.split("\n").filter(Boolean) : [];
  } catch {
    return [];
  }
}

export function readBlobAtRef(cwd, ref, relPath) {
  try {
    return gitBuffer(cwd, ["show", `${ref}:${relPath}`]);
  } catch {
    return null;
  }
}

export function auditRefForPii(cwd, ref) {
  const message = readCommitMessage(cwd, ref);
  const msgHit = auditTextForPii(message, `commit message (${ref})`);
  if (msgHit) return msgHit;

  let paths = [];
  try {
    git(cwd, ["rev-parse", "--verify", `${ref}^`]);
    paths = listChangedPathsInRange(cwd, `${ref}^`, ref);
  } catch {
    try {
      const out = git(cwd, [
        "show",
        "--name-only",
        "--pretty=format:",
        ref,
      ]);
      paths = out ? out.split("\n").filter(Boolean) : [];
    } catch {
      paths = [];
    }
  }

  for (const relPath of paths) {
    const pathHit = findPiiInText(relPath, { filePath: relPath });
    if (pathHit) {
      return { label: relPath, kind: pathHit.kind, hit: pathHit.masked };
    }

    if (isPiiSkippedPath(relPath)) continue;

    const content = readBlobAtRef(cwd, ref, relPath);
    if (content === null) continue;
    if (isBinaryBuffer(content)) continue;

    const textHit = findPiiInText(content.toString("utf8"), {
      filePath: relPath,
    });
    if (textHit) {
      return { label: relPath, kind: textHit.kind, hit: textHit.masked };
    }
  }

  return null;
}

export function auditRangeForPii(cwd, range) {
  const { base, head } = parseCommitRange(range);

  for (const sha of listCommitsInRange(cwd, base, head)) {
    const message = readCommitMessage(cwd, sha);
    const hit = auditTextForPii(message, `commit message (${sha})`);
    if (hit) return hit;
  }

  for (const relPath of listChangedPathsInRange(cwd, base, head)) {
    const pathHit = findPiiInText(relPath, { filePath: relPath });
    if (pathHit) {
      return {
        label: relPath,
        kind: pathHit.kind,
        hit: pathHit.masked,
      };
    }

    if (isPiiSkippedPath(relPath)) continue;

    const content = readBlobAtRef(cwd, head, relPath);
    if (content === null) continue;
    if (isBinaryBuffer(content)) continue;

    const textHit = findPiiInText(content.toString("utf8"), {
      filePath: relPath,
    });
    if (textHit) {
      return { label: relPath, kind: textHit.kind, hit: textHit.masked };
    }
  }

  return null;
}

export function stripCommitComments(message) {
  return message
    .split("\n")
    .filter((line) => !line.startsWith("#"))
    .join("\n");
}

function parseIdentString(ident) {
  const match = ident.match(/^(.+?) <([^>]+)> /);
  if (!match) return { name: ident.trim(), email: "" };
  return { name: match[1].trim(), email: match[2].trim() };
}

function resolveIdent(cwd, role) {
  const isAuthor = role === "author";
  const envName = isAuthor
    ? process.env.GIT_AUTHOR_NAME
    : process.env.GIT_COMMITTER_NAME;
  const envEmail = isAuthor
    ? process.env.GIT_AUTHOR_EMAIL
    : process.env.GIT_COMMITTER_EMAIL;
  const varName = isAuthor ? "GIT_AUTHOR_IDENT" : "GIT_COMMITTER_IDENT";
  const parsed = parseIdentString(git(cwd, ["var", varName]));

  if (envName !== undefined || envEmail !== undefined) {
    return {
      name: envName ?? parsed.name,
      email: envEmail ?? parsed.email,
    };
  }

  return parsed;
}

function auditIdentity(name, email) {
  const trimmedName = (name ?? "").trim();
  const trimmedEmail = (email ?? "").trim();

  if (!trimmedEmail.toLowerCase().endsWith("@users.noreply.github.com")) {
    return { kind: "non-noreply-email", hit: maskHit(trimmedEmail) };
  }

  const nameHit = findPiiInText(trimmedName, { filePath: "" });
  if (nameHit) return { kind: nameHit.kind, hit: nameHit.masked };

  const emailHit = findPiiInText(trimmedEmail, { filePath: "" });
  if (emailHit) return { kind: emailHit.kind, hit: emailHit.masked };

  return null;
}

export function auditAuthorIdent(cwd = process.cwd()) {
  for (const role of ["author", "committer"]) {
    const { name, email } = resolveIdent(cwd, role);
    const failure = auditIdentity(name, email);
    if (failure) return failure;
  }
  return null;
}
