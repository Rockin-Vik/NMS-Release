# Quest Script API Reference

Methods and functions available to **Lua** and **Perl** quest scripts on this server, transcribed
from the C++ binding files (`zone/lua_*.cpp`, `zone/perl_*.cpp`, `zone/lua_general.cpp`,
`zone/embparser_api.cpp`). Snapshot against NMS-Release commit `0e400b81` plus the binding fixes committed with this file (Lua waypoint methods, event-name tables). The stock EQEmu
surface is also documented upstream at <https://eqemu.gitbook.io/quest-api/>; that site is
maintained, this file is not, so when they disagree on a stock function trust upstream.

**What is unique to this server is in [§0](#0-nms-additions).** Read that first.

Related: [`CODEBASE.md`](../Release-NMS-Deploy/CODEBASE.md) (architecture and gotchas),
[`GM-COMMANDS.md`](../Release-NMS-Server/GM-COMMANDS.md), [`CONTRIBUTING.md`](CONTRIBUTING.md).

---

## Table of Contents

0. [NMS Additions](#0-nms-additions) — multiclass, pets, item tiers, waypoints, seasonal, Lua/Perl parity
1. [Script Structure & Events](#1-script-structure--events)
2. [Lua vs Perl — Syntax Comparison](#2-lua-vs-perl--syntax-comparison)
3. [Events Reference](#3-events-reference)
4. [Per-Event Variables (Lua `e` table / Perl scalars)](#4-per-event-variables)
5. [Perl Event Globals](#5-perl-event-globals)
6. [Event Return Values](#6-event-return-values)
7. [Handin Workflow](#7-handin-workflow)
8. [Global API — `eq.*` (Lua) / `quest::` (Perl)](#8-global-api)
9. [Mob](#9-mob)
10. [Client](#10-client)
11. [NPC](#11-npc)
12. [EntityList](#12-entitylist)
13. [Group](#13-group)
14. [Raid](#14-raid)
15. [Expedition / DynamicZone](#15-expedition--dynamiczone)
16. [Inventory](#16-inventory)
17. [ItemInstance (QuestItem)](#17-iteminstance-questitem)
18. [ItemData (QuestItemData)](#18-itemdata-questitemdata)
19. [Corpse](#19-corpse)
20. [Object](#20-object)
21. [Door](#21-door)
22. [Spawn](#22-spawn)
23. [Zone](#23-zone)
24. [Merc](#24-merc)
25. [HateEntry](#25-hateentry)
26. [StatBonuses](#26-statbonuses)
27. [Spell](#27-spell)
28. [Database (Lua)](#28-database-lua)
29. [Database (Perl — QuestDB)](#29-database-perl--questdb)
30. [PerlPacket](#30-perlpacket)
31. [Lua Utilities — `Random`, `bit`](#31-lua-utilities)
32. [Popup Formatting Helpers (Lua)](#32-popup-formatting-helpers-lua)
33. [Cross-Zone & World-Wide Functions](#33-cross-zone--world-wide-functions)
34. [Expansion & Content Flag Checks](#34-expansion--content-flag-checks)

---

## 0. NMS Additions

Everything in this section is specific to this fork. The rest of the document is stock EQEmu.

### 0.1 Four rules that will bite you

1. **Hand-ins must normalise item ids with `% 1000000`.** Item upgrade tiers are encoded in the id (`base`, `base + 1000000` Enchanted, `base + 2000000` Legendary). A player handing in a Legendary quest item will be rejected by a naive `$itemcount{1001}` check. Use `plugin::GetBaseID` (`NMS_item_utils.pl`) or `id % 1000000`. See `zone/cli/tests/npc_handins_multiquest.cpp`.
2. **`SummonItem()` rolls an upgrade tier.** Both the Lua and Perl `Client:SummonItem` bindings are rerouted to `Client::SummonApocItem` (`lua_client.cpp:968`, `perl_client.cpp:845`), which — with `Custom:DoItemUpgrades` on — may hand out `+1000000`/`+2000000` versions. For an exact item use `SummonFixedItem()` (both languages) or `quest::summonfixeditem()` (Perl). For giving a player back what they gave you use `ReturnItem()` / `ReturnHandinItems()`.
3. **Branch on class with `HasClassID()` / `HasClass()`, never `GetClass()`.** A character holds up to `Custom:MaxMulticlasses` classes as a bitmask. `GetClass()` returns one of them.
4. **Lua wins over Perl** when both `foo.lua` and `foo.pl` exist for the same NPC/player/zone (`zone/main.cpp:447,452`, LuaParser registered first).

### 0.2 Custom bindings

Registration lines are in `zone/lua_client.cpp`, `zone/perl_client.cpp`, `zone/lua_mob.cpp`, `zone/perl_mob.cpp`, `zone/lua_general.cpp`, `zone/embparser_api.cpp`.

**Multiclass (Client)**

| Method | Lua | Perl | Description |
|---|---|---|---|
| `HasClassID(class_id)` | ✓ | ✓ | Does the character hold this class (any of up to `Custom:MaxMulticlasses`)? |
| `HasClass("Warrior")` | — | ✓ | Same, by class name |
| `GetClassesBitmask()` | ✓ | ✓ | The class bitmask (`1 << (class_id - 1)` per class) |
| `GetClassBitmask()` | ✓ | — | Alias of the above |
| `CanAddExtraClass(class_id)` | ✓ | ✓ | Returns reason code: 0 is allowed; nonzero covers disabled, invalid/already held, cap, combat, zone, or row-insert rejection |
| `CanAddExtraClassMessage(class_id)` | ✓ | ✓ | Human-readable reason for the CanAddExtraClass code |
| `AddExtraClass(class_id [, join_at_watermark])` | ✓ | ✓ | Add a class; `join_at_watermark` is a trusted system-script flag that skips hard catch-up |
| `RemoveExtraClass(class_id)` | ✓ | ✓ | Remove a class |
| `GetClassLevel(class_id)` | ✓ | ✓ | Level of one stored class row |
| `GetClassExp(class_id)` | ✓ | ✓ | Experience of one stored class row |
| `GetRewardLevel()` | ✓ | ✓ | Highest class level used for group, raid, and EoM eligibility |
| `IsCatchingUp()` | ✓ | ✓ | True while any class row is below the watermark |

Perl helpers in `NMS_multiclass_utils.pl`: `plugin::MultiClassingEnabled()`, `MaxMulticlasses()`,
`GetClassLevel($client, $class_id)`, `GetClassExp($client, $class_id)`,
`GetRewardLevel($client)`, `IsCatchingUp($client)`, `CanAddClass($client, $class_id)`,
`CanAddClassMessage($client, $class_id)`, `AddClass`, `RemoveClass`, `HasClass`, `GrantClassesAA`,
`CommonCharacterUpdate`. `CanAddClass`
returns the server reason code; 0 is allowed.

**Multiple pets (Mob)**

| Method | Lua | Perl | Description |
|---|---|---|---|
| `GetActivePet()` | ✓ | ✓ | The currently selected pet |
| `GetAllPets()` | ✓ | ✓ | Table / array of all pets |
| `GetPetByIndex(i)` | ✓ | ✓ | Pet at index (0-based) |
| `GetPetCount()` | ✓ | ✓ | Number of pets |
| `RemovePet()` | ✓ | ✓ | ⚠ **Lua removes pet 0 only** (`RemovePetByIndex()`); **Perl removes all pets** (`RemoveAllPets()`) |
| `GrantPetNameChange()` | ✓ | ✓ | Allow the player to rename a pet |
| `ClearPetNameChange()`, `IsPetNameChangeAllowed()` | — | ✓ | |

Stock `GetPet()` / `HasPet()` / `SetPet()` still exist and act on the active pet. `AddPet` is not exposed. Cap is `Custom:AbsolutePetLimit` (default 9).

**Item tiers (Client)**

| Method | Lua | Perl | Description |
|---|---|---|---|
| `SummonItem(id, ...)` | ✓ | ✓ | Stock name, **may upgrade the item** (see 0.1) |
| `SummonFixedItem(id [,charges [,attune [,aug1..aug6 [,slot]]]])` | ✓ | ✓ | Exact item, no tier roll |
| `ReturnItem(id, ...)` | ✓ | ✓ | Exact item; the canonical "give it back" call, takes aug6 + slot in Perl |
| `quest::summonfixeditem(id [,charges])` | — | ✓ | Global-function form |

`NMS_item_utils.pl`: `plugin::GetBaseID($id)`, `IsItemTier0/1/2($id)`. `GetUpgrade` / `GetMaxUpgrade` / `AddItemExperience` exist in C++ only. The Power Source slot accrues item XP in the instance's `Exp` custom-data key (readable via `GetCustomData("Exp")`).

**Waypoints — player travel hubs (Client)**

| Method | Lua | Perl | Description |
|---|---|---|---|
| `SendWaypointList()` | ✓ | ✓ | Push the waypoint window to the client |
| `UnlockWaypoint("zonesn")` | ✓ | ✓ | Unlock by zone short name; returns bool |
| `IsWaypointUnlocked("zonesn")` | ✓ | ✓ | |
| `CheckWaypointGroupFeature()` | ✓ | ✓ | |
| `EnableWaypointGroupFeature()` | ✓ | ✓ | |

Not the same thing as the stock grid-waypoint functions on NPC (`GetWaypointX`, `AssignWaypoints`…). Waypoint NPC type is `26999`; seed rows must exist in `nms_waypoints*` (CODEBASE.md §4.4).

**Fabled season (Mob / NPC)** — design in `Release-NMS-Deploy/FABLED-ENCOUNTERS.md` §6

| Method | Lua | Perl | Description |
|---|---|---|---|
| `mob:GetOrigName()` | ✓ | ✓ | The spawn-time name (underscored, e.g. `Lord_Nagafen`) before any `TempName()` rename. **Use this, not `GetCleanName()`, for any kill or target check keyed on a named's name** — a Fabled spawn is renamed `The_Fabled_<name>`. `plugin::CleanNpcName($n)` (`NMS_progression_utils.pl`) turns it into the `GetCleanName()` form |
| `npc:IsFabled()` | ✓ | ✓ | True when this spawn was promoted to a Fabled. Flavour only; nothing on the spawn path should call into scripts. The entity variable `fabled` = `1` is also set |

**Seasonal, instances, global buffs, misc**

| Function | Lua | Perl | Description |
|---|---|---|---|
| `client:IsSeasonal()` | — | ✓ | Reads the `SeasonalCharacter` bucket against `Custom:EnableSeasonalCharacters` |
| `client:IsHardcore()` | — | ✓ | |
| `eq.is_static_instance()` / `quest::IsStaticInstance()` | ✓ | ✓ | Instance version 255 (no respawns) |
| `eq.is_farming_instance()` | ✓ | — | Instance version 254 |
| `quest::add_global_buff(...)`, `get_global_buff(...)`, `reload_global_buffs()` | — | ✓ | `global_buffs` table, `Custom:PermanentServerBuffsEnabled` |
| `client:ShowZoneShardMenu()` | ✓ | ✓ | Hub-zone shard picker (`Custom:HubZones`) |
| `client:SetCustomItemData()`, `GetCustomItemData()`, `ReloadDynamicItem()`, `quest::IsItemDynamic()` | — | ✓ | Dynamic item data |
| `mob:GetTimerDurationMS(name)` | ✓ | ✓ | |
| `quest::settimerMS`, `getremainingtimeMS`, `gettimerdurationMS` | — | ✓ | Perl ms-precision timers (Lua timers are ms natively) |
| `eq.discord_send(webhook, msg)` / `quest::discordsend(webhook, msg)` | ✓ | ✓ | Stock, but the `admin` and `ip-exempt` webhooks are what NMS uses |

### 0.3 Data buckets and signals NMS relies on

| Key | Scope | Written by | Read by |
|---|---|---|---|
| `GestaltClasses` | character | `Client::AddExtraClass` (`client.cpp:14536`) | login, char select (`worlddb.cpp`), guild rosters |
| `EoM-Award` | character | `#award` | `plugin::UpdateEoMAward` (consumed and deleted) |
| `SeasonalCharacter` | character | `NMS_seasonal_utils.pl` | `Client::IsSeasonal()` |
| `<account_id>-CheaterFlag` | global | `#soulmark` | `NMS_soulmark_utils.pl` |
| `DisableFancyModels` | character | `#tim` | NPC spawn packets |
| `waypoints` | character | waypoint toggles (JSON) | `nms_waypoints.cpp` |
| `flag-semaphore` | character | Lua scripts | `plugin::CommonCharacterUpdate` → `AddTitleFlag` |

Signals handled in `global/global_player.pl`: **666** (EoM award pending), **100** (title flag semaphore).

### 0.4 Extension points

`Release-NMS-Plugins/NMS_custom_events.pl` holds the hooks `global_npc.pl` and `global_player.pl` call before their own logic (`CustomEventSayEntry`, `CustomEventHandinEntry`, `CustomEventNPCSpawnEntry`, `CustomEventItemClickCastEntry` are gating — return 1 to short-circuit; the rest are notify-only). The file documents the contract per hook.

### 0.5 Lua / Perl asymmetries worth knowing (stock)

Beyond the NMS table above, upstream itself is not symmetric. Lua-only: `Marquee`/`SendMarqueeMessage` variants, `CalcATK`, `CalcCurrentWeight`, `MarkSingleCompassLoc`, `DisableArea*Regen`/`EnableArea*Regen`, `GetInventory`, `Disconnect`, `TrainDisc`, `QuestReadBook`, `SendItemScale`. Perl-only: `SignalClient`, `SilentMessage`, `Popup2`, `NPCSpawn`, `GMKill`, `SetBecomeNPC`, `IsTrader`, `ConsumeItemOnCursor`, `ConsumeUnspentAA`, `RemoveNoRent`, `TaskSelectorNoCooldown`, `UpdateWho`, `ExpeditionMessage`, `GetMerc`, `MarkCompassLoc`, `SendSpellAnim`, `GetFreeSpellBookSlot`, `GetFreeDisciplineSlot`, `RemoveFromInstance`, and on NPC `AddMeleeProc`/`AddRangedProc`/`AddDefensiveProc`/`RemoveFromHateList`/`SignalNPC`/`GetCombatState`. Naming also differs on items: Lua `AddExp/GetExp/SetExp`, `IsInstNoDrop`, `GetMaxEvolveLvl`; Perl `AddEXP/GetEXP/SetEXP`, `IsInstanceNoDrop`, `GetMaxEvolveLevel`. When a table below lists one name for both languages, check the binding file if it matters.

---

## 1. Script Structure & Events

### File Naming Convention

Scripts live under `quests/` and are resolved by `zone/quest_parser_collection.cpp`. For each candidate below, every quest root is tried, and for each root **`.lua` is tried before `.pl`** — Lua wins on a name collision. `{ver}` is the zone instance version.

| Script Type | Candidates, in order |
|---|---|
| NPC | `{zone}/v{ver}/{npc_id}`, `{zone}/v{ver}/{npc_name}`, `{zone}/v{ver}/{npc_name}_{npc_id}`, `{zone}/{npc_id}`, `{zone}/{npc_name}`, `{zone}/{npc_name}_{npc_id}`, `global/{npc_id}`, `global/{npc_name}`, `global/{npc_name}_{npc_id}`, `{zone}/v{ver}/default`, `{zone}/default`, `global/default` |
| Zone controller | Same NPC path with the literal name `zone_controller` (e.g. `{zone}/zone_controller.pl`). Receives the `*_ZONE` events. |
| Global NPC | `global/global_npc` — runs for every NPC in addition to its own script |
| Player | `{zone}/v{ver}/player`, `{zone}/player_v{ver}`, `{zone}/player`, `global/player` |
| Global player | `global/global_player` — runs for every player in addition to the zone player script |
| Item | `{zone}/v{ver}/items/{script}`, `{zone}/items/{script}`, `global/items/{script}`, `{zone}/items/default`, `global/items/default` |
| Spell | `{zone}/v{ver}/spells/{spell_id}`, `{zone}/spells/{spell_id}`, `global/spells/{spell_id}`, `{zone}/spells/default`, `global/spells/default` |
| Encounter | `{zone}/v{ver}/encounters/{name}`, `{zone}/encounters/{name}`, `global/encounters/{name}` (no default fallback) |
| Bot | `{zone}/v{ver}/bot`, `{zone}/bot_v{ver}`, `{zone}/bot`, `global/bot`; plus `global/global_bot` |
| Merc | `{zone}/v{ver}/merc`, `{zone}/merc_v{ver}`, `{zone}/merc`, `global/merc`; plus `global/global_merc` |

NPC names have backticks replaced with `-`. Shared Lua code goes in `lua_modules/` (path from `eqemu_config.json`, key `lua_modules`); shared Perl code goes in `quests/plugins/` and is called as `plugin::name()`.

### Lua Script Structure

```lua
-- Event handler functions are defined at the top level
function event_say(e)
    -- e.self      = the NPC (Mob)
    -- e.other     = the Client who spoke
    -- e.message   = the text said
    if e.message:findi("hello") then
        e.self:Say("Hello, " .. e.other:GetName() .. "!")
    end
end

function event_spawn(e)
    -- e.self = the NPC
end
```

### Perl Script Structure

```perl
sub EVENT_SAY {
    # $npc       = NPC object
    # $client    = Client object
    # $text      = text said
    if ($text =~ /hello/i) {
        $npc->Say("Hello, " . $client->GetName() . "!");
    }
}

sub EVENT_SPAWN {
    # fires when this NPC spawns
}
```

---

## 2. Lua vs Perl — Syntax Comparison

| Operation | Lua | Perl |
|---|---|---|
| Call NPC method | `e.self:Say("hi")` | `$npc->Say("hi")` |
| Call client method | `e.other:GetName()` | `$client->GetName()` |
| Call global quest fn | `eq.say("hi")` | `quest::say("hi")` |
| Get entity list | `local el = eq.get_entity_list()` | `my $el = $entity_list` |
| Set timer | `eq.set_timer("t", 5000)` | `quest::settimer("t", 5)` *(seconds)* |
| Boolean check | `if e.other:IsClient() then` | `if ($client->IsClient()) {` |
| Spell check | `if eq.is_beneficial_spell(1) then` | `if (plugin::BeneficialSpell(1))` |

> **Note:** Lua timers use **milliseconds**. Perl `settimer` uses **seconds**; use `settimerMS` for milliseconds.

---

## 3. Events Reference

Each event fires a handler function. In Lua, the handler receives a single table `e` with contextual fields. In Perl, the NPC/client/etc. objects are available as package globals.

### Event Handler Names

| Event | Lua Handler | Perl Sub | Context | Fires When |
|---|---|---|---|---|
| `EVENT_SAY` (0) | `event_say(e)` | `EVENT_SAY` | NPC / Player | Player says text near/to NPC, or near player |
| `EVENT_TRADE` (1) | `event_trade(e)` | **`EVENT_ITEM`** | NPC | Player gives item or money to NPC |
| `EVENT_DEATH` (2) | `event_death(e)` | `EVENT_DEATH` | NPC / Player | NPC or player is killed |
| `EVENT_SPAWN` (3) | `event_spawn(e)` | `EVENT_SPAWN` | NPC | NPC first spawns |
| `EVENT_ATTACK` (4) | `event_attack(e)` | `EVENT_ATTACK` | NPC | NPC is attacked |
| `EVENT_COMBAT` (5) | `event_combat(e)` | `EVENT_COMBAT` | NPC | NPC enters or leaves combat |
| `EVENT_AGGRO` (6) | `event_aggro(e)` | `EVENT_AGGRO` | NPC | NPC enters combat via PC attack |
| `EVENT_SLAY` (7) | `event_slay(e)` | `EVENT_SLAY` | NPC | NPC kills a PC |
| `EVENT_NPC_SLAY` (8) | `event_npc_slay(e)` | `EVENT_NPC_SLAY` | NPC | NPC kills another NPC |
| `EVENT_WAYPOINT_ARRIVE` (9) | `event_waypoint_arrive(e)` | `EVENT_WAYPOINT_ARRIVE` | NPC | NPC reaches a waypoint |
| `EVENT_WAYPOINT_DEPART` (10) | `event_waypoint_depart(e)` | `EVENT_WAYPOINT_DEPART` | NPC | NPC departs a waypoint |
| `EVENT_TIMER` (11) | `event_timer(e)` | `EVENT_TIMER` | NPC / Player / Item | A named timer fires |
| `EVENT_SIGNAL` (12) | `event_signal(e)` | `EVENT_SIGNAL` | NPC / Player | Signal sent via `Signal()` |
| `EVENT_HP` (13) | `event_hp(e)` | `EVENT_HP` | NPC | NPC HP crosses a threshold |
| `EVENT_ENTER` (14) | `event_enter(e)` | `EVENT_ENTER` | NPC | PC enters NPC proximity |
| `EVENT_EXIT` (15) | `event_exit(e)` | `EVENT_EXIT` | NPC | PC leaves NPC proximity |
| `EVENT_ENTER_ZONE` (16) | `event_enter_zone(e)` | **`EVENT_ENTERZONE`** | Player | Player enters zone |
| `EVENT_CLICK_DOOR` (17) | `event_click_door(e)` | **`EVENT_CLICKDOOR`** | Player | Player clicks a door |
| `EVENT_LOOT` (18) | `event_loot(e)` | `EVENT_LOOT` | Player / Item | Player loots an item |
| `EVENT_ZONE` (19) | `event_zone(e)` | `EVENT_ZONE` | Player | Player zones to another zone |
| `EVENT_LEVEL_UP` (20) | `event_level_up(e)` | `EVENT_LEVEL_UP` | Player | Player levels up |
| `EVENT_KILLED_MERIT` (21) | `event_killed_merit(e)` | `EVENT_KILLED_MERIT` | NPC | NPC killed; gives XP to PC/group |
| `EVENT_CAST_ON` (22) | `event_cast_on(e)` | `EVENT_CAST_ON` | NPC | PC casts spell on NPC |
| `EVENT_TASK_ACCEPTED` (23) | `event_task_accepted(e)` | **`EVENT_TASKACCEPTED`** | NPC / Player | Player accepts a task |
| `EVENT_TASK_STAGE_COMPLETE` (24) | `event_task_stage_complete(e)` | `EVENT_TASK_STAGE_COMPLETE` | Player | Task stage completes |
| `EVENT_TASK_UPDATE` (25) | `event_task_update(e)` | `EVENT_TASK_UPDATE` | Player | Task activity updates |
| `EVENT_TASK_COMPLETE` (26) | `event_task_complete(e)` | `EVENT_TASK_COMPLETE` | Player | Task fully completed |
| `EVENT_TASK_FAIL` (27) | `event_task_fail(e)` | `EVENT_TASK_FAIL` | Player | Task fails |
| `EVENT_AGGRO_SAY` (28) | `event_aggro_say(e)` | `EVENT_AGGRO_SAY` | NPC | NPC says text when aggroing |
| `EVENT_PLAYER_PICKUP` (29) | `event_player_pickup(e)` | `EVENT_PLAYER_PICKUP` | Player | Player picks up ground item |
| `EVENT_POPUP_RESPONSE` (30) | `event_popup_response(e)` | **`EVENT_POPUPRESPONSE`** | NPC / Player | Player clicks popup button |
| `EVENT_ENVIRONMENTAL_DAMAGE` (31) | `event_environmental_damage(e)` | `EVENT_ENVIRONMENTAL_DAMAGE` | Player | Environmental damage taken |
| `EVENT_PROXIMITY_SAY` (32) | `event_proximity_say(e)` | `EVENT_PROXIMITY_SAY` | NPC | Player says text in proximity range |
| `EVENT_CAST` (33) | `event_cast(e)` | `EVENT_CAST` | NPC / Player | NPC/player finishes casting |
| `EVENT_CAST_BEGIN` (34) | `event_cast_begin(e)` | `EVENT_CAST_BEGIN` | NPC / Player | NPC/player begins casting |
| `EVENT_SCALE_CALC` (35) | `event_scale_calc(e)` | `EVENT_SCALE_CALC` | NPC | NPC scale recalculation |
| `EVENT_ITEM_ENTER_ZONE` (36) | `event_item_enter_zone(e)` | `EVENT_ITEM_ENTER_ZONE` | Player | Item enters zone |
| `EVENT_TARGET_CHANGE` (37) | `event_target_change(e)` | `EVENT_TARGET_CHANGE` | Player | Target selected/changed/removed |
| `EVENT_HATE_LIST` (38) | `event_hate_list(e)` | `EVENT_HATE_LIST` | NPC | Added/removed from hate list |
| `EVENT_SPELL_EFFECT_CLIENT` (39) | `event_spell_effect_client(e)` | `EVENT_SPELL_EFFECT_CLIENT` | Player | Spell effect lands on client |
| `EVENT_SPELL_EFFECT_NPC` (40) | `event_spell_effect_npc(e)` | `EVENT_SPELL_EFFECT_NPC` | NPC | Spell effect lands on NPC |
| `EVENT_SPELL_EFFECT_BUFF_TIC_CLIENT` (41) | `event_spell_effect_buff_tic_client(e)` | `EVENT_SPELL_EFFECT_BUFF_TIC_CLIENT` | Player | Buff tics on client |
| `EVENT_SPELL_EFFECT_BUFF_TIC_NPC` (42) | `event_spell_effect_buff_tic_npc(e)` | `EVENT_SPELL_EFFECT_BUFF_TIC_NPC` | NPC | Buff tics on NPC |
| `EVENT_SPELL_FADE` (43) | `event_spell_fade(e)` | `EVENT_SPELL_FADE` | NPC / Player | Buff/spell fades |
| `EVENT_SPELL_EFFECT_TRANSLOCATE_COMPLETE` (44) | `event_spell_effect_translocate_complete(e)` | `EVENT_SPELL_EFFECT_TRANSLOCATE_COMPLETE` | Player | Translocate completes |
| `EVENT_COMBINE_SUCCESS` (45) | `event_combine_success(e)` | `EVENT_COMBINE_SUCCESS` | Player | Player succeeds tradeskill combine |
| `EVENT_COMBINE_FAILURE` (46) | `event_combine_failure(e)` | `EVENT_COMBINE_FAILURE` | Player | Player fails tradeskill combine |
| `EVENT_ITEM_CLICK` (47) | `event_item_click(e)` | `EVENT_ITEM_CLICK` | Player / Item | Player right-clicks item |
| `EVENT_ITEM_CLICK_CAST` (48) | `event_item_click_cast(e)` | `EVENT_ITEM_CLICK_CAST` | Player | Item click triggers spell cast |
| `EVENT_GROUP_CHANGE` (49) | `event_group_change(e)` | `EVENT_GROUP_CHANGE` | Player | Group membership changes |
| `EVENT_FORAGE_SUCCESS` (50) | `event_forage_success(e)` | `EVENT_FORAGE_SUCCESS` | Player | Forage succeeds |
| `EVENT_FORAGE_FAILURE` (51) | `event_forage_failure(e)` | `EVENT_FORAGE_FAILURE` | Player | Forage fails |
| `EVENT_FISH_START` (52) | `event_fish_start(e)` | `EVENT_FISH_START` | Player | Player begins fishing |
| `EVENT_FISH_SUCCESS` (53) | `event_fish_success(e)` | `EVENT_FISH_SUCCESS` | Player | Fishing succeeds |
| `EVENT_FISH_FAILURE` (54) | `event_fish_failure(e)` | `EVENT_FISH_FAILURE` | Player | Fishing fails |
| `EVENT_CLICK_OBJECT` (55) | `event_click_object(e)` | `EVENT_CLICK_OBJECT` | Player | Player clicks a world object |
| `EVENT_DISCOVER_ITEM` (56) | `event_discover_item(e)` | `EVENT_DISCOVER_ITEM` | Player | Player discovers a new item |
| `EVENT_DISCONNECT` (57) | `event_disconnect(e)` | `EVENT_DISCONNECT` | Player | Player disconnects |
| `EVENT_CONNECT` (58) | `event_connect(e)` | `EVENT_CONNECT` | Player | Player connects |
| `EVENT_ITEM_TICK` (59) | `event_item_tick(e)` | `EVENT_ITEM_TICK` | Item | Per-server-tick callback for an item script |
| `EVENT_DUEL_WIN` (60) | `event_duel_win(e)` | `EVENT_DUEL_WIN` | Player | Player wins a duel |
| `EVENT_DUEL_LOSE` (61) | `event_duel_lose(e)` | `EVENT_DUEL_LOSE` | Player | Player loses a duel |
| `EVENT_ENCOUNTER_LOAD` (62) | `event_encounter_load(e)` | `EVENT_ENCOUNTER_LOAD` | Encounter | Encounter script loads |
| `EVENT_ENCOUNTER_UNLOAD` (63) | `event_encounter_unload(e)` | `EVENT_ENCOUNTER_UNLOAD` | Encounter | Encounter script unloads |
| `EVENT_COMMAND` (64) | `event_command(e)` | `EVENT_COMMAND` | Player | Player uses a custom command |
| `EVENT_DROP_ITEM` (65) | `event_drop_item(e)` | `EVENT_DROP_ITEM` | Player | Player drops an item |
| `EVENT_DESTROY_ITEM` (66) | `event_destroy_item(e)` | `EVENT_DESTROY_ITEM` | Player | Player destroys an item |
| `EVENT_FEIGN_DEATH` (67) | `event_feign_death(e)` | **`EVENT_FEIGN_DEATH`** | Player | Player feigns death (fires on the player script) |
| `EVENT_WEAPON_PROC` (68) | `event_weapon_proc(e)` | `EVENT_WEAPON_PROC` | Item | Weapon proc triggers |
| `EVENT_EQUIP_ITEM` (69) | `event_equip_item(e)` | `EVENT_EQUIP_ITEM` | NPC | NPC equips an item |
| `EVENT_UNEQUIP_ITEM` (70) | `event_unequip_item(e)` | `EVENT_UNEQUIP_ITEM` | NPC | NPC unequips an item |
| `EVENT_AUGMENT_ITEM` (71) | `event_augment_item(e)` | `EVENT_AUGMENT_ITEM` | Item | Item augmented |
| `EVENT_UNAUGMENT_ITEM` (72) | `event_unaugment_item(e)` | `EVENT_UNAUGMENT_ITEM` | Item | Item unaugmented |
| `EVENT_AUGMENT_INSERT` (73) | `event_augment_insert(e)` | `EVENT_AUGMENT_INSERT` | Item | Augment inserted (server-side) |
| `EVENT_AUGMENT_REMOVE` (74) | `event_augment_remove(e)` | `EVENT_AUGMENT_REMOVE` | Item | Augment removed (server-side) |
| `EVENT_ENTER_AREA` (75) | `event_enter_area(e)` | `EVENT_ENTER_AREA` | NPC | Player enters a defined area |
| `EVENT_LEAVE_AREA` (76) | `event_leave_area(e)` | `EVENT_LEAVE_AREA` | NPC | Player leaves a defined area |
| `EVENT_RESPAWN` (77) | `event_respawn(e)` | `EVENT_RESPAWN` | Player | Player chooses respawn option |
| `EVENT_DEATH_COMPLETE` (78) | `event_death_complete(e)` | `EVENT_DEATH_COMPLETE` | NPC / Player | Death fully processed (after loot/XP) |
| `EVENT_UNHANDLED_OPCODE` (79) | `event_unhandled_opcode(e)` | `EVENT_UNHANDLED_OPCODE` | Player | Unknown client opcode |
| `EVENT_TICK` (80) | `event_tick(e)` | `EVENT_TICK` | NPC | Server tick fires on NPC |
| `EVENT_SPAWN_ZONE` (81) | `event_spawn_zone(e)` | `EVENT_SPAWN_ZONE` | Zone (NPC) | Any NPC spawns in zone (zone controller) |
| `EVENT_DEATH_ZONE` (82) | `event_death_zone(e)` | `EVENT_DEATH_ZONE` | Zone (NPC) | Any mob dies in zone (zone controller) |
| `EVENT_USE_SKILL` (83) | `event_use_skill(e)` | `EVENT_USE_SKILL` | Player | Player uses a skill |
| `EVENT_COMBINE_VALIDATE` (84) | `event_combine_validate(e)` | `EVENT_COMBINE_VALIDATE` | Player | Validate before combine |
| `EVENT_BOT_COMMAND` (85) | `event_bot_command(e)` | `EVENT_BOT_COMMAND` | Player | Bot command issued |
| `EVENT_WARP` (86) | `event_warp(e)` | `EVENT_WARP` | Player | Player warps |
| `EVENT_TEST_BUFF` (87) | `event_test_buff(e)` | `EVENT_TEST_BUFF` | Player | Buff application test |
| `EVENT_COMBINE` (88) | `event_combine(e)` | `EVENT_COMBINE` | Player | Any combine attempt |
| `EVENT_CONSIDER` (89) | `event_consider(e)` | `EVENT_CONSIDER` | Player | Player considers NPC |
| `EVENT_CONSIDER_CORPSE` (90) | `event_consider_corpse(e)` | `EVENT_CONSIDER_CORPSE` | Player | Player considers corpse |
| `EVENT_LOOT_ZONE` (91) | `event_loot_zone(e)` | `EVENT_LOOT_ZONE` | Zone (NPC) | Any player loots in zone (zone controller) |
| `EVENT_EQUIP_ITEM_CLIENT` (92) | `event_equip_item_client(e)` | `EVENT_EQUIP_ITEM_CLIENT` | Player | Client equips item |
| `EVENT_UNEQUIP_ITEM_CLIENT` (93) | `event_unequip_item_client(e)` | `EVENT_UNEQUIP_ITEM_CLIENT` | Player | Client unequips item |
| `EVENT_SKILL_UP` (94) | `event_skill_up(e)` | `EVENT_SKILL_UP` | Player | Player's skill increases |
| `EVENT_LANGUAGE_SKILL_UP` (95) | `event_language_skill_up(e)` | `EVENT_LANGUAGE_SKILL_UP` | Player | Player's language skill increases |
| `EVENT_ALT_CURRENCY_MERCHANT_BUY` (96) | `event_alt_currency_merchant_buy(e)` | `EVENT_ALT_CURRENCY_MERCHANT_BUY` | Player | Alt currency purchase |
| `EVENT_ALT_CURRENCY_MERCHANT_SELL` (97) | `event_alt_currency_merchant_sell(e)` | `EVENT_ALT_CURRENCY_MERCHANT_SELL` | Player | Alt currency sale |
| `EVENT_MERCHANT_BUY` (98) | `event_merchant_buy(e)` | `EVENT_MERCHANT_BUY` | Player | Merchant sale to player |
| `EVENT_MERCHANT_SELL` (99) | `event_merchant_sell(e)` | `EVENT_MERCHANT_SELL` | Player | Merchant purchase from player |
| `EVENT_INSPECT` (100) | `event_inspect(e)` | `EVENT_INSPECT` | Player | Player inspects NPC/item |
| `EVENT_TASK_BEFORE_UPDATE` (101) | `event_task_before_update(e)` | `EVENT_TASK_BEFORE_UPDATE` | Player | Before task activity update |
| `EVENT_AA_BUY` (102) | `event_aa_buy(e)` | `EVENT_AA_BUY` | Player | Player buys an AA |
| `EVENT_AA_GAIN` (103) | `event_aa_gain(e)` | `EVENT_AA_GAIN` | Player | Player gains AA points |
| `EVENT_AA_EXP_GAIN` (104) | `event_aa_exp_gain(e)` | `EVENT_AA_EXP_GAIN` | Player | Player gains AA experience |
| `EVENT_EXP_GAIN` (105) | `event_exp_gain(e)` | `EVENT_EXP_GAIN` | Player | Player gains experience |
| `EVENT_PAYLOAD` (106) | `event_payload(e)` | `EVENT_PAYLOAD` | NPC / Player | Payload signal received |
| `EVENT_LEVEL_DOWN` (107) | `event_level_down(e)` | `EVENT_LEVEL_DOWN` | Player | Player loses a level |
| `EVENT_GM_COMMAND` (108) | `event_gm_command(e)` | `EVENT_GM_COMMAND` | Player | GM command issued |
| `EVENT_DESPAWN` (109) | `event_despawn(e)` | `EVENT_DESPAWN` | NPC | NPC despawns |
| `EVENT_DESPAWN_ZONE` (110) | `event_despawn_zone(e)` | `EVENT_DESPAWN_ZONE` | Zone (NPC) | Any mob despawns in zone (zone controller) |
| `EVENT_BOT_CREATE` (111) | `event_bot_create(e)` | `EVENT_BOT_CREATE` | Player | Bot is created |
| `EVENT_AUGMENT_INSERT_CLIENT` (112) | `event_augment_insert_client(e)` | `EVENT_AUGMENT_INSERT_CLIENT` | Player | Client inserts augment |
| `EVENT_AUGMENT_REMOVE_CLIENT` (113) | `event_augment_remove_client(e)` | `EVENT_AUGMENT_REMOVE_CLIENT` | Player | Client removes augment |
| `EVENT_EQUIP_ITEM_BOT` (114) | `event_equip_item_bot(e)` | `EVENT_EQUIP_ITEM_BOT` | Bot | Bot equips item |
| `EVENT_UNEQUIP_ITEM_BOT` (115) | `event_unequip_item_bot(e)` | `EVENT_UNEQUIP_ITEM_BOT` | Bot | Bot unequips item |
| `EVENT_DAMAGE_GIVEN` (116) | `event_damage_given(e)` | `EVENT_DAMAGE_GIVEN` | NPC / Player | Mob deals damage |
| `EVENT_DAMAGE_TAKEN` (117) | `event_damage_taken(e)` | `EVENT_DAMAGE_TAKEN` | NPC / Player | Mob takes damage |
| `EVENT_ITEM_CLICK_CLIENT` (118) | `event_item_click_client(e)` | `EVENT_ITEM_CLICK_CLIENT` | Player | Client clicks item |
| `EVENT_ITEM_CLICK_CAST_CLIENT` (119) | `event_item_click_cast_client(e)` | `EVENT_ITEM_CLICK_CAST_CLIENT` | Player | Client item click cast |
| `EVENT_DESTROY_ITEM_CLIENT` (120) | `event_destroy_item_client(e)` | `EVENT_DESTROY_ITEM_CLIENT` | Player | Client destroys item |
| `EVENT_DROP_ITEM_CLIENT` (121) | `event_drop_item_client(e)` | `EVENT_DROP_ITEM_CLIENT` | Player | Client drops item |
| `EVENT_MEMORIZE_SPELL` (122) | `event_memorize_spell(e)` | `EVENT_MEMORIZE_SPELL` | Player | Player memorizes spell |
| `EVENT_UNMEMORIZE_SPELL` (123) | `event_unmemorize_spell(e)` | `EVENT_UNMEMORIZE_SPELL` | Player | Player unmemorizes spell |
| `EVENT_SCRIBE_SPELL` (124) | `event_scribe_spell(e)` | `EVENT_SCRIBE_SPELL` | Player | Player scribes spell |
| `EVENT_UNSCRIBE_SPELL` (125) | `event_unscribe_spell(e)` | `EVENT_UNSCRIBE_SPELL` | Player | Player unscribes spell |
| `EVENT_LOOT_ADDED` (126) | `event_loot_added(e)` | `EVENT_LOOT_ADDED` | NPC | Loot added to NPC corpse table |
| `EVENT_LDON_POINTS_GAIN` (127) | `event_ldon_points_gain(e)` | `EVENT_LDON_POINTS_GAIN` | Player | LDoN points gained |
| `EVENT_LDON_POINTS_LOSS` (128) | `event_ldon_points_loss(e)` | `EVENT_LDON_POINTS_LOSS` | Player | LDoN points lost |
| `EVENT_ALT_CURRENCY_GAIN` (129) | `event_alt_currency_gain(e)` | `EVENT_ALT_CURRENCY_GAIN` | Player | Alt currency gained |
| `EVENT_ALT_CURRENCY_LOSS` (130) | `event_alt_currency_loss(e)` | `EVENT_ALT_CURRENCY_LOSS` | Player | Alt currency lost |
| `EVENT_CRYSTAL_GAIN` (131) | `event_crystal_gain(e)` | `EVENT_CRYSTAL_GAIN` | Player | Crystal gained |
| `EVENT_CRYSTAL_LOSS` (132) | `event_crystal_loss(e)` | `EVENT_CRYSTAL_LOSS` | Player | Crystal lost |
| `EVENT_TIMER_PAUSE` (133) | `event_timer_pause(e)` | `EVENT_TIMER_PAUSE` | NPC / Player | Timer paused |
| `EVENT_TIMER_RESUME` (134) | `event_timer_resume(e)` | `EVENT_TIMER_RESUME` | NPC / Player | Timer resumed |
| `EVENT_TIMER_START` (135) | `event_timer_start(e)` | `EVENT_TIMER_START` | NPC / Player | Timer started |
| `EVENT_TIMER_STOP` (136) | `event_timer_stop(e)` | `EVENT_TIMER_STOP` | NPC / Player | Timer stopped |
| `EVENT_ENTITY_VARIABLE_DELETE` (137) | `event_entity_variable_delete(e)` | `EVENT_ENTITY_VARIABLE_DELETE` | NPC / Player | Entity variable deleted |
| `EVENT_ENTITY_VARIABLE_SET` (138) | `event_entity_variable_set(e)` | `EVENT_ENTITY_VARIABLE_SET` | NPC / Player | Entity variable set |
| `EVENT_ENTITY_VARIABLE_UPDATE` (139) | `event_entity_variable_update(e)` | `EVENT_ENTITY_VARIABLE_UPDATE` | NPC / Player | Entity variable updated |
| `EVENT_AA_LOSS` (140) | `event_aa_loss(e)` | `EVENT_AA_LOSS` | Player | Player loses AA points |
| `EVENT_SPELL_BLOCKED` (141) | `event_spell_blocked(e)` | `EVENT_SPELL_BLOCKED` | NPC / Player | Spell is blocked by a buff |
| `EVENT_READ_ITEM` (142) | `event_read_item(e)` | `EVENT_READ_ITEM` | Player | Player reads a book item |
| `EVENT_SPELL_EFFECT_BOT` (143) | `event_spell_effect_bot(e)` | `EVENT_SPELL_EFFECT_BOT` | Bot | Spell effect on bot |
| `EVENT_SPELL_EFFECT_BUFF_TIC_BOT` (144) | `event_spell_effect_buff_tic_bot(e)` | `EVENT_SPELL_EFFECT_BUFF_TIC_BOT` | Bot | Buff tic on bot |
| `EVENT_ITEM_GENERATE` (145) | `event_item_generate(e)` | `EVENT_ITEM_GENERATE` | — | **Never fires.** Declared in `event_codes.h` but nothing in the server dispatches it. |

> **Keep the three name tables in sync.** `QuestEventID` (`zone/event_codes.h`), `QuestEventSubroutines[]` (`zone/embparser.cpp`) and `LuaEvents[]` (`zone/lua_parser.cpp`) are parallel arrays sized `_LargestEventID`. A new event added to the enum without a name in both tables is a null pointer that gets dereferenced on dispatch. Add new events to all three, and to the `Event` enum in `zone/lua_general.cpp`.

> **Perl sub name differences from Lua handler names** — the following Perl subs use a different name than the Lua handler:
> | Lua Handler | Perl Sub |
> |---|---|
> | `event_trade` | `EVENT_ITEM` |
> | `event_enter_zone` | `EVENT_ENTERZONE` |
> | `event_click_door` | `EVENT_CLICKDOOR` |
> | `event_task_accepted` | `EVENT_TASKACCEPTED` |
> | `event_popup_response` | `EVENT_POPUPRESPONSE` |

---

## 4. Per-Event Variables

In **Lua**, every event handler receives a single table `e`. It always contains `e.self` (the NPC or mob the script is attached to). Additional fields depend on the event.

In **Perl**, each event sub receives variables exported into the package namespace (e.g. `$text`, `$killer_id`). The Perl names are listed alongside Lua names below.

> Fields marked `(Lua only)` are object references available in the Lua `e` table but not as Perl scalars (use `$npc`, `$client` etc. instead — see [Section 5](#5-perl-event-globals)).

### NPC Events

#### `event_say` / `EVENT_SAY`
| Field | Type | Perl | Description |
|---|---|---|---|
| `e.self` | NPC | `$npc` | The NPC receiving the say |
| `e.other` | Client | `$client` | The player who spoke |
| `e.message` | string | `$text` | The text spoken |
| `e.language` | int | `$langid` | Language ID used |

#### `event_trade` / `EVENT_ITEM`
| Field | Type | Perl | Description |
|---|---|---|---|
| `e.self` | NPC | `$npc` | The NPC |
| `e.other` | Client | `$client` | The player trading |
| `e.trade.item1` .. `e.trade.item4` | ItemInst | — | Items handed in (Lua only; use `e.trade.item1` etc.) |
| `e.trade.platinum` / `gold` / `silver` / `copper` | int | `$platinum` etc. | Money handed in |
| — | — | `$item1` .. `$item4` | Item IDs handed in (Perl) |
| — | — | `$item1_charges` .. `$item4_charges` | Charges per item (Perl) |
| — | — | `$item1_attuned` etc. | Is item attuned? (Perl) |
| — | — | `$item1_inst` etc. | QuestItem object (Perl) |
| — | — | `%itemcount` | Hash of `item_id => count` handed in (Perl) |

#### `event_death` / `EVENT_DEATH`
| Field | Type | Perl | Description |
|---|---|---|---|
| `e.self` | NPC | `$npc` | The NPC that died |
| `e.other` | Mob | `$client` | The killer. In Perl `$client` is only set when the killer is a client; use `$killer_id` with `$entity_list->GetMobID()` otherwise |
| `e.killer_id` | int | `$killer_id` | Entity ID of killer |
| `e.damage` | int | `$damage` | Final killing blow damage |
| `e.spell` | Spell | — | Spell that killed (or nil) |
| `e.skill_id` | int | `$skillid` | Skill used for killing blow |
| `e.killed_entity_id` | int | — | Same as killer_id |
| `e.combat_start_time` | int | — | Unix timestamp combat started |
| `e.combat_end_time` | int | — | Unix timestamp combat ended |
| `e.damage_received` | int64 | — | Total damage taken in fight |
| `e.healing_received` | int64 | — | Total healing received in fight |
| `e.corpse` | Corpse | — | Corpse object (Lua only) |
| `e.killed` | NPC | — | The NPC that was killed (Lua only) |

#### `event_spawn` / `EVENT_SPAWN`
| Field | Type | Description |
|---|---|---|
| `e.self` | NPC | The NPC that spawned. No other fields. |

#### `event_death_complete` / `EVENT_DEATH_COMPLETE`
Same fields as `event_death`. Fires after loot/XP have been processed (post-death cleanup). Cannot prevent death.

#### `event_combat` / `EVENT_COMBAT`
| Field | Type | Perl | Description |
|---|---|---|---|
| `e.self` | NPC | `$npc` | The NPC |
| `e.other` | Mob | `$client` | The combatant |
| `e.joined` | bool | `$joined` | `true` = entered combat, `false` = left combat |

#### `event_aggro` / `EVENT_AGGRO`
| Field | Type | Description |
|---|---|---|
| `e.self` | NPC | NPC entering combat |
| `e.other` | Mob | The mob that caused aggro |

#### `event_slay` / `EVENT_SLAY`
| Field | Type | Description |
|---|---|---|
| `e.self` | NPC | The NPC that killed |
| `e.other` | Mob | The mob that was killed |

#### `event_npc_slay` / `EVENT_NPC_SLAY`
| Field | Type | Description |
|---|---|---|
| `e.self` | NPC | The NPC that killed |
| `e.other` | Mob | The NPC that was slain |

#### `event_waypoint_arrive` / `EVENT_WAYPOINT_ARRIVE`
| Field | Type | Perl | Description |
|---|---|---|---|
| `e.self` | NPC | `$npc` | The NPC |
| `e.other` | Mob | — | Unused (always nil) |
| `e.wp` | int | `$wp` | Waypoint number arrived at |

#### `event_waypoint_depart` / `EVENT_WAYPOINT_DEPART`
| Field | Type | Perl | Description |
|---|---|---|---|
| `e.self` | NPC | `$npc` | The NPC |
| `e.wp` | int | `$wp` | Waypoint number departed from |

#### `event_timer` / `EVENT_TIMER`

> **Timer units:** Lua `eq.set_timer(name, ms)` takes **milliseconds**. Perl `quest::settimer(name, sec)` takes **seconds**; use `quest::settimerMS(name, ms)` for milliseconds. Getting this wrong by a factor of 1000 is a common bug.

| Field | Type | Perl | Description |
|---|---|---|---|
| `e.self` | NPC | `$npc` | The NPC |
| `e.timer` | string | `$timer` | Name of the timer that fired |

#### `event_signal` / `EVENT_SIGNAL`
| Field | Type | Perl | Description |
|---|---|---|---|
| `e.self` | NPC | `$npc` | The NPC |
| `e.signal` | int | `$signal` | Signal ID sent |

#### `event_hp` / `EVENT_HP`
| Field | Type | Perl | Description |
|---|---|---|---|
| `e.self` | NPC | `$npc` | The NPC |
| `e.hp_event` | int | `$hpevent` | HP% threshold crossed (decreasing), or -1 if increasing |
| `e.inc_hp_event` | int | `$inchpevent` | HP% threshold crossed (increasing), or -1 if decreasing |

#### `event_enter` / `EVENT_ENTER`
| Field | Type | Description |
|---|---|---|
| `e.self` | NPC | The NPC |
| `e.other` | Client | The client who entered proximity |

#### `event_exit` / `EVENT_EXIT`
Same as `event_enter` — `e.other` is the client who left proximity.

#### `event_aggro_say` / `EVENT_AGGRO_SAY`
Same fields as `event_say`.

#### `event_proximity_say` / `EVENT_PROXIMITY_SAY`
Same fields as `event_say`.

#### `event_task_accepted` / `EVENT_TASKACCEPTED`
| Field | Type | Perl | Description |
|---|---|---|---|
| `e.self` | NPC | `$npc` | The NPC |
| `e.other` | Client | `$client` | The client accepting |
| `e.task_id` | int | `$task_id` | Task ID accepted |

#### `event_popup_response` / `EVENT_POPUPRESPONSE`
| Field | Type | Perl | Description |
|---|---|---|---|
| `e.self` | NPC | `$npc` | The NPC |
| `e.other` | Mob | `$client` | The client who responded |
| `e.popup_id` | int | `$popupid` | ID of the popup button clicked |

#### `event_cast_on` / `EVENT_CAST_ON`
| Field | Type | Perl | Description |
|---|---|---|---|
| `e.self` | NPC | `$npc` | The NPC targeted by the spell |
| `e.spell` | Spell | — | Spell that was cast |
| `e.caster_id` | int | `$caster_id` | Entity ID of caster |
| `e.caster_level` | int | `$caster_level` | Caster's level |
| `e.target_id` | int | `$target_id` | Entity ID of target |
| `e.target` | Mob | — | Target Mob object (Lua only) |

#### `event_cast` / `event_cast_begin` — `EVENT_CAST` / `EVENT_CAST_BEGIN`
Same fields as `event_cast_on`.

#### `event_enter_area` / `event_leave_area` — `EVENT_ENTER_AREA` / `EVENT_LEAVE_AREA`
| Field | Type | Perl | Description |
|---|---|---|---|
| `e.self` | NPC | `$npc` | The NPC |
| `e.area_id` | int | `$areaid` | Area ID |
| `e.area_type` | int | `$areatype` | Area type |

#### `event_hate_list` / `EVENT_HATE_LIST`
| Field | Type | Perl | Description |
|---|---|---|---|
| `e.self` | NPC | `$npc` | The NPC |
| `e.other` | Mob | — | Mob added/removed from hate list |
| `e.joined` | bool | `$joined` | `true` = added, `false` = removed |

#### `event_payload` / `EVENT_PAYLOAD`
| Field | Type | Perl | Description |
|---|---|---|---|
| `e.self` | NPC | `$npc` | The NPC |
| `e.payload_id` | int | `$payload_id` | Payload ID |
| `e.payload_value` | string | `$payload_value` | Payload data string |

#### `event_loot_zone` / `EVENT_LOOT_ZONE`
| Field | Type | Description |
|---|---|---|
| `e.self` | NPC | Zone controller NPC |
| `e.other` | Client | The looting client |
| `e.item` | ItemInst | Item being looted |
| `e.corpse` | Corpse | Corpse being looted from |

#### `event_spawn_zone` / `EVENT_SPAWN_ZONE`
| Field | Type | Description |
|---|---|---|
| `e.self` | NPC | Zone controller NPC |
| `e.other` | NPC | The NPC that spawned |

#### `event_death_zone` / `EVENT_DEATH_ZONE`
| Field | Type | Description |
|---|---|---|
| `e.self` | NPC | Zone controller NPC |
| `e.other` | Mob | The mob that died |

#### `event_despawn_zone` / `EVENT_DESPAWN_ZONE`
| Field | Type | Description |
|---|---|---|
| `e.self` | NPC | Zone controller NPC |
| `e.other` | Mob | The mob that despawned |

#### `event_damage_given` / `event_damage_taken` — `EVENT_DAMAGE_GIVEN` / `EVENT_DAMAGE_TAKEN`
| Field | Type | Perl | Description |
|---|---|---|---|
| `e.self` | NPC/Mob | `$npc` | The mob giving or taking damage |
| `e.other` | Mob | `$client` | The other party |
| `e.entity_id` | int | `$entity_id` | Entity ID of other party |
| `e.damage` | int64 | `$damage` | Damage amount |
| `e.spell_id` | int | `$spell_id` | Spell ID (or -1 for melee) |
| `e.skill_id` | int | `$skill_id` | Attack skill ID |
| `e.is_damage_shield` | bool | `$is_ds` | Was damage shield? |
| `e.is_avoidable` | bool | `$is_avoidable` | Was avoidable? |
| `e.buff_slot` | int | — | Buff slot (if DoT) |
| `e.is_buff_tic` | bool | — | Is a DoT tick? |
| `e.special_attack` | int | — | Special attack type |

#### `event_loot_added` / `EVENT_LOOT_ADDED`
| Field | Type | Description |
|---|---|---|
| `e.self` | NPC | The NPC loot was added to |
| `e.item` | Item | ItemData of added item |
| `e.item_id` | int | Item ID |
| `e.item_name` | string | Item name |
| `e.item_charges` | int | Charges |
| `e.augment_one` .. `e.augment_six` | int | Augment item IDs |

#### `event_timer_pause` / `event_timer_resume` / `event_timer_start` — `EVENT_TIMER_PAUSE/RESUME/START`
| Field | Type | Description |
|---|---|---|
| `e.self` | NPC | The NPC |
| `e.timer` | string | Timer name |
| `e.duration` | int | Duration in ms |

#### `event_timer_stop` — `EVENT_TIMER_STOP`
| Field | Type | Description |
|---|---|---|
| `e.self` | NPC | The NPC |
| `e.timer` | string | Timer name |

#### `event_entity_variable_set` — `EVENT_ENTITY_VARIABLE_SET`
| Field | Type | Description |
|---|---|---|
| `e.self` | NPC | The NPC |
| `e.variable_name` | string | Variable name |
| `e.variable_value` | string | Variable value |

#### `event_entity_variable_update` — `EVENT_ENTITY_VARIABLE_UPDATE`
| Field | Type | Description |
|---|---|---|
| `e.self` | NPC | The NPC |
| `e.variable_name` | string | Variable name |
| `e.old_value` | string | Previous value |
| `e.new_value` | string | New value |

#### `event_entity_variable_delete` — `EVENT_ENTITY_VARIABLE_DELETE`
Same as `event_entity_variable_set`.

#### `event_spell_blocked` — `EVENT_SPELL_BLOCKED`
| Field | Type | Description |
|---|---|---|
| `e.self` | NPC | The NPC |
| `e.blocking_spell_id` | int | ID of blocking spell |
| `e.cast_spell_id` | int | ID of spell that was blocked |
| `e.blocking_spell` | Spell | Blocking Spell object |
| `e.cast_spell` | Spell | Cast Spell object |

---

### Player Events

#### `event_say` (player.lua) / `EVENT_SAY` (player.pl)
| Field | Type | Perl | Description |
|---|---|---|---|
| `e.self` | Client | `$client` | The player |
| `e.message` | string | `$text` | Text spoken |
| `e.language` | int | `$langid` | Language ID |

#### `event_death` (player) / `EVENT_DEATH`
| Field | Type | Perl | Description |
|---|---|---|---|
| `e.self` | Client | `$client` | Player who died |
| `e.other` | Mob | — | Killer mob |
| `e.killer_id` | int | `$killer_id` | Killer entity ID |
| `e.damage` | int | `$damage` | Killing blow damage |
| `e.spell` | Spell | — | Killing spell (or nil) |
| `e.skill` | int | `$skill` | Killing skill |
| `e.killed_entity_id` | int | — | Same as killer_id |
| `e.combat_start_time` | int | — | Combat start timestamp |
| `e.combat_end_time` | int | — | Combat end timestamp |
| `e.damage_received` | int64 | — | Total damage in fight |
| `e.healing_received` | int64 | — | Total healing in fight |

#### `event_timer` (player) / `EVENT_TIMER`
| Field | Type | Perl | Description |
|---|---|---|---|
| `e.self` | Client | `$client` | The player |
| `e.timer` | string | `$timer` | Timer name |

#### `event_signal` (player) / `EVENT_SIGNAL`
| Field | Type | Perl | Description |
|---|---|---|---|
| `e.self` | Client | `$client` | The player |
| `e.signal` | int | `$signal` | Signal ID |

#### `event_enter_zone` / `EVENT_ENTERZONE`
| Field | Type | Description |
|---|---|---|
| `e.self` | Client | The player entering the zone. No extra fields. |

#### `event_zone` / `EVENT_ZONE`
| Field | Type | Perl | Description |
|---|---|---|---|
| `e.self` | Client | `$client` | The player |
| `e.from_zone_id` | int | `$from_zoneid` | Zone ID zoning from |
| `e.from_instance_id` | int | `$from_instanceid` | Instance ID zoning from |
| `e.from_instance_version` | int | — | Version of source instance |
| `e.zone_id` | int | `$zoneid` | Destination zone ID |
| `e.instance_id` | int | `$instanceid` | Destination instance ID |
| `e.instance_version` | int | — | Destination instance version |

#### `event_loot` / `EVENT_LOOT`
| Field | Type | Description |
|---|---|---|
| `e.self` | Client | The player looting |
| `e.item` | ItemInst | The item looted |
| `e.corpse` | Corpse | The corpse looted from |

#### `event_click_door` / `EVENT_CLICKDOOR`
| Field | Type | Perl | Description |
|---|---|---|---|
| `e.self` | Client | `$client` | The player |
| `e.door` | Door | `$door` | The door clicked |

#### `event_click_object` / `EVENT_CLICK_OBJECT`
| Field | Type | Perl | Description |
|---|---|---|---|
| `e.self` | Client | `$client` | The player |
| `e.object` | Object | `$object` | The world object clicked |

#### `event_popup_response` (player) / `EVENT_POPUPRESPONSE`
| Field | Type | Perl | Description |
|---|---|---|---|
| `e.self` | Client | `$client` | The player |
| `e.popup_id` | int | `$popupid` | Popup ID of button clicked |

#### `event_task_accepted` (player) / `EVENT_TASKACCEPTED`
| Field | Type | Perl | Description |
|---|---|---|---|
| `e.self` | Client | `$client` | The player |
| `e.task_id` | int | `$task_id` | Task accepted |

#### `event_task_stage_complete` / `EVENT_TASK_STAGE_COMPLETE`
| Field | Type | Perl | Description |
|---|---|---|---|
| `e.self` | Client | `$client` | The player |
| `e.task_id` | int | `$task_id` | Task ID |
| `e.activity_id` | int | `$activity_id` | Stage that completed |

#### `event_task_update` / `EVENT_TASK_UPDATE`
| Field | Type | Perl | Description |
|---|---|---|---|
| `e.self` | Client | `$client` | The player |
| `e.task_id` | int | `$task_id` | Task ID |
| `e.activity_id` | int | `$activity_id` | Activity updated |
| `e.count` | int | `$count` | New count value |

#### `event_task_fail` / `EVENT_TASK_FAIL`
| Field | Type | Perl | Description |
|---|---|---|---|
| `e.self` | Client | `$client` | The player |
| `e.task_id` | int | `$task_id` | Task that failed |

#### `event_command` / `EVENT_COMMAND`
| Field | Type | Perl | Description |
|---|---|---|---|
| `e.self` | Client | `$client` | The player |
| `e.command` | string | `$command` | Command text (without leading `/`) |
| `e.args` | table | `@args` | Array of arguments |

#### `event_level_up` / `EVENT_LEVEL_UP`
| Field | Type | Perl | Description |
|---|---|---|---|
| `e.self` | Client | `$client` | The player |
| `e.levels_gained` | int | `$levels` | Number of levels gained |

#### `event_level_down` / `EVENT_LEVEL_DOWN`
| Field | Type | Perl | Description |
|---|---|---|---|
| `e.self` | Client | `$client` | The player |
| `e.levels_lost` | int | `$levels` | Levels lost |

#### `event_exp_gain` / `EVENT_EXP_GAIN`
| Field | Type | Perl | Description |
|---|---|---|---|
| `e.self` | Client | `$client` | The player |
| `e.exp_gained` | int64 | `$exp` | Experience gained |

#### `event_aa_gain` / `EVENT_AA_GAIN`
| Field | Type | Perl | Description |
|---|---|---|---|
| `e.self` | Client | `$client` | The player |
| `e.aa_gained` | int | `$aa_points` | AA points gained |

#### `event_aa_buy` / `EVENT_AA_BUY`
| Field | Type | Perl | Description |
|---|---|---|---|
| `e.self` | Client | `$client` | The player |
| `e.aa_id` | int | `$aa_id` | AA purchased |
| `e.aa_cost` | int | `$aa_cost` | Points spent |
| `e.aa_previous_id` | int | — | Previous rank ID |
| `e.aa_next_id` | int | — | Next rank ID |

#### `event_discover_item` / `EVENT_DISCOVER_ITEM`
| Field | Type | Perl | Description |
|---|---|---|---|
| `e.self` | Client | `$client` | The player |
| `e.item` | Item | `$item` | ItemData discovered |

#### `event_forage_success` / `event_fish_success` — `EVENT_FORAGE_SUCCESS` / `EVENT_FISH_SUCCESS`
| Field | Type | Description |
|---|---|---|
| `e.self` | Client | The player |
| `e.item` | ItemInst | Item foraged/fished |

#### `event_duel_win` / `EVENT_DUEL_WIN`
| Field | Type | Description |
|---|---|---|
| `e.self` | Client | The winner |
| `e.other` | Client | The loser |

#### `event_duel_lose` / `EVENT_DUEL_LOSE`
| Field | Type | Description |
|---|---|---|
| `e.self` | Client | The loser |
| `e.other` | Client | The winner |

#### `event_feign_death` / `EVENT_FEIGN_DEATH`
| Field | Type | Description |
|---|---|---|
| `e.self` | Client | The player feigning |
| `e.other` | NPC | The NPC that was engaging them |

#### `event_combine` / `event_combine_success` / `event_combine_failure`
| Field | Type | Perl | Description |
|---|---|---|---|
| `e.self` | Client | `$client` | The player |
| `e.recipe_id` | int | `$recipe_id` | Recipe ID |
| `e.recipe_name` | string | `$recipe_name` | Recipe name |

#### `event_combine_validate` / `EVENT_COMBINE_VALIDATE`
| Field | Type | Perl | Description |
|---|---|---|---|
| `e.self` | Client | `$client` | The player |
| `e.recipe_id` | int | `$recipe_id` | Recipe ID |
| `e.validate_type` | string | `$validate_type` | `"check_zone"` or `"check_tradeskill"` |
| `e.zone_id` | int | — | Zone ID (when validate_type = check_zone) |
| `e.tradeskill_id` | int | — | Tradeskill ID (when validate_type = check_tradeskill) |

#### `event_respawn` / `EVENT_RESPAWN`
| Field | Type | Perl | Description |
|---|---|---|---|
| `e.self` | Client | `$client` | The player |
| `e.option` | int | `$option` | Respawn option selected |
| `e.resurrect` | bool | `$resurrect` | Was a rez used? |

#### `event_warp` / `EVENT_WARP`
| Field | Type | Perl | Description |
|---|---|---|---|
| `e.self` | Client | `$client` | The player |
| `e.from_x` | float | `$from_x` | X before warp |
| `e.from_y` | float | `$from_y` | Y before warp |
| `e.from_z` | float | `$from_z` | Z before warp |

#### `event_consider` / `EVENT_CONSIDER`
| Field | Type | Description |
|---|---|---|
| `e.self` | Client | The player |
| `e.entity_id` | int | Entity ID considered |
| `e.other` | Mob | The mob considered |

#### `event_use_skill` / `EVENT_USE_SKILL`
| Field | Type | Perl | Description |
|---|---|---|---|
| `e.self` | Client | `$client` | The player |
| `e.skill_id` | int | `$skill_id` | Skill ID used |
| `e.skill_level` | int | `$skill_level` | Current skill level after skill-up |

#### `event_skill_up` / `EVENT_SKILL_UP`
| Field | Type | Perl | Description |
|---|---|---|---|
| `e.self` | Client | `$client` | The player |
| `e.skill_id` | int | `$skill_id` | Skill ID that increased |
| `e.skill_value` | int | `$skill_value` | New skill value |
| `e.skill_max` | int | `$skill_max` | Current skill cap |
| `e.is_tradeskill` | int | `$is_tradeskill` | Non-zero if this is a tradeskill |

#### `event_connect` / `EVENT_CONNECT`
| Field | Type | Perl | Description |
|---|---|---|---|
| `e.self` | Client | `$client` | The player |
| `e.last_login` | int | `$last_login` | Unix timestamp of last login |
| `e.seconds_since_last_login` | int | `$seconds_since_last_login` | Seconds since last login |
| `e.is_first_login` | bool | `$first_login` | Is this first login ever? |

#### `event_disconnect` / `EVENT_DISCONNECT`
| Field | Type | Description |
|---|---|---|
| `e.self` | Client | The disconnecting player. No extra fields. |

#### `event_payload` (player) / `EVENT_PAYLOAD`
| Field | Type | Perl | Description |
|---|---|---|---|
| `e.self` | Client | `$client` | The player |
| `e.payload_id` | int | `$payload_id` | Payload ID |
| `e.payload_value` | string | `$payload_value` | Payload data |

#### `event_item_click` / `EVENT_ITEM_CLICK`
| Field | Type | Perl | Description |
|---|---|---|---|
| `e.self` | Client | `$client` | The player |
| `e.slot_id` | int | `$slot_id` | Inventory slot |
| `e.item_id` | int | `$item_id` | Item ID clicked |
| `e.item_name` | string | `$item_name` | Item name |
| `e.spell_id` | int | `$spell_id` | Click effect spell ID |
| `e.item` | ItemInst | — | ItemInstance (Lua only) |

#### `event_drop_item` / `EVENT_DROP_ITEM`
| Field | Type | Perl | Description |
|---|---|---|---|
| `e.self` | Client | `$client` | The player |
| `e.slot_id` | int | `$slot_id` | Slot dropped from |
| `e.item_id` | int | `$item_id` | Item ID |
| `e.item_name` | string | `$item_name` | Item name |
| `e.quantity` | int | `$quantity` | Quantity dropped |

#### `event_destroy_item` / `EVENT_DESTROY_ITEM`
| Field | Type | Perl | Description |
|---|---|---|---|
| `e.self` | Client | `$client` | The player |
| `e.item_id` | int | `$item_id` | Item destroyed |
| `e.item_name` | string | `$item_name` | Item name |
| `e.quantity` | int | `$quantity` | Quantity |

#### `event_memorize_spell` / `event_unmemorize_spell` / `event_scribe_spell` / `event_unscribe_spell`
| Field | Type | Perl | Description |
|---|---|---|---|
| `e.self` | Client | `$client` | The player |
| `e.slot_id` | int | `$slot_id` | Spell book / gem slot |
| `e.spell_id` | int | `$spell_id` | Spell ID |
| `e.spell` | Spell | — | Spell object (Lua only) |

#### `event_ldon_points_gain` / `event_ldon_points_loss`
| Field | Type | Perl | Description |
|---|---|---|---|
| `e.self` | Client | `$client` | The player |
| `e.theme_id` | int | `$theme_id` | LDoN theme ID |
| `e.points` | int | `$points` | Points amount |

#### `event_crystal_gain` / `event_crystal_loss`
| Field | Type | Perl | Description |
|---|---|---|---|
| `e.self` | Client | `$client` | The player |
| `e.ebon_amount` | int | `$ebon` | Ebon crystals |
| `e.radiant_amount` | int | `$radiant` | Radiant crystals |
| `e.is_reclaim` | bool | `$is_reclaim` | Was this a reclaim? |

#### `event_alt_currency_gain` / `event_alt_currency_loss`
| Field | Type | Perl | Description |
|---|---|---|---|
| `e.self` | Client | `$client` | The player |
| `e.currency_id` | int | `$currency_id` | Alt currency type ID |
| `e.amount` | int | `$amount` | Amount changed |
| `e.total` | int | `$total` | New total |

#### `event_target_change` / `EVENT_TARGET_CHANGE`
| Field | Type | Description |
|---|---|---|
| `e.self` | Client | The player |
| `e.other` | Mob | The new target (nil if detargeted) |

#### `event_read_item` / `EVENT_READ_ITEM`
| Field | Type | Description |
|---|---|---|
| `e.self` | Client | The player |
| `e.text_file` | string | Book text file |
| `e.item_id` | int | Item ID read |
| `e.book_text` | string | Full book text |
| `e.can_cast` | bool | Can the player cast it? |
| `e.can_scribe` | bool | Can the player scribe it? |
| `e.slot_id` | int | Inventory slot |
| `e.target_id` | int | Target entity ID |
| `e.type` | int | Book type |
| `e.item` | ItemInst | The item |

#### `event_bot_create` / `EVENT_BOT_CREATE`
| Field | Type | Perl | Description |
|---|---|---|---|
| `e.self` | Client | `$client` | The owner |
| `e.bot_name` | string | `$bot_name` | Bot name |
| `e.bot_id` | int | `$bot_id` | Bot DB ID |
| `e.bot_race` | int | `$bot_race` | Race ID |
| `e.bot_class` | int | `$bot_class` | Class ID |
| `e.bot_gender` | int | `$bot_gender` | Gender ID |

---

### Item Script Events

Item scripts live in `quests/global/items/ITEM_ID.lua` (or `.pl`). The `e.self` is the **Client**, and `e.item` is the **ItemInstance**.

#### `event_item_click` (item script) / `EVENT_ITEM_CLICK`
| Field | Type | Description |
|---|---|---|
| `e.self` | Client | Player clicking |
| `e.item` | ItemInst | The item |
| `e.slot_id` | int | Slot clicked from |

#### `event_weapon_proc` / `EVENT_WEAPON_PROC`
| Field | Type | Description |
|---|---|---|
| `e.self` | Client | Player owner |
| `e.item` | ItemInst | The weapon |
| `e.target` | Mob | Mob targeted by the proc |
| `e.spell` | Spell | The proc spell |

#### `event_loot` (item script) / `EVENT_LOOT`
| Field | Type | Description |
|---|---|---|
| `e.self` | Client | Player looting |
| `e.item` | ItemInst | The item |
| `e.corpse` | Corpse | The source corpse (or nil) |

#### `event_equip_item` / `event_unequip_item` — `EVENT_EQUIP_ITEM` / `EVENT_UNEQUIP_ITEM`
| Field | Type | Description |
|---|---|---|
| `e.self` | Client | Player equipping |
| `e.item` | ItemInst | The item |
| `e.slot_id` | int | Equipment slot |

#### `event_augment_item` / `event_unaugment_item` — `EVENT_AUGMENT_ITEM` / `EVENT_UNAUGMENT_ITEM`
| Field | Type | Description |
|---|---|---|
| `e.self` | Client | Player |
| `e.item` | ItemInst | The item |
| `e.aug` | ItemInst | The augment |
| `e.slot_id` | int | Augment slot |

#### `event_augment_insert` / `event_augment_remove` — `EVENT_AUGMENT_INSERT` / `EVENT_AUGMENT_REMOVE`
| Field | Type | Description |
|---|---|---|
| `e.self` | Client | Player |
| `e.item` | ItemInst | Container item receiving/losing augment |
| `e.slot_id` | int | Augment socket slot |
| `e.destroyed` | bool | (`remove` only) Was augment destroyed? |

#### `event_timer` (item script) / `EVENT_TIMER`
| Field | Type | Description |
|---|---|---|
| `e.self` | Client | Player |
| `e.item` | ItemInst | The item |
| `e.timer` | string | Timer name |

---

### Encounter Script Events

Encounter scripts live at `quests/global/encounters/encounter_name.lua` (or `.pl`). They are loaded and unloaded programmatically. `e.self` is the `Encounter` object, not a Mob.

#### `event_encounter_load` / `EVENT_ENCOUNTER_LOAD`
| Field | Type | Description |
|---|---|---|
| `e.self` | Encounter | The encounter object |
| `e.encounter` | Encounter | Same encounter object (Lua only) |
| `e.data` | string | Optional data string passed at load time |

#### `event_encounter_unload` / `EVENT_ENCOUNTER_UNLOAD`
| Field | Type | Description |
|---|---|---|
| `e.self` | Encounter | The encounter object |
| `e.data` | string | Optional data string |

#### `event_timer` (encounter) / `EVENT_TIMER`
| Field | Type | Description |
|---|---|---|
| `e.self` | Encounter | The encounter object |
| `e.timer` | string | Name of the timer that fired |

All other encounter events (`event_death`, `event_spawn`, etc.) dispatch with a null handler — no extra fields are populated.

**Lua encounter usage example:**
```lua
-- quests/global/encounters/my_encounter.lua
function event_encounter_load(e)
    -- e.data contains the string passed to eq.load_encounter()
    eq.set_timer("my_timer", 5000)
end

function event_timer(e)
    if e.timer == "my_timer" then
        -- do something
    end
end
```

**Perl encounter usage example:**
```perl
# quests/global/encounters/my_encounter.pl
sub EVENT_ENCOUNTER_LOAD {
    quest::settimer("my_timer", 5);
}

sub EVENT_TIMER {
    if ($timer eq "my_timer") {
        # do something
    }
}
```

---

## 5. Perl Event Globals

These variables are automatically set in the Perl package namespace before each event sub is called. You do not need to declare them.

### Always Available

| Variable | Type | Description |
|---|---|---|
| `$entity_list` | EntityList | The zone entity list |
| `$charid` | int | Character ID of the involved client (negative NPC type ID if no client) |

### NPC Script Globals

| Variable | Type | Description |
|---|---|---|
| `$npc` | NPC | The NPC the script is attached to |
| `$client` | Client | The involved client (may be undef if no player involved) |

### Player Script Globals

| Variable | Type | Description |
|---|---|---|
| `$client` | Client | The player |

### Item Script Globals

| Variable | Type | Description |
|---|---|---|
| `$client` | Client | The player |
| `$questitem` | QuestItem | The item instance |

### Spell Script Globals

| Variable | Type | Description |
|---|---|---|
| `$client` | Client | The client (if applicable) |
| `$npc` | NPC | The NPC (if applicable) |
| `$spell` | Spell | The spell |

### Mob Export Variables (set when `mob` export is enabled for the event)

These are flat scalar exports set alongside the object references:

| Variable | Description |
|---|---|
| `$name` | Client's name |
| `$race` | Client's race name |
| `$class` | Client's class name |
| `$ulevel` | Client's level |
| `$userid` | Client's entity ID |
| `$uguild_id` | Client's guild ID |
| `$uguildrank` | Client's guild rank |
| `$status` | Client's GM status |
| `$mname` | NPC's name |
| `$mobid` | NPC's entity ID |
| `$mlevel` | NPC's level |
| `$hpratio` | NPC's HP percentage |
| `$x`, `$y`, `$z`, `$h` | NPC's coordinates |
| `$targetid` | NPC's current target entity ID |
| `$targetname` | NPC's current target name |
| `$faction` | Faction level of client toward NPC |

### Zone Export Variables (set when `zone` export is enabled)

| Variable | Description |
|---|---|
| `$zone` | Zone object |
| `$zoneid` | Zone ID |
| `$zonesn` | Zone short name |
| `$zoneln` | Zone long name |
| `$zonehour` | Current EQ hour |
| `$zonemin` | Current EQ minute |
| `$zonetime` | Hour*100 + minute |
| `$zoneweather` | Weather state |
| `$zoneuptime` | Uptime in seconds |
| `$instanceid` | Instance ID |
| `$instanceversion` | Instance version |

### Item Inventory Variables (set when `item` export is enabled)

| Variable | Description |
|---|---|
| `%hasitem` | Hash of `item_id => [slot, ...]` for all equipped/inventory items |
| `%oncursor` | Hash for item currently on cursor |

### Quest Globals

When the NPC has the `qglobal` flag set, applicable quest globals are exported as individual package scalars (e.g. `$my_flag_name`) **and** as the hash `%qglobals`.

---

## 6. Event Return Values

Most event handlers ignore the return value. The following events check it and change behavior based on what is returned:

### `event_death` / `EVENT_DEATH` — NPC only

Return a **non-zero integer** to prevent the NPC from dying (the kill is cancelled and the NPC's HP is set to 0 but it lives).

```lua
function event_death(e)
    -- Prevent death and heal NPC back up
    e.self:SetHP(e.self:GetMaxHP())
    return 1  -- non-zero = cancel death
end
```

```perl
sub EVENT_DEATH {
    $npc->SetHP($npc->GetMaxHP());
    return 1;  # non-zero = cancel death
}
```

> **Note:** `event_death_complete` fires after loot/XP and **cannot** prevent death. Use `event_death` for that.

### `event_death` / `EVENT_DEATH` — Player only

Return a **non-zero integer** to prevent the player from dying (the kill is cancelled and HP is clamped to 0).

### `event_combine_validate` / `EVENT_COMBINE_VALIDATE`

Return value controls whether the combine is allowed:
- **0** = use default behavior
- **1** = allow the combine regardless of normal checks
- **-1** = deny the combine

```lua
function event_combine_validate(e)
    -- Only allow this recipe in the tutorial zone
    if e.validate_type == "check_zone" and e.zone_id ~= 189 then
        return -1
    end
    return 0
end
```

### `event_command` / `EVENT_COMMAND`

Return value is added to the "found commands" count. Return **1** to indicate the command was handled (suppresses "unknown command" message). Return **0** to let it fall through.

```lua
function event_command(e)
    if e.command == "mycommand" then
        e.self:Message(15, "You used mycommand!")
        return 1
    end
    return 0
end
```

### `event_hate_list` / `EVENT_HATE_LIST`

No return value checked.

### All other events

Return value is read but ignored by the engine. Any return value is safe.

---

## 7. Handin Workflow

Item hand-ins are the most common NPC quest pattern. On this server the mechanics are the same in both languages:

- The server validates the hand-in with `NPC::CheckHandin()`, which **consumes exactly the items and money you declared as required** and leaves everything else on the trade.
- Anything not consumed is **returned automatically** by `ReturnHandinItems()` / the `Items:AlwaysReturnHandins` rule (default `true`, `zone/trading.cpp:676`). You do not re-summon items by hand.
- ⚠ **Normalise item ids with `% 1000000`** before comparing (§0.1). `plugin::check_handin` and `items.check_turn_in` do not do this for you; a Legendary quest item has a different id.

### Perl

Use the `plugin::check_handin` wrapper from `plugins/check_handin.pl`. It reads the event's `$item1..4_inst` objects and money globals, then calls `$npc->CheckHandin($client, \%handin, \%required, @item_insts)`.

```perl
sub EVENT_ITEM {
    # want 1x item 1001 and 1x item 1002; money keys are "platinum"/"gold"/"silver"/"copper"
    if (plugin::check_handin(\%itemcount, 1001 => 1, 1002 => 1)) {
        quest::say("Thank you! Here is your reward.");
        quest::summonitem(2001);          # rolls an upgrade tier on this server
        # quest::summonfixeditem(2001);   # exact item, no tier roll
    }
    plugin::return_items(\%itemcount);    # no-op stub kept for readability; the server returns leftovers
}
```

`while (plugin::check_handin(\%itemcount, 2827 => 1)) { ... }` consumes repeatedly for multi-stack hand-ins (see `global/Other_Elvish_Security_Officer.pl`).

Raw event data if you need it: `$item1..$item4` (ids), `$item1_charges`, `$item1_attuned`, `$item1_inst` (QuestItem), `%itemcount` (`id => count`), `$platinum`/`$gold`/`$silver`/`$copper`.

### Lua

Use `items.check_turn_in` from `lua_modules/items.lua`. It builds the handin/required tables from `e.trade` and calls `e.self:CheckHandin(e.other, handin, required, item_insts)`.

```lua
local items = require("items")

function event_trade(e)
    if items.check_turn_in(e.trade, { item1 = 1001, item2 = 1002 }) then
        e.self:Say("Thank you! Here is your reward.")
        e.other:SummonItem(2001)          -- rolls an upgrade tier on this server
        -- e.other:SummonFixedItem(2001)  -- exact item
    end
    items.return_items(e.self, e.other, e.trade)  -- calls npc:ReturnHandinItems(client)
end
```

`trade_check` accepts `item1..item4` and `platinum`/`gold`/`silver`/`copper` keys. Raw event data: `e.trade.item1..item4` (ItemInstance, check `.valid`), `e.trade.platinum` etc.

### Direct API

| Method | Lua | Perl |
|---|---|---|
| Validate + consume | `npc:CheckHandin(client, handin_tbl, required_tbl, items_tbl)` | `$npc->CheckHandin($client, \%handin, \%required, @item_insts)` |
| Return leftovers | `npc:ReturnHandinItems(client)` | `$npc->ReturnHandinItems($client)` |
| Fire the player-side handin event | `eq.send_player_handin_event()` | `quest::send_player_handin_event()` |
| Programmatic handin | `eq.handin(...)` | `quest::handin(...)` |

`global/global_npc.pl` runs `plugin::CustomEventHandinEntry()` before any NPC's `EVENT_ITEM`; returning 1 from that hook swallows the hand-in (§0.4).

---

## 8. Global API

These functions are called via `eq.function_name()` in Lua or `quest::function_name()` in Perl.

### Output / Communication

| Function | Description | Example |
|---|---|---|
| `say(msg)` | NPC says text in local chat | `eq.say("Hello!")` |
| `me(msg)` | NPC emotes text | `eq.me("waves at you.")` |
| `shout(msg)` | NPC shouts zone-wide | `eq.shout("Help!")` |
| `whisper(msg)` | NPC whispers to client | `eq.whisper("Secret.")` |
| `message(color, msg)` | Send colored message to client | `eq.message(15, "Red text")` |
| `gmsay(msg [,color [,world [,guild_id [,min_status]]]])` | Send GM channel message | `eq.gmsay("Debug", 15, false)` |
| `popup(title, text [,id [,buttons [,duration]]])` | Show a popup window to the client. `buttons`: 0=OK, 1=OK+Cancel | `eq.popup("Welcome", "Hello traveler", 1, 1, 60)` |
| `send_mail(to, from, subject, body)` | Send in-game mail | `eq.send_mail("Player", "NPC", "Hi", "Hello")` |
| `marquee(type, msg [,duration])` | Zone-wide marquee message | `eq.marquee(0, "Boss spawned!", 5000)` |
| `discord_send(channel, msg)` | Send message to Discord webhook | `eq.discord_send("general", "Event started")` |
| `voice_tell(...)` | Send voice tell | — |
| `zone_emote(type, msg)` | Send emote to entire zone | — |
| `world_emote(type, msg)` | Send emote to entire world | — |

### Spawn / NPC Management

| Function | Description | Example |
|---|---|---|
| `spawn2(npc_type_id, grid, unused, x, y, z, h)` | Spawn an NPC at coordinates; returns Mob | `local mob = eq.spawn2(1234, 0, 0, 100, 200, 5, 0)` |
| `unique_spawn(npc_type_id, grid, unused, x, y, z [,h])` | Spawn NPC only if not already spawned | — |
| `spawn_from_spawn2(spawn2_id)` | Spawn using a spawn2 entry | `eq.spawn_from_spawn2(456)` |
| `enable_spawn2(id)` / `disable_spawn2(id)` | Enable or disable a spawn2 entry | `eq.enable_spawn2(100)` |
| `depop([npc_type_id])` | Depop NPC (self if no arg) | `eq.depop()` |
| `depop_with_timer([npc_type_id])` | Depop and start respawn timer | `eq.depop_with_timer()` |
| `depop_all([npc_type_id])` | Depop all matching NPCs | — |
| `depop_zone(start_spawn_timers)` | Depop all NPCs in zone | `eq.depop_zone(0)` |
| `repop_zone([force])` | Repop zone NPCs | `eq.repop_zone(true)` |
| `process_mobs_while_zone_empty(bool)` | Keep processing when zone empty | — |
| `clear_npctype_cache()` | Clear the NPC type cache | — |
| `create_npc(...)` | Create a temporary NPC | — |
| `is_npc_spawned(id_table)` | Check if NPC type is spawned | `eq.is_npc_spawned({1234})` |
| `count_spawned_npcs(id_table)` | Count spawned NPCs by type | — |

### Timers

> **Lua:** durations in **milliseconds**. **Perl:** `settimer` in seconds; `settimerMS` in milliseconds.

| Function | Description | Example |
|---|---|---|
| `set_timer(name, ms)` | Start a named timer | `eq.set_timer("spawn", 30000)` |
| `stop_timer(name)` | Stop a named timer | `eq.stop_timer("spawn")` |
| `stop_all_timers()` | Stop all timers | `eq.stop_all_timers()` |
| `pause_timer(name)` | Pause a timer | `eq.pause_timer("spawn")` |
| `resume_timer(name)` | Resume a paused timer | `eq.resume_timer("spawn")` |
| `has_timer(name)` | Check if timer exists | `if eq.has_timer("spawn") then` |
| `is_paused_timer(name)` | Check if timer is paused | — |
| `get_remaining_time(name)` | Get remaining time in ms | `local ms = eq.get_remaining_time("t")` |
| `get_timer_duration(name)` | Get original duration | — |

### Tasks

| Function | Description | Example |
|---|---|---|
| `task_selector(task_id_table [,ignore_cooldown])` | Show task selection window | `eq.task_selector({101, 102})` |
| `task_set_selector(set_id [,ignore_cooldown])` | Show task set selector | — |
| `assign_task(task_id)` | Assign task to client | `eq.assign_task(101)` |
| `fail_task(task_id)` | Fail a task | `eq.fail_task(101)` |
| `complete_task(task_id)` | Complete a task | `eq.complete_task(101)` |
| `uncomplete_task(task_id)` | Mark task as uncomplete | — |
| `enable_task(task_id)` / `disable_task(task_id)` | Enable/disable task | — |
| `is_task_enabled(task_id)` | Check if task is enabled | — |
| `is_task_active(task_id)` | Check if client has task active | `if eq.is_task_active(101) then` |
| `is_task_activity_active(task_id, activity_id)` | Check specific activity | — |
| `is_task_completed(task_id)` | Check if task is completed | — |
| `is_task_appropriate(task_id)` | Check level appropriateness | — |
| `get_task_activity_done_count(task_id, activity_id)` | Get activity count | — |
| `update_task_activity(task_id, activity_id [,count])` | Update activity count | `eq.update_task_activity(101, 0, 1)` |
| `reset_task_activity(task_id, activity_id)` | Reset activity count | — |
| `task_time_left(task_id)` | Get time remaining on task | — |
| `get_task_name(task_id)` | Get task name string | `local name = eq.get_task_name(101)` |
| `get_dz_task_id()` | Get active DZ task ID | — |
| `end_dz_task([send_fail])` | End current DZ task | — |
| `are_tasks_completed(task_id_table)` | Check multiple tasks completed | `eq.are_tasks_completed({101, 102})` |

### Items / Inventory

| Function | Description | Example |
|---|---|---|
| `summonitem(item_id [,charges])` | **Perl only** (`quest::summonitem`). Lua uses `e.other:SummonItem()`. ⚠ Both roll an upgrade tier on this server — see §0.1; use `quest::summonfixeditem` / `client:SummonFixedItem()` for an exact item | `quest::summonitem(1001, 1)` |
| `collect_items(item_id, remove)` | Collect items from inventory | `eq.collect_items(1001, true)` |
| `count_item(item_id)` | Count item in inventory | `local n = eq.count_item(1001)` |
| `remove_item(item_id [,qty])` | Remove item from inventory | `eq.remove_item(1001, 1)` |
| `get_item_name(item_id)` | Get item name | `local name = eq.get_item_name(1001)` |
| `get_item_lore(item_id)` | Get item lore text | — |
| `get_item_comment(item_id)` | Get item comment text | — |
| `get_item_stat(item_id, stat)` | Get a numeric item stat by name | `local dmg = eq.get_item_stat(1001, "damage")` |
| `item_link(item_id)` | Generate an in-game item link string | `eq.say(eq.item_link(1001))` |
| `merchant_set_item(npc_id, item_id [,qty])` | Set merchant inventory | — |
| `merchant_count_item(npc_id, item_id)` | Count item in merchant stock | — |

### Spells

| Function | Description | Example |
|---|---|---|
| `cast_spell(spell_id, target_id)` | Cast spell on target entity ID | `eq.cast_spell(1, e.other:GetID())` |
| `self_cast(spell_id)` | Cast spell on self | `eq.self_cast(1)` |
| `get_spell_name(spell_id)` | Get spell name | `local n = eq.get_spell_name(1)` |
| `get_spell_level(spell_id, class_id)` | Get spell level for class | — |
| `get_spell_stat(spell_id, stat [,slot])` | Get spell stat by name | `eq.get_spell_stat(1, "cast_time")` |
| `is_beneficial_spell(spell_id)` | Check if spell is beneficial | `if eq.is_beneficial_spell(1) then` |
| `is_detrimental_spell(spell_id)` | Check if spell is detrimental | — |
| `scribe_spells(max_level [,min_level])` | Scribe all applicable spells | `eq.scribe_spells(65)` |
| `train_discs(max_level [,min_level])` | Train all applicable disciplines | — |
| `is_disc_tome(item_id)` | Check if item is a discipline tome | — |

### Data Buckets (Persistent Key-Value Store)

| Function | Description | Example |
|---|---|---|
| `get_data(key)` | Get a stored value | `local val = eq.get_data("event_done")` |
| `set_data(key, value [,expires])` | Store a value; optional expiry string (e.g. `"1d"`, `"5m"`) | `eq.set_data("event_done", "1", "7d")` |
| `delete_data(key)` | Delete a bucket entry | `eq.delete_data("event_done")` |
| `get_data_expires(key)` | Get expiry timestamp string | — |
| `get_data_remaining(key)` | Get remaining time string | — |

### Quest Globals

| Function | Description | Example |
|---|---|---|
| `set_global(key, value, options, duration)` | Set a quest global | `eq.set_global("flag", "1", 5, "F")` |
| `target_global(key, value, duration, npc_id, char_id, zone_id)` | Set targeted quest global | — |
| `delete_global(key)` | Delete a quest global | `eq.delete_global("flag")` |
| `get_qglobals([npc [,client]])` | Get quest globals table | `local g = eq.get_qglobals(e.self, e.other)` |

### Rules

| Function | Description |
|---|---|
| `get_rule(rule_name)` | Get a server rule value as string |
| `set_rule(rule_name, value)` | Set a server rule value |

### Utility / Lookups

| Function | Description |
|---|---|
| `get_race_name(race_id)` | Race ID → name string |
| `get_class_name(class_id [,level])` | Class ID → name string |
| `get_skill_name(skill_id)` | Skill ID → name string |
| `get_char_name_by_id(char_id)` | Char ID → name string |
| `get_char_id_by_name(name)` | Name → char ID |
| `get_npc_name_by_id(npc_type_id)` | NPC type ID → name |
| `get_guild_name_by_id(guild_id)` | Guild ID → name |
| `get_faction_name(faction_id)` | Faction ID → name |
| `get_deity_name(deity_id)` | Deity ID → name |
| `get_language_name(lang_id)` | Language ID → name |
| `get_inventory_slot_name(slot_id)` | Slot ID → name |
| `get_recipe_name(recipe_id)` | Recipe ID → name |
| `get_recipe_made_count(recipe_id)` | Times recipe has been made |
| `has_recipe_learned(recipe_id)` | Whether client has learned recipe |
| `commify(number_string)` | Add commas to number string |
| `check_name_filter(name)` | Validate name against profanity filter |
| `clock()` | Current server time in ms |
| `seconds_to_time(seconds)` | Convert seconds to time string |
| `time_to_seconds(time_string)` | Convert time string to seconds |

### Instances

| Function | Description | Example |
|---|---|---|
| `create_instance(zone_name, version, duration)` | Create zone instance; returns instance ID | `local id = eq.create_instance("befallen", 1, 3600)` |
| `destroy_instance(instance_id)` | Destroy an instance | `eq.destroy_instance(id)` |
| `get_instance_id(zone_name, version)` | Get existing instance ID | — |
| `assign_to_instance(instance_id)` | Assign current client to instance | `eq.assign_to_instance(id)` |
| `assign_group_to_instance(instance_id)` | Assign client's group | `eq.assign_group_to_instance(id)` |
| `assign_raid_to_instance(instance_id)` | Assign client's raid | — |
| `remove_from_instance(instance_id)` | Remove client from instance | — |
| `get_instance_timer(zone_name, version)` | Get remaining instance time | — |
| `update_instance_timer(instance_id, duration)` | Update instance expiry | — |
| `get_characters_in_instance(instance_id)` | Get table of char IDs | — |

### Proximity

| Function | Description | Example |
|---|---|---|
| `set_proximity(min_x, max_x, min_y, max_y [,min_z, max_z [,say]])` | Define NPC proximity zone | `eq.set_proximity(-50, 50, -50, 50)` |
| `set_proximity_range(x_range, y_range [,z_range [,say]])` | Set proximity by range | `eq.set_proximity_range(50, 50)` |
| `clear_proximity()` | Remove proximity zone | `eq.clear_proximity()` |
| `enable_proximity_say()` / `disable_proximity_say()` | Toggle proximity say events | — |

### Corpses

| Function | Description |
|---|---|
| `summon_buried_player_corpse(char_id, x, y, z, h)` | Summon buried corpse |
| `summon_all_player_corpses(char_id, x, y, z, h)` | Summon all corpses |
| `get_player_corpse_count()` | Count current client's corpses |
| `get_player_corpse_count_by_zone_id(zone_id)` | Count in specific zone |
| `get_player_buried_corpse_count()` | Count buried corpses |
| `bury_player_corpse()` | Bury the current client's corpse |

### Zones

| Function | Description |
|---|---|
| `get_zone_id()` | Current zone ID |
| `get_zone_short_name()` | Current zone short name |
| `get_zone_long_name()` | Current zone long name |
| `get_zone_instance_id()` | Current instance ID |
| `get_zone_instance_version()` | Current instance version |
| `get_zone()` | Returns Zone object |
| `get_zone_id_by_name(short_name)` | Zone ID from short name |
| `get_zone_long_name_by_id(zone_id)` | Long name from ID |
| `set_sky(sky_id)` | Set zone sky type |
| `rain(intensity)` / `snow(intensity)` | Set weather |
| `set_time(hour, minute [,realtime])` | Set in-game time |
| `zone(zone_name)` | Zone client to zone |
| `zone_group(zone_name)` | Zone entire group |
| `zone_raid(zone_name)` | Zone entire raid |
| `reloadzonestaticdata()` | Reload zone static data |
| `update_zone_header(...)` | Update zone header properties |
| `add_area(...)` / `remove_area(...)` / `clear_areas()` | Manage area triggers |

### HP Events

| Function | Description |
|---|---|
| `set_next_hp_event(percent)` | Set next HP threshold for EVENT_HP (decreasing) |
| `set_next_inc_hp_event(percent)` | Set next HP threshold for EVENT_HP (increasing) |

### LDoN

| Function | Description |
|---|---|
| `add_ldon_points(theme_id, points)` | Add LDoN points |
| `add_ldon_win(theme_id)` / `remove_ldon_win(theme_id)` | Add/remove LDoN win |
| `add_ldon_loss(theme_id)` / `remove_ldon_loss(theme_id)` | Add/remove LDoN loss |

### Expeditions

| Function | Description | Example |
|---|---|---|
| `get_expedition()` | Get current expedition object | `local exp = eq.get_expedition()` |
| `get_expedition_by_char_id(char_id)` | Get expedition by character | — |
| `get_expedition_by_dz_id(dz_id)` | Get expedition by DZ ID | — |
| `get_expedition_by_zone_instance(zone_id, inst_id)` | Get expedition by zone/instance | — |
| `get_expedition_lockout_by_char_id(char_id, exp_name, event)` | Get lockout data for character | — |
| `add_expedition_lockout_all_clients(exp_name, event, seconds)` | Add lockout to all clients in zone | — |
| `add_expedition_lockout_by_char_id(char_id, exp_name, event, seconds)` | Add lockout to specific character | — |
| `remove_expedition_lockout_by_char_id(char_id, exp_name, event)` | Remove lockout from character | — |

### Objects / Doors

| Function | Description |
|---|---|
| `create_ground_object(item_id, x, y, z, heading [,decay_ms])` | Spawn ground object; returns entity ID |
| `create_ground_object_from_model(model, x, y, z, heading [,type [,decay_ms]])` | Spawn model object |
| `create_door(model, x, y, z, heading [,type [,size]])` | Spawn a door |

### Signals

| Function | Description |
|---|---|
| `signal(entity_id, signal_id [,wait_ms])` | Send signal to entity by ID |

### Miscellaneous

| Function | Description |
|---|---|
| `get_entity_list()` | Returns EntityList object |
| `get_initiator()` | Returns the Client that initiated the event |
| `get_owner()` | Returns the owning Mob |
| `get_quest_item()` | Returns the current ItemInstance |
| `get_quest_spell()` | Returns the current Spell |
| `enable_recipe(recipe_id)` / `disable_recipe(recipe_id)` | Enable/disable a crafting recipe |
| `send_parcel(...)` | Send parcel to character |
| `track_npc(npc_type_id)` | Track an NPC on the map |
| `say_link(text)` | Generate a clickable say link |
| `log(category, msg)` | Write to server log |
| `debug(msg [,level])` | Debug output |

---

## 9. Mob

All `Mob` methods are available on any `Mob`, `Client`, `NPC`, or `Bot` object via inheritance.

**Lua:** `mob:Method()` | **Perl:** `$mob->Method()`

### Type Checks

| Method | Returns | Description |
|---|---|---|
| `IsClient()` | `bool` | Is this a player client? |
| `IsNPC()` | `bool` | Is this an NPC? |
| `IsMob()` | `bool` | Is this any mob? |
| `IsBot()` | `bool` | Is this a bot? |
| `IsMerc()` | `bool` | Is this a mercenary? |
| `IsCorpse()` | `bool` | Is this a corpse? |
| `IsPlayerCorpse()` | `bool` | Is this a player corpse? |
| `IsNPCCorpse()` | `bool` | Is this an NPC corpse? |
| `IsObject()` | `bool` | Is this a ground object? |
| `IsDoor()` | `bool` | Is this a door? |
| `IsPet()` | `bool` | Is this a pet? |
| `IsFamiliar()` | `bool` | Is this a familiar pet? |
| `IsEngaged()` | `bool` | Is in combat? |
| `IsCasting()` | `bool` | Currently casting? |
| `IsMoving()` | `bool` | Currently moving? |
| `IsRooted()` | `bool` | Is rooted? |
| `IsFeared()` | `bool` | Is feared? |
| `IsMezzed()` | `bool` | Is mezzed? |
| `IsStunned()` | `bool` | Is stunned? |
| `IsCharmed()` | `bool` | Is charmed? |
| `IsInvisible([mob])` | `bool` | Is invisible (to mob if specified)? |
| `IsRunning()` | `bool` | Is running vs walking? |
| `IsAlwaysAggro()` | `bool` | Always aggros? |
| `IsAIControlled()` | `bool` | AI controlled? |
| `IsBerserk()` | `bool` | Is berserk? |
| `IsBlind()` | `bool` | Is blind? |
| `IsSilenced()` | `bool` | Is silenced? |
| `IsAmnesiad()` | `bool` | Has amnesia? |
| `IsTargetable()` | `bool` | Can be targeted? |
| `IsTargeted()` | `bool` | Is currently targeted by anyone? |
| `IsIntelligenceCasterClass()` | `bool` | INT-based caster? |
| `IsWisdomCasterClass()` | `bool` | WIS-based caster? |
| `IsWarriorClass()` | `bool` | Warrior archetype? |
| `IsPureMeleeClass()` | `bool` | Pure melee class? |
| `IsTrackable()` | `bool` | Can be tracked? |
| `IsFindable()` | `bool` | Shows on find? |
| `IsBoat()` | `bool` | Is a boat? |
| `IsHorse()` | `bool` | Is a horse? |

### Cast / Conversion

| Method | Returns | Description |
|---|---|---|
| `CastToClient()` | `Client` | Cast to Client type |
| `CastToNPC()` | `NPC` | Cast to NPC type |
| `CastToMob()` | `Mob` | Cast to Mob |
| `CastToCorpse()` | `Corpse` | Cast to Corpse |
| `CastToBot()` | `Bot` | Cast to Bot |

### Identity

| Method | Returns | Description |
|---|---|---|
| `GetID()` | `int` | Entity ID |
| `GetNPCTypeID()` | `int` | NPC type DB ID |
| `GetName()` | `string` | Raw name (with underscores) |
| `GetCleanName()` | `string` | Display name (no underscores) |
| `GetLastName()` | `string` | Last name / surname |
| `GetLevel()` | `int` | Current level |
| `GetClass()` | `int` | Class ID |
| `GetClassName()` | `string` | Class name |
| `GetRace()` | `int` | Race ID |
| `GetRaceName()` | `string` | Race name |
| `GetGender()` | `int` | Gender ID |
| `GetDeity()` | `int` | Deity ID |
| `GetDeityName()` | `string` | Deity name |
| `GetBodyType()` | `int` | Body type ID |
| `GetZoneID()` | `int` | Current zone ID |
| `GetTarget()` | `Mob` | Current target |

### Stats

| Method | Returns | Description |
|---|---|---|
| `GetHP()` | `int64` | Current HP |
| `GetMaxHP()` | `int64` | Max HP |
| `GetHPRatio()` | `float` | HP as percentage (0–100) |
| `GetMana()` | `int64` | Current mana |
| `GetMaxMana()` | `int64` | Max mana |
| `GetManaRatio()` | `float` | Mana as percentage |
| `GetAC()` | `int` | Armor class |
| `GetDisplayAC()` | `int` | Displayed AC |
| `GetATK()` | `int` | Attack |
| `GetSTR()` / `GetSTA()` / `GetAGI()` / `GetDEX()` / `GetINT()` / `GetWIS()` / `GetCHA()` | `int` | Stats |
| `GetMaxSTR()` etc. | `int` | Stat caps |
| `GetMR()` / `GetCR()` / `GetFR()` / `GetDR()` / `GetPR()` / `GetCorruption()` / `GetPhR()` | `int` | Resists |
| `GetHaste()` | `int` | Haste value |
| `GetExtraHaste()` | `int` | Extra haste |
| `GetSize()` | `float` | Size |
| `GetRunspeed()` / `GetWalkspeed()` | `float` | Speed values |
| `GetSkill(skill_id)` | `int` | Skill value |
| `GetResist(type)` | `int` | Resist value by type |
| `GetAA(aa_id)` | `int` | AA rank |
| `SetHP(hp)` | — | Set current HP |
| `SetMaxHP(hp)` | — | Set max HP |
| `SetMana(mana)` | — | Set current mana |
| `SetLevel(level)` | — | Set level |
| `SetSize(size)` | — | Set size |
| `SetRunning(bool)` | — | Toggle run/walk |
| `SetInvul(bool)` | — | Toggle invulnerability |
| `SetAllowBeneficial(bool)` | — | Allow/deny beneficial spells |
| `SetDisableMelee(bool)` | — | Disable melee |

### Position

| Method | Returns | Description |
|---|---|---|
| `GetX()` / `GetY()` / `GetZ()` | `float` | Coordinates |
| `GetHeading()` | `float` | Heading (0–512) |
| `CalculateDistance(x, y, z)` | `float` | Distance to coordinates |
| `CalculateHeadingToTarget(x, y)` | `float` | Heading toward point |
| `CheckLoS(mob)` | `bool` | Line of sight to mob |
| `CheckLoSToLoc(x, y, z [,size])` | `bool` | Line of sight to location |
| `FindGroundZ(x, y [,z])` | `float` | Ground Z at location |
| `GMMove(x, y, z [,h [,update]])` | — | Teleport to location |
| `FaceTarget([mob])` | — | Face toward target or current target |
| `SetHeading(heading)` | — | Set heading |
| `SendTo(x, y, z)` | — | Move to location |
| `Gate()` | — | Gate to bind point |

### Combat & Hate

| Method | Description | Example |
|---|---|---|
| `Attack(mob [,hand [,riposte]])` | Attack a mob | `npc:Attack(client)` |
| `Damage(mob, amount, spell_id, skill [,avoidable [,buffslot [,pet]]])` | Deal direct damage | `mob:Damage(target, 1000, -1, 28)` |
| `DamageArea(amount [,dist])` | Damage all mobs in range | `mob:DamageArea(500, 50)` |
| `DamageHateList(amount [,dist])` | Damage all on hate list | — |
| `AddToHateList(mob [,hate [,damage [,yell [,generated [,buff_tic [,pet_feign]]]]]])` | Add mob to hate list | `npc:AddToHateList(client, 1000)` |
| `GetHateTop()` | Top hate target (Mob) | `local top = npc:GetHateTop()` |
| `GetHateTopClient()` | Top hate client | — |
| `GetHateRandom()` | Random hate target | — |
| `GetHateAmount(mob [,is_damage])` | Hate amount for mob | — |
| `GetHateList()` | Full hate list | — |
| `GetHateListCount()` | Count of mobs on hate list | — |
| `SetHate(mob [,hate [,damage]])` | Set hate amount | — |
| `WipeHateList()` | Clear hate list | `npc:WipeHateList()` |
| `CopyHateList(mob)` | Copy hate list from mob | — |
| `CheckAggro(mob)` | Would NPC aggro mob? | — |
| `HateSummon()` | Pull top hate target to NPC | — |
| `IsAttackAllowed(mob [,is_spell])` | Can attack this mob? | — |
| `CombatRange(mob)` | Is mob in melee range? | — |
| `BehindMob([mob [,x [,y]]])` | Is this mob behind target? | — |

### Buffs & Spells

| Method | Description | Example |
|---|---|---|
| `CastSpell(spell_id, target_id [,...])` | Cast a spell | `mob:CastSpell(1, target:GetID())` |
| `SpellFinished(spell_id [,target [,slot [,cast_time]]])` | Force spell completion | — |
| `InterruptSpell([spell_id])` | Interrupt current cast | `mob:InterruptSpell()` |
| `ApplySpellBuff(spell_id [,duration [,level]])` | Apply buff directly | `mob:ApplySpellBuff(1, 100, 65)` |
| `BuffCount([beneficial [,detrimental]])` | Count buffs | `local n = mob:BuffCount()` |
| `BuffFadeAll()` | Remove all buffs | `mob:BuffFadeAll()` |
| `BuffFadeBeneficial()` / `BuffFadeDetrimental()` | Remove beneficial/detrimental | — |
| `BuffFadeBySpellID(spell_id)` | Remove specific spell | `mob:BuffFadeBySpellID(1)` |
| `BuffFadeByEffect(effect_id [,slot])` | Remove by effect type | — |
| `BuffFadeBySlot(slot [,send_update])` | Remove buff in slot | — |
| `FindBuff(spell_id [,slot])` | Check if buff is active | `if mob:FindBuff(1) then` |
| `GetBuffs()` | Get all buff data (table) | — |
| `GetBuffSlotFromType(type)` | Get slot for buff type | — |
| `GetBuffSpellIDs()` | Get all buffed spell IDs | — |
| `GetSpellIDFromSlot(slot)` | Get spell ID in buff slot | — |
| `GetActSpellDamage(spell_id, base_damage [,target])` | Get actual spell damage | — |
| `GetActSpellHealing(spell_id, base_heal [,target [,is_hot]])` | Get actual heal | — |
| `GetActSpellCost(spell_id)` | Get actual mana cost | — |
| `GetActSpellDuration(spell_id)` | Get actual duration | — |
| `GetActSpellRange(spell_id)` | Get actual range | — |
| `CanBuffStack(spell_id, caster_level [,log])` | Check stacking | — |
| `HasSpellEffect(effect_id)` | Has specific spell effect? | — |
| `SetBuffDuration(slot [,duration [,level]])` | Change buff duration | — |
| `MassGroupBuff(caster, target, spell_id [,random])` | Apply group buff | — |

### Pets

| Method | Description |
|---|---|
| `MakePet(spell_id, pet_type [,name])` | Create a pet |
| `MakeTempPet(spell_id [,name [,duration [,owner [,no_owner_dmg]]]])` | Create temporary pet |
| `HasPet()` | Has an active pet? |
| `GetPet()` | Get pet Mob object |
| `GetPetID()` | Get pet entity ID |
| `SetPet(mob)` | Set mob as pet |
| `GetOwner()` | Get owner mob |
| `GetOwnerID()` | Get owner entity ID |
| `GetUltimateOwner()` | Get top-level owner |

### Appearance

| Method | Description | Example |
|---|---|---|
| `DoAnim(anim_id [,type [,ack [,filter]]])` | Play animation | `mob:DoAnim(10)` |
| `Emote(msg)` | NPC emotes text | `mob:Emote("waves.")` |
| `Say(msg)` | NPC says text | `mob:Say("Hello!")` |
| `Shout(msg)` | NPC shouts | — |
| `Message(color, msg)` | Send message to client | `mob:Message(15, "Hello")` |
| `SendIllusion(race [,gender [,texture [,...]]])` | Apply illusion | `mob:SendIllusion(128)` |
| `ChangeSize(size [,no_update])` | Change size | `mob:ChangeSize(2.0)` |
| `ChangeRace(race_id)` | Change race | — |
| `ChangeTexture(texture)` | Change texture | — |
| `ChangeGender(gender_id)` | Change gender | — |
| `CloneAppearance(mob [,clone_armor])` | Copy appearance | — |
| `RandomizeFeatures([illusion [,save]])` | Randomize face | — |
| `WearChange(slot, texture [,hero_forge [,material]])` | Change equipment appearance | — |
| `SetBodyType(type [,overwrite_orig])` | Change body type | — |
| `AddNimbusEffect(effect_id)` | Add nimbus (aura effect) | — |
| `RemoveNimbusEffect(effect_id)` | Remove nimbus | — |
| `RemoveAllNimbusEffects()` | Remove all nimbus effects | — |
| `TempName([name])` | Temporarily rename NPC | `mob:TempName("Bob")` |
| `CameraEffect(duration [,intensity [,client [,send_to_target]]])` | Camera shake effect | — |

### Entity Variables

| Method | Description | Example |
|---|---|---|
| `GetEntityVariable(key)` | Get entity variable value | `local v = mob:GetEntityVariable("state")` |
| `SetEntityVariable(key, value)` | Set entity variable | `mob:SetEntityVariable("state", "active")` |
| `EntityVariableExists(key)` | Check if variable exists | `if mob:EntityVariableExists("state") then` |
| `DeleteEntityVariable(key)` | Delete entity variable | `mob:DeleteEntityVariable("state")` |
| `ClearEntityVariables()` | Remove all entity variables | — |
| `GetEntityVariables()` | Get all variables as table | — |

### Timers (on Mob)

| Method | Description |
|---|---|
| `HasTimer(name)` | Check if mob has a named timer |
| `IsPausedTimer(name)` | Is timer paused? |
| `SetTimer(name, ms)` | Start timer on this mob |
| `StopTimer(name)` | Stop timer |
| `StopAllTimers()` | Stop all timers |
| `PauseTimer(name)` | Pause timer |
| `ResumeTimer(name)` | Resume timer |
| `GetRemainingTimeMS(name)` | Get remaining ms |

### Data Buckets (on Mob)

| Method | Description |
|---|---|
| `GetBucket(key)` | Get bucket value |
| `SetBucket(key, value [,expires])` | Set bucket value |
| `DeleteBucket(key)` | Delete bucket |
| `GetBucketExpires(key)` / `GetBucketRemaining(key)` | Get expiry info |

### Quest Globals (on Mob)

| Method | Description |
|---|---|
| `GetGlobal(key)` | Get quest global |
| `SetGlobal(key, value, options, duration)` | Set quest global |
| `DelGlobal(key)` | Delete quest global |

### Stat Bonuses (on Mob)

| Method | Description |
|---|---|
| `GetSpellBonuses()` | Returns StatBonuses from spells |
| `GetAABonuses()` | Returns StatBonuses from AAs |
| `GetItemBonuses()` | Returns StatBonuses from items |

### Special Abilities

| Method | Description |
|---|---|
| `GetSpecialAbility(id)` | Get special ability value |
| `GetSpecialAbilityParam(id, param)` | Get ability parameter |
| `SetSpecialAbility(id, value)` | Set special ability |
| `SetSpecialAbilityParam(id, param, value)` | Set ability parameter |
| `ClearSpecialAbilities()` | Clear all special abilities |
| `HasNPCSpecialAtk(flag)` | Check NPC special attack flag |
| `ProcessSpecialAbilities(str)` | Process ability string |

### Misc Mob

| Method | Description |
|---|---|
| `Kill()` | Kill the mob |
| `Depop([start_timer])` | Remove from zone |
| `Signal(signal_id)` | Send signal to this mob |
| `SignalClient(client, signal_id)` | Signal a specific client |
| `GoToBind([bind_num])` | Teleport to bind point |
| `GetLevelCon(level)` | Get consider text for level |
| `GetConsiderColor(mob)` | Get con color string |
| `HealDamage(amount [,caster])` | Restore HP |
| `RestoreHealth()` / `RestoreMana()` / `RestoreEndurance()` | Restore to full |
| `Spin()` | Spin animation |
| `Stun(duration_ms)` | Stun for duration |
| `Mesmerize()` | Mesmerize |
| `DivineAura()` | Trigger divine aura |
| `StartEnrage()` | Begin enrage |
| `DoKnockback(caster, push_back, push_up)` | Apply knockback |
| `RangedAttack(mob)` | Perform ranged attack |
| `ThrowingAttack(mob)` | Perform throwing attack |
| `ModSkillDmgTaken(skill, mod)` | Modify skill damage taken |
| `ModVulnerability(type, mod)` | Modify vulnerability |
| `GetInvul()` | Is invulnerable? |
| `GetFlurryChance()` | Get flurry chance |
| `GetHeroicStrikethrough()` | Get heroic strikethrough |
| `SetFlurryChance(chance)` | Set flurry chance |
| `SetExtraHaste(amount [,recalc])` | Set extra haste |
| `ProjectileAnim(target, item_id [,...])` | Play projectile animation |

---

## 10. Client

All `Mob` methods also available. These are Client-specific.

**Lua:** via `e.other` in NPC events, or `e.self` in player events | **Perl:** `$client`

### Identity

| Method | Returns | Description |
|---|---|---|
| `GetCharacterID()` / `CharacterID()` | `uint32` | Database character ID |
| `AccountID()` | `uint32` | Account ID |
| `AccountName()` | `string` | Account name |
| `GetGuild()` | `string` | Guild name |
| `GetGuildID()` | `uint32` | Guild ID |
| `GetGuildRank()` | `int` | Guild rank |
| `GetGuildPoints()` | `int` | Guild points |
| `GetBindZoneID([bind_num])` | `uint32` | Bind zone ID |
| `GetBindX/Y/Z/Heading([bind_num])` | `float` | Bind location |
| `GetAnon()` | `int` | Anon flag |
| `GetPVP()` | `bool` | PVP flag |
| `GetGM()` | `bool` | GM flag |
| `GetGMSpeed()` | `bool` | GM speed flag |
| `GetIP()` | `string` | Client IP address |

### Currency

| Method | Description | Example |
|---|---|---|
| `GetPlatinum()` / `GetGold()` / `GetSilver()` / `GetCopper()` | Get currency | `local pp = client:GetPlatinum()` |
| `AddPlatinum(amount)` etc. | Add currency | `client:AddPlatinum(100)` |
| `TakeMoneyFromPP(copper)` | Remove money (in copper) | `client:TakeMoneyFromPP(10000)` |
| `GiveMoney(pp, gp, sp, cp)` | Give money | `client:GiveMoney(10, 0, 0, 0)` |
| `GetAlternateCurrencyValue(currency_id)` | Get alt currency amount | — |
| `AddAlternateCurrencyValue(currency_id, amount)` | Add alt currency | — |
| `RemoveAlternateCurrencyValue(currency_id, amount)` | Remove alt currency | — |

### Experience

| Method | Description | Example |
|---|---|---|
| `GetEXP()` | Get current XP | — |
| `GetMaxXP()` | Get XP to next level | — |
| `AddEXP(amount)` | Add experience | `client:AddEXP(1000)` |
| `GetAAExp()` | Get AA XP | — |
| `AddAAExp(amount)` | Add AA XP | — |
| `GetTotalSecondsPlayed()` | Playtime in seconds | — |
| `GetSpentAA()` | Spent AA count | — |
| `GetUnspentAA()` | Unspent AA count | — |
| `AddAAPoints(amount)` | Add unspent AA | `client:AddAAPoints(5)` |
| `IncStats(stat_id, amount)` | Increase a base stat | — |
| `SetStat(stat_id, value)` | Set a base stat | — |

### Items / Inventory

| Method | Description | Example |
|---|---|---|
| `GetInv()` | Get Inventory object | `local inv = client:GetInv()` |
| `SummonItem(item_id [,charges])` | Summon item to cursor | `client:SummonItem(1001)` |
| `PushItemOnCursor(item_inst)` | Push item to cursor | — |
| `GetItemIDAt(slot_id)` | Get item ID in slot | `local id = client:GetItemIDAt(13)` |
| `GetItemInInventory(slot_id)` | Get ItemInstance in slot | — |
| `HasItem(item_id [,qty [,where]])` | Item in inventory? | `if client:HasItem(1001) then` |
| `HasItemEquipped(item_id)` | Item equipped? | — |
| `CountItem(item_id)` | Count of item | `local n = client:CountItem(1001)` |
| `RemoveItem(item_id [,qty])` | Remove from inventory | `client:RemoveItem(1001, 1)` |
| `DeleteItemInInventory(slot, qty [,client_update])` | Delete item in slot | — |
| `GetEquippedItemID(slot)` | Item ID in equip slot | `local id = client:GetEquippedItemID(13)` |
| `IsAllItemsNoDrop()` | All items no-drop? | — |

### Spells / Skills

| Method | Description | Example |
|---|---|---|
| `GetSpellIDMemorized(slot)` | Spell in gem slot | `local spell = client:GetSpellIDMemorized(0)` |
| `HasSpellScribed(spell_id)` | Is spell in spellbook? | — |
| `HasSpellMemorized(spell_id)` | Is spell memorized? | — |
| `MemorizeSpell(slot, spell_id, type)` | Memorize spell | `client:MemorizeSpell(0, 1, 1)` |
| `UnmemSpell(slot [,update [,remove]])` | Unmemorize spell | — |
| `ScribeSpell(spell_id, slot)` | Scribe to spellbook | — |
| `UnscribeSpell(slot)` | Remove from spellbook | — |
| `GetSkill(skill_id)` | Skill value | `local val = client:GetSkill(1)` |
| `SetSkill(skill_id, value)` | Set skill value | `client:SetSkill(1, 200)` |
| `MaxSkills()` | Max all skills | — |
| `GetLanguageSkill(lang_id)` | Language skill | — |
| `SetLanguageSkill(lang_id, value)` | Set language skill | — |
| `TrainSkill(skill_id, value)` | Train skill to value | — |
| `UseDiscipline(spell_id)` | Activate discipline | — |
| `GetDiscSlotBySpellID(spell_id)` | Get disc slot | — |
| `HasDisciplineLearned(spell_id)` | Is disc learned? | — |
| `TrainDiscipline(item_id)` | Train a discipline | — |

### Tasks

| Method | Description |
|---|---|
| `AssignTask(task_id [,enforce_level])` | Assign task |
| `IsTaskActive(task_id)` | Is task active? |
| `IsTaskCompleted(task_id)` | Is task completed? |
| `GetTaskActivityDoneCount(task_id, activity_id)` | Get activity count |
| `UpdateTaskActivity(task_id, activity_id [,count])` | Update activity |
| `FailTask(task_id)` | Fail a task |
| `TaskSelector(task_id_table)` | Open task select window |

### Movement / Zone

| Method | Description | Example |
|---|---|---|
| `MovePC(zone_id, x, y, z [,h])` | Move to zone/location | `client:MovePC(1, 0, 0, 0)` |
| `MovePCInstance(zone_id, inst_id, x, y, z [,h])` | Move to instance | — |
| `GoToBind([bind_num])` | Return to bind point | `client:GoToBind()` |
| `SafeMove()` | Move to safe coordinates | — |
| `Rebind(zone_id, x, y, z [,h])` | Change bind point | `client:Rebind(1, 0, 0, 0)` |
| `SetBindPoint([bind_num [,zone_id [,x [,y [,z [,h]]]]]])` | Set bind explicitly | — |

### Communication

| Method | Description | Example |
|---|---|---|
| `Message(color, msg)` | Send chat message | `client:Message(15, "Hello!")` |
| `MessageString(type, string_id [,...])` | Send string ID message | — |
| `Popup(title, msg)` | Send popup dialog | `client:Popup("Title", "Body")` |
| `SendFullPopup(title, msg [,popup_id [,neg_id [,buttons [,duration [,btn0 [,btn1]]]]]])` | Full popup | — |
| `SendColoredText(color, msg)` | Colored text | — |
| `SendMarqueeMessage(type, msg [,duration])` | Marquee | — |
| `Tell(from, msg)` | Send /tell | `client:Tell("NPCName", "Hello")` |
| `SendWindowsMessage(msg)` | Windows message box | — |
| `SendBooks(book_text [,type])` | Open book UI | `client:SendBooks("Text")` |
| `QuestReadBook(text [,type])` | Open book UI | — |
| `SendPlayerPacket(packet)` | Send raw packet | — |

### Faction

| Method | Description | Example |
|---|---|---|
| `GetFactionLevel(faction_id)` | Get faction value | `local f = client:GetFactionLevel(1)` |
| `SetFactionLevel(faction_id, value)` | Set faction | — |
| `UpdateFactionData(faction_id)` | Update from DB | — |
| `RewardFaction(faction_id, value)` | Give faction | `client:RewardFaction(1, 5)` |
| `GetFactionName(faction_id)` | Get faction name | — |

### Buffs / Resist

| Method | Description |
|---|---|
| `DontBuffMeBefore(ms)` | Suppress buff for duration |
| `DontDotMeBefore(ms)` | Suppress DoT for duration |
| `DontHealMeBefore(ms)` | Suppress heals for duration |
| `DontRootMeBefore(ms)` | Suppress root for duration |
| `DontSnareMeBefore(ms)` | Suppress snare for duration |

### Loot / Death

| Method | Description |
|---|---|
| `GetCorpseCount()` | Count of player corpses |
| `GetCorpseID(index)` | Get corpse entity ID |
| `GetCorpseItemAt(corpse_id, slot)` | Get item in corpse |
| `SummonAllPlayerCorpses(x, y, z, h)` | Summon all corpses |
| `BuryPlayerCorpse()` | Bury corpse |
| `GetPlayerBuriedCorpseCount()` | Count buried corpses |

### Bots / Pets (Client)

| Method | Description |
|---|---|
| `GetBotCount()` | Number of active bots |
| `GetBotByIndex(index)` | Get bot by index |
| `GetAllBots()` | Get all bots |
| `GetPet()` | Get active pet |
| `GetPetID()` | Get pet entity ID |

### Titles / Flags

| Method | Description |
|---|---|
| `SetTitleSuffix(title)` | Set title suffix |
| `SetTitle(title)` | Set title |
| `EnableTitle(title_id)` | Enable a title |
| `RemoveTitle(title_id)` | Remove a title |
| `CheckTitle(title_id)` | Check if title earned |
| `UpdateWho([always])` | Update /who listing |

### Misc Client

| Method | Description |
|---|---|
| `Kick()` | Disconnect the client |
| `Ban(reason)` | Ban the client |
| `GMKill()` | Kill without loot/XP effects |
| `Revive([bind_num])` | Revive from death |
| `ResetAA()` | Reset AA points |
| `Ding()` | Trigger level-up ding |
| `Freeze()` / `UnFreeze()` | Freeze/unfreeze |
| `SendToGuildHall()` | Zone to guild hall |
| `SendZoneFlagInfo(client)` | Send zone flag info |
| `CalcMaxEndurance()` | Recalculate max endurance |
| `GetEndurance()` | Current endurance |
| `GetMaxEndurance()` | Max endurance |
| `SetEndurance(val)` | Set endurance |
| `GetPVPPoints()` | PVP points |
| `AddPVPPoints(val)` | Add PVP points |
| `IsMedding()` | Is sitting and meditating? |
| `IsSitting()` | Is sitting? |
| `IsStanding()` | Is standing? |
| `IsLooting()` | Is looting? |
| `IsDead()` | Is dead? |
| `GetClientVersionBit()` | Client version bitmask |
| `GetClientVersion()` | Client version string |
| `GetAccountAge()` | Account age in days |
| `GetExpModifier(zone_id [,version])` | EXP modifier for zone |
| `SetExpModifier(zone_id, mod [,version])` | Set EXP modifier |

---

## 11. NPC

All `Mob` methods also available.

**Lua:** `npc:Method()` | **Perl:** `$npc->Method()`

### AI / Waypoints

| Method | Description | Example |
|---|---|---|
| `GetGrid()` | Get assigned grid ID | `local grid = npc:GetGrid()` |
| `SetGrid(grid_id)` | Assign a grid | `npc:SetGrid(5)` |
| `AssignWaypoints(grid_id)` | Load and start waypoints | `npc:AssignWaypoints(5)` |
| `GetMaxWp()` | Max waypoint in grid | — |
| `UpdateWaypoint(wp_index)` | Jump to waypoint | `npc:UpdateWaypoint(0)` |
| `GetWaypointID()` | Current waypoint number | — |
| `GetWaypointX/Y/Z/H()` | Current waypoint location | — |
| `GetWaypointPause()` | Pause at current waypoint | — |
| `PauseWandering(pause_ms)` | Pause wandering | `npc:PauseWandering(5000)` |
| `ResumeWandering()` | Resume wandering | — |
| `StopWandering()` | Stop wandering permanently | — |
| `CalculateNewWaypoint()` | Recalculate next waypoint | — |
| `DisplayWaypointInfo(client)` | Show waypoint info | — |
| `SaveGuardSpot([x, y, z, h])` | Save guard position | `npc:SaveGuardSpot()` |
| `IsGuarding()` | Is NPC guarding? | — |
| `GetGuardPointX/Y/Z()` | Guard position | — |
| `NextGuardPosition()` | Return to guard spot | — |
| `AI_SetRoambox(x, y, x2, y2, delay [,dist [,move_delay]])` | Set roambox | — |
| `MoveTo(x, y, z [,h [,save_guard]])` | Move to position | `npc:MoveTo(100, 200, 5, 0)` |
| `NavigateTo(x, y, z)` | Navigate using pathfinding | — |
| `RunTo(x, y, z)` / `WalkTo(x, y, z)` | Run/walk to position | — |
| `StopNavigation()` | Stop navigation | — |

### Loot

| Method | Description | Example |
|---|---|---|
| `AddItem(item_id [,charges [,equip [,aug1..aug6]]])` | Add item to loot | `npc:AddItem(1001, 1)` |
| `AddLootTable([loottable_id])` | Add entire loot table | `npc:AddLootTable(100)` |
| `RemoveItem(item_id [,qty [,slot]])` | Remove item from loot | — |
| `ClearItemList()` | Remove all loot | `npc:ClearItemList()` |
| `CountItem(item_id)` | Count of item in loot | — |
| `CountLoot()` | Total loot items | — |
| `HasItem(item_id)` | Is item in loot? | `if npc:HasItem(1001) then` |
| `GetLootList()` | Get all loot (table) | — |
| `GetLoottableID()` | DB loottable ID | — |

### Cash

| Method | Description |
|---|---|
| `AddCash(copper, silver, gold, platinum)` | Add cash to NPC loot |
| `RemoveCash()` | Remove all cash |
| `GetCopper/Silver/Gold/Platinum()` | Get cash amounts |
| `SetCopper/Silver/Gold/Platinum(val)` | Set cash amounts |

### Spells / Procs

| Method | Description | Example |
|---|---|---|
| `AddAISpell(priority, spell_id, type, min_hp, max_hp, min_mana [,resist [,cast_type]])` | Add AI spell | — |
| `RemoveAISpell(spell_id)` | Remove AI spell | — |
| `AddMeleeProc(spell_id, rate)` | Add melee proc | `npc:AddMeleeProc(100, 75)` |
| `RemoveMeleeProc(spell_id)` | Remove melee proc | — |
| `AddRangedProc(spell_id, rate)` | Add ranged proc | — |
| `RemoveRangedProc(spell_id)` | Remove ranged proc | — |
| `AddDefensiveProc(spell_id, rate)` | Add defensive proc | — |
| `RemoveDefensiveProc(spell_id)` | Remove defensive proc | — |
| `ReloadSpells()` | Reload spell list from DB | — |
| `GetNPCSpellsID()` | Spell list DB ID | — |
| `DoClassAttacks(target)` | Perform class-specific attacks | — |

### Stats / Scaling

| Method | Description | Example |
|---|---|---|
| `GetNPCStat(stat_name)` | Get NPC stat by name | `local hp = npc:GetNPCStat("max_hp")` |
| `ModifyNPCStat(stat_name, value)` | Modify NPC stat | `npc:ModifyNPCStat("runspeed", 0.7)` |
| `ScaleNPC(level [,use_npc_type])` | Scale NPC to level | `npc:ScaleNPC(70)` |
| `GetAccuracyRating()` / `GetAvoidanceRating()` | Rating values | — |
| `GetMaxDMG()` / `GetMinDMG()` | Damage values | — |
| `GetSlowMitigation()` | Slow mitigation | — |
| `GetSpellScale()` / `GetHealScale()` | Scale values | — |
| `RecalculateSkills()` | Recalculate NPC skills | — |
| `GetCombatState()` | Combat state integer | — |

### Faction

| Method | Description |
|---|---|
| `GetPrimaryFaction()` | NPC primary faction ID |
| `GetNPCFactionID()` | NPC faction table ID |
| `SetNPCFactionID(id)` | Set faction table |
| `CheckNPCFactionAlly(faction_id)` | Is faction an ally? |
| `GetNPCAggro()` / `SetNPCAggro(bool)` | NPC aggro flag |
| `IsOnHatelist(mob)` | Is mob on hate list? |
| `RemoveFromHateList(mob)` | Remove from hate list |

### Merchant

| Method | Description |
|---|---|
| `MerchantOpenShop()` / `MerchantCloseShop()` | Open/close merchant |
| `GetKeepsSoldItems()` | Keeps sold items setting |
| `SetKeepsSoldItems(bool)` | Set keeps sold items |
| `MultiQuestEnable(bool)` | Enable multi-quest |
| `IsMultiQuestEnabled()` | Is multi-quest on? |
| `PickPocket(client)` | Attempt pick pocket |

### LDoN Traps

| Method | Description |
|---|---|
| `IsLDoNLocked()` / `IsLDoNTrapped()` / `IsLDoNTrapDetected()` | LDoN state checks |
| `SetLDoNLocked(bool)` / `SetLDoNTrapped(bool)` / `SetLDoNTrapDetected(bool)` | Set LDoN states |
| `GetLDoNTrapType()` / `GetLDoNTrapSpellID()` | Trap info |
| `SetLDoNTrapType(type)` / `SetLDoNTrapSpellID(id)` | Set trap |

### Misc NPC

| Method | Description | Example |
|---|---|---|
| `SignalNPC(signal_id)` | Signal this NPC | `npc:SignalNPC(1)` |
| `SendPayload(payload_id [,payload])` | Send payload event | — |
| `IsRaidTarget()` | Is a raid target? | — |
| `IsRareSpawn()` | Is a rare spawn? | — |
| `GetSpawnKillCount()` | Times this spawn has been killed | — |
| `GetSpawnPointX/Y/Z/H/ID()` | Spawn point info | — |
| `GetSwarmOwner()` | Swarm owner mob | — |
| `GetSwarmTarget()` / `SetSwarmTarget(mob)` | Swarm target | — |
| `StartSwarmTimer(ms)` | Set swarm despawn timer | — |
| `SetNPCTintIndex(index)` | Set armor tint index | — |
| `CheckHandin(item_table)` | Validate handin | `npc:CheckHandin({[1001]=1})` |

---

## 12. EntityList

**Lua:** `local el = eq.get_entity_list()` then `el:Method()` | **Perl:** `$entity_list->Method()`

### Lookups

| Method | Returns | Description |
|---|---|---|
| `GetMob(name)` | `Mob` | Find mob by name |
| `GetMobID(entity_id)` | `Mob` | Find mob by entity ID |
| `GetNPCByID(entity_id)` | `NPC` | Find NPC by entity ID |
| `GetNPCByNPCTypeID(npc_type_id)` | `NPC` | First NPC of given type |
| `GetNPCBySpawnID(spawn2_id)` | `NPC` | NPC by spawn2 ID |
| `GetClientByName(name)` | `Client` | Find client by name |
| `GetClientByCharID(char_id)` | `Client` | Find client by char ID |
| `GetClientByAccID(acct_id)` | `Client` | Find by account ID |
| `GetCorpseByName(name)` | `Corpse` | Find corpse by name |
| `GetGroupByClient(client)` | `Group` | Group containing client |
| `GetRaidByClient(client)` | `Raid` | Raid containing client |
| `GetObjectByDBID(db_id)` | `Object` | World object by DB ID |
| `GetDoorsByDBID(db_id)` | `Door` | Door by DB ID |
| `GetBotByName(name)` | `Bot` | Bot by name |
| `IsMobSpawnedByNpcTypeID(npc_type_id)` | `bool` | Is NPC type in zone? |

### Lists

| Method | Returns | Description |
|---|---|---|
| `GetMobList()` | `table` | All mobs in zone |
| `GetNPCList()` | `table` | All NPCs |
| `GetClientList()` | `table` | All clients |
| `GetCorpseList()` | `table` | All corpses |
| `GetObjectList()` | `table` | All ground objects |
| `GetDoorsList()` | `table` | All doors |
| `GetBotList()` | `table` | All bots |
| `GetCloseMobList(mob [,dist [,include_combat]])` | `table` | Nearby mobs |
| `GetRandomClient([x,y,z,dist [,exclude]])` | `Client` | Random client |
| `GetRandomNPC([x,y,z,dist [,exclude]])` | `NPC` | Random NPC |
| `GetRandomMob([x,y,z,dist [,exclude]])` | `Mob` | Random mob |

### Signals / Messages

| Method | Description |
|---|---|
| `SignalAllClients(signal_id)` | Send signal to all clients |
| `SignalMobsByNPCID(npc_type_id, signal_id)` | Signal all NPCs of given type |
| `Message(color, msg)` | Send message to all |
| `MessageClose(mob, dist, color, msg)` | Message nearby |
| `MessageGroup(mob, skip_sender, color, msg)` | Message group |
| `Marquee(type, msg [,duration])` | Zone marquee |

### Area Effects

| Method | Description |
|---|---|
| `AreaAttack(mob, dist [,spell_id [,min_dmg [,aggro [,max_targets]]]])` | AoE attack |
| `AreaSpell(caster, center, spell_id [,...])` | Cast AoE spell |
| `AreaTaunt(client [,dist [,bonus]])` | AoE taunt |
| `MassGroupBuff(caster, target, spell_id [,random])` | Group-wide buff |

---

## 13. Group

**Lua:** via `eq.get_entity_list():GetGroupByClient(client)` | **Perl:** `$client->GetGroup()`

| Method | Description | Example |
|---|---|---|
| `GetID()` | Group ID | — |
| `GroupCount()` | Member count | `local n = group:GroupCount()` |
| `GetMember(index)` | Get member by index (0-based) | `local m = group:GetMember(0)` |
| `GetLeader()` | Group leader Mob | — |
| `GetLeaderName()` | Leader name | — |
| `IsLeader(mob)` | Is mob the leader? | — |
| `IsGroupMember(mob)` | Is mob in group? | — |
| `SetLeader(mob)` | Set group leader | — |
| `DisbandGroup()` | Disband the group | — |
| `CastGroupSpell(caster, spell_id)` | Cast group spell | `group:CastGroupSpell(npc, 1)` |
| `SplitExp(exp, mob)` | Split experience | — |
| `SplitMoney(cp, sp, gp, pp [,splitter])` | Split money | — |
| `GroupMessage(sender, msg [,language])` | Send group message | — |
| `GetAverageLevel()` | Average member level | — |
| `GetHighestLevel()` / `GetLowestLevel()` | Level range | — |
| `TeleportGroup(mob, zone_id, x, y, z, h)` | Teleport group | — |
| `DoesAnyMemberHaveExpeditionLockout(exp, event)` | Lockout check | — |
| `GetTotalGroupDamage(mob)` | Total damage on mob | — |
| `SendHPPacketsTo(mob)` / `SendHPPacketsFrom(mob)` | Sync HP | — |

---

## 14. Raid

**Lua:** via `eq.get_entity_list():GetRaidByClient(client)` | **Perl:** `$client->GetRaid()`

| Method | Description |
|---|---|
| `GetID()` | Raid ID |
| `RaidCount()` | Total member count |
| `GroupCount(group_id)` | Count in group |
| `GetGroup(client)` | Get group number for client |
| `GetGroupNumber(client)` | Group index |
| `GetClientByIndex(index)` | Client by index |
| `GetMember(index)` | Member at index |
| `GetLeader()` | Raid leader Mob |
| `GetLeaderName()` | Leader name |
| `IsLeader(name_or_client)` | Is raid leader? |
| `IsGroupLeader(name_or_client)` | Is group leader? |
| `IsRaidMember(name_or_client)` | Is in raid? |
| `SplitExp(exp, mob)` | Split XP |
| `SplitMoney(group_id, cp, sp, gp, pp [,splitter])` | Split money |
| `BalanceHP(penalty, group_id)` | Balance group HP |
| `CastGroupSpell(caster, spell_id, group_id)` | Cast to group |
| `GetHighestLevel()` / `GetLowestLevel()` | Level range |
| `TeleportGroup(mob, zone_id, x, y, z, h)` | Teleport group |
| `TeleportRaid(mob, zone_id, x, y, z, h)` | Teleport raid |
| `GetTotalRaidDamage(mob)` | Total damage |
| `DoesAnyMemberHaveExpeditionLockout(exp, event)` | Lockout check |

---

## 15. Expedition / DynamicZone

**Lua:** `local exp = eq.get_expedition()` | **Perl:** `$client->GetExpedition()`

| Method | Description | Example |
|---|---|---|
| `GetID()` | Expedition ID | — |
| `GetName()` | Expedition name | `local name = exp:GetName()` |
| `GetLeaderName()` | Leader name | — |
| `GetInstanceID()` | Instance ID | — |
| `GetZoneID()` | Zone ID | — |
| `GetZoneName()` | Zone name | — |
| `GetZoneVersion()` | Zone version | — |
| `GetDynamicZoneID()` | DZ ID | — |
| `GetUUID()` | Unique UUID string | — |
| `GetMemberCount()` | Member count | — |
| `GetMembers()` | Table of members | — |
| `GetSecondsRemaining()` | Time left (seconds) | `local t = exp:GetSecondsRemaining()` |
| `SetSecondsRemaining(seconds)` | Update time | `exp:SetSecondsRemaining(3600)` |
| `IsLocked()` | Is expedition locked? | — |
| `SetLocked(bool [,msg_type [,msg]])` | Lock/unlock | `exp:SetLocked(true)` |
| `HasLockout(event)` | Has a lockout? | `if exp:HasLockout("Boss") then` |
| `HasReplayLockout()` | Has replay timer? | — |
| `GetLockouts()` | Table of lockouts | — |
| `AddLockout(event, seconds)` | Add lockout to all members | `exp:AddLockout("Boss", 604800)` |
| `AddLockoutDuration(event, seconds [,members_only])` | Add time to lockout | — |
| `AddReplayLockout(seconds)` | Add replay timer | — |
| `AddReplayLockoutDuration(seconds [,members_only])` | Extend replay timer | — |
| `RemoveLockout(event)` | Remove lockout | — |
| `UpdateLockoutDuration(event, seconds [,members_only])` | Update lockout duration | — |
| `SetReplayLockoutOnMemberJoin(bool)` | Auto-assign replay on join | — |
| `SetCompass(zone_id, x, y, z)` | Set expedition compass | — |
| `RemoveCompass()` | Remove compass | — |
| `SetSafeReturn(zone_id, x, y, z, h)` | Set safe return | — |
| `SetZoneInLocation(x, y, z, h)` | Set zone-in point | — |
| `SetSwitchID(id)` | Set DZ switch ID | — |
| `SetLootEventByNPCTypeID(npc_type_id, event)` | Associate loot event | `exp:SetLootEventByNPCTypeID(1234, "Boss")` |
| `SetLootEventBySpawnID(spawn_id, event)` | Loot event by spawn | — |
| `GetLootEventByNPCTypeID(npc_type_id)` | Get loot event | — |
| `GetLootEventBySpawnID(spawn_id)` | Get loot event | — |

---

## 16. Inventory

Accessed via `client:GetInv()`.

**Lua:** `local inv = client:GetInv()` | **Perl:** `$client->GetInv()`

| Method | Description |
|---|---|
| `GetItem(slot_id)` | Get ItemInstance in slot |
| `HasItem(item_id [,qty [,where]])` | Has item? `where`: 0=all, 1=equip, 2=cursor, 4=general, 8=bank, 16=shared_bank |
| `HasItemByUse(use, qty [,where])` | Has item with use type? |
| `HasItemEquippedByID(item_id)` | Is item equipped? |
| `CountItemEquippedByID(item_id)` | Count equipped |
| `CountAugmentEquippedByID(item_id)` | Count equipped augments |
| `HasAugmentEquippedByID(item_id)` | Has augment equipped? |
| `GetAugmentIDsBySlotID(slot_id)` | Get augment IDs in slot |
| `DeleteItem(slot_id [,qty])` | Delete item |
| `PopItem(slot_id)` | Remove and return item |
| `PutItem(slot_id, item_inst)` | Place item in slot |
| `PushCursor(item_inst)` | Push to cursor |
| `SwapItem(from_slot, to_slot)` | Swap slots |
| `FindFreeSlot(for_bag, try_cursor [,min_size [,is_arrow]])` | Find free slot |
| `GetBagIndex(slot_id)` | Get bag sub-index |
| `GetSlotID(slot_id [,bag_idx])` | Resolve slot ID |
| `GetMaterialFromSlot(slot_id)` | Get material value |
| `GetSlotFromMaterial(material)` | Reverse material lookup |
| `CanItemFitInContainer(item, container)` | Fit check |
| `SupportsContainers(slot_id)` | Does slot hold bags? |
| `CheckNoDrop(slot_id)` | Is item in slot no-drop? |

---

## 17. ItemInstance (QuestItem)

Represents a specific instance of an item.

**Lua:** returned from `eq.get_quest_item()`, `inventory:GetItem(slot)` | **Perl:** `$item`

| Method | Description |
|---|---|
| `GetID()` | Item DB ID |
| `GetItemID()` | Same as GetID |
| `GetName()` | Item name |
| `GetCharges()` | Current charges |
| `SetCharges(n)` | Set charges |
| `GetPrice()` | Item price |
| `SetPrice(price)` | Set price |
| `GetColor()` | Color value |
| `SetColor(color)` | Set color |
| `IsAttuned()` | Is attuned? |
| `SetAttuned(bool)` | Set attuned |
| `IsStackable()` | Is stackable? |
| `IsWeapon()` | Is a weapon? |
| `IsAmmo()` | Is ammo? |
| `IsExpendable()` | Is expendable? |
| `IsAugmentable()` | Can be augmented? |
| `IsAugmented()` | Has augments? |
| `IsEvolving()` | Is an evolving item? |
| `IsEquipable(slot)` / `IsEquipable(race, class)` | Can equip? |
| `IsType(type)` | Is item type? |
| `IsInstanceNoDrop()` | Instance no-drop? |
| `SetInstanceNoDrop(bool)` | Set instance no-drop |
| `GetItem([aug_slot])` | Get underlying ItemData (or augment's) |
| `GetAugment(slot)` | Get augment ItemInstance |
| `GetAugmentItemID(slot)` | Augment item ID |
| `GetAugmentIDs()` | Table of augment IDs |
| `GetAugmentType(slot)` | Augment type |
| `ContainsAugmentByID(item_id)` | Has augment? |
| `CountAugmentByID(item_id)` | Count matching augments |
| `GetItemLink()` | Generate item link string |
| `GetCustomData(key)` | Get custom data field |
| `SetCustomData(key, value)` | Set custom data |
| `DeleteCustomData(key)` | Delete custom data |
| `GetCustomDataString()` | All custom data as string |
| `SetCustomDataString(str)` | Set all custom data |
| `GetRecastTimestamp()` | Recast timestamp |
| `SetRecastTimestamp(ts)` | Set recast timestamp |
| `SetTimer(name, ms)` | Start timer on item |
| `StopTimer(name)` | Stop timer on item |
| `ClearTimers()` | Clear all timers |
| `Clone()` | Clone this item instance |
| `SetScale(multiplier)` | Scale item stats |
| `SetScaling(bool)` | Enable/disable scaling |
| `GetEvolveLevel()` | Current evolve level |
| `GetEvolveAmount()` | Current EXP amount |
| `GetEvolveProgression()` | Progression (0.0–1.0) |
| `GetMaxEvolveLevel()` | Max evolve level |
| `GetEvolveFinalItemID()` | Final item ID |
| `SetEvolveActivated(bool)` | Start/stop evolving |
| `AddEvolveAmount(amt)` | Add evolve EXP |
| `GetEXP()` / `SetEXP(val)` / `AddEXP(val)` | Item EXP |
| `ItemSay(text [,language])` | Item speaks text |
| `GetOrnamentationIcon()` / `GetOrnamentationIDFile()` / `GetOrnamentHeroModel()` | Ornament info |
| `SetOrnamentIcon(icon)` / `SetOrnamentationIDFile(file)` / `SetOrnamentHeroModel(model)` | Set ornament |
| `GetTaskDeliveredCount()` | Count delivered to task |
| `RemoveTaskDeliveredItems()` | Remove task items |
| `GetTotalItemCount()` | Total count including stack |
| `GetUnscaledItem()` | Get pre-scaled item data |

---

## 18. ItemData (QuestItemData)

Read-only item database properties. Accessed via `item_inst:GetItem()`.

| Method | Type | Description |
|---|---|---|
| `GetID()` | `uint32` | Item DB ID |
| `GetName()` | `string` | Item name |
| `GetLore()` | `string` | Lore text |
| `GetComment()` | `string` | Comment text |
| `GetIDFile()` | `string` | Model file |
| `GetIcon()` | `uint32` | Icon ID |
| `GetItemClass()` | `uint8` | Item class (0=common,1=container,2=book) |
| `GetItemType()` | `uint8` | Item type |
| `GetClasses()` | `uint32` | Class bitmask |
| `GetRaces()` | `uint32` | Race bitmask |
| `GetDeity()` | `uint32` | Deity bitmask |
| `GetSlots()` | `uint32` | Slot bitmask |
| `GetRequiredLevel()` / `GetRecommendedLevel()` | `uint8` | Level requirements |
| `GetRecommendedSkill()` | `uint16` | Rec skill |
| `GetHP()` / `GetMana()` / `GetEndurance()` | `int32` | Stats |
| `GetAC()` / `GetATK()` | `int32` | AC/Attack |
| `GetSTR()` / `GetSTA()` / `GetAGI()` / `GetDEX()` / `GetINT()` / `GetWIS()` / `GetCHA()` | `int32` | Stats |
| `GetMR()` / `GetCR()` / `GetFR()` / `GetDR()` / `GetPR()` / `GetCorruption()` | `int32` | Resists |
| `GetHeroicSTR/STA/AGI/DEX/INT/WIS/CHA/MR/CR/FR/DR/PR/Corruption()` | `int32` | Heroic stats |
| `GetHaste()` | `int32` | Haste value |
| `GetDamage()` | `uint32` | Base damage |
| `GetDelay()` | `uint32` | Weapon delay |
| `GetRange()` | `uint8` | Bow range |
| `GetSkillModifier()` | `int32` | Skill modifier |
| `GetPrice()` | `uint32` | Base price |
| `GetWeight()` | `uint32` | Item weight |
| `GetSize()` | `uint8` | Item size |
| `GetNoDrop()` | `uint8` | No drop flag |
| `GetNoRent()` | `uint8` | No rent flag |
| `GetMagic()` | `uint8` | Magic flag |
| `GetLoreFlag()` | `bool` | Is lore? |
| `GetLoreGroup()` | `int32` | Lore group |
| `GetArtifactFlag()` | `uint8` | Artifact flag |
| `GetSummonedFlag()` | `uint8` | Summoned flag |
| `GetFVNoDrop()` | `uint8` | FV no-drop |
| `GetAttunable()` | `uint8` | Can be attuned |
| `GetBook()` | `uint8` | Is book? |
| `GetBookType()` | `uint8` | Book type |
| `GetFilename()` | `string` | Book file |
| `GetMaximumCharges()` | `int8` | Max charges (-1=unlimited) |
| `GetCastTime()` / `GetCastTime_()` | `uint32` | Cast time |
| `GetRecastDelay()` | `uint32` | Recast delay |
| `GetRecastType()` | `uint32` | Recast type |
| `GetClickEffect()` / `GetScrollEffect()` / `GetFocusEffect()` / `GetProcEffect()` / `GetWornEffect()` / `GetBardEffect()` | `int32` | Effect IDs |
| `GetClickType()` / `GetProcType()` etc. | `uint8` | Effect types |
| `GetClickLevel()` / `GetClickLevel2()` | `uint8` | Effect levels |
| `GetBagSlots()` / `GetBagType()` / `GetBagSize()` / `GetBagWeightReduction()` | Bag stats | — |
| `GetAugmentType()` / `GetAugmentRestrict()` | Augment info | — |
| `GetAugmentSlotType(slot)` / `GetAugmentSlotVisible(slot)` | Per-slot augment | — |
| `GetBaneDamageAmount()` / `GetBaneDamageBody()` / `GetBaneDamageRace()` | Bane damage | — |
| `GetElementalDamageType()` / `GetElementalDamageAmount()` | Elemental damage | — |
| `GetDamageShield()` / `GetDSMitigation()` / `GetDOTShielding()` | Defensive stats | — |
| `GetHealAmount()` / `GetSpellDamage()` / `GetClairvoyance()` | Caster stats | — |
| `GetRegen()` / `GetManaRegen()` / `GetEnduranceRegen()` | Regen stats | — |
| `GetExtraDamageSkill()` / `GetExtraDamageAmount()` | Extra damage | — |
| `GetPurity()` | `uint32` | Purity stat |
| `GetBackstabDamage()` | `uint32` | Backstab damage |
| `GetQuestItemFlag()` | `uint32` | Quest item flag |
| `GetMinimumStatus()` | `uint32` | Required status |
| `GetPotionBelt()` / `GetPotionBeltSlots()` | Potion belt info | — |
| `GetCharmFileID()` / `GetCharmFile()` | Charm info | — |
| `GetScriptFileID()` | `uint32` | Script file ID |
| `GetFactionModifier1-4()` / `GetFactionAmount1-4()` | Faction modifiers | — |
| `GetLDoNPrice()` / `GetLDoNSellBackRate()` / `GetLDoNTheme()` | LDoN info | — |

---

## 19. Corpse

**Lua/Perl:** from entity list or event data.

| Method | Description |
|---|---|
| `GetCharID()` | Owner's character ID |
| `GetDBID()` | Corpse DB ID |
| `GetOwnerName()` | Owner's name |
| `GetDecayTime()` | Remaining decay time (ms) |
| `ResetDecayTimer()` | Reset decay |
| `SetDecayTimer(ms)` | Set decay time |
| `IsEmpty()` | No items? |
| `IsLocked()` | Is locked? |
| `IsRezzed()` | Already rezzed? |
| `Lock()` / `UnLock()` | Lock/unlock |
| `GetCopper/Silver/Gold/Platinum()` | Cash on corpse |
| `SetCash(cp, sp, gp, pp)` | Set cash |
| `RemoveCash()` | Remove cash |
| `AddItem(item_id, charges [,slot])` | Add item to corpse |
| `RemoveItem(loot_slot)` | Remove item |
| `RemoveItemByID(item_id [,qty])` | Remove by ID |
| `CountItem(item_id)` | Count items |
| `CountItems()` | Total item count |
| `HasItem(item_id)` | Has item? |
| `GetItemIDBySlot(slot)` | Item ID in slot |
| `GetFirstSlotByItemID(item_id)` | First slot with item |
| `GetLootList()` | All loot items |
| `GetWornItem(slot)` | Item in worn slot |
| `AddLooter(client)` | Allow client to loot |
| `AllowMobLoot(mob, bool)` | Allow/deny mob loot |
| `CanMobLoot(mob)` | Can mob loot? |
| `ResetLooter()` | Reset looter list |
| `CastRezz(spell_id, client)` | Apply rez spell |
| `CompleteRezz()` | Complete resurrection |
| `Summon(client, rez_flag, at_client)` | Summon to client |
| `Delete()` | Delete corpse |

---

## 20. Object

World ground objects. From entity list or `event_click_object`.

| Method | Description |
|---|---|
| `GetID()` | Entity ID |
| `GetDBID()` | DB ID |
| `GetType()` | Object type |
| `GetIcon()` | Icon ID |
| `GetItemID()` | Item ID |
| `GetModelName()` | Model name |
| `GetX/Y/Z()` | Location |
| `GetHeading()` | Heading |
| `GetSize()` | Size |
| `GetSolidType()` | Solid type |
| `GetTiltX/Y()` | Tilt values |
| `IsGroundSpawn()` | Is ground spawn? |
| `SetLocation(x, y, z)` | Move object |
| `SetHeading(h)` | Set heading |
| `SetItemID(id)` | Change item |
| `SetModelName(name)` | Change model |
| `SetSize(size)` | Change size |
| `SetType(type)` | Change type |
| `SetIcon(icon)` | Change icon |
| `SetSolidType(type)` | Change solid type |
| `SetTiltX/Y(val)` | Set tilt |
| `Save()` | Save to DB |
| `Repop()` | Respawn |
| `Depop()` | Despawn |
| `Delete([reset_state])` | Delete object |
| `StartDecay()` | Begin decay |
| `Close()` | Close container |
| `ClearUser()` | Clear user |
| `DeleteItem(index)` | Delete item at index |
| `GetEntityVariable(key)` / `SetEntityVariable(key, val)` / etc. | Entity variables |

---

## 21. Door

From entity list or `event_click_door`.

| Method | Description |
|---|---|
| `GetID()` | Entity ID |
| `GetDoorID()` | Door ID |
| `GetDoorDBID()` | DB ID |
| `GetModelName()` | Model |
| `GetX/Y/Z()` | Location |
| `GetHeading()` | Heading |
| `GetSize()` | Size |
| `GetOpenType()` | Open type |
| `GetLockPick()` | Lock pick difficulty |
| `GetKeyItem()` | Required key item ID |
| `GetNoKeyring()` | No keyring flag |
| `GetInvertState()` | Inverted state |
| `GetIncline()` | Incline |
| `GetDoorParam()` | Door parameter |
| `GetGuildID()` | Required guild ID |
| `GetDzSwitchID()` | DZ switch ID |
| `GetTriggerDoorID()` / `GetTriggerType()` | Trigger info |
| `GetDestinationZoneName()` / `GetDestinationX/Y/Z/Heading()` / `GetDestinationInstanceID()` | Zone-in info |
| `HasDestinationZone()` / `IsDestinationZoneSame()` / `IsDoorBlacklisted()` / `IsLDoNDoor()` | Flag checks |
| `GetClientVersionMask()` | Version mask |
| `GetDisableTimer()` | Auto-close timer |
| `SetDisableTimer(ms)` | Set auto-close timer |
| `SetLocation(x, y, z)` | Move door |
| `SetHeading(h)` | Set heading |
| `SetSize(size)` | Set size |
| `SetModelName(name)` | Set model |
| `SetOpenType(type)` | Set open type |
| `SetLockPick(lp)` | Set lock pick |
| `SetKeyItem(item_id)` | Set key |
| `SetNoKeyring(bool)` | Set no keyring |
| `SetInvertState(bool)` | Set invert |
| `SetIncline(inc)` | Set incline |
| `ForceOpen(mob [,alt_mode])` | Force open |
| `ForceClose(mob [,alt_mode])` | Force close |
| `CreateDatabaseEntry()` | Persist to DB |

---

## 22. Spawn

Represents a `spawn2` entry.

**Perl:** `$spawn` | **Lua:** from event data

| Method | Description |
|---|---|
| `GetID()` | Spawn2 ID |
| `GetSpawnGroupID()` | Spawngroup ID |
| `GetCurrentNPCID()` | Current NPC type ID |
| `GetX/Y/Z/Heading()` | Location |
| `GetRespawnTimer()` | Respawn time |
| `GetVariance()` | Variance |
| `GetKillCount()` | Kill count |
| `GetSpawnCondition()` | Spawn condition |
| `IsEnabled()` | Is enabled? |
| `IsNPCPointerValid()` | Is NPC alive? |
| `Enable()` / `Disable()` | Enable/disable |
| `Repop([delay_ms])` | Force repop |
| `Reset()` | Reset timer |
| `Depop()` | Depop NPC |
| `ForceDespawn()` | Force despawn |
| `LoadGrid()` | Load waypoint grid |
| `SetRespawnTimer(ms)` | Set respawn time |
| `SetVariance(val)` | Set variance |
| `SetTimer(ms)` | Set manual timer |
| `SetCurrentNPCID(id)` | Change NPC type |
| `SetNPCPointer(npc)` | Set NPC reference |

---

## 23. Zone

**Lua:** `local z = eq.get_zone()` | **Perl:** `$zone`

| Method | Description |
|---|---|
| `GetShortName()` / `GetLongName()` | Zone names |
| `GetZoneID()` | Zone ID |
| `GetInstanceID()` / `GetInstanceVersion()` | Instance info |
| `GetInstanceType()` / `IsInstancePersistent()` | Instance type |
| `GetInstanceTimer()` / `GetInstanceTimeRemaining()` | Instance time |
| `GetSafeX/Y/Z/Heading()` | Safe coordinates |
| `GetFlagNeeded()` | Required zone flag |
| `GetMinimumLevel()` / `GetMaximumLevel()` | Level range |
| `GetMinimumStatus()` | Required status |
| `GetMaxClients()` | Max players |
| `GetExpansion()` | Expansion ID |
| `GetMinimumExpansion()` / `GetMaximumExpansion()` | Expansion range |
| `GetRuleSet()` | Rule set ID |
| `GetGravity()` | Zone gravity |
| `GetFogDensity()` | Fog density |
| `GetFogRed/Green/Blue([slot])` | Fog color |
| `GetFogMinimumClip/MaximumClip([slot])` | Fog clip |
| `GetSky()` / `GetSkyLock()` | Sky type |
| `GetWalkSpeed()` | Walk speed |
| `GetTimeType()` / `GetTimeZone()` | Time settings |
| `GetUnderworld()` | Underworld Z |
| `GetUnderworldTeleportIndex()` | Underworld TP index |
| `GetLavaDamage()` / `GetMinimumLavaDamage()` | Lava damage |
| `GetFastRegenHP/Mana/Endurance()` | Fast regen rates |
| `GetNPCMaximumAggroDistance()` | Max aggro range |
| `GetGraveyardX/Y/Z/Heading/ZoneID/ID()` | Graveyard info |
| `HasGraveyard()` | Has graveyard? |
| `GetNote()` | Zone note |
| `GetZoneDescription()` | Description |
| `GetContentFlags()` / `GetContentFlagsDisabled()` | Content flags |
| `GetExperienceMultiplier()` | XP modifier |
| `IsHotzone()` / `IsCity()` / `IsStaticZone()` / `IsPVPZone()` | Zone flags |
| `CanBind()` / `CanLevitate()` / `CanDoCombat()` / `CanCastOutdoor()` | Capability flags |
| `IsRaining()` / `IsSnowing()` / `HasWeather()` | Weather state |
| `GetRainChance/Duration([slot])` / `GetSnowChance/Duration([slot])` | Weather chances |
| `IsSpellBlocked(spell_id, x, y, z)` | Is spell blocked at location? |
| `GetZoneTotalBlockedSpells()` | Count of blocked spells |
| `HasMap()` / `HasWaterMap()` | Map info |
| `GetVariable(key)` / `SetVariable(key, val)` / `DeleteVariable(key)` / `GetVariables()` / `ClearVariables()` | Zone variables |
| `GetBucket(key)` / `SetBucket(key, val)` / `DeleteBucket(key)` | Zone buckets |
| `GetEXPModifier(client)` / `SetEXPModifier(client, mod)` | EXP modifiers |
| `GetAAEXPModifier(client)` / `SetAAEXPModifier(client, mod)` | AA EXP modifiers |
| `Repop([bool])` | Repop zone |
| `Depop([start_timers])` | Depop zone |
| `Despawn(spawngroup_id)` | Despawn group |
| `ClearSpawnTimers()` / `DisableRespawnTimers()` | Timer management |
| `GetFileName()` | Zone file name |
| `GetZoneZType()` / `GetZoneType()` | Zone type |
| `BuffTimersSuspended()` / `BypassesExpansionCheck()` | Special flags |
| `IsUCSServerAvailable()` | Is UCS available? |
| `IsWaterZone()` / `IsIdleWhenEmpty()` | More flags |
| `GetShutdownDelay()` / `GetSecondsBeforeIdle()` | Timing |
| `GetPEQZone()` | Is PEQ zone? |

---

## 24. Merc

**Lua/Perl:** from entity list or event data.

| Method | Description |
|---|---|
| `GetMercenaryID()` | Merc DB ID |
| `GetMercenaryCharacterID()` | Owner char ID |
| `GetMercenaryTemplateID()` | Template ID |
| `GetMercenaryType()` | Type ID |
| `GetMercenarySubtype()` | Subtype ID |
| `GetMercenaryNameType()` | Name type |
| `GetOwner()` | Owner Mob |
| `GetOwnerOrSelf()` | Owner or self |
| `GetMercenaryOwner()` | Merc owner |
| `GetGroup()` | Group object |
| `GetStance()` | Current stance |
| `GetTierID()` | Tier ID |
| `GetProficiencyID()` | Proficiency ID |
| `GetCostFormula()` | Cost formula |
| `ScaleStats(level [,bool])` | Scale to level |
| `IsMercenaryCaster()` | Is caster merc? |
| `IsMercenaryCasterCombatRange(mob)` | In combat range? |
| `IsSitting()` / `IsStanding()` | Posture |
| `Sit()` / `Stand()` | Set posture |
| `Suspend()` | Suspend merc |
| `Signal(signal_id)` | Send signal |
| `SendPayload(id [,payload])` | Send payload event |
| `SetTarget(mob)` | Set target |
| `UseDiscipline(spell_id, target)` | Use discipline |
| `HasOrMayGetAggro()` | May get aggro? |
| `GetHatedCount()` | How many hate this merc |
| `GetMaxMeleeRangeToTarget(mob)` | Max melee range |

---

## 25. HateEntry

Elements returned from `mob:GetHateList()`.

| Method | Description |
|---|---|
| `GetEnt()` | The Mob on the hate list |
| `GetHate()` | Hate amount |
| `GetDamage()` | Damage amount |
| `GetFrenzy()` | Is frenzy? |
| `SetEnt(mob)` | Set entity |
| `SetHate(val)` | Set hate |
| `SetDamage(val)` | Set damage |
| `SetFrenzy(bool)` | Set frenzy |

---

## 26. StatBonuses

Read-only struct returned by `GetSpellBonuses()`, `GetAABonuses()`, `GetItemBonuses()`.

All methods are getters that return numeric values. Key examples:

| Method | Description |
|---|---|
| `GetAC()` | AC bonus |
| `GetHP()` | HP bonus |
| `GetMana()` | Mana bonus |
| `GetHaste()` / `GetHasteType2()` / `GetHasteType3()` | Haste bonuses |
| `GetATK()` | Attack bonus |
| `GetSTR/STA/AGI/DEX/INT/WIS/CHA()` | Stat bonuses |
| `GetMR/CR/FR/DR/PR/Corruption()` | Resist bonuses |
| `GetHeroicSTR/STA/...()` | Heroic stat bonuses |
| `GetHPRegen()` / `GetManaRegen()` / `GetEnduranceRegen()` | Regen bonuses |
| `GetCriticalHitChance()` | Crit chance |
| `GetCriticalSpellChance()` | Spell crit chance |
| `GetDodgeChance()` | Dodge bonus |
| `GetDoubleAttackChance()` | Double attack |
| `GetFlurryChance()` | Flurry chance |
| `GetSkillDamageModifier()` | Skill damage |
| `GetHealAmt()` / `GetSpellDamage()` | Heal/spell bonus |
| `GetAggroRange()` / `GetAssistRange()` | Range modifiers |
| `GetDamageShield()` | DS amount |
| `GetHateModifier()` | Hate modifier |
| `GetSpellShield()` | Spell shield |
| `GetAbsorbMagicAttack()` | Absorb magic |
| `GetFocusEffects()` / `GetFocusEffectsWorn()` | Focus arrays |
| `GetEndurance()` / `GetEnduranceRegen()` | Endurance |
| `GetExtraAttackChance()` | Extra attacks |

---

## 27. Spell

The `Spell` object represents a static spell data record (read-only). It is passed as `e.spell` in events such as `event_death`, `event_cast`, `event_cast_on`, `event_cast_begin`, `event_weapon_proc`, `event_spell_blocked`, and `event_memorize_spell`.

**Lua:** `e.spell:Method()` — methods use short names without `Get` prefix
**Perl:** `$spell->Method()` — methods use full `GetXxx()` names

> Always check `e.spell ~= nil` (Lua) or `defined $spell` (Perl) before calling methods. The spell field is nil/undef when no spell was involved (e.g. a melee kill in `event_death`).

### Identification

| Lua Method | Perl Method | Returns | Description |
|---|---|---|---|
| `ID()` | `GetID()` | `int` | Spell ID |
| `Name()` | `GetName()` | `string` | Spell name |
| `YouCast()` | `GetYouCast()` | `string` | "You cast" message |
| `OtherCasts()` | `GetOtherCasts()` | `string` | "Other casts" message |
| `CastOnYou()` | `GetCastOnYou()` | `string` | "Cast on you" message |
| `CastOnOther()` | `GetCastOnOther()` | `string` | "Cast on other" message |
| `SpellFades()` | `GetSpellFades()` | `string` | Fade message |
| `TeleportZone()` | `GetTeleportZone()` | `string` | Zone for translocate spells |
| `Player1()` | `GetPlayer_1()` | `string` | Player 1 string field |
| `Rank()` | `GetRank()` | `int` | Spell rank (0=base, 1=Rk.II, 2=Rk.III) |
| `SpellGroup()` | `GetSpellGroup()` | `int` | Spell group ID (stacking group) |
| `SpellCategory()` | `GetSpellCategory()` | `int` | Spell category |
| `SpellAffectIndex()` | `GetSpellAffectIndex()` | `int` | Affect index |

### Targeting & Range

| Lua Method | Perl Method | Returns | Description |
|---|---|---|---|
| `TargetType()` | `GetTargetType()` | `int` | Target type (0=self, 1=group, 5=single, etc.) |
| `Range()` | `GetRange()` | `float` | Cast range |
| `AoeRange()` | `GetAoeRange()` | `float` | AoE range |
| `MinRange()` | `GetMinRange()` | `float` | Minimum cast range |
| `MinDist()` | `GetMinDistance()` | `float` | Min distance |
| `MinDistMod()` | `GetMinDistanceMod()` | `float` | Min distance modifier |
| `MaxDist()` | `GetMaxDistance()` | `float` | Max distance |
| `MaxDistMod()` | `GetMaxDistanceMod()` | `float` | Max distance modifier |
| `AEMaxTargets()` | `GetAOEMaxTargets()` | `int` | Max AoE targets |
| `MaxTargets()` | — (Lua only) | `int` | Max targets (general) |
| — | `GetNoHealDamageItemMod()` | `int` | Perl only |

### Timing

| Lua Method | Perl Method | Returns | Description |
|---|---|---|---|
| `CastTime()` | `GetCastTime()` | `uint32` | Cast time in ms |
| `RecoveryTime()` | `GetRecoveryTime()` | `uint32` | Recovery time in ms |
| `RecastTime()` | `GetRecastTime()` | `uint32` | Recast time in ms |
| `BuffDuration()` | `GetBuffDuration()` | `uint32` | Buff duration in ticks |
| `BuffdurationFormula()` | `GetBuffDurationFormula()` | `uint32` | Duration formula ID |
| `AEDuration()` | `GetAOEDuration()` | `uint32` | AoE duration |

### Mana / Endurance

| Lua Method | Perl Method | Returns | Description |
|---|---|---|---|
| `Mana()` | `GetMana()` | `int` | Mana cost |
| `EndurCost()` | `GetEnduranceCost()` | `int` | Endurance cost |
| `EndurUpkeep()` | `GetEnduranceUpkeep()` | `int` | Endurance upkeep per tick |
| `EndurTimerIndex()` | — (Lua only) | `int` | Endurance timer index |

### Resist / Hate

| Lua Method | Perl Method | Returns | Description |
|---|---|---|---|
| `ResistType()` | `GetResistType()` | `int` | Resist type (0=none, 1=magic, 2=fire, etc.) |
| `ResistDiff()` | `GetResistDifficulty()` | `int` | Resist difficulty modifier |
| `MinResist()` | `GetMinResist()` | `int` | Minimum resist cap |
| `MaxResist()` | `GetMaxResist()` | `int` | Maximum resist cap |
| `BonusHate()` | `GetBonusHate()` | `int` | Flat hate added |
| `HateAdded()` | `GetHateAdded()` | `int` | Hate on land |

### Effect Data (slot arrays, index 0–11)

| Lua Method | Perl Method | Returns | Description |
|---|---|---|---|
| `EffectID(i)` | `GetEffectID(i)` | `int` | Spell effect type in slot i |
| `Base(i)` | `GetBaseValue(i)` | `int` | Base value of effect in slot i |
| `Base2(i)` | `GetLimitValue(i)` | `int` | Limit value of effect in slot i |
| `Max(i)` | `GetMaxValue(i)` | `int` | Max value of effect in slot i |
| `Formula(i)` | `GetFormula(i)` | `int` | Formula ID for slot i |

### Reagents (slot arrays, index 0–3)

| Lua Method | Perl Method | Returns | Description |
|---|---|---|---|
| `Components(i)` | `GetComponent(i)` | `int` | Required component item ID |
| `ComponentCounts(i)` | `GetComponentCount(i)` | `int` | Required count |
| `NoexpendReagent(i)` | `GetNoExpendReagent(i)` | `int` | No-expend reagent item ID |

### Class / Deity Restrictions (index 0–15)

| Lua Method | Perl Method | Returns | Description |
|---|---|---|---|
| `Classes(i)` | `GetClasses(i)` | `int` | Min level for class i (255 = unavailable) |
| `Deities(i)` | `GetDeities(i)` | `int` | Deity restriction flag for index i |

### Flags & Properties

| Lua Method | Perl Method | Returns | Description |
|---|---|---|---|
| `GoodEffect()` | `GetGoodEffect()` | `int` | Beneficial (1) or detrimental (0) |
| `Skill()` | `GetSkill()` | `int` | Spell skill used (evocation, alteration, etc.) |
| `AllowRest()` | `GetAllowRest()` | `bool` | Can cast while resting? |
| `InCombat()` | `GetCanCastInCombat()` | `bool` | Can cast in combat? |
| `OutOfCombat()` | `GetCanCastOutOfCombat()` | `bool` | Can cast out of combat? |
| `PersistDeath()` | `GetPersistDeath()` | `bool` | Buff persists through death? |
| `CanMGB()` | `GetCanMGB()` | `bool` | Can be mass group buffed? |
| `Uninterruptable()` | `GetUninterruptable()` | `int` | Cannot be interrupted? |
| `DispelFlag()` | `GetDispelFlag()` | `int` | Dispel behavior |
| `ShortBuffBox()` | `GetShortBuffBox()` | `int` | Shows in short buff box? |
| `NumHits()` | `GetHitNumber()` | `int` | Number of hits before fading |
| `PowerfulFlag()` | `GetNoResist()` | `int` | No-resist flag |
| `NimbusEffect()` | `GetNimbusEffect()` | `int` | Nimbus/aura visual effect ID |
| `RecourseLink()` | `GetRecourseLink()` | `int` | Linked recourse spell ID |
| `ViralTargets()` | `GetViralTargets()` | `int` | Viral spell target count |
| `ViralTimer()` | `GetViralTimer()` | `int` | Viral spread timer |
| `ZoneType()` | `GetZoneType()` | `int` | Zone type restriction |
| `TimeOfDay()` | `GetTimeOfDay()` | `int` | Time of day restriction |
| `EnvironmentType()` | `GetEnvironmentType()` | `int` | Environment type |
| `PVPDuration()` | `GetPVPDuration()` | `int` | PvP duration |
| `PVPDurationCap()` | `GetPVPDurationCap()` | `int` | PvP duration cap |
| `PushBack()` | `GetPushBack()` | `float` | Push-back amount |
| `PushUp()` | `GetPushUp()` | `float` | Push-up amount |
| `DirectionalStart()` | `GetDirectionalStart()` | `float` | Directional cone start angle |
| `DirectionalEnd()` | `GetDirectionalEnd()` | `float` | Directional cone end angle |

### Perl-Only Methods

The following methods exist in Perl but have no direct Lua equivalent:

| Perl Method | Returns | Description |
|---|---|---|
| `GetCanCastInCombat()` | `bool` | (same as Lua `InCombat()`) |
| `GetCastNotStanding()` | `bool` | Can cast without standing? |
| `GetDeityAgnostic()` | `bool` | Deity-agnostic? |
| `GetFeedbackable()` | `bool` | Can be spell reflected? |
| `GetIsDiscipline()` | `bool` | Is a discipline? |
| `GetLDoNTrap()` | `bool` | Is an LDoN trap? |
| `GetNoBlock()` | `bool` | Cannot be blocked? |
| `GetNoDetrimentalSpellAggro()` | `bool` | Detrimental without aggro? |
| `GetNoPartialResist()` | `bool` | Cannot be partially resisted? |
| `GetNoRemove()` | `bool` | Cannot be removed/dispelled? |
| `GetNotFocusable()` | `bool` | Not affected by focus items? |
| `GetNPCNoLOS()` | `bool` | NPC ignores LOS for this spell? |
| `GetOverrideCritChance()` | `int` | Crit override percentage |
| `GetPCNPCOnlyFlag()` | `int` | PC-only or NPC-only flag |
| `GetReflectable()` | `bool` | Can be reflected? |
| `GetSneak()` | `bool` | Requires sneak? |
| `GetSongCap()` | `int` | Song cap modifier |
| `GetSpellClass()` | `int` | Spell class |
| `GetSpellSubclass()` | `int` | Spell subclass |
| `GetSuspendable()` | `bool` | Can be suspended? |
| `GetTimerID()` | `int` | Recast timer ID |
| `GetUnstackableDOT()` | `bool` | Unstackable DoT? |
| `GetCasterRequirementID()` | `int` | Caster requirement ID |
| `GetNewIcon()` | `int` | Spell icon ID |

### Common Usage Example

```lua
-- In event_death: check if the killing spell was a fire-based DD
function event_death(e)
    if e.spell ~= nil and e.spell:ResistType() == 2 then  -- 2 = fire
        e.self:Say("I'm on fire!")
    end
end
```

```perl
# In EVENT_DEATH: check killing spell
sub EVENT_DEATH {
    if (defined $spell && $spell->GetResistType() == 2) {
        $npc->Say("I'm on fire!");
    }
}
```

---

## 28. Database (Lua)

`zone/lua_database.cpp`. Same prepared-statement model as the Perl `QuestDB` below; there is no `eq.open_mysql_connection()` and no `query()` — you always `prepare` then `execute`.

```lua
local db = Database(Database.Content)   -- or Database.Default for the player DB, or Database()
local stmt = db:prepare("SELECT name FROM npc_types WHERE id = ?")
stmt:execute({ 1234 })
local row = stmt:fetch_hash()
if row then eq.say(row.name) end
stmt:close()
db:close()
```

| Constructor | Description |
|---|---|
| `Database()` | Default (player) connection |
| `Database(Database.Default \| Database.Content)` | Pick connection; optional second bool arg |
| `Database(host, user, pass, db, port)` | Custom connection |

| `Database` method | Description |
|---|---|
| `prepare(sql)` | Returns a `MySQLPreparedStmt` |
| `close()` | Close connection |

| `MySQLPreparedStmt` method | Description |
|---|---|
| `execute([args_table])` | Execute with bind params |
| `fetch()` / `fetch_array()` | Next row as array |
| `fetch_hash()` | Next row as table keyed by column |
| `insert_id()`, `num_fields()`, `num_rows()`, `rows_affected()` | Result info |
| `set_options(table)` | `buffer_results`, `use_max_length` |
| `close()` | Close statement |

Perl scripts on this server mostly use `plugin::LoadMysql()` (`plugins/MySQL.pl`, DBI) instead — see CODEBASE.md §6.1 for the driver caveats.

---

## 29. Database (Perl — QuestDB)

```perl
my $db = new QuestDB;
my $sth = $db->prepare("SELECT name FROM npc_types WHERE id = ?");
$sth->execute([1234]);
while (my $row = $sth->fetch_hashref) {
    quest::say($row->{name});
}
$sth->close;
```

| Method | Description |
|---|---|
| `new([connection_type])` | Create connection (default = content DB) |
| `new(host, user, pass, db, port)` | Custom connection |
| `prepare(sql)` | Prepare a statement |
| `close()` | Close connection |

**PreparedStatement:**

| Method | Description |
|---|---|
| `execute([args_array])` | Execute with bind params |
| `fetch()` / `fetch_array()` | Fetch row as array |
| `fetch_arrayref()` | Fetch as array ref |
| `fetch_hashref()` | Fetch as hash ref |
| `insert_id()` | Last insert ID |
| `num_fields()` | Column count |
| `num_rows()` | Row count |
| `rows_affected()` | Affected rows |
| `set_options(hash)` | Options: `buffer_results`, `use_max_length` |
| `close()` | Close statement |

---

## 30. PerlPacket

**Perl only.** Low-level packet construction.

```perl
my $pack = new PerlPacket(0x1234, 10);
$pack->SetByte(0, 42);
$pack->SendTo($client);
```

| Method | Description |
|---|---|
| `new([opcode [,length]])` | Create packet |
| `SetOpcode(opcode)` | Set opcode |
| `Resize(len)` | Resize buffer |
| `Zero()` | Zero out buffer |
| `SendTo(client)` | Send to specific client |
| `SendToAll()` | Send to all clients in zone |
| `FromArray(arrayref, length)` | Fill from array |
| `SetByte(pos, val)` | Write byte |
| `SetShort(pos, val)` | Write 16-bit int |
| `SetLong(pos, val)` | Write 32-bit int |
| `SetFloat(pos, val)` | Write float |
| `SetString(pos, str)` | Write string |
| `GetByte(pos)` | Read byte |
| `GetShort(pos)` | Read 16-bit int |
| `GetLong(pos)` | Read 32-bit int |
| `GetFloat(pos)` | Read float |

---

## 31. Lua Utilities

### `Random` Namespace

```lua
local val = Random.Int(1, 100)
local chance = Random.Roll(50)  -- 50% chance, returns bool
```

| Function | Description |
|---|---|
| `Random.Int(min, max)` | Random integer in range |
| `Random.Real(min, max)` | Random float in range |
| `Random.Roll(percent)` | True if roll succeeds (1–100 percent) |
| `Random.RollReal(percent)` | True if roll succeeds (0.0–100.0) |
| `Random.Roll0(max)` | Random int 0 to max-1 |

### `bit` Namespace (Bitwise)

```lua
local result = bit.band(flags, 0x04)
```

| Function | Description |
|---|---|
| `bit.band(a, b)` | Bitwise AND |
| `bit.bor(a, b)` | Bitwise OR |
| `bit.bxor(a, b)` | Bitwise XOR |
| `bit.bnot(a)` | Bitwise NOT |
| `bit.lshift(a, n)` | Left shift |
| `bit.rshift(a, n)` | Right shift |
| `bit.arshift(a, n)` | Arithmetic right shift |
| `bit.tobit(a)` | Convert to bit integer |
| `bit.tohex(a [,n])` | Convert to hex string |

---

## 32. Popup Formatting Helpers (Lua)

These helper functions build formatted HTML-like strings for use inside `eq.popup()`.

```lua
local content = eq.popup_color_message("{lb}", "Welcome to the server!")
content = content .. eq.popup_break()
content = content .. eq.popup_table(
    eq.popup_table_row(
        eq.popup_table_cell("Column 1"),
        eq.popup_table_cell("Column 2")
    )
)
eq.popup("Title", content)
```

| Function | Description |
|---|---|
| `eq.popup_break([width])` | Horizontal rule separator |
| `eq.popup_center_message(text)` | Centered text |
| `eq.popup_color_message(color_code, text)` | Colored text. Colors: `{y}`=yellow, `{r}`=red, `{g}`=green, `{lb}`=cyan, `{gold}`, `{orange}` |
| `eq.popup_indent([size])` | Indent block |
| `eq.popup_link(url [,link_text])` | Clickable link |
| `eq.popup_table(rows...)` | Build a table |
| `eq.popup_table_row(cells...)` | Build a table row |
| `eq.popup_table_cell([content])` | Build a table cell |

### DialogueWindow Render Syntax

When building popup bodies, inline directives are also supported in the text string:

| Directive | Description |
|---|---|
| `{color}text` | Color shortcuts as above |
| `+animname+` or `+N+` | NPC plays animation by name or ID |
| `=seconds=` | Popup auto-closes after N seconds |
| `wintype:N` | Set window type |
| `popupid:N` | Override popup ID |

---

## 33. Cross-Zone & World-Wide Functions

### Cross-Zone

Target a specific character, group, raid, guild, expedition, NPC type, or entity by name.

**Pattern:** `eq.cross_zone_[action]_by_[target_type](...)`

| Target Types | Identifiers |
|---|---|
| `char_id` | Character DB ID |
| `group_id` | Group ID |
| `raid_id` | Raid ID |
| `guild_id` | Guild ID |
| `expedition_id` | Expedition ID |
| `client_name` | Character name string |
| `npctype_id` | NPC type ID |

| Actions | Description |
|---|---|
| `add_ldon_loss` / `add_ldon_win` / `remove_ldon_loss` / `remove_ldon_win` | LDoN points |
| `add_ldon_points(theme_id, points)` | Add LDoN points |
| `assign_task(task_id)` | Assign task |
| `cast_spell(spell_id)` | Cast spell on target |
| `dialogue_window(text)` | Show dialogue window |
| `disable_task(task_id)` / `enable_task(task_id)` | Task management |
| `fail_task(task_id)` / `remove_task(task_id)` | Task management |
| `marquee(type, priority, fade_in, fade_out, dur, msg)` | Marquee |
| `message_player(color, msg)` | Send message |
| `move_player(zone_id, x, y, z, h)` | Zone player |
| `move_instance(zone_id, instance_id, x, y, z, h)` | Zone to instance |
| `remove_spell(spell_id)` | Remove buff |
| `reset_activity(task_id, activity_id)` | Reset task activity |
| `set_entity_variable(key, value)` | Set entity variable |
| `signal_client(signal_id)` | Signal client |
| `signal_npc(npc_type_id, signal_id)` | Signal NPC |
| `update_activity(task_id, activity_id, count)` | Update task |

**Example:**
```lua
eq.cross_zone_message_player_by_char_id(char_id, 15, "You've been selected!")
eq.cross_zone_assign_task_by_group_id(group_id, 101)
```

### World-Wide

Same actions as cross-zone but broadcast to all zones. Optionally filter by status level.

**Pattern:** `eq.world_wide_[action]([min_status [,max_status]])`

```lua
eq.world_wide_message(15, "Server event starting!", 0, 255)
eq.world_wide_signal_npc(1234, 5)
```

---

## 34. Expansion & Content Flag Checks

### Expansion Checks

Returns `bool`. Available for all EQ expansions:

```lua
if eq.is_planes_of_power_enabled() then
    -- PoP content
end
```

Available expansion names: `classic`, `ruins_of_kunark`, `scars_of_velious`, `shadows_of_luclin`, `planes_of_power`, `legacy_of_ykesha`, `lost_dungeons_of_norrath`, `gates_of_discord`, `omens_of_war`, `dragons_of_norrath`, `depths_of_darkhollow`, `prophecy_of_ro`, `serpents_spine`, `buried_sea`, `secrets_of_faydwer`, `seeds_of_destruction`, `underfoot`, `house_of_thule`, `veil_of_alaris`, `rain_of_fear`, `call_of_the_forsaken`, `darkened_sea`, `broken_mirror`, `empires_of_kunark`, `ring_of_scale`, `burning_lands`, `torment_of_velious`.

Use `eq.is_[name]_enabled()` or `eq.is_current_expansion_[name]()`.

### Content Flags

```lua
if eq.is_content_flag_enabled("halloween_event") then
    -- event active
end

eq.set_content_flag("halloween_event", true)
```

| Function | Description |
|---|---|
| `eq.is_content_flag_enabled(flag_name)` | Is named flag enabled? |
| `eq.set_content_flag(flag_name, bool)` | Enable/disable flag |
