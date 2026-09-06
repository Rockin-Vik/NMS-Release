# GM Commands Reference

Every command registered in `zone/command.cpp` (`command_init()`, 172 commands), with its
compiled-in default status level and syntax. Generated against NMS-Release commit `0e400b81`;
the status column and the command list were extracted from source, the per-command syntax
was written by hand. If you add a command, add it here.

Related: [`CODEBASE.md`](../Release-NMS-Deploy/CODEBASE.md) (architecture, what is custom),
[`QUEST-API.md`](../Release-NMS-Quests/QUEST-API.md) (script API).

---

## Account status levels

`common/emu_constants.h:29-46`. These are the values you put in `account.status`.

| Value | Constant | Display name |
|---|---|---|
| 0 | `Player` | Player |
| 10 | `Steward` | Steward |
| 20 | `ApprenticeGuide` | Apprentice Guide |
| 50 | `Guide` | Guide |
| 80 | `QuestTroupe` | Quest Troupe |
| 81 | `SeniorGuide` | Senior Guide |
| 85 | `GMTester` | GM Tester |
| 90 | `EQSupport` | EQ Support |
| 95 | `GMStaff` | GM Staff |
| 100 | `GMAdmin` | GM Admin |
| 150 | `GMLeadAdmin` | GM Lead Admin |
| 160 | `QuestMaster` | Quest Master |
| 170 | `GMAreas` | GM Areas |
| 180 | `GMCoder` | GM Coder |
| 200 | `GMMgmt` | GM Mgmt |
| 250 | `GMImpossible` | GM Impossible |
| 255 | `Max` | GM Max |

`SeniorGuide`, `GMTester`, `GMStaff` and `QuestMaster` exist but no command in this fork
requires them. The first account to log in on a fresh install gets
`UPDATE account SET status = 250 WHERE name = '<login>'`.

## How access is actually decided

The **Default status** shown under each command is what is compiled into `command.cpp`. It is
only a default:

- At zone boot `command_init()` reads the `command_settings` table and **overrides** every
  compiled-in level with the DB value (`command.cpp:249-341`). New commands are auto-inserted
  into `command_settings` at their compiled default the first time a zone sees them.
- `command_subsettings` gates individual subcommands of `#set`, `#show`, `#find` and friends.
- `#reload commands` re-reads both tables without restarting the zone.

So if a command behaves differently from this document, check `command_settings` first.
Commands with default status **Player (0)** are player-facing features, not GM tools.

## What is NMS-specific

Nine commands do not exist in upstream EQEmu: `#alttoggle`, `#attackmode`, `#autoskill`,
`#award`, `#castspellnms`, `#fabled`, `#petcmd`, `#soulmark`, `#tim`. One `#show` subcommand,
`#show exempt`, is also custom. `#zoneshard` is stock by name but its implementation is
NMS-modified (hub zones). Everything else is upstream. Side effects of the custom commands
(data buckets, Discord webhooks, signals) are noted under each one.

---

## Commands

### `#acceptrules`
Default status: **Player (0)**  
Accept the EQEmu server rules agreement.

---

### `#advnpcspawn`
Default status: **GMLeadAdmin (150)**  
Advanced NPC spawn management.

| Subcommand | Description |
|---|---|
| `addentry [Spawngroup ID] [NPC ID] [Spawn Chance]` | Add an entry to a spawngroup |
| `addspawn [Spawngroup ID]` | Add a spawn from an existing spawngroup |
| `clearbox [Spawngroup ID]` | Clear a spawngroup's roambox |
| `deletespawn` | Delete a spawngroup |
| `editbox [Spawngroup ID] [Distance] [Min X] [Max X] [Min Y] [Max Y] [Delay]` | Edit a spawngroup's roambox |
| `editrespawn [Respawn Timer] [Variance]` | Edit a spawngroup's respawn timer |
| `makegroup [Name] [Limit] [Distance] [Min X] [Max X] [Min Y] [Max Y] [Delay]` | Create a new spawngroup |
| `makenpc` | Create a new NPC |
| `movespawn` | Move a spawngroup to your current location |
| `setversion [Version]` | Set a spawngroup's version |

---

### `#aggrozone [Aggro]`
Default status: **GMAdmin (100)**  
Aggro every NPC in the zone with the specified aggro value (default 0). Use with caution — recommended while invulnerable.

---

### `#ai`
Default status: **GMAdmin (100)**  
Modify AI settings on a targeted NPC.

| Subcommand | Description |
|---|---|
| `consider [Mob Name]` | Show how the targeted NPC considers another mob |
| `faction [Faction ID]` | Set the NPC's faction ID |
| `guard` | Save the NPC's current location as its guard spot |
| `roambox [Distance] [Min X] [Max X] [Min Y] [Max Y] [Delay] [Min Delay]` | Set a roambox using coordinates |
| `roambox [Distance] [Roam Distance] [Delay] [Min Delay]` | Set a roambox using roam distance |
| `spells [Spell List ID]` | Set the NPC's spell list ID |

---

### `#alttoggle [AA ID]`
Default status: **Player (0)**  
**NMS.** Toggle a passive AA on or off for yourself. Validated against `aa_ability`.

---

### `#appearance [Type] [Value]`
Default status: **GMLeadAdmin (150)**  
Send an appearance packet for yourself or your target. Use with no arguments to list all available type IDs.

---

### `#appearanceeffects`
Default status: **GMAdmin (100)**  
Modify appearance effects on yourself or your target.

| Subcommand | Description |
|---|---|
| `help` | Display the help menu |
| `remove` | Remove all saved appearance effects |
| `set [Effect ID] [Slot ID]` | Set an appearance effect in a slot |
| `view` | Display all saved appearance effects |

---

### `#apply_shared_memory [Name]`
Default status: **GMImpossible (250)**  
Tell world and every zone to switch to the named shared-memory segment. Pair with `#load_shared_memory`, or use `#hotfix` for both.

---

### `#attack [Entity Name]`
Default status: **GMLeadAdmin (150)**  
Make your targeted NPC attack the specified entity by name.

---

### `#attackmode [ranged|melee|toggle]`
Default status: **Player (0)**  
**NMS.** Switch between ranged and melee autoattack. No argument prints the current mode.

---

### `#augmentitem`
Default status: **GMImpossible (250)**  
Force augments an item. Must have the augment item window open.

---

### `#autoskill [Skill ID|Skill Name] [enable|disable|status]`
Default status: **Player (0)**  
**NMS.** Toggle automatic use of a combat skill. `#autoskill list` shows what your classes
can automate (Backstab, Bash, Disarm, Dragon Punch, Eagle Strike, Flying Kick, Kick, Round
Kick, Tiger Claw, Frenzy). Accepts `on/off/1/0/yes/no` as synonyms.

Side effect: enabling a skill you have at 0 sets it to 1 first (`gm_commands/autoskill.cpp`).

---

### `#award [Character Name] [Amount] [Reason...]`
Default status: **GMAdmin (100)**  
**NMS.** Grant Echo of Memory to a character (online or offline). All three arguments are
required; the reason is free text.

How it works (`gm_commands/award.cpp`): the amount is **added** to the character's `EoM-Award`
data bucket, a message is posted to the Discord webhook `admin`, and cross-zone signal **666**
is sent to the character. `plugin::UpdateEoMAward` (`NMS_custom_events.pl`) consumes the
bucket on signal 666 and on every zone-in, credits alt currency 6 (account-wide when
`Custom:EnableAccountAltCurrency` is on) and deletes the bucket. Nothing is written to
`account_alt_currency` by the command itself — see CODEBASE.md §3.3.

---

### `#ban [Character Name] [Reason]`
Default status: **GMLeadAdmin (150)**  
Ban an account by character name.

---

### `#bot`
Default status: **Player (0)**  
Bot command tree; `#bot help` or `^help` lists subcommands. Only registered when
`Bots:Enabled` is true.

---

### `#bugs`
Default status: **QuestTroupe (80)**  
Manage player bug reports.

| Subcommand | Description |
|---|---|
| `close [Bug ID]` | Close a bug report |
| `delete [Bug ID]` | Delete a bug report |
| `review [Bug ID] [Review]` | Add a review to a bug report |
| `search [Search Criteria]` | Search bug reports |
| `view [Bug ID]` | View a bug report |

---

### `#camerashake [Duration (ms)] [Intensity (1-10)]`
Default status: **QuestTroupe (80)**  
Shake the camera globally for all players.

---

### `#castspell [Spell ID] [Instant]`
Default status: **Guide (50)**  
Cast a spell. Instant defaults to 1 (true). Example: `#castspell 1 1`

---

### `#castspellnms [Spell ID|Spell Name]`
Default status: **5 (raw literal, no AccountStatus constant)**  
**NMS.** Cast a spell you have scribed without memorising it, out of combat only. Name may be
quoted. Refuses bard songs, detrimental spells, spells above your level, and anything while
the rest timer is running. Targets your current target, or you for self-only spells. The
in-code help advertises it as `/cast`, i.e. it is meant to be bound to a client alias.

The status `5` is a bare number in `command.cpp:106` — it sits between Player (0) and Steward
(10), so effectively only accounts with an explicit non-zero status get it. Set the real value
in `command_settings`.

---

### `#chat [Channel ID] [Message]`
Default status: **GMMgmt (200)**  
Send a channel message to all zones.

---

### `#clearxtargets`
Default status: **Player (0)**  
Clear your extended targets list.

---

### `#copycharacter [Source Name] [Dest Name] [Dest Account]`
Default status: **GMImpossible (250)**  
Copy a character to a destination account.

---

### `#corpse`
Default status: **Guide (50)**  
Manipulate corpses.

| Subcommand | Description |
|---|---|
| `charid [Character ID]` | Change a player corpse's owner |
| `delete` | Delete targeted corpse |
| `deletenpccorpses` | Delete all NPC corpses |
| `deleteplayercorpses` | Delete all player corpses |
| `depop [Bury]` | Depop targeted corpse (Bury=0 skips burying) |
| `depopall [Bury]` | Depop all of a player's corpses |
| `inspectloot` | Inspect loot on a corpse |
| `listnpc` | List all NPC corpses |
| `listplayer` | List all player corpses |
| `lock` | Lock a corpse (GM-only loot) |
| `moveallgraveyard` | Move all player corpses to the zone graveyard |
| `removecash` | Remove cash from a corpse |
| `unlock` | Unlock a corpse |

---

### `#corpsefix`
Default status: **Player (0)**  
Attempt to bring nearby corpses up from beneath the ground.

---

### `#countitem [Item ID]`
Default status: **GMLeadAdmin (150)**  
Count how many of a specific item are in your or your target's inventory.

---

### `#damage [Amount]`
Default status: **GMAdmin (100)**  
Deal damage to yourself or your target.

---

### `#databuckets`
Default status: **QuestTroupe (80)**  
View and manage data buckets. Character ID, NPC ID, and Bot ID are optional filters.

| Subcommand | Description |
|---|---|
| `delete [Key] [Char ID] [NPC ID] [Bot ID]` | Delete matching data buckets |
| `edit [Key] [Char ID] [NPC ID] [Bot ID] [Value] [Expires]` | Edit a data bucket |
| `view [Partial Key] [Char ID] [NPC ID] [Bot ID]` | View matching data buckets |

---

### `#dbspawn2 [Spawngroup ID] [Respawn] [Variance] [Condition ID] [Condition Min]`
Default status: **GMAdmin (100)**  
Spawn an NPC from a `spawn2` table row. Respawn and Variance are in seconds. Condition is optional.

---

### `#delacct [Account ID|Account Name]`
Default status: **GMLeadAdmin (150)**  
Delete an account by ID or name.

---

### `#delpetition [Petition Number]`
Default status: **ApprenticeGuide (20)**  
Delete a petition by number.

---

### `#depop [Start Spawn Timer]`
Default status: **Guide (50)**  
Depop your targeted NPC, optionally starting its spawn timer. Example: `#depop 1`

---

### `#depopzone [Start Spawn Timers]`
Default status: **GMAdmin (100)**  
Depop the entire zone. Pass `1` to also start spawn timers.

---

### `#devtools [menu|window] [0|1]`
Default status: **GMMgmt (200)**  
Manage Developer Tools. No arguments opens the dev tools menu. Pass `menu` or `window` with `0` or `1` to toggle.

---

### `#disablerecipe [Recipe ID]`
Default status: **QuestTroupe (80)**  
Disable a crafting recipe.

---

### `#disarmtrap`
Default status: **QuestTroupe (80)**  
Disarm an LDoN trap on your target. Chat-command stand-in for the client action, which does not work on newer clients.

---

### `#doanim [Animation ID|Name] [Speed]`
Default status: **Guide (50)**  
Play an animation on yourself or your target. Speed is optional. Example: `#doanim 3 10`

---

### `#door`
Default status: **QuestTroupe (80)**  
Interactive door editing. Use with no arguments for the help menu.

---

### `#dye [Slot|help] [Red] [Green] [Blue]`
Default status: **ApprenticeGuide (20)**  
Dye an armor slot. Bypasses darkness limits. Example: `#dye chest 255 0 0`

---

### `#dz`
Default status: **QuestTroupe (80)**  
Manage expeditions and dynamic zone instances.

| Subcommand | Description |
|---|---|
| `cache reload` | Reload all dynamic zones from database |
| `destroy [ID]` | Destroy a dynamic zone by ID |
| `list` | List all dynamic zones in zone cache |
| `listdb [all]` | List dynamic zones from database; `all` includes expired |
| `lockouts` | Manage lockouts |

---

### `#dzkickplayers`
Default status: **Player (0)**  
Remove all players from your current expedition. Stand-in for `/kickplayers` on pre-RoF clients.

---

### `#editmassrespawn [Name Search] [Seconds]`
Default status: **GMAdmin (100)**  
Zone-wide NPC respawn timer edit by name search.

---

### `#emote [Name|World|Zone] [Type] [Message]`
Default status: **QuestTroupe (80)**  
Send an emote message. Separate multiple messages with `^`.

---

### `#emptyinventory`
Default status: **GMImpossible (250)**  
Clear your or your target's entire inventory (equipment, general, bank, shared bank).

---

### `#enablerecipe [Recipe ID]`
Default status: **QuestTroupe (80)**  
Enable a crafting recipe.

---

### `#entityvariable`
Default status: **GMAdmin (100)**  
Manage entity variables on yourself or your target. Use quotes for names/values with spaces.

| Subcommand | Description |
|---|---|
| `clear` | Clear all entity variables |
| `delete [Variable Name]` | Delete a specific entity variable |
| `set [Variable Name] [Value]` | Set an entity variable |
| `view [Variable Name]` | View an entity variable |

Example: `#entityvariable set "my_var" "hello world"`

---

### `#evolve`
Default status: **Steward (10)**  
Evolving item manipulation. Use `#evolve help` for details.

---

### `#exptoggle [Toggle]`
Default status: **QuestTroupe (80)**  
Toggle experience gain for yourself or your target.

---

### `#fabled`
Default status: **GMMgmt (200)**  
**NMS.** Manage the Fabled season (design: `Release-NMS-Deploy/FABLED-ENCOUNTERS.md` §6). Every write
updates the single `fabled_season` row and is pushed through world to all zones; no reload or
restart is needed. Named NPCs on the `fabled_npcs` roster that spawn while the season is on have a
chance to come up as `The Fabled <name>` at their Fabled level with Legendary-tier loot.

| Subcommand | Description |
|---|---|
| `on [scope] [duration] [chance]` | Start a season now. All three tokens are optional and detected by shape |
| `schedule [scope] [YYYY-MM-DD] [YYYY-MM-DD] [chance]` | Start and end at server-local midnight; the start day is included, the end day is not. May be in the future |
| `off` | End the season everywhere now (`active = 0`, `end_epoch = now`). Fableds already up stay until killed or their spawn point cycles |
| `status` | Show the season row (state, scope, chance, loot tier, window, time remaining, who set it) and this zone's cached view: enabled, in window, eligible count vs roster size |
| `force` | Promote the targeted NPC now, ignoring season and chance. The NPC must be on this zone's eligible roster |

Token grammar:

| Token | Values |
|---|---|
| scope | `all` (default), `era:Classic`, `era:RoK`, `era:SoV`, `era:SoL`, `era:PoP`, `zone:<shortname>` |
| duration | `<n>m`, `<n>h`, `<n>d`, `<n>w` (default: open-ended, ends only with `#fabled off`) |
| chance | `1`–`100` (default: rule `Custom:FabledDefaultChance`, read only when the command runs) |

Examples: `#fabled on` · `#fabled on era:RoK 2w 25` · `#fabled schedule zone:permafrost 2026-12-20 2027-01-03` · `#fabled off`.

Edit the roster (`fabled_npcs`, content DB) and then `#reload fabled [global]` to re-read it without a restart.

---

### `#faction`
Default status: **QuestTroupe (80)**  
Manage faction.

| Subcommand | Description |
|---|---|
| `review [Search|All]` | Review a targeted player's faction hits |
| `reset [Faction ID]` | Reset a targeted player's faction to base value |
| `view` | Display targeted NPC's primary faction |

---

### `#factionassociation [Faction ID] [Amount]`
Default status: **GMLeadAdmin (150)**  
Trigger faction hits via faction association.

---

### `#feature`
Default status: **QuestTroupe (80)**  
Temporarily change appearance features on yourself or your target. Same as `#size` for size changes.

---

### `#find`
Default status: **Guide (50)**  
Search for game data. All subcommands accept a search criteria string.

| Subcommand | Aliases |
|---|---|
| `#find aa` | |
| `#find account` | `#findaccount` |
| `#find body_type` | `#findbodytype` |
| `#find bug_category` | `#findbugcategory` |
| `#find character` | `#findcharacter` |
| `#find class` | `#findclass` |
| `#find currency` | `#findcurrency` |
| `#find deity` | `#finddeity` |
| `#find emote` | `#findemote` |
| `#find faction` | `#findfaction` |
| `#find item [Search]` | `#fi`, `#finditem` |
| `#find language` | `#findlanguage` |
| `#find npctype [Search]` | `#fn`, `#findnpc`, `#findnpctype` |
| `#find race` | `#findrace` |
| `#find recipe` | `#findrecipe` |
| `#find skill` | `#findskill` |
| `#find special_ability` | `#fsa`, `#findspecialability` |
| `#find spell [Search]` | `#fs`, `#findspell` |
| `#find task` | `#findtask` |
| `#find zone [Search]` | `#fz`, `#findzone` |

---

### `#fish`
Default status: **QuestTroupe (80)**  
Forage a fish item.

---

### `#fixmob [stat] [next|prev]`
Default status: **QuestTroupe (80)**  
Cycle through appearance options on your target. Stats: `race`, `gender`, `texture`, `helm`, `face`, `hair`, `haircolor`, `beard`, `beardcolor`, `heritage`, `tattoo`, `detail`.

---

### `#flagedit`
Default status: **GMAdmin (100)**  
Edit zone flags on your target. Use `#flagedit help` for details.

---

### `#fleeinfo`
Default status: **QuestTroupe (80)**  
Display info about whether a targeted NPC will flee, using you as the top hate entry.

---

### `#forage`
Default status: **QuestTroupe (80)**  
Forage an item.

---

### `#gearup`
Default status: **GMMgmt (200)**  
Developer tool to quickly equip yourself or your target.

---

### `#giveitem [Item ID] [Charges]`
Default status: **GMMgmt (200)**  
Summon an item onto your target's cursor. Charges optional.

---

### `#givemoney [Platinum] [Gold] [Silver] [Copper]`
Default status: **GMMgmt (200)**  
Give money to yourself or your player target.

---

### `#gmzone [Zone ID|Short Name] [Version] [Instance Identifier]`
Default status: **GMAdmin (100)**  
Zone to a private GM instance. Version defaults to `0`, identifier defaults to `gmzone`.

---

### `#goto [Player Name]` or `#goto [X] [Y] [Z] [H]`
Default status: **Steward (10)**  
Teleport to a player or coordinates.

---

### `#grantaa [Level]`
Default status: **GMMgmt (200)**  
Grant all available AA points up to the specified level. Omit level to grant all AAs.

---

### `#grid`
Default status: **GMAreas (170)**  
Manage NPC wandering grids in the current zone.

| Subcommand | Description |
|---|---|
| `add [Grid ID] [Wander Type] [Pause Type]` | Create a new grid |
| `delete [Grid ID]` | Delete a grid |
| `hide` | Despawn visual node markers for targeted NPC's grid |
| `max` | Show the highest grid ID used in this zone |
| `show` | Spawn visual node markers for targeted NPC's grid |

---

### `#guild`
Default status: **Steward (10)**  
Guild management.

| Subcommand | Description |
|---|---|
| `create [Char ID|Name] [Guild Name]` | Create a guild |
| `delete [Guild ID]` | Delete a guild |
| `details [Guild ID]` | Show guild details |
| `info [Guild ID]` | Show guild info |
| `list` | List all guilds |
| `rename [Guild ID] [New Name]` | Rename a guild |
| `search [Search Criteria]` | Search guilds |
| `set [Char ID|Name] [Guild ID]` | Set a character's guild (0 = guildless) |
| `setleader [Guild ID] [Char ID|Name]` | Set a guild's leader |
| `setrank [Char ID|Name] [Rank]` | Set a character's guild rank |
| `status [Char ID|Name]` | Show a character's guild status |

---

### `#help [Search]`
Default status: **Player (0)**  
List the commands available at your status, with descriptions. Optional partial-name filter.

---

### `#hotfix [Name]`
Default status: **GMImpossible (250)**  
Reload shared memory into a named hotfix segment and apply it everywhere — `#load_shared_memory` followed by `#apply_shared_memory`. This is how you push item/spell changes without restarting (see CODEBASE.md §3.4: item changes need `shared_memory` re-run).

---

### `#hp`
Default status: **Player (0)**  
Refresh your HP bar from the server.

---

### `#illusionblock`
Default status: **Guide (50)**  
Toggle whether illusion effects cast by other players/bots land on you.

---

### `#instance`
Default status: **GMMgmt (200)**  
Manage zone instances.

| Subcommand | Description |
|---|---|
| `add [Instance ID] [Name]` | Add a character to an instance |
| `create [Zone ID|Short Name] [Version] [Duration]` | Create a new instance |
| `destroy [Instance ID]` | Destroy an instance |
| `list [Name]` | List instances for a character |
| `remove [Instance ID] [Name]` | Remove a character from an instance |

---

### `#interrogateinv`
Default status: **Player (0)**  
Inspect your inventory. Use `#interrogateinv help` for options.

---

### `#interrupt [Message ID] [Color]`
Default status: **Guide (50)**  
Interrupt your current cast. Arguments are optional.

---

### `#invsnapshot`
Default status: **QuestTroupe (80)**  
Manipulate inventory snapshots for your current target.

---

### `#ipban [IP]`
Default status: **GMMgmt (200)**  
Ban an IP address.

---

### `#kick [Character Name]`
Default status: **GMLeadAdmin (150)**  
Disconnect a player by name.

---

### `#kill`
Default status: **GMAdmin (100)**  
Kill your target.

---

### `#killallnpcs [NPC Name]`
Default status: **GMMgmt (200)**  
Kill all NPCs by name search. Leave blank to kill all attackable NPCs.

---

### `#list [npcs|players|corpses|doors|objects] [Search]`
Default status: **ApprenticeGuide (20)**  
Search entities in the zone.

---

### `#load_shared_memory [Name]`
Default status: **GMImpossible (250)**  
Rebuild shared memory into a segment with the given name, without applying it.

---

### `#loc`
Default status: **Player (0)**  
Print your or your target's current location and heading.

---

### `#logs`
Default status: **GMImpossible (250)**  
Manage server logging.

| Subcommand | Description |
|---|---|
| `list [Start Category ID]` | Show up to 50 log categories (starting at ID if specified) |
| `reload` | Reload log settings in world and all zone processes from database |
| `set [console|file|gmsay] [Category ID] [Level (1-3)]` | Set log output for the zone lifetime |

---

### `#lootsim [NPC Type ID] [Loottable ID] [Iterations]`
Default status: **GMImpossible (250)**  
Run the real loot roll N times for a loottable and report drop statistics. Useful for checking `Custom:Tier1ItemDropRate` / `Tier2ItemDropRate` outcomes.

---

### `#makepet [Pet Name]`
Default status: **Guide (50)**  
Create a pet.

---

### `#memspell [Spell ID] [Gem]`
Default status: **Guide (50)**  
Memorize a spell into the specified gem slot for yourself or your target.

---

### `#merchantshop`
Default status: **GMAdmin (100)**  
Open or close your targeted NPC merchant's shop.

---

### `#modifynpcstat [Stat] [Value]`
Default status: **GMLeadAdmin (150)**  
Temporarily modify a stat on a targeted NPC.

---

### `#movechar [Char ID|Name] [Zone ID|Short Name]`
Default status: **Guide (50)**  
Move an offline character to the specified zone.

---

### `#movement`
Default status: **GMMgmt (200)**  
Movement utilities.

| Subcommand | Description |
|---|---|
| `clear` | Clear movement stats |
| `packet [X] [Y] [Z] [Heading] [Animation]` | Send a movement command packet |
| `rotate` | Rotate target to face you |
| `run` | Force target to run |
| `stats` | Show movement stats |
| `stop` | Stop target movement |
| `walk` | Force target to walk |

---

### `#myskills`
Default status: **Player (0)**  
Show your current skill levels.

---

### `#mysql [help|query] [SQL]`
Default status: **GMImpossible (250)**  
Run SQL from in-game against the server database. `#mysql help` for options.

---

### `#mystats`
Default status: **Guide (50)**  
Show stats for yourself or your pet.

---

### `#npccast [Target Name|Entity ID] [Spell ID]`
Default status: **QuestTroupe (80)**  
Make your targeted NPC cast a spell on the specified target.

---

### `#npcedit [Subcommand] [Value]`
Default status: **GMAdmin (100)**  
Edit NPC data on the targeted NPC. Changes are written to the database.

| Subcommand | Description |
|---|---|
| `ac [AC]` | Armor class |
| `accuracy [Value]` | Accuracy |
| `agi [Value]` | Agility |
| `aggroradius [Radius]` | Aggro radius |
| `alt_currency_id [ID]` | Alternate currency ID |
| `always_aggro [0\|1]` | Always aggro flag |
| `ammoidfile [ID]` | Ammo ID file |
| `armortint_id [ID]` | Armor tint ID |
| `armtexture [Texture]` | Arm texture |
| `assistradius [Radius]` | Assist radius |
| `atk [Value]` | Attack |
| `attackcount [Count]` | Attack count |
| `attackdelay [Delay]` | Attack delay |
| `attackspeed [Speed]` | Attack speed modifier |
| `avoidance [Value]` | Avoidance |
| `bodytype [ID]` | Body type |
| `bracertexture [Texture]` | Bracer texture |
| `cha [Value]` | Charisma |
| `charm_ac [AC]` | AC while charmed |
| `charm_accuracy_rating [Value]` | Accuracy while charmed |
| `charm_atk [Value]` | Attack while charmed |
| `charm_attack_delay [Value]` | Attack delay while charmed |
| `charm_avoidance_rating [Value]` | Avoidance while charmed |
| `charm_max_dmg [Value]` | Max damage while charmed |
| `charm_min_dmg [Value]` | Min damage while charmed |
| `class [Class ID]` | Class |
| `color [R] [G] [B]` | Armor tint (RGB) |
| `corrup [Value]` | Corruption resistance |
| `cr [Value]` | Cold resistance |
| `damage [Min] [Max]` | Min/max damage |
| `dex [Value]` | Dexterity |
| `dr [Value]` | Disease resistance |
| `emoteid [ID]` | Emote ID |
| `exp_mod [%]` | Experience modifier |
| `faction [ID]` | Faction ID |
| `faction_amount [Value]` | Faction amount |
| `faction_amount [Value]` | Faction amount |
| `featuresave` | Save current facial features to DB |
| `feettexture [Texture]` | Feet texture |
| `findable [0\|1]` | Findable flag |
| `flymode [0-5]` | Fly mode (0=Ground, 1=Flying, 2=Levitating, 3=Water, 4=Floating, 5=Levitating while running) |
| `fr [Value]` | Fire resistance |
| `gender [ID]` | Gender |
| `handtexture [Texture]` | Hand texture |
| `healscale [%]` | Heal scaling rate |
| `helmtexture [Texture]` | Helmet texture |
| `herosforgemodel [Model]` | Hero's Forge model |
| `hp [Value]` | Max HP |
| `hp_regen_per_second [Value]` | HP regen per second |
| `hpregen [Value]` | HP regen per tick |
| `int [Value]` | Intelligence |
| `is_parcel_merchant [0\|1]` | Parcel merchant flag |
| `keeps_sold_items [0\|1]` | Keeps sold items flag |
| `lastname [Name]` | Last name |
| `level [Level]` | Level |
| `legtexture [Texture]` | Leg texture |
| `loottable [ID]` | Loottable ID |
| `mana [Value]` | Max mana |
| `manaregen [Value]` | Mana regen per tick |
| `maxlevel [Level]` | Maximum level |
| `meleetype [Primary] [Secondary]` | Melee skill types |
| `merchantid [ID]` | Merchant ID |
| `model [Race ID]` | Race model |
| `mr [Value]` | Magic resistance |
| `name [Name]` | NPC name |
| `no_target [0\|1]` | No target hotkey flag |
| `npcaggro [0\|1]` | NPC aggro flag |
| `npc_spells_effects_id [ID]` | Spell effects ID |
| `phr [Value]` | Physical resistance |
| `pr [Value]` | Poison resistance |
| `qglobal [0\|1]` | Quest global flag |
| `raidtarget [0\|1]` | Raid target flag |
| `rangedtype [Type]` | Ranged skill type |
| `rarespawn [0\|1]` | Rare spawn flag |
| `respawntime [Seconds]` | Respawn timer (spawn2 table) |
| `runspeed [Speed]` | Run speed |
| `scalerate [%]` | Scale rate (50=50%, 100=100%, 200=200%) |
| `seehide [0\|1]` | See hide flag |
| `seeinvis [0\|1]` | See invisible flag |
| `seeinvisundead [0\|1]` | See invisible vs. undead flag |
| `seeimprovedhide [0\|1]` | See improved hide flag |
| `set_grid [Grid ID]` | Assign a grid to this NPC's spawn entry |
| `setanimation [Animation ID]` | Spawn animation (spawn2 table) |
| `size [Size]` | Size |
| `skip_global_loot [0\|1]` | Skip global loot flag |
| `slow_mitigation [Value]` | Slow mitigation |
| `spawn_limit [Limit]` | Spawn limit counter |
| `special_abilities [Value]` | Special abilities string |
| `special_attacks [Value]` | Special attacks |
| `spell [List ID]` | Spell list ID |
| `spellscale [%]` | Spell scaling rate |
| `sta [Value]` | Stamina |
| `str [Value]` | Strength |
| `stuck_behavior [0-3]` | Stuck behavior (0=Run to Target, 1=Warp to Target, 2=No Action, 3=Evade Combat) |
| `texture [Texture]` | Texture |
| `trackable [0\|1]` | Trackable flag |
| `trap_template [ID]` | Trap template ID |
| `untargetable [0\|1]` | Untargetable flag |
| `version [Version]` | NPC version |
| `walkspeed [Speed]` | Walk speed |
| `weapon [Primary] [Secondary]` | Primary/secondary weapon model |
| `wis [Value]` | Wisdom |
| `show_name [0\|1]` | Show name flag |

---

### `#npceditmass [Name Search] [Column] [Value]`
Default status: **GMAdmin (100)**  
Zone-wide NPC data edit matching a name search.

---

### `#npcemote [Message]`
Default status: **GMLeadAdmin (150)**  
Make your targeted NPC emote a message.

---

### `#npcloot`
Default status: **QuestTroupe (80)**  
Manipulate loot an NPC is carrying. Use `#npcloot help` for details.

---

### `#npcsay [Message]`
Default status: **GMLeadAdmin (150)**  
Make your targeted NPC say a message.

---

### `#npcshout [Message]`
Default status: **GMLeadAdmin (150)**  
Make your targeted NPC shout a message.

---

### `#npcspawn`
Default status: **GMAreas (170)**  
Manage NPC spawns in the database.

| Subcommand | Description |
|---|---|
| `add [Respawn Time]` | Create a new spawn2/spawngroup entry for targeted NPC |
| `clone [Respawn Time]` | Copy the targeted NPC's spawngroup; create a spawn2 at your location |
| `create [Respawn Time]` | Create a new NPC type copied from targeted NPC, with new spawn2/spawngroup |
| `delete` | Delete spawn2, spawngroup, spawnentry, and npc_types for targeted NPC |
| `remove [Remove Spawngroups]` | Delete spawn2 row; also removes spawngroup/spawnentry if > 0 |
| `update` | Update NPC appearance in database |

---

### `#npctypespawn [NPC ID] [Faction ID]`
Default status: **Steward (10)**  
Spawn an NPC by type ID from the database. Faction ID is optional.

---

### `#nudge [x=float] [y=float] [z=float] [h=float]`
Default status: **QuestTroupe (80)**  
Nudge your target by specific amounts. Use named arguments in any combination. Example: `#nudge x=5.0 z=1.0`

---

### `#nukebuffs [Beneficial|Detrimental]`
Default status: **Guide (50)**  
Strip all buffs from yourself or your target. No argument removes all buffs.

---

### `#nukeitem [Item ID]`
Default status: **GMLeadAdmin (150)**  
Remove a specific item from your or your target's inventory.

---

### `#object`
Default status: **GMAdmin (100)**  
Manage static and tradeskill objects. Subcommands: `List`, `Add`, `Edit`, `Move`, `Rotate`, `Copy`, `Save`, `Undo`, `Delete`. Use `#object` with no arguments for the help menu.

---

### `#opcode`
Default status: **GMMgmt (200)**  
Alias of `#reload opcodes`.

---

### `#parcels`
Default status: **GMMgmt (200)**  
View and edit the parcel system (requires parcels enabled in rules).

---

### `#path`
Default status: **GMMgmt (200)**  
View and edit zone pathing.

---

### `#peqzone [Zone ID|Short Name]`
Default status: **Player (0)**  
Teleport to a zone if you meet requirements (player-accessible).

---

### `#petcmd [verb...] [target...]`
Default status: **Player (0)**  
**NMS.** Issue pet commands to a subset of your pets (multi-pet system). Verbs and targets can
be given in any order.

| Kind | Tokens |
|---|---|
| Simple verbs | `attack`, `qattack`, `follow`/`followme`, `guard`/`guardhere`, `sit`, `stop`/`freeze`, `back`/`backoff`, `leave`/`dismiss`/`getlost`, `health`/`hp`/`stats`/`inventory`, `leader`/`master`, `feign`/`fd`/`playdead` |
| Toggles (optional `on`/`off`) | `taunt`, `hold`, `ghold`, `spellhold`/`nocast`, `focus`, `regroup`, `assist`/`assistme` |
| Targets | `all` (default), `swarm`, or a class token: `mag`, `bst`, `nec`, `enc`, `shm`, `dru`, `brd`, `shd`/`sk`, `war`, `clr`, `pal`, `rng`, `mnk`, `rog`, `wiz`, `ber` (long forms accepted) |

Pets are matched by the class that summoned them (`NPC::GetPetOriginClass()`). Swarm pets
ignore `follow`, `guard`, `sit`, `health`, `feign`, `regroup`, `spellhold`, `taunt`.
Example: `#petcmd attack nec mag`, `#petcmd hold off all`.

---

### `#petitems`
Default status: **ApprenticeGuide (20)**  
List the items your pet is carrying.

---

### `#petname [New Name]`
Default status: **GMAdmin (100)**  
Temporarily rename your pet. Leave blank to restore original name.

---

### `#picklock`
Default status: **Player (0)**  
Pick an LDoN lock on your target. Chat-command stand-in for the client action on newer clients.

---

### `#profanity`
Default status: **GMLeadAdmin (150)**  
Manage the censored language list.

---

### `#push [Back Push] [Up Push]`
Default status: **GMLeadAdmin (150)**  
Apply spell-style push to your target.

---

### `#raidloot [All|GroupLeader|RaidLeader|Selected]`
Default status: **Player (0)**  
Set the raid loot type, if you have permission in the raid.

---

### `#randomfeatures`
Default status: **QuestTroupe (80)**  
Temporarily randomize facial features on your target.

---

### `#refreshgroup`
Default status: **Player (0)**  
Refresh your group data from the server.

---

### `#reload [Type] [global]`
Default status: **GMMgmt (200)**  
Reload server data. Without `global` the reload is local to this zone; with it, world pushes it
to every zone. `#reload` alone prints the menu. Types (`common/server_reload_types.h`):

`aa_data`, `alternate_currencies`, `base_data`, `blocked_spells`, `commands`, `content_flags`,
`data_buckets_cache`, `doors`, `dz_templates`, `fabled`, `factions`, `global_buffs`, `ground_spawns`,
`level_exp_mods`, `logs`, `loot`, `maps`, `merchants`, `npc_emotes`, `npc_spells`, `objects`,
`opcodes`, `perl_event_export_settings`, `quest`, `quests_with_timer`, `rules`, `skill_caps`,
`static_zone_data`, `tasks`, `titles`, `traps`, `variables`, `veteran_rewards`, `waypoints`,
`world_repop`, `world_repop_timers`, `zone_data`, `zone_points`.

**NMS:** `fabled` re-reads the `fabled_npcs` roster (content DB) into the zone's Fabled
cache — the season state itself never needs a reload, `#fabled` pushes it. Note it is `quest`,
singular. `quests_with_timer` also resets timer events. Aliases: `#rq` →
`#reload quest`, `#rl` → `#reload logs`, `#opcode` → `#reload opcodes`. Items and spells are
**not** reloaded here — they live in shared memory; use `#hotfix`.

---

### `#removeitem [Item ID] [Amount]`
Default status: **GMAdmin (100)**  
Remove an item by ID from your or your target's inventory. Amount defaults to `1`.

---

### `#repop [Force]`
Default status: **GMAdmin (100)**  
Repop the zone. Pass `1` to force repop.

---

### `#resetaa [aa|leadership]`
Default status: **GMMgmt (200)**  
Reset a player's AAs or Leadership AAs and refund to unspent.

---

### `#resetaa_timer [All|Timer ID]`
Default status: **GMMgmt (200)**  
Reset AA cooldown timers for yourself or your target.

---

### `#resetdisc_timer [All|Timer ID]`
Default status: **GMMgmt (200)**  
Reset discipline timers.

---

### `#revoke [Character Name] [0|1]`
Default status: **GMMgmt (200)**  
Revoke or unrevoke a player's OOC chat access. `1` = revoke, `0` = unrevoke.

---

### `#rl`
Default status: **GMMgmt (200)**  
Alias of `#reload logs`.

---

### `#roambox`
Default status: **GMMgmt (200)**  
Manage roambox on a targeted NPC.

| Subcommand | Description |
|---|---|
| `remove` | Remove the NPC's roambox |
| `set [Box Size] [Delay]` | Set a roambox with the given size and delay |

---

### `#rq`
Default status: **GMMgmt (200)**  
Alias of `#reload quest`. Use this after editing any `.pl`/`.lua` or plugin.

---

### `#rules`
Default status: **GMImpossible (250)**  
Manage server rules.

| Subcommand | Description |
|---|---|
| `current` | Show the currently active ruleset name |
| `get [Rule]` | Get a rule's current local value |
| `list [Category]` | List all rules in a category (or all) |
| `listsets` | List available rule sets |
| `load [Ruleset Name]` | Load a ruleset in this zone only |
| `reload` | Reload the selected ruleset in this zone |
| `reset` | Reset all rules to default values |
| `set [Rule] [Value]` | Set a rule locally |
| `setdb [Rule] [Value]` | Set a rule locally and in the database |
| `store [Ruleset Name]` | Store the running ruleset under a name |
| `switch [Ruleset Name]` | Change the active ruleset and load it |
| `values [Category]` | List values of all rules in a category |

---

### `#save`
Default status: **Guide (50)**  
Force your player or player corpse target to save to the database.

---

### `#scale [dynamic|static]`
Default status: **GMLeadAdmin (150)**  
Scale NPC stats. Target an NPC to scale it, or pass a name search for zone-wide scaling. Use `all` for every NPC in the zone.

---

### `#scribespell [Spell ID]`
Default status: **GMCoder (180)**  
Scribe a spell into your or your target's spellbook.

---

### `#scribespells [Max Level] [Min Level]`
Default status: **GMLeadAdmin (150)**  
Scribe all usable spells up to the specified level.

---

### `#sendzonespawns`
Default status: **GMLeadAdmin (150)**  
Refresh the spawn list for all clients in the zone.

---

### `#sensetrap`
Default status: **Player (0)**  
Sense LDoN traps nearby. Chat-command stand-in for the client action on newer clients.

---

### `#serverrules`
Default status: **Player (0)**  
Display the server rules (player-accessible).

---

### `#set`
Default status: **Guide (50)**  
Set player/server properties. Individual subcommands are gated by `command_subsettings`.

| Subcommand | Aliases | Description |
|---|---|---|
| `aa_exp [aa\|group\|raid] [Amount]` | `#setaaxp` | Set AA experience |
| `aa_points [aa\|group\|raid] [Amount]` | `#setaapts` | Set AA points |
| `adventure_points [Theme ID] [Amount]` | | Set adventure points |
| `alternate_currency [Currency ID] [Amount]` | `#setaltcurrency` | Set alternate currency |
| `animation [Animation ID]` | `#setanim` | Set animation |
| `anon [Anonymous Flag]` | `#setanon` | Set anonymous flag |
| `auto_login [0\|1]` | `#setautologin` | Toggle auto-login |
| `bind_point` | `#setbind` | Set bind point to current location |
| `class_permanent [Class ID]` | `#permaclass` | Permanently set class |
| `crystals [ebon\|radiant] [Amount]` | `#setcrystals` | Set crystal currency |
| `date [Year] [Month] [Day] [Hour] [Minute]` | `#date` | Set in-game date/time |
| `endurance [Amount]` | `#setendurance` | Set endurance |
| `endurance_full` | `#endurance` | Fill endurance |
| `exp [aa\|exp] [Amount]` | `#setxp` | Set experience |
| `flymode [Flymode ID]` | `#flymode` | Set fly mode (0-5) |
| `frozen [on\|off]` | `#freeze`, `#unfreeze` | Freeze/unfreeze target |
| `gender [ID]` | `#gender` | Set gender |
| `gender_permanent [ID]` | `#permagender` | Permanently set gender |
| `gm [on\|off]` | `#gm` | Toggle GM mode |
| `gm_speed [on\|off]` | `#gmspeed` | Toggle GM speed |
| `gm_status [Status] [Account]` | `#flag` | Set account GM status |
| `god_mode [on\|off]` | `#godmode` | Toggle god mode |
| `haste [%]` | `#haste` | Set haste percentage |
| `hero_model [Model] [Slot]` | `#heromodel` | Set hero model |
| `hide_me [on\|off]` | `#hideme` | Toggle visibility to players |
| `hp [Amount]` | `#sethp` | Set HP |
| `hp_full` | `#heal` | Fill HP |
| `invulnerable` | `#invul` | Toggle invulnerability |
| `language [ID] [Level]` | `#setlanguage` | Set language skill |
| `last_name [Name]` | `#lastname` | Set last name |
| `level [Level]` | `#level` | Set level |
| `loginserver_info [Email] [Pass]` | `#setlsinfo` | Set login server credentials |
| `mana [Amount]` | `#setmana` | Set mana |
| `mana_full` | `#mana` | Fill mana |
| `motd` | `#motd` | Set message of the day |
| `name` | `#name` | Set name |
| `ooc_mute` | `#oocmute` | Mute OOC for a player |
| `password [Account] [Pass]` | `#setpass` | Set account password |
| `pvp [on\|off]` | `#pvp` | Toggle PvP |
| `pvp_points [Amount]` | `#setpvppoints` | Set PvP points |
| `race [Race ID]` | `#race` | Set race |
| `race_permanent [Race ID]` | `#permarace` | Permanently set race |
| `server_locked [on\|off]` | `#lock`, `#unlock`, `#serverlock` | Lock/unlock the server |
| `skill [Skill ID] [Level]` | `#setskill` | Set a skill level |
| `skill_all [Level]` | `#setskillall` | Set all skill levels |
| `skill_all_max` | `#maxskills` | Max all skills |
| `start_zone` | `#setstartzone` | Set start zone |
| `temporary_name [Name]` | `#tempname` | Temporarily rename target |
| `texture [Texture ID]` | `#texture` | Set texture |
| `time [Hour] [Minute]` | `#time` | Set in-game time |
| `time_zone [Hour] [Minute]` | `#timezone` | Set time zone offset |
| `title [Title]` | `#title` | Set title |
| `title_suffix [Suffix]` | `#titlesuffix` | Set title suffix |
| `weather [0-3]` | `#weather` | Set weather (0=None, 1=Rain, 2=Snow, 3=Reset) |
| `zone [option]` | `#zclip`, `#zcolor`, `#zheader`, `#zonelock`, `#zsafecoords`, `#zsky`, `#zunderworld` | Zone header options |

---

### `#show`
Default status: **Guide (50)**  
Display information. Individual subcommands are gated by `command_subsettings`; legacy aliases listed.

| Subcommand | Alias(es) | Description |
|---|---|---|
| `aas` | `#showaas` | Show AA list |
| `aa_points` | `#showaapoints`, `#showaapts` | Show AA points |
| `aggro [Distance] [-v]` | `#aggro` | Show aggro info; `-v` for verbose faction info |
| `auto_login` | `#showautologin` | Show auto-login status |
| `buffs` | `#showbuffs` | Show buffs on target |
| `buried_corpse_count` | `#getplayerburiedcorpsecount` | Show buried corpse count |
| `client_version_summary` | `#cvs` | Show client version summary |
| `content_flags` | `#showcontentflags` | Show content flags |
| `currencies` | `#viewcurrencies` | Show currency balances |
| `distance` | `#distance` | Show distance to target |
| `emotes` | `#emoteview` | List emotes |
| `field_of_view` | `#fov` | Check field of view to target |
| `flags` | `#flags` | Show zone flags |
| `group_info` | `#ginfo` | Show group information |
| `hatelist` | `#hatelist` | Show NPC hate list |
| `inventory` | `#peekinv` | Inspect target's inventory |
| `ip_lookup` | `#iplookup` | Look up a player's IP |
| `line_of_sight` | `#checklos` | Check line of sight to target |
| `network` | `#network` | Show network info |
| `network_stats` | `#netstats` | Show network statistics |
| `npc_global_loot` | `#shownpcgloballoot` | Show global loot for targeted NPC |
| `npc_stats` | `#npcstats` | Show targeted NPC's stats |
| `npc_type [NPC ID]` | `#viewnpctype` | View NPC type data |
| `peqzone_flags` | `#peqzone_flags` | Show PEQ zone flags |
| `petition` | `#listpetition`, `#viewpetition` | View petitions |
| `petition_info` | `#petitioninfo` | Show petition info |
| `proximity` | `#proximity` | Show proximity triggers |
| `quest_errors` | `#questerrors` | Show quest script errors |
| `quest_globals` | `#globalview` | Show quest globals |
| `recipe [Recipe ID]` | `#viewrecipe` | View a recipe |
| `server_info` | `#serverinfo` | Show server info |
| `skills` | `#showskills` | Show target's skills |
| `spawn_status [all\|disabled\|enabled\|Spawn ID]` | `#spawnstatus` | Show spawn status |
| `special_abilities` | `#showspecialabilities` | Show special abilities |
| `spells [disciplines\|spells]` | `#showspells` | Show spells or disciplines |
| `spells_list` | `#showspellslist` | Show full spell list |
| `stats` | `#showstats` | Show target stats |
| `timers` | `#timers` | Show timers |
| `traps` | `#trapinfo` | Show trap info |
| `uptime [Zone Server ID]` | `#uptime` | Show uptime |
| `variable [Variable Name]` | `#getvariable` | Show a variable value |
| `version` | `#version` | Show server version |
| `waypoints` | `#wpinfo` | Show waypoints for targeted NPC |
| `who [Search Criteria]` | `#who` | List players online |
| `xtargets [Amount]` | `#xtargets` | Show extended targets |
| `zone_data` | `#zstats` | Show zone statistics |
| `zone_global_loot` | `#showzonegloballoot` | Show zone global loot |
| `zone_loot` | `#viewzoneloot` | Show zone loot table |
| `zone_points` | `#showzonepoints` | Show zone points |
| `zone_status` | `#zonestatus` | Show zone status |
| `zone_variables` | | Show zone variables |
| `exempt [Search]` | | **NMS.** Shared-IP report: accounts logged in within the last 10 minutes (excluding zone 151) that share an IP with another account. Prints raw IPs and account names with `#goto`/`#summon` links **and mirrors the whole report to Discord webhook `ip-exempt` on every run**. No per-subcommand gate by default — inherits `#show` (Guide 50). Restrict it in `command_subsettings`. |

---

### `#shutdown`
Default status: **GMLeadAdmin (150)**  
Shut down the current zone process.

---

### `#size [Value]`
Default status: **QuestTroupe (80)**  
Change your target's size. Alias of `#feature size`.

---

### `#soulmark [add|remove] [Character] [Reason...]`
Default status: **GMAdmin (100)**  
**NMS.** Flag or unflag an account as a suspected cheater. Resolves the character to its
account, then writes the global data bucket `<account_id>-CheaterFlag` with the reason
(`add`) or deletes it (`remove`). Both directions post to the Discord webhook `admin`. Reason
is required for `add`. `NMS_soulmark_utils.pl` reads the bucket to warn on login.

---

### `#spawn [Name] [Race] [Level] [Material] [HP] [Gender] [Class] [PriWeapon] [SecWeapon] [MerchantID]`
Default status: **Steward (10)**  
Spawn an NPC with the specified parameters.

---

### `#spawneditmass [Search] [Option] [Value] [Apply]`
Default status: **GMLeadAdmin (150)**  
Zone-wide spawn editing. Pass `1` for Apply to commit changes.

---

### `#spawnfix`
Default status: **GMAreas (170)**  
Find the targeted NPC in the database by X/Y/heading and update it to spawn at your current location and heading.

---

### `#stun [Duration]`
Default status: **GMAdmin (100)**  
Stun yourself or your target for the specified duration in milliseconds.

---

### `#summon [Character Name]`
Default status: **QuestTroupe (80)**  
Summon a corpse, NPC, or player. Optionally specify a player by name.

---

### `#summonburiedplayercorpse`
Default status: **GMAdmin (100)**  
Summon your target's oldest buried corpse.

---

### `#summonitem [Item ID] [Charges]`
Default status: **GMMgmt (200)**  
Summon an item onto your cursor. Charges optional.

---

### `#suspend [Name] [Days] [Reason]`
Default status: **GMLeadAdmin (150)**  
Suspend a character for the specified number of days.

---

### `#suspendmulti [Name One|Name Two|...] [Days] [Reason]`
Default status: **GMLeadAdmin (150)**  
Suspend multiple characters. Separate names with `|`.

---

### `#takeplatinum [Amount]`
Default status: **GMMgmt (200)**  
Take platinum from yourself or your player target.

---

### `#task`
Default status: **GMLeadAdmin (150)**  
Task system management.

| Subcommand | Description |
|---|---|
| `assign [Task ID]` | Assign a task to the target |
| `complete [Task ID]` | Complete a task |
| `purgetimers` | Purge task timers for target |
| `reload lists` | Reload goal/reward list data |
| `reload sets` | Reload task set data |
| `reload task [Task ID]` | Reload a single task |
| `reloadall` | Reload all task data from database |
| `sharedpurge` | Purge all active shared tasks |
| `show` | List active tasks for target |
| `uncomplete [Task ID]` | Uncomplete a completed task |
| `update [Task ID] [Activity ID] [Count]` | Update task progress |

---

### `#tim`
Default status: **Player (0)**  
**NMS.** Toggle improved NPC models for yourself. Writes the character bucket
`DisableFancyModels` when off (deleted when on) and despawns/respawns every NPC in the zone
for your client so the change takes effect immediately.

---

### `#traindisc [Level]`
Default status: **GMLeadAdmin (150)**  
Train all disciplines usable by the target up to the specified level.

---

### `#tune`
Default status: **GMAdmin (100)**  
Calculate combat statistical values.

| Subcommand | Description |
|---|---|
| `stats [A/D]` | Show AC mitigation %, hit chance, avoidance chance |
| `FindATK [A/D] [Target %] [Interval] [Loop Max] [AC Override] [Info Level]` | Find ATK for target mitigation % |
| `FindAC [A/D] [Target %] [Interval] [Loop Max] [ATK Override] [Info Level]` | Find AC for target mitigation % |
| `FindAccuracy [A/D] [Hit %] [Interval] [Loop Max] [Avoidance Override] [Info Level]` | Find Accuracy for target hit % |
| `FindAvoidance [A/D] [Hit %] [Interval] [Loop Max] [Accuracy Override] [Info Level]` | Find Avoidance for target hit % |

`A` = Attacker perspective, `D` = Defender perspective.

---

### `#undye`
Default status: **GMAdmin (100)**  
Remove dye from all armor slots on yourself or your target.

---

### `#unmemspell [Spell ID]`
Default status: **Guide (50)**  
Unmemorize a spell by ID for yourself or your target.

---

### `#unmemspells`
Default status: **Guide (50)**  
Unmemorize all spells for yourself or your target.

---

### `#unscribespell [Spell ID]`
Default status: **GMCoder (180)**  
Unscribe a spell from yourself or your target's spellbook.

---

### `#unscribespells`
Default status: **GMCoder (180)**  
Clear your or your target's entire spellbook.

---

### `#untraindisc [Spell ID]`
Default status: **GMCoder (180)**  
Untrain a discipline from your or your target by spell ID.

---

### `#untraindiscs`
Default status: **GMCoder (180)**  
Untrain all disciplines from your target.

---

### `#wc [Slot ID] [Material] [Hero Forge Model] [Elite Material]`
Default status: **GMMgmt (200)**  
Set the weapon/armor material for a specific slot on yourself or your target.

---

### `#worldshutdown`
Default status: **GMMgmt (200)**  
Shut down world and all zone servers.

---

### `#worldwide`
Default status: **GMImpossible (250)**  
Perform world-wide GM functions such as zone-wide casting. Use with caution.

---

### `#wp [add|delete] [Grid ID] [Pause] [Waypoint ID] [-h]`
Default status: **GMAreas (170)**  
Add or delete a waypoint by grid ID. Pause and Waypoint ID can be `0` to auto-append. Use `-h` to apply your current heading.

---

### `#wpadd [Pause] [-h]`
Default status: **GMAreas (170)**  
Add your current position as a waypoint to your targeted NPC's path. Creates a new grid if none exists. Pause defaults to `0`. Use `-h` for current heading.

---

### `#zone [Zone ID|Short Name] [X] [Y] [Z]`
Default status: **Guide (50)**  
Teleport to a zone by ID or short name. Coordinates are optional.

---

### `#zonebootup [Zone Server ID] [Short Name]`
Default status: **GMLeadAdmin (150)**  
Boot a specific zone on a zone server.

---

### `#zoneinstance [Instance ID] [X] [Y] [Z]`
Default status: **Guide (50)**  
Teleport to a zone instance by ID. Coordinates optional.

---

### `#zoneshard [Zone] [Instance ID]`
Default status: **Player (0)**  
Teleport to a specific shard (instance) of a zone. Stock command, **NMS-modified body**
(`gm_commands/zone_shard.cpp`): honours hub zones from `Custom:HubZones` (only when
`Custom:MulticlassingEnabled`), refuses to move you while you have aggro, uses fixed arrival
points for East Commons and Bazaar, and shows `Client::ShowZoneShardMenu()` unless
`Zone:ZoneShardQuestMenuOnly` is set.

---

### `#zoneshutdown [instance|zone] [Instance ID|Zone ID|Short Name]`
Default status: **GMLeadAdmin (150)**  
Shut down a zone server by instance ID, zone ID, or short name.

---

### `#zonevariable`
Default status: **GMAdmin (100)**  
Manage variables for the current zone.

| Subcommand | Description |
|---|---|
| `clear` | Clear all zone variables |
| `delete [Variable Name]` | Delete a zone variable |
| `set [Variable Name] [Value]` | Set a zone variable |
| `view [Variable Name]` | View a zone variable |

Use quotes for names/values with spaces.

---

### `#zsave`
Default status: **QuestTroupe (80)**  
Save the zone header to the database.
