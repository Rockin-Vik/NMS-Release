#!/usr/bin/env node
import { auditStagedForPreCommit } from "../.cursor/hooks/secrets-lib.mjs";
import { auditStagedForPii } from "./pii-lib.mjs";

const cwd = process.cwd();

const secretFailure = auditStagedForPreCommit(cwd);
if (secretFailure) {
  console.error(
    `pre-commit: blocked — staged file contains secret pattern in "${secretFailure.file}": ${secretFailure.hit}…`,
  );
  console.error(
    "pre-commit: remove the secret or use tracked templates / *.example files only.",
  );
  process.exit(1);
}

const piiFailure = auditStagedForPii(cwd);
if (piiFailure) {
  console.error(
    `pre-commit: blocked — ${piiFailure.kind} in staged "${piiFailure.file}": ${piiFailure.hit}`,
  );
  console.error(
    "pre-commit: remove personal names, emails, profile paths, or private project names.",
  );
  process.exit(1);
}
