# NMS Codebase — Working Understanding

> Reference document for all work on this repo. Written from a full scan of the source at
> commit `4d9f2224` ("Initial commit of NMS-Release"). Read this before touching anything.
>
> Companion references: [`QUEST-API.md`](../Release-NMS-Quests/QUEST-API.md) (script
> bindings — §0 is the NMS delta) and [`GM-COMMANDS.md`](../Release-NMS-Server/GM-COMMANDS.md)
> (every `#command` with its default status).

---

## 1. The thesis, in one paragraph

**NMS is not a new game server. It is stock [EQEmu](https://github.com/EQEmu/Server) with a
custom layer bolted on, where almost every custom behavior is a boolean rule that can be
switched off.** The fork tracks EQEmu binary database version `9325`. The custom layer is
concentrated in one `RULE_CATEGORY(Custom)` block of ~120 rules in `common/ruletypes.h`
(~lines 1194–1320), a second parallel migration manifest, and a handful of new opcodes that
only a modified client understands. Understanding those three things — **the Custom rule
block, the custom manifest, and the client contract** — is most of understanding NMS.

The practical consequence: when something behaves oddly, the first question is almost always
*"which Custom rule governs this, and what is it set to in `rule_values`?"* — not *"where is
this in the C++?"*

---

## 2. Repository layout

Four sibling folders, one git repo, no submodule linkage between them:

| Folder | What it is | Deployed to |
| --- | --- | --- |
| `Release-NMS-Server/` | The EQEmu-derived C++ server + the 540 MB DB dump | The VPS |
| `Release-NMS-Quests/` | 8,054 quest scripts across 220 zone folders | `<runtime>/quests/` |
| `Release-NMS-Plugins/` | 52 Perl plugins the quests call into | `<runtime>/quests/plugins/` |
| `Release-NMS-Client/` | `dinput8.dll` + modified UI XML | Each player's RoF2 client |
| `Release-NMS-Deploy/` | Install/build automation (this folder) | The VPS |

**Client target: RoF2 only.** Other patch files exist in `utils/patches/` (Titanium, SoF, SoD,
UF, RoF) because they came with upstream EQEmu, but the custom opcode block is only defined in
`patch_RoF2.conf`. Non-RoF2 clients are untested and will not see any custom feature.

### Process model

The build produces seven binaries into `Build/bin/Release/`:

| Binary | Role | Notes |
| --- | --- | --- |
| `shared_memory` | Loads items/spells/etc. into shared memory files | **Must run and exit before `world`.** Re-run after any content DB change. |
| `world` | Login handoff, character select, zone orchestration | Runs DB migrations at boot. Start second. |
| `zone` | Gameplay: combat, spells, quests | Many instances, one per active zone. Usually launched by `eqlaunch`. |
| `eqlaunch` | Spawns and supervises `zone` processes | Takes a config name, e.g. `eqlaunch zone` |
| `ucs` | Universal chat (channels, mail) | Port 7778 |
| `queryserv` | Optional query/logging service | |
| `loginserver` | Standalone login | Port 5998. Built only with `-DEQEMU_BUILD_LOGIN=ON` |
| `export_client_files` | Not a service — a tool | Emits the four client data files from the DB |

**Boot order matters:** `shared_memory` → `world` → `eqlaunch` → `ucs`/`queryserv`.
`loginserver` is independent and can start any time.

---

## 3. The custom layer

Everything below is gated behind a `Custom:` rule unless stated otherwise. All rules live in
`common/ruletypes.h` and are overridable per-ruleset in the `rule_values` table.

Lookup index for every `Custom` rule (type, default, related rules, note): [`custom-rules/README.md`](custom-rules/README.md) — generated, regenerate with `python Release-NMS-Deploy/custom-rules/generate.py`.

### 3.1 Multiclassing — a bitmask, not extra columns

The single most important design decision in the codebase, and the one most likely to surprise.

A character can hold up to `Custom:MaxMulticlasses` classes (default **4**). This is **not** stored as `class2`/`class3` columns.
It is a **bitmask** (`uint32 classes`) squeezed into existing padding in `PlayerProfile_Struct`
(`common/eq_packet_structs.h` ~line 1190), and **persisted as a data bucket** named
`GestaltClasses` — not a table of its own.

- The inventory window's Shrouds tab is the **Hero** tab (`EQUI_Inventory.xml` page
  `IW_AltCharProgPage` + `eqgame_dll/hero_tab.cpp`): it lists the sixteen classes with held
  levels and sends `OP_HeroRequest` (`0x140C`, add or remove). `Handle_OP_HeroRequest` fails
  closed with `CanAddExtraClass` / `HasClass`, then fires the player event
  `EVENT_HERO_REQUEST` (global script only, `EventPlayerGlobal`); `global_player.pl` routes it
  to `plugin::HeroRequest`, which shares
  the guildmaster add path and the Ayonae removal policy (`RemoveClassFree` /
  `RemoveClassPaid` in `NMS_multiclass_utils.pl`; the tab uses the free removal first, Ayonae
  lets the player choose). The cap and the join level are the server's: the tab sends every
  request and shows the server's refusal. No server-to-client opcode: the bulk stats packet
  redraws the tab.
- Per-class experience is persisted in `character_class_exp`; with `HeroCatchupEnabled` off
  (the default), every row shadows the profile pool, while on the pool and displayed level cache
  the lowest class and `Client::SetEXP` water-fills the lowest rows until they catch up.
  The hard cap is `Character:MaxExpLevel` (70): over-cap rows and the pool are pulled down
  on login and on `SetEXP`. `KeepLevelOverMax` must not lift the pool to the watermark.
  `#level` / quest `SetLevel(..., true)` clamp to that cap. Rule-off login still applies
  the per-character `CharMaxLevel` bucket after `KeepLevelOverMax`.
- Write: `common/database.cpp:532`, `zone/client.cpp:14536` / `:14582`
- Read: `zone/client_packet.cpp:644` loads it into `m_pp.classes`
- Accessors: `Client::GetClassesBits()` (`zone/client.cpp:14509`) returns the mask when
  `RuleB(Custom, MulticlassingEnabled)` is true, otherwise just the single-class bit
- Spell knowledge is `character_learned_spells` / `character_learned_discs` (uncapped). The live
  book is 2880 slots; the RoF2 window shows one 720-slot volume at a time (`/book 1-4` in the
  add-on). `RemoveExtraClass` hides class-owned spells the current mask cannot use; it does not
  delete learned rows. Skills and AA ranks are shelved the same way: skill values stay in
  `character_skills` (read as 0 and shown greyed while no held class can have them, no level
  clamp on a held class's value), AA rows stay in `character_alternate_abilities` and leave
  memory only (`ReloadAlternateAdvancementForClasses`), and a reset refunds shelved rows too.
  Only spells follow the hero level (`UnmemorizeGemsAboveLevel` on a drop and on re-add).
  If the learned tables cannot be read, reconcile skips hide/restore
  rather than unscribing against an empty set. Coordinated server + DLL deploy; CAuth cannot
  reject an old add-on before the profile goes out. Spec: `specs/2026-09-07-spellbook-capacity.md`.
- **`Mob::HasClass(class, bitmask)`** (`zone/mob.cpp:4859`) replaces every stock
  `GetClass() == X` comparison across attack, spells, AA and bonuses. **If you add code that
  branches on class, use `HasClass`, never `GetClass()`.** This is the most common way to
  introduce a multiclass bug.
- Quest API: `AddExtraClass` / `RemoveExtraClass` / `HasClassID` / `GetClassesBitmask` in
  Perl (`zone/perl_client.cpp`) and Lua (`zone/lua_client.cpp`); the cap is enforced in
  `Client::CanAddExtraClass()` / `Client::AddExtraClass()`. Full table in QUEST-API.md §0.2.

**Two ugly-but-load-bearing hacks** you must not "clean up" without understanding them:

1. **Character select smuggles the mask through the `Deity` field.** `world/worlddb.cpp:110-180`
   reads the `GestaltClasses` bucket, picks a *random* one of the character's classes for
   `cse->Class`, and puts the full bitmask in `cse->Deity`. The modified client unpacks it.
2. **Guild rosters send `GetClassesBits() + 1000` as the class value**
   (`zone/client_packet.cpp:8423`, `common/guild_base.cpp:851`). The `+1000` is the signal to
   the client that this is a mask and not a class id.

Supporting rules: `Custom:ServerAuthStats` (server-authoritative stats, requires the DLL),
`Custom:UseDynamicAATimers` (+ `character_dynamic_aa_timers` table: every timed AA a character
owns, grant-only ones included, gets its own client shared-timer index, 1..98 per character,
allocated at the table send and on a first-rank purchase; unowned ranks go out as 0; the RoF2
client discards indexes above 99, so rows above 98 and rows for abilities no longer held are
dropped at zone entry; a dropped class's index frees itself once its cooldown ends; spec
`specs/2026-09-08-aa-reuse-timer-ids.md`), `Custom:AAIgnoreExpansionGate` (skip `aa_ranks.expansion` vs the
character/World bitmask so later-era AAs remain trainable; off = stock refuse),
`Custom:BypassMulticlassStackConflict`, `Custom:MaxMulticlasses`,
`Custom:HeroCatchupEnabled`, `Custom:NewClassStartLevel`, and the `character_aa_disabled` table.

### 3.2 Multiple pets

`Mob` holds `std::vector<uint16> petids` (`zone/mob.h:1683`) where stock EQEmu has a single
`petid`. Cap is `RuleI(Custom, AbsolutePetLimit)`, default 9.

- API: `zone/mob.h:1129-1155` — `GetAllPets`, `AddPet`, `RemovePet`, `ValidatePetList`,
  `GetActivePet`, `ConfigurePetWindow`, `MarkPetListDirty`
- Implementation: `zone/pets.cpp` (~1805 lines)
- Wire: new `OP_PetList` — `uint32 count`, then `count × {spawn_id, class_id}`, where
  `class_id` comes from `NPC::GetPetOriginClass()` (`zone/npc.cpp:5531`). Flushed once per
  `Client::Process` via a dirty flag, so **setting the dirty flag is how you make the pet
  window refresh** — do not send the packet directly.
- Persistence: `character_pet_name` (gained a `class_id` column, manifest v8/v11) and
  `character_pet_command_states` (v13)
- Related: pet bags (`Custom:EnablePetBags`), suspended minions (`m_suspendedminions`,
  `zone/client.h:2343`, stored with pet ids offset by 100), `familiar_names` content table (v10)

### 3.3 Emperor's Favor

**Alt currency id 6** (`constexpr uint8 EMPERORS_FAVOR_CURRENCY_ID = 6`, `world/client.h:40`). The
custom part is that it is stored **per account, not per character**.

- Table: `account_alt_currency (account_id, currency_id, amount)` — manifest v9, which also
  back-fills by SUMming `character_alt_currency` per account
- Repository: `common/repositories/account_alt_currency_repository.h`
- Gate: `RuleB(Custom, EnableAccountAltCurrency)`. `Client::SetAlternateCurrencyValue`
  (`zone/client.cpp:8901`) routes to `UpdateAccountAltCurrencyValue` when on.
- Drops: `zone/attack.cpp:3054` — a flat `Custom:EmperorsFavorDropChance` roll (1 in 150),
  independently per eligible player per corpse, awarded to every member of the group or raid.
  **No level gate and no con-color gate of any kind** — both were deliberately removed (see
  `Release-NMS-Deploy/specs/2026-09-08-currency-rename-emperors-favor.md`). This means a
  low-level member of a group still rolls, and a grey-con kill still rolls: both are accepted
  design choices, not defects — do not reintroduce either gate without asking first.
- Spent at character select to unlock character sets and slots (`world/client.cpp:3178-3240`)

⚠️ **`#award` does not touch `account_alt_currency` directly.** The GM command
(`zone/gm_commands/award.cpp`) adds to the character's `EmperorsFavor-Award` data bucket, fires a
Discord webhook, and sends cross-zone signal 666. `plugin::UpdateEmperorsFavorAward`
(`NMS_custom_events.pl`) consumes the bucket on that signal and on every zone-in and credits
currency 6 through `AddAlternateCurrencyValue`. If the balance did not change, check that the
plugin is the real one and not the original `return 0;` stub.

### 3.4 Item upgrade tiers — encoded in the item id

Tiers are arithmetic on the item id, not a column:

```
base_id                 → Tier 0 (normal)
base_id + 1,000,000     → Tier 1 (Enchanted)
base_id + 2,000,000     → Tier 2 (Legendary)
```

- Helpers: `EQ::ItemInstance::GetUpgrade()` / `GetMaxUpgrade()`
  (`common/item_instance.cpp:899-925`), `Mob::GetApocItemUpgrade()`, `Client::SummonApocItem()`
  (`zone/inventory.cpp:221-320`)
- Perl mirror: `NMS_item_utils.pl` — `GetBaseID`, `IsItemTier0/1/2`, all using `id % 1000000`
- Drop rates: `Custom:Tier1ItemDropRate` (25%), `Custom:Tier2ItemDropRate` (5%), gated by
  `Custom:DoItemUpgrades`
- Shared-bucket loot (`Custom:RandomLootBuckets`, compiled default **false**): mapped
  named/raid NPCs skip stock drops whose base id is in the bucket pool, then roll one
  shared drop through the existing `AddLootDrop` / `DoUpgradeLoot` hook. Seed is
  `utils/sql/nms_loot_buckets_seed.sql` (not a migration). Empty tables fail closed to
  stock loot. Do not use `global_loot` for this.
- **Quest hand-ins must normalize with `id % 1000000`** or a Legendary version of a quest item
  will not be recognized. See `zone/cli/tests/npc_handins_multiquest.cpp`.
- Separately, `Custom:PowerSourceItemUpgrade` turns the Power Source slot into an item-XP slot:
  `Client::AddItemExperience()` (`zone/exp.cpp:929`) accumulates a float in the item's `Exp`
  custom-data; at 100% the item is swapped for its `+1,000,000` version.
- `Custom:UseNMSItemMutations` rewrites item stats and names at shared-memory load time
  (`common/shareddb.cpp:1453+`) — meaning **item changes require re-running `shared_memory`**.

### 3.5 Waypoints

A player teleport-hub system. `zone/nms_waypoints.cpp` (453 lines) + `.h`.

- Five tables via five repositories (`common/repositories/nms_waypoints*_repository.h`):
  `nms_waypoints`, `nms_waypoints_categories`, `nms_waypoints_default` (content schema);
  `nms_waypoints_character`, `nms_waypoints_account` (player schema)
- Each configured zone auto-spawns **NPC type 26999** at the waypoint coords
  (`Zone::SpawnWaypointNPC`, `WAYPOINT_NPC_ID` is hardcoded)
- Wire: `OP_WaypointList` (server → client), `OP_WaypointRequest` (client → server)
- Unlocked by visiting (`Client::UnlockWaypoint`); account-wide sharing via
  `AllowAccountWaypoints`; toggles stored as JSON in the `waypoints` data bucket
- Own log category: `LogWaypoints`

### 3.6 Character sets

Accounts get named "sets" of characters. `MAX_CHARACTER_SETS = 64`, 24 base slots, more
purchasable with Emperor's Favor. Opcodes `OP_CharacterSetRequest/Create/Move/Unlock`,
`OP_SendCharacterSets`. Handled in `world/client.cpp` and `world/worlddb.cpp`.

⚠️ See §4.2 — the tables this needs have **no migration**.

### 3.7 Everything else, briefly

- **Global buffs** — `global_buffs` table, `Custom:PermanentServerBuffsEnabled`,
  handled at `zone/zone.cpp:3194` and `zone/worldserver.cpp:4627`
- **Custom instances** — `Custom:StaticInstanceVersion` (255, no respawns),
  `Custom:FarmingInstanceVersion` (254)
- **Custom GM commands** in `zone/gm_commands/`: `award`, `castspellnms`, `corpsefix`,
  `gearup`, `gmpack`, `lootsim`, `zoneshard`, `alttoggle`, `illusion_block`, `feature`
- **Discord webhooks** — `zone->SendDiscordMessage`, used by `#award` and GM audit
- **Combat/spell rework** — `Custom:SuppressDispels` (replaces `SE_CancelMagic` with a
  "SuppressBuff" SPA 527 + `OP_SuppressBuffNameInfo`), heroic stat scaling,
  `TemporaryStunImmunity`, `AdditiveBackstabDamage`, `SuspendGroupBuffs`,
  `FadeNPCDebuffsOutofCombat`
- **Seasonal characters** — `Custom:EnableSeasonalCharacters` + `SeasonalCharacter` bucket

### 3.8 Firiona Vie + attune loop

NMS loot is tradable until worn. `World:FVNoDropFlag` compiled default is **1** (dump
row is 0 until custom **v44**). Unattuned no-drop can be traded, dropped, and shared-banked.
Wearable no-drop (and no-drop augs) that are not already attuneable are promoted at
`shared_memory` load so equip sets attuned. Attuned instances stay bound: `IsDroppable`
returns false (contents and augs are inspected before the FV parent
early-return), and drop / trade / shared-bank no longer bypass that with
`CanTradeFVNoDropItem()`. Trade finish still consults that helper for **AdminOnly**
GMs giving unattuned no-drop; character-bound items stay rejected. Urthron's
Ultimate Unattuner (`9208` / `52024`) clears attuned instance state even when
item-table `nodrop` is 0; it refuses when the cursor is at the RoF2 persist
limit and does not consume the source until the returned item is saved. A failed
cursor or inventory put rolls back the destination clone so the kept source is
not duplicated. Armarium
stays bound (`fvnodrop = 1` plus identity in `IsDroppable`; vault refuse is
recursive). Re-run `shared_memory` after changing the FV rule.
`Items:DisableAttuneable` or FV `0` keeps stock item flags.

Spec: `Release-NMS-Deploy/specs/2026-09-07-fv-attune-loop.md` (decisions D1-D6).

### 3.9 Armarium — the inventory clicky that opens vault storage

One lore / no-drop inventory key, item **`9011013`**, named **Armarium**. Right-click opens the
vault window on page 1. Gated by `Custom:DimensionalVault` (compiled default **true**; custom
**v45** sets the live `rule_values` row).

- **Auto-summoned** on zone-in / login when the character does not already hold one. "Already
  holds one" means inventory, bags, the **entire** cursor queue, bank, shared bank, the vault
  itself, **and the character's corpses** — vault storage is invisible to `CountItem`, so a
  location missed here is a duplicate key.
- **Identity is two-part:** `id >= 9011013 && id % 1000000 == 11013`
  (`common/nms_vault_item.h`). Remainder alone would match stock `11013`, Boots of Quickness.
- **Vault deposit is refused, recursively** — cursor deposit, a bag containing the key,
  bag-in-vault, and `/nmsloot` Vault. Deposit-then-regrant would duplicate it.
- **The click is intercepted server-side.** `clickeffect` is spell id `1`, a dummy that only
  exists so the RoF2 client draws a clicky; the zone never casts it and `IsValidSpell` rejects
  ids below 2. Opening storage is `NmsVaultHandlePage(c, 1)` → `VAULTDATA|` — the same wire as
  `#vault_page 1`, so no client change was needed.
- **Fail closed:** rule off, tables missing, item absent from `items` or shared memory, or an
  ownership query that *fails* rather than returning no rows — none of those grant. A query
  failure is not "not owned".
- Bound even under Firiona Vie, and bound regardless of the vault rule.

⚠️ The two-part identity test protects the Armarium's own checks, **not** the generic
`% 1000000` normalization this fork uses elsewhere. NPC hand-ins (`zone/npc.cpp:5915`) match on
the remainder, and the bound-item trade guard (`zone/inventory.cpp:2255`) only fires for
player-to-player trades, so an NPC quest requiring Boots of Quickness (`11013`) would accept and
consume an Armarium — which the next zone-in re-grants. No shipped quest requires `11013`
(verified against `Release-NMS-Quests/` and the dump: only `11013` and `9011013` share that
remainder), so this is latent, not live. Check before adding one:
`SELECT id, Name FROM items WHERE id % 1000000 = 11013;`

Spec: `Release-NMS-Deploy/specs/2026-09-07-armarium.md` (decisions D1-D9, and §4 as the
acceptance checklist).

---

## 4. The migration system — read this before touching the DB

### 4.1 Two manifests, two version numbers

NMS runs a **second migration manifest in parallel with stock EQEmu's**:

| Manifest | File | Version column | Current |
| --- | --- | --- | --- |
| Stock | `database_update_manifest.cpp` | `db_version.version` | 9325 |
| **Custom** | `database_update_manifest_custom.cpp` | **`db_version.custom_version`** | **47** |
| Bots | `database_update_manifest_bots.cpp` | `db_version.bots_database_version` | |

Both are `#include`d directly into `common/database/database_update.cpp` (lines 9–11) and run
in sequence from `DatabaseUpdate::CheckDbUpdates()`.

The `custom_version` column does not exist in stock EQEmu. It is added lazily at boot by
`DatabaseUpdate::InjectCustomVersionColumn()` (`database_update.cpp:404`):

```sql
ALTER TABLE db_version ADD COLUMN custom_version INT UNSIGNED NOT NULL DEFAULT 0
```

…and compared against `CUSTOM_BINARY_DATABASE_VERSION` in `common/version.h:47`.

**Implication for deployment:** the DB user needs DDL rights, and
`server.auto_database_updates` must be on. `world` and `zone` refuse to proceed while
`HasPendingUpdates()` is true — you get a boot loop, not an error.

### 4.2 What is actually in the custom manifest

47 entries declared (v1–v47), **44 live**. Numbering is a plain sequence independent of the 9325
stock number. Entries carry `content_schema_update` to target the content DB rather than the
player DB.

| Range | Contents | Status |
| --- | --- | --- |
| v1 | Creates a junk table literally named `new_table` | Leftover test. Harmless, confusing. |
| v2–v14 | Schema: waypoint tables, `zone.npc_update_range`, `global_buffs`, `account_kill_counts`, `character_pet_name.class_id`, `account_alt_currency`, `familiar_names`, `character_aa_disabled`, `character_pet_command_states`, `character_dynamic_aa_timers` | Live |
| **v15–v17** | The three `account_character_set*` tables | **Commented out** — lines 273–334 |
| v18–v25 | Content payloads: Beastlord spell merchant + 38 scrolls, faction fixes, Bazaar spawns, AA339 whitelist | Live |
| v26 | Waypoint categories aligned with the client DLL tabs; expansion hub rune circles | Live |
| v27–v28 | Fabled season schema: `fabled_npcs` roster table (content DB) and the `fabled_season` state row (see FABLED-ENCOUNTERS.md) | Live |
| v29–v30 | `character_class_exp` table and backfill for per-class experience (`#hero`) | Live |
| v31–v32 | GM Starter Box item `9011012` and the `nms_gm_starter_pack` seed behind `#gmpack` | Live |
| v33 | Shared-bucket loot schema: `nms_loot_buckets`, `nms_loot_bucket_npcs`, `nms_loot_bucket_items` (gated by `Custom:RandomLootBuckets`) | Live |
| v34 | Mastery of the Past ranks 7–9 opened at levels 67 / 69 / 70 (`aa_ranks` 7059–7061; they shipped at level 80, expansion -1) | Live |
| v35 | Player table `character_nms_vault` (Dimensional Vault slots; `Custom:DimensionalVault`) | Live |
| v36 | Player table `character_nms_loot_offers` (`Custom:NmsLootOffers`) | Live |
| v37 | `character_nms_loot_offers.corpse_serial` | Live |
| v38 | `corpse_serial` widened to `BIGINT UNSIGNED` | Live |
| v39 | `instance_id` and Pass tombstone (`passed`) | Live |
| v40 | `passed_from` (client offer `name2` passer name) | Live |
| v41 | `character_nms_vault` per-instance item state: attunement, `custom_data`, ornamentation, `guid` | Live |
| v42 | `character_learned_spells` / `character_learned_discs` / `character_learned_mem` (B1 hide/restore) | Live |
| v43 | Armarium item `9011013` (inventory clicky that opens vault storage; `Custom:DimensionalVault`). Identity is `id >= 9011013` and `id % 1000000 = 11013` so stock `11013` is not the key. `norent = 1`, `fvnodrop = 1`, `attuneable = 0`. Missing clone source `9011010` (and missing dest) is an SQL error, not a silent stamp. | Live |
| v44 | `World:FVNoDropFlag = 1` on the active player `rule_values` row (dump `0` only; does not stomp `2`). Firiona Vie + attune loop. Wearable no-drop is promoted at `shared_memory` load, not by rewriting the dump. | Live |
| v45 | `Custom:DimensionalVault = true` on the active player `rule_values` row (does not stomp an existing true). Armarium grant and vault commands are on. | Live |
| v46 | **Content half** of the Emperor's Favor rename: item `46779` name and `lore`, the `db_str` alt-currency label, the two themed merchant NPCs, the `spawngroup` key. Guards on the `db_str` label, so a fresh install from the regenerated dump skips it. | Live |
| v47 | **Player half** of the same rename: the five `Custom:EmperorsFavor*` rule keys (drop chance to 150), the `EmperorsFavor-Award` bucket, the stale `saylink` rows. Separate entry so a split content/player deployment routes each half to the right connection. Guards on the renamed rule key. | Live |

### 4.3 ⚠️ The version number is a claim, not a fact

The v19–v25 comments are a candid post-mortem by the original authors. Earlier entries used
bare `UPDATE` statements that **silently no-opped** on databases where the target row did not
exist — so `custom_version` got stamped past payloads that never landed. This has been found
in the wild twice.

v22–v25 are "resync" entries written defensively, using `check = "SELECT 1"` with
`condition = "not_empty"` so they re-run idempotently every boot.

**Therefore: never trust `db_version.custom_version`. Always audit with**

```
mysql -u <user> -p <db> < utils/sql/nms_content_health_check.sql
```

It is read-only, safe to run any number of times, and every line prints its own expected value
so a mismatch names the exact missing payload.

### 4.4 What the migrations do *not* do

This is the biggest deployment trap in the repo. **Migrations create schema. They do not seed
content.** The seed data lives in the 540 MB dump. Specifically:

1. **Waypoint seed data has no migration anywhere.** v2/v3 create the five `nms_waypoints*`
   tables *empty*. The actual `INSERT INTO content.nms_waypoints...` exists only as a
   **commented-out block inside `zone/nms_waypoints.h`**. If the dump lacks those rows,
   waypoints silently do nothing — no NPC spawns, empty list, no error.
2. **`account_character_set*` tables have no migration** (v15–17 are commented out), but
   `world/client.cpp` and `worlddb.cpp` query them at character select. They must come from
   the dump or character select errors.
3. **Twelve loose `.sql` files are referenced nowhere in code** and must be applied by hand:
   - `Release-NMS-Server/`: `baztradeskills.sql`, `environmentdoodads.sql`, `holedoor.sql`,
     `kaesoradoors.sql`, `pojdoors.sql`, `pomdoors.sql`, `tranquilitydebris.sql`
   - `Release-NMS-Quests/`: `akanonfixyetanotherlamp.sql`, `overlordngrub.sql`,
     `skyfiredoodads.sql`
   - `Release-NMS-Server/utils/sql/`: `fabled_roster_seed.sql` (the Fabled roster; needs manifest v27
     first, see FABLED-ENCOUNTERS.md §6.8) and `nms_loot_buckets_seed.sql` (shared-bucket loot;
     needs manifest v33 first)

---

## 5. The client contract

**A stock RoF2 client cannot play on this server** with custom features enabled. The server
sends opcodes in the `0x1338`–`0x140C` range that stock clients do not understand.

- Opcodes: `common/emu_oplist.h` (~lines 620–643), mapped in `utils/patches/patch_RoF2.conf`
  under a `#CUSTOM` block (~line 733)
- The set: `OP_ServerAuthStats`, `OP_SkillTimers`, `OP_PetList`, `OP_CustomDiscTimer`,
  `OP_CAuth`, `OP_WaypointList`, `OP_WaypointRequest`, `OP_MulticlassCharSelect`,
  `OP_CharacterSet*`, `OP_SuppressBuffNameInfo`, `OP_NmsLootOffer` (`0x140A`),
  `OP_NmsLootDecision` (`0x140B`), `OP_HeroRequest` (`0x140C`, Hero tab add/remove)
- Loot-offer opcodes require the matching installed add-on build (not the repo `dinput8.dll`).
  `Custom:NmsLootOffers` default off; without that add-on, leave the rule off.
  When on, each in-zone group/raid member (and the killer) gets an independent
  loot-table roll in `/nmsloot` on NPC death; opening a corpse only resends.
- Spellbook is 2880 absolute slots on the wire. The add-on keeps `CHARINFO2.SpellBook[720]`
  unchanged and shows one volume at a time (`/book 1-4`). Ship server and DLL together; CAuth
  has no build number and runs after the profile is sent, so an old add-on cannot be rejected
  before a 2880-slot `OP_PlayerProfile` goes out. Spec: `specs/2026-09-07-spellbook-capacity.md`.
- **Enforcement:** when `Custom:ServerAuthStats` is on, the `CAuth` handshake
  (`zone/client_packet.cpp:5106`) validates `GetClassesBits() * GetID()` and **disconnects
  clients without the DLL.**

### 5.1 ⚠️ The login stream: RoF2 needs port 5999, not 5998

The loginserver opens **two UDP listeners in one process**, each with its own opcode file
(`loginserver/client_manager.cpp:88` and `:126`):

| Port | Opcode file | Client lineage |
| --- | --- | --- |
| 5998 | `login_opcodes.conf` | Titanium |
| **5999** | `login_opcodes_sod.conf` | **SoD onwards — includes RoF2** |

The two files disagree on the opcodes that matter:

| Opcode | Titanium (5998) | SoD (5999) |
| --- | --- | --- |
| `OP_Login` | 0x0002 | 0x0002 |
| **`OP_ChatMessage`** | **0x0016** | **0x0017** |
| `OP_LoginAccepted` | 0x0017 | 0x0018 |
| `OP_ServerListResponse` | 0x0018 | 0x0019 |
| `OP_LoginExpansionPacketData` | *absent* | 0x0031 |

**Why this bites so hard:** the login handshake reply is sent as `OP_ChatMessage`
(`loginserver/client.cpp:97`). Point a RoF2 client at 5998 and the server answers with
`0x0016`; the client is waiting for `0x0017`, discards the packet, and never sends
`OP_Login`. The client sits on "Logging in to the server. Please wait." forever.

Server-side there is **no error at all** — the log shows a connection and
`Session ready received`, then nothing, because from the server's point of view the client
simply stopped talking. Every service reports healthy.

Note also that `display_expansions: true` in `login.json` requires
`OP_LoginExpansionPacketData`, which exists only in the SoD set.

So `eqhost.txt` must read:

```
[LoginServer]
Host=<server-ip>:5999
```

and **UDP 5999 must be open** in Windows Firewall *and* at the hosting provider. It is easy
to open only 5998, since that is the port every generic EQEmu guide mentions.

### What players install

`Release-NMS-Client/ClientFiles/` is an *overlay* on a client they source themselves (RoF2-era;
Daybreak's, not distributable).

- **`dinput8.dll` is prebuilt and shipped** (1.68 MB, PE32 x86). No Visual Studio needed unless
  you change `eqgame_dll/_options.h`. It is a DirectInput proxy — Windows loads it instead of
  the system lib, it forwards real calls through and hooks the client meanwhile. `eqgame.exe`
  is never modified; deleting the DLL fully reverts.
- If rebuilding: VS 2022, **Win32/x86 only** (the client is 32-bit), always **Rebuild** not
  incremental. All deps are vendored (`Detours/`, `dxsdk81/`, `Blech/`, `dependencies/`).
- 24 UI XML files across `default/`, `gearcore/`, `shinsparxx/`, `Blue/` skins, including two
  windows with no stock equivalent: `NMS_WaypointsWnd.xml`, `NMS_MapFilterWnd.xml`
- **Four DB-derived files** must be regenerated per deployment with `export_client_files` and
  copied into **both the client root and `Resources/`** (the client keeps two copies and will
  load stale data otherwise): `spells_us.txt`, `dbstr_us.txt`, `SkillCaps.txt`, `BaseData.txt`

Known cosmetic gaps (server still runs): 397 item-model `.eqg` archives base RoF2 lacks;
inventory icon sheets `dragitem179`–`222.dds` (base client stops at 178).

---

## 6. Quests and plugins

### 6.0 ⚠️ The embedded Perl — pin it before you build

`zone.exe` does not shell out to Perl; it **embeds an interpreter**, and the quest scripts
run inside it. That has a consequence people miss: the CPAN modules and DBD driver the
plugins need must be installed in *that* Perl, not whichever one happens to be on `PATH`.

Which Perl gets embedded is decided at configure time by
`cmake/DependencyHelperMSVC.cmake`:

```cmake
#Try to find perl first, (so you can use your active install first)
FIND_PACKAGE(PerlLibs)
IF(NOT PerlLibs_FOUND)      # else download portable Strawberry 5.24.4.1
```

So it silently adopts your system Perl if there is one. **The version is not a free
choice:**

| Evidence | Version |
| --- | --- |
| `DependencyHelperMSVC.cmake` portable fallback (Windows) | 5.24.4.1 |
| `CMakeLists.txt:28` static-build pin (Linux) | 5.32.1 |
| **What these deploy scripts pin** | **5.32.1.1** |

Two independent things break on a newer Perl:

1. **EQEmu's embedded-Perl C code predates the API churn** in modern Perls. Its own
   fallback is 5.24; 5.32 is the newest version the project demonstrably builds against.
2. **Strawberry 5.40+ switched to UCRT.** `DBD::MariaDB`'s `dbdimp.c` still references the
   msvcrt-era internal `__pioinfo`, so it compiles and then dies at link with
   `undefined reference to __imp___pioinfo`. Observed on Strawberry 5.42.2.

Changing Perl after building means rebuilding the server, so settle this first. If the box
already carries a newer Perl, uninstall it before running the deploy scripts — stage 1
refuses to proceed against an out-of-range version rather than failing later in the build.

### 6.1 Structure

- **8,054 files: 4,033 Perl + 3,994 Lua**, roughly 1:1. **Both engines must be enabled.**
- 220 zone-named directories, plus `global/` and `lua_modules/`
- Entry points into the custom layer: `global/global_player.pl` and `global/global_npc.pl`
- `lua_modules/` holds 25 shared modules (`client_ext.lua`, `nms/`, `json.lua`, etc.)

The 11 `NMS_*` plugins in `Release-NMS-Plugins/`:

| Plugin | Provides |
| --- | --- |
| `NMS_multiclass_utils.pl` | Core multiclass engine: login hook, class map/bitmask lookups, `AddClass`/`RemoveClass`/`HasClass`, AA granting |
| `NMS_progression_utils.pl` | Expansion flagging: zone→expansion atlas, stage prereqs, time locks, `UpdateCharMaxLevel` |
| `NMS_slayer_utils.pl` | `ProcessSlayerCredit` — slayer titles by NPC race → creature type |
| `NMS_title_utils.pl` | Title unlocks on account + character buckets |
| `NMS_item_utils.pl` | Item tier arithmetic (mirrors the C++ `% 1000000` logic) |
| `NMS_popup_utils.pl` | Tutorial popup framework (IDs shaped `628<nnn>0`) |
| `NMS_instance_utils.pl` | `OfferStandardInstance` — DZ creation, `ScaleInstanceNPC` |
| `NMS_progression`/`seasonal`/`soulmark` | Seasonal chars; Soulmark/CheaterFlag warnings |
| `NMS_custom_events.pl` | **Hook stubs for you to extend** — say, death, handin, spawn, exp gain, item equip/click. Each is commented with whether its return value gates the caller. `UpdateEmperorsFavorAward` is live (consumes the `#award` bucket). |
| `NMS_general.pl` | Shared helpers: announces, serialization, `transform_item` |

### ⚠️ Perl dependencies

- **`MySQL.pl` needs `DBI`, `JSON`, and a DBD driver.** It opens its *own* DB connection by
  reading `eqemu_config.json` from the working directory. `NMS_item_utils.pl` and
  `NMS_progression_utils.pl` both call `plugin::LoadMysql()` — so **item tiers and progression
  are broken without these CPAN modules**, with no obvious error.

  ⚠️ **The DBD driver is the one genuine blocker on a MariaDB box.** Upstream `MySQL.pl`
  hardcoded a `dbi:mysql:` DSN, which only `DBD::mysql` serves — but **DBD::mysql 5.x
  removed MariaDB support outright** (upstream's own advice: "use DBD::MariaDB instead")
  and will not configure against MariaDB's client libraries. `DBD::mysql` 4.050 could, but
  no longer builds on modern Perl (5.42+). So on MariaDB the only installable driver is
  `DBD::MariaDB`, which answers to `dbi:MariaDB:` and *not* to `dbi:mysql:`.

  This fork patches `try_connect` to ask `DBI->available_drivers` and try whichever is
  actually present. A real MySQL box still takes the `dbi:mysql:` path exactly as before;
  a MariaDB box now works at all. If neither driver is installed it warns explicitly
  rather than returning `undef` silently.
- **`illusion_tools.pl:36` has `use Switch;`** — removed from core Perl in 5.14. Install
  `Switch` from CPAN or that file fails to compile on modern Strawberry Perl.
- `MP3.pl` needs a `cust_sound_files` table that is **not part of stock PEQ**. Missing → sound
  looping silently does nothing.

---

## 7. Gotchas index

Quick reference. Each links to the section above.

| # | Gotcha | § |
| --- | --- | --- |
| 1 | Branch on `HasClass()`, never `GetClass()` | 3.1 |
| 2 | Character select smuggles the class mask through `Deity`; guilds use `mask + 1000` | 3.1 |
| 3 | Pet window refreshes via the dirty flag, not by sending `OP_PetList` | 3.2 |
| 4 | `#award` writes a bucket + Discord ping; `plugin::UpdateEmperorsFavorAward` does the credit | 3.3 |
| 4b | Lua scripts use `eq.`, not `quest.`; Lua loads before Perl on a name collision | QUEST-API §0 |
| 4c | `SummonItem()` rolls an upgrade tier; use `SummonFixedItem()` for an exact item | QUEST-API §0.1 |
| 5 | Quest hand-ins must normalize item ids with `% 1000000` | 3.4 |
| 6 | Item stat changes need `shared_memory` re-run | 3.4 |
| 6b | Changing `World:FVNoDropFlag` needs a `shared_memory` re-run — the wearable no-drop promotion is a load-time mutation | 3.8 |
| 6c | Armarium identity is `id >= 9011013` **and** `id % 1000000 == 11013`; remainder alone matches stock Boots of Quickness | 3.9 |
| 6d | **Latent:** NPC hand-ins normalize with `% 1000000` (`npc.cpp:5915`), so the Armarium would satisfy a quest requiring Boots of Quickness (`11013`) and be consumed, then re-granted. No shipped quest requires `11013`. Do not write one. | 3.9 |
| 7 | `db_version.custom_version` is a claim — audit with the health-check SQL | 4.3 |
| 8 | Migrations create schema only; content comes from the dump | 4.4 |
| 9 | Waypoint seed data exists **only** as a comment in `nms_waypoints.h` | 4.4 |
| 10 | Twelve loose `.sql` files must be applied by hand | 4.4 |
| 11 | v1 creates a junk `new_table` on every fresh DB — harmless | 4.2 |
| 12 | `CAuth` disconnects clients without the DLL when `ServerAuthStats` is on | 5 |
| 13 | The four exported client files go in **both** client root and `Resources/` | 5 |
| 14 | Perl needs `DBI`/`JSON`/`Switch` + a DBD driver, or tiers + progression silently break | 6.1 |
| 14b | On MariaDB the driver **must** be `DBD::MariaDB` — DBD::mysql 5.x refuses to build | 6.1 |
| 14c | `zone.exe` **embeds** Perl — pin 5.32.1.1; 5.40+ breaks the build *and* the driver | 6.0 |
| 15 | `utils/defaults/Maps/` is **empty** — zone pathing/LOS files must be fetched separately | — |
| 16 | `shared_memory` must run and exit before `world` starts | 2 |
| 17 | **RoF2 logs in on UDP 5999, not 5998** — wrong port hangs the client silently | 5.1 |
| 18 | The VC++ **runtime** is not installed by Build Tools — binaries exit -1073741515 mute | 8 |
| 19 | `zlib-ng1.dll` is built outside `Build\bin\Release`; sweep the whole build tree | 8 |
| 20 | `zone.exe` needs `perl<ver>.dll` from PATH — services read only the **machine** PATH | 6.0 |
| 21 | Build BEFORE installing Perl and CMake silently links its own downloaded 5.24 | 6.0 |
| 22 | `launcher` table ships empty — without a 'zone' row, zero zones boot, silently | 8 |
| 23 | `lua_modules` defaults to the server root; `zone.exe` exits 1 without the config key | 8 |
| 24 | Defender quarantines the compiled binaries after they are copied | 8 |
| 25 | The exp pool caches the trailing class; only `SetEXP` and `SetLevel(command)` write it | 3.1 |
| 26 | `level2` is a high-water mark, not the effective multiclass level | 3.1 |
| 27 | Server-auth stat keys are sent from 1 through `statMax - 1`; key 0 is invalid | 3.1 |

---

## 8. Deployment summary

The full sequence, which `build-scripts/2-Setup-NMSServer.ps1` automates:

1. Install prerequisites (MariaDB, VS Build Tools, CMake, Git, 7-Zip, and **Strawberry Perl
   5.32.1.1** plus its CPAN modules — the Perl version is not a free choice, see §6.0)
2. Clone the repo
3. Create schema + user; import `database/release-peq.zip` (~540 MB unpacked)
4. `cmake -S . -B Build -G "Visual Studio 17 2022" -A x64 -DEQEMU_BUILD_LOGIN=ON` then build
   Release. **The first configure needs internet** — it downloads ~132 MB of vcpkg deps.
   The `vcpkg/vcpkg-export-x64/` directory committed to this repo looks like it makes that
   unnecessary. It does not: `.gitignore` has a bare `bin/`, which git applies at every
   depth, so the committed tree contains **no runtime DLLs at all**, and
   `DependencyHelperMSVC.cmake:40` gates on the `.zip` rather than the directory. Do not
   disable the fetch.
5. Assemble the runtime directory: binaries, `assets/patches/`, `quests/`, `quests/plugins/`,
   `logs/`, `shared/`, `Maps/`, and **`export/`** — the exporter writes there with a bare
   `ofstream` and will not create it, so without it all four client files silently fail
6. **Fetch the Maps repo** — not in this repo, not mentioned in any README
7. Write `eqemu_config.json` + `login.json` with real credentials and the public IP. Emit
   `server.ucs`, **not** the legacy `chatserver`/`mailserver` pair —
   `CheckUcsConfigConversion()` rewrites the config in place on load and drops a `.bak`
   copy of your cleartext DB password with inherited ACLs
8. Run `shared_memory`, then boot `world` to apply migrations
9. **Apply the loose SQL patches** — *after* migrations, so manifest entries touching
   `doors` / `object` / `npc_types` cannot clobber them
10. Run the health check and read the output
11. Run `export_client_files`; ship the four files to players with the client overlay
12. Register services and open the firewall. **All player traffic is UDP** — every
    client-facing listener is `EQStreamManager` → `uv_udp_t`, and world's is hardcoded to
    9000 in `world/main.cpp:335` (it is *not* `world.tcp.port` from the config):
    - Open: **UDP 5998** and **UDP 5999** login (RoF2 uses 5999 — see §5.1), **UDP 9000**
      world, **UDP 7778** UCS, **UDP 7000–7400** zones
    - Open the same ports at the **hosting provider** — its firewall is separate from
      Windows Firewall and several providers block inbound UDP by default
    - Not opened: 3306 (DB, loopback only), **TCP** 9000 (telnet — an unauthenticated
      admin channel, and a different thing from UDP 9000), 9001 (servertalk, loopback),
      9080/9081 (web)
13. First account to log in gets GM: `UPDATE account SET status = 250 WHERE name = '<login>'`

---

*Sources: full source scan of `Release-NMS-Server/`, `Release-NMS-Client/`,
`Release-NMS-Quests/`, `Release-NMS-Plugins/` at commit `4d9f2224`.*
