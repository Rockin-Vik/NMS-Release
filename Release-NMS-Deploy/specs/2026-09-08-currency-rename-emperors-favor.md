# Rename "Echo of Memory" → "Emperor's Favor", and rework the drop gate

Status: **approved — ready to implement.** Nothing has been changed yet.

Every `file:line` below was read in this checkout; every DB row was read by streaming
`Release-NMS-Server/database/release-peq.zip`. **Nothing here was built or run** — this machine has
no compiler, no MariaDB, no client install (AGENTS.md). Read-verified only.

---

## 1. The drop gate as it is today

`NPC::Death` — `Release-NMS-Server/zone/attack.cpp:3044-3085`. Reached only when the NPC makes a
corpse: not an owned pet, not a merc, not a swarm pet, and killed by a client or a client's pet
(`attack.cpp:2886-2914`).

Candidate rollers: the whole raid if the killer is raided, else the whole group, else the killer alone.

**Gate 1 — level range.** `Mob::IsWithinRewardLevelRange(c->GetRewardLevel(), reference)`
(`zone/mob_ai.cpp:2545-2555`), `reference` = the group's or raid's highest reward level (own level
when solo, so solo always passes):

```
max_diff = -(member_level * 15 / 10 - member_level)   // == -floor(member_level / 2)
if (max_diff > -5) max_diff = -5                      // floor of 5 levels
pass if (member_level - reference) >= max_diff
```

A member may be at most `max(5, floor(own_level/2))` levels below the top of the group. This is the
stock XP-split rule, lifted verbatim.

**Gate 2 — con colour.** `c->GetLevelCon(GetLevel())` must be White, Yellow or Red
(`attack.cpp:3053-3055`). In both con systems (`mob_ai.cpp:2324-2537`) White is `diff == 0` and
Yellow/Red are positive, so this reduces to **the NPC must be at or above the player's level**.

**Gate 3 — the roll.** `attack.cpp:3056-3057`: flat `1 in RuleI(Custom, EventEOMDropChance)`, **per
eligible player per kill**. On success: `CheckItemDiscoverability(46779)`,
`AddAlternateCurrencyValue(6, 1, true)`, a green chat line and a 4-second marquee.

### What is *not* in the gate

- **No event gate.** `EventEOMDropChance` is the only `Event`-prefixed rule in the `Custom` block
  (`ruletypes.h:1258`), and there is no event check anywhere in the enclosing scopes — I walked the
  brace nesting from line 3044 out to `NPC::Death` at 2578. The prefix and "during event" in its
  description are vestigial. It always drops.
- No minimum NPC level, no zone list, no NPC-type filter, no rarity tier.
- `Custom:EnableAccountAltCurrency` does **not** gate the drop; it only chooses account-wide vs
  per-character storage in `Client::SetAlternateCurrencyValue` (`zone/client.cpp:8932-8936`).
- `zone->DoesAlternateCurrencyExist(6)` must hold — it does: `alternate_currency` row `(6,46779)`.

### Value in the shipped baseline

`release-peq.sql` `rule_values` ruleset 1 carries `Custom:EventEOMDropChance = '200'`, equal to the
compiled default. **The value on the running server was not read** — this is the release dump.

### The economics that set the new number

`Release-NMS-Quests/bazaar/151061.pl:46,132` — every sink offers a platinum alternative at
`$platinum_alt_cost = 2500` per unit (`TakeMoneyFromPP($platinum_alt_cost * $cost * 1000, 1)`, i.e.
copper). **The server prices 1 unit at 2,500pp.** So at 1-in-N, grinding beats paying only when a
white-or-better kill is worth more than `2500/N` platinum:

| N | Breakeven | Solo kills for a 10-cost purchase |
| --- | --- | --- |
| 200 (today) | 12.5pp/kill | 2,000 |
| **150 (chosen)** | **16.7pp/kill** | **1,500** |
| 100 | 25pp/kill | 1,000 |
| 50 | 50pp/kill | 500 |

Full sink table, read-verified: 2 (`Purveyor_of_Glamour.pl:123`); 5 (AA reset
`Vision_of_Ayonae.pl:12`, set unlock and slot unlock `ruletypes.h:1219,1222`, map attunement
`Tearel.pl:50`, single world buff `Apocrypha.pl:26,30`); 10 (class removal
`NMS_multiclass_utils.pl:398`, name/race/deity/gender/pet-name change `151061.pl:41-45`, exp buff
`Apocrypha.pl:38`); 20/25/35 (world-buff bundles). Lifetime unlock ceiling is 3×5 + 12×5 = 75.

---

## 2. The new drop behaviour (decided)

**Both level gates are removed.** The currency rewards time played, broadly: every eligible player
rolls on every corpse, at a flat 1-in-150, with no level check of any kind.

1. **Delete gate 1** — the `IsWithinRewardLevelRange` call at `attack.cpp:3049`, plus the now-unused
   `reference_level` parameter and the `raid_top` / `grp_top` locals (`attack.cpp:3066,3074`) and the
   two `GetHighestRewardLevel()` calls that fed them.
2. **Delete gate 2** — the `GetLevelCon` con-colour check at `attack.cpp:3052-3055`.
3. **Keep the flat roll**, `Custom:EmperorsFavorDropChance`, default and live value **150**.

The lambda reduces to roughly:

```cpp
auto TryEmperorsFavorAward = [](Client* c) {
    if (!c) {
        return;
    }
    const int chance = RuleI(Custom, EmperorsFavorDropChance);
    if (chance > 0 && zone->random.Int(0, chance - 1) == 0) {
        c->CheckItemDiscoverability(46779);
        c->AddAlternateCurrencyValue(6, 1, true);
        c->Message(Chat::Green, "You receive 1 Emperor's Favor.");
        c->SendMarqueeMessage(15, "YOU HAVE FOUND AN EMPEROR'S FAVOR!", 4000);
    }
};
```

The capture list becomes empty — `this` was only needed for `GetLevel()` in gate 2.

### What still bounds the award

The enclosing corpse condition (`attack.cpp:2886-2914`) is structural, not a gate, and stays: the NPC
must actually make a corpse — not an owned pet, not a merc, not a swarm pet — and must be killed by a
client or a client's pet. Merchants only count when `Merchant:AllowCorpse` is on.

### Accepted consequences, on the record

- **Mules.** A parked level-1 alt in a group or raid rolls on every kill.
- **Trivial-content farming.** A capped character AoE-grinding a low-level zone earns at that zone's
  kill rate, which is far higher than current content's. With no con gate, this is the fastest way to
  earn the currency.

Both were put to the repo owner explicitly and accepted. They are design choices, not defects — do
not "fix" them later without asking.

### Callers of the things being removed

`Mob::IsWithinRewardLevelRange` has three callers. `attack.cpp:3049` is removed. `exp.cpp:2137`
(`Group::SplitExp`) and `exp.cpp:2181` (`Raid::SplitExp`) are **left alone** — they are the stock XP
split and are not in scope. The helper and its declaration (`mob.h:802`) stay; only its comment
changes, to stop claiming the currency award uses it.

`Mob::GetLevelCon` is used widely (con display, XP, faction). Only this one call site is removed.

`Group::GetHighestRewardLevel` / `Raid::GetHighestRewardLevel` keep their other callers in
`groups.cpp:1167` and `raids.cpp:1125`; only the two calls in this block go.

---

## 3. Rename inventory

### 3a. Flagged as FALSE POSITIVES — do not touch

Validated by reading each one:

- `Release-NMS-Quests/vexthal/Eom_Centien.lua`, `Eom_Liako.lua`, `Eom_Senshali.lua`, `Eom_Thall.lua`,
  `Eom_Va_Liako.lua`, `Eom_Zethon.lua`; plus `shade_trigger.lua:22,37`, `akhevan_trigger.lua:21,36`,
  `Zun_Thall.lua:27` and the `Qua_/Zov_/Zun_/Pli_` siblings. **"Eom" is a Vex Thal Akhevan mob-name
  prefix** marking the level-66 shade tier (`Qua`=L55, `Zov`=L58, `Zun`=L61, `Pli`=L64, `Eom`=L66).
- DB items `139498` / `1139498` `'Eom Draues, Longbow of Torment'` and `705977`
  `'Glamour - Eom Draues...'` — same Akhevan naming.
- DB `items_reference` id `46779` is `'Bayle Mark'` — a different table, coincidental id.
- `eqgame_dll`: the `/echo` command, `USERCOLOR_ECHO_*`, the spell "Phantom Echo", `CVideoModesWnd`.
- `Release-NMS-Server/submodules/recastnavigation/*` — vendored, unrelated.
- Dozens of DB ids containing the digits `46779` (`146779`, `546779`, `2146779`) in `doors`, `grid`,
  `grid_entries`, `skill_caps`, `spawn2`, `tool_game_objects`, `tradeskill_recipe_entries`.

### 3b. Naming scheme (decided: `EmperorsFavor` everywhere)

| Old | New |
| --- | --- |
| `Custom:EventEOMDropChance` | `Custom:EmperorsFavorDropChance` |
| `Custom:EoMUnlockCharacterSets` | `Custom:EmperorsFavorUnlockCharacterSets` |
| `Custom:EoMUnlockCharacterSetCost` | `Custom:EmperorsFavorUnlockCharacterSetCost` |
| `Custom:EoMUnlockCharacterSlots` | `Custom:EmperorsFavorUnlockCharacterSlots` |
| `Custom:EoMUnlockCharacterSlotCost` | `Custom:EmperorsFavorUnlockCharacterSlotCost` |
| `EOM_CURRENCY_ID` | `EMPERORS_FAVOR_CURRENCY_ID` |
| `m_eom_available` | `m_emperors_favor_available` |
| `TryEOMAward` | `TryEmperorsFavorAward` |
| `"EoM-Award"` bucket | `"EmperorsFavor-Award"` |
| `SpendEOM` / `GetEOM` / `EOMLink` / `LootEOM` | `SpendEmperorsFavor` / `GetEmperorsFavor` / `EmperorsFavorLink` / `LootEmperorsFavor` |
| `SpendEOM.pl` | `EmperorsFavor.pl` |
| `IW_EOMBackground` / `IW_EOMIcon` / `IW_EOMPoints` | `IW_EmperorsFavorBackground` / `Icon` / `Points` |

Apostrophe: ASCII `'`, not U+2019, in every string literal and DB row — the EQ client's label
rendering is not verifiable from here and ASCII is safe.

### 3c. Server C++ — true hits

| File | Lines | What |
| --- | --- | --- |
| `common/ruletypes.h` | 1218, 1219, 1221, 1222, 1258 | 5 rule names + descriptions; default of the drop rule 200 → **150** |
| `zone/attack.cpp` | 3044-3085 | comment, lambda rename, **both gates removed** (§2), **player-visible** `"You receive 1 Echo of Memory."` and `"YOU HAVE FOUND AN ECHO OF MEMORY!"` |
| `zone/mob.h` | 801 | comment — must stop claiming the currency award uses the helper |
| `zone/client_packet.cpp` | 17288, 17308 | comments |
| `zone/command.cpp` | 99 | `#award` help text is literally `"EoM"` — GM-visible |
| `zone/gm_commands/award.cpp` | 56, 57, 62, 75, 81 | comments, bucket key, GM reply, Discord message |
| `world/client.h` | 40, 128 | `EOM_CURRENCY_ID`, `m_eom_available` |
| `world/client.cpp` | 2858, 2920-3210 | ~25 identifier uses plus `LogError`/`LogCharacterSets` strings |
| `common/eq_packet_structs.h` | 217 | `uint32 eom_available` — field name only, wire layout unchanged |

**Boundary — leave alone.** `common/database/database_update_manifest_custom.cpp:325,328`
(`eom_sets`, `eom_slots`) sit inside a `/* ... */` block spanning lines 273-334; those manifest
entries (v15-v17) are disabled and `account_character_set_limits` does not exist in the shipped dump.
`common/repositories/base/base_account_character_set_limits_repository.h` (~24 uses) is **generated
code** mirroring those column names. Renaming the columns means a migration plus regenerating that
header for zero player-visible benefit.

### 3d. Perl / Lua — true hits

| File | What |
| --- | --- |
| `Release-NMS-Plugins/SpendEOM.pl` | whole file + filename; all four subs; marquee string. **`LootEOM` has zero callers repo-wide** — dead code, delete it |
| `Release-NMS-Plugins/NMS_custom_events.pl` | 72-93: `UpdateEoMAward`, bucket key, player message |
| `Release-NMS-Plugins/NMS_multiclass_utils.pl` | 12, 398, 421, 422, 426 |
| `Release-NMS-Quests/global/global_player.pl` | 3 |
| `Release-NMS-Quests/bazaar/151061.pl` | 112, 117, 131, 146, 170, 180, 202, 222, 231, 246, 253, 264, 285, 311, 328 |
| `Release-NMS-Quests/bazaar/Apocrypha.pl` | 2, 17, 46, 53 |
| `Release-NMS-Quests/cshome/Apocrypha.pl` | 2, 70, 78-145 — **uses the plural "Echoes"**, see D1 |
| `Release-NMS-Quests/bazaar/Vision_of_Ayonae.pl` | 246-286 |
| `Release-NMS-Quests/bazaar/Purveyor_of_Glamour.pl` | 78, 116, 118, 119, 123 |
| `Release-NMS-Quests/cshome/A_Fading_Ally.pl` | 11 — GM-only (`$client->GetGM()`) say trigger `eom` granting 10 |
| `Release-NMS-Quests/bazaar/Tearel.pl`, `ecommons/Son_of_Tearel.pl` | 3, 40, 54 — `quest::varlink(46779)` only, **follow the DB rename automatically** |

20 call sites total; all are inside this repo.

### 3e. Client — true hits

| File | Lines | What |
| --- | --- | --- |
| `eqgame_dll/MQ2Labels.cpp` | 1854 | comment; EQType 338 → `GetAltCurrency(6)` |
| `eqgame_dll/hero_tab.cpp` | 129 | **player-visible** "10 Echo of Memory" |
| `ClientFiles/uifiles/default/EQUI_Inventory.xml` | 3342, 3354, 3366, 4051-4053 | `IW_EOM*` names, self-contained in this file |
| same | 10079 | **player-visible** `TooltipReference` |
| `ClientFiles/dinput8.dll` | — | carries the compiled `hero_tab.cpp:129` string (confirmed by `grep -a`) |

**Do not rename `EQUI_Inventory.xml:3364` `<Animation>A_EoMIcon</Animation>`.** Referenced once,
**defined nowhere in this repo** — it lives in the base client's own `EQUI_Animations.xml`, outside
this checkout. Renaming it would silently blank the inventory icon. The item icon (`6864`,
`IT11122`) is likewise base-client/DB data.

**Blocker:** the tooltip string is compiled into `dinput8.dll`. Until the DLL is rebuilt on the build
box the client keeps showing "Echo of Memory". Per AGENTS.md the new DLL must be grepped for the new
string *and* for the absence of the old one, and byte-compared against the previous commit.

### 3f. Docs

`README.md:42` · `Release-NMS-Deploy/CODEBASE.md:149-165, 216, 479, 516` ·
`Release-NMS-Deploy/custom-rules/clusters.json:41,42,45,47,48,50,51,217,218,222,223,227` (hand-edited
source) · `Release-NMS-Deploy/custom-rules/README.md` (**generated** — regenerate with
`python Release-NMS-Deploy/custom-rules/generate.py`, verify with `--check`) ·
`Release-NMS-Server/GM-COMMANDS.md:174-179` · `Release-NMS-Quests/QUEST-API.md:85,159,166`.

CODEBASE.md §3.3 also needs its drop description corrected — it currently repeats the "1 in 200,
con-color gated" line and the level-range claim.

The specs dated 2026-09-05 and 2026-09-06 are historical design records. Leave them.

### 3g. Database

Read from `release-peq.zip`. The live DB may differ.

| Table | Row | Player-visible? | Action |
| --- | --- | --- | --- |
| `items` | `46779` name, description `'These echoes hold the gratitude of the many Heroes that have come before.'` | **yes** | rename + rewrite description (D1) |
| `db_str` | `(6,17,'Echo of Memory')`, `(6,18,...)` | **yes** — alt-currency window label | rename |
| `npc_types` | `1120001186` name `'Echo of Memory'`, lastname `'EoM Merchant'` | **yes** | rename (D6) |
| `npc_types` | `1120001290` name `'An Echo Exchange'` | **yes** | rename (D6) |
| `spawngroup` | `5003654` `'bazaar_Echo of Memory000_682659186'` | no | rename for tidiness |
| `rule_values` | 5 rows, ruleset 1 | no | rename keys, set drop chance to 150 |
| `alternate_currency` | `(6,46779)` | no | unchanged |
| `saylink` | `199` `'Echo of Memory'`, `275` `'#find item echo of memory'` | **yes** — a cached link a player clicks | rename both |
| `player_event_logs`, `player_event_merchant_sell` | historical rows | — | **leave** — telemetry history |

Neither `EoM-Award` buckets nor an `account_character_set_limits` table exist in the dump.

---

## 4. Copy, as approved by the repo owner

Use these strings verbatim; they were written by the owner, not by me.

- `cshome/Apocrypha.pl:70` — "twenty-five Echoes" → **"twenty-five tokens of the Emperor's favor"**
- `items` 46779 description → **"A token of the Emperor's favor, borne by the heroes of old."**
- npc `1120001186` → name **`Imperial Emissary`**, lastname **`Favor Merchant`** (renders as
  `Imperial Emissary <Favor Merchant>`)
- npc `1120001290` → **`Imperial Exchanger`**

Note the case: the item name and `db_str` label are **`Emperor's Favor`** (title case, it is the
currency's proper name), while the prose above uses lower-case "favor". That is deliberate.

### One pre-deploy check, to run on the live DB

If this returns rows, the `EoM-Award` → `EmperorsFavor-Award` bucket rename has to drain them first.
The shipped dump has none, but the live server was not read from here:

```sql
SELECT character_id, `key`, value FROM data_buckets WHERE `key` = 'EoM-Award';
```

---

## 5. Sequence

1. **Migration 43** in `database_update_manifest_custom.cpp` (42 is the current highest): `items.Name`
   and `items.lore` for 46779, `db_str` (6,17)/(6,18), the five `rule_values` key renames plus the new
   drop value, the two `npc_types` renames, the `spawngroup` name, the `data_buckets` award key, and
   the two `saylink` cache rows. Guarded with `.check` /
   `.condition` like the existing entries, and using `INSERT ... ON DUPLICATE KEY` for rule rows, not
   a bare `UPDATE` — the manifest's own v18 comment records that a bare `UPDATE` silently no-ops when
   the row is absent.
2. **Server C++** — rules (including the 150 default), `attack.cpp` rename + removal of both gates,
   `world/client.*`, `award.cpp`, `command.cpp`, `mob.h` comment. Every new symbol checked against
   its declaration. **This checkout cannot compile it.**
3. **Perl/Lua** — plugin file rename, all 20 call sites, all player text, delete dead `LootEOM`.
4. **Client** — `hero_tab.cpp`, `MQ2Labels.cpp` comment, `EQUI_Inventory.xml` `IW_EOM*` names and the
   tooltip at 10079. `A_EoMIcon` untouched.
5. **Docs** — CODEBASE.md (including the corrected §3.3 drop description), README.md, GM-COMMANDS.md,
   QUEST-API.md, clusters.json, then regenerate `custom-rules/README.md` and run `generate.py --check`.
6. **Regenerate `release-peq.zip`** with the renames applied.
7. **Rebuild** server and `dinput8.dll` on the build box; verify the new DLL carries the new string,
   not the old, and is not byte-identical to the previous commit.
8. **Verify live**: `#award` credits; an item link renders; the inventory label shows a value; a kill
   awards and prints the new text; a low-level group member now rolls (gate 1 gone); a grey-con kill
   now rolls (gate 2 gone); character-select unlock spend works.

Steps 2, 4, 7 and 8 cannot be verified on this machine.
