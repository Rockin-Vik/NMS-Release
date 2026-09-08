# AA reuse timer ids: a bounded per-character pool, allocated at the table send

Status: **v4, decided by the in-game spike (2026-09-08); built on branch `aa-timer-ids`, adversarial review of the code and the in-game pass (§3) still owed.** First item under the hero class-switching decision (local ADR-0002). v1 to v3 were reviewed adversarially (a twelve-agent pass and a delta pass); the spike on draft PR 18 answered the four client questions below and this version replaces the two allocation options of v3 with the one the answers allow.

## 0. Spike answers (owner, test server, branch `spike-aa-timer-ids`)

Method: for every probe, mapping rows cleared, the row set, camp and log in, the `[aaspike] send` log line checked for the number that actually reached the client, then the ability used against a positive control (a known-good number dimming its own icon on the same character in the same session). An early "254 works" reading was withdrawn once the control showed a total failure and a clean pass look alike when only *other* buttons are watched.

1. **Range: 0 to 99.** Numbers 7, 25, 50, 75, 85, 95 and 99 dim the ability's own icon for its own recast with a hover countdown and nothing else. **100, 255 and 256 give no client cooldown display at all**: the icon never dims, it does not dim with the index-0 group either, and the server still enforces the cooldown and reports it in chat on a repeat click. A rejected number is discarded, not wrapped or truncated. The live allocator was seen handing out **124, 138 and 145** to the test hero; those abilities are the "button never greys" report.
2. **Update channel: a full table re-send works without a zone.** `SendClearPlayerAA` plus `SendAlternateAdvancementTable` (what `#reload aa_data` does per client) makes the client take a new number for a rank it already holds; a single-rank re-send is ignored. A row changed without a table re-send or a re-log leaves server and client out of step: the server keys the cooldown on the new number while the client still holds the old registration.
3. **Index 0 is a real shared timer.** With every timed ability sent as 0, using Consume Item dimmed every owned timed ability at once. Each dims for **its own** recast (Consume Item cleared at 5 s while the others held), so the client keeps the start time per index and the duration per ability.
4. **Cooldowns are keyed by the number, not the rank.** Buying the next rank while on cooldown keeps the cooldown.

## 1. Problem

A hero with three or four classes logs `[SetDynamicAATimer] WARNING: Out-of-Range AA Timer ID [100..145]` on zone-in and when a class is added, and every ability whose id landed at 100 or above has a server-enforced cooldown with no client display.

`Custom:UseDynamicAATimers` (on since the multiclass work) gives each timed AA its own shared-timer number instead of the stock `aa_ranks.spell_type`, because two classes' unrelated abilities can carry the same stock number and would otherwise lock each other out. The number is handed out in `Client::SendAlternateAdvancementRank` (`zone/aa.cpp` ~1061-1066) for **every rank the hero can see, owned or not**, at every table send (`SendAlternateAdvancementTable` ~975-991 sends rank 1 of every unowned ability; `CanUseAlternateAdvancementRank` ~1950-2091 never filters by level). Ids are picked lowest-free from 1..1999 (`SetDynamicAATimer` ~1284) and persisted in `character_dynamic_aa_timers`. Counted from the stock dump with `Release-NMS-Deploy/research/aa_timer_census.py`:

| Held classes | Timed abilities the table send allocates for today (no level filter) | Of those, ownable at level 70 |
| --- | --- | --- |
| SHD / MNK / BER | 121 | 50 |
| SHD / MNK / BER / BRD | 151 | 60 |
| CLR / SHD / MNK / BER | 170 | 68 |
| WAR / PAL / DRU / MNK | 193 | 80 |
| NEC / WIZ / MAG / ENC | 235 | 112 |

So the send path passes 99 for any three-class hero. Allocating only for **owned** abilities keeps every combination but one under the ceiling; the exception is handled in §2.

### 1.1 Other defects in the same code (all confirmed in the tree)

- **Reset paths use the stock number.** `ResetAlternateAdvancementTimer` (~1338-1343) ignores its argument, resolves the rank from `casting_spell_aa_id` and clears `rank->spell_type + pTimerAAStart`, so an interrupt or `/stopcast` (`spells.cpp` ~1465, ~1548) clears the wrong slot, and `#resetaa_timer <id>` (`gm_commands/resetaa_timer.cpp` ~43), which passes a timer id into the same function, is a no-op unless a cast is in flight. `ResetOnDeathAlternateAdvancement` (~1387) does the same for every `reset_on_death` ability.
- **The timer packet is composed in `spells.cpp`.** `SpellFinished` sends `OP_AAAction` with a second `GetDynamicAATimer` lookup (`spells.cpp` ~3104-3107).
- **Index 99 is on the wire.** `SendAlternateAdvancementRank` overwrites `spell_type = 99` for Situational Awareness (~1114-1116) after the dynamic block, and four stock timed abilities (699, 739, 744, 16001) carry 99 in the dump. Situational Awareness is grant-only with no recast and no spell, so it never starts a timer; 99 is simply never handed out.
- **Zone-in order.** `p_timers.Load` runs in `Handle_Connect_OP_ZoneEntry` (`client_packet.cpp` ~1790). Timers are sent from `SendZoneInPackets` (`client.cpp` ~917) and again from `Handle_Connect_OP_SendAAStats` (`client_packet.cpp` ~1243) if the client answers the invitation at ~1193; the table goes in `CompleteConnect` (~1074) and `Handle_Connect_OP_SendAATable` (~1252). Timers precede the table on every path, so a leftover row above 99 is broadcast as `ability = 100+` before any table-send repair could run.
- **Expired timers stay in memory** (`ptimer.cpp` ~200-210; `Load` drops them ~306-309) and `SendAlternateAdvancementTimers` walks the list with no expiry check (~1181-1189).
- **The table has a second unique key**, `UNIQUE (character_id, timer_id)` (`database_update_manifest_custom.cpp` ~260-267); the insert-failed branch (~1301-1308) reads back by `aa_id` and returns 0 on a `timer_id` collision.
- **"Cache empty" means "not loaded"** (~1270).
- **Removal wipes every cooldown; no reset path touches the table.** `ClearDynamicAATimers` (~1329-1335) resets all AA cooldowns and deletes every row; its only caller is `RemoveExtraClass` (`client.cpp` ~15121). `ResetAA` (~548-575) and its six callers leave the mapping rows in place.
- **The off switch leaks.** The table send always reads the mapping table (~976), and running dynamic timers are still broadcast after the rule is turned off; dynamic id N and stock `spell_type` N are the same persistent-timer type `1000 + N` (`ptimer.h` ~70).
- **`#reload aa_data` exists** (`entity.cpp` ~5689-5701): per client `SendClearPlayerAA`, then the full table, stats and points. It is the channel answer 2 proved.

## 2. Decision

- **D1 — Pool.** Per character, dynamic ids are **1..98**. 99 stays reserved (Situational Awareness on the wire). 0 is the **unassigned and overflow** index: every rank sent without an id carries 0.
- **D2 — Allocate at the table send, for owned timed abilities only.** `SendAlternateAdvancementRank` gives an id to a rank only when the character owns the ability (`GetAA(first_rank_id) > 0`), the ability is timed (first rank `recast_time > 0`) and not grant-only. Unowned ranks are sent with `spell_type = 0`. An unowned ability cannot be activated, so its button dimming with the index-0 group (answer 3) costs nothing. This alone takes the live hero from 151 allocations to 60.
- **D3 — Purchase of a timed ability's first rank allocates and re-sends the table.** In `FinishAlternateAdvancementPurchase`, when the purchased rank is rank 1 of a timed, non-grant ability and the character has no id for it: allocate, then `SendClearPlayerAA()` and `SendAlternateAdvancementTable()` (answer 2's channel) before the stock next-rank send. Later ranks change nothing (answer 4). Auto-grant goes through the same function and gets the same treatment.
- **D4 — Held and free.** An id is **held** while its mapping row exists **and** (the ability is owned by a held class **or** its persistent timer has not expired, `p_timers.Expired(&database, type, false)` false). A dropped class's abilities therefore keep their ids until their cooldowns end, then release them; re-adding the class allocates again at the table send. **Recycle order**, lowest free id first: `p_timers.Clear(&database, pTimerAAStart + id)` → `SendAlternateAdvancementTimer(id, 0, now)` to the client → delete the old row → insert the new row → update the cache. The evicted ability is not visible to the client, so nothing else is re-sent.
- **D5 — Exhaustion.** When no id is free (the only stock case is four pure casters with every timed ability at 70 bought: 112 owned against 98), the ability is sent with **0** and one log line per character per zone-in names the count. Those abilities then share a real cooldown with each other and dim with the unowned group; that is a working, bounded degradation in place of today's silent nothing. **Owner decision, default accept:** the alternatives are a per-server list of low-value timed AAs that never take an id, or a client change this add-on cannot make (the 100-entry table is the game client's).
- **D6 — Data repair at zone entry, before any timer packet.** Right after `p_timers.Load` in `Handle_Connect_OP_ZoneEntry`: every mapping row with `timer_id > 98` has its persistent timer cleared and its row deleted, one log line per character. The ability gets a fresh id at the table send that follows. Verification asserts the count of rows above 98 is 0 after zone-in and that no zone-in `OP_AAAction` carries an ability above 98.
- **D7 — One resolver for every composer.** `ResolveAATimerIndex(rank)`: dynamic lookup with the rule on (a miss on an **owned** ability allocates and re-sends the table, the self-heal for any path that reached activation without an id), `rank->spell_type` otherwise. Used by activation including its cooldown test, `SpellFinished` (which takes the id from activation and does not look it up again), both reset paths and `ResetOnDeathAlternateAdvancement`. `ResetAlternateAdvancementTimer(int ability)` is split: `/stopcast` resolves from `casting_spell_aa_id`; `#resetaa_timer <id>` clears by index directly.
- **D8 — Unique key and cache.** An insert that fails on `(character_id, timer_id)` retries the next free id and never returns 0. The cache carries a loaded flag; empty-after-load is a valid state.
- **D9 — Removal keeps cooldowns; reset clears mappings.** `RemoveExtraClass` stops calling `ClearDynamicAATimers()` (rule 2: a cooldown started as a Monk keeps running through a switch; the other classes' cooldowns are no longer wiped). `ClearDynamicAATimers` is called from **`Client::ResetAA`** so all six reset callers clear the mapping table together with the ranks. The persistence spec's D8 edits the same function; whichever lands second rebases.
- **D10 — Off switch.** With the rule off: no allocation, no cache use, no table read from the table send. At zone entry with the rule off, if the character has mapping rows, clear the persistent timer of every mapped id, delete the rows, log one line; after that the character is fully on stock numbers. Switching the rule on a live zone still needs a re-zone; the rule's header note says so.
- **D11 — The warning goes.** `SetDynamicAATimer` becomes `AcquireDynamicAATimer(aa_id)`: lowest free id in 1..98 by D4, D8 on failure, 0 on exhaustion with the D5 log line. Nothing above 98 is ever written.

## 3. Verification (in game, the live four-class hero, catch-up on)

1. Zone in with the hero that produced the warnings. **Expect:** no `Out-of-Range` line; `SELECT COUNT(*) FROM character_dynamic_aa_timers WHERE character_id = ? AND timer_id > 98` = 0; the packet log shows no `OP_AAAction` with `ability` above 98 at any point of zone-in; `SELECT COUNT(*) ... WHERE character_id = ?` equals the number of owned timed abilities (60 for SHD/MNK/BER/BRD from the dump; the live catalog may differ).
2. Activate five owned timed abilities from three classes within a minute. **Expect:** five distinct ids in 1..98 in the table, each ability's `OP_SendAATable` carrying that id in `spell_type`, five buttons dimmed independently, no unowned button dimmed.
3. Buy the first rank of a timed ability the hero did not own. **Expect:** a new row, a `SendClearPlayerAA` and full table in the packet log before the next-rank send, the new button dimming alone on first use without a zone.
4. Camp and log back in with three cooldowns running. **Expect:** across the one or two timers packets, the `ability` values are exactly those three ids, the right buttons dimmed.
5. Die with a `reset_on_death` ability on cooldown. **Expect:** its persistent timer (`timers` type `1000 + id`) gone, every other AA timer untouched, the stock slot `1000 + rank->spell_type` untouched.
6. `/stopcast` during an AA cast: that ability's dynamic slot cleared, nothing else. `#resetaa_timer <id>` with no cast in flight: that index cleared (today a no-op).
7. Drop the Monk while a Monk ability and a Shadow Knight ability are on cooldown, re-add the Monk. **Expect:** both persistent timers still running, the Shadow Knight button still dimmed, the Monk row still present until its cooldown ends (then free), the Monk ability dimmed again after re-add once the persistence spec's reload sends timers.
8. Exhaustion, forced with SQL: 98 rows for the character on owned abilities, then buy the first rank of one more timed ability. **Expect:** it is sent with 0, one log line, it dims with the index-0 group and shares a cooldown only with other overflow abilities.
9. `Custom:UseDynamicAATimers = false`, `#reload rules global`, re-zone with a dynamic cooldown still running. **Expect:** stock `spell_type` in every `OP_SendAATable`, the mapping rows gone with one log line, no `OP_AAAction` on that zone-in whose index was in the mapping table before the switch.

Local, before any of that: `build zone` green; the adversarial handoff on the diff; the composer table in §4 checked against `git grep` and pasted into the PR body.

## 4. Files and every composer of an AA timer index

Server (`Release-NMS-Server`):

- `zone/aa.cpp`: `SendAlternateAdvancementTable` (drop the unconditional table read), `SendAlternateAdvancementRank` (owned-only allocation, 0 otherwise, 99 override kept), `GetDynamicAATimers` (loaded flag), `GetDynamicAATimer` (lookup only), `SetDynamicAATimer` → `AcquireDynamicAATimer` (D4, D5, D8, D11), new `ResolveAATimerIndex`, `FinishAlternateAdvancementPurchase` (D3), `ResetAlternateAdvancementTimer` split, `ResetOnDeathAlternateAdvancement`, `ActivateAlternateAdvancementAbility`, `ResetAA` (call `ClearDynamicAATimers`).
- `zone/client_packet.cpp` `Handle_Connect_OP_ZoneEntry` ~1790: D6 repair and the D10 rule-off clear, right after `p_timers.Load`.
- `zone/spells.cpp` ~3104-3107: the id passed in from activation.
- `zone/client.cpp` `RemoveExtraClass` ~15121: drop `ClearDynamicAATimers()`.
- `zone/gm_commands/resetaa_timer.cpp`: clear by index.
- `zone/client.h`: declarations.
- `common/ruletypes.h` `UseDynamicAATimers` note: re-zone after switching; `python Release-NMS-Deploy/custom-rules/generate.py --check` afterwards.
- `Release-NMS-Deploy/CODEBASE.md` ~125-130 (the `UseDynamicAATimers` sentence): the 1..98 pool, allocation at the table send for owned abilities, 0 for the rest.
- Rides along in the same PR: `Release-NMS-Deploy/build-scripts/Check-HeroRules.ps1` (read-only ruleset report, already on this branch), the `Check-LootOfferRules.ps1` wording fix, the `agents/AGENTS.md` lesson line, this spec and `research/aa_timer_census.py`.

| Site | Today | After |
| --- | --- | --- |
| `SendAlternateAdvancementRank` ~1061 | allocates for every visible timed rank | owned timed only; 0 otherwise; 99 kept |
| `FinishAlternateAdvancementPurchase` ~1482 | sends the next rank | allocate on a first rank + clear and full table, then the next rank |
| `ActivateAlternateAdvancementAbility` ~1608-1717 incl. the cooldown test ~1630 | lookup, allocates on miss | `ResolveAATimerIndex` (owned miss self-heals) |
| `SpellFinished` packet `spells.cpp` ~3105 | second lookup | id passed in |
| `ResetAlternateAdvancementTimer` ~1339 | **stock** | resolve from `casting_spell_aa_id` |
| `ResetOnDeathAlternateAdvancement` ~1387 | **stock** | resolve |
| `#resetaa_timer` ~43 | stock via the above | by index |
| `SendAlternateAdvancementTimers` / `ResetAlternateAdvancementTimers` | whatever is in `p_timers` | unchanged; D6 and D10 sanitise first |
| `ClearDynamicAATimers` ~1329 | from `RemoveExtraClass` only | from `ResetAA` only |

No client add-on change, no migration, no new rule.

## 5. Not in this spec

- Keeping AA ranks through a class drop (the persistence spec, draft PR 20; lands after this).
- Restoring stock intra-class shared timers (two Monk abilities that stock EverQuest locks together each get their own id here). If the owner wants them back it is a small hand-written table of groups, one id per group; not guessed from the stock numbers.
- The placeholder ranks at level 80 (ADR-0001 catalog pass).
