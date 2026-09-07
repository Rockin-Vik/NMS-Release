---
name: diagnose
description: Disciplined diagnosis loop for hard bugs and performance regressions in the NMS server / client add-on / quests. Reproduce → minimise → hypothesise → instrument → fix → regression-test. Use when the user says "diagnose this" / "debug this", reports a bug, says something is broken/crashing/failing, or describes a performance regression.
---

<!-- Adapted from the MIT-licensed cursor-team-kit `diagnose` skill for NMS-Release. -->

# Diagnose

A discipline for hard bugs. Skip phases only when explicitly justified.

Before exploring, read `Release-NMS-Deploy/CODEBASE.md` §1, §3 and §7. The first question for any
odd behavior in this codebase is **which `Custom` rule governs it and what is it set to in
`rule_values`** — a large share of "bugs" are a rule toggled the wrong way, not a C++ defect.
`Release-NMS-Deploy/custom-rules/README.md` is the lookup index for that question: every Custom rule with
its type, compiled default, related rules and header note, clustered by subsystem.

## Phase 0 — Rule check (NMS-specific)

- [ ] Find the `Custom` rule(s) that gate the behavior in `custom-rules/README.md` (search the cluster for
      the subsystem, then read the **Related** column — rules in a group must be read together).
- [ ] Read their current value in the `rule_values` table (or the ruleset the zone loads). The
      catalog shows compiled defaults only; the DB value is what the server is actually running.
- [ ] Confirm the DB is at the expected binary version and the custom migration manifest is fully applied (CODEBASE.md §4).
- [ ] If the symptom is client-side, confirm the client is running the matching `dinput8.dll` and UI files (CODEBASE.md §5) — an opcode the client does not understand looks like a server bug.

Only once these are ruled out do you move to a code-level loop.

## Phase 1 — Build a feedback loop

**This is the skill.** If you have a fast, deterministic, agent-runnable pass/fail signal for the bug, you will find the cause. If you don't, no amount of staring at code will save you.

Ways to construct one, roughly in order:

1. **Failing unit test** in `Release-NMS-Server/tests/` at whatever seam reaches the bug.
2. **Quest-script repro**: a minimal Perl/Lua quest on a throwaway NPC that triggers the path (`#reloadquest`), asserting via `quest::debug` / log lines.
3. **GM command + log grep**: reproduce with in-game GM commands, watch `logs/` with `rtk`-wrapped `tail`/`grep` on a tagged log category.
4. **SQL differential**: snapshot the affected rows before/after (`character_data`, `inventory`, `rule_values`, …) and diff.
5. **Packet capture / opcode trace** for client-contract bugs: log the opcode and struct on both sides.
6. **Bisection harness** over commits or over `rule_values` toggles — automate "set state X, check, repeat" so `git bisect run` can drive it.
7. **Differential loop**: same action against stock EQEmu behavior vs NMS (toggle the `Custom` rule off) and diff outputs.

Iterate on the loop: faster, sharper signal, more deterministic (pin RNG where possible, isolate a single zone, fixed character).

For non-deterministic bugs, aim for a higher reproduction rate, not a clean repro: loop the trigger, add stress, narrow timing windows.

If you genuinely cannot build a loop: stop, list what you tried, and ask for a captured artifact (server log dump, crash dump, client screenshot with timestamps, DB snapshot). Do **not** hypothesise without a loop.

## Phase 2 — Reproduce

Run the loop. Confirm it produces the failure the **user** described (not a nearby one), reproducibly, and capture the exact symptom.

## Phase 3 — Hypothesise

Generate **3–5 ranked, falsifiable hypotheses** before testing any. Format: "If <X> is the cause, then <changing Y> will make the bug disappear / <Z> will make it worse." Show the ranked list to the user before testing; proceed with your ranking if they are away.

## Phase 4 — Instrument

One probe per prediction; change one variable at a time. Prefer a debugger (attach to `zone.exe` / `world.exe`) over logs; then targeted logs at the boundaries that distinguish hypotheses. **Tag every debug log** with a unique prefix such as `[DEBUG-a4f2]` so cleanup is one grep. For performance regressions, measure first (timing harness, profiler, `EXPLAIN` on the query), then bisect.

## Phase 5 — Fix + regression test

Write the regression test **before the fix** if a correct seam exists (one that exercises the real bug pattern at the call site). If no correct seam exists, that is itself a finding — note it. Then: failing test → fix → passing test → re-run the Phase 1 loop against the original scenario.

## Phase 6 — Cleanup + post-mortem

- [ ] Original repro no longer reproduces
- [ ] Regression test passes, or the absence of a seam is documented
- [ ] All `[DEBUG-...]` instrumentation removed (`git grep` the prefix)
- [ ] Throwaway quests / NPCs / SQL deleted
- [ ] The confirmed hypothesis is stated in the commit message
- [ ] If the root cause was a rule or migration gap, add a one-liner to the `agents/AGENTS.md` **Lessons** section

Then ask: what would have prevented this bug? Make that recommendation **after** the fix is in.
