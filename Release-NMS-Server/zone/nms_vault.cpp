#include "../common/global_define.h"
#include "nms_vault.h"

#include "../common/eqemu_logsys.h"
#include "../common/rulesys.h"
#include "../common/strings.h"
#include "../common/eq_packet_structs.h"
#include "../common/item_instance.h"
#include "../common/item_data.h"
#include "../common/spdat.h"
#include "client.h"
#include "entity.h"
#include "npc.h"
#include "zonedb.h"
#include "string_ids.h"

#include <fmt/format.h>
#include <unordered_map>
#include <vector>

extern ZoneDatabase database;
extern ZoneDatabase content_db;

namespace {
	bool tables_checked = false;
	bool tables_ready = false;

	struct LockerCache {
		uint32 primary = 0;
		uint32 secondary = 0;
		uint32 ranged = 0;
		int16  secondary_charges = 1;
		uint32 secondary_aug[6] = {0, 0, 0, 0, 0, 0};
		bool   secondary_is_shield = false;
	};

	std::unordered_map<uint32, LockerCache> locker_cache;

	std::string SanitizeField(const std::string &in)
	{
		std::string out;
		out.reserve(in.size());
		for (char ch : in) {
			if (ch == '|' || ch == '~' || ch == ':') {
				out.push_back(' ');
			}
			else {
				out.push_back(ch);
			}
		}
		return out;
	}

	bool EnsureTables()
	{
		if (tables_checked) {
			return tables_ready;
		}
		tables_checked = true;
		auto results = database.QueryDatabase("SHOW TABLES LIKE 'character_nms_vault'");
		if (!results.Success() || results.RowCount() == 0) {
			tables_ready = false;
			return tables_ready;
		}
		auto primary_key = database.QueryDatabase(
			"SELECT "
			"SUM(CASE WHEN column_name IN ('character_id', 'slot', 'bag_slot') THEN 1 ELSE 0 END) AS named_cols, "
			"COUNT(*) AS total_cols "
			"FROM information_schema.statistics "
			"WHERE table_schema = DATABASE() "
			"AND table_name = 'character_nms_vault' "
			"AND index_name = 'PRIMARY'"
		);
		auto unique_indexes = database.QueryDatabase(
			"SELECT COUNT(DISTINCT index_name) FROM information_schema.statistics "
			"WHERE table_schema = DATABASE() "
			"AND table_name = 'character_nms_vault' "
			"AND non_unique = 0"
		);
		tables_ready = false;
		if (primary_key.Success() && primary_key.RowCount() > 0
			&& unique_indexes.Success() && unique_indexes.RowCount() > 0) {
			auto row = primary_key.begin();
			auto unique_row = unique_indexes.begin();
			tables_ready = Strings::ToInt(row[0]) == 3
				&& Strings::ToInt(row[1]) == 3
				&& Strings::ToInt(unique_row[0]) == 1;
		}
		return tables_ready;
	}

	EQ::ItemInstance *MakeInstance(const NmsVaultItem &row)
	{
		return database.CreateItem(
			row.item_id,
			row.charges,
			row.aug[0],
			row.aug[1],
			row.aug[2],
			row.aug[3],
			row.aug[4],
			row.aug[5]
		);
	}

	NmsVaultItem FromInstance(int slot, int bag_slot, const EQ::ItemInstance *inst)
	{
		NmsVaultItem row;
		row.slot = slot;
		row.bag_slot = bag_slot;
		if (!inst || !inst->GetItem()) {
			return row;
		}
		row.item_id = inst->GetItem()->ID;
		row.charges = inst->GetCharges();
		for (int i = 0; i < 6; ++i) {
			row.aug[i] = inst->GetAugmentItemID(static_cast<uint8>(i));
		}
		return row;
	}

	std::string BagContentsField(const std::vector<NmsVaultItem> &all, int slot)
	{
		std::string out;
		for (const auto &row : all) {
			if (row.slot != slot || row.bag_slot <= 0) {
				continue;
			}
			const auto *item = database.GetItem(row.item_id);
			if (!item) {
				continue;
			}
			if (!out.empty()) {
				out.append("~");
			}
			out.append(fmt::format(
				"{}:{}:{}:{}",
				row.item_id,
				SanitizeField(item->Name),
				row.charges,
				item->Icon
			));
		}
		return out;
	}

	void SendLine(Client *c, const std::string &line)
	{
		c->Message(Chat::White, "%s", line.c_str());
	}

	bool IsVaultClicky(const EQ::ItemData *item)
	{
		if (!item || !IsValidSpell(item->Click.Effect)) {
			return false;
		}
		return item->Click.Type == EQ::item::ItemEffectClick
			|| item->Click.Type == EQ::item::ItemEffectClick2
			|| item->Click.Type == EQ::item::ItemEffectEquipClick;
	}

	void CollectClickySpells(const std::vector<NmsVaultItem> &items, int slot, std::vector<uint16> &out)
	{
		if (slot < NMS_VAULT_CLICKY_BEGIN || slot > NMS_VAULT_CLICKY_END) {
			return;
		}
		for (const auto &row : items) {
			if (row.slot != slot) {
				continue;
			}
			const auto *item = database.GetItem(row.item_id);
			if (IsVaultClicky(item)) {
				out.push_back(static_cast<uint16>(item->Click.Effect));
			}
		}
	}

	void FadeClickySpells(Client *c, const std::vector<uint16> &spells)
	{
		for (auto spell_id : spells) {
			c->BuffFadeBySpellID(spell_id);
		}
	}

	bool CursorPersisted(Client *c)
	{
		if (!c) {
			return false;
		}
		auto start = c->GetInv().cursor_cbegin();
		auto end = c->GetInv().cursor_cend();
		if (!database.SaveCursor(c->CharacterID(), start, end)) {
			return false;
		}
		auto results = database.QueryDatabase(fmt::format(
			"SELECT COUNT(*) FROM inventory WHERE character_id = {} "
			"AND (slot_id = {} OR slot_id BETWEEN {} AND {})",
			c->CharacterID(),
			EQ::invslot::slotCursor,
			EQ::invbag::CURSOR_BAG_BEGIN,
			EQ::invbag::CURSOR_BAG_END
		));
		if (!results.Success() || results.RowCount() == 0) {
			return false;
		}
		auto row = results.begin();
		return Strings::ToInt(row[0]) == c->GetInv().CursorSize();
	}

	bool DeliverToPlayer(Client *c, EQ::ItemInstance *inst)
	{
		if (!c || !inst) {
			return false;
		}
		if (c->GetInv().CursorSize() >= EQ::invbag::CURSOR_BAG_COUNT) {
			return c->AutoPutLootInInventory(*inst, true, false);
		}

		const int before = c->GetInv().CursorSize();
		c->PushItemOnCursor(*inst, true);
		if (c->GetInv().CursorSize() > before) {
			return true;
		}
		return c->AutoPutLootInInventory(*inst, true, false);
	}

	bool ParentIsBagWithSlot(const std::vector<NmsVaultItem> &items, int slot, int bag_slot)
	{
		const auto *parent = NmsVaultFind(items, slot, 0);
		if (!parent) {
			return false;
		}
		const auto *parent_item = database.GetItem(parent->item_id);
		return parent_item
			&& parent_item->IsClassBag()
			&& bag_slot >= 1
			&& bag_slot <= static_cast<int>(parent_item->BagSlots);
	}

	bool RestoreVaultSnapshot(uint32 character_id, const std::vector<NmsVaultItem> &snapshot)
	{
		bool ok = true;
		for (const auto &row : snapshot) {
			if (!NmsVaultSaveItem(character_id, row)) {
				ok = false;
			}
		}
		return ok;
	}

	bool VaultSlotOccupied(const std::vector<NmsVaultItem> &items, int slot)
	{
		for (const auto &item : items) {
			if (item.slot == slot) {
				return true;
			}
		}
		return false;
	}

	bool VaultSlotHasPersistedRows(uint32 character_id, int slot)
	{
		auto results = database.QueryDatabase(fmt::format(
			"SELECT COUNT(*) FROM character_nms_vault WHERE character_id = {} AND slot = {}",
			character_id,
			slot
		));
		if (!results.Success() || results.RowCount() == 0) {
			return true;
		}
		auto row = results.begin();
		return Strings::ToInt(row[0]) > 0;
	}

	bool CleanupVaultSlot(uint32 character_id, int slot)
	{
		auto results = database.QueryDatabase(fmt::format(
			"DELETE FROM character_nms_vault WHERE character_id = {} AND slot = {}",
			character_id,
			slot
		));
		if (!results.Success() || VaultSlotHasPersistedRows(character_id, slot)) {
			LogError(
				"NmsVault: failed to clean slot {} for character {}",
				slot,
				character_id
			);
			return false;
		}
		return true;
	}

	bool SaveVaultSlot(uint32 character_id, int slot, EQ::ItemInstance *inst)
	{
		if (!inst || !EnsureTables()) {
			return false;
		}

		if (inst->IsClassBag() && inst->IsNoneEmptyContainer()) {
			for (auto &content : *inst->GetContents()) {
				if (!content.second) {
					continue;
				}
				auto inner = FromInstance(slot, content.first + 1, content.second);
				if (!NmsVaultSaveItem(character_id, inner)) {
					CleanupVaultSlot(character_id, slot);
					return false;
				}
			}
		}

		auto row = FromInstance(slot, 0, inst);
		if (!NmsVaultSaveItem(character_id, row)) {
			CleanupVaultSlot(character_id, slot);
			return false;
		}
		return true;
	}

	bool ConsumeCursorAfterSave(Client *c, int slot, int bag_slot)
	{
		auto *cursor = c->GetInv().GetItem(EQ::invslot::slotCursor);
		if (!cursor) {
			return false;
		}
		auto *copy = cursor->Clone();
		c->DeleteItemInInventory(EQ::invslot::slotCursor, 0, true, false);
		if (CursorPersisted(c)) {
			safe_delete(copy);
			return true;
		}

		bool vault_cleared = false;
		for (int attempt = 0; attempt < 3 && !vault_cleared; ++attempt) {
			vault_cleared = NmsVaultDeleteItem(c->CharacterID(), slot, bag_slot);
		}
		if (vault_cleared && copy) {
			c->GetInv().PushCursorFront(*copy);
			c->SendItemPacket(EQ::invslot::slotCursor, copy, ItemPacketLimbo);
			CursorPersisted(c);
		}
		else if (!vault_cleared) {
			LogError(
				"NmsVault: cursor persist failed and vault rollback delete failed for character {} slot {} bag {}",
				c->CharacterID(),
				slot,
				bag_slot
			);
			CursorPersisted(c);
		}
		safe_delete(copy);
		return false;
	}

	void RestoreWithdrawOnFail(
		Client *c,
		EQ::ItemInstance *inst,
		int16 before,
		const NmsVaultItem &original,
		bool one_charge,
		const std::vector<NmsVaultItem> *snapshot
	)
	{
		const int16 left = inst->GetCharges();
		if (left < before) {
			if (left > 0) {
				NmsVaultItem leftover = original;
				leftover.charges = left;
				if (!NmsVaultSaveItem(c->CharacterID(), leftover)) {
					LogError(
						"NmsVault: leftover persist failed for character {} slot {} charges {}",
						c->CharacterID(),
						original.slot,
						left
					);
				}
			}
			return;
		}
		if (one_charge) {
			NmsVaultSaveItem(c->CharacterID(), original);
		}
		else if (snapshot) {
			RestoreVaultSnapshot(c->CharacterID(), *snapshot);
		}
		else {
			NmsVaultSaveItem(c->CharacterID(), original);
		}
	}

	void AfterVaultMutation(Client *c, int slot, const std::vector<uint16> &fade_spells)
	{
		NmsVaultRefreshCache(c);
		if (slot >= NMS_VAULT_PROC_PRIMARY && slot <= NMS_VAULT_PROC_RANGED) {
			c->CalcBonuses();
		}
		FadeClickySpells(c, fade_spells);
	}

	void DepopVaultMerchant(Client *c)
	{
		if (!c || !c->GetNmsVaultMerchantId()) {
			return;
		}
		if (auto *npc = entity_list.GetNPCByID(static_cast<uint16>(c->GetNmsVaultMerchantId()))) {
			npc->Depop();
		}
		c->SetNmsVaultMerchantId(0);
		c->SetNmsVaultMerchant(false);
	}
}

void NmsVaultRefreshCache(Client *c)
{
	if (!c) {
		return;
	}

	locker_cache.erase(c->CharacterID());
	if (!NmsVaultEnabled() || !EnsureTables()) {
		return;
	}

	LockerCache cache;
	std::vector<NmsVaultItem> items;
	if (!NmsVaultLoad(c->CharacterID(), items)) {
		return;
	}
	if (const auto *row = NmsVaultFind(items, NMS_VAULT_PROC_PRIMARY, 0)) {
		cache.primary = row->item_id;
	}
	if (const auto *row = NmsVaultFind(items, NMS_VAULT_PROC_RANGED, 0)) {
		cache.ranged = row->item_id;
	}
	if (const auto *row = NmsVaultFind(items, NMS_VAULT_PROC_SECONDARY, 0)) {
		cache.secondary = row->item_id;
		cache.secondary_charges = row->charges;
		for (int i = 0; i < 6; ++i) {
			cache.secondary_aug[i] = row->aug[i];
		}
		if (const auto *item = database.GetItem(row->item_id)) {
			cache.secondary_is_shield = item->ItemType == EQ::item::ItemTypeShield;
		}
	}
	locker_cache[c->CharacterID()] = cache;
}

bool NmsVaultEnabled()
{
	return RuleB(Custom, DimensionalVault);
}

int NmsVaultPageForSlot(int slot)
{
	if (slot < NMS_VAULT_SLOT_MIN || slot > NMS_VAULT_SLOT_MAX) {
		return 1;
	}
	if (slot <= 60) {
		return ((slot - 1) / 10) + 1;
	}
	if (slot <= 70) {
		return 7;
	}
	if (slot <= 80) {
		return 8;
	}
	return 9;
}

bool NmsVaultSlotValid(int slot)
{
	return slot >= NMS_VAULT_SLOT_MIN && slot <= NMS_VAULT_SLOT_MAX;
}

bool NmsVaultTablesReady()
{
	return EnsureTables();
}

bool NmsVaultLoad(uint32 character_id, std::vector<NmsVaultItem> &items)
{
	items.clear();
	if (!EnsureTables()) {
		return false;
	}

	auto results = database.QueryDatabase(fmt::format(
		"SELECT slot, bag_slot, item_id, charges, aug1, aug2, aug3, aug4, aug5, aug6 "
		"FROM character_nms_vault WHERE character_id = {} ORDER BY slot, bag_slot",
		character_id
	));
	if (!results.Success()) {
		return false;
	}

	for (auto row = results.begin(); row != results.end(); ++row) {
		NmsVaultItem item;
		item.slot = Strings::ToInt(row[0]);
		item.bag_slot = Strings::ToInt(row[1]);
		item.item_id = Strings::ToUnsignedInt(row[2]);
		item.charges = static_cast<int16>(Strings::ToInt(row[3]));
		for (int i = 0; i < 6; ++i) {
			item.aug[i] = Strings::ToUnsignedInt(row[4 + i]);
		}
		items.push_back(item);
	}
	return true;
}

static bool LoadVaultForClient(Client *c, std::vector<NmsVaultItem> &items)
{
	if (!c || !NmsVaultLoad(c->CharacterID(), items)) {
		if (c) {
			c->Message(Chat::Red, "[NMS] Could not read your vault.");
		}
		return false;
	}
	return true;
}

const NmsVaultItem *NmsVaultFind(const std::vector<NmsVaultItem> &items, int slot, int bag_slot)
{
	for (const auto &item : items) {
		if (item.slot == slot && item.bag_slot == bag_slot) {
			return &item;
		}
	}
	return nullptr;
}

bool NmsVaultSaveItem(uint32 character_id, const NmsVaultItem &item)
{
	if (!EnsureTables()) {
		return false;
	}

	auto results = database.QueryDatabase(fmt::format(
		"REPLACE INTO character_nms_vault "
		"(character_id, slot, bag_slot, item_id, charges, aug1, aug2, aug3, aug4, aug5, aug6) "
		"VALUES ({}, {}, {}, {}, {}, {}, {}, {}, {}, {}, {})",
		character_id,
		item.slot,
		item.bag_slot,
		item.item_id,
		item.charges,
		item.aug[0],
		item.aug[1],
		item.aug[2],
		item.aug[3],
		item.aug[4],
		item.aug[5]
	));
	return results.Success();
}

bool NmsVaultDeleteItem(uint32 character_id, int slot, int bag_slot)
{
	if (!EnsureTables()) {
		return false;
	}

	if (bag_slot == 0) {
		auto results = database.QueryDatabase(fmt::format(
			"DELETE FROM character_nms_vault WHERE character_id = {} AND slot = {}",
			character_id,
			slot
		));
		return results.Success() && results.RowsAffected() > 0;
	}

	auto results = database.QueryDatabase(fmt::format(
		"DELETE FROM character_nms_vault WHERE character_id = {} AND slot = {} AND bag_slot = {}",
		character_id,
		slot,
		bag_slot
	));
	return results.Success() && results.RowsAffected() > 0;
}

void NmsVaultSendRefresh(Client *c, int open_page)
{
	if (!c || !NmsVaultEnabled() || !EnsureTables()) {
		return;
	}

	std::vector<NmsVaultItem> items;
	if (!NmsVaultLoad(c->CharacterID(), items)) {
		return;
	}

	SendLine(c, "VAULTDATA|CLEAR");
	for (const auto &row : items) {
		if (row.bag_slot != 0) {
			continue;
		}
		const auto *item = database.GetItem(row.item_id);
		if (!item) {
			continue;
		}

		const int page = NmsVaultPageForSlot(row.slot);
		const bool is_bag = item->IsClassBag();
		const int bag_slots = is_bag ? item->BagSlots : 0;
		const std::string bag_contents = is_bag ? BagContentsField(items, row.slot) : "";

		SendLine(c, fmt::format(
			"VAULTDATA|ADD|{}|{}|{}|{}|{}|{}|{}|{}|{}|{}|{}|{}|{}|{}|{}",
			page,
			row.slot,
			row.item_id,
			row.charges,
			item->Icon,
			SanitizeField(item->Name),
			bag_contents,
			row.aug[0],
			row.aug[1],
			row.aug[2],
			row.aug[3],
			row.aug[4],
			row.aug[5],
			item->NoDrop == 0 ? 1 : 0,
			bag_slots
		));
	}

	if (open_page < 1) {
		open_page = 1;
	}
	SendLine(c, fmt::format("VAULTDATA|OPEN|{}", open_page));
}

void NmsVaultHandlePage(Client *c, int page)
{
	if (!c || !NmsVaultEnabled() || !EnsureTables()) {
		return;
	}
	if (page < 1) {
		page = 1;
	}
	NmsVaultSendRefresh(c, page);
}

static EQ::ItemInstance *PeekCursor(Client *c)
{
	auto *cursor = c->GetInv().GetItem(EQ::invslot::slotCursor);
	if (!cursor) {
		c->Message(Chat::Red, "[NMS] Put an item on your cursor first.");
		return nullptr;
	}
	return cursor;
}

void NmsVaultHandleDeposit(Client *c, int slot)
{
	if (!c || !NmsVaultEnabled() || !EnsureTables() || !NmsVaultSlotValid(slot)) {
		return;
	}

	std::vector<NmsVaultItem> items;
	if (!LoadVaultForClient(c, items)) {
		return;
	}
	if (VaultSlotOccupied(items, slot)) {
		c->Message(Chat::Red, "[NMS] That vault slot is not empty.");
		return;
	}

	auto *inst = PeekCursor(c);
	if (!inst) {
		return;
	}

	if (!SaveVaultSlot(c->CharacterID(), slot, inst)) {
		c->Message(Chat::Red, "[NMS] Could not save that item to the vault.");
		return;
	}
	if (!ConsumeCursorAfterSave(c, slot, 0)) {
		c->Message(Chat::Red, "[NMS] Could not remove that item from your cursor.");
		return;
	}
	AfterVaultMutation(c, slot, {});
	NmsVaultSendRefresh(c, NmsVaultPageForSlot(slot));
}

void NmsVaultHandleWithdraw(Client *c, int slot, int quantity)
{
	if (!c || !NmsVaultEnabled() || !EnsureTables() || !NmsVaultSlotValid(slot)) {
		return;
	}

	std::vector<NmsVaultItem> items;
	if (!LoadVaultForClient(c, items)) {
		return;
	}
	const auto *row = NmsVaultFind(items, slot, 0);
	if (!row) {
		c->Message(Chat::Red, "[NMS] That vault slot is empty.");
		return;
	}

	auto *inst = MakeInstance(*row);
	if (!inst) {
		c->Message(Chat::Red, "[NMS] Could not recreate that vault item.");
		return;
	}

	std::vector<NmsVaultItem> snapshot;
	for (const auto &inner : items) {
		if (inner.slot != slot) {
			continue;
		}
		snapshot.push_back(inner);
		if (inner.bag_slot <= 0) {
			continue;
		}
		auto *bag_item = MakeInstance(inner);
		if (!bag_item) {
			safe_delete(inst);
			c->Message(Chat::Red, "[NMS] Could not recreate that vault bag.");
			return;
		}
		const uint8 bag_index = static_cast<uint8>(inner.bag_slot - 1);
		inst->PutItem(bag_index, *bag_item);
		safe_delete(bag_item);
		if (!inst->GetItem(bag_index)) {
			safe_delete(inst);
			c->Message(Chat::Red, "[NMS] Could not recreate that vault bag.");
			return;
		}
	}

	const NmsVaultItem original = *row;
	const bool one_charge = quantity == 1 && original.charges > 1;
	if (one_charge) {
		inst->SetCharges(1);
		NmsVaultItem remain = original;
		remain.charges = static_cast<int16>(original.charges - 1);
		if (!NmsVaultSaveItem(c->CharacterID(), remain)) {
			c->Message(Chat::Red, "[NMS] Could not update that vault item.");
			safe_delete(inst);
			return;
		}
	}
	else if (!NmsVaultDeleteItem(c->CharacterID(), slot, 0)) {
		c->Message(Chat::Red, "[NMS] Could not update that vault item.");
		safe_delete(inst);
		return;
	}

	const int16 before = inst->GetCharges();
	if (!DeliverToPlayer(c, inst)) {
		const int16 left = inst->GetCharges();
		RestoreWithdrawOnFail(c, inst, before, original, one_charge, &snapshot);
		if (left >= before) {
			c->Message(Chat::Red, "[NMS] Your inventory is full.");
			safe_delete(inst);
			return;
		}
	}

	std::vector<uint16> fade_spells;
	CollectClickySpells(items, slot, fade_spells);

	safe_delete(inst);
	AfterVaultMutation(c, slot, fade_spells);
	NmsVaultSendRefresh(c, NmsVaultPageForSlot(slot));
}

void NmsVaultHandleDepositBagItem(Client *c, int slot, int bag_slot)
{
	if (!c || !NmsVaultEnabled() || !EnsureTables() || !NmsVaultSlotValid(slot)) {
		return;
	}

	std::vector<NmsVaultItem> items;
	if (!LoadVaultForClient(c, items)) {
		return;
	}
	if (!ParentIsBagWithSlot(items, slot, bag_slot)) {
		c->Message(Chat::Red, "[NMS] There is no bag in that vault slot.");
		return;
	}
	if (NmsVaultFind(items, slot, bag_slot)) {
		c->Message(Chat::Red, "[NMS] That bag slot is not empty.");
		return;
	}

	auto *inst = PeekCursor(c);
	if (!inst) {
		return;
	}
	if (inst->IsClassBag()) {
		c->Message(Chat::Red, "[NMS] Cannot deposit a container into a vault bag.");
		return;
	}

	auto row = FromInstance(slot, bag_slot, inst);
	if (!NmsVaultSaveItem(c->CharacterID(), row)) {
		c->Message(Chat::Red, "[NMS] Could not save that item to the vault.");
		return;
	}
	if (!ConsumeCursorAfterSave(c, slot, bag_slot)) {
		c->Message(Chat::Red, "[NMS] Could not remove that item from your cursor.");
		return;
	}
	AfterVaultMutation(c, slot, {});
	NmsVaultSendRefresh(c, NmsVaultPageForSlot(slot));
}

void NmsVaultHandleWithdrawBagItem(Client *c, int slot, int bag_slot, int quantity)
{
	if (!c || !NmsVaultEnabled() || !EnsureTables() || !NmsVaultSlotValid(slot)) {
		return;
	}

	std::vector<NmsVaultItem> items;
	if (!LoadVaultForClient(c, items)) {
		return;
	}
	if (!ParentIsBagWithSlot(items, slot, bag_slot)) {
		c->Message(Chat::Red, "[NMS] There is no bag in that vault slot.");
		return;
	}

	const auto *row = NmsVaultFind(items, slot, bag_slot);
	if (!row) {
		c->Message(Chat::Red, "[NMS] That bag slot is empty.");
		return;
	}

	auto *inst = MakeInstance(*row);
	if (!inst) {
		return;
	}

	const NmsVaultItem original = *row;
	const bool one_charge = quantity == 1 && original.charges > 1;
	if (one_charge) {
		inst->SetCharges(1);
		NmsVaultItem remain = original;
		remain.charges = static_cast<int16>(original.charges - 1);
		if (!NmsVaultSaveItem(c->CharacterID(), remain)) {
			c->Message(Chat::Red, "[NMS] Could not update that vault item.");
			safe_delete(inst);
			return;
		}
	}
	else if (!NmsVaultDeleteItem(c->CharacterID(), slot, bag_slot)) {
		c->Message(Chat::Red, "[NMS] Could not update that vault item.");
		safe_delete(inst);
		return;
	}

	const int16 before = inst->GetCharges();
	if (!DeliverToPlayer(c, inst)) {
		const int16 left = inst->GetCharges();
		RestoreWithdrawOnFail(c, inst, before, original, one_charge, nullptr);
		if (left >= before) {
			c->Message(Chat::Red, "[NMS] Your inventory is full.");
			safe_delete(inst);
			return;
		}
	}

	std::vector<uint16> fade_spells;
	if (slot >= NMS_VAULT_CLICKY_BEGIN && slot <= NMS_VAULT_CLICKY_END) {
		const auto *item = database.GetItem(original.item_id);
		if (IsVaultClicky(item)) {
			fade_spells.push_back(static_cast<uint16>(item->Click.Effect));
		}
	}

	safe_delete(inst);
	AfterVaultMutation(c, slot, fade_spells);
	NmsVaultSendRefresh(c, NmsVaultPageForSlot(slot));
}

void NmsVaultHandleBank(Client *c)
{
	if (!c || !NmsVaultEnabled() || !EnsureTables()) {
		return;
	}

	c->SetNmsVaultBank(true);

	auto outapp = new EQApplicationPacket(OP_BankerChange, sizeof(BankerChange_Struct));
	auto *bc = reinterpret_cast<BankerChange_Struct *>(outapp->pBuffer);
	bc->copper = c->GetPP().copper;
	bc->silver = c->GetPP().silver;
	bc->gold = c->GetPP().gold;
	bc->platinum = c->GetPP().platinum;
	bc->copper_bank = c->GetPP().copper_bank;
	bc->silver_bank = c->GetPP().silver_bank;
	bc->gold_bank = c->GetPP().gold_bank;
	bc->platinum_bank = c->GetPP().platinum_bank;
	c->QueuePacket(outapp);
	safe_delete(outapp);
}

void NmsVaultHandleMerchant(Client *c)
{
	if (!c || !NmsVaultEnabled() || !EnsureTables()) {
		return;
	}

	if (c->GetNmsVaultMerchantId()) {
		if (auto *existing = entity_list.GetNPCByID(static_cast<uint16>(c->GetNmsVaultMerchantId()))) {
			c->SetNmsVaultMerchant(true);
			auto outapp = new EQApplicationPacket(OP_ShopRequest, sizeof(MerchantClick_Struct));
			auto *mco = reinterpret_cast<MerchantClick_Struct *>(outapp->pBuffer);
			mco->npc_id = existing->GetID();
			mco->player_id = 0;
			mco->command = MerchantActions::Open;
			mco->rate = 1.0f;
			mco->tab_display = 1;
			c->QueuePacket(outapp);
			safe_delete(outapp);
			c->SetMerchantSessionEntityID(existing->GetID());
			c->BulkSendMerchantInventory(existing->MerchantType, existing->GetNPCTypeID());
			return;
		}
		c->SetNmsVaultMerchantId(0);
		c->SetNmsVaultMerchant(false);
	}

	auto pick = content_db.QueryDatabase(
		"SELECT id FROM npc_types WHERE `class` = 41 AND merchanttype > 0 ORDER BY id LIMIT 1"
	);
	if (!pick.Success() || pick.RowCount() == 0) {
		c->Message(Chat::Red, "[NMS] No merchant template is available to open.");
		return;
	}

	const uint32 npc_id = Strings::ToUnsignedInt(pick.begin()[0]);
	const auto *npc_type = content_db.LoadNPCTypesData(npc_id);
	if (!npc_type) {
		c->Message(Chat::Red, "[NMS] Could not load a merchant template.");
		return;
	}

	auto *npc = new NPC(npc_type, nullptr, c->GetPosition(), GravityBehavior::Flying);
	entity_list.AddNPC(npc, true, true);
	npc->SetInvisible(1);
	c->SetNmsVaultMerchantId(npc->GetID());
	c->SetNmsVaultMerchant(true);

	auto outapp = new EQApplicationPacket(OP_ShopRequest, sizeof(MerchantClick_Struct));
	auto *mco = reinterpret_cast<MerchantClick_Struct *>(outapp->pBuffer);
	mco->npc_id = npc->GetID();
	mco->player_id = 0;
	mco->command = MerchantActions::Open;
	mco->rate = 1.0f;
	mco->tab_display = 1;
	c->QueuePacket(outapp);
	safe_delete(outapp);
	c->SetMerchantSessionEntityID(npc->GetID());
	c->BulkSendMerchantInventory(npc->MerchantType, npc->GetNPCTypeID());
}

bool NmsVaultBankAccess(Client *c)
{
	return c && NmsVaultEnabled() && EnsureTables() && c->GetNmsVaultBank();
}

bool NmsVaultIsMerchant(Client *c, uint16 entity_id)
{
	return c
		&& NmsVaultEnabled()
		&& EnsureTables()
		&& c->GetNmsVaultMerchant()
		&& entity_id
		&& c->GetNmsVaultMerchantId() == entity_id;
}

int NmsVaultTryDepositInstance(Client *c, EQ::ItemInstance *inst)
{
	if (!c || !inst || !NmsVaultEnabled() || !EnsureTables()) {
		return 0;
	}

	std::vector<NmsVaultItem> items;
	if (!NmsVaultLoad(c->CharacterID(), items)) {
		return 0;
	}
	int slot = 0;
	for (int candidate = NMS_VAULT_SLOT_MIN; candidate <= 60; ++candidate) {
		if (!VaultSlotOccupied(items, candidate)) {
			slot = candidate;
			break;
		}
	}
	if (!slot) {
		return 0;
	}

	if (!SaveVaultSlot(c->CharacterID(), slot, inst)) {
		return 0;
	}
	AfterVaultMutation(c, slot, {});
	NmsVaultSendRefresh(c, NmsVaultPageForSlot(slot));
	return slot;
}

void NmsVaultApplyClickies(Client *c)
{
	if (!c || !NmsVaultEnabled() || !EnsureTables()) {
		return;
	}

	std::vector<NmsVaultItem> items;
	if (!NmsVaultLoad(c->CharacterID(), items)) {
		return;
	}
	for (const auto &row : items) {
		if (row.bag_slot != 0
			|| row.slot < NMS_VAULT_CLICKY_BEGIN
			|| row.slot > NMS_VAULT_CLICKY_END) {
			continue;
		}
		const auto *item = database.GetItem(row.item_id);
		if (IsVaultClicky(item)) {
			c->SpellOnTarget(item->Click.Effect, c);
		}
		for (const auto &inner : items) {
			if (inner.slot != row.slot || inner.bag_slot <= 0) {
				continue;
			}
			const auto *bag_item = database.GetItem(inner.item_id);
			if (IsVaultClicky(bag_item)) {
				c->SpellOnTarget(bag_item->Click.Effect, c);
			}
		}
	}
}

void NmsVaultOnZoneIn(Client *c)
{
	if (!c) {
		return;
	}
	DepopVaultMerchant(c);
	c->SetNmsVaultBank(false);
	c->SetNmsVaultMerchant(false);
	c->SetNmsVaultMerchantId(0);
	NmsVaultRefreshCache(c);
	NmsVaultApplyClickies(c);
}

void NmsVaultOnMerchantEnd(Client *c)
{
	DepopVaultMerchant(c);
}

const EQ::ItemData *NmsVaultProcItem(Client *c, uint16 hand)
{
	if (!c || !NmsVaultEnabled()) {
		return nullptr;
	}

	auto it = locker_cache.find(c->CharacterID());
	if (it == locker_cache.end()) {
		return nullptr;
	}

	uint32 item_id = 0;
	if (hand == EQ::invslot::slotPrimary) {
		item_id = it->second.primary;
	}
	else if (hand == EQ::invslot::slotSecondary) {
		item_id = it->second.secondary;
	}
	else if (hand == EQ::invslot::slotRange) {
		item_id = it->second.ranged;
	}

	if (!item_id) {
		return nullptr;
	}
	return database.GetItem(item_id);
}

void NmsVaultApplyLockerBonuses(Client *c, StatBonuses *b)
{
	if (!c || !b || !NmsVaultEnabled()) {
		return;
	}

	auto it = locker_cache.find(c->CharacterID());
	if (it == locker_cache.end() || !it->second.secondary) {
		return;
	}

	if (!it->second.secondary_is_shield) {
		return;
	}
	if (const auto *worn = c->GetInv().GetItem(EQ::invslot::slotSecondary)) {
		if (worn->GetItem() && worn->GetItem()->ItemType == EQ::item::ItemTypeShield) {
			return;
		}
	}

	auto *inst = database.CreateItem(
		it->second.secondary,
		it->second.secondary_charges,
		it->second.secondary_aug[0],
		it->second.secondary_aug[1],
		it->second.secondary_aug[2],
		it->second.secondary_aug[3],
		it->second.secondary_aug[4],
		it->second.secondary_aug[5]
	);
	if (!inst) {
		return;
	}
	c->AddItemBonuses(inst, b, false, true, 0, false);
	if (inst->GetItem() && inst->GetItem()->ItemType == EQ::item::ItemTypeShield) {
		c->SetShieldEquipped(true);
	}
	safe_delete(inst);
}
