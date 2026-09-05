#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";
import {
  auditRangeForPii,
  auditStagedForPii,
  auditTextForPii,
  findPiiInText,
} from "./pii-lib.mjs";

function usage() {
  console.error(
    "usage: node .githooks/pii-scan.mjs --staged | --text <string> | --file <path> | --range <base>..<head>",
  );
  process.exit(2);
}

function reportBlocked(where, kind, hit) {
  console.error(`pii-scan: blocked — ${kind} in ${where}: ${hit}`);
  process.exit(1);
}

function reportClean() {
  console.log("pii-scan: clean");
  process.exit(0);
}

const cwd = process.cwd();
const args = process.argv.slice(2);

if (args.length === 0) usage();

if (args[0] === "--staged") {
  const failure = auditStagedForPii(cwd);
  if (failure) {
    reportBlocked(failure.file, failure.kind, failure.hit);
  }
  reportClean();
}

if (args[0] === "--text") {
  const text = args[1];
  if (text === undefined) usage();
  const failure = auditTextForPii(text, "text");
  if (failure) reportBlocked(failure.label, failure.kind, failure.hit);
  reportClean();
}

if (args[0] === "--file") {
  const filePath = args[1];
  if (!filePath) usage();
  const abs = path.isAbsolute(filePath) ? filePath : path.join(cwd, filePath);
  const rel = path.relative(cwd, abs).replace(/\\/g, "/");
  const content = fs.readFileSync(abs, "utf8");
  // Ad-hoc files (PR bodies, drafts) may live anywhere, so only their CONTENT is
  // scanned; repo paths are still checked by --staged and --range.
  const contentHit = findPiiInText(content, { filePath: rel });
  if (contentHit) reportBlocked(rel, contentHit.kind, contentHit.masked);
  reportClean();
}

if (args[0] === "--range") {
  const range = args[1];
  if (!range) usage();
  const failure = auditRangeForPii(cwd, range);
  if (failure) reportBlocked(failure.label, failure.kind, failure.hit);
  reportClean();
}

usage();
