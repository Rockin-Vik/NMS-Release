# Spellbook capacity + learned spells survive spec change

2026-09-07. Reviewed 2026-09-07 (REVISE applied: §2, §3.1–§3.3, §4, §8–§10; D9 note). Owner locked volume-view §4 and D12 the same day. Fixes live B1. Governs visible spellbook size, learned-spell persistence across add/remove class, and the matching disc/gem behavior.

Does not change which spells a class may scribe. Does not restore spells already deleted by today's `RemoveExtraClass`. Does not change gear eject, AA refund, or pet dismiss on class remove.

Parked note this replaces: `specs/local/2026-09-06-aa-classes-races-adr.md` §B1. Amends `2026-09-05-hero-catchup-multiclass-design.md` §5 (`RemoveExtraClass` unscribes; re-add does not restore).

**Do not implement on `hero-exp-pool-repair` or the B2 AA branch.** New branch after this spec is green.

## Symptom

Scribe fails with `Unable to scribe … no more spell book slots available.` (`zone/effects.cpp` after `GetNextAvailableSpellBookSlot()` returns `-1`).

Separately, changing specs forces a vendor trip and a remem: `Client::RemoveExtraClass` (`client.cpp` ~14746–14766) unmems, **unscribes**, and untrains anything the remaining classes cannot use. `SaveSpells()` then delete/rewrites `character_spells` from the live book. `AddExtraClass` does not put any of that back.

## Owner decisions (locked 2026-09-07)

| # | Decision | Why |
| --- | --- | --- |
| D1 | Once scribed (or a disc trained), it stays **learned**. Spec change may block **cast/use**. It must not force **rebuy or remem**. | Product. |
| D2 | Drop a class: those spells/discs **leave the book and gems**. They are not deleted. Take the class again: they **return**. | Owner: hide until the class is held again. |
| D3 | Server book is **2880** absolute slots. The client shows that as **four 90-page volumes** (`/book 1-4`), not one 360-page window. Do not ship a 720 stopgap. | Four live trainers must never hit the scribe wall. A flat 360-page book needs a `CSpellBookWnd` rewrite the DLL does not have offsets for (§4). |
| D4 | Learned set in the database is **uncapped** and is **not** `SaveSpells()` of the live book. | Today's delete/rewrite would wipe hidden spells. |
| D5 | Restore into the **next empty book slot**. Prefer the **same gem** if it is free, else the next empty gem. | Same-page restore collides when that slot was reused. Lowest-lift, fewest future bugs. |
| D6 | Shared spells stay visible if **any remaining class** can use them (`GetSpellLevel` `< 255`, `HasClass`, not `GetClass() ==`). | Do not hide Complete Heal because you dropped Cleric but still have Druid. |
| D7 | Player (or GM) **unscribe / untrain** is a real forget: drop from the learned set. Spec change is not an unscribe. | Stock "I deleted it from my book" still means rebuy. |
| D8 | Spells already wiped by past `RemoveExtraClass` stay gone. | The rows are not in the database. |
| D9 | Coordinated **server + DLL** deploy. Do not ship 2880 on the wire without the matching add-on. The server cannot fail closed on this: the profile is sent in `Handle_Connect_OP_ZoneEntry` before any add-on handshake (§4.4). | Stock CHARINFO2 cannot hold 2880 in place (see §4). |
| D10 | Client spike is **gate 0**. If the profile parser cannot consume 2880 dwords without corrupting mem/skills, **do not merge**. | Raising the server array alone is a client smash, not a partial win. |
| D11 | 2880 is sized to `Custom:MaxMulticlasses` **4**. Raising that cap later requires growing the visible book again. Knowledge still would not be lost (D4). | Honest limit. |
| D12 | Hide only spells **some player class can use** and **no held class can**. Spells/discs that no class 1–16 can use (every class level 255) stay in the window. Same for discs. | `#scribespell` / quest toys stay visible. Spec change still hides real class spells you no longer hold. |

## 1. Thesis

Two bugs, one contract:

1. **Capacity.** RoF2's live book is 720 slots. Four caster books do not fit.
2. **Forgetting.** `RemoveExtraClass` treats "cannot use" as "never learned."

The live window shows spells the **current** class mask can use, plus off-class GM/quest spells nobody can use (D12). The database remembers every spell the character has ever scribed (until they unscribe it themselves). Re-add and login fill empty pages from that set. The server book is 2880 slots so four full trainers do not stall. The RoF2 window shows one 720-slot volume at a time (`/book 1-4`).

## 2. Current wiring (do not guess)

| Piece | Where | Today |
| --- | --- | --- |
| Emu book size | `EQ::spells::SPELLBOOK_SIZE` via `emu_constants.h` → `RoF2::spells::SPELLBOOK_SIZE` | **720** (`rof2_limits.h`) |
| PP array | `m_pp.spell_book[]` (`eq_packet_structs.h`) | 720 × `uint32` |
| Live layout table | `character_spells` (`id` = character id, `slot_id`, `spell_id`) | `SaveSpells()` **deletes all rows** then inserts the live book (`client.cpp` ~13138) |
| Load | `ZoneDatabase::LoadCharacterSpellBook` (`zonedb.cpp` ~618) | Fills `pp->spell_book[slot_id]`; skips `slot_id` outside `0..SPELLBOOK_SIZE` **inclusive** (`ValueWithin`). Slot `720` would be OOB today. Load must become `slot_id < SPELLBOOK_SIZE`. |
| Scribe fail | `Client::MemorizeSpellFromItem` (`effects.cpp` ~1079) | `HasSpellScribed` then `GetNextAvailableSpellBookSlot()`; `-1` → the red line |
| Already-known | `Client::HasSpellScribed` (`client.h` ~1497) | `FindSpellBookSlotBySpellID != -1` (**visible book only**) |
| Hide on remove | `RemoveExtraClass` | `UnscribeSpell` / `UnmemSpellBySpellID` / `UntrainDisc` then `SaveSpells` / `SaveDisciplines` |
| Restore on add | `AddExtraClass` | **Nothing** for spells, discs, or gems |
| RoF2 encode | `rof2.cpp` ~2717 | Writes `spells::SPELLBOOK_SIZE` then that many `uint32`s. Client is assumed to read the **count**. |
| Delete-slot wire | `DeleteSpell_Struct.spell_slot` | `int16` — 2880 fits |
| Swap-slot wire | `SwapSpell_Struct` | `uint32` from/to |
| Client CHARINFO2 | `Release-NMS-Client/eqgame_dll/EQData.h` | `SpellBook[NUM_BOOK_SLOTS]`, `NUM_BOOK_SLOTS = 0x2d0` (**720**). Next field is `MemorizedSpells` at `0x3060` = `0x2520 + 720*4`. **Growing this array in place moves every later field.** |
| Disc PP | `MAX_PP_DISCIPLINES` in `eq_packet_structs.h` | **100**. RoF2 already encodes **300** and pads (`rof2.cpp` ~2683–2694). Four melee trainers can hit the 100 wall independently of the book. |
| Disc already-known | `HasDisciplineLearned` | Walks the live PP array only |
| Quest copy | `QUEST-API.md` `HasSpellScribed` | "Is spell in spellbook?" (`Release-NMS-Quests/QUEST-API.md` ~2034; `HasDisciplineLearned` ~2048) |
| Book size lookup | `EQ::spells::DynamicLookup(...)->SpellbookSize` (`eq_limits.cpp` ~1204, built from `RoF2::spells::SPELLBOOK_SIZE`) | Bounds for `Handle_OP_DeleteSpell`, `Handle_OP_SwapSpell`, and the `OP_DeleteSpell` send inside `UnscribeSpell`. Follows the constant; listed so nobody hardcodes 720 there. |
| Player delete | `Client::Handle_OP_DeleteSpell` (`client_packet.cpp` ~6243) | Clears the PP slot and calls `DeleteCharacterSpell` directly. **Does not go through `UnscribeSpell`.** |
| Drag-to-book scribe / mem gate | `Client::OPMemorizeSpell` (`client_process.cpp` ~1530–1550) | `memSpellScribing` calls `ScribeSpell(m->spell_id, m->slot)` with **no already-known check**; `memSpellMemorize` is gated by `HasSpellScribed`. |
| Disc window packet | `ENCODE(OP_DisciplineUpdate)` (`rof2.cpp` ~1175) | `ENCODE_LENGTH_EXACT(Disciplines_Struct)` + `memcpy` of `sizeof(Disciplines_Struct)` into the 300-slot RoF2 struct. Becomes exact once emu is 300. |
| Character save | `Client::Save()` | Does **not** call `SaveSpells` / `SaveDisciplines`. Only `ScribeSpells`, `LearnDisciplines`, `UnscribeSpellAll`, `UntrainDiscAll` and `RemoveExtraClass` rewrite the layout tables. |
| Login order | `Handle_Connect_OP_ZoneEntry` / `CompleteConnect` | `LoadCharacterSpellBook` + `LoadCharacterMemmedSpells` (~1465) run **before** `m_pp.classes` and `LoadClassExp()` (~1579); `OP_PlayerProfile` at ~1817. `LoadCharacterDisciplines` runs later, in `CompleteConnect` (~1028), **after** the profile. |
| Add-on check | `Handle_OP_CAuth` (`client_packet.cpp` ~5111), kick loop `client_process.cpp` ~773 | Validates `classes * id` only; **no build number**. Runs after zone-in; failure relocates to the Bazaar after ~11 tics, no disconnect. The profile has already been sent. |

`character_spells.slot_id` is `uint16` in the generated repository. 2880 fits. Do not hand-edit `base_character_spells_repository.h`.

## 3. Server contract

### 3.1 Two stores

**Learned set (source of truth for "do they know it"):**

```
character_learned_spells (character_id, spell_id)  PK (character_id, spell_id)
character_learned_discs  (character_id, spell_id)  PK (character_id, spell_id)
character_learned_mem    (character_id, spell_id, gem_slot)  PK (character_id, spell_id)
```

Player schema. Custom migration **v41**. `content_schema_update = false`. Bump `CUSTOM_BINARY_DATABASE_VERSION` to **41** in the same change (main is 40; v41 is free on main and on PRs 11, 12 and 13 as of 2026-09-07; renumber if any of them takes it first). Manifest entry: `.check = "SHOW TABLES LIKE 'character_learned_mem'"`, `.condition = "empty"`; SQL is three `CREATE TABLE IF NOT EXISTS` followed by the two `INSERT IGNORE`s below. The runner is not transactional and stops at the first error, so every statement must be safe to run again.

Backfill (same migration, idempotent):

```sql
INSERT IGNORE INTO character_learned_spells (character_id, spell_id)
SELECT id, spell_id FROM character_spells
WHERE spell_id IS NOT NULL;

INSERT IGNORE INTO character_learned_discs (character_id, spell_id)
SELECT id, disc_id FROM character_disciplines
WHERE disc_id IS NOT NULL AND disc_id <> 0;
```

No mem backfill. Gems already live in `character_memmed_spells`. `character_learned_mem` is only written when a gem is **hidden** on class remove.

**Visible layout (what the client book/disc window shows):**

- `character_spells` / `m_pp.spell_book[0..2879]` — current-class spells only.
- `character_disciplines` / `m_pp.disciplines.values[0..299]` after D14.

`SaveSpells()` / `SaveDisciplines()` stay "rewrite the live layout." They must never be the only copy of knowledge.

### 3.2 When the learned set changes

| Event | Learned | Visible book / discs / gems |
| --- | --- | --- |
| Scribe from scroll, `#scribespell`, quest `ScribeSpell` | Insert spell id | Next empty slot (existing path). `#scribespell` / quest `ScribeSpell` into an **occupied** slot unscribes the displaced spell (D7) |
| Train tome, quest train | Insert disc id | Next empty disc slot |
| Player delete from the book (`Handle_OP_DeleteSpell`), `#unscribespell`, `#untraindisc`, quest `UnscribeSpell*` / `UntrainDisc*` | **Delete** that id, whether or not it is currently visible | Clear the slot if visible (existing path) |
| `#unscribespells` / `UnscribeSpellAll` / `UntrainDiscAll` | **Clear** that character's learned rows | Clear the window |
| `RemoveExtraClass` | **No change** | Hide unusable (D2, D6); snapshot hidden gems into `character_learned_mem` |
| `AddExtraClass` | **No change** | Reconcile (§3.3) |
| Login / zone-in | **No change** | Reconcile (§3.3) |

`HasSpellScribed` and `HasDisciplineLearned` read the **learned set**, not the live window. Hidden spells return "already know" and must not consume a scroll.

`FindSpellBookSlotBySpellID` / `GetScribedSpells` stay **visible-book**. Quest `HasSpellScribed` means "ever learned, not forgotten," and `QUEST-API.md` must say that when this ships.

Cast, mem-from-book, and pet-from-book still require the spell to be in the **visible** book or on a gem. Hidden ⇒ cannot use. That is D1.

Consequences of moving `HasSpellScribed` / `HasDisciplineLearned` to the learned set (review 2026-09-07, each is a producer or consumer in the tree today):

- The `memSpellMemorize` case in `OPMemorizeSpell` is gated by `HasSpellScribed` today. It must switch to the **visible** book (`FindSpellBookSlotBySpellID != -1`), or a hidden spell can be memmed by packet and D1 is broken.
- The drag-to-book scribe (`OPMemorizeSpell`, `memSpellScribing`) has **no** already-known check today; only the item-click path (`MemorizeSpellFromItem`) has one. Add a learned-set check before `ScribeSpell` there with the same `You already know this spell.` line, or a hidden spell's scroll is consumed.
- `Handle_OP_DeleteSpell` is the player unscribe. It bypasses `UnscribeSpell`. It must also delete the learned row.
- `#unscribespell` / `#untraindisc` gate on `HasSpellScribed` / `HasDisciplineLearned` and then call `UnscribeSpellBySpellID` / `UntrainDiscBySpellID`, which only walk the visible window. The learned delete must happen even when the spell is hidden (do it in the `*BySpellID` helpers, and in `UnscribeSpell` / `UntrainDisc` for the slot forms).
- Hiding is **not** an unscribe (D7). `UnscribeSpell` fires `EVENT_UNSCRIBE_SPELL` and `UnscribeSpell` / `UntrainDisc` will now delete the learned row; the hide step in §3.3 needs its own slot-clear (or a flag) that skips both. It may still send `OP_DeleteSpell` / `SendDisciplineUpdate` to the client.
- `#scribespells` / quest `ScribeSpells` and `LearnDisciplines` use `HasSpellScribed` / `HasDisciplineLearned` to skip known spells and end with `SaveSpells` / `SaveDisciplines`. With the learned set they skip hidden spells (correct, D2) and still rewrite only the live layout. No change needed beyond the learned insert inside `ScribeSpell` / the disc train path.
- `TrainDiscipline` (tome click and NPC hand-in) and `TrainDiscBySpellID` write `m_pp.disciplines.values` and `SaveCharacterDiscipline` directly; both need the learned insert. `TrainDiscipline` already refuses known discs with `You already know this discipline.` via the PP walk; point that at the learned set.

### 3.3 Reconcile (one helper, three callers)

`Client::ReconcileLearnedSpells()` after the class mask is correct:

1. **Hide (D12).** Take a visible book/disc/gem off the window only when **some** class 1–16 can use it (`GetSpellLevel` `< 255`) **and no held class can**. Do not delete learned. If it was a gem, upsert `character_learned_mem`. Spells no class can use stay put.
2. **Show.** Every learned spell/disc that **is** usable and not already visible: `ScribeSpell` / train into `GetNextAvailable*Slot()` (D5). Do not reshuffle spells that are already on a page.
3. **Gems.** For each `character_learned_mem` row whose spell is now usable: if that `gem_slot` is empty, mem there; else next empty gem. Drop the row once it is on a gem (or if the spell is no longer learned).
4. Persist live layout (`SaveSpells`, `SaveDisciplines`, mem save). Send client book/disc/gem updates when `update_client` is true. `MemSpell` / `UnmemSpell` persist gems immediately; there is no separate mem dirty flag.

Call from `AddExtraClass` (after `m_pp.classes` is set, before its `Save()`, `update_client` true), `RemoveExtraClass` (replace the current unscribe/untrain block; the `SetBucket("GestaltClasses")` write just above it is the commit point, so a crash after it is repaired by the login call; `update_client` true), and **twice at login** with `update_client` **false**. Book/gem packets before `OP_PlayerProfile` hit the DLL while `g_nmsSpellBook` is still the previous zone and would forward in-volume `OP_DeleteSpell` / `OP_MemorizeSpell` into eqgame too early. The profile already carries the reconciled book. Discs load after the profile (`CompleteConnect` ~1028); pass `update_client` false there too (no per-slot disc spam) and still `SendDisciplineUpdate()` if the disc window changed. A single login call site does not exist today. The usable check goes through `GetClassesBits()` (falls back to `class_` when `Custom:MulticlassingEnabled` is off; `m_pp.classes` is never set at login in that case), not `m_pp.classes`.

If `LoadLearnedKnowledge` failed (`m_learned_ready` false), reconcile returns without hide or restore.

Usable by the current mask = any held class with `GetSpellLevel(spell_id, class_id) < UINT8_MAX`. Multiclass loops use `HasClass`. **Class-owned** = any class 1–16 has that level. Hide = class-owned and not usable by the current mask (D12). Show = learned and usable by the current mask and not already visible.

Remove still dismisses pets the remaining classes cannot own, ejects class-locked gear, and refunds unusable AAs. Those paths stay.

### 3.4 Visible size

Raise **RoF2 and emu** `SPELLBOOK_SIZE` to **2880**. `EQ::spells::SPELLBOOK_SIZE` aliases RoF2. Leave Titanium/SoF/SoD/UF/RoF limits at stock; this server is RoF2-only (`CODEBASE.md` §5).

`GetNextAvailableSpellBookSlot`, `ScribeSpell` bounds, `LoadCharacterSpellBook`, `SaveSpells`, and every `for (i < SPELLBOOK_SIZE)` walk follow the constant. Do not scatter `2880`.

`DeleteSpell_Struct.spell_slot` is `int16`. 2880 is in range. Keep using it.

### 3.5 Discs (same product rule, smaller wire)

Raise emu `MAX_PP_DISCIPLINES` from **100** to **300** so it matches the RoF2 count the encoder already writes. Then the pad loop in `rof2.cpp` is a no-op (`structs::MAX_PP_DISCIPLINES - MAX_PP_DISCIPLINES == 0`). Learned discs use `character_learned_discs` the same way as spells.

Train fail `You have learned too many disciplines and can learn no more.` (`effects.cpp` ~999) must not fire for a 4-class melee while 300 live slots remain.

Audit anything that `memcpy`s a whole `PlayerProfile_Struct` or hardcodes `100` disc slots before changing the PP field. Known consumers that follow the constant (verified 2026-09-07): `SaveDisciplines` (slot-range delete + `ReplaceMany`), `LoadCharacterDisciplines` (`slot_id < MAX_PP_DISCIPLINES`), `UntrainDisc*`, `GetNextAvailableDisciplineSlot`, `HasDisciplineLearned`, `TrainDiscipline` / `TrainDiscBySpellID`, `GetDiscSlotBySpellID`, and `ENCODE(OP_DisciplineUpdate)` (`memcpy` of `sizeof(Disciplines_Struct)` into the 300-slot RoF2 struct, exact after the raise). No `100` literal in the disc paths. `bot.cpp` does not use it.

### 3.6 Rules

No new Custom rule. Book size is a compile-time client contract, not a toggle.

When `MulticlassingEnabled` is false, `RemoveExtraClass` / `AddExtraClass` do not run. Learned inserts on scribe still happen so `HasSpellScribed` stays one path. Reconcile on login is cheap and still correct for a single class.

### 3.7 Fail-closed

- Missing learned tables: boot refuses when `auto_database_updates` is on (pending custom migration). If it is off and the three `character_learned_*` SELECTs fail, `LoadLearnedKnowledge` leaves `m_learned_ready` false and reconcile **must not hide**. Hiding against an empty learned set would unscribe the live book and then fail the learned INSERT. Do not "just use the book."
- Reconcile cannot place a usable learned spell because the visible book is full: log **Error** with character id, spell id, and used/2880. This is a product bug (D3 failed). Still do not delete the learned row.
- `SaveSpells` must not delete `character_learned_*`.

## 4. Client contract (the actual risk)

`eqgame.exe` is never modified (`CODEBASE.md` §5). The add-on is `dinput8.dll`.

**Do not enlarge `CHARINFO2.SpellBook` in `EQData.h`.** It is a mirror of eqgame's layout. `MemorizedSpells` sits immediately after 720 dwords (`0x2520 + 720*4 = 0x3060`, verified). Expanding in place desyncs mem, skills, and the rest of the profile.

Stock RoF2 reads a **count** then that many `uint32`s into a **720-slot** array (`rof2_structs.h` `spell_book_count // Seen 720`; the client-side loop is not decoded, see §4.2). Sending 2880 without a hook either overflows CHARINFO2 or leaves 2160 dwords in the stream for `mem_spells` / skills to ingest. Either way the client is wrong.

**What the DLL has today** (`eqgame_dll/eqgame.h`, 530 offsets): `pinstCSpellBookWnd`, `CSpellBookWnd::MemorizeSet`, `CSpellBookWnd::CanStartMemming`. No other `CSpellBookWnd` method has an address, no packet dispatch or send routine has one, and the profile deserializer has none. Every reader of the book in the window (`GetBookSlot`, `TurnToPage`, `HandleLeftClickOnSpell`, `HandleRightClickOnSpell`, `DeleteSpellFromBook`, `SwapSpellBookSlots`, `FinishScribing`, `FinishMemorizing`, `RequestSpellDeletion`, `AutoMemSpell`, the spell-set loader, draw) indexes `pPCData->SpellBook[]` inline. The earlier plan ("hook book UI / mem-from-book / delete / swap / scribe-finish so slots 720..2879 read the overflow") is a DLL rewrite of `CSpellBookWnd` with no offsets in hand, and the spike as written never exercised it. **Rejected.**

### 4.1 Required approach: overflow + volume view

The DLL owns the 2880-slot book. eqgame only ever sees a 720-slot **volume** of it, so no window code is hooked and no window code can index past 720.

1. `NUM_BOOK_SLOTS` / `CHARINFO2.SpellBook[720]` unchanged. `EQData.h` gets `NMS_SPELLBOOK_SIZE 2880` and `NMS_BOOK_VOLUME 720` for DLL use only.
2. DLL keeps `g_nmsSpellBook[2880]` (the book exactly as the server sent it, absolute slots) and `g_nmsBookVolume` (0..3, reset to 0 at zone-in).
3. **Profile compact (existing `HandleWorldMessage`, no new eqgame offset).** RoF2 writes Timestamp2 immediately before the book: dword `100`, then 100 zero dwords, then the book count, then that many spell dwords, then gem count `16`. Anchor the scan on that Timestamp2 block (4-byte aligned). This server sends count **2880** only; compact to 720 and copy the tail so eqgame never sees 2880 dwords. A 720 count after the same anchor is an old server: copy into `g_nmsSpellBook` and do not compact. Do **not** match a bare `720`/`2880` dword — AA rank 720 (Hastened Marr's Salvation) plus a skill of 16 is a false hit, and Pass without compact is the CHARINFO2 smash. If the anchor is missing: log (`OutputDebugString`); if the packet is large enough to be a 2880 profile (`>= 22000` bytes), **suppress** the packet (fail closed). Pass on a miss is the smash path.
4. **Inbound slot translation.** Server → client `OP_MemorizeSpell` (scribing = 0), `OP_DeleteSpell` and `OP_SwapSpell` carry absolute slots 0..2879 (`MemorizeSpell_Struct.slot` `uint32`, `DeleteSpell_Struct.spell_slot` `int16`, `SwapSpell_Struct` `uint32`; RoF2 has no ENCODE for any of the three, so emu struct = wire struct). Apply the change to `g_nmsSpellBook` first. If the slot is inside the active volume, rewrite it to `slot - volume*720` and let the stock handler run. If a **scribe echo** is outside the active volume, switch to that slot's volume and forward the relative packet — suppressing it strands client-side scribe state (`#scribespell`, quest scribe, item click, reconcile restore). Swap with one end inside and one outside: apply to the DLL copy, then refresh the visible volume from the copy instead of forwarding. Out-of-volume delete stays suppressed (no scribe echo).
5. **Outbound slot translation.** Client → server `OP_MemorizeSpell` (scribe case only; the mem/forget cases carry gem slots), `OP_DeleteSpell` and `OP_SwapSpell` carry volume-relative slots. Add `volume*720` before send. Nothing else on the client puts a book slot on the wire.
6. **Volume switch.** `/book <1-4>` sets the volume and copies that 720-slot window from `g_nmsSpellBook` into `CHARINFO2.SpellBook`. Stock `/book` **toggles** the window; if the book is already open, do not `InterpretCmd("/book")` — `Show(true)` if the window is visible, otherwise open. Page math stays stock: 90 pages per volume. No XML. `TurnToPage` / `GetSpellMemTicksLeft` have no offsets in `eqgame.h` and are not called. Switching while a scribe is in progress is refused (`g_scribeInProgress`, `g_scribeTimerActive`). Mem-in-progress is not gated: mem packets carry a spell id and gem, not a book slot, so the wire stays safe.
7. Existing scribe spoof in `Hooks.cpp` stays; it does not grant slots.
8. Server side is unchanged by any of this: 2880 absolute slots on the wire, `GetNextAvailableSpellBookSlot` fills from 0, so volume 1 fills first and a single-class character never needs `/book`.

Hook sites this needs: the profile book loop, the inbound handlers (or the one dispatch point) for the three opcodes, and the outbound send point used by `CSpellBookWnd` for the same three. None has an offset in `eqgame.h` today. Finding them is the spike.

D3 is met: the server book is 2880, every slot is reachable via `/book 1-4`, nothing is discarded. **Owner locked 2026-09-07:** volume view is the client contract. A flat 360-page book is out of this pass.

Stretch, not in this pass: turning past page 90 / before page 1 flips the volume; a "Vol. N" label on the window (`MQ2Labels.cpp` pattern).

### 4.2 Spike (gate 0) — do this first, before any server change

On a disposable RoF2 client with a debug DLL:

1. **Locate** and record in `eqgame.h`: the book-count loop in the profile deserializer; the inbound handlers for `OP_MemorizeSpell`, `OP_DeleteSpell`, `OP_SwapSpell` (or the dispatch point they hang off); the outbound send used by `CSpellBookWnd` for the same three.
2. A test encode (or a throwaway server build with the constant raised) writes count **2880** and 2880 dwords with sentinels at `[0]`, `[719]`, `[720]`, `[2879]`, then the normal mem-gem tail.
3. **Pass:** `MemorizedSpells`, skills and level match the character; all four sentinels are in `g_nmsSpellBook`; volume 1 shows `[0..719]`; `/book 4` shows `[2160..2879]` on pages 1–90; scribing a scroll while on volume 2 lands in the server's slot 720+ and `character_spells` has that row; delete and swap on volume 2 round-trip; `#scribespell` / item-click into a slot on another volume completes the client scribe (volume switches, echo is not suppressed); `/book 2` with the book already open does not close it; no crash on zone-in, on opening the book, or on switching volumes with the book open. The profile scanner must have taken the Timestamp2-anchored 2880 path (not a first-match 720).
4. **Fail:** any desync of the fields after the book, or a site that cannot be found or hooked. Stop. Report the exact site and why. Do not ship a server-only 2880. Do not invent a second wire format in the same pass.

### 4.3 UI XML

`Release-NMS-Client/ClientFiles` has no stock spellbook XML override today and this design needs none: each volume is a stock 90-page book.

### 4.4 Old add-on + new server

`Handle_OP_CAuth` (`client_packet.cpp` ~5111) validates `GetClassesBits() * GetID()` and carries **no build number**. It runs after zone-in, and on failure the loop at `client_process.cpp` ~773 relocates the client to the Bazaar after about 11 tics; it does not disconnect, and the Bazaar tolerates it. By then the 2880-slot `OP_PlayerProfile` has already gone out from `Handle_Connect_OP_ZoneEntry`. **The server cannot fail closed against an old add-on for this change.** The deploy ships server and DLL together and the DLL build is the gate. If fail-closed is wanted it is a separate spec: a build number sent before zone entry (the existing character-select exchange), stored where zone can read it before the profile encode, with the encoder falling back to a 720-slot profile for unknown builds.

## 5. Quest / plugin / GM

| Surface | After |
| --- | --- |
| `HasSpellScribed` / `HasDisciplineLearned` | Learned set |
| `GetScribedSpells` | Visible book only |
| `ScribeSpell` / `UnscribeSpell*` | Scribe inserts learned; unscribe deletes learned |
| `#scribespell` / `#unscribespell` / `#unscribespells` | Same |
| `#memspell` | Unchanged (gem write) |

Update `QUEST-API.md` on the one `HasSpellScribed` line.

## 6. Documentation when this ships

- `CODEBASE.md` §3.1 (multiclass) and §5 (client contract): 2880 book, volume view (`/book 1-4`), learned tables, coordinated DLL. Deploy is the old-add-on gate (§4.4).
- `custom-rules` README: no new rule; mention the book size only if a nearby Custom note already talks about multiclass client contract.
- Hero-catchup spec §5: delete "unscribes" / "re-add does not restore spells."
- Local ADR B1: point here, mark spec written.

## 7. Not

- Which spells a class can scribe or the level-free scribe QoL.
- Recovering spells deleted before the learned table existed.
- Same-page restore (rejected; D5).
- Showing dropped-class spells greyed out in the book (rejected; D2).
- Phase 2 class IDs 17–19, new races, AA expansion (B2), hero pool (B3).
- Persisting dismissed pets or ejected gear across spec change.
- Raising `MaxMulticlasses` above 4.
- Non-RoF2 patch files.
- Changing `eqgame.exe`.
- A flat 360-page spellbook window (no offsets; rejected §4).

## 8. Implementation order (one branch)

0. **Client spike** (§4.2). Stop if red.
1. Custom v41 tables + backfill + `CUSTOM_BINARY_DATABASE_VERSION`.
2. Learned insert/delete on scribe/unscribe/train/untrain. Point `HasSpellScribed` / `HasDisciplineLearned` at the set.
3. `ReconcileLearnedSpells`; wire add/remove and the two login sites (§3.3). **Stop deleting knowledge in `RemoveExtraClass`.** D12 is locked.
4. Raise `SPELLBOOK_SIZE` to 2880 and `MAX_PP_DISCIPLINES` to 300. RoF2 encode follows the constants.
5. DLL: profile hook + `g_nmsSpellBook` + inbound/outbound slot translation + `/book` (§4.1). Rebuild **Release/Win32**, full Rebuild.
6. Docs in §6.

Do not raise the server array (step 4) before the spike is green.

## 9. Acceptance

Falsifiable:

- A 4-class caster can scribe every trainer spell they are allowed without the "no more spell book slots" line.
- Drop Cleric: Cleric-only spells vanish from the book and gems; shared spells that Druid (or another held class) can use stay. The scroll vendor will not sell those Cleric spells again (`already know`).
- Re-add Cleric: those spells return on empty pages; gems prefer the old gem index. No coin spent, no remem required.
- Drag a scroll for a hidden spell onto the book: refused with `You already know this spell.`, scroll kept. Send a mem request for a hidden spell: refused.
- Delete a visible spell from the book window (`OP_DeleteSpell`): the learned row is gone; a later drop/re-add does not bring it back.
- Drop then re-add does not restore a spell the player unscribed from the book themselves.
- `#unscribespells` forgets learned rows; a later re-add does not bring them back.
- Login after a crash mid-respec ends with visible book = (learned ∩ current mask) ∪ (learned spells no class 1–16 can use that were already on a page) (D12).
- A `#scribespell` / quest spell that no class can use is still on the page after zone-in.
- Rule-off multiclass: single-class scribe/unscribe unchanged except that `HasSpellScribed` still sees the learned row (same as the book for someone who never respecced).
- Old DLL + new server is not a supported pair. Deploy ships both; the server cannot detect an old add-on before the profile goes out (§4.4).
- Disc train for four melee classes does not hit the 100-slot PP cap.
- `/book 1..4` on the client shows four distinct 90-page volumes; a scribe on volume 2 writes `character_spells.slot_id >= 720`.

Negative:

- Hidden spell cannot be cast or memmed until the class is held again.
- Full 2880 with a still-unplaced learned row logs Error and keeps the row.

## 10. Verification

| Change | Minimum |
| --- | --- |
| Custom migration | Manifest v41 + `CUSTOM_BINARY_DATABASE_VERSION` 41 agree. Idempotent. Player schema. Backfill count on a disposable DB equals distinct `character_spells` / `character_disciplines` rows. |
| Server | From `Release-NMS-Server`: configure VS 2022 x64, `cmake --build Build --config Release` for `zone`. |
| Client DLL | From `Release-NMS-Client`: `msbuild eqgame_dll.sln /t:Rebuild /p:Configuration=Release /p:Platform=Win32`. |
| Client spike | §4.2 in full: sentinels at 0 / 719 / 720 / 2879 land in the DLL copy; mem bar and skills intact; book opens; `/book 4` shows slot 2879 on page 90; scribe / delete / swap on volume 2 round-trip to `character_spells`. |
| Quest copy | `QUEST-API.md` path exists; wording matches D7. |
| Docs | Paths and 2880 / v41 / 300 cited above are real files. |

Live RoF2 + disposable DB is required to claim the spike or hide/restore. A server compile alone does not prove D9–D10.

`tests:class-exp-routing` does not cover this.

## 11. Review notes for Fable

Attack these before anyone writes the 2880 encode:

1. **Profile compact site.** The scan must stay anchored on Timestamp2 (`100` + 100 zero dwords) then count 2880 and gem 16. A first-match `720`/`2880` dword is a smash (AA 720 + skill 16). A miss on a 2880-sized profile must suppress, not Pass. Do not "just send 720 and a custom opcode" in the same PR without a spec revision.
2. **`SaveSpells` wipe.** Any path that still delete/rewrites `character_spells` and also thinks that table is the learned set will drop hidden spells on the next save.
3. **`HasSpellScribed` = book** will sell a "new" scroll for a hidden spell, or fail to place on re-add if someone only checks the window.
4. **Inclusive `ValueWithin(..., SPELLBOOK_SIZE)`** writes `spell_book[2880]` if a bad `slot_id` lands.
5. **CHARINFO2 grow** is the obvious-looking patch and it is wrong. Overflow only.
6. **Disc 100 vs 300** is easy to miss and will look like "melee B1" a week later.
7. **Shared spells** (D6) are the usual hide/restore off-by-one.
