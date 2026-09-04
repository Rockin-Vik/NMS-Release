# Claude Code — NMS-Release

> A community-release **EQEmu-derived EverQuest server** (C++ server, Perl/Lua quests, `dinput8.dll`
> client add-on, PowerShell deploy scripts). **Canonical read order:** `README.md` →
> `Release-NMS-Deploy/CODEBASE.md`. CODEBASE.md wins over any per-folder README when they conflict.

Read these before any work:

1. [`README.md`](./README.md) — what is in each folder, quick start, requirements
2. [`Release-NMS-Deploy/CODEBASE.md`](./Release-NMS-Deploy/CODEBASE.md) — the thesis (stock EQEmu +
   a `RULE_CATEGORY(Custom)` layer), migration system, client contract, gotchas index
3. [`Release-NMS-Deploy/custom-rules/README.md`](./Release-NMS-Deploy/custom-rules/README.md) — generated lookup
   index of every `Custom` rule (type, compiled default, related rules, header note), clustered by
   subsystem. `clusters.json` in that folder is the only hand-edited file; regenerate with
   `python Release-NMS-Deploy/custom-rules/generate.py` and run it with `--check` before committing
   any change to the Custom block of `ruletypes.h`
4. The per-folder README for whichever of Server / Client / Quests / Plugins you are touching

## Operating model

You are usually the **orchestrator**. Prefer `cursor-bridge` `explore` / `read_slice` / `delegate`
over burning context on grunt work; the Cursor worker has full read/edit/shell access in this repo.
Load the `dual-agent-bridge` skill for the short form (lane gate, decorrelated review, orchestrator
owns the final gate). Cursor sees the same bridge via `.cursor/mcp.json`.

**First question for any odd behavior:** *which `Custom` rule governs this, and what is it set to in
`rule_values`?* — not *where is this in the C++?* Find the rule in custom-rules/README.md first, then read
its live value from the DB (see CODEBASE.md §1 and §7).

## Build principle — done means done end-to-end

A change is done only when it works end to end (rule/schema → server → client contract → quest
scripts, all states) and the build is green on the toolchain the README names. Never weaken a
fail-closed check to move faster. When you stop at an external blocker (client files, Daybreak
assets, a live DB), say so and why.

## Secrets

- `credentials.txt`, `Release-NMS-Server/eqemu_config.json` and `Release-NMS-Server/login.json`
  (the ones the deploy script writes with real passwords) are **never** committed. The tracked
  templates under `.devcontainer/base/` and `loginserver/login_util/` are fine.
- Guards: `.githooks/pre-commit` (secret scan, wired via `core.hooksPath`) applies to every commit,
  including ones Claude makes. The `.cursor/hooks` write/prompt guards apply only inside Cursor.
- **Never** paste DB passwords or connection strings into chat or tracked files.
- **Never** use `git commit --no-verify` — it skips the pre-commit secret scan.

## Lessons (self-maintained)

**Process:** whenever the user corrects me, or I catch myself making a mistake, I append a one-line
rule here (with a short _why_) **before continuing** — so it never recurs. Keep each to one line;
newest at the bottom. These apply to Cursor too.

- The bare `bin/` rule in `.gitignore` matches at every depth — it silently dropped every runtime
  DLL from the vendored vcpkg tree, so the tree looked shipped but was unusable. Check what a
  broad ignore rule actually excludes (`git check-ignore -v`) before trusting a "vendored" folder.

## Project skills

In `.claude/skills/`: `verify-this` (prove a claim with baseline vs treatment evidence) and
`diagnose` (feedback-loop-first debugging, adapted for this server). Global skills that also fit
here: `prompt-review`, `verify-before-claim`, `grilling`.

## Token & context frugality

Goal: never dump noisy output or whole files into context.

- **Never dump raw command output.** If the clarity-agent-toolkit is installed locally, wrap noisy
  builds/imports/tests with `clarity-compact.sh run --label X -- <any cmd>` (Aaron's install:
  `C:\Projects\clarity-agent-toolkit\scripts\clarity-compact.sh`); it captures full output to
  `.logs/` and prints only a compact summary (real exit code preserved). Otherwise capture full
  output to a file under `.logs/` and read only the tail or a grep of it. The
  `check|test|lint|build` subcommands are pnpm-shaped and do **not** apply here — use `run`.
- **Locate before reading:** `rg`/`git grep` first, then read only the relevant line ranges.
  Size-check big files first (`changelog.txt` is 635 KB; the DB dump zip is 55 MB).
- **Don't read** vendored/generated/binary trees — see `.claudeignore` (`submodules/`, `vcpkg/`,
  `Build/`, `*.obj`, `*.zip`, the SQL dumps, `SpellIcons/`, UI XML).
- **>3 source files** seem needed? Summarize + justify before expanding scope.
- **Thinking budget:** low for routine edits and mechanical refactors; escalate for anything touching
  the migration manifest, `rule_values`, opcodes / the client contract, or DB imports.
