#!/usr/bin/env node
/**
 * One-shot local setup after cloning. Idempotent; safe to re-run.
 *
 *   node agents/setup.mjs
 *
 * 1. Points git at the commit guards in agents/hooks (secret + PII scans).
 * 2. Links .claude/skills -> agents/skills so Claude Code finds the project skills.
 *    (.claude/ is gitignored — agents/skills is the source of truth.)
 *
 * No-op for hooks when git is unavailable (CI tarballs, npm pack).
 */
import { execSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

try {
  execSync("git rev-parse --git-dir", { cwd: root, stdio: "ignore" });
  execSync("git config core.hooksPath agents/hooks", { cwd: root, stdio: "ignore" });
  console.log("hooks: core.hooksPath = agents/hooks");
} catch {
  console.log("hooks: not a git checkout, skipped");
}

const linkDir = path.join(root, ".claude");
const link = path.join(linkDir, "skills");
const target = path.join(root, "agents", "skills");

try {
  fs.mkdirSync(linkDir, { recursive: true });
  let st = null;
  try { st = fs.lstatSync(link); } catch {}
  if (st && st.isSymbolicLink()) {
    if (path.resolve(linkDir, fs.readlinkSync(link)) === target) {
      console.log("skills: .claude/skills already linked");
    } else {
      fs.unlinkSync(link);
      st = null;
    }
  } else if (st) {
    // A stale copy from before agents/skills existed — replace with a link.
    fs.rmSync(link, { recursive: true, force: true });
    st = null;
  }
  if (!st) {
    fs.symlinkSync(target, link, process.platform === "win32" ? "junction" : "dir");
    console.log("skills: linked .claude/skills -> agents/skills");
  }
} catch (err) {
  console.error(`skills: could not link .claude/skills (${err.message}); copying instead`);
  fs.cpSync(target, link, { recursive: true });
}
