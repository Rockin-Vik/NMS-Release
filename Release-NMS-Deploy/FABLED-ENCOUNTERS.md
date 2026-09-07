# Fabled Encounters — analysis, current state, and how to enable

> Companion to [`CODEBASE.md`](CODEBASE.md). Everything here was verified against the tree and
> the shipped DB dump (`Release-NMS-Server/database/release-peq.zip`) on 2026-09-05. Where a
> claim depends on a DB row, the query used is shown so it can be re-run against a live DB.

> **Status (2026-09-06): implemented, not yet built or play-tested.** §6 is the design as coded;
> §8 lists what is done and what remains (build on the Windows toolchain, apply the roster seed,
> run the acceptance test). §2–§3 describe the tree *before* this work and are kept as the record
> of why it was needed.

## 0. TL;DR

- The repo contained **two unrelated things called "Fabled"**. One worked, one was a stub.
- **Fabled Nagafen's Lair** (`FNagafen` progression stage, `soldungb` instance version 1) is a
  complete custom raid. It has NPCs, loot, a spawn point, scripts and a progression gate.
- **Fabled Season** used to be `Custom:EnableFabledMobs` flipping spawn condition **99** with no
  content behind it (no condition rows, no `spawn2` rows, no Fabled NPCs). That rule and the call
  are now gone.
- §6 is the design **as implemented**: a push-based C++ season state (world owns, zones cache), an
  O(1) hook in `Spawn2::Process` that promotes the normal named in place (no new `npc_types`), the
  existing Legendary item tier as "Fabled loot", and a `#fabled` GM command. Seasons start, change
  and **end with no reload or restart**.

---

## 1. Two features share the word

| | Fabled Season toggle | Fabled Nagafen's Lair |
| --- | --- | --- |
| What it is meant to be | Live-EQ-style anniversary event: named NPCs spawn as harder "The Fabled X" variants with better loot | A single custom endgame raid instance |
| Switch | `Custom:EnableFabledMobs` (BOOL, default `false`) | Progression flag `FNagafen`, sub-flag `Quarm` |
| Where wired | `common/ruletypes.h:1319`, `Release-NMS-Quests/global/global_player.pl:19-21` | `Release-NMS-Plugins/NMS_progression_utils.pl:170-204, 514, 771-774`; `Release-NMS-Quests/soldungb/player.pl` |
| Content in DB | **None** (see §3) | NPCs `1120001072/78/79/80/86`, loot `222003`, `spawn2` id `2141635` |
| Scripts | none beyond the toggle | `soldungb/The_Fabled_Lord_Nagafen.lua`, `Fabled_Magus_Rokyl.lua`, `Fabled_Fire_Giant_Warrior.lua` |
| Status | **Stub** | Working, with the loose ends in §7 |

The rest of this document is about the toggle. The raid is covered in §7 only where it matters.

---

## 2. How the toggle is wired today

### 2.1 The rule

```c
// common/ruletypes.h:1319
RULE_BOOL(Custom, EnableFabledMobs, false,
  "Enable Fabled Season globally (true to enable 100% Fabled spawns, false to disable).")
```

Present in the dump's `rule_values` as `(1,'Custom:EnableFabledMobs','false',…)` — so the live
value is the compiled default unless someone has changed it. Listed in
[`custom-rules/README.md`](custom-rules/README.md) under the same cluster as `EnableGlobalLoot`.

### 2.2 The only consumer

```perl
# Release-NMS-Quests/global/global_player.pl:18-21
sub EVENT_ENTERZONE {
    # NMS: Fabled Season Synchronization. Automatically turns on/off 100% Fabled spawns based on rule.
    my $fabled_active = quest::get_rule("Custom:EnableFabledMobs") eq "true" ? 2 : 1;
    quest::spawn_condition($zonesn, $instanceid, 99, $fabled_active);
```

Every player zone-in calls `SpawnConditionManager::SetCondition(zone, instance, 99, 2|1)`. That
is the 4-argument Perl form (`embparser_api.cpp:971`), so it is instance-aware. `get_rule` on a
BOOL returns the literal strings `"true"`/`"false"` (`common/rulesys.cpp:117-118`), so the
comparison is correct.

The intended contract is therefore: **condition 99 = 1 → normal season, 99 = 2 → Fabled
season**, and content is expected to key off those values.

### 2.3 What the C++ does with that call

`zone/spawn2.cpp`, all stock EQEmu:

- `LoadSpawnConditions` (l. 955) loads `spawn_conditions WHERE zone = ?` from the content DB,
  then overlays `spawn_condition_values WHERE zone = ? AND instance_id = ?` from the player DB.
  Conditions are **per zone, declared in the DB**; a zone only knows the ids it has rows for.
- `SetCondition` (l. 1151) for the local zone does
  `spawn_conditions.find(condition_id)`; **if the id is not loaded it logs at `Spawns` level and
  returns without touching the DB** (l. 1186-1189). Same value → early return, no write.
  Otherwise it writes `spawn_condition_values` and calls `Zone::SpawnConditionChanged`.
- `Spawn2::Process` (l. 173) gates a spawn point with
  `zone->spawn_conditions.Check(condition_id, condition_min_value)`, and `Check` (l. 1396) is
  **`cond.value >= min_value`**. A missing condition returns `false` — the spawn point never
  fires.
- `Spawn2::SpawnConditionChanged` (l. 669) reacts only when the `>=` threshold is *crossed*, and
  what it does is the condition's `onchange`: `0` nothing, `1` depop, `2` repop, `3` repop if
  respawn timer expired, `≥100` signal NPC with `(onchange-100)`.

Two consequences for any design:

1. **A `spawn_conditions` row `(zone, 99, …)` is a hard prerequisite** in every zone that should
   participate. Without it the toggle is a silent no-op, which is exactly the current state.
2. Because the check is `>=`, a single condition cannot express "spawn A *or* B". Fabled rows
   with `cond_value=2` are suppressed at value 1, but normal rows with `cond_value=1` still
   spawn at value 2. Making the normal version disappear during the season needs either a
   second, inverted condition or a design that does not duplicate spawn points (§6).

---

## 3. What the DB actually contains

All counts from the dump; line numbers refer to `release-peq.sql` inside the zip.

| Check | Result |
| --- | --- |
| `spawn_conditions` rows total | 153 |
| `spawn_conditions` rows with `id = 99` or a name containing "fabled" | **0** |
| `spawn_condition_values` rows with `id = 99` | **0** |
| `spawn2` rows with `_condition = 99` | **0** (of ~173 k) |
| `npc_types` whose name contains "fabled" | **5**, all NMS custom (table below) |
| `items` whose name contains "Fabled" | 3 base items + their `1xxxxxx`/`2xxxxxx` tier copies |
| Base (non-Fabled) versions of the live Fabled roster present? | Yes — 50/50 sampled names found (`Lord_Nagafen`, `Trakanon`, `the_ghoul_lord`, `Quarm`, …) |

The five Fabled `npc_types`:

| id | name | lvl | hp | loottable | placed by |
| --- | --- | --- | --- | --- | --- |
| 1120001072 | The_Fabled_Lord_Nagafen | 80 | 2,500,000 | 222003 | `spawn2` 2141635 → `soldungb` **version 1**, condition 0, respawn 604800 s |
| 1120001078 | Fabled_Magus_Rokyl | 79 | 1,250,000 | 0 | script (`SpawnRokyl`) |
| 1120001080 | fabled_fire_giant_warrior | 68 | 10,000 | 0 | script (`SpawnGiants`) |
| 1120001086 | A_Fabled_Lost_Iksar (lastname "Fabled Kunark Flag") | 100 | 1,000,000 | 0 | script (`SpawnFabledIksar`, on Nagafen death) |
| 1120001110 | The_Fabled_Panic | 80 | 10,000,000 | 222004 | script (`bazaar/`, `fearplane/A_Fading_Ally.pl`) |

Re-run against a live DB:

```sql
SELECT zone, id, value, onchange, name FROM spawn_conditions WHERE id = 99 OR name LIKE '%abled%';
SELECT COUNT(*) FROM spawn2 WHERE _condition = 99;
SELECT id, name, level, loottable_id FROM npc_types WHERE name LIKE '%abled%';
SELECT * FROM rule_values WHERE rule_name = 'Custom:EnableFabledMobs';
```

**Conclusion:** PEQ never shipped Fabled variants, and NMS did not add any. The toggle was
written ahead of the content.

---

## 4. What "Fabled" means on live EQ (target behaviour)

Summarised from the sources in §9; this is the model the toggle is trying to reproduce.

- Runs for roughly a month each year from the 16 March anniversary. On live it is calendar
  driven; since 2016 the whole back-catalogue is re-enabled together.
- A Fabled is a *variant* of an existing named: same spawn point and spawn timer, but bumped
  well above its zone's level band (Classic/Kunark names became 50–70, Velious/Luclin 70–80,
  PoP 83–90), given extra abilities, and dropping a "Fabled &lt;original item&gt;" upgrade. The
  original or the Fabled version may pop; the Fabled roll is not 100%.
- Coverage stopped at **Planes of Power (incl. Plane of Time)**. Classic → PoP is the whole
  roster; GoD/OoW/DoN never received Fableds. That roster is ~330 named across ~90 zones, which
  maps onto NMS's own progression stages `RoK`, `SoV`, `SoL`, `PoP`.
- Fabled loot on live is a hand-made item per drop. NMS already has a generic upgraded-item
  concept — the `+1,000,000` (Enchanted) and `+2,000,000` (Legendary) item IDs rolled by
  `NPC::DoUpgradeLoot` (`zone/loot.cpp:270`, rules `Custom:DoItemUpgrades`,
  `Tier1ItemDropRate`=25, `Tier2ItemDropRate`=5) — which is the obvious stand-in.

---

## 5. Legacy runbook (to be removed with §6)

Until §6 ships, the only switch is `Custom:EnableFabledMobs`, and it is a no-op:
`#rules setdb Custom:EnableFabledMobs true` → `#reload rules global` → zone in → the `Spawns` log
prints `Local Condition update requested for [99], but we do not have that conditon`. §6 deletes
this rule and the `global_player.pl:19-21` call; there is nothing to migrate because no state was
ever written.

---

## 6. The design (decided 2026-09-05)

Design goals, in priority order: **zero per-spawn cost when off, O(1) when on; no polling; no
reload or restart to start, change, or end a season; everything a GM needs is a `#fabled`
sub-command.** One compile + restart to ship the code is accepted; nothing after that.

### 6.1 Decisions

| Topic | Decision |
| --- | --- |
| Where the logic lives | C++ (`zone`, `world`, `common`). Perl gets one exported getter (`IsFabled`) for optional flavour scripts and nothing on the spawn path |
| Alive at season end | **Live-EQ behaviour**: Fableds already up stay until killed or their spawn point cycles. No depop pass |
| Naming | Rename to `The_Fabled_<name>` via the original-name path; **all name-keyed kill logic switches to `GetOrigName()`** (see 6.6) |
| Where it applies | Everywhere — static zones and every instance, including `StaticInstanceVersion` (255) progression raids |
| Level/stats | Per-NPC absolute target level from `fabled_npcs.level` (live values), capped at `Character:MaxLevel` (75). HP/hit multipliers derived from the level delta, per-row overrides |
| Roster v1 | Full live roster Classic → PoP incl. Plane of Time: 458 live rows → **472 `npc_types` ids** (ambiguous same-zone duplicates all included, 8 unmatched — see the seed file footer), from `utils/sql/fabled_roster_seed.sql` |
| Loot | The named's **own table** is forced to the Legendary tier (`+2,000,000`) inside the existing `DoUpgradeLoot` roll; global loot keeps its normal roll (`m_loading_global_loot` guard). No extra currency/title in v1 |
| Announcements | World emote on season start and end only. **No per-spawn announce** |
| GM access | `#fabled` at status **200** (GMMgmt, same as `#reload`) |
| Default chance | `Custom:FabledDefaultChance` (INT, default **50**) — read **only** when `#fabled on` is typed without a chance; the active value lives in the season row |
| Old toggle | `Custom:EnableFabledMobs` and the `global_player.pl` spawn-condition call are **deleted**; `custom-rules/README.md` regenerated |

### 6.2 Data model

Two tables, both via the custom migration manifest (v27, v28 — see 6.8 for the manifest rules).

**`fabled_npcs`** — content DB, the roster. One row per eligible `npc_types.id`.

| column | type | meaning |
| --- | --- | --- |
| `npc_id` | int PK | `npc_types.id` of the *normal* named |
| `era` | varchar(8) | `Classic`, `RoK`, `SoV`, `SoL`, `PoP` — matches the NMS stage names for scoping |
| `level` | tinyint | absolute Fabled level (live value), clamped to `Character:MaxLevel` at load |
| `hp_mult` / `min_hit_mult` / `max_hit_mult` | float, nullable | overrides; `NULL` → derived from level delta (6.5) |
| `npc_spells_id` | int, nullable | override spell set; `NULL` → keep |
| `special_abilities_append` | varchar(255), nullable | appended to the NPC's `special_abilities` string |
| `chance` | tinyint, nullable | per-NPC chance override; `NULL` → season chance |
| `enabled` | tinyint(1) | soft switch per row |

**`fabled_season`** — player DB, exactly one row (`id = 1`), the operational state world owns.

| column | type | meaning |
| --- | --- | --- |
| `active` | tinyint(1) | GM intent; `0` after `#fabled off` or after `end_epoch` passes |
| `start_epoch` / `end_epoch` | bigint | UTC epoch seconds; `#fabled schedule` stores local midnight |
| `scope_kind` | enum(`all`,`era`,`zone`) | |
| `scope_value` | varchar(32) | era name or zone short name |
| `chance` | tinyint | 1–100 |
| `loot_tier` | tinyint | 2 (Legendary). Kept as data so it can be lowered without code |
| `set_by` / `set_at` | varchar(64) / bigint | audit |

### 6.3 State flow — push only

```
GM: #fabled …  ──►  zone writes fabled_season, sends ServerOP_FabledSeasonUpdate(action=1) to world
                     world re-reads the row, broadcasts ServerFabledSeason_Struct to every zone,
                     emotes only on a live↔not-live transition
zone boot      ──►  zone reads fabled_season once itself (ZoneFabled::LoadSeasonFromDatabase — so the
                     first Spawn2::Process tick cannot race world), then sends action=0 and world
                     replies with its copy to that zone only
world boot     ──►  world reads fabled_season, broadcasts to zones that stayed up
end_epoch      ──►  nothing is sent; every zone's spawn check fails the time compare on its own
world 1-min tick ─► if active && now ≥ end: active=0 in DB, broadcast, "…fades" emote (bookkeeping only);
                     one "…stirs" emote when a scheduled start is reached
```

`ServerFabledSeason_Struct` (`common/servertalk.h`) is a fixed POD (`active`, `scope_kind`,
`chance`, `loot_tier`, `start_epoch`, `end_epoch`, `scope_value[32]`); opcodes `0x4790`
(world→zone) and `0x4791` (zone→world). World owner: `world/fabled_season.{h,cpp}`
(`WorldFabledSeason`). Zone cache: `zone/fabled.{h,cpp}` (`ZoneFabled`, member `zone->fabled`).

### 6.4 Zone-side cache and the hook

On receipt of the struct (or at boot) the zone computes **once**:

```cpp
struct ZoneFabledState {
    bool     enabled;         // struct.active && scope matches this zone (kind==zone → short name; kind==era → filter set below)
    int64    start, end;
    uint8    chance, loot_tier;
    std::unordered_map<uint32, FabledNpcRow> npcs;   // fabled_npcs rows, filtered by era if scope_kind==era
};
```

`npcs` is loaded from `fabled_npcs` at zone boot (472 rows server-wide, fewer after era scoping)
and refreshed only by `#reload fabled`. Live NPCs hold a raw pointer to their roster row, so a
reload never erases: rows missing from the new result are disabled in place. No per-spawn DB
access anywhere.

Hook — `Spawn2::Process`, between the `new NPC(...)` at `spawn2.cpp:288` and `AddLootTable()` at
`:302`:

```cpp
auto &fs = zone->fabled;
if (fs.enabled) {                                         // one bool when off — the entire cost
    const int64 now = std::time(nullptr);                 // ~20 ns; no syscall on modern libc
    if (now >= fs.start && now < fs.end) {
        auto it = fs.npcs.find(npc->GetNPCTypeID());      // O(1); misses for 99%+ of spawns
        if (it != fs.npcs.end() && zone->random.Int(1, 100) <= (it->second.chance ? it->second.chance : fs.chance)) {
            npc->SetFabled(&it->second);                  // flag + row pointer only; stats applied after loot
        }
    }
}
npc->AddLootTable();                                      // existing line — DoUpgradeLoot sees IsFabled()
if (npc->DropsGlobalLoot()) npc->CheckGlobalLootTables(); // existing — evaluated at BASE level
if (npc->IsFabled()) npc->ApplyFabled();                  // name, level, stats — after loot, before AddNPC
```

Ordering matters twice: loot is rolled at the base level so `MeetsLootDropLevelRequirements`
(`loot.cpp:241-265`) and level-banded global loot behave exactly as for the normal mob; the
rename happens before `entity_list.AddNPC(npc)` (`:311`) so the Fabled name ships in the original
spawn packet — no `TempName` broadcast.

Script-spawned NPCs (`quest::spawn2`, `#spawn`) do not pass through this hook and are never
promoted. `#fabled force` (6.7) exists for testing.

### 6.5 `ApplyFabled()` and loot

- Name: `TempName(fmt::format("The_Fabled_{}", GetOrigName()))`. `orig_name` is untouched
  (`mob.cpp:4545`), which is what 6.6 relies on.
- Level: `row.level` clamped to `RuleI(Character, MaxLevel)`; `delta = level - base_level`.
- Derived defaults when a multiplier is `NULL`: `hp_mult = 1 + 0.35·delta`,
  `min/max_hit_mult = 1 + 0.15·delta` (tunable constants in one place; a level-60 → 70 named
  becomes ~4.5× HP, ~2.5× hits). Row overrides win.
- `npc_spells_id` / `special_abilities_append` applied if present.
- Sets entity variable `fabled=1` **and** persists nothing else — see zone-state note below.
- Pre-registration (`already_spawned=false`) the name is set directly (`RemoveNumbers` →
  `MakeNameUnique` → `SetName`) and `level` is assigned without `SetLevel`, so no packets go out
  for an NPC that has no entity id yet; the spawn packet carries both. `#fabled force`
  (`already_spawned=true`) uses `TempName`/`SetLevel` and re-tiers the loot list in place.
- `default_min_dmg/max_dmg/special_abilities` are updated too, so charm-break does not revert a
  Fabled to base stats.
- Loot: in `NPC::DoUpgradeLoot` (`loot.cpp:270`), before the random roll:
  `if (IsFabled() && !m_loading_global_loot) { forced = (itemID % 1000000) + loot_tier*1000000; if (forced > itemID && database.GetItem(forced)) return forced; }`.
  Items without a Legendary variant fall through to the normal roll. Nothing is removed or re-added.
  `m_loading_global_loot` is set for the duration of `AddLootTable(id, is_global=true)` only.

**Zone suspend/resume.** `zone_save_state.cpp` restores entity variables (`:293`) and loot, but
name/level/stats come back from `npc_types`. `LoadNPCStatePreSpawn` runs before the hook, so the
hook checks `IsResumedFromZoneSuspend()` + `EntityVariableExists("fabled")` first: if set, skip
the roll, re-attach the row via `Find()`, and `ApplyFabled()` after the (restored, not re-rolled)
loot. A suspended Fabled resumes as a Fabled; a suspended normal named can never become one by
resuming. Requires `Zone:StateSaveEntityVariables` (default true).

### 6.6 Name-keyed logic that must use the original name

`NMS_progression_utils.pl:873` grants progression flags from `lc($npc->GetCleanName())`. With the
rename, a Fabled Vox kill would silently fail to flag RoK. Fix:

1. Export `GetOrigName` to Perl (`perl_mob.cpp`) and Lua (`lua_mob.cpp`) — one binding each; the
   C++ accessor already exists (`mob.h:633`).
2. Change the matcher to `lc(plugin::CleanName($npc->GetOrigName()))` (strip the `_`/`#` the same
   way `GetCleanName` does).
3. Audit the remaining `GetCleanName() eq` / `=~` kill checks in `Release-NMS-Quests` (303 files
   reference `GetCleanName`; most are self-emotes and unaffected). Any that gate on a *named's* name
   switch to `GetOrigName`. `soldungb/player.pl:4` (`eq "Lord Nagafen"`) is one.

Quest **script binding is not affected**: `quest_parser_collection.cpp:938` resolves files from
`npc_type->name`, not the live name. The custom raid's `The_Fabled_Lord_Nagafen` (npc
`1120001072`) shares a display name with a Fabled stock Nagafen; they are different `npc_types`
and bind to different scripts, so this is cosmetic.

### 6.7 `#fabled` (status 200)

| Command | Effect |
| --- | --- |
| `#fabled on [scope] [duration] [chance]` | scope `all` \| `era:<RoK…>` \| `zone:<short>`; duration `30m`/`6h`/`3d`/`2w` (default: open-ended); chance 1–100 (default `Custom:FabledDefaultChance`) |
| `#fabled schedule [scope] <YYYY-MM-DD> <YYYY-MM-DD> [chance]` | start/end at **server-local midnight**; may be in the future |
| `#fabled off` | immediate end everywhere (sets `end_epoch = now`, `active = 0`) |
| `#fabled status` | row contents, time remaining, this zone's `enabled`, eligible count in this zone |
| `#fabled force` | promote the targeted NPC now (testing; ignores season/chance, respects roster) |
| `#reload fabled [global]` | re-read `fabled_npcs` after editing the roster — `ServerReload::Type::Fabled`, no restart |

All writes go through world (6.3) so every zone sees the same struct. Duration `m/h/d` parse via
`Strings::TimeToSeconds`; `w` is computed locally (the helper has no week suffix). `off` on an
already-inactive season is a no-op (no broadcast). Dynamic text is printed through a `"%s"`
wrapper because `Client::Message` is printf-style.

### 6.8 Rules and migrations

Rules (then `python Release-NMS-Deploy/custom-rules/generate.py`, `--check` before commit):

```c
RULE_INT(Custom, FabledDefaultChance, 50, "Percent chance used by #fabled on when no chance is given. Read only at command time, never per spawn.")
// RULE_BOOL(Custom, EnableFabledMobs, …)  — DELETED
```

Migrations `v27` (`fabled_npcs`, `content_schema_update = true`) and `v28` (`fabled_season` +
its single seed row); `CUSTOM_BINARY_DATABASE_VERSION` 25 → 27. Per CODEBASE.md §4.3: both use a
`check` on the created artifact and `CREATE TABLE IF NOT EXISTS` / `INSERT … WHERE NOT EXISTS`, so
they are idempotent; no bare `UPDATE`s. `utils/sql/nms_content_health_check.sql` asserts the
season row and the roster count (472). The roster seed is **not** a migration — it is
`utils/sql/fabled_roster_seed.sql`, generated by `utils/scripts/fabled_roster.py` (`--dump
<zip|sql>`, `--report-only`) from the live roster (zone + name → `npc_types.id`, tolerant matching,
spawn-zone preference, unmatched/ambiguous report in the file footer), and applied by hand like the
other loose SQL files in CODEBASE.md §4.4.

### 6.9 Costs, stated

| Path | Cost |
| --- | --- |
| Spawn, season off | 1 bool |
| Spawn, season on, not eligible | 1 `time()`, 2 compares, 1 hash miss |
| Spawn, promoted | + `ApplyFabled` (a dozen field writes) once per Fabled |
| Loot roll, promoted | 1 extra `GetItem` lookup per drop |
| Season change | 1 DB write, 1 broadcast, per-zone: rebuild `npcs` filter (≤330 entries) |
| Season end | 0 — plus one DB write and one emote from world's existing minute timer |
| Memory per zone | one fixed struct + one map of ≤330 small rows |
| Memory per NPC | one `bool` + one pointer |

---

## 7. Loose ends found on the way

1. `soldungb/The_Fabled_Lord_Nagafen.lua:1` says `(223201)`; that id is **Quarm**. The NPC is
   `1120001072`. Comment only, but misleading.
2. `A_Fabled_Lost_Iksar` (`1120001086`, lastname "Fabled Kunark Flag") is spawned on Nagafen's
   death but **has no quest script** in `Release-NMS-Quests/soldungb/`, so whatever flag it was
   meant to hand out never happens. `NMS_seasonal_utils.pl:82` records `FNagafen` participation
   from `is_stage_complete`, which is set from the Quarm kill, not from this NPC.
3. `cauldron/#The_Fabled_Bilge_Farfathom.pl` and the three trigger scripts reference NPC `70069`,
   which in this DB is `frostcrypt70069` / `#goto Liahh`. Dead PEQ-era script.
4. `global_player.pl:19-21` issues a dead `spawn_condition(…, 99, …)` call on **every** zone
   entry. Deleted by §8 step 9.
5. The rule text promises "100% Fabled spawns"; the rule is deleted by §8 step 9.
6. Progression kill credit is keyed on the live display name (`NMS_progression_utils.pl:873`).
   Any feature that renames an NPC breaks it — §6.6 moves it to `GetOrigName()`.
7. Zone suspend/resume (`zone_save_state.cpp`) restores entity variables and loot but not
   runtime stat changes (`modify_stat_*` variables are saved yet never re-applied by C++).
   `ScaleInstanceNPC` survives only because its `EVENT_SPAWN` re-runs on resume and finds its
   `original_*` variables; a C++ promotion has no such hook, hence the explicit resume path in §6.5.
8. `Timer::GetCurrentTime()` is process uptime in ms, not wall-clock; anything comparing to an
   epoch must use `std::time(nullptr)` (as §6.4 does).

---

## 8. Implementation status

Implemented 2026-09-06 in four parallel lanes plus an independent read-only review; nothing has
been compiled yet (no toolchain in the authoring sandbox).

| # | Step | Files | Status |
| --- | --- | --- | --- |
| 1 | Schema: `fabled_npcs`, `fabled_season` + seed row; manifest v27/v28; `CUSTOM_BINARY_DATABASE_VERSION` 28; health check | `common/database/database_update_manifest_custom.cpp`, `common/version.h`, `utils/sql/nms_content_health_check.sql`, `common/repositories/{base/base_,}fabled_{npcs,season}_repository.h`, `common/CMakeLists.txt` | **Done** |
| 2 | Shared struct + opcodes + reload type | `common/servertalk.h`, `common/server_reload_types.h` | **Done** |
| 3 | World owner: load, broadcast, reply to zone request, minute tick, emotes | `world/fabled_season.{h,cpp}`, `world/zoneserver.cpp`, `world/main.cpp`, `world/CMakeLists.txt` | **Done** |
| 4 | Zone cache: roster load, DB season read at boot, request/receive, `#reload fabled` | `zone/fabled.{h,cpp}`, `zone/zone.{h,cpp}`, `zone/worldserver.cpp`, `zone/CMakeLists.txt` | **Done** |
| 5 | NPC promotion: `SetFabled/IsFabled/GetFabledRow/ApplyFabled/GetFabledLootTier`, hook in `Spawn2::Process`, resume path | `zone/npc.{h,cpp}`, `zone/spawn2.cpp` | **Done** |
| 6 | Loot: forced tier for own drops only | `zone/loot.cpp` | **Done** |
| 7 | `#fabled on/schedule/off/status/force` (status 200) | `zone/gm_commands/fabled.cpp`, `zone/command.{h,cpp}`, `GM-COMMANDS.md` | **Done** |
| 8 | `GetOrigName` (Perl/Lua), `IsFabled` (Perl/Lua), progression matcher on the original name, Nagafen/Vox banish checks | `zone/{perl,lua}_mob.*`, `zone/{perl,lua}_npc.*`, `NMS_progression_utils.pl` (`CleanNpcName`), `soldungb/player.pl`, `permafrost/player.pl`, `QUEST-API.md` | **Done** |
| 9 | Rules: `FabledDefaultChance` added, `EnableFabledMobs` deleted, `global_player.pl:19-21` deleted, index regenerated | `common/ruletypes.h`, `Release-NMS-Deploy/custom-rules/`, `global/global_player.pl` | **Done** |
| 10 | Roster generator + seed (458 live rows → 472 ids; 8 unmatched listed in the seed footer) | `utils/scripts/fabled_roster.py`, `utils/sql/fabled_roster_seed.sql` | **Done** |
| 11 | Build on the Windows/MSVC toolchain named in the README; fix whatever the compiler finds | — | **Open (maintainer)** |
| 12 | Boot world + a zone: v27/v28 apply once, `nms_content_health_check.sql` clean; apply `fabled_roster_seed.sql`; re-run health check (expects 472) | — | **Open** |
| 13 | Acceptance test below | — | **Open** |
| 14 | Commit from the Windows checkout (the tree is CRLF) | — | **Done** |

Known follow-ups, deliberately not done here: the GetCleanName audit also flagged
`pojustice/#Event_Execution_Control.pl` (compares trial-mob names indirectly) — only matters if
those NPCs are ever added to the roster; `Zone:StateSaveEntityVariables` must stay on for the
resume path; global loot is intentionally excluded from the forced tier.

**Acceptance (end-to-end):** build green; fresh DB import → boot →
`#fabled on all 2h 100` → `#repop` in `soldungb`: every roster named is `The_Fabled_*`, at its
row level, with Legendary drops (`#npcloot show`), and `#showstats` matches the derived
multipliers; kill one → progression flag mob spawns as for the normal named; `#fabled schedule all
<yesterday> <today>` → `#fabled status` shows ended, `#repop` gives normal named; `#fabled on all
5m` → wait six minutes with no commands → next `#repop` is normal and world emitted the end emote;
suspend and resume the zone with a Fabled up → still Fabled; same sequence inside a
`StaticInstanceVersion` expedition; `#fabled force` on a roster named outside a season promotes it
and re-tiers its loot; `#reload fabled` after editing a roster row changes the next spawn.

---

## 9. Sources

Repo (line numbers as of this commit): `Release-NMS-Server/common/ruletypes.h`,
`Release-NMS-Server/zone/spawn2.cpp`, `Release-NMS-Server/zone/loot.cpp`,
`Release-NMS-Server/zone/npc.cpp`, `Release-NMS-Server/zone/embparser_api.cpp`,
`Release-NMS-Server/common/rulesys.cpp`, `Release-NMS-Quests/global/global_player.pl`,
`Release-NMS-Quests/global/global_npc.pl`, `Release-NMS-Plugins/NMS_progression_utils.pl`,
`Release-NMS-Plugins/NMS_instance_utils.pl`, `Release-NMS-Server/GM-COMMANDS.md`,
`Release-NMS-Server/database/release-peq.zip`.

External:

- EQEmu docs — [Spawns](https://docs.eqemu.dev/server/npc/spawns/),
  [`spawn_conditions` schema](https://docs.eqemu.io/schema/spawns/spawn_conditions/),
  [`spawn_events` schema](http://docs.eqemu.io/schema/spawns/spawn_events/)
- Live Fabled roster by level/zone (Classic → PoP, ~330 entries) —
  [Fabled Mobs for Newbies](https://www.paullynch.org/eqguide/guides/fabled-mobs/)
- Era coverage stopped at PoP — [Almar's Fabled guide](https://almarsguides.com/eq/general/fabled/)
- Anniversary/Fabled timeline — [Bonzz: Anniversary Events](https://www.bonzz.com/anniversary.htm),
  [EverQuest: 6th anniversary Fabled NPCs](https://www.everquest.com/news/imported-eq-enus-50000),
  [EverQuest: 2016 legacy anniversary content](https://www.everquest.com/news/anniversary-content-fabled-npcs-april-2016)
- Community precedent for script-spawned Fableds —
  [EQEmu forums: Fabled spawn code](https://www.eqemulator.org/forums/showthread.php?p=204162)
