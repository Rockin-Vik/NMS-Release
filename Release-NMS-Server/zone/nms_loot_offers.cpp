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
		auto table = database.QueryDatabase("SHOW TABLES LIKE 'character_nms_loot_offers'");
		// A failed QUERY is not a failed SCHEMA. Latching tables_checked before the answer
		// was known meant one transient DB error at first use disabled loot offers for the
		// whole life of the zone process, and hid a schema fix applied to a running server
		// until restart. Only a definitive answer is cached; a query failure retries.
		if (!table.Success()) {
			LogError("NmsLootOffers: table check query failed; will retry on next use");
			return false;
		}
		if (table.RowCount() == 0) {
			tables_checked = true;
			tables_ready   = false;
			return tables_ready;
		}
		auto columns = database.QueryDatabase(
			"SELECT column_name, data_type, column_type FROM information_schema.columns "
			"WHERE table_schema = DATABASE() "
			"AND table_name = 'character_nms_loot_offers' "
			"AND column_name IN ('corpse_serial', 'instance_id', 'passed', 'passed_from')"
		);
		if (!columns.Success()) {
			LogError("NmsLootOffers: column check query failed; will retry on next use");
			return false;
		}
		tables_checked = true;
		tables_ready   = false;
		if (columns.RowCount() < 4) {
			return tables_ready;
		}
		bool have_serial = false;
		bool have_instance = false;
		bool have_passed = false;
		bool have_passed_from = false;
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
			else if (name == "passed_from") {
				have_passed_from = true;
			}
		}
		tables_ready = have_serial && have_instance && have_passed && have_passed_from;
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
		if (expire_seconds < 1) {
			expire_seconds = 1;
		}

		auto results = database.QueryDatabase(fmt::format(
			"INSERT INTO character_nms_loot_offers "
			"(character_id, zone_id, instance_id, corpse_id, corpse_serial, item_id, icon, charges, bonus, name, "
			"aug1, aug2, aug3, aug4, aug5, aug6, passed, passed_from, expires_at) "
			"VALUES ({}, {}, {}, {}, {}, {}, {}, {}, {}, '{}', {}, {}, {}, {}, {}, {}, {}, '{}', "
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
			Strings::Escape(offer.passed_from),
			expire_seconds
		));
		if (!results.Success()) {
			return false;
		}
		offer.id = results.LastInsertedID();
		if (!offer.id) {
			return false;
		}
		offer.expire_remaining = expire_seconds;
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
		offer.passed_from = row[18] ? row[18] : "";
		offer.expire_remaining = Strings::ToInt(row[19]);
		return offer;
	}

	const char *OfferSelectColumns()
	{
		return "id, character_id, zone_id, instance_id, corpse_id, corpse_serial, item_id, icon, charges, bonus, name, "
			"aug1, aug2, aug3, aug4, aug5, aug6, passed, passed_from, "
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

		uint32 count = static_cast<uint32>(active.size());
		if (count > 64) {
			count = 64;
		}
		int expire = RemainingExpireSeconds(*active.front());
		for (uint32 i = 0; i < count; ++i) {
			const int remain = RemainingExpireSeconds(*active[i]);
			if (remain < expire) {
				expire = remain;
			}
		}
		const uint32 size = sizeof(NmsLootOfferHeader_Struct) + (count * sizeof(NmsLootOfferEntry_Struct));
		auto outapp = new EQApplicationPacket(OP_NmsLootOffer, size);
		memset(outapp->pBuffer, 0, size);
		auto *header = reinterpret_cast<NmsLootOfferHeader_Struct *>(outapp->pBuffer);
		header->count = count;
		header->corpse_id = corpse_id;
		header->expire_seconds = static_cast<uint32>(expire);
		if (auto *corpse = entity_list.GetCorpseByID(static_cast<uint16>(corpse_id))) {
			strn0cpy(header->title, corpse->GetName(), sizeof(header->title));
		}

		auto *entries = reinterpret_cast<NmsLootOfferEntry_Struct *>(outapp->pBuffer + sizeof(NmsLootOfferHeader_Struct));
		for (uint32 i = 0; i < count; ++i) {
			entries[i].offer_id = active[i]->id;
			entries[i].icon = active[i]->icon;
			entries[i].charges = active[i]->charges;
			entries[i].item_id = active[i]->item_id;
			entries[i].bonus = active[i]->bonus;
			strn0cpy(entries[i].name, active[i]->name.c_str(), sizeof(entries[i].name));
			if (!active[i]->passed_from.empty()) {
				strn0cpy(entries[i].name2, active[i]->passed_from.c_str(), sizeof(entries[i].name2));
			}
		}

		c->QueuePacket(outapp);
		safe_delete(outapp);
	}

	// A corpse item can legitimately carry charges == 0: quest scripts call AddItem(id, 0)
	// directly (greatdivide/Sentry_Badain.lua, encounters/RingTen.lua) and lootdrop_entries
	// rows exist with item_charges = 0. Stock treats zero as one when it builds the instance
	// (corpse.cpp:1151), and so did every other site in this file EXCEPT the two below.
	//
	// LootItemMatchesOffer normalised only the OFFER side, so a zero-charge corpse item was
	// compared as 0 == 1 and could never match: the offer showed up in Pending and then
	// refused every Keep, Sell, Tribute, Destroy and Pass, re-sending itself each time until
	// it expired. One helper, applied consistently, is what keeps the comparison symmetric.
	int32 NormalizeChargeCount(int32 charges)
	{
		return charges > 0 ? charges : 1;
	}

	EQ::ItemInstance *MakeLootItem(const NmsLootOffer &offer)
	{
		return database.CreateItem(
			offer.item_id,
			static_cast<int16>(NormalizeChargeCount(offer.charges)),
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
			&& NormalizeChargeCount(item->charges) == NormalizeChargeCount(offer.charges)
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
			static_cast<uint16>(NormalizeChargeCount(offer.charges)),
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
	// Rule first, then tables - the same order every other entry point in this file uses
	// (:507, :582, :616). Without the rule check this ran on EVERY native corpse loot on a
	// server that had merely applied the migrations, issuing a blocking DELETE per item
	// removed - including the per-item loops in Corpse::RemoveItemByPercent and the bag
	// content loop - for a feature that was switched off. Stock loot must be untouched when
	// the rule is off (design decision D4/D7). Rows written while the rule was on are left
	// behind deliberately: they carry expires_at and are reclaimed by ExpireOffers, and no
	// offer is sent or actioned while the rule is off, so a stale row is inert.
	if (!NmsLootOffersEnabled() || !EnsureTables() || !character_id || !corpse_id || !item || !item->item_id) {
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
	strn0cpy(pass_to, in->name, sizeof(pass_to));

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

	auto action = static_cast<NmsLootAction>(in->action);
	if (action == NmsLootAction::ReturnToPasser) {
		action = NmsLootAction::Pass;
	}
	if (action < NmsLootAction::Keep || action > NmsLootAction::Pass) {
		c->Message(Chat::Red, "[NMS] Unknown loot action.");
		return;
	}
	if (action == NmsLootAction::Pass && pass_to[0] == '\0') {
		c->Message(Chat::Red, "[NMS] Choose a player to pass that item to.");
		return;
	}

	if (!DeleteOffer(c->CharacterID(), match.id)) {
		c->Message(Chat::White, "[NMS] That loot offer has expired.");
		return;
	}

	if (!NmsLootOfferApply(c, match, action, pass_to)) {
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
	const int16 qty = static_cast<int16>(NormalizeChargeCount(offer.charges));
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
		dest.passed_from = c->GetName();
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
