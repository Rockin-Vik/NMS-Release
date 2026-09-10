-- ============================================================================
-- NMS content health check - verifies the DATA every custom-manifest version
-- (v18 through v48) is supposed to deliver, without trusting db_version.
--
-- Why this exists: we have now twice found servers whose custom_version was
-- stamped PAST an entry whose content never landed (a half-apply healed by a
-- later resync; a wholesale-skip healed by the v23-25 repairs). The version
-- number is a claim; this file is the audit. Every line prints its own
-- expectation - anything that misses its expected value identifies exactly
-- which payload is absent.
--
-- Run (akk-stack):
--   docker exec -i <mariadb-container> mariadb -u eqemu -p'<password>' peq \
--     < nms_content_health_check.sql
-- Or from any mysql/mariadb client: source nms_content_health_check.sql
--
-- Split player/content schemas: this script uses one DATABASE(). Point it at the
-- player schema for db_version, rule_values, and character_nms_* tables; point it
-- at the content schema for items / npc / zone / aa checks. A single run against
-- one schema cannot prove both halves.
--
-- READ-ONLY: SELECT/SHOW only. Safe on any server, any number of times.
-- ============================================================================

SELECT 'db_version (expect 48 once current)' AS what, custom_version AS value FROM db_version LIMIT 1;

-- ---- v18 / v23: Beastlord spell merchant + scrolls -------------------------
SELECT 'v23 bl merchant npc (expect 1)' AS what, COUNT(*) AS value FROM npc_types WHERE id = 1120001300;
SELECT 'v23 bl scrolls (expect 38)' AS what, COUNT(*) AS value FROM merchantlist WHERE merchantid = 1120001300;

-- ---- v18 / v24: merchant spawns --------------------------------------------
SELECT 'v24 spawngroups (expect 2)' AS what, COUNT(*) AS value FROM spawngroup WHERE name IN ('fv_Beastlord_Spell_Merchant','ot_Beastlord_Spell_Merchant');
SELECT 'v24 spawn2 rows (expect 2)' AS what, COUNT(*) AS value FROM spawn2 WHERE spawngroupID IN (SELECT id FROM spawngroup WHERE name IN ('fv_Beastlord_Spell_Merchant','ot_Beastlord_Spell_Merchant'));

-- ---- v18 / v25: data payload ------------------------------------------------
SELECT 'v25 whitelist has aa516 (expect 1)' AS what, COUNT(*) AS value FROM rule_values WHERE rule_name = 'Custom:AA339Whitelist' AND rule_value LIKE '%aa516%';
SELECT 'v25 bl GMs class (expect 34,34)' AS what, GROUP_CONCAT(class) AS value FROM npc_types WHERE id IN (93152, 84202);

-- ---- v19 / v22: factions + rules --------------------------------------------
SELECT 'v19 factions (expect 929,929,929,929)' AS what, GROUP_CONCAT(npc_faction_id) AS value FROM npc_types WHERE id IN (46016,46017,46061,46089);
SELECT 'v19 faction 2000507 (expect 79)' AS what, npc_faction_id AS value FROM npc_types WHERE id = 2000507;
SELECT 'v19 buy cost mod (expect 1.0)' AS what, rule_value AS value FROM rule_values WHERE rule_name = 'Merchant:BuyCostMod';
SELECT 'v19 db_str 15594 fixed (expect 1)' AS what, COUNT(*) AS value FROM db_str WHERE id = 15594 AND type = 4 AND value LIKE '%additional damage%';

-- ---- v20: Sateal in the Bazaar -----------------------------------------------
SELECT 'v20 sateal titled (expect 1)' AS what, COUNT(*) AS value FROM npc_types WHERE name = 'Sateal_Deirosap' AND lastname = 'Smithing Supplies';

-- ---- v21 / v22: data payload --------------------------------------------------
SELECT 'v22 bazaar cancombat (expect 0,0)' AS what, GROUP_CONCAT(cancombat) AS value FROM zone WHERE short_name = 'bazaar';
SELECT 'v22 bazaar safe_x (expect -134.13 x2)' AS what, GROUP_CONCAT(safe_x) AS value FROM zone WHERE short_name = 'bazaar';
SELECT 'v22 hastened AA (expect 1600,2000)' AS what, GROUP_CONCAT(base1) AS value FROM aa_rank_effects WHERE rank_id IN (12899,12900) AND slot = 1 AND base2 = 57;
SELECT 'v22 aa next_id (expect -1)' AS what, next_id AS value FROM aa_ranks WHERE id = 12900;
SELECT 'v22 quegmor moved (expect -76.12)' AS what, ROUND(z,2) AS value FROM spawn2 WHERE id = 14745;

-- ---- v27 / v28: Fabled season schema + roster seed ---------------------------
-- fabled_season is the single operational row world owns; fabled_npcs is filled by the loose
-- utils/sql/fabled_roster_seed.sql (not a migration - see CODEBASE.md 4.4), expected value is
-- the row count printed in that file's header.
SELECT 'v28 fabled_season rows (expect 1)' AS what, COUNT(*) AS value FROM fabled_season;
SELECT 'v28 fabled_season seed id (expect 1)' AS what, MIN(id) AS value FROM fabled_season;
SELECT 'v27 fabled_npcs seeded (expect 472)' AS what, COUNT(*) AS value FROM fabled_npcs;

-- ---- v33: shared-bucket loot schema (empty until seed is applied) -----------
SELECT 'v33 nms_loot_buckets (expect 1)' AS what, COUNT(*) AS value
  FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name = 'nms_loot_buckets';
SELECT 'v33 nms_loot_bucket_npcs (expect 1)' AS what, COUNT(*) AS value
  FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name = 'nms_loot_bucket_npcs';
SELECT 'v33 nms_loot_bucket_items (expect 1)' AS what, COUNT(*) AS value
  FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name = 'nms_loot_bucket_items';

-- ---- v34: Mastery of the Past ranks 7-9 ------------------------------------
SELECT 'v34 mastery rank 7061 open (expect 1)' AS what, COUNT(*) AS value
  FROM aa_ranks WHERE id = 7061 AND level_req <= 70 AND expansion = 8;

-- ---- v35: vault player table -----------------------------------------------
SELECT 'v35 character_nms_vault (expect 1)' AS what, COUNT(*) AS value
  FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name = 'character_nms_vault';
SELECT 'v35 vault.slot (expect 1)' AS what, COUNT(*) AS value
  FROM information_schema.columns
  WHERE table_schema = DATABASE() AND table_name = 'character_nms_vault' AND column_name = 'slot';
SELECT 'v35 vault.bag_slot (expect 1)' AS what, COUNT(*) AS value
  FROM information_schema.columns
  WHERE table_schema = DATABASE() AND table_name = 'character_nms_vault' AND column_name = 'bag_slot';
SELECT 'v35 vault primary key named cols (expect 3)' AS what, COUNT(*) AS value
  FROM information_schema.statistics
  WHERE table_schema = DATABASE() AND table_name = 'character_nms_vault'
    AND index_name = 'PRIMARY'
    AND column_name IN ('character_id', 'slot', 'bag_slot');
SELECT 'v35 vault primary key total cols (expect 3)' AS what, COUNT(*) AS value
  FROM information_schema.statistics
  WHERE table_schema = DATABASE() AND table_name = 'character_nms_vault'
    AND index_name = 'PRIMARY';
SELECT 'v35 vault unique indexes (expect 1)' AS what, COUNT(DISTINCT index_name) AS value
  FROM information_schema.statistics
  WHERE table_schema = DATABASE() AND table_name = 'character_nms_vault'
    AND non_unique = 0;

-- ---- v36: loot-offer player table ------------------------------------------
SELECT 'v36 character_nms_loot_offers (expect 1)' AS what, COUNT(*) AS value
  FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name = 'character_nms_loot_offers';

-- ---- v37: offer corpse_serial ----------------------------------------------
SELECT 'v37 loot_offers.corpse_serial (expect 1)' AS what, COUNT(*) AS value
  FROM information_schema.columns
  WHERE table_schema = DATABASE() AND table_name = 'character_nms_loot_offers' AND column_name = 'corpse_serial';

-- ---- v38: durable corpse_serial --------------------------------------------
SELECT 'v38 loot_offers.corpse_serial bigint unsigned (expect 1)' AS what, COUNT(*) AS value
  FROM information_schema.columns
  WHERE table_schema = DATABASE() AND table_name = 'character_nms_loot_offers'
    AND column_name = 'corpse_serial' AND data_type = 'bigint'
    AND column_type LIKE '%unsigned%';

-- ---- v39: instance + pass tombstone ----------------------------------------
SELECT 'v39 loot_offers.instance_id (expect 1)' AS what, COUNT(*) AS value
  FROM information_schema.columns
  WHERE table_schema = DATABASE() AND table_name = 'character_nms_loot_offers'
    AND column_name = 'instance_id';
SELECT 'v39 loot_offers.passed (expect 1)' AS what, COUNT(*) AS value
  FROM information_schema.columns
  WHERE table_schema = DATABASE() AND table_name = 'character_nms_loot_offers'
    AND column_name = 'passed';

-- ---- v40: passer name for client name2 -------------------------------------
SELECT 'v40 loot_offers.passed_from (expect 1)' AS what, COUNT(*) AS value
  FROM information_schema.columns
  WHERE table_schema = DATABASE() AND table_name = 'character_nms_loot_offers'
    AND column_name = 'passed_from';

-- ---- v41: vault per-instance item state -------------------------------------
-- Without these six columns a vault round trip silently returned a different item than the
-- one deposited (attunement, ornamentation and custom_data were dropped), and every vault
-- SELECT/REPLACE now references them - EnsureTables keeps the vault disabled until they exist.
SELECT 'v41 vault instance columns (expect 6)' AS what, COUNT(*) AS value
  FROM information_schema.columns
  WHERE table_schema = DATABASE() AND table_name = 'character_nms_vault'
    AND column_name IN ('instnodrop', 'custom_data', 'ornament_icon',
                        'ornament_idfile', 'ornament_hero_model', 'guid');


-- ---- v42: learned spell/disc/mem carry-over -----------------------------------
-- The spec change hides class-illegal spells instead of deleting them; without these three
-- tables a spec change permanently loses every spell and discipline the character learned.
SELECT 'v42 learned carry-over tables (expect 3)' AS what, COUNT(*) AS value
  FROM information_schema.tables
  WHERE table_schema = DATABASE()
    AND table_name IN ('character_learned_spells', 'character_learned_discs',
                       'character_learned_mem');

-- ---- v43: Armarium inventory clicky ----------------------------------------
-- Identity is items.id 9011013. Runtime matching is id >= 9011013 AND
-- id % 1000000 = 11013 so stock 11013 (Boots of Quickness) is not Armarium.
-- norent must be nonzero (1): NoRent == 0 is deleted after a long camp.
SELECT 'v43 armarium item (expect 1)' AS what, COUNT(*) AS value
  FROM items WHERE id = 9011013 AND Name = 'Armarium';
SELECT 'v43 armarium norent (expect 1)' AS what, norent AS value
  FROM items WHERE id = 9011013;
SELECT 'v43 armarium nodrop (expect 0)' AS what, nodrop AS value
  FROM items WHERE id = 9011013;
SELECT 'v43 armarium notransfer (expect 1)' AS what, notransfer AS value
  FROM items WHERE id = 9011013;
SELECT 'v43 armarium fvnodrop (expect 1)' AS what, fvnodrop AS value
  FROM items WHERE id = 9011013;
SELECT 'v43 armarium itemclass (expect 0)' AS what, itemclass AS value
  FROM items WHERE id = 9011013;
SELECT 'v43 armarium itemtype (expect 33)' AS what, itemtype AS value
  FROM items WHERE id = 9011013;
SELECT 'v43 armarium bagslots (expect 0)' AS what, bagslots AS value
  FROM items WHERE id = 9011013;
SELECT 'v43 armarium clicktype (expect 1)' AS what, clicktype AS value
  FROM items WHERE id = 9011013;
SELECT 'v43 armarium clickeffect (expect 1)' AS what, clickeffect AS value
  FROM items WHERE id = 9011013;
SELECT 'v43 armarium clickname (expect Open Armarium)' AS what, clickname AS value
  FROM items WHERE id = 9011013;
SELECT 'v43 armarium casttime (expect 0)' AS what, casttime AS value
  FROM items WHERE id = 9011013;
SELECT 'v43 armarium maxcharges (expect -1)' AS what, maxcharges AS value
  FROM items WHERE id = 9011013;
SELECT 'v43 armarium loregroup (expect -1)' AS what, loregroup AS value
  FROM items WHERE id = 9011013;
SELECT 'v43 armarium attuneable (expect 0)' AS what, attuneable AS value
  FROM items WHERE id = 9011013;
SELECT 'v43 armarium slots (expect 0)' AS what, slots AS value
  FROM items WHERE id = 9011013;
SELECT 'v43 armarium book (expect 0)' AS what, book AS value
  FROM items WHERE id = 9011013;
SELECT 'v43 armarium bagtype (expect 0)' AS what, bagtype AS value
  FROM items WHERE id = 9011013;
SELECT 'v43 clone source 9011010 (expect 1)' AS what, COUNT(*) AS value
  FROM items WHERE id = 9011010;

-- ---- v44: Firiona Vie + attune loop ----------------------------------------
-- Player schema (rule_values). Expect 1 (all players) or 2 (GM only) on the
-- active ruleset: RuleSet variable, else rule_sets 'default', else id 1.
SELECT 'v44 World:FVNoDropFlag active (expect 1 or 2)' AS what, rv.rule_value AS value
  FROM rule_values rv
 WHERE rv.rule_name = 'World:FVNoDropFlag'
   AND rv.ruleset_id = COALESCE(
     (SELECT rs.ruleset_id FROM rule_sets rs
       INNER JOIN variables v ON v.varname = 'RuleSet' AND v.value = rs.`name`
       LIMIT 1),
     (SELECT rs.ruleset_id FROM rule_sets rs WHERE rs.`name` = 'default' LIMIT 1),
     1
   )
 LIMIT 1;

-- Absence probe: the value SELECT above returns NO ROW when the rule is missing on
-- the active ruleset, which reads identically to 'this file was never run'. COUNT(*)
-- always returns exactly one row, so 0 is unambiguous.
SELECT 'v44 World:FVNoDropFlag row present (expect 1)' AS what, COUNT(*) AS value
  FROM rule_values rv
 WHERE rv.rule_name = 'World:FVNoDropFlag'
   AND rv.ruleset_id = COALESCE(
     (SELECT rs.ruleset_id FROM rule_sets rs
       INNER JOIN variables v ON v.varname = 'RuleSet' AND v.value = rs.`name`
       LIMIT 1),
     (SELECT rs.ruleset_id FROM rule_sets rs WHERE rs.`name` = 'default' LIMIT 1),
     1
   );

-- ---- v45: Armarium / vault rule on ----------------------------------------
-- Player schema (rule_values). Expect true or 1 on the active ruleset.
SELECT 'v45 Custom:DimensionalVault active (expect true or 1)' AS what, rv.rule_value AS value
  FROM rule_values rv
 WHERE rv.rule_name = 'Custom:DimensionalVault'
   AND rv.ruleset_id = COALESCE(
     (SELECT rs.ruleset_id FROM rule_sets rs
       INNER JOIN variables v ON v.varname = 'RuleSet' AND v.value = rs.`name`
       LIMIT 1),
     (SELECT rs.ruleset_id FROM rule_sets rs WHERE rs.`name` = 'default' LIMIT 1),
     1
   )
 LIMIT 1;

-- Absence probe: the value SELECT above returns NO ROW when the rule is missing on
-- the active ruleset, which reads identically to 'this file was never run'. COUNT(*)
-- always returns exactly one row, so 0 is unambiguous.
SELECT 'v45 Custom:DimensionalVault row present (expect 1)' AS what, COUNT(*) AS value
  FROM rule_values rv
 WHERE rv.rule_name = 'Custom:DimensionalVault'
   AND rv.ruleset_id = COALESCE(
     (SELECT rs.ruleset_id FROM rule_sets rs
       INNER JOIN variables v ON v.varname = 'RuleSet' AND v.value = rs.`name`
       LIMIT 1),
     (SELECT rs.ruleset_id FROM rule_sets rs WHERE rs.`name` = 'default' LIMIT 1),
     1
   );


-- ---- v46 (content) / v47 (player): Echo of Memory -> Emperor's Favor rename ---
-- v46 writes items and db_str; v47 writes rule_values, data_buckets and saylink. Each
-- probe below is labelled with the version that actually delivers it, so a failure names
-- the right half.
-- The rename spans the item, the alt-currency window label and the five rule keys. The
-- dangerous half is rule_values: the binary looks up Custom:EmperorsFavor*, so if the rows
-- kept their old names every one of those rules silently falls back to its compiled default
-- and any operator tuning is ignored with nothing logged.
SELECT 'v46 item 46779 renamed (expect 1)' AS what, COUNT(*) AS value
  FROM items WHERE id = 46779 AND Name = 'Emperor''s Favor';

SELECT 'v46 alt-currency label rows (expect 2)' AS what, COUNT(*) AS value
  FROM db_str WHERE id = 6 AND type IN (17, 18) AND value = 'Emperor''s Favor';

SELECT 'v47 renamed rule keys (expect 5)' AS what, COUNT(*) AS value
  FROM rule_values WHERE rule_name IN (
    'Custom:EmperorsFavorDropChance',
    'Custom:EmperorsFavorUnlockCharacterSets',
    'Custom:EmperorsFavorUnlockCharacterSetCost',
    'Custom:EmperorsFavorUnlockCharacterSlots',
    'Custom:EmperorsFavorUnlockCharacterSlotCost');

SELECT 'v47 stale EoM rule keys (expect 0)' AS what, COUNT(*) AS value
  FROM rule_values WHERE rule_name LIKE 'Custom:EoM%' OR rule_name = 'Custom:EventEOMDropChance';

SELECT 'v47 stale EoM award buckets (expect 0)' AS what, COUNT(*) AS value
  FROM data_buckets WHERE `key` = 'EoM-Award';


-- ---- v48: Armarium lore fits items.lore ------------------------------------
-- items.lore is varchar(80). v43 originally wrote 101 characters: a strict server
-- aborted the whole manifest with error 1406, a lenient one truncated mid-word. v43
-- now writes the 77-character text and v48 repairs anything already cut. A 0 here
-- means the item is carrying truncated or stale lore.
SELECT 'v48 armarium lore correct (expect 1)' AS what, COUNT(*) AS value
  FROM items
 WHERE id = 9011013
   AND lore = 'A bound key to your Armarium. Right-click to open storage, bank and merchant.';

-- Nothing anywhere may exceed the column. A nonzero value is a truncated row.
SELECT 'v48 overlong armarium lore (expect 0)' AS what, COUNT(*) AS value
  FROM items
 WHERE Name = 'Armarium' AND CHAR_LENGTH(lore) > 80;


-- ---- v49: Favor world buff spells rename -----------------------------------
-- Renames the 9 custom 'Echo of' server buffs to 'Favor of'.
-- spells_new is content schema.
SELECT 'v49 favor spells renamed (expect 9)' AS what, COUNT(*) AS value
  FROM spells_new
 WHERE id IN (17779, 36856, 43002, 43003, 43004, 43005, 43006, 43007, 43008)
   AND name IN (
     'Favor of Luck',
     'Favor of Power',
     'Favor of Experience',
     'Favor of Aegolism',
     'Favor of Focus',
     'Favor of Selo',
     'Favor of Koadic',
     'Favor of the Brood',
     'Favor of the Grove'
   );

SELECT 'v49 stale echo buff spells (expect 0)' AS what, COUNT(*) AS value
  FROM spells_new
 WHERE id IN (17779, 36856, 43002, 43003, 43004, 43005, 43006, 43007, 43008)
   AND name LIKE 'Echo of %';


-- ---- v50: saylink cache favor spell cleanup --------------------------------
SELECT 'v50 stale echo spell saylinks (expect 0)' AS what, COUNT(*) AS value
  FROM saylink
 WHERE phrase IN ('#find item echo of power', '#find spell echo of selo');


-- ---- v51: NPC renames (Apocrypha -> Decimus, Vision of Ayonae -> Lady Lachesis)
SELECT 'v51 Decimus npc (expect 1)' AS what, COUNT(*) AS value
  FROM npc_types WHERE id = 1120001125 AND name = 'Decimus';

SELECT 'v51 Lady Lachesis npc (expect 1)' AS what, COUNT(*) AS value
  FROM npc_types WHERE id = 151063 AND name = 'Lady_Lachesis' AND lastname = 'the Measurer';

SELECT 'v51 stale Apocrypha npc (expect 0)' AS what, COUNT(*) AS value
  FROM npc_types WHERE id = 1120001125 AND name = 'Apocrypha';

SELECT 'v51 stale Vision of Ayonae npc (expect 0)' AS what, COUNT(*) AS value
  FROM npc_types WHERE id = 151063 AND name = 'Vision_of_Ayonae';

SELECT 'v51 Decimus spawngroup (expect 1)' AS what, COUNT(*) AS value
  FROM spawngroup WHERE id = 5003653 AND name = 'bazaar_Decimus000_681750305';


-- ---- v52: saylink cache Apocrypha cleanup ----------------------------------
SELECT 'v52 stale Apocrypha saylinks (expect 0)' AS what, COUNT(*) AS value
  FROM saylink WHERE phrase IN ('#goto Apocrypha', '#summon Apocrypha');


