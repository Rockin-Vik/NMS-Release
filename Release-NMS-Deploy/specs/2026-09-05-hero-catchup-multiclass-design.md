# Hero loadout — hard catch-up multiclass (design)

2026-09-06, owner decision: shipped with `Custom:HeroCatchupEnabled` off. A new class joins at the character's current level; the catch-up machinery below stays behind the rule and off-mode keeps every class row in lockstep with the pool. Characters that already took the level-1 reset are restored to their highest class row on next load.

Status: draft v5. Three code-grounded review passes (two adversarial; last verdict GO), then the owner resolved every decision on 2026-09-06. Not implemented.
Date: 2026-09-05
Governs: `Custom` multiclass layer (`CODEBASE.md` §3.1), Inventory header, a new Hero tab.

## 0. Decisions

Evidence is the file and line each decision rests on. D1–D15 came from the first review pass, D16–D22 close the adversarial findings. The owner resolved every gameplay-facing row on 2026-09-06 and overrode three recommendations: **D4** (skills clamp, AAs keep working), **D16** (pet and buffs survive the add) and the confirm step (adding stays a single hail). Those three make the tax lighter than first drafted; the rows below record the resolved state.

| # | Decision | Why |
| --- | --- | --- |
| D1 | **Per-class exp is the only stored progression number.** Level is derived on read. | `SetEXP` derives level from the exp pool and re-levels on mismatch (`exp.cpp:1160-1187`, `1275-1294`). A stored level that disagrees with the pool is overwritten on the next kill, so the table stores no level column at all. |
| D2 | **Routing is water-filling.** A gain raises the lowest rows to the next distinct row's exp, then continues with the newly tied set until the delta is spent. A loss comes off the lowest rows only, with checked subtraction. | Plain "add delta to the minimum" lets a row overshoot the row above it on the ding that finishes catch-up; water-filling keeps rows monotone and spends every point. When all rows are equal it is today's lockstep. |
| D3 | **Clamp, then route, then let the stock loop run.** | The max-level clamps rewrite the target after the derivation loop (`exp.cpp:1254-1270`) and the pool is written at `1319`. Routing before those clamps would persist rows above the cap. So: after the Lua `SetEXP` hook (`1045-1058`) and the group incentive bonus (`1136-1142`) have finished mutating the target, compute the clamped target with the same rules (`Character:MaxLevel`, `KeepLevelOverMax` on the current level, per-character max), route it into rows, set the pool to the minimum row, then the stock loop and its clamps run and are no-ops. The derivation and clamp logic is extracted into two helpers rather than duplicated. The post-`SetLevel` cap at `1302-1308` stays in the stock tail. The delta is taken against the pre-repair pool because the target was derived from that same pool. |
| D4 | **Skills clamp to the cap at effective level, only while a row is behind. AAs are not gated.** (Owner decision.) | Skills are returned raw (`client.cpp:14659`), so without the clamp a level-1 body fights with 250 skills. Guarding on "a row is behind" means characters who never catch up see zero behavior change. Tradeskills and bind wound read the raw skill (`tradeskills.cpp:1253, 1402, 1984`; `client.cpp:4743`) and stay raw on purpose. AA bonuses apply with no level check (`bonuses.cpp:602-612`) and activation has none either (`aa.cpp:1565-1583`); the owner chose to leave that as is, so every purchased AA keeps working during catch-up. |
| D5 | **Gear stays on. No level gate, no stripping.** | The client ignores equip level (`Hooks.cpp:965-985`). Stock already withholds item bonuses below `reqlevel` (`bonuses.cpp:280-285`) and a weapon above the wielder's level hits for zero (`attack.cpp:1250-1252`). Those are the gear costs and they are not new. |
| D6 | **Reward eligibility uses the watermark; awards use effective level.** | The group share rule needs a member within about half its own level of the top member (`mob_ai.cpp:2545-2553`). The top level itself is computed from effective levels (`groups.cpp:1144-1156`, `raids.cpp:1107-1117`) and the Echo-of-Memory award has its own copy of the gate (`attack.cpp:3044-3074`). One `GetRewardLevel()` on `Client` plus a highest-reward-level helper on `Group` and `Raid` covers all of them; the raid helper reads the live client, not the cached member level that `SetLevel` writes (`exp.cpp:1367-1372`). Bots and the merc read it at every owner-level site: the level-with-owner call (`exp.cpp:1296-1298`), `Bot::CalcBotStats` (`bot.cpp:7307-7308`), the merc template lookup (`merc.cpp:4284`) and the merc re-level (`merc.cpp:5623-5629`). |
| D7 | **No per-kill brake.** | The curve is cubic (`exp.cpp:1517-1521`). A level-1 gains several levels per kill early and about 1% per kill in the fifties. The tax paces itself. |
| D8 | **Primary class = your last remaining class.** Not the create class. | Vision of Ayonae removes the lowest set bit, usually the create class (`Vision_of_Ayonae.pl:54-74`). Locking `m_pp.class_` breaks the reroll for nothing. |
| D9 | **`AddExtraClass` gets a trusted `join_at_watermark` flag.** Only system scripts pass it. | Ayonae is a trade, not a widening. Player-facing paths never pass it. Scripts are server-owned content, so this does not weaken the player-facing guarantee. |
| D10 | **Adding a class is refused where the zone's minimum level exceeds the start level.** | Zone entry checks effective level (`zoning.cpp:1443`). The zone object does not carry `min_level` at runtime; read it through `ZoneStore::GetZoneMinimumLevel(zone_id, version)` (`common/zone_store.h:53`). |
| D11 | **Header titles ride the existing server-auth stats channel.** No new server-to-client opcode. | The DLL parses a key/value list into a map (`MQ2Labels.cpp:1118-1131`) and the class labels read it (`MQ2Labels.cpp:881`, titles from spawn level at `892`). Structs are trailing arrays (`eq_packet_structs.h:1549-1564`), CAuth scans for key 1 and does not hash the payload (`eqgame.cpp:776-789`). The bulk sender is `SendBulkStatsUpdate` (`inventory.cpp:3875-3892`) and has a pre-existing off-by-one: it sends key 0 and omits the last enum value. Fix the loop to `1..statMax-1` in passing. |
| D12 | **Phases 1 and 2 merge.** | Table, routing and sync are the same block of `SetEXP`. |
| D13 | **`#hero` is the integration and recovery surface; the routing helper gets CLI unit tests.** | `zone/cli/tests/` exists (`databuckets.cpp`, `zone_state.cpp`, …). Routing is pure logic; test ties, overflow across tiers, negative deltas and caps there. |
| D14 | **Perl reads the cap from the rule and checks the C++ result.** The welcome popup's "up to three classes" line follows the cap. | Literals at `NMS_multiclass_utils.pl:313, 328, 453`, `global_npc.pl:34, 83`, `Vision_of_Ayonae.pl:77`, `NMS_popup_utils.pl:48`. Today `plugin::AddClass` ignores the boolean and still dings, messages and announces (`NMS_multiclass_utils.pl:309-331`); Ayonae charges and locks out before knowing removal succeeded (`Vision_of_Ayonae.pl:280-294`). |
| D15 | **Losses route through the same rule; on this server they are rare.** | Death loss is off by rule here, but the path exists (`attack.cpp:2060-2129`), sacrifice removes exp (`client.cpp:5544-5550`) and rez restores through `SetEXP` (`client_process.cpp:1408-1411`). The delta is signed and subtraction is checked; a loss comes off the lowest rows, which are the rows a rez then refills. |
| D16 | **An add that lowers effective level leaves the active pet and running buffs alone.** (Owner decision.) | Pets take their template level at creation and never re-level with the owner (`pets.cpp:300-339`), and running buffs keep applying at their stored caster level (`bonuses.cpp:1882-1897`). So a level-1 body keeps its 65 pet until it dies or is dismissed, and its 65 buffs until they expire; neither can be recast above level. The owner accepted that as part of the lighter tax. No Hero-specific depop or fade code. |
| D17 | **`CanAddExtraClass(class_id, flag)` returns a reason code; `AddExtraClass` uses it; Perl and the Hero tab read it.** | Ayonae picks random classes through the reason code (`Vision_of_Ayonae.pl:61-69`). Selection filters through the reason code; charges, lockouts, announcements and counters happen only after a true result. |
| D18 | **Quest and Lua `SetLevel` on a client set every row.** Raw `SetLevel(level, false)` is internal only. | Both overloads are exported (`perl_mob.cpp:159-166`, `lua_mob.cpp:61-68`); only `quest::level` uses the command form (`questmgr.cpp:1228-1237`). The non-command form changes `Mob::level` without exp (`exp.cpp:1348-1426`) and would break the invariant. |
| D19 | **`Character:UseOldClassExpPenalties` must be false.** `AddExtraClass` refuses while it is on and logs why. | That rule makes the exp curve depend on every held class (`exp.cpp:1539-1556`), so adding a class would move every row's level. Default is false (`ruletypes.h:126`). |
| D20 | **`level2` is untouched.** | It is the historical high-water level and only increases (`exp.cpp:1359-1381`); quest and API surfaces expose it (`client.h:579`, `questmgr.cpp:3216`, `api_service.cpp:729`). During catch-up it stays 65. Never use it for eligibility or display. |
| D21 | **Two manifest entries: create, then backfill.** | The runner is not transactional and stamps the version regardless. A single entry checked on table existence would skip the backfill forever if the insert failed. The backfill entry's condition is "a character with a set bit and no row exists" (`not_empty`, evaluated as in `database_update.cpp:115-131`). An entry runs once when the version bumps, so this check exists to make a manual re-run safe, not to retry by itself; the login fallback is the guarantee. |
| D22 | **Absolute exp writers set every row; delta writers route.** | `#set exp` is absolute (`gm_commands/set/exp.cpp:34-38`) and so are Perl and Lua `SetEXP` (`perl_client.cpp:273-280`); routing a delta into the lowest rows cannot land all four rows on one value. `SetLevel(command)`, `#set exp` and the quest `SetEXP` call one `SetAllClassExp(target)` first. Kills, quest `AddEXP`, rez, sacrifice and death loss are deltas and route. |

## 1. Thesis

Keep today's gestalt rule: **the character is every class in the bitmask at once.** Do not add an "active class" switcher.

Raise the cap from 3 to **4**. Persist **experience per class**. The number on the Inventory header (`Level: 65`) and every `GetLevel()` check is the level of the **lowest** class.

A class this character has **never** held starts at **1**. That drops the whole set to effective level 1 until that class reaches the **watermark** (the highest class level on the character). When every class is equal again they level in lockstep as they do today. Re-adding a class you previously removed resumes its stored exp.

Example the Inventory header must support:

```
Level: 65
PAL  LordProtector
DRU  StormWarden
BER  Fury
```

Player opens Hero and adds Enchanter. Header becomes:

```
Level: 1
PAL  LordProtector
DRU  StormWarden
BER  Fury
ENC  Enchanter
```

Paladin, Druid and Berserker keep their **titles at 65** because the client receives per-class levels (D11). Combat, zones, spells, skills, HP and the who-list treat the character as **level 1** until Enchanter hits 65. AAs, gear, the active pet and running buffs are kept (D4, D5, D16). Then the header is `Level: 65` with four classes and the set levels together again.

This is the Inventory class list (`IW_Level` / `IW_Class` / `IW_ClassAbbr` in `EQUI_Inventory.xml`), not character select.

## 2. Non-goals

- Per-class **switching** (one class live, others parked).
- Per-class **independent** adventuring.
- Raising character-select icon columns in the first ship. Tracked as a follow-up (§11.4).
- Deity or race re-checks when adding a class.
- Soft catch-up (header says 1 but you fight as 65). Rejected.
- A per-kill experience brake (D7).
- Supporting `Character:UseOldClassExpPenalties` (D19).

## 3. Player rules (locked)

| Rule | Value |
| --- | --- |
| Cap | 4 classes (`Custom:MaxMulticlasses`) |
| New class start level | 1 (`Custom:NewClassStartLevel`) |
| Effective level | level of the lowest-exp class in the bitmask |
| Watermark | level of the highest-exp class in the bitmask |
| XP routing | water-filling from the lowest rows (D2) |
| Race | No add-time lock; any race may add any class |
| Cannot remove | your last class (D8); any class whose exp is below the watermark |
| Can remove | any other class once caught up; the row is kept for resume |
| Cannot add | at the cap; a class already held; in combat, feigning or dueling; where zone `min_level` exceeds the start level (D10); while the old class-penalty rule is on (D19) |
| On add that lowers level | pet and buffs are kept (D16) |
| Confirm | single step, as today; the trainer hail text and the Hero tab state the cost up front |
| Group / raid / EoM / bots / merc | eligibility and re-level from the watermark (D6) |
| Losses | off the lowest rows, checked (D15); death loss is off by rule on this server |
| Existing characters at ship | every bitmask class is backfilled to `character_data.exp`. **No retroactive debt.** |

Adding the 2nd or 3rd class uses the same join-at-1 rule as the 4th. Guild trainers and the Hero tab are two doors into one function.

Escape hatch: you cannot drop the brand-new Enchanter to snap back to 65. That is intentional. You finish the catch-up or you live at 1. D10 exists because this is irreversible.

## 4. Data

Do **not** add `class2` / `class3` columns. The bitmask stays in `m_pp.classes` + bucket `GestaltClasses`.

New player-schema table (D1: no level column):

```sql
CREATE TABLE IF NOT EXISTS `character_class_exp` (
  `character_id` int(10) unsigned NOT NULL,
  `class_id`     tinyint(3) unsigned NOT NULL,
  `class_exp`    bigint(20) unsigned NOT NULL DEFAULT 0,
  PRIMARY KEY (`character_id`, `class_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```

**Manifest (D21).** Two entries in `database_update_manifest_custom.cpp`, at the next free versions after HEAD when implementation starts (28 and 29 at the time of writing; `CUSTOM_BINARY_DATABASE_VERSION` is 27). Both `content_schema_update` false. Merge-order note: entries 26 and 27 belong to other open branches; whichever lands last must renumber above the highest merged version, or servers already stamped at 29 will skip them.

1. *Create:* `check` = `SHOW TABLES LIKE 'character_class_exp'`, condition `empty`. SQL is the create above.
2. *Backfill:* `check` = a query that finds one character with a set bit and no row (join `character_data`, the `GestaltClasses` bucket decoded with a sixteen-row derived table, left join the new table where null, limit 1), condition `not_empty`. SQL is one `INSERT IGNORE … SELECT` of one row per set bit at the character's current exp, falling back to `character_data.class` when the bucket is missing. Runs once on the version bump; safe to re-run by hand; the login fallback below catches anything it missed.

**Login fallback:** where the bitmask is loaded (`client_packet.cpp:643`), any class bit without a row gets one inserted at the current exp.

**Caches.** `m_pp.exp`, `m_pp.level`, `character_data.exp`, `character_data.level` and `Mob::level` are caches of the trailing class. Login sets the pool from the rows. A crash mid-catch-up cannot forget the stored 65s because they are never in the pool. `m_pp.level2` is not a cache (D20).

Repository: `character_class_exp_repository.h` next to the other `character_*` repos. No raw SQL in zone call sites. Rows are written in the same `Save()` as the pool.

## 5. Seam

**Deep module:** `Client` owns the rows. Callers keep using `GetLevel()` / `HasClass()`. `SetEXP` is the only place that moves exp between rows and the pool.

```
uint8   Client::GetClassLevel(uint8 class_id) const;      // derived from the row
uint64  Client::GetClassExp(uint8 class_id) const;
uint8   Client::GetRewardLevel() const;                   // watermark; == GetLevel() when nothing is behind
bool    Client::IsCatchingUp() const;                     // any row below the watermark
int     Client::CanAddExtraClass(int class_id, bool join_at_watermark = false) const;  // 0 = ok, else reason enum
bool    Client::AddExtraClass(int class_id, bool join_at_watermark = false);
bool    Client::RemoveExtraClass(int class_id);
uint8   Group::GetHighestRewardLevel(); uint8 Raid::GetHighestRewardLevel();
```

Pure helper, unit-tested (D13): `RouteClassExp(std::vector<uint64>& rows, int64 delta, uint64 cap) -> uint64 new_min`.

`CanAddExtraClass` reasons, in order, all fail-closed: multiclassing off; class-penalty rule on (D19); class id outside 1–16; bit already set; popcount at `MaxMulticlasses`; `GetAggroCount() > 0`, feigning, or dueling; zone minimum level above the start level unless `join_at_watermark` (D10). `RaceNotAllowed` remains an unused reason code so script-facing values do not shift. `AddExtraClass` calls it first and also fails if the row insert fails.

On success, in this order so a set bit never exists without a row:

1. **Row first.** First time this class: insert a row at `GetEXPForLevel(NewClassStartLevel)`, or at the watermark's exp when `join_at_watermark` or `HeroCatchupEnabled` is off. Re-add of a class with a row: keep the row. If the insert fails, return false with nothing changed.
2. **Then bit and bucket.** If the bucket write fails, delete the row just inserted and return false.
3. Call `SetEXP` with the current pool value. The delta is zero, but routing returns the minimum row (§6), so the pool drops and the stock loop levels the character down and fires `EVENT_LEVEL_DOWN`. `SetEXP` has no early return on an unchanged value (`exp.cpp:1065-1067` only rejects an invalid curve).
4. `CalcBonuses()`, AA table refresh, guild roster update (existing `+1000` path), `SendBulkStatsUpdate()` (D11). Pet and buffs are not touched (D16).

`RemoveExtraClass`: reject if it would leave zero classes; reject if the row's exp is below the watermark. Otherwise the existing body runs (it already unscribes, ejects class-locked gear, refunds AAs, `client.cpp:14587-14653`) and the row is **kept**. Re-add does not restore spells or gear. Then `SetEXP` with the pool value so the new minimum takes effect.

`GetLevel()` stays `Mob::level`. Do not scatter `min()` at call sites.

## 6. XP

In `Client::SetEXP`, in this order (D3):

```
// after the Lua SetEXP hook and the group incentive bonus have adjusted set_exp
target  = ApplyExpClamps(set_exp, DeriveLevel(set_exp))    // extracted from the stock clamp block
delta   = int64(target) - int64(m_pp.exp)                  // signed
if (m_pp.exp != min(rows)) repair: m_pp.exp = min(rows)   // after the delta, see code comment
new_min = RouteClassExp(rows, delta, GetEXPForLevel(max level))   // delta 0 still returns min(rows)
set_exp = new_min                                          // pool becomes the trailing class
// stock derivation loop runs unchanged, calls SetLevel, fires events;
// the stock clamps run and are no-ops because every row is already capped
```

`RouteClassExp`, positive delta: sort rows ascending; take the set at the minimum; raise them together until they reach the next distinct value or the delta is spent; merge that value into the set; repeat. Negative delta: lower the minimum set, floor 0, never below any row that was already below. Cap every row at the max-level exp. With a zero delta it returns the current minimum, which is what makes add and remove work through the same call.

**Absolute writers (D22).** `SetAllClassExp(target)` sets every row to the clamped target and the pool with it; `SetLevel(level, true)` (`exp.cpp:1420-1421`), `#set exp` and the quest `SetEXP` call it. Everything that arrives through `AddEXP` is a delta and routes.

**AA XP** still uses the character AA pool. The per-kill AA cap scales with `GetLevel()/50` (`exp.cpp:984`), so a body at 1 earns almost no AA XP during catch-up. Accepted.

**`#level` and quest `level`** call `SetLevel(level, true)`, which becomes a `SetAllClassExp` (D22). Quest and Lua `SetLevel` on a client route to the same operation (D18).

**Login** sets the pool from the rows, then the stock path computes level.

**Losses** (D15) go through the same routing.

**Reward gates** (D6): `Group::GetHighestRewardLevel` replaces the effective-level max at `groups.cpp:1144-1156` and `raids.cpp:1107-1117` for XP splitting and for the Echo-of-Memory gate at `attack.cpp:3044-3074`; the member argument at `exp.cpp:1640` and `1684` is `GetRewardLevel()`. Awards still use `GetLevel()`. Bots and the merc read `GetRewardLevel()` at the four sites listed in D6.

## 7. Race (no lock)

Any race may add any class. The server had no add-time race check before this design, and existing characters already hold race-illegal combinations, so the owner dropped the proposed lock on 2026-09-06. The shared race helper remains for character creation only. `RaceNotAllowed` is kept as an unused reason code so script-facing values do not shift. Deity is ignored on add.

## 8. What the tax removes

| System | Behavior at effective level 1 | Change needed |
| --- | --- | --- |
| HP / mana / endurance | follow effective level | none |
| Spells / discs | ranks above effective level unusable, not unscribed | none; stock level gates |
| Buffs | running buffs keep their caster level until they expire; cannot be recast above level | none (D16) |
| Pets | the active pet stays at its level until it dies or is dismissed; resummon at level-1 ranks | none (D16) |
| Skills | **clamped** to the cap at effective level in `GetSkill`; raw for tradeskills and bind wound | clamp while `IsCatchingUp()`, caps cached per level change (D4) |
| AAs | every purchased rank keeps applying and activating | none (D4, owner decision) |
| Gear | stays equipped; `reqlevel` items lose bonuses and weapons hit for zero via stock | none (D5) |
| Zones / con / who | read effective level | none; D10 closes the trap |
| Group / raid / EoM share | eligibility on watermark | D6 |

`character_aa_disabled` stays a player toggle. `UseDynamicAATimers` stays on.

## 9. Custom rules

Add to `RULE_CATEGORY(Custom)` and cluster **Multiclass / client contract** in `clusters.json`. Regenerate with `python Release-NMS-Deploy/custom-rules/generate.py` and run `--check` before commit.

| Rule | Type | Default | Note |
| --- | --- | --- | --- |
| `MaxMulticlasses` | INT | `4` | Cap enforced in `CanAddExtraClass`; Perl reads it via `quest::get_rule`. |
| `HeroCatchupEnabled` | BOOL | `false` | Off (default): new classes join at the watermark and rows stay in lockstep. On: new classes start at `NewClassStartLevel` and catch up. |
| `NewClassStartLevel` | INT | `1` | Ignored when catch-up is off. |

All three are inert unless `MulticlassingEnabled` is true. Header note for the first: requires `Character:UseOldClassExpPenalties` false (D19).

## 10. Quest and plugin surfaces

`AddExtraClass` / `RemoveExtraClass` / `HasClassID` / `GetClassesBitmask` stay; `CanAddExtraClass` is new. Cap and catch-up live in C++; the only script-side affordance is `join_at_watermark` (D9).

Perl to update (D14, D17):

- `NMS_multiclass_utils.pl` — `AddClass` (313) checks the C++ boolean before ding, message, task update and announce; unique-combo (328) and `IsValidToAddClass` (453) read the rule and `CanAddExtraClass`. `AddClass` gains an optional third argument passed through as `join_at_watermark`. `RemoveClass` (336) already checks its boolean.
- `global/global_npc.pl` — guildmaster hail (34, 83): rule instead of `3`; the offer text states the cost up front; offered classes filtered by `CanAddExtraClass`. Single step, as today.
- `bazaar/Vision_of_Ayonae.pl` — random picks (61-69) come from classes with reason 0; the fill loop (77) reads the rule and passes the trusted flag; EoM charge, lockout and free-use bucket (280-294) apply only after a true result.
- `global/global_player.pl` — `EVENT_LEVEL_UP` (179-191): the max-level world announce keys on a per-character bucket so the fourth class reaching the cap does not announce twice. `CommonCharacterUpdate` re-runs `GrantClassesAA` on every ding (`NMS_multiclass_utils.pl:17`), so the catching-up class receives its ranks as it levels.
- `NMS_popup_utils.pl` (48) — "up to three classes" becomes the cap.
- Lua modules: `client_ext.lua` only decodes the bitmask; grep the Lua tree for a cap literal before shipping and expect none.

Perl helpers (thin wrappers): `plugin::GetClassLevel($client, $class_id)`, `plugin::GetRewardLevel($client)`, `plugin::IsCatchingUp($client)`, `plugin::CanAddClass($client, $class_id)`.

Unique-combo world announce fires when popcount first reaches the cap on a successful add. Same bucket scheme, key `class-<bitmask>`.

`QUEST-API.md` §0.1 / §0.2 and `CODEBASE.md` §3.1 are updated in the same change that ships the C++ cap.

## 11. Client

### 11.1 Inventory header

`IW_Level` (`EQType` 2) shows the pool's level; after sync it is the minimum.

`IW_Class` / `IW_ClassAbbr` (`EQType` 3 and `6666`) walk the bitmask from the stat map (`MQ2Labels.cpp:879-949`). Add sixteen keys `ClassLevel1..16` to the stat enum on both sides, **inserted before the terminal value**, and fix the sender loop to `1..statMax-1` (D11). `GetClassTitle` reads the class's own level from the map and falls back to spawn level when the key is absent. Old DLLs drop unknown keys, so a stale client shows level-1 titles and nothing breaks. `SendBulkStatsUpdate()` after every add or remove and on every ding while catching up.

Confirm the `CY` of those labels fits four lines; grow the label height if the fourth title clips.

### 11.2 Hero tab

Replace the unused **Shrouds** tab (`IW_AltCharProgPage`, `EQUI_Inventory.xml:9996-10003`). Do not add a sixth tab.

Page contents (ScreenIDs locked): `Hero_ClassList` (abbreviation, name, class level, tag), `Hero_Info` (STML: effective level, watermark, one sentence of the tax), `Hero_AddCombo` (classes with reason 0; disabled at cap or in combat), `Hero_AddButton` / `Hero_RemoveButton`. No confirm dialog; `Hero_Info` states the cost before the button is pressed.

Skins that ship `EQUI_Inventory.xml` stay in sync: `default/`, `gearcore/`, `shinsparxx/`, `Blue/`.

### 11.3 Wire

One new RoF2-only opcode in `emu_oplist.h` and the `#CUSTOM` block of `patch_RoF2.conf`, next free after `0x1409` (`patch_RoF2.conf:747`):

| Opcode | Direction | Role |
| --- | --- | --- |
| `OP_HeroRequest` `0x140A` | client to server | `op` = add / remove, `class_id` |

Server fail-closes every request with `CanAddExtraClass` and answers with `SendBulkStatsUpdate()` (D11). No server-to-client Hero opcode.

DLL: hook `CInventoryWnd::WndNotification` only for the Hero ScreenIDs. In-tab widgets, not a `CCustomWnd`.

`CAuth` / `ServerAuthStats` stay required. No Hero UI on a stock client.

### 11.4 Character select icons (follow-up)

`EQUI_CharacterListWnd.xml` has three icon columns and `GetItemIcon_Detour` is `col < 3` (`Hooks.cpp:787`). Not required to prove catch-up.

## 12. Phased delivery

1. **Server core:** rules, table, two manifest entries, login fallback, `RouteClassExp` with CLI tests, `SetEXP` ordering, `SetLevel(command)` row write, quest `SetLevel` routing, `CanAddExtraClass` and guards, reward-level helpers at the group, raid, EoM, bot and merc sites, skill clamp, stat keys plus the sender fix, `#hero` (D12, D13). Exercised with `#hero` and the existing trainer. Server rebuild.
2. **Perl:** rule-driven cap, result checks, Ayonae flag and filtering, announce bucket, helpers, popup line, docs (§10).
3. **Client header:** DLL enum and title resolver (§11.1).
4. **Hero tab and opcode** (§11.2, 11.3).
5. **Char-select fourth icon** (§11.4).

Phases 1 and 2 ship together.

## 13. Tests

Unit (CLI, `RouteClassExp`):

- `[65,65,65,1]` + gain below the gap: only the last row moves.
- `[65,65,65,64.9]` + gain past the gap: last row reaches the others, remainder splits four ways, rows stay equal.
- `[100,150]` + 100: result `[150,150]` with 50 left over applied to both, i.e. `[175,175]`.
- Three tiers `[10,20,30]` + large delta: fills 10 to 20, then both to 30, then all three.
- Negative delta on `[65,65,65,10]`: only the last row drops, floor 0.
- Any row above the cap is clamped; a gain at cap is a no-op.
- Zero delta on `[65,65,65,1]` returns the level-1 row's exp (the add and remove path).
- Pool repair: pool 65 with rows `[65,65,65,1]` is corrected to 1 before routing and logged.

Integration (`#hero`):

- Backfill: 3-class level 65 character produces three rows at 65 exp, effective 65, not catching up. Re-running the backfill entry inserts nothing.
- Add 4th: new row at level-1 exp, effective 1, watermark 65, four bits, pet and buffs still present, header titles still 65 for the old three.
- Add 5th, in combat, in a `min_level` 60 zone, with the old class-penalty rule on: each rejected with its reason.
- Remove the new class at 1: rejected. Remove the last class: rejected.
- Remove a caught-up non-last class: allowed; effective stays 65; row kept; re-add resumes at 65 with no debt.
- XP while behind: only the trailing row moves. XP when equal: all four move.
- Group: level-1 body in a group of 65s receives a share; a group of four catching-up bodies still receives shares; EoM eligibility matches.
- `#level 65`, `#set exp <n>` and a quest `SetLevel(65)` mid-catch-up: all four rows land on the same exp.
- Add with a failing row insert (simulated): bit and bucket unchanged, returns false.
- Skills: while behind, a 250 skill reports the level-1 cap and returns when caught up; tradeskills unchanged. AAs: a 65-only rank still applies and activates at effective level 1.
- Stats packet: count equals the number of real keys, key 0 absent, last key present.
- `HeroCatchupEnabled false`: add joins at 65, four rows at 65.
- Ayonae reroll on a 65: new random classes join at 65; a failed add charges nothing.

## 14. Why this shape

| | A. Cap 4 only, shared level | B. Full class switcher | **C. This spec** |
| --- | --- | --- | --- |
| Play model | All classes live, one level | One live class, per-class levels | All classes live, effective = lowest |
| Add 4th | Instant 65 Enc | Enc 1 you switch to | Enc 1 downlevels the body |
| Code blast | Small | Rewrites `HasClass` meaning | One table, one routing helper in `SetEXP`, one skill clamp, reward-level helpers |
| Tax | None | Optional | Hard catch-up |

C matches the Inventory header the player pointed at and gives a real cost to widening the set, while riding the stock leveling engine instead of replacing it.

## 15. CODEBASE.md delta (when implementing)

Replace "up to **3** classes" in §3.1 with the rule name, point at `character_class_exp` and `RouteClassExp`, and name the three rules. Add gotchas: the exp pool is a cache of the trailing class and is only written by `SetEXP` and `SetLevel(command)`; `level2` is the high-water level, not the effective level; the stats sender's key range.

## 16. Out of this spec

`nmsloot` (not in repo). Welcome-popup expansion sentence. Soft catch-up. Combat class swapping. Per-kill experience brake. The old class-penalty exp rule.
