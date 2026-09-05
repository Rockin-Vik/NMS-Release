#!/usr/bin/env node
import {
  auditPaths,
  emit,
  extractShellCommand,
  listPushRangePaths,
  listStagedPaths,
  listWorkingTreeCandidates,
  readHookInput,
} from "./secrets-lib.mjs";

function parseGitAddPaths(command) {
  const tokens = command.trim().split(/\s+/);
  const paths = [];
  let isAdd = false;
  for (const token of tokens) {
    if (token === "git") continue;
    if (token === "add") {
      isAdd = true;
      continue;
    }
    if (!isAdd) continue;
    if (token.startsWith("-")) continue;
    paths.push(token.replace(/^["']|["']$/g, ""));
  }
  return { paths };
}

function isBroadAdd(command) {
  return (
    /\bgit\s+add\b/.test(command) && /\s(-A|--all|\.|\*)\s*$/.test(command)
  );
}

function isGitSecretOperation(command) {
  return /\bgit\s+(add|commit|push)\b/.test(command);
}

async function main() {
  let input;
  try {
    input = await readHookInput();
  } catch (err) {
    emit({
      permission: "deny",
      user_message: "Git secrets guard could not parse hook input.",
      agent_message: String(err),
    });
    process.exit(2);
    return;
  }
  if (!input) {
    emit({ permission: "allow" });
    return;
  }

  const command = extractShellCommand(input);
  const cwd =
    (typeof input.cwd === "string" && input.cwd) ||
    (Array.isArray(input.workspace_roots) &&
    typeof input.workspace_roots[0] === "string"
      ? input.workspace_roots[0]
      : process.cwd());

  if (!isGitSecretOperation(command)) {
    emit({ permission: "allow" });
    return;
  }

  let pathsToCheck = [];
  if (/\bgit\s+commit\b/.test(command)) pathsToCheck = listStagedPaths(cwd);
  else if (/\bgit\s+push\b/.test(command))
    pathsToCheck = listPushRangePaths(cwd);
  else if (/\bgit\s+add\b/.test(command)) {
    const { paths } = parseGitAddPaths(command);
    pathsToCheck =
      isBroadAdd(command) || paths.length === 0
        ? listWorkingTreeCandidates(cwd)
        : paths;
  }

  const failure = auditPaths(cwd, pathsToCheck);
  if (failure) {
    emit(failure);
    process.exit(2);
    return;
  }
  emit({ permission: "allow" });
}

main().catch((err) => {
  emit({
    permission: "deny",
    user_message: "Git secrets guard failed unexpectedly.",
    agent_message: String(err),
  });
  process.exit(2);
});
