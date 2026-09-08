# Firiona Vie + attune loop

Status: implemented on this tree (2026-09-07).
Date: 2026-09-07
Governs: loot is tradable until worn; wearing binds; an unattuner undoes that.
Companion: `2026-09-07-armarium.md` (the bound key is the exception).

## 0. Decisions

| # | Decision | Why |
| --- | --- | --- |
| D1 | **`World:FVNoDropFlag` default and live value is `1`.** Compiled default is 1. Custom **v44** updates `rule_values` (the dump ships `0`). | Stock Firiona Vie: unattuned no-drop can be traded. Dump overlay would otherwise keep FV off. |
| D2 | **Wearable no-drop attunes on equip.** Rows that are no-drop, not already attuneable, have worn slots (or are augs), are rentable, and are not summoned are promoted to attuneable at `shared_memory` load while FV is not `0`. | The dump has ~63k wearable no-drop items that are not attuneable. Flipping FV without this makes loot tradable and wearing does nothing. Do not rewrite `release-peq.zip`. |
| D3 | **Attuned stays bound.** `IsDroppable` is false when attuned, when the item is Armarium, or when a bag/aug holds either. Contents are inspected *before* the FV parent early-return. Drop, parcel, and trade/shared-bank moves use that result and must not let `CanTradeFVNoDropItem()` authorize a bound item. Trade *finish* and `CheckTradeNonDroppable` use `CanGiveItemInTrade`: bound is always false; unattuned no-drop is allowed when `IsDroppable` or the giver is an AdminOnly GM. Under FV, a refused drop, move, or trade return keeps the item (no delete / WorldKick / ignored `DropInst`). An owned bot is not the same binding domain: `^inventorygive` may give unattuned no-drop to the owner's bot, not attuned or Armarium. | Stock FV bypass let attuned items leave the character. A droppable bag must not carry a bound child. AdminOnly=2 must work end-to-end, not only at `SwapItem`. |
| D4 | **Unattuner is existing content.** Urthron's Ultimate Unattuner `9208` / `52024` clears `IsAttuned()` regardless of item-table `nodrop` (`0` is no-drop). Plat-cost mode stays `Custom:UseCustomUnattuneCombine` (default off = free, consumes the bag). Both modes refuse when the cursor is at `CURSOR_BAG_COUNT` and do not remove the source (or consume plat) unless `PushItemOnCursor` persists. A failed persist rolls back the appended cursor clone (`PopCursorBack`); it must not leave an unattuned duplicate when the cursor was already occupied. Trade returns that keep the original do the same for the destination clone. | Promoted wearable no-drop stays `NoDrop == 0`; the combine must not require a truthy `NoDrop`. `SaveCursor` can return true after dropping a 201st entry. `PushItemOnCursor` / `PutItemInInventory` mutate memory before the save result. |
| D5 | **Armarium stays bound.** `fvnodrop = 1` and identity in `IsDroppable`. Not attuneable. | Storage key, not gear. |
| D6 | **Re-run `shared_memory` after the FV rule changes.** First boot applies v44 in `world` after the initial `shared_memory` pass. | Promotion is a load-time mutation. |

`Items:DisableAttuneable` or FV `0` keeps stock item flags.

## 1. What does not change

- Item-table `nodrop` flags stay. FV makes unattuned no-drop tradable; it does not strip the column.
- `/nmsloot` Sell / Tribute still refuse item-table no-drop (vendor/tribute, not player trade).
- Quest clickies and other no-slot no-drop stay tradable under FV and never attune.
- The dump is not rewritten.
