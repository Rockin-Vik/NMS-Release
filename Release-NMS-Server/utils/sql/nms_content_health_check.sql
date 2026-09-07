-- ============================================================================
-- NMS content health check - verifies the DATA every custom-manifest version
-- (v18 through v41) is supposed to deliver, without trusting db_version.
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
-- READ-ONLY: SELECT/SHOW only. Safe on any server, any number of times.
-- ============================================================================

SELECT 'db_version (expect 41 once current)' AS what, custom_version AS value FROM db_version LIMIT 1;

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
