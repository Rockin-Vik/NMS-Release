#!/usr/bin/env node
import fs from "node:fs";
import { auditTextForPii, stripCommitComments } from "./pii-lib.mjs";

const messagePath = process.argv[2];
if (!messagePath) {
  console.error("commit-msg: missing commit message file path");
  process.exit(2);
}

const raw = fs.readFileSync(messagePath, "utf8");
const message = stripCommitComments(raw);
const failure = auditTextForPii(message, messagePath);

if (failure) {
  console.error(
    `commit-msg: blocked — ${failure.kind} in commit message: ${failure.hit}`,
  );
  console.error(
    "commit-msg: remove personal names, emails, profile paths, or private project names.",
  );
  process.exit(1);
}
