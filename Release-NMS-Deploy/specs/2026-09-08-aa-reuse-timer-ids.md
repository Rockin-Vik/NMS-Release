# AA reuse timer ids: bounded pool, recycled ids, and a client spike that decides the allocation point

Status: **draft v3, NO-GO until the §3 spike has run.** 2026-09-08. First item under the hero class-switching decision (local ADR-0002). Not built. v1 and v2 were each reviewed adversarially (v2 by a twelve-agent parallel review); every finding was checked against the tree and is folded in below. The count dispute from v1 is settled in §1.1.

## 1. Problem

A hero with three or four classes logs red lines on zone-in and again when a class is added:

```
[SetDynamicAATimer] WARNING: Out-of-Range AA Timer ID [100] assigned to character ... for AA [1277] -> Classes [32848]
... [101] ... [107]
```

Every AA whose id lands at 100 or above has no working reuse timer on the client: the button never greys after use. The warning is the only visible symptom; the broken timers are silent.

### 1.1 Why it happens

`Custom:UseDynamicAATimers` (on since the multiclass work) gives each timed AA its own shared-timer id instead of the stock `aa_ranks.spell_type`, because two classes' unrelated abilities can carry the same stock `spell_type` and would otherwise lock each other out. The id is handed out in `Client::SendAlternateAdvancementRank` (`zone/aa.cpp` ~1061-1066: `GetDynamicAATimer` falls through to `SetDynamicAATimer` on a miss), which runs for **every rank the hero can see**, owned or not, at every table send (`SendAlternateAdvancementTable` ~975-991 sends rank 1 of every unowned ability). `CanUseAlternateAdvancementRank` (~1950-2091) filters by class, race, deity, status, category and expansion (the last skipped under `Custom:AAIgnoreExpansionGate`), **never by level**; level is checked only at purchase (~2132). Ids are picked lowest-free from 1..1999 (`SetDynamicAATimer` ~1284, loop bound `pTimerAAEnd - pTimerAAStart`), persisted per character in `character_dynamic_aa_timers`, and released only by `ClearDynamicAATimers` (~1329), which runs on class removal (`client.cpp` ~15121) and nowhere else.

Two counts matter, and they answer different questions. Both come from the stock dump (`release-peq.sql`: `aa_ability.enabled = 1`, `grant_only = 0`, first rank `recast_time > 0`, `aa_ability.classes & held_bits` with held bit `1 << (class_id - 1)`, the dump's convention; the server shifts the mask left once at load, `aa.cpp` ~2283) via `Release-NMS-Deploy/research/aa_timer_census.py`. Status, race, deity and the shroud categories change nothing: every timed row has status 0, all races, all deities and category -1, 7 or 9. The load-time remaps at `aa.cpp` ~2297-2311 (Silent Casting 500/316 moved to a caster mask; 494, 144, 285, 9301 given an empty class mask) take one or two rows off some combinations; the remapped figure is in brackets.

| Held classes | Timed abilities the **table send** allocates ids for (no level filter) | Of those, **ownable at level 70** (first rank `level_req <= 70`) |
| --- | --- | --- |
| SHD / MNK / BER (the live hero before its fourth class; the warning's mask 32848 is exactly this three-class set) | 121 (120) | 50 (49) |
| SHD / MNK / BER / BRD | 151 (150) | 60 (59) |
| CLR / SHD / MNK / BER | 170 (169) | 68 |
| WAR / PAL / DRU / MNK | 193 (191) | 80 (79) |
| NEC / WIZ / MAG / ENC | 235 | 112 |

The v1 reviewer's "54-55" was the second column's filter, not a second reading of the first. So: **the send path overflows 99 for any three-class hero** (that is what the live warning shows, and AA 1277 in it is a level-80 rank that no hero can own), while **the owned-at-70 path overflows only for the four-pure-caster case**. Live characters already carry rows with `timer_id` 100-107, so a fix that only changes future allocation leaves those buttons broken. Precondition for every number: the live catalog may differ from the dump, and the counts assume `Custom:AAIgnoreExpansionGate` is on (read from `rule_values` before quoting them for the live server).

### 1.2 The client premise

The client's shared-timer index space is believed to be 0-99: stock data never uses a `spell_type` above 99, the existing code warns at 100, and the add-on's headers expose no shared-timer array (`EQData.h` `_ALTABILITY.ReuseTimer` is a duration, `AA_CHAR_MAX*` is the purchased list; the only sized reuse array in `CHARINFO2` is the 20-slot discipline one). Nothing in this tree proves it. §3 does.

### 1.3 Other defects in the same code (all confirmed in the tree)

- **Reset paths use the stock id.** `ResetAlternateAdvancementTimer` (~1338-1343) ignores its `ability` argument, resolves the rank from `casting_spell_aa_id`, and clears `rank->spell_type + pTimerAAStart`, so an interrupt or `/stopcast` (`spells.cpp` ~1465, ~1548) clears the wrong slot under dynamic timers, and `#resetaa_timer <id>` (`gm_commands/resetaa_timer.cpp` ~43), which passes a typed timer id into that same function, is a no-op unless a cast is in flight. `ResetOnDeathAlternateAdvancement` (~1387) does the same for every `reset_on_death` ability.
- **The timer packet is composed in `spells.cpp`, not `aa.cpp`.** `SpellFinished` sends `OP_AAAction` with `GetDynamicAATimer(...)` (`spells.cpp` ~3104-3107), which today allocates on a miss and under any lookup-only change would send 0. Every site that composes an AA timer index is listed in §5.
- **Index 99 is on the wire.** `SendAlternateAdvancementRank` overwrites `spell_type = 99` for Situational Awareness (`aa.cpp` ~1114-1116) after the dynamic block, and four stock timed abilities (699, 739, 744, 16001) carry `spell_type = 99` in the dump. Situational Awareness itself never starts a timer: it is grant-only with `recast_time` 0 and `spell = -1` on every rank, so activation returns at the `IsValidSpell` test (~1600) before any lookup. 99 is therefore a shared index the client already knows, not a slot this code ever races; it is simply never handed out.
- **Index 0 is in use.** Twenty-four enabled, non-grant, timed stock abilities have `spell_type = 0` (Consume Item 17785, Holy Steed, Suspended Minion, Project Illusion, Pyromancy, ...). With the rule off, activating one starts `pTimerAAStart + 0` (~1608, ~1714). Index 0 is therefore a real shared timer on the client, not a "none" value. With the rule on, the only ways type 1000 starts today are a cooldown begun before the rule was switched on, or `SetDynamicAATimer` returning 0 on a failed insert (~1305, ~1325) and activation then starting timer 0 (~1714).
- **The cooldown test is a fail-closed return too.** Activation (`ActivateAlternateAdvancementAbility` ~1588-1719) runs: rank / ability / `IsValidSpell` / `CanUse` (~1589-1604) → **the dynamic lookup** (~1608-1612) → passive (~1617) → not owned (~1623) → no charges (~1626) → **`!p_timers.Expired(spell_type + pTimerAAStart)` (~1630)** → sneak (~1659) → not standing (~1683) → caster and target checks (~1699-1703) → `SpellFinished` (~1706) or `CastSpell` (~1717). Any lookup-only change that returns 0 on a miss feeds index 0 into the cooldown test at 1630.
- **Expired timers stay in memory.** `PTimerList::Expired(db, false)` deletes the DB row and leaves the object in the list (`ptimer.cpp` ~200-210); `Load` drops expired entries (~306-309); `SendAlternateAdvancementTimers` walks the list with no expiry check (`aa.cpp` ~1181-1189).
- **Zone-in order.** `p_timers.Load` runs in `Handle_Connect_OP_ZoneEntry` (`client_packet.cpp` ~1790). Timers are sent from `SendZoneInPackets` (`client.cpp` ~917, always) and again from `Handle_Connect_OP_SendAAStats` (`client_packet.cpp` ~1243) if the client answers the `OP_SendAAStats` invitation the server queues at ~1193 ("Live does this"). The table goes out in `CompleteConnect` (~1074) and again in `Handle_Connect_OP_SendAATable` (~1252). Timers precede the table on every path, and a leftover row with timer 100-107 is broadcast as `ability = 100+` before the table send's `GetDynamicAATimers()` (~976) ever runs.
- **The table has a second unique key.** `PRIMARY KEY (character_id, aa_id)` and `UNIQUE (character_id, timer_id)` (`database_update_manifest_custom.cpp` ~260-267). The insert-failed branch (~1301-1308) reads back by `aa_id`, so a collision on `timer_id` returns 0.
- **"Cache empty" means "not loaded".** `GetDynamicAATimer` reloads whenever the cache is empty (~1270), so a character with legitimately zero rows re-queries on every call.
- **Removal wipes every cooldown; no reset path touches the table.** `ClearDynamicAATimers` (~1329-1335) first calls `ResetAlternateAdvancementTimers`, which clears **all** AA cooldowns and tells the client, then deletes every mapping row: dropping the Monk today also resets Shadow Knight cooldowns. Its only caller is `RemoveExtraClass`. `ResetAA` (~548-575: `SendClearPlayerAA`, `RefundAA`, `memset`, `DeleteCharacterAAs`) never touches timers or mappings, and neither does any of its six callers (`#resetaa`, `Handle_OP_ResetAA`, the two Perl and two Lua exports; through Perl, the Vision of Ayonae and the Endless Quiver script).
- **The off switch leaks.** `SendAlternateAdvancementTable` always calls `GetDynamicAATimers()` (~976), so the table is read with the rule off, and running dynamic timers (types 1001+) are still broadcast after `#reload rules global` and grey whatever stock `spell_type` shares that index. Dynamic id N and stock `spell_type` N are the **same** persistent-timer type `1000 + N` (`ptimer.h` ~70), so nothing in `p_timers` can tell the two apart.
- **`#reload aa_data` exists** (`server_reload_types.h` ~11, `reload.cpp` ~41-44, `worldserver.cpp` ~4556, `entity.cpp` ~5689-5701): per client it reloads the catalog, sends `SendClearPlayerAA`, then the full table, stats and points. It is a clear-and-rebuild channel without a re-zone, not an in-place single-rank update.

## 2. Decision

Two parts. **2.1 is mandatory whatever the spike finds.** 2.2 is the allocation strategy and is chosen by the spike.

### 2.1 Mandatory (independent of client behaviour)

- **M1 — Pool.** Dynamic ids are 1..98. 0 is a live stock index; 99 is on the wire for Situational Awareness and four stock abilities. Neither is handed out while the rule is on, and no packet built from a dynamic lookup may carry 0: a lookup miss is "no id", never index 0, and the cooldown test at ~1630 treats a miss as ready.
- **M2 — Data repair, in code, no migration, before any timer is sent.** Immediately after `p_timers.Load` in `Handle_Connect_OP_ZoneEntry` (`client_packet.cpp` ~1790), and before `SendZoneInPackets`, any mapping row with `timer_id > 98` is repaired: its persistent timer (`pTimerAAStart + timer_id`) is cleared, the row is deleted, and the ability gets a fresh id by the normal path when it next needs one. Doing this inside the table send (as v2 said) is too late, because the timers packet already went out with `ability = 100+`. **Owner decision, default clear:** a cooldown running on an overflow id is dropped rather than migrated; those buttons never greyed anyway, and migration (clear old type, start the new type with the remaining time) is more code for a one-time repair of at most eight rows. Verification asserts `SELECT COUNT(*) FROM character_dynamic_aa_timers WHERE timer_id > 98` is 0 after the hero zones in and that no `OP_AAAction` on zone-in carried an ability above 98.
- **M3 — Recycle order.** Reassigning an id: `p_timers.Clear(&database, pTimerAAStart + id)` → send the client a reset for that index (`SendAlternateAdvancementTimer(id, 0, now)`) → delete the old mapping row → re-send the evicted ability's owned rank (and owned+1) with the unassigned sentinel so the client no longer keys it on that index → insert the new row → update the cache. "Expired" means `p_timers.Expired(&database, type, false)` is true, never "the row exists".
- **M4 — Unique key.** An insert that fails on `(character_id, timer_id)` retries with the next free id; it never returns 0. The cache carries a loaded flag; empty-after-load is a valid state.
- **M5 — Every composer of an AA timer index resolves the same way.** One helper, `ResolveAATimerIndex(rank)`: dynamic lookup when the rule is on (miss = no id), `rank->spell_type` otherwise. Used by activation (including the cooldown test at ~1630), `SpellFinished` (`spells.cpp` ~3105, which receives the id from activation and does not look it up again), both reset paths, and `ResetOnDeathAlternateAdvancement`. `ResetAlternateAdvancementTimer(int ability)` is split: the `/stopcast` path resolves from `casting_spell_aa_id`; `#resetaa_timer <id>` clears by timer index directly and no longer goes through the rank.
- **M6 — Removal keeps cooldowns; reset clears mappings.** `RemoveExtraClass` stops calling `ClearDynamicAATimers()`. This drops the global cooldown wipe on removal deliberately: rule 2 says nothing earned is lost, and a cooldown started as a Monk keeps running through a switch (the local decision record's fix-direction line was corrected to match). `ClearDynamicAATimers` is called from **`Client::ResetAA` itself** (`aa.cpp` ~548), so all six reset callers, the Ayonae player reset included, clear the mapping table together with the ranks; wiring it into the `#resetaa` command alone (v2) would have left the player paths with stale rows that M8 can never recycle while the abilities stay visible. **Owner decision on the shelved class's ids, default (ii):** (i) free a dropped class's ids on removal, (ii) keep them until each cooldown expires and then recycle (M8), (iii) keep them until the class is re-added. (ii) is the only one that keeps a running cooldown and still bounds the pool.
- **M7 — Off switch is clean.** With the rule off: no allocation, no cache use, no `GetDynamicAATimers` from the table send. Because a leftover dynamic type is indistinguishable from a stock one in `p_timers`, the switch-off path needs **one** table read: at zone-in with the rule off, if the character has mapping rows, clear the persistent timer of every mapped id, delete the rows, log one line. After that the character is fully on stock ids. Switching modes on a live zone still needs a re-zone to resend the table; the spec says so in the rule's header note.
- **M8 — Shelved and idle abilities do not hold ids forever.** An id counts as **held** only while its mapping row exists **and** its persistent timer is not expired. Visibility does not hold an id: under Option A an idle ability's id may be recycled and the ability acquires a fresh one at its next activation (M3 re-sends its rank with the sentinel when it is evicted); under Option B, owned visible ranks are re-sent with the sentinel on eviction and re-acquire at the next table send. The persistence spec's evicted ranks keep their rows only until their cooldown ends. Shared sentence, used verbatim in that spec: *an ability's timer id is held while its row exists and its cooldown has not expired; after expiry the id is free; a re-added or re-activated ability gets a new id by this spec's allocation path.*

### 2.2 Allocation strategy (decided by the spike, §3)

The unknowns are (a) the client's index range, (b) whether the client updates an ability's shared-timer index when `OP_SendAATable` arrives again for a rank it already holds (the purchase path does **not** prove this: it re-sends the **next** rank, a different rank id, `aa.cpp` ~1481-1483, and re-sends nothing at max rank), and (c) what index a never-used timed ability should carry so it greys with nothing.

- **Option A — allocate on first activation** (if the spike answers "yes" to (b)). Table send carries the stored id or the unassigned sentinel from (c); `ResolveAATimerIndex` acquires an id only in `ActivateAlternateAdvancementAbility`, placed **after** every fail-closed return (passive ~1617, unowned ~1623, no charges ~1626, **the cooldown test ~1630 run on the stored id with miss = ready**, sneak ~1659, not standing ~1683, caster and target checks ~1699-1703) and **immediately before** `CastSpell` / `SpellFinished`, re-sending the owned rank and the owned+1 rank (the two the table send uses, ~983-990) before the timer packet. The acquired id is passed into `SpellFinished`. Ids in use are then bounded by **concurrent cooldowns**: an ability whose cooldown has ended releases its id under M8, so 99 lifetime activations do not exhaust the pool, only 99 simultaneous ones would, and the recycle in M3 handles that.
- **Option B — allocate at table send for owned timed abilities only** (if the client ignores an in-place index change). Unowned ranks are sent with the sentinel. Sizing from the dump, level cap 70, every timed ability of every held class bought: SHD/MNK/BER/BRD 60, CLR/SHD/MNK/BER 68, WAR/PAL/DRU/MNK 80, NEC/WIZ/MAG/ENC 112. The four-pure-caster case exceeds 98 when every timed ability is owned, and **M8 does not help there**: every owned rank of a held class is visible and would be re-acquired at the next table send. Option B therefore needs the owner to accept that ceiling (a log line at 90 in use; the last abilities bought get no reuse timer) or is dead for that combination. Option B also has to change the purchase path: the purchased rank is not re-sent today (~1482), so under this option purchase must re-send it, and if the client ignores in-place updates that means `SendClearPlayerAA` plus the full table on every purchase, which is what `#reload aa_data` already does per client.

Either option keeps M1-M8. Option A is preferred because its bound is behavioural (concurrent use) rather than statistical (ownership).

## 3. Spike: four questions, one disposable character, one throwaway debug build, before any production code

**The spike cannot run on the tree as it is.** The table send allocates an id for every visible rank on every re-zone (`aa.cpp` ~1063-1065), so "delete the row and re-zone" re-creates it, and Consume Item gets a dynamic id like everything else, so no question about index 0 can be asked with the rule on. The spike therefore needs a **throwaway debug branch** (never merged; the production change is written afterwards from the answers) with exactly three edits:

1. `SendAlternateAdvancementRank`: lookup only, the sentinel under test on a miss (no `SetDynamicAATimer` call).
2. One `#` command that re-sends a single rank in place: `#aaresend <aa_id> [index]` calling `SendAlternateAdvancementRank(aa_id, owned_level)` with an optional forced `spell_type`.
3. Activation uses the stored id and, on a miss, the same sentinel (so question 3 can start a timer on it).

Plus a disposable character with `Custom:UseDynamicAATimers` on, write access to `character_dynamic_aa_timers` on a test database (raw SQL; there is no setter), and the four re-send channels named so the answer records which one was used: **camp and log in**, **zone to zone**, **`#reload aa_data`** (clear-and-rebuild of the whole table, no re-zone), **`#aaresend`** (one rank in place).

1. **Range.** Give two owned timed abilities rows with `timer_id` 98 and 100 (not 99: it is on the wire for five stock abilities), re-zone, activate each. Expected under the premise: 98 greys correctly, 100 does not or greys the wrong button. If both work, repeat at 150 and 250 and record the highest index that works. This sets M1's upper bound. This question runs on the current tree too (a row that exists is not reallocated).
2. **In-place index update.** With the debug build: give one owned, never-used timed ability no row (it is sent with the sentinel), zone in, insert a row for it with a free id, then `#aaresend` that rank without a re-zone. Activate it. If **only that** button greys, the client accepts in-place updates and Option A is viable. If it does not grey, or greys other buttons, repeat via `#reload aa_data`: if that works, Option B with the clear-and-rebuild purchase path; if neither works without a re-zone, the answer is a re-zone-only client and Option B with a re-zone note.
3. **Sentinel.** First, with the rule **off** and no debug build: activate Consume Item (stock `spell_type` 0, all-class, recast 5) and watch the other index-0 buttons (Holy Steed, Pyromancy, ... whichever the character can see). If they grey together, 0 is a real shared index and cannot be the sentinel. Then with the debug build and the rule on: send unused ranks as `spell_refresh = 0` (not timed) and check a never-used button neither greys nor blocks; failing that, the first index above the range from question 1.
4. **Keying.** Activate an ability, then buy its next rank (the purchase path sends the next rank, same ability id, new rank id). If the running cooldown still shows on the new rank, the client keys timers by shared index, not by rank; if it clears, the client keys per rank and Option A must re-send after every purchase too. Runs on the current tree.

Record all four answers at the top of this spec. Build nothing for production until they are in.

## 4. Verification (in game, four-class hero, catch-up on)

Each step names what could pass while the design is still wrong and the assertion that catches it.

1. Zone in with the live SHD/MNK/BER/BRD hero that produced the warnings. **Expect:** no `Out-of-Range` line **and** `SELECT COUNT(*) ... WHERE character_id = ? AND timer_id > 98` = 0 **and** the packet log shows no `OP_AAAction` with `ability` 0 or above 98 at any point of zone-in, including the timers packets that precede the table.
2. Activate five timed abilities from three classes within a minute. **Expect:** five rows with five distinct ids in 1..98, the packet log shows an `OP_SendAATable` carrying that id in `spell_type` for each ability before its `OP_AAAction` (the zone-in table does not count: the assert is on the `spell_type` value, not on packet order), five buttons greyed independently. "Five greys" alone is not enough: all five could be sitting on the sentinel.
3. Camp and log back in with three still on cooldown. **Expect:** across the one or two timers packets the client receives (the second only if it answers `OP_SendAAStats`), the set of `ability` values is exactly those three ids, each equal to that ability's row, the right buttons greyed. Catches stale list entries re-greying the wrong button.
4. Die with a `reset_on_death` ability on cooldown. **Expect:** its persistent timer (`timers` row type `1000 + its id`) gone, every other AA timer row untouched, the stock slot `1000 + rank->spell_type` never touched.
5. Two separate tests. `/stopcast` during an AA cast: the dynamic slot of that ability cleared, nothing else. `#resetaa_timer <id>` with no cast in flight: the slot at that index cleared, nothing else (today this is a no-op, so a pass here is the M5 split working).
6. Drop the Monk while a Monk ability and a Shadow Knight ability are on cooldown, re-add the Monk. **Expect:** both timer rows still present, both persistent timers still running (`timers` table), and the Shadow Knight button still grey; today `ClearDynamicAATimers` wipes both, so the Shadow Knight cooldown surviving is the M6 proof. Until the persistence spec lands, the Monk rank itself is refunded on drop, so the Monk button cannot be checked; when it lands, its reload must call `SendAlternateAdvancementTimers()` after the table or the re-added button shows no cooldown without a re-zone.
7. Pool exhaustion, forced with SQL: 98 rows for the character, all with expired persistent timers, mixed visible and shelved abilities, then activate a 99th ability. **Expect:** the lowest id recycled in M3 order, visible in the packet log: reset for the old index, the evicted ability's rank re-sent with the sentinel, the new ability's rank re-sent with the id, then the new timer; one log line; activation succeeds.
8. `Custom:UseDynamicAATimers = false`, `#reload rules global`, re-zone with a dynamic cooldown still running from before the switch. **Expect:** stock `spell_type` in every `OP_SendAATable`; the mapping rows for the character gone and one log line; **no `OP_AAAction` at all on that zone-in whose index was in the mapping table before the switch** (a stock-looking index that happens to equal a leftover dynamic one is the failure this catches); afterwards, exactly one `SELECT` against the mapping table in the query log for that zone-in.

Local, before any of that: `build zone` green on the README toolchain; the adversarial handoff on the diff; the caller list in §5 checked against `git grep` output and pasted into the PR body.

## 5. Files and every composer of an AA timer index

Server (`Release-NMS-Server`):

- `zone/aa.cpp`: `SendAlternateAdvancementTable` (drop the unconditional `GetDynamicAATimers`), `SendAlternateAdvancementRank` (no allocation; sentinel; keep the Situational Awareness 99 override), `GetDynamicAATimers` (loaded flag), `GetDynamicAATimer` (lookup only), `SetDynamicAATimer` → `AcquireDynamicAATimer` (M1, M3, M4, M8), new `ResolveAATimerIndex`, `ResetAlternateAdvancementTimer` split, `ResetOnDeathAlternateAdvancement`, `ActivateAlternateAdvancementAbility` (cooldown test on the stored id; Option A placement), `SendAlternateAdvancementTimers` (unchanged once M2 and M7 run before it), `ResetAA` (call `ClearDynamicAATimers`).
- `zone/client_packet.cpp` `Handle_Connect_OP_ZoneEntry` ~1790: M2 repair and the M7 rule-off clear, right after `p_timers.Load`.
- `zone/spells.cpp` ~3104-3107: `SpellFinished` timer packet uses the id passed in from activation, not a second lookup.
- `zone/client.cpp` `RemoveExtraClass` ~15121: drop `ClearDynamicAATimers()`.
- `zone/gm_commands/resetaa_timer.cpp`: clear by index. `resetaa.cpp` is unchanged (it calls `ResetAA`, which now clears).
- `zone/client.h`: declarations.
- `Release-NMS-Deploy/CODEBASE.md` ~125-130 (the `UseDynamicAATimers` sentence in "Supporting rules"): when ids are allocated and the 1..98 pool. The persistence and gates specs edit other sentences of the hero section; each PR rewrites only its own.
- `common/ruletypes.h` `UseDynamicAATimers` note: re-zone after switching.
- Rides along in the same PR (no PR of its own, per the workspace rule): `Release-NMS-Deploy/build-scripts/Check-HeroRules.ps1` (read-only ruleset report, already tracked on this branch), the `Check-LootOfferRules.ps1` wording fix, and the `agents/AGENTS.md` lesson line.

Sites that compose `index + pTimerAAStart` or send an index to the client, and what each becomes:

| Site | Today | After |
| --- | --- | --- |
| `ActivateAlternateAdvancementAbility` ~1608-1717, incl. the cooldown test ~1630 | dynamic lookup (allocates on miss), 0 on failure | `ResolveAATimerIndex`; miss = ready at 1630; Option A acquires after 1703 |
| `SpellFinished` packet `spells.cpp` ~3105 | dynamic lookup (allocates on miss) | id passed in |
| `SpellFinished` `p_timers.Start(casting_spell_timer)` ~3117 | id passed in from activation | unchanged |
| Bard song start `spells.cpp` ~3112 | gated off under multiclass | unchanged |
| `ResetAlternateAdvancementTimer` ~1339-1343 | **stock** | resolve from `casting_spell_aa_id` |
| `ResetOnDeathAlternateAdvancement` ~1387 | **stock** | resolve |
| `#resetaa_timer` ~43 | stock via the above (no-op without a cast) | by index |
| `SendAlternateAdvancementTimers` / `ResetAlternateAdvancementTimers` | whatever is in `p_timers` | unchanged; M2 and M7 sanitise `p_timers` first |
| `SendAlternateAdvancementRank` ~1061, ~1116 | allocate; 99 override | sentinel or stored id; 99 kept, reserved |
| `ClearDynamicAATimers` ~1329 | called from `RemoveExtraClass` only | called from `ResetAA` only |

No client add-on change, no migration, no new rule, **if** the spike confirms the range and the update channel. Otherwise the spike result says which of those becomes necessary.

## 6. Not in this spec

- Keeping AA ranks through a class drop (the persistence spec). Step 6 above is limited by that, and that spec's reload must send timers (its D7).
- The placeholder ranks at level 80 (ADR-0001 catalog pass).
- The live catalog: the numbers in §1.1 are the dump's; if the owner wants the live figure, `aa_timer_census.py`'s filter is the query to run against the live `aa_ability` / `aa_ranks`.
