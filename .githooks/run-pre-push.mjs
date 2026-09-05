#!/usr/bin/env node
import fs from "node:fs";
import { auditRangeForPii, auditRefForPii, git } from "./pii-lib.mjs";

const ZERO_SHA = "0".repeat(40);

function readStdinLines() {
  const raw = fs.readFileSync(0, "utf8").trim();
  if (!raw) return [];
  return raw.split("\n").filter(Boolean);
}

function resolveRange(cwd, localSha, remoteSha) {
  if (remoteSha && remoteSha !== ZERO_SHA) {
    return `${remoteSha}..${localSha}`;
  }

  try {
    git(cwd, ["rev-parse", "--verify", "origin/main"]);
    return `origin/main..${localSha}`;
  } catch {
    return localSha;
  }
}

const cwd = process.cwd();
const lines = readStdinLines();

for (const line of lines) {
  const parts = line.trim().split(/\s+/);
  if (parts.length < 4) continue;

  const localSha = parts[1];
  const remoteSha = parts[3];
  const range = resolveRange(cwd, localSha, remoteSha);

  const failure = range.includes("..")
    ? auditRangeForPii(cwd, range)
    : auditRefForPii(cwd, range);

  if (failure) {
    console.error(
      `pre-push: blocked — ${failure.kind} in ${failure.label}: ${failure.hit}`,
    );
    console.error(
      "pre-push: remove personal names, emails, profile paths, or private project names before pushing.",
    );
    process.exit(1);
  }
}
