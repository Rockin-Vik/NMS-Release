# AA reuse timer ids: bounded pool, recycled ids, and a client spike that decides the allocation point

Status: **draft v2, NO-GO until the §3 spike has run.** 2026-09-08. First item under the hero class-switching decision (local ADR-0002). Not built. v1 was reviewed adversarially; every finding was checked against the tree and is folded in below.

## 1. Problem

A hero with three or four classes logs red lines on zone-in and again when a class is added:

```
[SetDynamicAATimer] WARNING: Out-of-Range AA Timer ID [100] assigned to character ... for AA [1277] -> Classes [32848]
... [101] ... [107]
```

Every AA whose id lands at 100 or above has no working reuse timer on the client: the button never greys after use. The warning is the only visible symptom; the broken timers are silent.

### 1.1 Why it happens

`Custom:UseDynamicAATimers` (on since the multiclass work) gives each timed AA its own shared-timer id instead of the stock `aa_ranks.spell_type`, because two classes' unrelated abilities can carry the same stock `spell_type` and would otherwise lock each other out. The id is handed out in `Client::SendAlternateAdvancementRank` (`zone/aa.cpp` ~1061-1066: `GetDynamicAATimer` falls through to `SetDynamicAATimer` on a miss), which runs for **every rank the hero can see**, owned or not, at every table send (`SendAlternateAdvancementTable` ~975-991 sends rank 1 of every unowned ability). `CanUseAlternateAdvancementRank` (~1950-2091) filters by class, race, deity, status, category and expansion (the last skipped under `Custom:AAIgnoreExpansionGate`), **never by level**; level is checked only at purchase (~2132). Ids are picked lowest-free from 1..1999 (`SetDynamicAATimer` ~1284, loop bound `pTimerAAEnd - pTimerAAStart`), persisted per character in `character_dynamic_aa_timers`, and released only by `ClearDynamicAATimers` (~1329), which runs on class removal (`client.cpp` ~15121) and nowhere else.

Counted from the stock dump (`release-peq.sql`: `aa_ability.enabled = 1`, `grant_only = 0`, first rank `recast_time > 0`, `aa_ability.classes & held_bits` with held bit `1 << (class_id - 1)`, which is the dump's convention; the server shifts the mask left once at load, `aa.cpp` ~2283):

| Held classes | Timed abilities the table send allocates ids for |
| --- | --- |
| SHD / MNK / BER (the live hero before its fourth class) | 121 |
| SHD / MNK / BER / BRD | 151 |
| CLR / SHD / MNK / BER | 170 |
| WAR / PAL / DRU / MNK | 193 |
| NEC / WIZ / MAG / ENC | 235 |

A reviewer recomputing from the same file reported roughly half these figures (54-55 for the three-class row). The difference is not explained by the all-class mask, shroud categories, status or race (each was checked); the query above is the one to reproduce. The design below does not depend on the exact number: any three-class hero exceeds 99 under either count, and live characters **already carry rows with `timer_id` 100-107**, so a fix that only changes future allocation leaves those buttons broken.

### 1.2 The client premise

The client's shared-timer index space is believed to be 0-99: stock data never uses a `spell_type` above 99, the existing code warns at 100, and the add-on's headers expose no shared-timer array (`EQData.h` `_ALTABILITY.ReuseTimer` is a duration, `AA_CHAR_MAX*` is the purchased list; the only sized reuse array in `CHARINFO2` is the 20-slot discipline one). Nothing in this tree proves it. §3 does.

### 1.3 Other defects in the same code (all confirmed in the tree)

- **Reset paths use the stock id.** `ResetAlternateAdvancementTimer` (~1338-1343) ignores its `ability` argument, resolves the rank from `casting_spell_aa_id`, and clears `rank->spell_type + pTimerAAStart`, so an interrupt or `/stopcast` (`spells.cpp` ~1465, ~1548) and `#resetaa_timer <id>` (`gm_commands/resetaa_timer.cpp` ~43) clear the wrong slot under dynamic timers. `ResetOnDeathAlternateAdvancement` (~1387) does the same for every `reset_on_death` ability.
- **The timer packet is composed in `spells.cpp`, not `aa.cpp`.** `SpellFinished` sends `OP_AAAction` with `GetDynamicAATimer(...)` (`spells.cpp` ~3104-3107), which today allocates on a miss and under any lookup-only change would send 0. Every site that composes an AA timer index is listed in §5.
- **Index 99 is hard-coded.** `SendAlternateAdvancementRank` overwrites `spell_type = 99` for Situational Awareness (`aa.cpp` ~1114-1116) after the dynamic block. Any pool that hands out 99 collides with it.
- **Index 0 is in use.** Twenty-four enabled, non-grant, timed stock abilities have `spell_type = 0` (Holy Steed, Suspended Minion, Project Illusion, Pyromancy, Consume Item, ...). With the rule off, activating one starts `pTimerAAStart + 0` (~1608, ~1714). Index 0 is therefore a real shared timer on the client, not a "none" value.
- **Expired timers stay in memory.** `PTimerList::Expired(db, false)` deletes the DB row and leaves the object in the list (`ptimer.cpp` ~200-210); `Load` drops expired entries (~306-309); `SendAlternateAdvancementTimers` walks the list with no expiry check (`aa.cpp` ~1181-1189) and runs on zone-in **before** the table (`client.cpp` ~917 in `SendZoneInPackets`; the table goes at `client_packet.cpp` ~1074, and the client also asks for timers at ~1243 before the table at ~1252).
- **The table has a second unique key.** `PRIMARY KEY (character_id, aa_id)` and `UNIQUE (character_id, timer_id)` (`database_update_manifest_custom.cpp` ~260-267). The insert-failed branch (~1301-1308) reads back by `aa_id`, so a collision on `timer_id` returns 0.
- **"Cache empty" means "not loaded".** `GetDynamicAATimer` reloads whenever the cache is empty (~1270), so a character with legitimately zero rows re-queries on every call.
- **Removal wipes every cooldown.** `ClearDynamicAATimers` first calls `ResetAlternateAdvancementTimers`, which clears **all** AA cooldowns and tells the client, then wipes the table: dropping the Monk today also resets Shadow Knight cooldowns. `#resetaa` (`gm_commands/resetaa.cpp` ~21 → `ResetAA` ~548) does **not** touch the table.
- **The off switch leaks.** `SendAlternateAdvancementTable` always calls `GetDynamicAATimers()` (~976), so the table is read with the rule off, and running dynamic timers (types 1001+) are still broadcast after `#reload rules global` and grey whatever stock `spell_type` shares that index.

## 2. Decision

Two parts. **2.1 is mandatory whatever the spike finds.** 2.2 is the allocation strategy and is chosen by the spike.

### 2.1 Mandatory (independent of client behaviour)

- **M1 — Pool.** Dynamic ids are 1..98. 0 is a live stock index; 99 is Situational Awareness. Both are never handed out while the rule is on, and no packet built from a dynamic lookup may carry 0.
- **M2 — Data repair, in code, no migration.** On `GetDynamicAATimers()` any row with `timer_id > 98` is treated as vacant: its persistent timer (`pTimerAAStart + timer_id`) is cleared, the row is deleted, and the ability is reassigned by the normal path when it next needs an id. Verification asserts `SELECT COUNT(*) FROM character_dynamic_aa_timers WHERE timer_id > 98` is 0 after the hero zones in.
- **M3 — Recycle order.** Reassigning an id: `p_timers.Clear(&database, pTimerAAStart + id)` → send the client a reset for that index (`SendAlternateAdvancementTimer(id, 0, now)`) → delete the old mapping row → insert the new row → update the cache. "Expired" means `p_timers.Expired(&database, type, false)` is true, never "the row exists".
- **M4 — Unique key.** An insert that fails on `(character_id, timer_id)` retries with the next free id; it never returns 0. The cache carries a loaded flag; empty-after-load is a valid state.
- **M5 — Every composer of an AA timer index resolves the same way.** One helper, `ResolveAATimerIndex(rank)`: dynamic lookup when the rule is on, `rank->spell_type` otherwise. Used by activation, `SpellFinished` (`spells.cpp` ~3105), both reset paths, and `ResetOnDeathAlternateAdvancement`. `ResetAlternateAdvancementTimer(int ability)` is split: the `/stopcast` path resolves from `casting_spell_aa_id`; `#resetaa_timer <id>` clears by timer index directly and no longer goes through the rank.
- **M6 — Removal keeps cooldowns.** `RemoveExtraClass` stops calling `ClearDynamicAATimers()`. This drops the global cooldown wipe on removal deliberately: rule 2 says nothing earned is lost, and a cooldown started as a Monk keeps running through a switch. `ClearDynamicAATimers` is wired into `#resetaa` so a GM still has one bulk reset.
- **M7 — Off switch is clean.** With the rule off: no table read (`GetDynamicAATimers` is not called from the table send), no allocation, no cache use; `SendAlternateAdvancementTimers` skips any persistent timer whose index is not a stock `spell_type` of a rank the hero owns. Switching modes on a live zone still needs a re-zone to resend the table; the spec says so in the rule's header note.
- **M8 — Shelved abilities do not hold ids forever.** An id counts as **held** only if its mapping row exists **and** (the ability is currently visible to the hero **or** its persistent timer is not expired). Rows for abilities no held class can see (which the persistence spec will create) are recyclable once their cooldown ends.

### 2.2 Allocation strategy (decided by the spike, §3)

The unknowns are (a) the client's index range, (b) whether the client updates an ability's shared-timer index when `OP_SendAATable` arrives again for a rank it already holds (the purchase path does **not** prove this: it re-sends the **next** rank, a different rank id, `aa.cpp` ~1482), and (c) what index a never-used timed ability should carry so it greys with nothing.

- **Option A — allocate on first activation** (if the spike answers "yes" to (b)). Table send carries the stored id or the unassigned sentinel from (c); `ResolveAATimerIndex` acquires an id only in `ActivateAlternateAdvancementAbility`, placed **after** every fail-closed return (passive ~1617, unowned ~1623, no charges ~1626, sneak ~1659, not standing ~1682, caster and target checks ~1699-1704) and **immediately before** `CastSpell` / `SpellFinished`, re-sending the owned rank and the owned+1 rank (the two the table send uses, ~983-990) before the timer packet. The acquired id is passed into `SpellFinished`; it does not look the id up again. Ids in use are then bounded by abilities actually activated, and M8 lets ids of abilities that fell out of view recycle.
- **Option B — allocate at table send for owned timed abilities only** (if the client ignores an in-place index change). Unowned ranks are sent with the sentinel from (c) and get their id when the purchase path re-sends them (which is a fresh rank to the client). Sizing from the dump, level cap 70, every timed ability of every held class bought: SHD/MNK/BER/BRD 60, CLR/SHD/MNK/BER 68, WAR/PAL/DRU/MNK 80, NEC/WIZ/MAG/ENC 112. The four-pure-caster case exceeds 98 only when every timed ability is owned; M8 recycling and a log line at 90 in use cover it, and the owner accepts that ceiling or not.

Either option keeps M1-M8. Option A is preferred because its bound is behavioural (concurrent use) rather than statistical (ownership).

## 3. Spike: four questions, one disposable character, before any code

Needs a disposable character with `Custom:UseDynamicAATimers` on, write access to `character_dynamic_aa_timers` on a test database (raw SQL is fine; there is no GM setter and `#resetaa_timer` only clears), and a re-zone after each edit so the table is re-sent (there is no `#reload aa` command in this tree; `SendAlternateAdvancementTable` runs on zone-in).

1. **Range.** Give two owned timed abilities `timer_id` 99 and 100, re-zone, activate each. Expected under the premise: 99 greys correctly, 100 does not or greys the wrong button. If both work, repeat at 150 and 250 and record the highest index that works. This sets M1's upper bound.
2. **In-place index update.** Give one owned, never-used timed ability no row (it is sent with index 0), re-zone, then insert a row for it with a free id and trigger a rank re-send for that same rank without a re-zone (`#reloadaa` does not exist; a debug branch or a one-off `#` command that calls `SendAlternateAdvancementRank(aa_id, owned_level)` is the smallest tool). Activate it. If **only that** button greys, the client accepts in-place updates and Option A is viable. If it does not grey, or greys every index-0 ability, Option B.
3. **Sentinel.** With several unused timed abilities sent as index 0, activate a stock `spell_type = 0` ability (Consume Item is all-class). If every index-0 button greys, 0 cannot be the sentinel; test `spell_refresh = 0` on the unassigned ranks and, failing that, the first index above the range from question 1.
4. **Keying.** Activate an ability, then buy its next rank (the purchase path sends a new rank id). If the running cooldown still shows on the new rank, the client keys timers by shared index, not by rank; if it clears, the client keys per rank and Option A must re-send after every purchase too.

Record all four answers at the top of this spec. Build nothing until they are in.

## 4. Verification (in game, four-class hero, catch-up on)

Each step names what could pass while the design is still wrong and the assertion that catches it.

1. Zone in with the live SHD/MNK/BER/BRD hero that produced the warnings. **Expect:** no `Out-of-Range` line **and** `SELECT COUNT(*) ... WHERE character_id = ? AND timer_id > 98` = 0 **and** no `OP_AAAction` in the packet log with `ability` 0 or above 98.
2. Activate five timed abilities from three classes within a minute. **Expect:** five rows with five distinct ids, the packet log shows `OP_SendAATable` for each before its `OP_AAAction`, five buttons greyed independently. "Five greys" alone is not enough: all five could be sitting on index 0.
3. Camp and log back in with three still on cooldown. **Expect:** exactly three `OP_AAAction` on zone-in, each `ability` equal to that ability's row, the right buttons greyed. Catches stale list entries re-greying the wrong button.
4. Die with a `reset_on_death` ability on cooldown. **Expect:** its persistent timer (`timers` row type `1000 + its id`) gone, every other AA timer row untouched, the stock slot `1000 + rank->spell_type` never touched.
5. `/stopcast` during an AA cast and `#resetaa_timer <id>`. **Expect:** the dynamic slot cleared, nothing else.
6. Drop the Monk while a Monk ability is on cooldown, re-add it. **Expect:** the timer row still present, the cooldown still running. Until the persistence spec lands the rank itself is refunded on drop, so this step only checks that the timer survives; it cannot check the button.
7. Pool exhaustion, forced with SQL: 98 rows for the character, all with expired persistent timers, then activate a 99th ability. **Expect:** the lowest id recycled (M3 order visible in the packet log: reset for the old index, then the rank re-send, then the new timer), one log line, activation succeeds.
8. `Custom:UseDynamicAATimers = false`, `#reload rules global`, re-zone with a dynamic cooldown still running from before the switch. **Expect:** stock `spell_type` in every `OP_SendAATable`, no `OP_AAAction` with a non-stock index, no table read in the query log.

Local, before any of that: `build zone` green on the README toolchain; the adversarial handoff on the diff; the caller list in §5 checked against `git grep` output and pasted into the PR body.

## 5. Files and every composer of an AA timer index

Server (`Release-NMS-Server`):

- `zone/aa.cpp`: `SendAlternateAdvancementTable` (drop the unconditional `GetDynamicAATimers`), `SendAlternateAdvancementRank` (no allocation; sentinel; keep the Situational Awareness 99 override), `GetDynamicAATimers` (M2 repair, loaded flag), `GetDynamicAATimer` (lookup only), `SetDynamicAATimer` → `AcquireDynamicAATimer` (M1, M3, M4, M8), new `ResolveAATimerIndex`, `ResetAlternateAdvancementTimer` split, `ResetOnDeathAlternateAdvancement`, `ActivateAlternateAdvancementAbility` (Option A placement), `SendAlternateAdvancementTimers` (M7 filter).
- `zone/spells.cpp` ~3104-3107: `SpellFinished` timer packet uses the id passed in from activation, not a second lookup.
- `zone/client.cpp` `RemoveExtraClass` ~15121: drop `ClearDynamicAATimers()`.
- `zone/gm_commands/resetaa.cpp`: call `ClearDynamicAATimers()`. `zone/gm_commands/resetaa_timer.cpp`: clear by index.
- `zone/client.h`: declarations.
- `Release-NMS-Deploy/CODEBASE.md` ~126: when ids are allocated and the 1..98 pool.
- `common/ruletypes.h` `UseDynamicAATimers` note: re-zone after switching.

Sites that compose `index + pTimerAAStart` or send an index to the client, and what each becomes:

| Site | Today | After |
| --- | --- | --- |
| `ActivateAlternateAdvancementAbility` ~1608-1717 | dynamic lookup (allocates on miss) | `ResolveAATimerIndex`, Option A acquires here |
| `SpellFinished` packet `spells.cpp` ~3105 | dynamic lookup (allocates on miss) | id passed in |
| `SpellFinished` `p_timers.Start(casting_spell_timer)` ~3117 | id passed in from activation | unchanged |
| Bard song start `spells.cpp` ~3112 | gated off under multiclass | unchanged |
| `ResetAlternateAdvancementTimer` ~1339-1343 | **stock** | resolve |
| `ResetOnDeathAlternateAdvancement` ~1387 | **stock** | resolve |
| `#resetaa_timer` ~43 | stock via the above | by index |
| `SendAlternateAdvancementTimers` / `ResetAlternateAdvancementTimers` | whatever is in `p_timers` | M7 filter |
| `SendAlternateAdvancementRank` ~1061, ~1116 | allocate; 99 override | sentinel or stored id; 99 kept, reserved |

No client add-on change, no migration, no new rule, **if** the spike confirms the range and the update channel. Otherwise the spike result says which of those becomes necessary.

## 6. Not in this spec

- Keeping AA ranks through a class drop and removing the level check on using an owned rank (the persistence spec). Step 6 above is limited by that.
- The placeholder ranks at level 80 (ADR-0001 catalog pass).
- The reviewer's alternate count. If the owner wants it settled, the query in §1.1 is the one to run against the live `aa_ability` / `aa_ranks`; the live catalog may also differ from the dump.
