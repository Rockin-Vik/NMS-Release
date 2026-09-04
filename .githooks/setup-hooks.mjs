#!/usr/bin/env node
/**
 * Fail-safe prepare hook: wire core.hooksPath when this is a git checkout.
 * No-op in CI tarballs, npm pack, or when git is unavailable.
 */
import { execSync } from "node:child_process";

try {
  execSync("git rev-parse --git-dir", { stdio: "ignore" });
  execSync("git config core.hooksPath .githooks", { stdio: "ignore" });
} catch {
  // Not a git repo or git missing — skip silently so install never fails.
}
