# Switching gates: free, instant, out of combat only, no announcements

Status: draft v3 for review, 2026-09-08. Third item under the hero class-switching decision (local ADR-0002, rules 6 and 7, and the owner's 2026-09-08 decision that first-of-a-kind announcements stop firing). Not built. Lands after the AA reuse timer spec and the skills + AAs persistence spec, so that nobody can switch freely into a class drop that still refunds and zeroes. v1 was verified by three independent readers against the tree; v2 went through a twelve-agent adversarial review (GO-WITH-FIXES); every confirmed finding is folded in.

## 1. Problem

Switching a class today runs through four gates that rule 6 says should not exist, and one zone rule that rule 7 says should not apply to a hero:

| Gate | Where | Value today | Under ADR-0002 |
| --- | --- | --- | --- |
| Removal fee | `NMS_multiclass_utils.pl:398` `RemoveClassCost` | 10 Echo of Memory | none |
| Removal lockout | `NMS_multiclass_utils.pl:399` `RemoveClassLockoutDays`; expedition lockout `"Class Removal Lockout"` (`:417`, `:427`) | 7 days | none |
| First removal free | per-character bucket `free_remove_class_used` (`:405`, `:407`; `Vision_of_Ayonae.pl:268`) | one per character | none |
| Zone too high to add | `client.cpp:14930-14937` `AddClassResult::ZoneTooHigh` | refuses an add when **all three** hold: `Custom:HeroCatchupEnabled` is on (compiled default `false`, `ruletypes.h:1199`; the live value is the one that matters), the add is not `join_at_watermark`, and the zone's `min_level` exceeds `Custom:NewClassStartLevel`. With catch-up off the block never fires today, so nothing about it can be observed on a stock boot | none |
| Zone minimum level on entry | `zoning.cpp:1443` `CanEnterZone` | kick to bind on zone-in (`client_packet.cpp:1091`) or `ZoneNoExperience` on a zone line (`zoning.cpp:348`) when `GetLevel() < min_level` | bypassed for a hero holding more than one class |
| In combat | `client.cpp:14926` `AddClassResult::InCombat` | aggro, feign, duel refuse an **add** only | the only gate; applies to add **and** remove |

The policy is spread over three doors. The Hero tab (`Handle_OP_HeroRequest`, `client_packet.cpp:17267`) fail-closes on rule, class range, held and last-class, then dispatches to `plugin::HeroRequest` (`NMS_multiclass_utils.pl:434`), which tries `RemoveClassFree` then `RemoveClassPaid` (`:446-447`). The Vision of Ayonae has its own copy of the same choice with four yellow strings (`Vision_of_Ayonae.pl:268-286`) and two handlers (`:291-296`). The guildmasters only add (`global/global_npc.pl:66-75`) and already charge nothing.

Two things ride along:

- `ZoneTooHigh` is retired under ADR-0002 line 28 ("`CanAddExtraClass` keeps `InCombat`; `ZoneTooHigh` goes"). Its original purpose is not recorded anywhere in the tree (no comment at `client.cpp:14930`, nothing in the 2026-09-05 design spec); the plausible reading, inferred, is that it stopped a new level-1 hero from being kicked on its next zone-in. Rule 7 removes the kick, so the pre-emptive refusal has no purpose either way.
- The world announcement "X has become the FIRST <combination>" (`NMS_multiclass_utils.pl:367-371`) fires only when an add reaches `Custom:MaxMulticlasses` **and** the resulting class bitmask has never been announced (`CheckUniqueClass`, `:452-462`, keyed on a global `class-<bits>` bucket). The owner decided 2026-09-08 that it stops firing.

One gap in the other direction: rule 6 makes out of combat *the* check on switching, but today the combat test exists only on the add path. `RemoveExtraClass` (`client.cpp:15065-15081`) checks rule-on, class range, held and not-last; the Hero tab remove branch (`client_packet.cpp:17315-17328`) checks held and not-last; `HeroRequest` op 2 checks not-last (`:445`). Once the fee and lockout go, removal is gated by nothing unless the combat test is added there.

## 2. Decision

Removal and addition are free and immediate. The only refusal that reads the character's **situation** is **in combat** (aggro count, feign death, duel), and it applies to **both** add and remove at every door. Every refusal that remains, so the word "only" is not misread: rule off (`MulticlassingDisabled`, `client.cpp:14894`; `Custom:ServerAuthStats` off at the tab, `client_packet.cpp:17283`), `Character:UseOldClassExpPenalties` on (`OldClassPenaltyRuleOn`, `:14899`), class id out of range, already held / not held, at `Custom:MaxMulticlasses`, race not allowed, last class (`:15078`), in combat, and the row insert failing. All of those are structural or rule-driven; none is a cost, a lockout, a zone or a timer. A hero holding more than one class enters and stays in any zone regardless of its minimum level. No world announcement fires on a class change. No new rule, no opcode change, no schema change.

### D1. One `RemoveClass` in the plugin

`plugin::RemoveClass` (`NMS_multiclass_utils.pl:379-395`) is the survivor: `RemoveExtraClass`, the yellow message, and `BuffFadeAll` (`:389`) **only if the persistence spec kept it**; that spec's D10 default deletes the buff wipe, and this spec must not restore it by copying the sub as it stands today. `RemoveClassFree` (`:401-409`), `RemoveClassPaid` (`:411-429`), `RemoveClassCost` (`:398`) and `RemoveClassLockoutDays` (`:399`) are deleted with their header comment (`:397`). Every caller and what it becomes:

| Caller | Today | Becomes |
| --- | --- | --- |
| `NMS_multiclass_utils.pl:446-447` `HeroRequest` op 2 | `return 1 if RemoveClassFree(...); return RemoveClassPaid(...);` | `return RemoveClass($class_id, $client) ? 1 : 0;` |
| `NMS_multiclass_utils.pl:415-416` inside `RemoveClassPaid` | `RemoveClassCost()`, `RemoveClassLockoutDays()` | deleted with the sub |
| `Vision_of_Ayonae.pl:11` | `my $remove_class_cost = plugin::RemoveClassCost();` | deleted |
| `Vision_of_Ayonae.pl:13` | `my $remove_class_lockout = plugin::RemoveClassLockoutDays();` | deleted |
| `Vision_of_Ayonae.pl:291-293` `proceed_<id>` | `plugin::RemoveClassPaid($client, $1)` | one `remove_<id>` handler (D7) |
| `Vision_of_Ayonae.pl:294-296` `free_<id>` | `plugin::RemoveClassFree($client, $1)` | deleted (covered by `remove_<id>`) |

Both deleted subs carried a Perl `HasClass` guard (`:404`, `:414`) that `RemoveClass` does not. The tab is covered by the packet handler (`client_packet.cpp:17316-17319`, "You do not hold that class."). Ayonae's new `remove_<id>` handler keeps `return 0 unless plugin::HasClass($client, $1);` so a hand-typed link for a class not held is a no-op rather than "Remove Class Operation Failed.".

The `HeroRequest` op 2 guard `return 0 if GetClassesCount($client) <= 1;` (`:445`) stays. `RemoveExtraClass` refuses the last class on its own as well (`client.cpp:15078`).

The `HeroRequest` header comment (`:431-433`, "free first removal, then fee + lockout") becomes "free add, free remove; the C++ gates (in combat, last class, cap) are the whole policy".

### D2. Out of combat applies to removal too, at every door

Required by rule 6, not optional. One helper, `Client::CanRemoveExtraClass(int class_id)` returning a reason code from a new `RemoveClassResult` enum (`Ok`, `MulticlassingDisabled`, `InvalidClass`, `NotHeld`, `LastClass`, `InCombat`) with a matching `RemoveClassResultMessage`, mirroring the add side. `InCombat` uses the same test as `client.cpp:14926` (`GetAggroCount() > 0 || GetFeigned() || IsDueling()`). `LastClass` is `!HasMultipleClasses()` (D4), so the bit-count loop lives in one place. Red message: `You cannot remove a class while fighting, feigning, or dueling.`

Callers:

- `RemoveExtraClass` (`client.cpp:15065`) calls it first and messages the reason, so Ayonae, the blind-fate path (`Vision_of_Ayonae.pl:87`), and the Perl and Lua exports (`perl_client.cpp:2252`, `lua_client.cpp:235`) are covered by one line.
- `Handle_OP_HeroRequest` remove branch (`client_packet.cpp:17315-17328`) replaces its inline held and last-class tests with the helper, so the tab refuses in combat **before** the Perl dispatch, the same way the add branch already runs `CanAddExtraClass` first. Without this the tab's request would reach Perl and only fail inside `RemoveExtraClass`, which works but prints the extra "Remove Class Operation Failed." line.

A refused removal through Perl still prints `plugin::RemoveClass`'s "Remove Class Operation Failed." (`:392`) after the red reason. Acceptable; the red line carries the reason.

### D3. `ZoneTooHigh` stops firing; the enum keeps its values

Delete the block at `client.cpp:14930-14937`. Keep:

- `AddClassResult::ZoneTooHigh = 8` in `client.h:268-279`, annotated the way `RaceNotAllowed` is (`client.cpp:14923-14924`): retired, kept so Perl and Lua reason codes do not shift. The enum has no explicit initialisers, so deleting the enumerator would silently move `RowInsertFailed` from 9 to 8; add `static_assert(static_cast<int>(AddClassResult::ZoneTooHigh) == 8 && static_cast<int>(AddClassResult::RowInsertFailed) == 9)` beside the retirement note so the "keeps its values" claim is compiler-checked. Readers of the integer: `NMS_multiclass_utils.pl:304-312`, `:553`; `global/global_npc.pl:35`, `:67`; `Vision_of_Ayonae.pl:49`.
- The `case AddClassResult::ZoneTooHigh:` line in `AddClassResultMessage` (`client.cpp:14953`), dead but mapped, same as `RaceNotAllowed` at `:14951`.
- The `join_at_watermark` parameter of `CanAddExtraClass`. After the deletion it is unused inside that function (the Perl and Lua exports call the one-argument form, `perl_client.cpp:2222`, `lua_client.cpp:205`, and the join level is chosen in `AddExtraClass` at `client.cpp:14985-14990` from its own read). Keep it for signature stability, mark it `[[maybe_unused]]`.

After this, `GetZoneMinimumLevel` has no C++ caller outside the script exports (`embparser_api.cpp:5198`, `:5203`; `lua_general.cpp:4234`, `:4239`; `lua_zone.cpp:336`; `perl_zone.cpp:256`). It stays for scripts.

Guildmaster effect: `global/global_npc.pl:61` and `:72` echo `CanAddClassMessage`, so today a guildmaster in a `min_level > 1` zone says "You cannot begin that class in this zone." That string stops being returned. No script change.

### D4. Zone minimum level bypassed for a hero with more than one class

The single enforcement point is `Client::CanEnterZone` (`zoning.cpp:1425-1456`). Its callers:

| Site | On refusal | Change |
| --- | --- | --- |
| `client_packet.cpp:1091` zone-in | `GoToBind()`, no message | none; fixed by the bypass |
| `zoning.cpp:348` `Handle_OP_ZoneChange` (zone lines, solicited zones, `#zone` for non-GMs via `MovePC`) | `SendZoneError(ZoneNoExperience)` | none; fixed by the bypass |
| `perl_client.cpp:3132`, `:3137`; `lua_client.cpp:3165`, `:3170` | returns the bool | none; no quest or plugin calls them |

`Handle_OP_GMZoneRequest` (`client_packet.cpp:7492-7552`) compares against a hard-coded 0 (`:7509`, `:7543`) and never refuses on level. `world/` has no zone `min_level` test. So there is one edit: at `zoning.cpp:1443`, `if (!GetGM() && !HasMultipleClasses() && GetLevel() < z->min_level)`. `HasMultipleClasses()` is a new inline const helper on `Client` next to `GetClassesBits()` (`client.h:620`), true when more than one bit is set, reusing the bit-count loop at `client.cpp:14913-14916` (and the one in the packet handler, `client_packet.cpp:17321-17324`, which D2's helper replaces; the packet handler then calls `CanRemoveExtraClass`, which calls `HasMultipleClasses`, so the loop is written once). The persistence spec also needs this helper (its D5, D9 and D11); whichever of the two PRs lands first defines it with this exact meaning and the other reuses it. A single-class character keeps the stock rule.

**Owner decision, what "hero" means for the bypass.** Keyed on *currently holds more than one class*, a hero that stands in a `min_level` 50 zone at level 1 with a 70 class held, then drops the 70 there, becomes a single-class level-1 character with shelved rows and is sent to bind on its next zone-in (`client_packet.cpp:1091` → `GoToBind()`). Under the persistence spec that character still *has* the shelved class. Default: keep the bypass on the current hold (the code can read it without a query, and a single-class character is a single-class character); the alternative is "has ever held more than one class", which needs the shelved rows read at zone-in. Step 11 below exercises the case either way.

**Owner decision, rule 7 wording.** Rule 7's headline is "No zone level requirement applies to a hero"; its second clause says "the stock zone minimum level is bypassed". This spec bypasses the **minimum** only and leaves the `max_level` test at `zoning.cpp:1453` as stock. A hero's level is its lowest class, so it can never exceed a zone maximum in a way a single class could not. If the owner reads rule 7 as both bounds, the change is the same one-condition edit on line 1453.

Existing behaviour this makes correct: a hero that adds a class while inside a high-minimum zone drops to level 1 in place (nothing re-runs `CanEnterZone` after `SetLevel`, `exp.cpp:1430-1565`) and today is sent to bind on its next zone-in. After D4 it stays and can come back.

### D5. Announcements stop firing

Delete `NMS_multiclass_utils.pl:367-371` in `AddClass` (the `CheckUniqueClass` test, the `quest::set_data("class-$class_bits", ...)` write and the `WorldAnnounce`). Delete `sub CheckUniqueClass` (`:452-462`); `:367` was its only caller.

Kept: the per-player yellow "You have permanently gained access to the $class_name class, and are now a $full_class_name." (`:360`), `quest::ding()` (`:355`), `CommonCharacterUpdate` (`:361`), the task activity update (`:363-365`).

**Owner decision** on two adjacent world announcements the 2026-09-08 note does not name. Default: both stay, since neither is a first-of-a-kind class announcement:

- "$name ($full_class_name) has logged in for the first time." (`global/global_player.pl:112-121`, keyed on the `First-Login` bucket).
- "$name has cast themselves upon the whims of blind fate, choosing random classes ($full_class_name)." (`Vision_of_Ayonae.pl:108`).

**Owner decision** on one blind-fate line this spec makes stale: the warning at `Vision_of_Ayonae.pl:38` ends "This decision cannot be reversed." Blind fate removes the original class (`:87`) and assigns random ones; once removal and addition are free the original class is one guildmaster hail away, so the sentence is no longer true. Default: rewrite to "Your current classes are dropped and random ones assigned; they can be changed again afterwards." The owner may prefer to keep the dramatic line.

### D6. Rows already in the database

Three kinds of rows exist from the old policy. Nothing left in the tree reads any of them after D1, D5 **and D7** (the Ayonae hail and menu read the bucket and the lockout until D7 deletes those lines):

| Rows | Table | Readers after this spec |
| --- | --- | --- |
| `free_remove_class_used = 1`, per character | `data_buckets` (character-scoped) | none (were `NMS_multiclass_utils.pl:405` via D1; `Vision_of_Ayonae.pl:22` and `:268` via D7) |
| `"Class Removal Lockout"`, event name empty, 7-day expiry | `character_expedition_lockouts` | none (were `NMS_multiclass_utils.pl:417` via D1; `Vision_of_Ayonae.pl:272` via D7) |
| `class-<bits>`, global | `data_buckets` | none (was `CheckUniqueClass`, `:455`, via D5) |

Default: **leave them**. A player under a live lockout is not refused because nothing asks `HasExpeditionLockout` for that name any more; the row expires on its own. The buckets are inert strings. No migration.

**Owner decision** if a tidy-up is wanted: one custom manifest entry, idempotent, with `content_schema_update = false`. Both tables are **player** tables (`common/database_schema.h` `GetPlayerTables()`: `character_expedition_lockouts` at `:135`, `data_buckets` at `:161`), so a content-schema entry would run against the wrong database. Note the `data_buckets` column is literally named `key`, a reserved word the repository maps as `key_` (`base_data_buckets_repository.h:23`; the column list at `:61` is the line that quotes it as `` `key` ``), so it must be backtick-quoted, and the pattern must be anchored: `` DELETE FROM data_buckets WHERE `key` = 'free_remove_class_used' OR `key` REGEXP '^class-[0-9]+$' `` and `DELETE FROM character_expedition_lockouts WHERE expedition_name = 'Class Removal Lockout'`. Column names to be confirmed against the live schema first.

### D7. Copy, exact strings

**Vision of Ayonae** (`Release-NMS-Quests/bazaar/Vision_of_Ayonae.pl`), anchors read from the worktree:

| Lines | Before | After |
| --- | --- | --- |
| 11, 13 | the two cost/lockout reads | deleted |
| 22-25 hail | bucket read and `You have a free class removal available. You will be given the option to use it by proceeding with the menu.` | deleted (the free AA reset notice at 27-30 stays) |
| 268-270 | bucket read, `if`, `You have a free class removal available. Would you like to [use it]? This will bypass any lockouts or costs.` | deleted |
| 271-276 | `You cannot remove a class at this time, you still are under cooldown from a previous class removal.` and its `return 0` | deleted |
| 278 | `if (plugin::HasClass($client, $class_id))` | kept |
| 279-282 | `It will cost $remove_class_cost Echo of Memory ... Would you like to [Proceed]?` | `Sever the thread of the $class_name? This takes effect at once and costs nothing. [Proceed]` where `Proceed` is `quest::saylink("remove_$class_id", 1, "Proceed")` and the handler declares `my $class_name = quest::getclassname($class_id);` after `my $class_id = $1;` at 266 (no `$class_name` exists in this file today) |
| 283-286 | `It costs $remove_class_cost Echo of Memory ... purchase from other players in the Bazaar.` | deleted |
| 291-296 | `proceed_(\d+)` → `RemoveClassPaid`; `free_(\d+)` → `RemoveClassFree` | `remove_(\d+)`: `return 0 unless plugin::HasClass($client, $1); plugin::RemoveClass($1, $client);` |

The reforge intro at `:134` ("granting you the rare privilege of choosing another") is flavour and is left alone; the owner may trim "rare". The Echo of Memory AA reset (`:12`, `:27-30`, `:240-263`) is a separate sink outside ADR-0002 and is untouched.

**Plugin `RemoveClass` message** (`NMS_multiclass_utils.pl:388`). Before: `You are NO LONGER a $class_name, and have lost access to all Spells, Disciplines, Skills, and Abilities of that class.` After: `You are no longer a $class_name. Everything it earned is kept and returns when you take it up again.` This spec owns every player-facing string at the three doors so there is one place to look; the persistence spec does not touch copy. Until this spec lands the old wording is wrong for a short while after persistence ships; accepted. The reverse is not: the three "kept" strings (here, the info box, the tooltip) are **true only after the persistence spec** has removed the skill zeroing and the AA refund, so this spec does not ship before it, and step 4a below proves the copy against the rows rather than taking the landing order on trust.

**Guildmasters** (`global/global_npc.pl:53-57`): no string changes. Adds are already free; the hail copy ("A new class begins at level 1 and your effective level becomes the lowest of your classes until it catches up.", `:55`) matches rule 1. The only visible change is D3.

**Hero tab info box** (`Release-NMS-Client/eqgame_dll/hero_tab.cpp` `RenderInfo`, `:128-130`). Before:

```
held. Remove drops it and you lose access to its spells, disciplines, skills and abilities. Your first removal is free and is used first; after that each removal costs 10 Echo of Memory and starts a 7-day lockout.<br>
```

After:

```
held. Remove drops it; everything it earned is kept and returns when you add it again.<br>
```

`not held. Add is free.<br>` (`:132`), `Select a class, then press Add Class or Remove Class.<br>` (`:135`) and `The guildmasters and the Vision of Ayonae in the Bazaar make the same changes.` (`:137`) stay. The client-side pre-checks (`:289-312`) contain no cost, lockout or zone logic and stay; the local last-class refusal (`:307-308`) stays.

**Hero tab Remove button tooltip** (`Release-NMS-Client/ClientFiles/uifiles/default/EQUI_Inventory.xml:10079`). Before: `Drop the selected class. Your free removal is used first; after that 10 Echo of Memory and a 7-day lockout.` After: `Drop the selected class. What it earned is kept.`

### D8. Comments that describe the old policy

Comment-only edits: `client_packet.cpp:17288-17293` (the throttle justification names "lockout, or not enough Echo of Memory"; the 1 s `m_hero_request_timer` at `:17294-17298` stays because it protects the zone thread from a replayed packet, not policy; the comment now says the C++ gates and the Perl last-class check are the only refusals), `client_packet.cpp:17308-17309` ("free add, Echo of Memory fee and lockout on removal, announcements" → "free add, free remove; in combat refused on both"), `common/eq_packet_structs.h:1621-1623` (`HeroRequest_Struct`: "where the Perl policy (free add, fee and lockout on removal) lives" → "where the Perl dispatch lives; the C++ gates are the policy"), `NMS_multiclass_utils.pl:431-433` (D1).

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
3. Control: a single-class level-1 character on the same account tries the same zone line. **Expect:** stock `ZoneNoExperience` refusal, proving the bypass is keyed on class count.
4. Hero tab Remove on a held class, out of combat, with 0 Echo of Memory, a `Class Removal Lockout` row planted for this character, **and the `free_remove_class_used` bucket set to 1 first** (without that, today's code takes the free path and the step passes on the old policy too). **Expect:** removal succeeds at once; no fee, lockout or Echo of Memory text; the info box reads the D7 line before the press and the tooltip reads the D7 text.
   4a. Straight after: `SELECT` the dropped class's rows in `character_alternate_abilities` (its class-only ranks) and the raw values of a skill only it can hold in the profile. **Expect:** all still present. This is what makes the "kept" copy true; if either is gone the persistence spec has not landed and this spec must not ship.
5. Remove another held class straight away (after 1 s). **Expect:** succeeds.
6. In combat (pull one mob, keep aggro), more than 1 s apart: press Add, then Remove. **Expect:** red `You cannot add a class while fighting, feigning, or dueling.` then red `You cannot remove a class while fighting, feigning, or dueling.`, no "Remove Class Operation Failed." (the tab is refused in C++ before Perl), class list unchanged. Repeat feigned and in a duel. Then via Ayonae's `remove_<id>` in combat: the red line **and** "Remove Class Operation Failed.".
7. Vision of Ayonae out of combat: hail, `reforge your path`, pick a `del_class_<id>` link. **Expect:** no free-removal notice on hail, one yellow line naming the class with a single `Proceed` link, removal on click, the new plugin message, no cost text anywhere.
8. Last class. Single-class character: the tab's Remove button says `You cannot remove your last class.` from the add-on (`hero_tab.cpp:307-308`); the server is never asked. Two-class character: remove one, then say Ayonae's `remove_<id>` for the other. **Expect:** the server's red `You cannot remove your last class.`.
9. Guildmaster in a `min_level > 1` zone: hail with a class not held. **Expect:** the "A new class begins at level 1..." offer, never "You cannot begin that class in this zone.".
10. Reason codes from a scratch quest printing `$client->CanAddExtraClass($id)`: already held → 4 (`AlreadyHeld`); at cap → 5 (`AtCap`); with aggro → 7 (`InCombat`); in a `min_level > 1` zone with a free slot and no aggro → 0 (never 8). Same integers as before the change; the `static_assert` in D3 is what proves 8 and 9 did not move.
11. Two-class hero at level 1 (one class 70) standing in a `min_level > 1` zone: remove the 70 class there, then cross a zone line. **Expect (default D4):** the now single-class level-1 character is refused with the stock `ZoneNoExperience` and, on camping and logging in, sent to bind. That is the documented consequence of keying on the current hold; if the owner chooses "has ever held", expect the opposite and the bypass reads the shelved rows.

Local, before any of that: `build zone` green; a rebuilt `dinput8.dll` (Release, Win32, the configuration the client README names) with the `RenderInfo` change, verified by grepping the binary for the new held-line string and for the absence of "7-day lockout"; its hash recorded in the PR body and that same file installed on the client used for steps 4-6 (the tooltip lives in `EQUI_Inventory.xml`, a text file the binary grep says nothing about, so it is checked with `git diff` and by reading it in game); the adversarial handoff on the diff; `git grep` for `RemoveClassFree`, `RemoveClassPaid`, `RemoveClassCost`, `RemoveClassLockoutDays`, `CheckUniqueClass`, `free_remove_class_used`, `Class Removal Lockout`, `class-$class_bits`, `ZoneTooHigh` (outside the enum, the message case and the retirement comment) across `Release-NMS-Quests`, `Release-NMS-Plugins`, `Release-NMS-Server/zone`, `Release-NMS-Client`, with every hit and its fate in the PR body; `python Release-NMS-Deploy/custom-rules/generate.py --check` (no rule change, must pass unchanged).

## 5. Files

- `Release-NMS-Plugins/NMS_multiclass_utils.pl`: `AddClass` (drop `:367-371`), `RemoveClass` (message `:388`), delete `RemoveClassCost`, `RemoveClassLockoutDays`, `RemoveClassFree`, `RemoveClassPaid`, `CheckUniqueClass`; `HeroRequest` op 2 and its header comment.
- `Release-NMS-Quests/bazaar/Vision_of_Ayonae.pl`: lines 11, 13, 22-25, 266-296 per D7.
- `Release-NMS-Server/zone/client.cpp`: `CanAddExtraClass` (delete `:14930-14937`, retirement comment, `[[maybe_unused]]`), new `CanRemoveExtraClass` / `RemoveClassResultMessage`, `RemoveExtraClass` (call the helper first), `HasMultipleClasses` definition.
- `Release-NMS-Server/zone/client.h`: `RemoveClassResult` enum, the two declarations, `HasMultipleClasses()` near `:620`, retirement note on `ZoneTooHigh` at `:268-279`.
- `Release-NMS-Server/zone/zoning.cpp` `CanEnterZone` `:1443`: the `!HasMultipleClasses()` condition.
- `Release-NMS-Server/zone/client_packet.cpp` `Handle_OP_HeroRequest`: remove branch uses `CanRemoveExtraClass`; comments at `:17288-17293` and `:17308-17309`.
- `Release-NMS-Server/common/eq_packet_structs.h:1621-1623`: comment only.
- `Release-NMS-Client/eqgame_dll/hero_tab.cpp` `RenderInfo` `:128-130`. **DLL rebuild required**; no opcode or struct change.
- `Release-NMS-Client/ClientFiles/uifiles/default/EQUI_Inventory.xml:10079`: tooltip.
- `Release-NMS-Deploy/CODEBASE.md:85-88`: replace the "Ayonae removal policy (`RemoveClassFree` / `RemoveClassPaid` ...)" sentence with "one `RemoveClass`, always free; the C++ gates (in combat, last class, `MaxMulticlasses`) are the whole policy" ("one free `RemoveClass`" reads as the old first-free policy and is avoided). The timer and persistence specs also touch the hero paragraph of CODEBASE.md; the three PRs edit it in landing order and each rewrites only its own sentence.
- `Release-NMS-Deploy/specs/2026-09-05-hero-catchup-multiclass-design.md:226-228` and `:272-275`: one "superseded" pointer each, naming the PR number and the CODEBASE.md paragraph (the ADR is local-only and cannot be linked from a tracked file).
- `Release-NMS-Quests/QUEST-API.md:79`: the `CanAddExtraClass` row lists "zone" among the nonzero reasons; drop that word in the same PR. `:90-91`, `:406`: optional one clause that removal has no fee; neither line names the deleted subs today.
- No rule change, no migration (D6 default), no opcode change.

## 6. Not in this spec

- What a dropped class keeps: `RemoveExtraClass` also zeroes skills (`client.cpp:15104-15107`), clears AA timers (`:15121`) and refunds AAs (`:15139`). Those are the persistence spec and the AA timer spec, which land first; this spec only changes the doors and the copy.
- The `BuffFadeAll()` after removal (`NMS_multiclass_utils.pl:389`): the persistence spec decides (its default deletes it; D1 above follows whatever it decided).
- Memorized gems on the level drop that a free add now makes routine: the persistence spec's D11 hooks the level decrease and the add path; this spec adds no gem handling.
- Retiring the `HeroCatchupEnabled` off mode and the guildmaster "joins you at your current level" branch (`global/global_npc.pl:56`; ADR line 24).
- The blind-fate randomizer's own flow (`Vision_of_Ayonae.pl:45-114`): pays no fee, uses `join_at_watermark = 1`; only its `AddClass` calls stop producing the FIRST announcement (D5). Its own announcement stays unless the owner rules otherwise.
- The Echo of Memory AA reset at Ayonae.
- The `Please wait a moment` throttle window (1 s).
