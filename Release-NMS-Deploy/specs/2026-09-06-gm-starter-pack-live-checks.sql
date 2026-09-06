-- GM starter pack (#gmpack): checks to run against the LIVE content database.
-- Section A runs BEFORE merging/deploying; sections B and C after world has applied custom v30/v31
-- and shared_memory has been rerun. Nothing here writes.

-- ---------------------------------------------------------------------------------------------
-- A. Before deploy: the box id must still be free, and the clone source must exist.
-- ---------------------------------------------------------------------------------------------
-- Expect: 9011010 (Satchel of the Hero) and 9011011 present; 9011012 absent. If 9011012 is taken,
-- pick the next free id in the block and change BOTH the v30 entry and the v31 'box' seed row.
SELECT id, Name, bagslots, bagsize, bagwr, bagtype, nodrop, norent
FROM items
WHERE id BETWEEN 9011000 AND 9011999
ORDER BY id;

-- Expect: exactly one row, the Legendary sword (2017731 in the release dump). The v31 seed picks
-- the highest id >= 2000000 whose name starts with this; if none, the worn box just lacks it.
SELECT id, Name FROM items WHERE Name LIKE 'Sword of Truth, Reforged%' AND id >= 2000000 ORDER BY id DESC;

-- ---------------------------------------------------------------------------------------------
-- B. After migrate + shared_memory: the migration landed completely.
-- ---------------------------------------------------------------------------------------------
-- Expect: 31 (or whatever the branch was renumbered to at merge time).
SELECT custom_version FROM db_version;

-- Expect: one row, 40 / 4 / 100 / 5 / 0 / 1 (40 slots, giant, WR 100, bag type 5, NO DROP, NO RENT).
SELECT id, Name, lore, bagslots, bagsize, bagwr, bagtype, nodrop, norent, weight, size
FROM items WHERE id = 9011012;

-- Expect: 1 box, 20 worn (19 + the sword lookup), 14 extras, 12 weapons, 28 clickies.
SELECT bag, COUNT(*) AS rows_, SUM(count) AS items_
FROM nms_gm_starter_pack GROUP BY bag ORDER BY FIELD(bag, 'box', 'worn', 'extras', 'weapons', 'clickies');

-- Expect: no rows. Any row here is a seed id the item table does not have; #gmpack skips it and
-- prints it, but it means the list needs a corrected id.
SELECT s.bag, s.item_id, s.note
FROM nms_gm_starter_pack s
LEFT JOIN items i ON i.id = s.item_id
WHERE i.id IS NULL;

-- Expect: no rows. count 2 is only meant for non-lore items; a lore item with count 2 is placed once.
SELECT s.bag, s.item_id, s.note, i.loregroup
FROM nms_gm_starter_pack s
JOIN items i ON i.id = s.item_id
WHERE s.count > 1 AND i.loregroup <> 0;

-- ---------------------------------------------------------------------------------------------
-- C. In game (GM account, status >= 200, #gm on to target another client)
-- ---------------------------------------------------------------------------------------------
-- 1. With three free general slots: #gmpack            -> three GM Starter Boxes (worn, weapons, clickies).
-- 2. #gmpack extras                                     -> a fourth box.
-- 3. Open each box in the client: 40 slots render, every item listed above is present, the
--    Staff of Forbidden Rites (2011608) shows its full charge count (50 in the release dump).
-- 4. Run #gmpack again: every lore item is reported as skipped; only the non-lore duplicates land.
-- 5. Fill every general slot, run #gmpack: the box goes to the cursor (the cursor is a queue).
-- 6. Optional: INSERT a bogus row (bag 'weapons', item_id 999999999), run #gmpack weapons,
--    confirm "missing from item store" and no crash, then DELETE the row.
