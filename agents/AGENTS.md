# Agent instructions — NMS-Release

> A community-release **EQEmu-derived EverQuest server** (C++ server, Perl/Lua quests, `dinput8.dll`
> client add-on, PowerShell deploy scripts). **Canonical read order:** `README.md` →
> `Release-NMS-Deploy/CODEBASE.md`. CODEBASE.md wins over any per-folder README when they conflict.

Read these before any work:

1. [`README.md`](../README.md) — what is in each folder, quick start, requirements
2. [`Release-NMS-Deploy/CODEBASE.md`](../Release-NMS-Deploy/CODEBASE.md) — the thesis (stock EQEmu +
   a `RULE_CATEGORY(Custom)` layer), migration system, client contract, gotchas index
3. [`Release-NMS-Deploy/custom-rules/README.md`](../Release-NMS-Deploy/custom-rules/README.md) — generated
   lookup index of every `Custom` rule (type, compiled default, related rules, header note), clustered by
   subsystem. `clusters.json` in that folder is the only hand-edited file; regenerate with
   `python Release-NMS-Deploy/custom-rules/generate.py` and run it with `--check` before committing
   any change to the Custom block of `ruletypes.h`
4. The per-folder README for whichever of Server / Client / Quests / Plugins you are touching

## Layout of this folder

Everything agent- or tooling-related lives here; nothing else at the repo root is for agents.

| Path | What it is |
| --- | --- |
| `agents/AGENTS.md` | This file. Root `CLAUDE.md` is a one-line `@agents/AGENTS.md` import — edit here, not there. |
| `agents/skills/` | Project skills (`diagnose`, `verify-this`). Source of truth; `.claude/` is local and gitignored. |

No git hooks, no setup scripts, no editor config: the maintainer uses Claude only, and nothing in
this folder needs Node or any other runtime. The rules below are followed by hand and by the agent.

## Operating model

Delegate grunt work (broad searches, mechanical edits) to subagents rather than burning context on
it; keep the final review and gate yourself.

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
- **Never** paste DB passwords or connection strings into chat or tracked files.
- Before every commit, check `git diff --cached` for credentials, connection strings, and tokens.

## Push hygiene — no identifiable information leaves this machine

This is a public community repo. Nothing pushed here — file contents, commit messages, PR titles
and bodies, issue comments, branch names — may carry: personal first/last names, personal email
addresses, user-profile paths (`C:\Users\<name>`, `/home/<name>`), machine names, or the names of
the maintainers' other private projects or clients. Attribute tooling generically ("the sibling
repo", "a local install", "the reviewer") and use `users.noreply.github.com` addresses.

- Not enforced by tooling: before every commit, PR body, or issue comment, the agent reads what it
  is about to publish (added lines, the message, the title) for names, emails, and profile paths.
- Commit identity: the author name may be a GitHub handle, but the email must be that account's
  `users.noreply.github.com` address, never a personal one (`git config user.email`).
- Merges made in the GitHub web UI are authored with the account's public email unless the GitHub
  setting **Keep my email addresses private** (and **Block command line pushes that expose my
  email**) is on. Turn both on at github.com/settings/emails before merging a PR through the
  browser; a merge commit that exposed a personal email is only removable by rewriting history.
- After cloning on a new machine: set `git config user.email` to your GitHub noreply address.

## Lessons (self-maintained)

**Process:** whenever the user corrects me, or I catch myself making a mistake, I append a one-line
rule here (with a short _why_) **before continuing** — so it never recurs. Keep each to one line;
newest at the bottom.

- The bare `bin/` rule in `.gitignore` matches at every depth — it silently dropped every runtime
  DLL from the vendored vcpkg tree, so the tree looked shipped but was unusable. Check what a
  broad ignore rule actually excludes (`git check-ignore -v`) before trusting a "vendored" folder.
- A commit message and a PR body on this public repo named a private sibling project, and the agent
  instructions carried a first name and a private toolkit path — nobody was checking prose, only
  secrets. Read every commit message and PR body for names and private project references before publishing.
- A delegated worker committed a `__pycache__/*.pyc` because it ran the generator before staging the
  folder. Review `git diff --cached --stat` for build artifacts before every commit, not just secrets.
- I changed the welcome popup's "maximum available expansion is Kunark" line while opening later
  expansions; the repo owner pointed out it describes a NEW account's default reach, not the server
  max. Player-facing copy encodes intent that is not in the code: leave it alone unless the change
  request names it, and ask the owner when a string looks stale.
- A PII scan that read whole staged files refused the first edit to a stock upstream header carrying
  an old contact address. Judge what a change adds, not what a file already held.
- I proposed a Perl design with 60 s polling and per-spawn rule lookups for Fabled spawns because
  "plugins first" is the convention — the maintainer wants performance-first architecture. For
  anything on a per-entity path, design push-based C++ state (world pushes, zone caches, O(1) hook)
  and offer Perl only for the flavour layer; convention never outranks load on the server.
- Agent/tooling files were scattered across root dotfiles (`.claude`, `.claudeignore`, `.githooks`,
  `.mcp.json`, plus config for an editor the maintainer does not use) and the clutter was noise.
  Everything agent-related lives in `agents/`; hidden dirs are local, generated, and gitignored.
  The maintainer does not use Cursor — do not add Cursor config, rules, or references.
- I moved the git hooks into `agents/` and a setup script switched them on; the maintainer's first
  push then failed on `node: not found` — he never asked for hooks, only for the clutter to go, and
  Node is not on his machine. No hooks, no setup scripts, no runtime dependencies for tooling: the
  repo must commit and push with plain git. Ask before adding anything that runs automatically.

## Project skills

In `agents/skills/`: `verify-this` (prove a claim with baseline vs treatment evidence) and
`diagnose` (feedback-loop-first debugging, adapted for this server). Global skills that also fit
here: `prompt-review`, `verify-before-claim`, `grilling`.

## Token & context frugality

Goal: never dump noisy output or whole files into context.

- **Never dump raw command output.** If a compact-output wrapper is installed locally, wrap noisy
  builds/imports/tests with it so full output goes to a log file and only a summary prints (real
  exit code preserved). Otherwise capture full output to a file under `.logs/` and read only the
  tail or a grep of it.
- **Locate before reading:** `rg`/`git grep` first, then read only the relevant line ranges.
  Size-check big files first (`changelog.txt` is 635 KB; the DB dump zip is 55 MB).
- **Don't read** these unless a task explicitly needs it, and then only targeted line ranges:
  vendored/fetched deps (`Release-NMS-Server/submodules/`, `vcpkg/`, `dependencies/`, `libs/`);
  build output and IDE caches (`Build/`, `build/`, `bin/`, `out/`, `.vs/`, `*.obj`, `*.pdb`, `*.ilk`,
  `*.tlog`, `Release-NMS-Client/eqgame_dll/Release/`); DB dumps and bulk SQL (`*.zip`,
  `Release-NMS-Server/database/`, `Release-NMS-Server/utils/sql/`); client art and binaries
  (`Release-NMS-Client/SpellIcons/`, `ClientFiles/uifiles/`, `*.dds`, `*.tga`, images, `*.wav`,
  `*.dll`, `*.exe`, `*.lib`); logs (`Release-NMS-Server/changelog.txt`, `.logs/`, `*.log`);
  and secrets (`credentials.txt`, server-root `eqemu_config.json` / `login.json`, `.env*`) — never.
- **>3 source files** seem needed? Summarize + justify before expanding scope.
- **Thinking budget:** low for routine edits and mechanical refactors; escalate for anything touching
  the migration manifest, `rule_values`, opcodes / the client contract, or DB imports.
