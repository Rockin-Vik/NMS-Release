# Switching gates: free, instant, out of combat only, no announcements

Status: **v4, built on branch `aa-reuse-timers` (2026-09-09)**; the second adversarial review of v3 (three agents, GO-WITH-FIXES, twelve findings) and the code review of the diff are folded in; the in-game pass of section 4 is recorded in the PR body. Third item under the hero class-switching decision (local ADR-0002, rules 6 and 7, and the owner's 2026-09-08 decision that first-of-a-kind announcements stop firing). The AA reuse timer change (PR 21) and the skills + AAs persistence change (PR 20) are both on main and verified in game, so a dropped class keeps everything and the "kept" copy below is true. The currency was renamed Emperor's Favor → Emperor's Favor on main in between; this spec uses the new name. v1 was verified by three independent readers against the tree; v2 went through a twelve-agent adversarial review; v3 through a three-agent one. Line anchors were re-read against main 618a2cf7.

## 1. Problem

Switching a class today runs through four gates that rule 6 says should not exist, and one zone rule that rule 7 says should not apply to a hero:

| Gate | Where | Value today | Under ADR-0002 |
| --- | --- | --- | --- |
| Removal fee | `NMS_multiclass_utils.pl:398` `RemoveClassCost` | 10 Emperor's Favor | none |
| Removal lockout | `NMS_multiclass_utils.pl:399` `RemoveClassLockoutDays`; expedition lockout `"Class Removal Lockout"` (`:417`, `:427`) | 7 days | none |
| First removal free | per-character bucket `free_remove_class_used` (`:405`, `:407`; `Vision_of_Ayonae.pl:268`) | one per character | none |
| Zone too high to add | `client.cpp:14930-14937` `AddClassResult::ZoneTooHigh` | refuses an add when **all three** hold: `Custom:HeroCatchupEnabled` is on (compiled default `false`, `ruletypes.h:1199`; the live value is the one that matters), the add is not `join_at_watermark`, and the zone's `min_level` exceeds `Custom:NewClassStartLevel`. With catch-up off the block never fires today, so nothing about it can be observed on a stock boot | none |
| Zone minimum level on entry | `zoning.cpp:1443` `CanEnterZone` | kick to bind on zone-in (`client_packet.cpp:1091`) or `ZoneNoExperience` on a zone line (`zoning.cpp:348`) when `GetLevel() < min_level` | bypassed for a hero: a character that holds, or has ever held, more than one class (decided 2026-09-08, D4) |
| In combat | `client.cpp:14926` `AddClassResult::InCombat` | aggro, feign, duel refuse an **add** only | the only gate; applies to add **and** remove |

The policy is spread over three doors. The Hero tab (`Handle_OP_HeroRequest`, `client_packet.cpp:17267`) fail-closes on rule, class range, held and last-class, then dispatches to `plugin::HeroRequest` (`NMS_multiclass_utils.pl:434`), which tries `RemoveClassFree` then `RemoveClassPaid` (`:446-447`). The Vision of Ayonae has its own copy of the same choice with four yellow strings (`Vision_of_Ayonae.pl:268-286`) and two handlers (`:291-296`). The guildmasters only add (`global/global_npc.pl:66-75`) and already charge nothing.

Two things ride along:

- `ZoneTooHigh` is retired under ADR-0002 line 28 ("`CanAddExtraClass` keeps `InCombat`; `ZoneTooHigh` goes"). Its original purpose is not recorded anywhere in the tree (no comment at `client.cpp:14930`, nothing in the 2026-09-05 design spec); the plausible reading, inferred, is that it stopped a new level-1 hero from being kicked on its next zone-in. Rule 7 removes the kick, so the pre-emptive refusal has no purpose either way.
- The world announcement "X has become the FIRST <combination>" (`NMS_multiclass_utils.pl:367-371`) fires only when an add reaches `Custom:MaxMulticlasses` **and** the resulting class bitmask has never been announced (`CheckUniqueClass`, `:452-462`, keyed on a global `class-<bits>` bucket). The owner decided 2026-09-08 that it stops firing.

One gap in the other direction: rule 6 makes out of combat *the* check on switching, but today the combat test exists only on the add path. `RemoveExtraClass` (`client.cpp:15065-15081`) checks rule-on, class range, held and not-last; the Hero tab remove branch (`client_packet.cpp:17315-17328`) checks held and not-last; `HeroRequest` op 2 checks not-last (`:445`). Once the fee and lockout go, removal is gated by nothing unless the combat test is added there.

## 2. Decision

Removal and addition are free and immediate. The only refusal that reads the character's **situation** is **in combat** (aggro count, feign death, duel), and it applies to **both** add and remove at every door. Every refusal that remains, so the word "only" is not misread: rule off (`MulticlassingDisabled`, `client.cpp:14894`; `Custom:ServerAuthStats` off at the tab, `client_packet.cpp:17283`), `Character:UseOldClassExpPenalties` on (`OldClassPenaltyRuleOn`, `:14899`), class id out of range, already held / not held, at `Custom:MaxMulticlasses`, race not allowed, last class (`:15078`), in combat, and the row insert failing. All of those are structural or rule-driven; none is a cost, a lockout, a zone or a timer. A hero, meaning a character that holds or has ever held more than one class, enters and stays in any zone regardless of its minimum level. No first-of-a-kind announcement fires on a class change; the blind-fate announcement and the first-login announcement stay (D5), and the per-character max-level announcement still fires the first time a hero's effective level reaches the cap, which a class drop can cause (D5, owner note). No new rule, no opcode change, no schema change.

### D1. One `RemoveClass` in the plugin

`plugin::RemoveClass` (`NMS_multiclass_utils.pl:378-394` on main) is the survivor: `RemoveExtraClass` and the yellow message. The `BuffFadeAll` it once carried was deleted by the persistence change (its D10) and is not restored. `RemoveClassFree` (`:401-409`), `RemoveClassPaid` (`:411-429`), `RemoveClassCost` (`:398`) and `RemoveClassLockoutDays` (`:399`) are deleted with their header comment (`:397`). Every caller and what it becomes:

| Caller | Today | Becomes |
| --- | --- | --- |
| `NMS_multiclass_utils.pl:446-447` `HeroRequest` op 2 | `return 1 if RemoveClassFree(...); return RemoveClassPaid(...);` | `return RemoveClass($class_id, $client) ? 1 : 0;` |
| `NMS_multiclass_utils.pl:415-416` inside `RemoveClassPaid` | `RemoveClassCost()`, `RemoveClassLockoutDays()` | deleted with the sub |
| `Vision_of_Ayonae.pl:11` | `my $remove_class_cost = plugin::RemoveClassCost();` | deleted |
| `Vision_of_Ayonae.pl:13` | `my $remove_class_lockout = plugin::RemoveClassLockoutDays();` | deleted |
| `Vision_of_Ayonae.pl:306-308` `proceed_<id>` | `plugin::RemoveClassPaid($client, $1)` | one `remove_<id>` handler (D7) |
| `Vision_of_Ayonae.pl:309-311` `free_<id>` | `plugin::RemoveClassFree($client, $1)` | deleted (covered by `remove_<id>`) |
| `Vision_of_Ayonae.pl:87` blind fate | `plugin::RemoveClass(...)` already | unchanged |

Both deleted subs carried a Perl `HasClass` guard (`:404`, `:414`) that `RemoveClass` does not. The tab is covered by the packet handler (`client_packet.cpp:17316-17319`, "You do not hold that class."). Ayonae's new `remove_<id>` handler keeps `return 0 unless plugin::HasClass($client, $1);` so a hand-typed link for a class not held is a no-op rather than "Remove Class Operation Failed.".

The `HeroRequest` op 2 guard `return 0 if GetClassesCount($client) <= 1;` (`:445`) stays. `RemoveExtraClass` refuses the last class on its own as well (`client.cpp:15078`).

The `HeroRequest` header comment (`:431-433`, "free first removal, then fee + lockout") becomes "free add, free remove; the C++ gates (in combat, last class, cap) are the whole policy".

### D2. Out of combat applies to removal too, at every door

Required by rule 6, not optional. One helper, `Client::CanRemoveExtraClass(int class_id)` returning a reason code from a new `RemoveClassResult` enum (`Ok`, `MulticlassingDisabled`, `InvalidClass`, `NotHeld`, `LastClass`, `InCombat`) with a matching `RemoveClassResultMessage`, mirroring the add side. `InCombat` uses the same test as `client.cpp:14926` (`GetAggroCount() > 0 || GetFeigned() || IsDueling()`). `LastClass` is `!HasMultipleClasses()` (D4), so the bit-count loop lives in one place. Red message: `You cannot remove a class while fighting, feigning, or dueling.`

Callers:

- `RemoveExtraClass` (`client.cpp:15158` on main) calls it first and messages the reason in red, so Ayonae, the blind-fate path (`Vision_of_Ayonae.pl:87`), and the Perl and Lua exports (`perl_client.cpp`, `lua_client.cpp`) are covered by one line. A script caller that relied on a silent `false` now also gets the red line; no shipped caller did.
- `Handle_OP_HeroRequest` remove branch (`client_packet.cpp:17315-17328`) replaces its inline held and last-class tests with the helper, so the tab refuses in combat **before** the Perl dispatch, the same way the add branch already runs `CanAddExtraClass` first. Without this the tab's request would reach Perl and only fail inside `RemoveExtraClass`, which works but prints the extra "Remove Class Operation Failed." line.

A refused removal through Perl still prints `plugin::RemoveClass`'s "Remove Class Operation Failed." (`:392`) after the red reason. Acceptable; the red line carries the reason.

### D3. `ZoneTooHigh` stops firing; the enum keeps its values

Delete the block at `client.cpp:14930-14937`. Keep:

- `AddClassResult::ZoneTooHigh = 8` in `client.h:268-279`, annotated the way `RaceNotAllowed` is (`client.cpp:14923-14924`): retired, kept so Perl and Lua reason codes do not shift. The enum has no explicit initialisers, so deleting the enumerator would silently move `RowInsertFailed` from 9 to 8; add `static_assert(static_cast<int>(AddClassResult::ZoneTooHigh) == 8 && static_cast<int>(AddClassResult::RowInsertFailed) == 9)` beside the retirement note so the "keeps its values" claim is compiler-checked. Readers of the integer: `NMS_multiclass_utils.pl:304-312`, `:553`; `global/global_npc.pl:35`, `:67`; `Vision_of_Ayonae.pl:49`.
- The `case AddClassResult::ZoneTooHigh:` line in `AddClassResultMessage` (`client.cpp:14953`), dead but mapped, same as `RaceNotAllowed` at `:14951`.
- The `join_at_watermark` parameter of `CanAddExtraClass`. After the deletion it is unused inside that function (the Perl and Lua exports call the one-argument form, `perl_client.cpp:2222`, `lua_client.cpp:205`, and the join level is chosen in `AddExtraClass` at `client.cpp:14985-14990` from its own read). Keep it for signature stability, mark it `[[maybe_unused]]`.

After this, `GetZoneMinimumLevel` has no C++ caller outside the script exports (`embparser_api.cpp:5198`, `:5203`; `lua_general.cpp:4234`, `:4239`; `lua_zone.cpp:336`; `perl_zone.cpp:256`). It stays for scripts.

Guildmaster effect: `global/global_npc.pl:61` and `:72` echo `CanAddClassMessage`, so today a guildmaster in a `min_level > 1` zone says "You cannot begin that class in this zone." That string stops being returned. No script change.

### D4. Zone minimum level bypassed for a hero (held or shelved classes)

The single enforcement point is `Client::CanEnterZone` (`zoning.cpp:1425-1456`). Its callers:

| Site | On refusal | Change |
| --- | --- | --- |
| `client_packet.cpp:1091` zone-in | `GoToBind()`, no message | none; fixed by the bypass |
| `zoning.cpp:348` `Handle_OP_ZoneChange` (zone lines, solicited zones, `#zone` for non-GMs via `MovePC`) | `SendZoneError(ZoneNoExperience)` | none; fixed by the bypass |
| `perl_client.cpp:3132`, `:3137`; `lua_client.cpp:3165`, `:3170` | returns the bool | none; no quest or plugin calls them |

`Handle_OP_GMZoneRequest` (`client_packet.cpp:7492-7552`) compares against a hard-coded 0 (`:7509`, `:7543`) and never refuses on level. `world/` has no zone `min_level` test. So there is one edit: at `zoning.cpp:1443`, `if (!GetGM() && !IsHero() && GetLevel() < z->min_level)`.

**Decided 2026-09-08: "hero" means held or shelved.** A character that holds, or has ever held, more than one class keeps the bypass; a character that has only ever been one class keeps the stock rule. The reading is free of any new query: `LoadClassExp` fills `m_class_exp` from `character_class_exp` at zone entry (`client_packet.cpp:1587`, inside `Handle_Connect_OP_ZoneEntry`), which runs before `CompleteConnect`'s `CanEnterZone` at `:1091` and before any zone line, and those rows keep a dropped class (`RemoveExtraClass` never deletes them; `SetAllClassExp` even says "retained rows for classes that are no longer in the bitmask move too", `exp.cpp:1885`). So `Client::IsHero()` is a new inline const helper: `m_class_exp.size() > 1`. With multiclassing off the map is empty and the helper is false. The rejected alternative, keying on the current class bits, would send a hero to bind after it dropped to one class inside a high zone; step 11 tests the chosen behaviour.

Two helpers, two meanings, on purpose: `IsHero()` (history, for the zone rule) and `HasMultipleClasses()` (current bits, for the last-class refusal in D2). `HasMultipleClasses()` already exists on main from the persistence change (`client.h:621`, out-of-line at `client.cpp:15265`, `bits && (bits & (bits - 1))`); this spec **calls it and declares nothing new** for it. `IsHero()` is the new inline const helper next to `LoadClassExp`: `HasMultipleClasses() || m_class_exp.size() > 1`, so a hero whose rows failed to load this session still reads as one (review finding). The `CanEnterZone` condition is `!GetGM() && !(RuleB(Custom, MulticlassingEnabled) && IsHero()) && GetLevel() < z->min_level`: the rule test keeps a former hero on the stock rule if multiclassing is switched off at run time, when the map would otherwise still be loaded from before the switch (review finding). The `m_class_exp` bitset invalidation the persistence spec names has a third writer at zone-in (`client_packet.cpp:1586`); it is safe because `GetSkill` rebuilds on `!valid`.

**Owner decision, rule 7 wording.** Rule 7's headline is "No zone level requirement applies to a hero"; its second clause says "the stock zone minimum level is bypassed". This spec bypasses the **minimum** only and leaves the `max_level` test at `zoning.cpp:1453` as stock. A hero's level is its lowest class, so it can never exceed a zone maximum in a way a single class could not. If the owner reads rule 7 as both bounds, the change is the same one-condition edit on line 1453.

Existing behaviour this makes correct: a hero that adds a class while inside a high-minimum zone drops to level 1 in place (nothing re-runs `CanEnterZone` after `SetLevel`, `exp.cpp:1430-1565`) and today is sent to bind on its next zone-in. After D4 it stays and can come back.

### D5. Announcements stop firing

Delete `NMS_multiclass_utils.pl:367-371` in `AddClass` (the `CheckUniqueClass` test, the `quest::set_data("class-$class_bits", ...)` write and the `WorldAnnounce`). Delete `sub CheckUniqueClass` (`:452-462`); `:367` was its only caller.

Kept: `quest::ding()` (`:354`), `CommonCharacterUpdate` (`:360`), the task activity update (`:362-364`). The per-player yellow add line (`:359`) drops its "permanently": `You have gained access to the $class_name class, and are now a $full_class_name.` (review finding: after free, reversible switching the old wording contradicted the D7 remove line).

**Owner note (code review of the diff, reported, not changed):** `global_player.pl` `EVENT_LEVEL_UP` announces "$name has reached Level N" the first time a character's level equals its `CharMaxLevel` bucket, once per character (`MaxLevelAnnounced`). A hero whose effective level was held down by a lagging class reaches the cap the moment that class is dropped, so a drop can be the trigger. That is the max-level announcement doing its job on the first time the character is effectively at cap, not a class-change announcement, and it fires once; left as is. If the owner wants it silent on that path, the fix is a flag on the drop's `SetEXP` that the event reads.

**Owner decision** on two adjacent world announcements the 2026-09-08 note does not name. Default: both stay, since neither is a first-of-a-kind class announcement:

- "$name ($full_class_name) has logged in for the first time." (`global/global_player.pl:112-121`, keyed on the `First-Login` bucket).
- "$name has cast themselves upon the whims of blind fate, choosing random classes ($full_class_name)." (`Vision_of_Ayonae.pl:108`).

**Decided 2026-09-08**, one blind-fate line this spec makes stale: the warning at `Vision_of_Ayonae.pl:38` ends "This decision cannot be reversed." Blind fate removes the original class (`:87`) and assigns random ones; once removal and addition are free the original class is one guildmaster hail away, so the sentence is no longer true. It is rewritten in D7 to "Your current classes are dropped and random ones assigned; they can be changed again afterwards."

### D6. Rows already in the database

Three kinds of rows exist from the old policy. Nothing left in the tree reads any of them after D1, D5 **and D7** (the Ayonae hail and menu read the bucket and the lockout until D7 deletes those lines):

| Rows | Table | Readers after this spec |
| --- | --- | --- |
| `free_remove_class_used = 1`, per character | `data_buckets` (character-scoped) | none (were `NMS_multiclass_utils.pl:405` via D1; `Vision_of_Ayonae.pl:22` and `:268` via D7) |
| `"Class Removal Lockout"`, event name empty, 7-day expiry | `character_expedition_lockouts` | none (were `NMS_multiclass_utils.pl:417` via D1; `Vision_of_Ayonae.pl:272` via D7) |
| `class-<bits>`, global | `data_buckets` | none (was `CheckUniqueClass`, `:455`, via D5) |

Default: **leave them**. A player under a live lockout is not refused because nothing asks `HasExpeditionLockout` for that name any more; the row expires on its own. The buckets are inert strings. **This PR adds no manifest entry.**

**Owner decision** if a tidy-up is wanted later: one custom manifest entry with the next unused `.version` (49 or later; main is at 48), a `.check` of `SELECT 1 FROM data_buckets WHERE \`key\` = 'free_remove_class_used' LIMIT 1` with `.condition = "not_empty"`, `content_schema_update = false`, and a bump of `CUSTOM_BINARY_DATABASE_VERSION`, or the entry never runs (review finding: the runner applies only entries at or below the binary version). Both tables are **player** tables (`common/database_schema.h` `GetPlayerTables()`: `character_expedition_lockouts` at `:135`, `data_buckets` at `:161`), so a content-schema entry would run against the wrong database. Note the `data_buckets` column is literally named `key`, a reserved word the repository maps as `key_` (`base_data_buckets_repository.h:23`; the column list at `:61` is the line that quotes it as `` `key` ``), so it must be backtick-quoted, and the pattern must be anchored: `` DELETE FROM data_buckets WHERE `key` = 'free_remove_class_used' OR `key` REGEXP '^class-[0-9]+$' `` and `DELETE FROM character_expedition_lockouts WHERE expedition_name = 'Class Removal Lockout'`. Column names to be confirmed against the live schema first.

### D7. Copy, exact strings

**Vision of Ayonae** (`Release-NMS-Quests/bazaar/Vision_of_Ayonae.pl`), anchors read from the worktree:

| Lines | Before | After |
| --- | --- | --- |
| 11, 13 | the two cost/lockout reads | deleted |
| 37 | `You will be put upon an irrevocable path, impossible to predict. Are you certain that you wish to do this?` | `Fate will choose your path, impossible to predict. Are you certain that you wish to do this?` (review finding: "irrevocable" and "can be changed again" were on one screen) |
| 38 | `... you will be assigned N random classes. This decision cannot be reversed.` | `... you will be assigned N random classes. Your current class is dropped and random ones assigned; they can be changed again afterwards.` (singular: the blind-fate hail is only offered to a single-class character; the `plugin::MaxMulticlasses()` interpolation stays) |
| 22-25 hail | bucket read and `You have a free class removal available. You will be given the option to use it by proceeding with the menu.` | deleted (the free AA reset notice stays) |
| 283-291 | bucket read, `if`, `You have a free class removal available. Would you like to [use it]? This will bypass any lockouts or costs.`, the lockout test and `You cannot remove a class at this time, you still are under cooldown from a previous class removal.` with its `return 0` | deleted |
| 293 | `if (plugin::HasClass($client, $class_id))` | kept |
| 294-297 | `It will cost $remove_class_cost Emperor's Favor ... Would you like to [Proceed]?` | `Sever the thread of the $class_name? This takes effect at once and costs nothing. [Proceed]` where `Proceed` is `quest::saylink("remove_$class_id", 1, "Proceed")` and the handler declares `my $class_name = quest::getclassname($class_id);` after `my $class_id = $1;` |
| 299-302 | `It costs $remove_class_cost Emperor's Favor ... purchase from other players in the Bazaar.` | deleted |
| 306-311 | `proceed_(\d+)` → `RemoveClassPaid`; `free_(\d+)` → `RemoveClassFree` | `remove_(\d+)`: `return 0 unless plugin::HasClass($client, $1); plugin::RemoveClass($1, $client);` |

The reforge intro at `:134` ("granting you the rare privilege of choosing another") is flavour and is left alone; the owner may trim "rare". The Emperor's Favor AA reset (`:12`, `:27-30`, `:240-263`) is a separate sink outside ADR-0002 and is untouched.

**Plugin add message** (`NMS_multiclass_utils.pl:359`): "permanently" dropped, see D5.

**Plugin `RemoveClass` message** (`NMS_multiclass_utils.pl:387`). Before: `You are NO LONGER a $class_name, and have lost access to all Spells, Disciplines, Skills, and Abilities of that class.` After: `You are no longer a $class_name. Everything it earned is kept and returns when you take it up again.` This spec owns every player-facing string at the three doors so there is one place to look. The three "kept" strings (here, the info box, the tooltip) are true because the persistence change is on main and was verified in game before this was built; step 4a below still checks the rows so a regression cannot hide behind the copy.

**Guildmasters** (`global/global_npc.pl:53-57`): no string changes. Adds are already free; the hail copy ("A new class begins at level 1 and your effective level becomes the lowest of your classes until it catches up.", `:55`) matches rule 1. The only visible change is D3.

**Hero tab info box** (`Release-NMS-Client/eqgame_dll/hero_tab.cpp` `RenderInfo`, `:128-130`). This is the one D7 string that lives in the add-on binary: the tracked `Release-NMS-Client/ClientFiles/dinput8.dll` is the file the client loads, so the PR rebuilds it (Win32 Release, the configuration the client README names) and replaces that tracked file; the build is gated on its exit code, and the new binary is grepped for the new held-line and for the absence of "7-day lockout" (review finding: a source-only change leaves the info box old while the tooltip XML changes). Before:

```
held. Remove drops it and you lose access to its spells, disciplines, skills and abilities. Your first removal is free and is used first; after that each removal costs 10 Emperor's Favor and starts a 7-day lockout.<br>
```

After:

```
held. Remove drops it; everything it earned is kept and returns when you add it again.<br>
```

`not held. Add is free.<br>` (`:132`), `Select a class, then press Add Class or Remove Class.<br>` (`:135`) and `The guildmasters and the Vision of Ayonae in the Bazaar make the same changes.` (`:137`) stay. The client-side pre-checks (`:289-312`) contain no cost, lockout or zone logic and stay; the local last-class refusal (`:307-308`) stays.

**Hero tab Remove button tooltip** (`Release-NMS-Client/ClientFiles/uifiles/default/EQUI_Inventory.xml:10079`). Before: `Drop the selected class. Your free removal is used first; after that 10 Emperor's Favor and a 7-day lockout.` After: `Drop the selected class. What it earned is kept.`

### D8. Comments that describe the old policy

Comment-only edits: `client_packet.cpp:17328-17333` (the throttle justification names "lockout, or not enough Emperor's Favor"; the 1 s `m_hero_request_timer` stays because it protects the zone thread from a replayed packet, not policy; the comment now says the C++ gates and the Perl last-class check are the only refusals), `client_packet.cpp:17348-17349` ("free add, Emperor's Favor fee and lockout on removal, announcements" → "free add, free remove; in combat refused on both"), `common/eq_packet_structs.h:1625-1626` (`HeroRequest_Struct`: "where the Perl policy (free add, fee and lockout on removal) lives" → "where the Perl dispatch lives; the C++ gates are the policy"), `NMS_multiclass_utils.pl:430-432` (D1), `global/global_player.pl:784-785` (the `EVENT_HERO_REQUEST` header, review finding), and two "superseded" pointers in the 2026-09-05 design spec plus one in the currency rename spec's sink table (class removal is no longer a sink).

### D9. Rule and schema

No new rule. `Custom:MulticlassingEnabled`, `Custom:ServerAuthStats`, `Custom:MaxMulticlasses`, `Custom:HeroCatchupEnabled`, `Custom:NewClassStartLevel` keep their meanings; `NewClassStartLevel` is still read by `AddExtraClass` (`client.cpp:14985-14990`), only its use in the deleted `ZoneTooHigh` test goes. No migration (D6 default). `HeroRequest_Struct` and `OP_HeroRequest` are unchanged, so a client on the previous add-on keeps working and only shows the old info text until it updates.

## 3. Spike

None. Every premise is in the tree.

## 4. Verification (in game, catch-up on, `Custom:MaxMulticlasses` = 4)

Preconditions that decide whether a pass means anything:

- Steps 1-3 and 9 on an account with status **below** `GM:MinStatusToZoneAnywhere` and `#gm off`; `CanEnterZone` returns true early for GM status (`zoning.cpp:1430`, `:1443`). Record the account status in the PR body.
- Step 1 only proves D5 if `SELECT * FROM data_buckets WHERE `key` = 'class-<bits>'` for the target bitmask returns nothing beforehand (or the row is deleted first); today's announcement already stays silent for a combination announced before.
- Wait more than 1 s between Hero tab presses; the throttle (`client_packet.cpp:17294-17298`) runs before every gate.

1. Three-class hero at 70 in a zone with `min_level > 1`. Add a fourth class at the Hero tab. **Expect:** add succeeds, hero level 1, no "You cannot begin that class in this zone.", no world announcement in any channel or the world log, no new `class-<bits>` row.
2. Same hero, still there: camp, log back in, cross a zone line into another `min_level > 1` zone. **Expect:** no kick to bind (the `does not meet minimum level requirement` log line absent), no zone error, hero in the new zone at level 1.
3. Control: a level-1 character on the same account that has **never** held a second class tries the same zone line, or logs in inside such a zone. **Expect:** stock `ZoneNoExperience` refusal on the line, kick to bind on the login, proving the bypass is keyed on class history, not on level. The control is `SELECT COUNT(*) FROM character_class_exp WHERE character_id = ?` = 1 **after a zone-in** (a character that never zoned since creation has 0 rows; one that added and dropped a class has 2 and is a hero); never a character that was added-then-dropped (review finding).
4. Hero tab Remove on a held class, out of combat, with 0 Emperor's Favor, a `Class Removal Lockout` row planted for this character, and the `free_remove_class_used` bucket set to 1 **for this character** (`data_buckets.character_id = <id>`, `` `key` `` = `free_remove_class_used`; an unscoped row is invisible to `GetBucket` and the old code would take the free path, review finding). After D1 nothing reads either row, so they are only a regression discriminator. **Expect:** removal succeeds at once; no fee, lockout or Emperor's Favor text; the info box reads the D7 line before the press (the rebuilt DLL installed) and the tooltip reads the D7 text.
   4a. Regression observer (persistence is on main, so this cannot be a landing test any more, review finding). Before step 4, with the Monk still held, require `SELECT value FROM character_skills WHERE id = <character_id> AND skill_id = 26` (Flying Kick, Monk-only) **> 0** and record `SELECT aa_id, aa_value, charges FROM character_alternate_abilities WHERE id = <character_id> ORDER BY aa_id` plus `aa_points` and `aa_points_spent`. Straight after the drop, run them again. **Expect:** Flying Kick unchanged, AA rows identical, `aa_points` unchanged, `aa_points_spent` lower by exactly the shelved Monk ranks' cost, and `git grep RefundUnusuableAA` empty in the tree that was built.
5. Remove another held class straight away (after 1 s). **Expect:** succeeds.
6. In combat (pull one mob, keep aggro), more than 1 s apart: press Add, then Remove. **Expect:** red `You cannot add a class while fighting, feigning, or dueling.` then red `You cannot remove a class while fighting, feigning, or dueling.`, no "Remove Class Operation Failed." (the tab is refused in C++ before Perl), class list unchanged. Repeat feigned and in a duel. Then via Ayonae's `remove_<id>` in combat: the red line **and** "Remove Class Operation Failed.".
7. Vision of Ayonae out of combat: hail, `reforge your path`, pick a `del_class_<id>` link. **Expect:** no free-removal notice on hail, one yellow line naming the class with a single `Proceed` link, removal on click, the new plugin message, no cost text anywhere.
8. Last class. Single-class character: the tab's Remove button says `You cannot remove your last class.` from the add-on (`hero_tab.cpp:307-308`); the server is never asked. Two-class character: remove one, then say Ayonae's `remove_<id>` for the other. **Expect:** the server's red `You cannot remove your last class.`.
9. Guildmaster in a `min_level > 1` zone: hail with a class not held. **Expect:** the "A new class begins at level 1..." offer, never "You cannot begin that class in this zone.".
10. Reason codes from a scratch quest printing `$client->CanAddExtraClass($id)`, on **two** characters (review finding: the four-class hero from step 1 is at cap, so it can only show 4 and 5): on that hero, a held class → 4 (`AlreadyHeld`) and a free class → 5 (`AtCap`); on a below-cap character in a `min_level > 1` zone, a free class with no aggro → 0 (never 8) and with aggro → 7 (`InCombat`). Same integers as before the change; the `static_assert` in D3 is what proves 8 and 9 did not move.
11. Two-class hero at level 1 (one class 70) standing in a `min_level > 1` zone: remove the 70 class there, then cross a zone line, then camp and log back in. Standing where it was after the drop proves nothing (nothing re-runs `CanEnterZone` inside `RemoveExtraClass`, review finding); the zone line and the relog are the test. **Expect (D4 as decided):** no refusal and no kick to bind either time; the character holds one class but its shelved row keeps it a hero. Then `SELECT COUNT(*) FROM character_class_exp WHERE character_id = ?` = 2, which is what `IsHero()` read.

Local, before any of that: `build zone` green; a rebuilt `dinput8.dll` (Release, Win32, the configuration the client README names) with the `RenderInfo` change, **copied over the tracked `Release-NMS-Client/ClientFiles/dinput8.dll`**, verified by grepping that binary for the new held-line string and for the absence of "7-day lockout" and by `cmp` against the previously committed file; its hash recorded in the PR body and that same file installed on the client used for steps 4-6 (the tooltip lives in `EQUI_Inventory.xml`, a text file the binary grep says nothing about, so it is checked with `git diff` and by reading it in game); the adversarial handoff on the diff; `git grep` for `RemoveClassFree`, `RemoveClassPaid`, `RemoveClassCost`, `RemoveClassLockoutDays`, `CheckUniqueClass`, `free_remove_class_used`, `Class Removal Lockout`, `class-$class_bits`, `ZoneTooHigh` (outside the enum, the message case and the retirement comment) across `Release-NMS-Quests`, `Release-NMS-Plugins`, `Release-NMS-Server/zone`, `Release-NMS-Client`, with every hit and its fate in the PR body; `python Release-NMS-Deploy/custom-rules/generate.py --check` (no rule change, must pass unchanged).

## 5. Files

- `Release-NMS-Plugins/NMS_multiclass_utils.pl`: `AddClass` (drop `:367-371`), `RemoveClass` (message `:388`), delete `RemoveClassCost`, `RemoveClassLockoutDays`, `RemoveClassFree`, `RemoveClassPaid`, `CheckUniqueClass`; `HeroRequest` op 2 and its header comment.
- `Release-NMS-Quests/bazaar/Vision_of_Ayonae.pl`: lines 11, 13, 22-25, 38, 266-296 per D7.
- `Release-NMS-Server/zone/client.cpp`: `CanAddExtraClass` (delete `:14930-14937`, retirement comment, `[[maybe_unused]]`), new `CanRemoveExtraClass` / `RemoveClassResultMessage`, `RemoveExtraClass` (call the helper first); `HasMultipleClasses` is the persistence spec's.
- `Release-NMS-Server/zone/client.h`: `RemoveClassResult` enum, the three declarations (`CanRemoveExtraClass`, `RemoveClassResultMessage`, `CanRemoveExtraClassMessage`), `IsHero()` (inline, `HasMultipleClasses() || m_class_exp.size() > 1`) next to `LoadClassExp`, retirement note on `ZoneTooHigh`. `HasMultipleClasses` is already there; nothing is re-declared.
- `Release-NMS-Server/zone/zoning.cpp` `CanEnterZone` `:1443`: the `!(RuleB(Custom, MulticlassingEnabled) && IsHero())` condition.
- `Release-NMS-Server/zone/client_packet.cpp` `Handle_OP_HeroRequest`: remove branch uses `CanRemoveExtraClass`; comments at `:17288-17293` and `:17308-17309`.
- `Release-NMS-Server/common/eq_packet_structs.h:1621-1623`: comment only.
- `Release-NMS-Client/eqgame_dll/hero_tab.cpp` `RenderInfo` `:128-130`, and the rebuilt, tracked `Release-NMS-Client/ClientFiles/dinput8.dll` (D7); no opcode or struct change.
- `Release-NMS-Client/ClientFiles/uifiles/default/EQUI_Inventory.xml:10079`: tooltip.
- `Release-NMS-Deploy/CODEBASE.md:85-88`: replace the "Ayonae removal policy (`RemoveClassFree` / `RemoveClassPaid` ...)" sentence with "one `RemoveClass`, always free; the C++ gates (in combat, last class, `MaxMulticlasses`) are the whole policy" ("one free `RemoveClass`" reads as the old first-free policy and is avoided). The timer and persistence specs also touch the hero paragraph of CODEBASE.md; the three PRs edit it in landing order and each rewrites only its own sentence.
- `Release-NMS-Deploy/specs/2026-09-05-hero-catchup-multiclass-design.md:226-228` and `:272-275`: one "superseded" pointer each, naming the PR number and the CODEBASE.md paragraph (the ADR is local-only and cannot be linked from a tracked file).
- `Release-NMS-Quests/QUEST-API.md:79`: the `CanAddExtraClass` row lists "zone" among the nonzero reasons; that word is dropped. `:90-91`, `:406` name no deleted sub and are left.
- `Release-NMS-Quests/global/global_player.pl:784-785`: the `EVENT_HERO_REQUEST` header comment (D8).
- `Release-NMS-Deploy/specs/2026-09-08-currency-rename-emperors-favor.md`: the sink table's "10 (class removal)" entry gets a "sink removed" note.
- No rule change, no migration (D6 default: this PR adds no manifest entry), no opcode change.

## 6. Not in this spec

- What a dropped class keeps: the persistence change (PR 20) and the AA timer change (PR 21), both on main. This spec only changes the doors and the copy.
- The `BuffFadeAll()` after removal: deleted by the persistence change; D1 does not restore it.
- Memorized gems on the level drop that a free add now makes routine: the persistence spec's D11 hooks the level decrease and the add path; this spec adds no gem handling.
- Retiring the `HeroCatchupEnabled` off mode and the guildmaster "joins you at your current level" branch (`global/global_npc.pl:56`; ADR line 24).
- The blind-fate randomizer's own flow (`Vision_of_Ayonae.pl:45-114`): pays no fee, uses `join_at_watermark = 1`; only its `AddClass` calls stop producing the FIRST announcement (D5) and its warning line is reworded (D7). Its own announcement stays unless the owner rules otherwise.
- The Emperor's Favor AA reset at Ayonae.
- The `Please wait a moment` throttle window (1 s).
