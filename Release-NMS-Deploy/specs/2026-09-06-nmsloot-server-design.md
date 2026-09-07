# NMS loot offers + Dimensional Vault — server contract (design)

Status: implemented on this tree (2026-09-06); **do not enable in production**. Rules stay default-off. Vault protocol is the observed `#vault_*` / `VAULTDATA|` contract. Loot-offer opcodes `OP_NmsLootOffer=0x140A` and `OP_NmsLootDecision=0x140B` match the installed add-on; the packed layouts were replaced after disassembly (header 86 + `count`×150, decision 75). Unknown header/entry fields remain unnamed until a capture. `#nmsloot_decide` is GMAdmin-only.
Date: 2026-09-06
Governs: (1) the custom loot-offer path so `/nmsloot` can fill and act, and (2) Dimensional Vault storage including **Proc Locker** and clicky-bag autoload. Does not replace stock `OP_LootRequest`. Does not govern `/ptmap` or `/browser`.

Companion reverse-engineering (not in this repo): `NMSLoot_Spec.md`, `DimensionalVault_Spec.md`.

## 0. Decisions

| # | Decision | Why |
| --- | --- | --- |
| D1 | **Keep the installed 3.5 MB `dinput8.dll`.** Do not port `/nmsloot` into `Release-NMS-Client` in this pass. | That DLL already has Pending / Rules / keywords / auto-apply / bonus keep / DND / pop-out / pass. The repo DLL has none of those strings. A UI port would ship a thinner looter. |
| D2 | **Leave client chrome as-is** (`TRIUNE > Loot`, `/nmsloot`, `NMSLoot\`). | Renaming the 6-letter `TRIUNE` slot is optional and not required for function. `/nmsloot` and `NMSLoot\` are load-bearing. |
| D3 | **No one-active-looter gate on this server.** Every client that is entitled to the corpse gets the offer. | The DLL's `ActiveLooter.ini` / "set this on only one toon" is a box lock. This server must not add a per-account or per-PC looter lock. If boxed toons still sit in STANDBY, that is a client check to bypass later, not a server rule. |
| D4 | **Stock corpse loot stays.** The native loot window continues to work. | Observed: `Splintered Discordling Bone` already appears on `OP_LootRequest`. `/nmsloot` is a second pipe, not a replacement. |
| D5 | **Keep / Sell / Tribute / Destroy / Pass run on the server.** No merchant window for Sell. | Vault spec appendix A: chat lines `[NMS] <item> sold for …`, `Item destroyed.`, `tributed for N favor points.`, `added to inventory.` The client sends a decision; the zone executes it. |
| D6 | **Offers expire and are restored on return to the zone.** | Appendix A: `[NMS] That loot offer has expired.` and `[NMS] N unclaimed loot items recovered from your last visit to this zone.` |
| D7 | **Gate the new path with a Custom rule, default off.** Stock loot when the rule is off or the payload is missing. | CODEBASE thesis: optional NMS behavior is a `Custom` switch. Fail closed to today's corpse window. |
| D8 | **Dimensional Vault is in scope**, including Proc Locker and clicky pages. | Same installed DLL. Protocol is already known (`#vault_*` + `VAULTDATA\|` chat). No custom opcode. |
| D9 | **`You receive 1 Echo of Memory.` is not a loot-offer message.** | Already sent from `zone/attack.cpp` on the kill award. Do not re-send it from the loot path. |
| D10 | **Proc Locker (vault page 9) overrides equipped-weapon procs, not stats.** Slot 81 = primary proc, 82 = shield stats + block (and/or secondary proc), 83 = ranged proc. Does not stack with augment procs. | Vault spec §2 / §6.8. Community: locker weapon acts like a "lifetap aug." |
| D11 | **Clicky pages (vault 7–8, slots 61–80) auto-load on zone-in and login.** Bags in those slots have their click effects applied until death or zone. | Vault spec §2 help text and §6.7. |

## 0b. Six features this pass builds

| # | Feature | Server work |
| --- | --- | --- |
| F1 | `/nmsloot` offers | Send offer when a corpse is opened so Pending fills |
| F2 | Keep / Sell / Tribute / Destroy / Pass | Execute on the server; no merchant window for Sell |
| F3 | Dimensional Vault (83 slots) | `#vault_*` + `VAULTDATA\|` persist and refresh |
| F4 | Proc Locker (slots 81–83) | Combat proc (and slot-82 shield stats) from locker items |
| F5 | Clicky bag autoload (slots 61–80) | Apply click effects on zone-in / login |
| F6 | Vault Bank / Merchant buttons | `#vault_bank` / `#vault_merchant` without a nearby NPC |

No one-active-looter gate (D3). TRIUNE chrome unchanged (D2). `/ptmap` and `/browser` stay out.

## 1. Thesis

The installed `dinput8.dll` already draws `/nmsloot` and Dimensional Vault (including Proc Locker). This tree is missing the **server half** of both.

- Loot: no offer opcode, so Pending stays empty while the native corpse window works.
- Vault: no `#vault_*` commands and no `VAULTDATA|` chat, so the vault UI has nothing to show. Proc Locker and clicky autoload never apply.

This spec adds both contracts, **without** a one-looter lock. `/ptmap` and `/browser` stay client-only and are not required for loot or vault.

## 2. What the client already does

Observed in the installed `dinput8.dll` (2026-08-23) and `NMSLoot\` / `NMSImGui\`:

- ImGui window `NMS loot window  [/nmsloot]`; header chrome `TRIUNE > Loot`.
- Command `/nmsloot [show|open|hide|close|reset|popout|dock|help]`.
- Pending is filled from a **loot-offer packet**. Malformed payloads log `[NMS] Discarded a malformed loot offer packet.`
- Rules live in `NMSLoot\<Char>_LootList.ini` (`Action|IconID|ItemID[|Limit|ThenAction]`). Unassigned items stay on Pending.
- Bonus-roll items can auto-keep (`AutoKeepBonus`).
- The same chat hook that hides `VAULTDATA\|` also swallows `[NMS] Not active looter` (vault spec §3). That is why boxing STANDBY can look like "nothing happened" in chat.

Not in this repo's `Release-NMS-Client\ClientFiles\dinput8.dll` (1.6 MB, no `/nmsloot` strings).

## 3. Protocol (known vs open)

### 3.1 Known (from both reverse-engineering docs)

| Direction | What | Evidence |
| --- | --- | --- |
| Server → client | Binary **loot-offer** packet. Client validates or discards. | `[NMS] Discarded a malformed loot offer packet.` |
| Client → server | Decision for each item (Keep / Sell / Tribute / Bank / Vault / Destroy / Pass). | Result chat in appendix A is server-authored. Vault deposit is `#vault_*`; loot decisions are **not** `#` say (loot spec §7.2). |
| Server → client | Result lines: sold (coin breakdown), no sell value, destroyed, added to inventory, tributed for favor, offer expired, N unclaimed recovered. | Appendix A, chat logs. |
| Server | Pending offers time out. Returning to the zone restores unclaimed items as new offers. | Appendix A. |

### 3.2 Loot packet (opcodes recovered; field names partly inferred)

The installed add-on dispatches `0x140A` and emits `0x140B`. Those numbers stay. The first server layout (`12 + count×81` offer, 84-byte decision) does not match the parser. Current packed sizes: header 86, entry 150, decision 75. Count is clamped to 64.

| Direction | Opcode | Value | Layout |
| --- | --- | --- | --- |
| Server → client | `OP_NmsLootOffer` | `0x140A` | packed header: `uint16` unused, `char title[64]`, `uint32 corpse_id`, `uint32 expire_seconds`, two unused `uint32`s, `uint32 count` at offset 82; then `count` entries of `uint32 offer_id`, `uint32 icon`, `int32 charges`, `uint32 item_id`, `uint8 bonus`, 5 unused bytes, `char name[64]`, `char name2[64]` |
| Client → server | `OP_NmsLootDecision` | `0x140B` | packed, exact 75 bytes: `uint16` unused, `uint32 item_id` (echo of entry+12), `uint32 offer_id` (echo of entry+0), `uint8 action` (1 Keep, 2 Sell, 3 Tribute, 4 Bank, 5 Vault, 6 Destroy, 7 Pass, 9 return-to-passer), `char name[64]` (Pass target, or passer name for action 9). No quantity field; the server treats every decision as all charges |

Entry `name` at offset 22 is the item name. Entry `name2` at offset 86 is empty on a fresh corpse offer and is the passing player’s name on a forwarded offer (`passed_from`). Action 9 is mapped to Pass toward `name`. Actions other than 1–7 and 9, and Pass/action 9 with an empty target name, are refused without deleting the offer.

Expire default is `Custom:NmsLootOfferExpireSeconds` = 300. Offers are sent only after a successful stock loot session (`IsBeingLootedBy` and `AllowedPVE` / `GMAllowed`). Decisions match by `offer_id` owned by the connected character, recheck corpse lock/range/`CanPlayerLoot` when the corpse still exists, and refuse if the matching corpse item is gone. Pass requires the recipient online in this zone, NoDrop-eligible, and `CanPlayerLoot` / group / raid. Sell and Tribute refuse NoDrop and augmented items. `#nmsloot_decide` is a GMAdmin QA command; players cannot fire decisions through say.

A wrong-size `0x140B` is ignored and does not change inventory, vault, or corpse state. Vault does not depend on this packet. Pending display still needs an in-game check after this layout change.

## 4. Server behaviour

When the Custom rule is **on**:

1. Build an offer for each item the player is allowed to loot (same entitlement as stock corpse loot: solo / group / raid / FFA as today).
2. Send the offer to **that client**. Do not consult `ActiveLooter.ini`. Do not keep one "account looter."
3. Persist unclaimed offers per character (and zone or corpse id) so a zone-out can restore them (D6).
4. On decision: Keep → inventory (respect LORE; DLL already has a LORE skip string). Sell → coin, no merchant. Tribute → favor. Destroy → delete. Pass → other player's Pending (ignore list is client-side return). Bank / Vault deposit only after §4b exists; until then refuse with a clear `[NMS]` line.
5. When the rule is **off**, or tables/payload are missing: do not send offers. Native loot only.

Stock `OP_LootRequest` is unchanged. Players can still loot the native window; implementing "loot in one place removes it from the other" is required once the opcode is known (same corpse slot / item instance).

## 4b. Vault / Proc Locker / clicky bags

No custom opcode. The DLL talks in `/say #vault_*` and eats chat lines that start with `VAULTDATA|`.

| Page | Slots | Job |
| --- | --- | --- |
| 1–6 Bag 1–6 | 1–60 | Storage (10 per page) |
| 7–8 Clicky 1–2 | 61–80 | Bags whose click effects auto-cast on zone-in / login until death or zone |
| 9 Proc Locker | 81 Pri, 82 Sec, 83 Rng | 81 replaces the equipped primary's **proc**. 82: shield stats + block (help text) and/or secondary proc. 83: ranged proc override. Do not stack with augment procs. Equipped-item **stats** stay on the worn item except as specified for 82. |

Server must provide:

1. Persist 83 slots per character (item id, charges, augments[6], nested bag contents).
2. `#vault_page N` — may be a no-op besides remembering page.
3. `#vault_deposit S` / `#vault_withdraw S [1]` — cursor ↔ slot S; then `VAULTDATA|CLEAR` + one `ADD` per occupied slot (and `OPEN` when first opened).
4. `#vault_deposit_bagitem_specific S B` / `#vault_withdraw_bagitem S B [1]` — same inside the container at S.
5. `#vault_bank` / `#vault_merchant` — open bank / a merchant without a nearby NPC.
6. On zone-in / login: apply click effects from bags in 61–80.
7. In melee / ranged proc selection: if 81/82/83 is filled, use that item's proc (and 82 shield block) instead of the worn weapon's proc.

`ADD` field map is in the vault reverse-engineering spec §3. Do not invent a second format.

This repo today: no `command_vault`, no `character_vault` table, no `VAULTDATA` sender. `inventory.cpp` only blocks putting Veeshan's Dimensional Pocket in the shared bank and treats item 17304 as a summoned bag — that is **not** the vault.

## 5. Boxing / active looter

- **Server:** no active-looter state, no "one system per account."
- **Client:** `ActiveLooter.ini` may still force STANDBY on extra local clients. That does not change D3. Follow-up if boxing still ignores offers: bypass the DLL check (same-length patch or ignore the file), after the offer packet works on a single character.
- `World:EnforceCharacterLimitAtLogin` stays whatever it is today (compiled default false). That is a login rule, not loot.

## 6. Feature gap (installed DLL vs this tree)

| Feature | Installed 3.5 MB DLL | This repo server | This repo `dinput8.dll` | This spec |
| --- | --- | --- | --- | --- |
| `/nmsloot` UI | Yes | No offer packet | No | **In** — server protocol |
| Loot Keep/Sell/Tribute/Destroy/Pass | Client sends decision | No handlers | No | **In** |
| One-active-looter lock | Yes (`ActiveLooter.ini`) | None today | n/a | **Must not add** |
| Dimensional Vault 83 slots | Yes | No `#vault_*` | No | **In** |
| Proc Locker (81–83) | Yes | No combat hook | No | **In** |
| Clicky bag autoload (61–80) | Yes | No | No | **In** |
| Vault Bank / Merchant buttons | Yes | No | No | **In** |
| `#autoskill` / autoplay console | ImGui `> Autoskill` | **Yes** (`#autoskill`) | `/autoskill` forward | Already shipped |
| Waypoints | Yes | **Yes** | Yes | Already shipped |
| Multiclass / pets / EoM / item tiers | Yes | **Yes** | Partial | Already shipped |
| `/ptmap` tactical map | Yes (client-only) | Not needed | No | Out |
| `/browser` / `/weblink` | Yes (client-only) | Not needed | No | Out |
| Welcome-popup copy | Hook swallows a line | Quest popup exists | Suppress hook | Do not rewrite copy unless asked |
| TRIUNE chrome rename | Baked `TRIUNE` string | n/a | n/a | Out (D2) |

## 6b. Out of scope

- Porting `/nmsloot` or vault ImGui into `Release-NMS-Client`.
- Renaming TRIUNE chrome.
- `/ptmap`, `/browser` (client-only; they already run in the installed DLL).
- Changing Echo of Memory award text or `#award`.
- Shared-bucket loot (`Custom:RandomLootBuckets`) except that offer item ids must be the same ids the corpse already rolled (including upgrade tiers `+1e6` / `+2e6`).

## 7. Verification (once implemented)

- Rule off: native loot only; no offer packet; Pending stays empty.
- Rule on, solo, open corpse that has an item: Pending shows that item (name / icon / qty).
- Keep: item in inventory; native slot clears; `[NMS] … added to inventory.`
- Sell of a vendor-valued item: coin granted; `[NMS] … sold for …`. No merchant window.
- Sell of no-value item: refused, item remains pending.
- Zone out with unclaimed offer: expire or restore line on return (match recovered DLL timeout).
- Two boxed characters on one PC, both entitled: **server** sent an offer to both. If the second client still shows STANDBY, record it as the known DLL lock (D3 follow-up), not a server bug.
- Repo `dinput8.dll` (no `/nmsloot`): unchanged; native loot still works.
- Vault: deposit to an empty slot, `VAULTDATA` refresh, withdraw to cursor.
- Proc Locker: weapon in slot 81, equipped weapon without that proc → hits use the locker proc; remove locker item → worn proc returns.
- Clicky page: bag in 61–70, zone → click effects present; death or zone-out without the bag → they do not persist incorrectly.
- `#vault_bank` / `#vault_merchant` open those windows with no nearby NPC.

## 8. Implementation map (this tree)

| Feature | Where |
| --- | --- |
| F1 `/nmsloot` offers | `nms_loot_offers.cpp`, sent after `Handle_OP_LootRequest` → `MakeLootRequestPackets` |
| F2 Keep/Sell/Tribute/Destroy/Pass | `NmsLootOfferApply`; `#nmsloot_decide` (GMAdmin) for QA |
| F3 Vault 83 slots | `nms_vault.cpp` + `#vault_*` + `character_nms_vault` |
| F4 Proc Locker | Cached locker IDs + `TryWeaponProc` + slot-82 bonuses (no shield+shield stack) |
| F5 Clicky autoload | `NmsVaultApplyClickies` on `CompleteConnect`; fade on clicky-slot withdraw |
| F6 Bank / Merchant | Separate bank vs merchant flags; `#vault_bank` / `#vault_merchant`; merchant depop on `SendMerchantEnd` |

Rules default **off**: `Custom:DimensionalVault`, `Custom:NmsLootOffers`. Migration v28 creates `character_nms_vault`; v29 creates `character_nms_loot_offers`; v30 adds `corpse_serial`; v31 widens `corpse_serial` to `BIGINT UNSIGNED`; v32 adds `instance_id` and a Pass tombstone (`passed`); v33 adds `passed_from` for the client pass-from name. Stock corpse loot is unchanged. Do not enable either rule in production until a later QA pass.
