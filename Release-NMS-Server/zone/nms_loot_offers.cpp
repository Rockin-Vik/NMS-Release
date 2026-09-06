#include "../common/global_define.h"
#include "nms_loot_offers.h"
#include "nms_vault.h"

#include "../common/eq_constants.h"
#include "../common/emu_constants.h"
#include "../common/eq_packet.h"
#include "../common/eq_packet_structs.h"
#include "../common/eqemu_logsys.h"
#include "../common/item_data.h"
#include "../common/item_instance.h"
#include "../common/loot.h"
#include "../common/misc_functions.h"
#include "../common/mysql_request_row.h"
#include "../common/rulesys.h"
#include "../common/strings.h"
#include "client.h"
#include "common.h"
#include "corpse.h"
#include "entity.h"
#include "groups.h"
#include "raids.h"
#include "zone.h"
#include "zonedb.h"

#include <climits>
#include <map>
#include <fmt/format.h>

extern ZoneDatabase database;
extern Zone *zone;

namespace {
	bool tables_checked = false;
	bool tables_ready = false;

	bool EnsureTables()
	{
		if (tables_checked) {
			return tables_ready;
		}
		tables_checked = true;
		auto table = database.QueryDatabase("SHOW TABLES LIKE 'character_nms_loot_offers'");
		if (!table.Success() || table.RowCount() == 0) {
			tables_ready = false;
			return tables_ready;
		}
		auto columns = database.QueryDatabase(
			"SELECT column_name, data_type, column_type FROM information_schema.columns "
			"WHERE table_schema = DATABASE() "
			"AND table_name = 'character_nms_loot_offers' "
			"AND column_name IN ('corpse_serial', 'instance_id', 'passed')"
		);
		tables_ready = false;
		if (!columns.Success() || columns.RowCount() < 3) {
			return tables_ready;
		}
		bool have_serial = false;
		bool have_instance = false;
		bool have_passed = false;
		for (auto row = columns.begin(); row != columns.end(); ++row) {
			const std::string name = Strings::ToLower(row[0] ? row[0] : "");
			const std::string type = Strings::ToLower(row[1] ? row[1] : "");
			const std::string column_type = Strings::ToLower(row[2] ? row[2] : "");
			if (name == "corpse_serial") {
				have_serial = type == "bigint" && Strings::Contains(column_type, "unsigned");
			}
			else if (name == "instance_id") {
				have_instance = true;
			}
			else if (name == "passed") {
				have_passed = true;
			}
		}
		tables_ready = have_serial && have_instance && have_passed;
		return tables_ready;
	}

	int RemainingExpireSeconds(const NmsLootOffer &offer)
	{
		return offer.expire_remaining > 0 ? offer.expire_remaining : 1;
	}

	void ExpireOffers(uint32 character_id)
	{
		if (!EnsureTables()) {
			return;
		}
		database.QueryDatabase(fmt::format(
			"DELETE FROM character_nms_loot_offers WHERE character_id = {} AND expires_at < NOW()",
			character_id
		));
	}

	bool DeleteOffer(uint32 character_id, uint32 offer_id)
	{
		if (!EnsureTables() || !offer_id || !character_id) {
			return false;
		}
		auto results = database.QueryDatabase(fmt::format(
			"DELETE FROM character_nms_loot_offers WHERE id = {} AND character_id = {}",
			offer_id,
			character_id
		));
		return results.Success() && results.RowsAffected() > 0;
	}

	bool SaveOffer(NmsLootOffer &offer, int expire_seconds)
	{
		if (!EnsureTables() || !zone) {
			return false;
		}

		auto results = database.QueryDatabase(fmt::format(
			"INSERT INTO character_nms_loot_offers "
			"(character_id, zone_id, instance_id, corpse_id, corpse_serial, item_id, icon, charges, bonus, name, "
			"aug1, aug2, aug3, aug4, aug5, aug6, passed, expires_at) "
			"VALUES ({}, {}, {}, {}, {}, {}, {}, {}, {}, '{}', {}, {}, {}, {}, {}, {}, {}, "
			"DATE_ADD(NOW(), INTERVAL {} SECOND))",
			offer.character_id,
			offer.zone_id ? offer.zone_id : zone->GetZoneID(),
			offer.instance_id,
			offer.corpse_id,
			offer.corpse_serial,
			offer.item_id,
			offer.icon,
			offer.charges,
			offer.bonus,
			Strings::Escape(offer.name),
			offer.aug[0],
			offer.aug[1],
			offer.aug[2],
			offer.aug[3],
			offer.aug[4],
			offer.aug[5],
			offer.passed ? 1 : 0,
			expire_seconds
		));
		if (!results.Success()) {
			return false;
		}
		offer.id = results.LastInsertedID();
		if (!offer.id) {
			return false;
		}
		offer.expire_remaining = expire_seconds > 0 ? expire_seconds : 1;
		return true;
	}

	NmsLootOffer RowToOffer(MySQLRequestRow &row)
	{
		NmsLootOffer offer;
		offer.id = Strings::ToUnsignedInt(row[0]);
		offer.character_id = Strings::ToUnsignedInt(row[1]);
		offer.zone_id = Strings::ToUnsignedInt(row[2]);
		offer.instance_id = Strings::ToUnsignedInt(row[3]);
		offer.corpse_id = Strings::ToUnsignedInt(row[4]);
		offer.corpse_serial = Strings::ToUnsignedBigInt(row[5]);
		offer.item_id = Strings::ToUnsignedInt(row[6]);
		offer.icon = Strings::ToUnsignedInt(row[7]);
		offer.charges = static_cast<int16>(Strings::ToInt(row[8]));
		offer.bonus = static_cast<uint8>(Strings::ToInt(row[9]));
		offer.name = row[10] ? row[10] : "";
		for (int i = 0; i < 6; ++i) {
			offer.aug[i] = Strings::ToUnsignedInt(row[11 + i]);
		}
		offer.passed = Strings::ToInt(row[17]) != 0;
		offer.expire_remaining = Strings::ToInt(row[18]);
		return offer;
	}

	const char *OfferSelectColumns()
	{
		return "id, character_id, zone_id, instance_id, corpse_id, corpse_serial, item_id, icon, charges, bonus, name, "
			"aug1, aug2, aug3, aug4, aug5, aug6, passed, "
			"GREATEST(0, UNIX_TIMESTAMP(expires_at) - UNIX_TIMESTAMP(NOW()))";
	}

	bool LoadOfferById(uint32 character_id, uint32 offer_id, NmsLootOffer &out)
	{
		if (!EnsureTables() || !character_id || !offer_id) {
			return false;
		}

		auto results = database.QueryDatabase(fmt::format(
			"SELECT {} FROM character_nms_loot_offers "
			"WHERE id = {} AND character_id = {} AND passed = 0 AND expires_at >= NOW()",
			OfferSelectColumns(),
			offer_id,
			character_id
		));
		if (!results.Success() || results.RowCount() == 0) {
			return false;
		}

		out = RowToOffer(results.begin());
		return true;
	}

	std::vector<NmsLootOffer> LoadOffers(uint32 character_id, uint32 zone_id, uint32 corpse_id, uint64 corpse_serial)
	{
		std::vector<NmsLootOffer> out;
		if (!EnsureTables()) {
			return out;
		}

		std::string sql = fmt::format(
			"SELECT {} FROM character_nms_loot_offers WHERE character_id = {} AND expires_at >= NOW()",
			OfferSelectColumns(),
			character_id
		);
		if (zone_id) {
			sql += fmt::format(" AND zone_id = {} AND instance_id = {}", zone_id, zone ? zone->GetInstanceID() : 0);
		}
		if (corpse_id) {
			sql += fmt::format(" AND corpse_id = {}", corpse_id);
		}
		if (corpse_serial) {
			sql += fmt::format(" AND corpse_serial = {}", corpse_serial);
		}
		sql += " ORDER BY id";

		auto results = database.QueryDatabase(sql);
		if (!results.Success()) {
			return out;
		}

		for (auto row = results.begin(); row != results.end(); ++row) {
			out.push_back(RowToOffer(row));
		}
		return out;
	}

	void SendOffers(Client *c, const std::vector<NmsLootOffer> &offers, uint32 corpse_id)
	{
		if (!c) {
			return;
		}

		std::vector<const NmsLootOffer *> active;
		active.reserve(offers.size());
		for (const auto &offer : offers) {
			if (!offer.passed) {
				active.push_back(&offer);
			}
		}
		if (active.empty()) {
			return;
		}

		const uint32 count = static_cast<uint32>(active.size());
		int expire = RemainingExpireSeconds(*active.front());
		for (const auto *offer : active) {
			const int remain = RemainingExpireSeconds(*offer);
			if (remain < expire) {
				expire = remain;
			}
		}
		const uint32 size = sizeof(NmsLootOfferHeader_Struct) + (count * sizeof(NmsLootOfferEntry_Struct));
		auto outapp = new EQApplicationPacket(OP_NmsLootOffer, size);
		auto *header = reinterpret_cast<NmsLootOfferHeader_Struct *>(outapp->pBuffer);
		header->count = count;
		header->corpse_id = corpse_id;
		header->expire_seconds = static_cast<uint32>(expire);

		auto *entries = reinterpret_cast<NmsLootOfferEntry_Struct *>(outapp->pBuffer + sizeof(NmsLootOfferHeader_Struct));
		for (uint32 i = 0; i < count; ++i) {
			entries[i].offer_id = active[i]->id;
			entries[i].item_id = active[i]->item_id;
			entries[i].icon = active[i]->icon;
			entries[i].charges = active[i]->charges;
			entries[i].bonus = active[i]->bonus;
			strn0cpy(entries[i].name, active[i]->name.c_str(), sizeof(entries[i].name));
		}

		c->QueuePacket(outapp);
		safe_delete(outapp);
	}

	EQ::ItemInstance *MakeLootItem(const NmsLootOffer &offer)
	{
		return database.CreateItem(
			offer.item_id,
			offer.charges,
			offer.aug[0],
			offer.aug[1],
			offer.aug[2],
			offer.aug[3],
			offer.aug[4],
			offer.aug[5]
		);
	}

	bool OfferHasAugments(const NmsLootOffer &offer)
	{
		for (int i = 0; i < 6; ++i) {
			if (offer.aug[i]) {
				return true;
			}
		}
		return false;
	}

	bool LootItemMatchesOffer(const LootItem *item, const NmsLootOffer &offer)
	{
		return item
			&& item->item_id == offer.item_id
			&& item->charges == static_cast<uint16>(offer.charges > 0 ? offer.charges : 1)
			&& item->aug_1 == offer.aug[0]
			&& item->aug_2 == offer.aug[1]
			&& item->aug_3 == offer.aug[2]
			&& item->aug_4 == offer.aug[3]
			&& item->aug_5 == offer.aug[4]
			&& item->aug_6 == offer.aug[5];
	}

	LootItem *FindMatchingLootItem(Corpse *corpse, const NmsLootOffer &offer)
	{
		if (!corpse) {
			return nullptr;
		}
		for (auto *item : corpse->GetLootItems()) {
			if (LootItemMatchesOffer(item, offer)) {
				return item;
			}
		}
		return nullptr;
	}

	bool RecheckLiveCorpse(Client *c, const NmsLootOffer &offer, Corpse **out_corpse)
	{
		if (out_corpse) {
			*out_corpse = nullptr;
		}
		if (!c) {
			return false;
		}
		if (!offer.corpse_id || !offer.corpse_serial) {
			return false;
		}
		if (!zone || offer.zone_id != zone->GetZoneID() || offer.instance_id != zone->GetInstanceID()) {
			return false;
		}

		auto *ent = entity_list.GetID(offer.corpse_id);
		if (!ent || !ent->IsCorpse()) {
			return false;
		}

		auto *corpse = ent->CastToCorpse();
		if (corpse->GetNmsLootSerial() != offer.corpse_serial) {
			return false;
		}
		if (corpse->IsPlayerCorpse()) {
			return false;
		}
		if (corpse->IsLocked() && c->Admin() < AccountStatus::GMAdmin) {
			return false;
		}
		if (DistanceSquaredNoZ(c->GetPosition(), corpse->GetPosition()) > 625) {
			return false;
		}
		if (!corpse->CanPlayerLoot(static_cast<int>(c->CharacterID()))) {
			return false;
		}
		if (!FindMatchingLootItem(corpse, offer)) {
			return false;
		}

		if (out_corpse) {
			*out_corpse = corpse;
		}
		return true;
	}

	bool RemoveMatchingFromCorpse(Corpse *corpse, const NmsLootOffer &offer)
	{
		auto *match = FindMatchingLootItem(corpse, offer);
		if (!match) {
			return false;
		}
		corpse->RemoveItem(match, false);
		return true;
	}

	void RestoreCorpseItem(Corpse *corpse, const NmsLootOffer &offer)
	{
		if (!corpse) {
			return;
		}
		corpse->AddItem(
			offer.item_id,
			static_cast<uint16>(offer.charges > 0 ? offer.charges : 1),
			0,
			offer.aug[0],
			offer.aug[1],
			offer.aug[2],
			offer.aug[3],
			offer.aug[4],
			offer.aug[5]
		);
	}

	bool PutInBank(Client *c, EQ::ItemInstance *inst)
	{
		if (!c || !inst) {
			return false;
		}
		for (int16 slot = EQ::invslot::BANK_BEGIN; slot <= EQ::invslot::BANK_END; ++slot) {
			if (c->GetInv().GetItem(slot)) {
				continue;
			}
			if (c->PutItemInInventory(slot, *inst, true)) {
				return true;
			}
			auto *placed = c->GetInv().GetItem(slot);
			if (placed && inst->GetItem() && placed->GetItem()
				&& placed->GetItem()->ID == inst->GetItem()->ID) {
				return true;
			}
		}
		return false;
	}

	bool EligiblePassTarget(Client *from, Client *to, Corpse *corpse)
	{
		if (!from || !to || from == to) {
			return false;
		}
		if (corpse) {
			return corpse->CanPlayerLoot(static_cast<int>(to->CharacterID()));
		}
		if (from->GetGroup() && from->GetGroup()->IsGroupMember(to)) {
			return true;
		}
		if (from->GetRaid() && from->GetRaid()->IsRaidMember(to)) {
			return true;
		}
		return false;
	}

	bool CanAddSellCopper(Client *c, uint64 copper)
	{
		if (!c) {
			return false;
		}
		const int32 current_plat = c->GetPP().platinum;
		if (current_plat < 0) {
			return false;
		}
		const uint64 plat = copper / 1000;
		return plat <= static_cast<uint64>(INT32_MAX) - static_cast<uint64>(current_plat);
	}
}

void NmsLootOfferForgetCorpseItem(uint32 character_id, uint32 corpse_id, const LootItem *item)
{
	if (!EnsureTables() || !character_id || !corpse_id || !item || !item->item_id) {
		return;
	}
	database.QueryDatabase(fmt::format(
		"DELETE FROM character_nms_loot_offers WHERE character_id = {} AND corpse_id = {} "
		"AND item_id = {} AND aug1 = {} AND aug2 = {} AND aug3 = {} AND aug4 = {} AND aug5 = {} AND aug6 = {}",
		character_id,
		corpse_id,
		item->item_id,
		item->aug_1,
		item->aug_2,
		item->aug_3,
		item->aug_4,
		item->aug_5,
		item->aug_6
	));
}

bool NmsLootOffersEnabled()
{
	return RuleB(Custom, NmsLootOffers);
}

bool NmsLootOfferTablesReady()
{
	return EnsureTables();
}

void NmsLootOfferOnCorpseOpen(Client *c, Corpse *corpse)
{
	if (!c || !corpse || !NmsLootOffersEnabled() || !EnsureTables() || !zone) {
		return;
	}
	if (!corpse->IsBeingLootedBy(c)) {
		return;
	}

	const auto loot_type = corpse->GetLootRequestType();
	if (loot_type != LootRequestType::AllowedPVE && loot_type != LootRequestType::GMAllowed) {
		return;
	}
	if (corpse->IsPlayerCorpse()) {
		return;
	}
	if (!corpse->CanPlayerLoot(static_cast<int>(c->CharacterID()))) {
		return;
	}

	ExpireOffers(c->CharacterID());
	database.QueryDatabase(fmt::format(
		"DELETE FROM character_nms_loot_offers WHERE character_id = {} AND zone_id = {} "
		"AND instance_id = {} AND corpse_id = {} AND corpse_serial != {} AND passed = 0",
		c->CharacterID(),
		zone->GetZoneID(),
		zone->GetInstanceID(),
		corpse->GetID(),
		corpse->GetNmsLootSerial()
	));

	auto existing = LoadOffers(c->CharacterID(), zone->GetZoneID(), corpse->GetID(), corpse->GetNmsLootSerial());
	if (!existing.empty()) {
		SendOffers(c, existing, corpse->GetID());
		return;
	}

	const int expire_seconds = RuleI(Custom, NmsLootOfferExpireSeconds);
	std::vector<NmsLootOffer> created;
	for (auto *item : corpse->GetLootItems()) {
		if (!item || !item->item_id) {
			continue;
		}
		const auto *data = database.GetItem(item->item_id);
		if (!data) {
			continue;
		}

		NmsLootOffer offer;
		offer.character_id = c->CharacterID();
		offer.zone_id = zone->GetZoneID();
		offer.instance_id = zone->GetInstanceID();
		offer.corpse_id = corpse->GetID();
		offer.corpse_serial = corpse->GetNmsLootSerial();
		offer.item_id = item->item_id;
		offer.icon = data->Icon;
		offer.charges = static_cast<int16>(item->charges);
		offer.bonus = 0;
		offer.name = data->Name;
		offer.aug[0] = item->aug_1;
		offer.aug[1] = item->aug_2;
		offer.aug[2] = item->aug_3;
		offer.aug[3] = item->aug_4;
		offer.aug[4] = item->aug_5;
		offer.aug[5] = item->aug_6;
		if (SaveOffer(offer, expire_seconds)) {
			created.push_back(offer);
		}
	}

	if (!created.empty()) {
		SendOffers(c, created, corpse->GetID());
	}
}

void NmsLootOfferRestoreOnZoneIn(Client *c)
{
	if (!c || !NmsLootOffersEnabled() || !EnsureTables() || !zone) {
		return;
	}

	ExpireOffers(c->CharacterID());
	auto offers = LoadOffers(c->CharacterID(), zone->GetZoneID(), 0, 0);
	uint32 active = 0;
	for (const auto &offer : offers) {
		if (!offer.passed) {
			++active;
		}
	}
	if (!active) {
		return;
	}

	std::map<uint32, std::vector<NmsLootOffer>> by_corpse;
	for (const auto &offer : offers) {
		if (!offer.passed) {
			by_corpse[offer.corpse_id].push_back(offer);
		}
	}
	for (auto &entry : by_corpse) {
		SendOffers(c, entry.second, entry.first);
	}
	c->Message(
		Chat::White,
		"[NMS] %u unclaimed loot items recovered from your last visit to this zone.",
		active
	);
}

void NmsLootOfferHandleDecision(Client *c, const EQApplicationPacket *app)
{
	if (!c || !app || !NmsLootOffersEnabled() || !EnsureTables()) {
		return;
	}
	if (app->size != sizeof(NmsLootDecision_Struct)) {
		LogError(
			"Received OP_NmsLootDecision packet. Expected size {}, received size {}.",
			sizeof(NmsLootDecision_Struct),
			app->size
		);
		return;
	}

	const auto *in = reinterpret_cast<const NmsLootDecision_Struct *>(app->pBuffer);
	if (!in->offer_id) {
		c->Message(Chat::White, "[NMS] That loot offer has expired.");
		return;
	}

	char pass_to[64] = {0};
	strn0cpy(pass_to, in->pass_to, sizeof(pass_to));

	ExpireOffers(c->CharacterID());

	NmsLootOffer match;
	if (!LoadOfferById(c->CharacterID(), in->offer_id, match)) {
		c->Message(Chat::White, "[NMS] That loot offer has expired.");
		return;
	}
	if (in->item_id && in->item_id != match.item_id) {
		c->Message(Chat::White, "[NMS] That loot offer has expired.");
		return;
	}
	if (in->corpse_id && in->corpse_id != match.corpse_id) {
		c->Message(Chat::White, "[NMS] That loot offer has expired.");
		return;
	}
	if (in->quantity > 0 && in->quantity < static_cast<uint32>(match.charges > 0 ? match.charges : 1)) {
		c->Message(Chat::White, "[NMS] Partial quantity is not supported.");
		return;
	}

	if (!DeleteOffer(c->CharacterID(), match.id)) {
		c->Message(Chat::White, "[NMS] That loot offer has expired.");
		return;
	}

	if (!NmsLootOfferApply(c, match, static_cast<NmsLootAction>(in->action), pass_to)) {
		if (match.expire_remaining <= 0) {
			return;
		}
		match.id = 0;
		match.passed = false;
		if (SaveOffer(match, match.expire_remaining)) {
			std::vector<NmsLootOffer> one{match};
			SendOffers(c, one, match.corpse_id);
		}
	}
}

bool NmsLootOfferApply(Client *c, const NmsLootOffer &offer, NmsLootAction action, const std::string &pass_to)
{
	if (!c) {
		return false;
	}

	Corpse *corpse = nullptr;
	if (!RecheckLiveCorpse(c, offer, &corpse)) {
		c->Message(Chat::White, "[NMS] That loot offer is no longer available.");
		return false;
	}

	const auto *item = database.GetItem(offer.item_id);
	const std::string item_name = offer.name.empty() && item ? item->Name : offer.name;
	const int16 qty = offer.charges > 0 ? offer.charges : 1;
	bool removed_from_corpse = false;

	auto take_from_corpse = [&]() -> bool {
		if (!corpse || !RemoveMatchingFromCorpse(corpse, offer)) {
			c->Message(Chat::White, "[NMS] That loot offer is no longer available.");
			return false;
		}
		removed_from_corpse = true;
		return true;
	};

	auto restore_if_needed = [&]() {
		if (removed_from_corpse && corpse) {
			RestoreCorpseItem(corpse, offer);
		}
	};

	switch (action) {
	case NmsLootAction::Keep: {
		if (item && c->CheckLoreConflict(item)) {
			c->Message(Chat::White, "[NMS] Cannot loot %s - you already have one of this LORE item.", item_name.c_str());
			return false;
		}
		auto *inst = MakeLootItem(offer);
		if (!inst) {
			c->Message(Chat::Red, "[NMS] Could not create %s.", item_name.c_str());
			return false;
		}
		if (!take_from_corpse()) {
			safe_delete(inst);
			return false;
		}
		const int16 before = inst->GetCharges();
		const bool cursor_ok = c->GetInv().CursorSize() < EQ::invbag::CURSOR_BAG_COUNT;
		if (!c->AutoPutLootInInventory(*inst, false, cursor_ok)) {
			const int16 left = inst->GetCharges();
			if (left < before) {
				if (left > 0) {
					NmsLootOffer leftover = offer;
					leftover.id = 0;
					leftover.charges = left;
					RestoreCorpseItem(corpse, leftover);
					if (SaveOffer(leftover, RemainingExpireSeconds(offer))) {
						std::vector<NmsLootOffer> one{leftover};
						SendOffers(c, one, leftover.corpse_id);
					}
				}
				c->Message(Chat::White, "[NMS] %s added to inventory.", item_name.c_str());
				safe_delete(inst);
				return true;
			}
			c->Message(Chat::Red, "[NMS] Your inventory is full.");
			restore_if_needed();
			safe_delete(inst);
			return false;
		}
		c->Message(Chat::White, "[NMS] %s added to inventory.", item_name.c_str());
		safe_delete(inst);
		return true;
	}
	case NmsLootAction::Sell: {
		if (!item || item->Price == 0 || item->NoDrop == 0 || item->SummonedFlag || OfferHasAugments(offer)) {
			c->Message(Chat::White, "[NMS] %s has no sell value - please pick another option.", item_name.c_str());
			return false;
		}
		const uint64 copper = static_cast<uint64>(item->Price) * static_cast<uint64>(qty);
		if (!CanAddSellCopper(c, copper)) {
			c->Message(Chat::Red, "[NMS] You cannot carry that much coin.");
			return false;
		}
		if (!take_from_corpse()) {
			return false;
		}
		c->AddMoneyToPP(copper, true);
		c->Message(
			Chat::White,
			"[NMS] %s sold for %s.",
			item_name.c_str(),
			Strings::Money(copper / 1000, (copper / 100) % 10, (copper / 10) % 10, copper % 10).c_str()
		);
		return true;
	}
	case NmsLootAction::Tribute: {
		if (!item || item->Favor == 0 || item->NoDrop == 0 || OfferHasAugments(offer)) {
			c->Message(Chat::White, "[NMS Tribute] %s has no tribute value - please pick another option.", item_name.c_str());
			return false;
		}
		const int64 favor64 = static_cast<int64>(item->Favor) * static_cast<int64>(qty);
		if (favor64 <= 0 || favor64 > INT32_MAX) {
			c->Message(Chat::White, "[NMS Tribute] %s has no tribute value - please pick another option.", item_name.c_str());
			return false;
		}
		if (!take_from_corpse()) {
			return false;
		}
		const int32 favor = static_cast<int32>(favor64);
		c->AddTributePoints(favor);
		c->Message(Chat::White, "[NMS] %s tributed for %d favor points.", item_name.c_str(), favor);
		return true;
	}
	case NmsLootAction::Bank: {
		if (!NmsVaultEnabled() || !NmsVaultTablesReady()) {
			c->Message(Chat::Red, "[NMS] Vault banking is not available.");
			return false;
		}
		auto *inst = MakeLootItem(offer);
		if (!inst) {
			return false;
		}
		if (!take_from_corpse()) {
			safe_delete(inst);
			return false;
		}
		if (!PutInBank(c, inst)) {
			c->Message(Chat::Red, "[NMS] Your bank is full.");
			restore_if_needed();
			safe_delete(inst);
			return false;
		}
		c->Message(Chat::White, "[NMS] %s added to your bank.", item_name.c_str());
		safe_delete(inst);
		return true;
	}
	case NmsLootAction::Vault: {
		auto *inst = MakeLootItem(offer);
		if (!inst) {
			return false;
		}
		const int vault_slot = NmsVaultTryDepositInstance(c, inst);
		if (!vault_slot) {
			c->Message(Chat::Red, "[NMS] Your vault is full.");
			safe_delete(inst);
			return false;
		}
		if (!take_from_corpse()) {
			if (!NmsVaultDeleteItem(c->CharacterID(), vault_slot, 0)) {
				LogError(
					"NmsLoot: vault rollback delete failed for character {} slot {}",
					c->CharacterID(),
					vault_slot
				);
			}
			NmsVaultSendRefresh(c, NmsVaultPageForSlot(vault_slot));
			safe_delete(inst);
			return false;
		}
		c->Message(Chat::White, "[NMS] %s added to your vault.", item_name.c_str());
		safe_delete(inst);
		return true;
	}
	case NmsLootAction::Destroy:
		if (!take_from_corpse()) {
			return false;
		}
		c->Message(Chat::White, "[NMS] Item destroyed.");
		return true;
	case NmsLootAction::Pass: {
		if (pass_to.empty()) {
			c->Message(Chat::Red, "[NMS] Choose a player to pass that item to.");
			return false;
		}
		if (!item || item->NoDrop == 0) {
			c->Message(Chat::Red, "[NMS] That item cannot be passed.");
			return false;
		}

		auto *other = entity_list.GetClientByName(pass_to.c_str());
		if (!other || other == c) {
			c->Message(Chat::Red, "[NMS] That player is not a valid pass target.");
			return false;
		}
		if (!EligiblePassTarget(c, other, corpse)) {
			c->Message(Chat::Red, "[NMS] That player is not a valid pass target.");
			return false;
		}
		if (other->CheckLoreConflict(item)) {
			c->Message(Chat::Red, "[NMS] That player cannot receive this LORE item.");
			return false;
		}
		if (!corpse) {
			c->Message(Chat::White, "[NMS] That loot offer is no longer available.");
			return false;
		}

		const int dest_expire = RemainingExpireSeconds(offer);
		NmsLootOffer tomb = offer;
		tomb.id = 0;
		tomb.character_id = c->CharacterID();
		tomb.passed = true;
		if (zone) {
			tomb.zone_id = zone->GetZoneID();
			tomb.instance_id = zone->GetInstanceID();
		}
		if (!SaveOffer(tomb, dest_expire)) {
			c->Message(Chat::Red, "[NMS] Could not pass %s.", item_name.c_str());
			return false;
		}

		NmsLootOffer dest = offer;
		dest.id = 0;
		dest.character_id = other->CharacterID();
		dest.passed = false;
		if (zone) {
			dest.zone_id = zone->GetZoneID();
			dest.instance_id = zone->GetInstanceID();
		}
		if (!SaveOffer(dest, dest_expire)) {
			DeleteOffer(c->CharacterID(), tomb.id);
			c->Message(Chat::Red, "[NMS] Could not pass %s.", item_name.c_str());
			return false;
		}

		std::vector<NmsLootOffer> one{dest};
		SendOffers(other, one, dest.corpse_id);
		other->Message(Chat::White, "[NMS] %s passed %s to you.", c->GetName(), item_name.c_str());
		return true;
	}
	default:
		c->Message(Chat::Red, "[NMS] Unknown loot action.");
		return false;
	}
}
