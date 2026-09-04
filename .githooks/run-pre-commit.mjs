#!/usr/bin/env node
import { auditStagedForPreCommit } from "../.cursor/hooks/secrets-lib.mjs";

const failure = auditStagedForPreCommit(process.cwd());
if (failure) {
  console.error(
    `pre-commit: blocked — staged file contains secret pattern in "${failure.file}": ${failure.hit}…`,
  );
  console.error(
    "pre-commit: remove the secret or use tracked templates / *.example files only.",
  );
  process.exit(1);
}
