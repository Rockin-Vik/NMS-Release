-- Hero catch-up live database checks.
-- Run after deploying this branch and starting world once.

-- Expect exactly one row with custom_version = CUSTOM_BINARY_DATABASE_VERSION from common/version.h (33 as of 2026-09-06; the class-exp entries landed as v29/v30).
SELECT custom_version
FROM db_version;

-- Expect character_class_exp to exist.
SHOW TABLES LIKE 'character_class_exp';

-- Expect a non-negative row count; it should cover every class bit held by every character.
SELECT COUNT(*) AS character_class_exp_rows
FROM character_class_exp;

-- Expect 0 rows: every set GestaltClasses bit (or fallback character_data.class) has a class-exp row.
SELECT cd.id AS character_id, classes.class_id
FROM character_data cd
LEFT JOIN data_buckets db ON db.character_id = cd.id AND db.`key` = 'GestaltClasses'
CROSS JOIN (
	SELECT 1 AS class_id UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4
	UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8
	UNION ALL SELECT 9 UNION ALL SELECT 10 UNION ALL SELECT 11 UNION ALL SELECT 12
	UNION ALL SELECT 13 UNION ALL SELECT 14 UNION ALL SELECT 15 UNION ALL SELECT 16
) classes
LEFT JOIN character_class_exp e ON e.character_id = cd.id AND e.class_id = classes.class_id
WHERE ((IF(db.character_id IS NOT NULL, CAST(db.`value` AS UNSIGNED), IF(cd.`class` BETWEEN 1 AND 16, 1 << (cd.`class` - 1), 0)) >> (classes.class_id - 1)) & 1) = 1
  AND e.character_id IS NULL;

-- Expect 0 rows: profile exp equals every held class exp. Any result is repaired by the login fallback on next zone-in.
SELECT cd.id AS character_id, cd.exp AS profile_exp, MIN(e.class_exp) AS minimum_class_exp, MAX(e.class_exp) AS maximum_class_exp
FROM character_data cd
JOIN character_class_exp e ON e.character_id = cd.id
GROUP BY cd.id, cd.exp
HAVING cd.exp <> MIN(e.class_exp) OR cd.exp <> MAX(e.class_exp);

-- Expect these rows only when operators have explicitly overridden compiled defaults.
-- Absence means the compiled defaults apply: MaxMulticlasses=4, HeroCatchupEnabled=false, NewClassStartLevel=1.
-- A Custom:HeroCatchupEnabled row set to true in rule_values re-enables the reset; remove it or set it to false.
SELECT ruleset_id, rule_name, rule_value, notes
FROM rule_values
WHERE rule_name IN (
	'Custom:MaxMulticlasses',
	'Custom:HeroCatchupEnabled',
	'Custom:NewClassStartLevel'
)
ORDER BY ruleset_id, rule_name;

-- Inspect the ruleset whose id must be reused for overrides.
SELECT ruleset_id
FROM rule_values
WHERE rule_name = 'Custom:MulticlassingEnabled';

-- To set overrides, replace the example values as needed. This reuses MulticlassingEnabled's ruleset id.
-- INSERT INTO rule_values (ruleset_id, rule_name, rule_value, notes)
-- SELECT ruleset_id, 'Custom:MaxMulticlasses', '4', 'Hero catch-up class cap'
-- FROM rule_values WHERE rule_name = 'Custom:MulticlassingEnabled'
-- ON DUPLICATE KEY UPDATE rule_value = VALUES(rule_value), notes = VALUES(notes);
-- INSERT INTO rule_values (ruleset_id, rule_name, rule_value, notes)
-- SELECT ruleset_id, 'Custom:HeroCatchupEnabled', 'true', 'Enable hard catch-up'
-- FROM rule_values WHERE rule_name = 'Custom:MulticlassingEnabled'
-- ON DUPLICATE KEY UPDATE rule_value = VALUES(rule_value), notes = VALUES(notes);
-- INSERT INTO rule_values (ruleset_id, rule_name, rule_value, notes)
-- SELECT ruleset_id, 'Custom:NewClassStartLevel', '1', 'New class catch-up start level'
-- FROM rule_values WHERE rule_name = 'Custom:MulticlassingEnabled'
-- ON DUPLICATE KEY UPDATE rule_value = VALUES(rule_value), notes = VALUES(notes);

-- Expect no rows, or only rows whose value is 'false': the old class-exp penalties are incompatible with catch-up.
SELECT ruleset_id, rule_name, rule_value, notes
FROM rule_values
WHERE rule_name = 'Character:UseOldClassExpPenalties';

-- VPS test with a non-GM 3-class character:
-- 1. Add a fourth class at the guildmaster.
-- 2. Confirm the new class joins at the character's current level.
-- 3. Confirm the Inventory header shows the class list and effective level.
-- 4. Kill for experience.
-- 5. As a GM on that target, use #hero show and confirm every class row shadows the pool.
-- 6. Confirm the character receives its group experience share.
-- 7. Remove the new class and confirm the effective level does not change.
-- 8. Confirm an Ayonae reroll joins replacement classes at the watermark.
