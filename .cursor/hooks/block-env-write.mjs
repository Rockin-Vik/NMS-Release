#!/usr/bin/env node
import {
  deny,
  emit,
  findSecretInText,
  isDeniedSecretPath,
  readHookInput,
} from "./secrets-lib.mjs";

async function main() {
  let input;
  try {
    input = await readHookInput();
  } catch (err) {
    emit({
      permission: "deny",
      user_message: "Secret write guard could not parse hook input.",
      agent_message: String(err),
    });
    process.exit(2);
    return;
  }
  if (!input) {
    emit({ permission: "allow" });
    return;
  }

  const toolName = typeof input.tool_name === "string" ? input.tool_name : "";
  if (!/^Write$|^StrReplace$/i.test(toolName)) {
    emit({ permission: "allow" });
    return;
  }

  const toolInput =
    input.tool_input &&
    typeof input.tool_input === "object" &&
    !Array.isArray(input.tool_input)
      ? input.tool_input
      : {};

  const filePath =
    (typeof toolInput.path === "string" && toolInput.path) ||
    (typeof toolInput.file_path === "string" && toolInput.file_path) ||
    "";
  const contents =
    (typeof toolInput.contents === "string" && toolInput.contents) ||
    (typeof toolInput.new_string === "string" && toolInput.new_string) ||
    (typeof toolInput.content === "string" && toolInput.content) ||
    "";

  if (isDeniedSecretPath(filePath)) {
    emit(
      deny(
        `Blocked write to "${filePath}". Use tracked templates (.devcontainer/base/, loginserver/login_util/) or *.example files only.`,
        `Refusing ${toolName} to ${filePath}`,
      ),
    );
    process.exit(2);
    return;
  }

  const secretHit = findSecretInText(contents, { filePath });
  if (secretHit) {
    emit(
      deny(
        `Blocked ${toolName}: content looks like a live secret (${secretHit}…).`,
        `Secret pattern in ${toolName}`,
      ),
    );
    process.exit(2);
    return;
  }

  emit({ permission: "allow" });
}

main().catch((err) => {
  emit({
    permission: "deny",
    user_message: "Secret write guard failed unexpectedly.",
    agent_message: String(err),
  });
  process.exit(2);
});
