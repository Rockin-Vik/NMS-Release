# AA reuse timer ids: allocate on use, recycle when expired

Status: draft for review, 2026-09-08. First item under the hero class-switching decision (local ADR-0002). Not built.

## 1. Problem

A hero with three or four classes logs red lines on zone-in and again when a class is added:

```
[SetDynamicAATimer] WARNING: Out-of-Range AA Timer ID [100] assigned to character ... for AA [1277] -> Classes [32848]
... [101] ... [107]
```

Every AA whose id lands at 100 or above has no working reuse timer on the client: the button never greys after use, and the server-side cooldown (which is keyed by the same id) shares its slot with whatever the client does with an out-of-range index. The warning is the only visible symptom; the broken timers are silent.

### Why it happens

`Custom:UseDynamicAATimers` (on since the multiclass work) gives each timed AA its own shared-timer id instead of the stock `aa_ranks.spell_type`, because two classes' unrelated abilities can carry the same stock `spell_type` and would otherwise lock each other out. The id is handed out in `Client::SendAlternateAdvancementRank` (`zone/aa.cpp` ~1061), which runs for **every rank the hero can see**, owned or not, at every table send (`SendAlternateAdvancementTable`, ~975). Ids count upward from 1 (`SetDynamicAATimer`, ~1283), are persisted per character in `character_dynamic_aa_timers`, and are never released while a class is held. `ClearDynamicAATimers` (~1329) wipes the whole table only when a class is removed (`client.cpp` ~15121).

`CanUseAlternateAdvancementRank` (~1950) filters by class and category only, never by level, so the table send includes every timed AA of every held class at every level. From the stock data (`release-peq.sql`, enabled, non-grant abilities whose first rank has a recast time):

| Held classes | Timed AAs sent (ids needed today) | Distinct stock `spell_type` |
| --- | --- | --- |
| SHD / MNK / BER | 119 | 67 |
| SHD / MNK / BER / BRD (the live report) | 142 | 68 |
| CLR / SHD / MNK / BER | 165 | 71 |
| WAR / PAL / DRU / MNK | 155 | 68 |
| NEC / WIZ / MAG / ENC | 220 | 75 |
| WIZ / SHM / MAG / NEC (worst four) | 235 | 77 |

The client's shared-timer index space is 0–99: stock data never uses a `spell_type` above 99, and the existing code treats 100 as out of range. Any three-class hero is already over it; the persistence decision (keep every class's ranks) does not change these counts but removes the one thing that used to shrink them (the wipe on class removal).

Two more defects in the same code, found while reading it:

- `ResetAlternateAdvancementTimer` (~1338) and `ResetOnDeathAlternateAdvancement` (~1379) clear `rank->spell_type + pTimerAAStart`, the **stock** id, not the dynamic one. With dynamic timers on, a death clears the wrong cooldown (or none) for `reset_on_death` abilities, and the per-ability reset clears a stranger's timer.
- Twenty-four timed stock abilities have `spell_type = 0` (Holy Steed, Suspended Minion, Project Illusion, Pyromancy, ...). Under stock rules those all share timer slot 0. Dynamic ids start at 1, so today they are deconflicted; the design below keeps 0 reserved.

## 2. Decision

Timer ids are a pool of **99 slots (1–99)** per hero, **allocated on first activation** of an ability, **recycled once the cooldown has expired**, and **reported to the client by re-sending the rank** with the new id. Nothing is allocated at table send. An ability that has never been used has no id and is sent with `spell_type = 0`.

Consequences:

- The number of ids in use is bounded by the number of abilities on cooldown at the same time, not by how many the hero can see. No realistic hero runs 99 concurrent cooldowns.
- Ids survive zoning and camping exactly as today (same table, same persistent timers).
- Class removal no longer touches the table or the running cooldowns. A cooldown started as a Monk keeps running through a switch, which is what the persistence decision asks for, and a re-added class finds its ids where it left them if they have not been recycled.

### D1 — Allocation on activation

In `ActivateAlternateAdvancementAbility` (~1604), replace the lookup with `AcquireDynamicAATimer(ability_id)`:

1. If the ability already has an id in the cache/table, return it.
2. Otherwise pick the lowest id in 1–99 that no ability holds.
3. If all 99 are held, pick the id whose persistent timer (`pTimerAAStart + id`) is **expired**, lowest id first. Reassign it: delete the old row, insert the new one, update the cache, and re-send the old owner's rank with `spell_type = 0` so the client stops showing a timer for it.
4. If every held id has a running timer (99 concurrent cooldowns), take the one that expires soonest, log it at error level, and proceed. Fail open rather than refuse the activation; the log line is the tell.
5. Re-send the activating ability's rank (`SendAlternateAdvancementRank(aa_id, owned_level)`) **before** starting the timer and before the timer packet, so the client has the new `spell_type` when `OP_AAAction` arrives for it.

Packets are ordered on one stream, so the rank update lands first. This is the same rank re-send the purchase path already uses, so the client is known to accept an updated `spell_type` for an ability it already holds.

### D2 — Table send

`SendAlternateAdvancementRank` sends `spell_type = GetDynamicAATimer(aa_id)` if an id exists, else `0`. It never allocates. The `classes == 0xFFFFFFF && recast > 0 && !grant_only` condition stays as the "is this a timed AA under multiclass" test.

`GetDynamicAATimer` becomes a pure lookup (no `SetDynamicAATimer` fallback). `SetDynamicAATimer` is renamed `AcquireDynamicAATimer` with the recycling rules of D1; the `id >= 100` warning goes because the pool cannot exceed 99.

### D3 — Reset paths use the dynamic id

`ResetAlternateAdvancementTimer` and `ResetOnDeathAlternateAdvancement` resolve the id through the same lookup the activation path uses (`GetDynamicAATimer` when the rule is on, `rank->spell_type` otherwise), so a death clears the right cooldown. `ResetAlternateAdvancementTimers` (clear everything) is unchanged; it iterates the persistent timers, not the mapping.

### D4 — Class removal

`RemoveExtraClass` stops calling `ClearDynamicAATimers()`. The function stays for `#resetaa`-style GM use and is the only remaining bulk delete of the table. This is the first piece of the persistence decision to land: cooldowns and their ids are not part of what a dropped class loses.

### D5 — Rule and schema

No new rule, no schema change. `character_dynamic_aa_timers (character_id, aa_id, timer_id)` keeps its shape; the unique key on `(character_id, aa_id)` stays, and the code must tolerate a unique key on `(character_id, timer_id)` if the live table has one (recycling deletes the old row before inserting the new one, in that order).

### D6 — Off switch

`Custom:UseDynamicAATimers = false` still means stock behaviour (`rank->spell_type`, no table). Nothing here changes the off path.

## 3. Spike: confirm the client's range before building

Premise this checkout cannot prove: the client's shared-timer array holds indices 0–99. The evidence is indirect (stock data tops out at 99; the existing warning threshold is 100; the add-on's headers expose per-ability `ReuseTimer` but not the shared-timer array). One in-game test settles it and takes ten minutes:

1. On a disposable character with `Custom:UseDynamicAATimers` on, use `#` commands or a one-off debug branch to force two owned timed abilities to ids **99** and **100** in `character_dynamic_aa_timers`, then `#reloadaa` / re-zone so the table is re-sent.
2. Activate each. Expected if the premise holds: the id-99 button greys for its recast, the id-100 button does not (or greys the wrong button).
3. If **both** grey correctly, repeat at 150 and 250. The pool size in D1 becomes the highest index that works, and the table in §1 says whether 99 is still the binding limit.

Record the result at the top of this spec before the build starts.

## 4. Verification (in game, four-class hero, catch-up on)

1. Zone in with SHD / MNK / BER / BRD at 70. **Expect:** no `Out-of-Range AA Timer ID` line in the log; `character_dynamic_aa_timers` has no new rows from the zone-in.
2. Activate five timed abilities from three different classes within a minute. **Expect:** five rows, ids 1–5, five buttons greyed independently, each ungreys at its own recast.
3. Camp and log back in while three are still on cooldown. **Expect:** the three buttons still greyed with the right remaining time (`SendAlternateAdvancementTimers` on zone-in).
4. Drop the Monk while a Monk ability is on cooldown, re-add it. **Expect:** the Monk rows still there, the cooldown still running, the button greyed on return.
5. Die with a `reset_on_death` ability on cooldown. **Expect:** that ability's cooldown cleared (right timer), other cooldowns untouched.
6. Pool exhaustion, forced: set 99 rows for the character with expired timers, activate a 100th ability. **Expect:** the lowest expired id reassigned, the old owner's button no longer shows a timer, one log line, activation succeeds.
7. `Custom:UseDynamicAATimers = false`, `#reload rules global`, re-zone. **Expect:** stock `spell_type` ids in the packets, table untouched.

Local, before any of that: `build zone` green on the README toolchain; the adversarial handoff on the diff; grep that every caller of `SetDynamicAATimer` / `GetDynamicAATimer` / `ClearDynamicAATimers` is accounted for (list them in the PR body with what each became).

## 5. Files

- `Release-NMS-Server/zone/aa.cpp`: `SendAlternateAdvancementRank`, `GetDynamicAATimer`, `SetDynamicAATimer` → `AcquireDynamicAATimer`, `ResetAlternateAdvancementTimer`, `ResetOnDeathAlternateAdvancement`, `ActivateAlternateAdvancementAbility`.
- `Release-NMS-Server/zone/client.h`: the declarations above.
- `Release-NMS-Server/zone/client.cpp` `RemoveExtraClass`: drop the `ClearDynamicAATimers()` call.
- `Release-NMS-Deploy/CODEBASE.md` line ~126: one sentence on when ids are allocated.
- No client add-on change, no migration, no rule change.

## 6. Not in this spec

- Keeping AA ranks through a class drop and removing the level check on using an owned rank (the persistence spec).
- The placeholder ranks at level 80 (ADR-0001 catalog pass).
- Berserker timed abilities: the stock dump has none flagged for class 16 under the `1 << class` mask convention (the common "all classes" mask 65535 stops at bit 15). Noted for the catalog pass; not a timer problem.
