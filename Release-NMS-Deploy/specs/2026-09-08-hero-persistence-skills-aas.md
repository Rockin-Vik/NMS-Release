# Skills and AAs persist through the level-1 reset and across class drops

Status: draft v2 for review, 2026-09-08. Second item under the hero class-switching decision (local ADR-0002, rules 2, 3 and 5, plus the level-drop side effects under rules 1, 4 and 8). Lands after the AA reuse timer spec (`2026-09-08-aa-reuse-timer-ids.md`), which is itself NO-GO until its client spike runs; the one sentence here that depends on that spike's outcome is marked in D7. Not built. v1 was verified by three independent readers against the tree; every confirmed finding is folded in.

## 1. Problem

A 70 SHD/MNK/BER adds a Warrior. Under rule 1 the hero is now level 1. What the player loses today, and what the decision says must be kept:

- **Every skill reads at the level-1 cap.** The stored values are untouched, but `Client::GetSkill` (`zone/client.cpp` 15174-15196) clamps every read to `MaxSkill(skill, class, hero level)` whenever the held class rows differ (`IsCatchingUp`, `zone/exp.cpp` 1828). It overrides `Mob::GetSkill` (`zone/mob.h` 577), so combat, skill checks and the "You have become better" message all see the clamped number. A 250 Monk skill swings as a 5. This is the "skill cap clamp applied when the level drops" that rule 2 forbids.
- **Dropping a class zeroes its skills.** `RemoveExtraClass` writes 0 to every skill no remaining class can hold (`client.cpp` 15104-15109), persists it, and sends "You have lost access".
- **Dropping a class refunds its AAs from memory, and the rows survive by accident.** `RefundUnusuableAA` (`zone/aa.cpp` 909-951, sole caller `client.cpp` 15139) erases from the in-memory `aa_ranks` every rank the remaining classes cannot use and returns its points. It never deletes a row: `SaveAA` (`client.cpp` 989-1030) only `REPLACE`s (`ReplaceMany`, 1030) and nothing on the drop path deletes. So today a shelved class's rows are still in `character_alternate_abilities` while its points have been refunded, and re-adding the class loads the rows again (`LoadAlternateAdvancement(Client*)`, `aa.cpp` 1836-1846, filtered by `CanUse`): the player gets the ranks back **and** kept the refund. Live characters that have dropped and re-added a class have double-counted points.
- **The AA reset deletes shelved ranks without refunding them.** `Client::ResetAA` (`aa.cpp` 548-573) calls `RefundAA` (870-906, refunds only ranks in memory, i.e. held classes) and then `DeleteCharacterAAs` (`zonedb.cpp` 1300-1309, `DELETE ... WHERE id = character`), which removes **every** row including the shelved ones. Callers: `#resetaa` (`gm_commands/resetaa.cpp` 21), `Handle_OP_ResetAA` (`client_packet.cpp` 16381-16387, Guide status and above), the Perl and Lua exports (`perl_client.cpp` 612, 1248; `lua_client.cpp` 669, 1321), the Vision of Ayonae's free and paid AA reset (`Vision_of_Ayonae.pl` 121, 259) and `AA_EndlessQuiver.pl` 4. The Ayonae path is player-reachable: a hero that resets its AAs loses every shelved class's ranks for nothing.
- **The plugin zeroes Tracking** whenever no held class has a Tracking cap at the current hero level (`NMS_multiclass_utils.pl` 44-48), which under rule 1 is after every add.

Two corrections to the decision record, both now written into it: `CanUseAlternateAdvancementRank` (`aa.cpp` 1950-2091) never checks `level_req`; the only level gates are purchase (`aa.cpp` 2132), auto-grant (2629, 2691) and bots. Activation (1604-1630) and passive bonuses (`zone/bonuses.cpp` 608-625) have no level gate, so rule 2 for AA use already holds **on the server**. Whether the RoF2 client refuses to fire an owned rank whose `level_req` (sent at `aa.cpp` 1042) is above the hero level is unproven; §4 step 1 settles it and D7 names the fallback.

### 1.1 Every path that lowers a skill value

| Site | Trigger | Today | This spec |
| --- | --- | --- | --- |
| `client.cpp` 15174-15196 `Client::GetSkill` | every read while catching up | clamps the returned value to the hero-level cap (not persisted) | remove (D1) |
| `client.cpp` 15104-15109 `RemoveExtraClass` | class drop | `SetSkill(skill, 0)` for every `!CanHaveSkill` skill; persists | remove (D2) |
| `NMS_multiclass_utils.pl` 44-48 `CommonCharacterUpdate` | zone-in, connect, level-up, after `AddClass` | `SetSkill(53, 0)` when `MaxSkill(Tracking) == 0` | remove (D2) |
| `client.cpp` 4300-4390 `GetMaxSkillAfterSpecializationRules` | any cap query **on a Specialize skill** (guard at 4310) | resets all five Specialize skills to 1 when more than `MaxSpecializations` exceed 50 | bypass the reset, keep the cap (D4) |
| `client.cpp` 3036-3043 `AddSkill` | `quest::addskill` (`questmgr.cpp` 1527), Perl/Lua `AddSkill` (`perl_client.cpp` 542, `lua_client.cpp` 616) | `raw + add` clamped to the hero-level cap, which can be below a raw value carried from 70 | never below raw (D3) |
| `gm_commands/set/level.cpp` 40-44 `#set level` | GM command | lowers every skill above `MaxSkill` at the new level | gate on multiclass (D5) |
| `client.h` 1060 `IncreaseSkill` (Perl 500-507, Lua 574-581) | explicit script write, signed value, no cap, no save, no packet | a negative value lowers the in-memory value | unchanged; explicit write |
| `questmgr.cpp` 1551, 1561; `perl_client.cpp` 537; `lua_client.cpp` 611 `SetSkill` | explicit script write | any value | unchanged |
| `soltemple/Ostorm.pl` 33-37 | stock quest, Ruby hand-in | lowers the five Specialize skills to 49 | unchanged; the player's deliberate specialization reset |
| `gm_commands/set/skill.cpp` 27, `skill_all.cpp` 33 | explicit GM command | any value up to the cap | unchanged |

Checked and only raise: `CheckIncreaseSkill` (`client.cpp` 4052-4093), the trainer (`client_process.cpp` 2119-2208), `MaxSkills` (`client.cpp` 14124-14152, a no-op: `highestSkillCap` is never assigned), the plugin's level-1 fill (`NMS_multiclass_utils.pl` 59-62), `Zapf.pl` 55-59, character creation (`world/client.cpp` 2402). `Client::SetLevel` (`exp.cpp` 1430-1566) reads or writes no skill. `LoadCharacterSkills` (`zonedb.cpp` 726-742) copies `character_skills` verbatim, so a value above the cap already survives login.

### 1.2 Every AA refund, delete and level-check path

| Site | Today | This spec |
| --- | --- | --- |
| `aa.cpp` 909-951 `RefundUnusuableAA` (sole caller `client.cpp` 15139) | erases held-but-unusable ranks from memory, refunds `total_cost`; rows survive | remove call and function (D7) |
| `aa.cpp` 548-573 `ResetAA` → `RefundAA` (870-906) + `DeleteCharacterAAs` (`zonedb.cpp` 1300) | refunds held ranks only, deletes **all** rows | refund from every row before deleting (D8) |
| `aa.cpp` 2132 `CanPurchaseAlternateAdvancementRank` | refuses to buy when `level_req > GetLevel()` | unchanged; rule 2 puts the level gate on buying |
| `aa.cpp` 2629, 2691 auto-grant | grants only `level_req <= level` | unchanged |
| `aa.cpp` 1604 activation; `bonuses.cpp` 608-625 `CalcAABonuses` | no level test | unchanged on the server; client behaviour verified in §4 |
| `aa.cpp` 1807-1849 `LoadAlternateAdvancement(Client*)` | `ClearAAs()` then loads each row whose current rank passes `CanUse`; writes `aa_array` slots 0..n-1 without zeroing the tail | becomes the shelving mechanism (D7), with a `memset` first |

### 1.3 What a level drop already does (rules 1, 4, 8)

Adding a class drags the pool to the new row and runs a zero-delta `SetEXP` (`client.cpp` 15046-15050), which lowers the level through the stock loss loop (`exp.cpp` 1232) and `SetLevel`. D10 lists what that touches.

## 2. Decision

Skills and AA ranks are records of what a class earned. They are written by play and by explicit GM or script commands only. No level change and no class change ever lowers a skill value or removes a rank. While a class is held its skills and ranks work at any hero level. While it is shelved they stay in the database, are not loaded into the parts of memory that apply them, are hidden from the client, and come back on re-add without a re-zone. A reset that deletes rows refunds every row first.

### D1 — No skill clamp on read (rule 2)

`Client::GetSkill` returns the raw value plus item skill mods and nothing else. Lines 15181-15196 go, with the cache members `m_catchup_skill_caps`, `m_catchup_skill_caps_level`, `m_catchup_skill_caps_valid` (`zone/client.h` 2416-2418) and the two invalidations (`client.cpp` 15049, 15097). `IsCatchingUp` stays for the stats push (`exp.cpp` 1562) and the Perl/Lua exports (`perl_client.cpp` 2247, `lua_client.cpp` 228-230). `GetRawSkill` (`client.h` 1063) was never clamped.

### D2 — No zeroing on class drop (rules 2 and 5)

- `RemoveExtraClass`: delete the loop at `client.cpp` 15104-15109. Values stay in `m_pp.skills` and `character_skills`.
- Plugin `CommonCharacterUpdate`: delete the `SetSkill($i, 0)` branch at `NMS_multiclass_utils.pl` 47-48. The raise to base cap at 49-51 stays.

`CanHaveSkill` (`client.cpp` 4233: any held class has a cap above 0 at `Character:MaxLevel`) is the "usable while held" test. After the loop is gone, `HasSkill` (4230) returns false for a shelved class's skill even though its value is non-zero, which is rule 5's "kept, not usable". `SetSkill` (2988) stays the single write primitive.

### D3 — Raising follows the stock cap at the hero level, best held class (rule 2)

`MaxSkill` (`client.cpp` 4252-4272) already takes the highest cap over all held classes at the hero level, and `CheckIncreaseSkill` compares the raw value against it. A level-1 hero gets no skill-ups on a 250 Monk skill until the hero level passes 250 again; nothing is lowered. No code.

One guard: `AddSkill` (`client.cpp` 3036-3043) computes `raw + add` and clamps to the cap; when the raw value is already above the cap the clamp lowers it. Change the clamp to `std::max(max, GetRawSkill(skillid))`. It is reached only through `quest::addskill` and the Perl/Lua `AddSkill` exports; no script in the tree calls them.

The plugin's level-1 fill (`NMS_multiclass_utils.pl` 59-62) raises held-class skills below 50 to the level-1 cap on every zone-in after an add. It only raises and stays. §4 step 1 accounts for the rows it writes.

### D4 — Specialization reset (rule 2)

Stock resets all five Specialize skills to 1 when more than `MaxSpecializations` (1, or 2 with Secondary Forte, `client.cpp` 4306) exceed 50, from any cap query on a Specialize skill (`SetSkill` 3000, `AddSkill` 3040, `CheckIncreaseSkill` 4053, trainer `client_process.cpp` 2191 and 2223, GM train list `client_process.cpp` 1998 and 2012). A hero that held a Wizard (evocation) and a Cleric (alteration) trips it and loses both.

Under `Custom:MulticlassingEnabled` the reset branch (4365-4383) does not run. Because the 50 / 100 caps are assigned only inside the `count <= MaxSpecializations` branch (4344-4363), a bare bypass would leave every specialization uncapped. So the bypass also assigns the cap: `Result = 50` for any specialization that is not the primary one (100 for the Secondary Forte skill), the same values the normal branch uses. Raising a second specialization above 50 is therefore still refused without Secondary Forte, and values already above 50 are never lowered. **Owner decision:** whether the raise cap should instead count specializations per held caster class (a WIZ/CLR hero could then raise two). The default is the smaller change.

### D5 — GM `#set level` (rule 2, scoped to heroes)

`set/level.cpp` 40-44 lowers every skill above the new level's cap after `SetLevel(level, true)`, which also rewrites every class row (`exp.cpp` 1513-1514). Gate the clamp loop on `!IsCatchingUp() && held classes == 1`, so a GM who types `#set level 1` on a hero does not wipe its skills, while a single-class character keeps stock behaviour. `#set skill` remains the explicit way to lower one.

### D6 — Shelved skills on the wire (rule 5)

The client greys a skill when the server sends `0xFFFFFFFF`. Today that happens only for zero-valued `!CanHaveSkill` skills (profile at `zone/client_packet.cpp` 1834-1837; `SetSkill` packet at `client.cpp` 2997). With D2 a shelved class's skill is non-zero and would be sent as its real number while `HasSkill` says unusable.

Both sites send `0xFFFFFFFF` for any `!CanHaveSkill` skill regardless of value. Packet-only. Add `Client::SendSkillValues()` that sends one `OP_SkillUpdate` per skill (`CanHaveSkill ? raw : 0xFFFFFFFF`), called at the end of `AddExtraClass` and `RemoveExtraClass`, so the skill window greys and un-greys without a re-zone. Whether the client flips a greyed skill back to a number on that packet is **not** proven by the trainer (it refuses `!CanHaveSkill` skills at `client_process.cpp` 2119-2122, so its packet never crosses that boundary); it is proven today only by the zeroing path (`client.cpp` 15107 → 2997, grey) and by a re-zone (un-grey). §4 step 6 tests the un-grey without a re-zone; if the client ignores it, the fallback is the profile resend the stock `#set level` path already performs. **Owner decision:** show the real number instead of greying (drop the packet change, keep the resend).

### D7 — AA ranks: no refund, shelved rows evicted from memory, reloaded on re-add (rules 2, 3, 5)

`RemoveExtraClass` stops calling `RefundUnusuableAA`; the function and its declaration (`client.h` 1266) go. `RefundAA` stays as the deliberate full refund used by `ResetAA`.

In-memory model: **shelved ranks are not in `aa_ranks`.** After `m_pp.classes` is narrowed (15096) or widened (`AddExtraClass`): `memset(&m_pp.aa_array[0], 0, sizeof(AA_Array) * MAX_PP_AA_ARRAY)` (as `ResetAA` does at `aa.cpp` 553; the loader never zeroes the tail), then `database.LoadAlternateAdvancement(this)` (`aa.cpp` 1808: `ClearAAs()` then reload every row whose current rank passes `CanUse` under the new bits), then `CalcBonuses()`, then `SendClearPlayerAA()`, `SendAlternateAdvancementTable()`, `SendAlternateAdvancementPoints()`, `SendAlternateAdvancementStats()`. `RemoveExtraClass` already sends those four (15141-15144); `AddExtraClass` today sends only the table (15052) and gains the other three, or a re-added class's ranks reappear in the window without their spent-points total and passive bonuses updating until the next re-zone. In `RemoveExtraClass` the reload must precede the `CalcBonuses()` at 15101.

Why this model and not a filter in `CalcAABonuses`: `bonuses.cpp` 608-625, `SendAlternateAdvancementPoints` (`aa.cpp` 1142-1155) and `SaveAA` (`client.cpp` 989-1030) all iterate `aa_ranks` with no class filter; evicting once is one change. It is what a re-zone does (`client_packet.cpp` 1652). `SaveAA` uses `REPLACE` and never deletes; the only per-row delete is `RemoveExpendedAA` (`client.cpp` 1033-1042). Rows not in memory are untouched by every save cycle. That holds today; only `ResetAA` (D8) breaks it.

Consequences stated plainly:

- `m_pp.aapoints_spent` is recomputed from loaded ranks (`client.cpp` 997-1020), so the client's spent total counts held classes only. Unspent points are untouched by a drop. **Owner decision:** acceptable (default), or count shelved rows too.
- The AA window and `#aa list` (`aa.cpp` 2742) do not show shelved ranks. They are absent, and back on re-add.
- Rule 3 needs no code: the row is keyed `(id, aa_id)` with no class column; `CanUse` intersects the ability mask with all held bits (`aa.cpp` 1982); prerequisites read `aa_ranks` regardless of which class bought them (2172-2184). Combat Fury bought as a Warrior stays loaded when the Warrior is dropped and a Shadow Knight is held. One edge, accepted and recorded: Fury of Magic ranks 7+ are restricted to pure-caster bits (`aa.cpp` 1963-1977) and the loader tests only the current rank, so a Wizard-bought rank 7 is shelved entirely while only a Cleric is held rather than falling back to rank 6.
- **Live repair.** Characters that dropped and re-added a class under the old code hold rows that were refunded. There is no way to tell those rows from honestly bought ones after the fact. Accepted: the points stand. Recorded here so nobody files it as a new bug.
- **Client refusal (§4 step 1).** If the RoF2 client refuses to fire an owned rank whose sent `level_req` is above the hero level, the fallback is to send `level_req = 1` for **owned** ranks in `SendAlternateAdvancementRank` (precedent: the same function already rewrites fields per ability at `aa.cpp` 1112-1116). Unowned ranks keep the real requirement so the purchase gate still reads right.
- **Timer interplay.** The timer spec's M6 stops `ClearDynamicAATimers()` in `RemoveExtraClass`; evicted ranks keep their timer rows and running cooldowns. If that spec's spike selects Option A (ids allocated on first activation), nothing here changes; under Option B (ids at table send for owned ranks) the reload here triggers allocation for re-added ranks, which is that spec's M8 case. This is the one sentence blocked on the timer spike.

### D8 — `ResetAA` refunds every row before it deletes (rules 2 and 5)

`Client::ResetAA` (`aa.cpp` 548-573) on a character with `Custom:MulticlassingEnabled`: before `RefundAA`, load every `character_alternate_abilities` row for the character **without** the `CanUse` filter (a new `ZoneDatabase::LoadAllAlternateAdvancement(Client*)` or a repository read), sum `total_cost` of each row's rank into the refund, then proceed to `DeleteCharacterAAs` as today. The refund equals what was paid for held and shelved ranks alike. All nine callers (§1) inherit it. The Ayonae AA reset copy (`Vision_of_Ayonae.pl` 240-263) does not change.

### D9 — Player-reachable level set (rule 1, owner decision)

`Vision_of_Ayonae.pl` 200-227 (`confirm_level_change_N`) lets a player pay 500 platinum per level to `SetLevel($desired_level, 1)` back to a stored `MaxLevelAchieved`. `SetLevel(level, true)` calls `SetAllClassExp` (`exp.cpp` 1513-1514, 1875-1888), which writes **every** class row, shelved ones included, to the new level. On a hero that breaks rule 5 (a shelved 70 becomes whatever was bought) and rule 1 (the pool is no longer the lowest held class). Default: refuse the Ayonae level change for a hero holding more than one class with a one-line message, and leave `SetAllClassExp` as the GM tool it is. **Owner decision:** instead make `SetAllClassExp` write held rows only under multiclassing.

### D10 — Level-drop side effects: change or accept

| Effect | Where | This spec |
| --- | --- | --- |
| Skills read at level-1 caps | `client.cpp` 15174 | changed (D1) |
| Skill-ups refused on skills above the hero-level cap | `client.cpp` 4052 | accepted (rule 2) |
| AA passives and activations keep working server-side | `bonuses.cpp` 608; `aa.cpp` 1604 | accepted; client verified in §4 |
| Buying a rank refused below `level_req` | `aa.cpp` 2132 | accepted (rule 2) |
| AA exp keeps flowing at level 1 | `exp.cpp` 1032-1038, 1402 | accepted |
| Spellbook: unscribed on drop, re-scribed from the learned table on re-add | `client.cpp` 15111 → `ReconcileLearnedSpells` 13381-13475 | accepted; this is rule 5's shelving for spells and already exists |
| Memorizing gated at the hero level | `client_process.cpp` 1473, 1500 | accepted (rule 4) |
| **Spells already in gems stay castable at level 1** | `Handle_OP_CastSpell` (`client_packet.cpp` ~4659-4800) has only an item-click level test; `Mob::CastSpell` none; `Client::CanCastSpell` (`client.cpp` 15579) has one caller, the GM `#castspellnms` | **changed (D11)**: rule 4 says spells follow the current level |
| Buffs from 70 stay; `BuffFadeAll` on class drop | `spells.cpp` 3807; `NMS_multiclass_utils.pl` 389 | drop the `BuffFadeAll` (rule 6: no penalty on switching; buffs are not "earned" but wiping them is a cost). **Owner decision** to keep it |
| HP clamped (or healed under `Character:HealOnLevel`), mana and endurance set to the new maximum | `exp.cpp` 1535-1553; `client_mods.cpp` 1620-1628 | accepted (rule 8) |
| Combat formulas that read the hero level, not the skill | `attack.cpp` 1169 (Monk/Beastlord hand-to-hand at 30+), 1288 (30+), 1719 (Warrior main-hand bonus at 28+), 4268 (triple attack at 60+), 4322 (35+), 5709-5711 (12+) | accepted (rule 8): a level-1 hero swings with maxed skills but without the level-gated formulas; listed so the owner sees the whole list |
| Pets survive; removed on a class drop only if no held class can summon them | `client.cpp` 15125-15130 | accepted |
| No training points on the climb back (`level2` watermark stays 70) | `exp.cpp` 1470 | accepted |
| `EVENT_LEVEL_DOWN` fires; no handler | `exp.cpp` 1495 | accepted |
| Death costs no exp at level 1; losses land on the trailing row only | `attack.cpp` 2096; `class_exp_routing.cpp` 40 | accepted |
| GM `#level` / `#set level` rewrite every class row including shelved ones | `exp.cpp` 1513-1514 | accepted, GM tool; D9 covers the player door |
| Con colours, kill exp, reward level | `exp.cpp` 203, 989, 1793 | accepted (rule 8) |
| Zone minimum level | `zoning.cpp` 1443; `client.cpp` 14930-14937 | gates spec |

### D11 — Gems follow the level (rule 4)

On any level decrease for a hero (`SetLevel` when `set_level < GetLevel()` and more than one class is held), unmemorize every gem whose spell requires, for **every** held class, a level above the new one (`spells[id].classes[class - 1] > level` for all held classes), sending the stock unmemorize packet per gem. The spellbook is untouched. Add the same test to `Handle_OP_CastSpell` for gem casts so a stale client gem cannot cast, with the stock "You must be level N" style message. Re-memorizing is already gated (`client_process.cpp` 1473, 1500). **Owner decision:** none; rule 4 is explicit.

### D12 — Sizing (rules 2 and 5, the cost)

Reproducible from `Release-NMS-Deploy/research/aa_persistence_census.py` (stock dump, `enabled = 1`, `status = 0`, category not shroud, class mask `1 << (class_id - 1)`; race, deity, heritage and expansion not applied):

| Held classes | Abilities usable | Ownable with a rank at level ≤ 70 | Rank steps ≤ 70 | Points to buy every rank ≤ 70 |
| --- | --- | --- | --- | --- |
| MAG alone | 274 | 166 | 665 | 3,517 |
| SHD / MNK / BER | 433 | 225 | 974 | 4,906 |
| SHD / MNK / BER / WAR (the test hero) | 521 | 249 | 1,037 | 5,263 |
| CLR / SHD / MNK / BER | 547 | 262 | 1,125 | 5,718 |
| ENC / MAG / NEC / DRU (four largest) | 593 | 278 | 974 | 5,078 |
| Every class ever held (DB rows only under D7) | 1,544 | 576 | 2,112 | 10,855 |

Widths and limits:

| Field | Width or limit | Where |
| --- | --- | --- |
| `character_alternate_abilities.aa_id`, `aa_value`, `charges` | smallint unsigned | repository header 21 |
| `character_data.aa_points`, `aa_points_spent`, `aa_exp` | int unsigned | `base_character_data_repository.h` 61 |
| `PlayerProfile_Struct` `aapoints`, `aapoints_spent`, `expAA` | uint32 | `eq_packet_structs.h` 1171-1173 |
| `AltAdvStats_Struct.unspent` (`OP_AAExpUpdate`) | uint16 | `eq_packet_structs.h` 5514 |
| `AA:UnusedAAPointCap` | 100 compiled; live value unread | `ruletypes.h` 1016; `exp.cpp` 1022-1029 |
| `pp.aa_array` and `aa_list` | `MAX_PP_AA_ARRAY = 240`, no bounds check at either writer | `eq_packet_structs.h` 955; `aa.cpp` 1152, 1839 |
| RoF2 wire block | 300 slots: 240 copied, 60 zero | `patches/rof2.cpp` 2651-2660 |
| Client owned list | `AA_CHAR_MAX_REAL = 300` | `EQData.h` 752, 1059 |

Points fit everywhere. The binding number is **distinct owned abilities loaded at once**: every four-class combination can own 249 to 278 at level 70, above the server's 240 and below the client's 300. So this spec **raises `MAX_PP_AA_ARRAY` to 300** (the RoF2 encoder already writes 300 and only RoF2 is served; every patch encoder that copies the constant is checked in the build) and adds a bounds check at both writers that **skips only the `aa_array` write** past the limit; `SetAA` (`aa.cpp` 1843) still runs for every row so `CalcAABonuses` applies them. One error line names the character and the count. Rule 2 then holds in full for any four-class hero at 70; it is stated plainly that a hero above 300 owned abilities (only reachable with five or more classes, or a bigger catalog) would have a short client list.

## 3. Spike

None beyond §4 steps 1 and 6, which are the two client behaviours the tree cannot prove (activation above `level_req`; un-grey without a re-zone). Both have a stated fallback in D6 and D7 and do not block the build.

## 4. Verification (in game, 70 SHD/MNK/BER adding WAR, catch-up on)

Before: record `character_skills`, `character_alternate_abilities` (`aa_id`, `aa_value`, `charges`) and `aa_points` / `aa_points_spent` for the character. Note one Monk-only skill at its 70 value (Flying Kick), one Monk-only rank with `level_req >= 51`, one shared AA (Combat Fury), and that Tracking is 0.

1. Add WAR at the guildmaster. **Expect:** level 1; no skill value lower than baseline (rows for skills below 50 with a Warrior level-1 cap may be added or raised by the plugin fill); the skill window shows the 70 values without a re-zone; `#showstats` HP and mana at level-1 values; AA rows and points unchanged. Then activate the Monk-only `level_req >= 51` rank from the window and from a hotbutton. **Expect:** it fires. If the client refuses, apply the D7 fallback and re-test.
2. Fixed-target combat check: 50 swings at a training dummy at 70 before the add and 50 at level 1 after. **Expect:** hit rate within noise, damage lower only by the level-gated formulas in D10 (no Monk hand-to-hand bonus below 30), no "You have become better" line on any skill above its level-1 cap.
3. Try to buy a Warrior rank with `level_req` above 1. **Expect:** the level refusal. Buy the next rank of Combat Fury with `level_req` 1. **Expect:** purchasable, owned for every held class.
4. Drop MNK. **Expect:** `character_skills` unchanged; Monk-only skills greyed without a re-zone; Monk-only AAs absent from the window; row count unchanged; `aa_points` unchanged; the Monk passive's contribution gone from `#showstats`; Combat Fury still owned; buffs still up (D10 default); no "You have lost access" lines; gems above level 1 unmemorized (D11).
5. Camp and log back in. **Expect:** identical state.
6. Re-add MNK. **Expect:** Monk skills un-greyed at their recorded values without a re-zone (if greyed until a re-zone, apply the D6 fallback); Monk AAs back as owned, no points charged; `aa_points_spent` back to baseline; a Monk ability activates.
7. `#resetaa` on the hero with MNK shelved. **Expect:** `aa_points` rises by the sum of held **and** shelved ranks' costs; all rows gone (D8).
8. Ayonae `confirm_level_change` on the hero. **Expect (D9 default):** refused with the message; class rows untouched.
9. GM `#set level 5` on the hero. **Expect (D5):** level 5, skills unchanged. On a single-class character: stock clamp still runs.
10. CLR/WIZ hero with two specializations above 50: buy one point **in a specialization skill** at a trainer. **Expect (D4):** no reset message, both values kept, a third specialization cannot be raised past 50.
11. Log check: no `MAX_PP_AA_ARRAY` line. Then a GM-granted 290 owned abilities. **Expect:** all 290 in the client list (300 limit), passives applied.

Local, before any of that: `build zone` (and `world`, for the constant) green on the README toolchain; the adversarial handoff on the diff; every caller of `RefundUnusuableAA`, `ResetAA`, the `GetSkill` cache members, `CanHaveSkill` at the two packet sites, `SetAllClassExp` and the plugin's Tracking branch listed in the PR body with what each became.

## 5. Files

- `Release-NMS-Server/zone/client.cpp`: `GetSkill` (15174-15196); `RemoveExtraClass` (delete 15097, 15104-15109, the `RefundUnusuableAA()` at 15139; memset + reload before `CalcBonuses()` at 15101; `SendSkillValues()` at the end); `AddExtraClass` (delete 15049; memset + reload before `CalcBonuses()` at 15051; the three extra sends; `SendSkillValues()`); `AddSkill` (3040-3042); `GetMaxSkillAfterSpecializationRules` (4344-4383 bypass with cap); `SetSkill` (2997); new `SendSkillValues()`.
- `Release-NMS-Server/zone/client.h`: remove 2416-2418 and the declaration at 1266; declare `SendSkillValues`; `HasMultipleClasses()` if the gates spec has not landed it first.
- `Release-NMS-Server/zone/aa.cpp`: delete `RefundUnusuableAA` (909-951); `ResetAA` refund-from-rows (548-573); bounds checks at 1152 and 1839; optional `level_req` fallback in `SendAlternateAdvancementRank` (§4 step 1).
- `Release-NMS-Server/zone/zonedb.cpp`: `LoadAllAlternateAdvancement` (unfiltered read) next to 1300.
- `Release-NMS-Server/zone/exp.cpp` `SetLevel`: D11 gem unmemorize on decrease.
- `Release-NMS-Server/zone/client_packet.cpp`: 1834-1837 (`0xFFFFFFFF` for every `!CanHaveSkill`); `Handle_OP_CastSpell` gem level test (D11).
- `Release-NMS-Server/zone/gm_commands/set/level.cpp` 40-44: gate the clamp (D5).
- `Release-NMS-Server/common/eq_packet_structs.h` 955: `MAX_PP_AA_ARRAY = 300`; every patch encoder that copies it re-checked.
- `Release-NMS-Plugins/NMS_multiclass_utils.pl`: 47-48 (Tracking zero), 389 (`BuffFadeAll`, D10 default).
- `Release-NMS-Quests/bazaar/Vision_of_Ayonae.pl` 200-227: hero refusal (D9 default).
- `Release-NMS-Deploy/research/aa_persistence_census.py`: the sizing query (this PR).
- `Release-NMS-Deploy/CODEBASE.md`: one paragraph in the hero section on what a shelved class keeps and where it lives.
- No client add-on change, no migration, no rule change, no schema change.

## 6. Not in this spec

- Switching gates: `ZoneTooHigh`, `CanEnterZone`, the paid and free removal paths, announcements, and every player-facing string at the three doors including `plugin::RemoveClass`'s "lost access" line and the Hero tab info text (the gates spec owns all copy).
- AA reuse timer ids and `ClearDynamicAATimers` (the timer spec; lands first).
- The placeholder level-80 ranks (ADR-0001 catalog pass).
- Fixing `Client::MaxSkills` (`client.cpp` 14124-14152), a no-op today.
- Per-class exp rows: already shelved and restored by `LoadClassExp` (`exp.cpp` 1994).
- Reading the live `AA:UnusedAAPointCap` from `rule_values` (pending live-DB checks).
- The double-counted points on live characters that dropped and re-added a class under the old code (accepted, D7).
