# Hero catch-up — exp pool must stay the trailing row, capped at 70

2026-09-07. Fixes live B3. Governs the `SetEXP` / login cache when `Custom:HeroCatchupEnabled` is on. Does not change water-fill or add/remove class.

## Symptom

Other Chat / zone logs, twice on zone-in (Wall of Slaughter, 2026-09-07):

`[Error] [SetEXP] Class exp pool for [<name>] was [1837382400] but the lowest class row is [1398659552], repairing the pool`

`1837382400` is `GetEXPForLevel(85)` — the `Character:KeepLevelOverMax` freeze point for a level-84 body. `1398659552` is a held class row at level 77. Table is `character_class_exp`.

The repair in `Client::SetEXP` is correct (pool must equal the lowest active row). It was logging Error because `KeepLevelOverMax` kept writing the watermark back into the pool.

## Cause

`Character:MaxExpLevel` is 70. `KeepLevelOverMax` was on, so a catch-up character over that cap kept:

- `character_data.exp` / `m_pp.level` at the watermark (84)
- at least one `character_class_exp` row behind (77)

Login and the `SetEXP` stock tail then rewrote the pool to `GetEXPForLevel(GetLevel()+1)` instead of the trailing row. The login-time `character_data` `UpdateOne` persisted the stale FindOne snapshot.

## Decision

Keep the invariant: pool = min(active rows). Do not delete the repair.

The displayed and stored cap is **70** (`Character:MaxExpLevel` / `Character:MaxLevel`):

- Over-cap class rows are pulled down to the last exp that still derives as 70
- Catch-up finishes at 70, not at a leftover 84 watermark
- After a route, clamp `set_exp` and the derived level down to 70; do not raise them via `KeepLevelOverMax`
- Login clamps rows, then assigns the trailing row to the pool
- The login-time `UpdateOne` writes the in-memory pool, not the stale snapshot
- `KeepLevelOverMax` defaults **false**; `MaxLevel` defaults **70**

A class still behind 70 (for example 50) stays behind; only values above the cap move.

Live `rule_values` can still pin `KeepLevelOverMax` true or `MaxLevel` above 70. The catch-up path clamps to `MaxExpLevel` regardless.

## Acceptance closures (2026-09-07 review)

- `#level` and quest/Lua `SetLevel(..., true)` clamp to `GetExpLevelCap()` (70 by default). The `#level` handler parses the requested level as `int` (same as `#hero set` / `setall`) and rejects a client target outside `1..MaxLevel` **before** narrowing to `uint8`, so values such as `326` (70 modulo 256) are refused. NPC targets stay uncapped within `1..255`.
- Rule-off login (`HeroCatchupEnabled=false`) still applies the stock `CharMaxLevel` tail after a `KeepLevelOverMax` watermark freeze. `ApplyExpClamps` shares that helper with `SetEXP`, so a non-GM cannot remain over their bucket. The hard-cap branch already includes the bucket via `GetExpLevelCap` and is left alone so hero-on routing does not snap to the start of the bucket.

## Not

- B1 (spellbook size) or B2 (AA expansion refuse)
- Soft catch-up (header stays at 84 while a class is behind)
