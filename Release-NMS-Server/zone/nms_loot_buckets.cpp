#include "../common/global_define.h"
#include <fmt/format.h>
#include "nms_loot_buckets.h"

#include "../common/eqemu_logsys.h"
#include "../common/strings.h"
#include "zonedb.h"

#include <algorithm>
#include <string>
#include <unordered_map>
#include <unordered_set>

namespace {
	bool                                                loaded = false;
	bool                                                tables_present = false;
	uint32                                              member_count = 0;
	std::unordered_map<uint32, NmsLootBucketInfo>       buckets;
	std::unordered_map<std::string, uint32>             npc_zone_to_bucket;
	std::unordered_map<uint32, uint32>                  npc_to_bucket;
	std::unordered_map<uint32, std::unordered_set<uint32>> npc_bucket_ids;

	std::string NpcZoneKey(uint32 npc_id, const std::string &zone_sn)
	{
		return fmt::format("{}:{}", npc_id, Strings::ToLower(zone_sn));
	}

	bool TableExists(const char *name)
	{
		auto results = content_db.QueryDatabase(
			fmt::format("SHOW TABLES LIKE '{}'", name)
		);
		return results.Success() && results.RowCount() > 0;
	}
}

void NmsLoadLootBuckets()
{
	loaded = false;
	tables_present = false;
	member_count = 0;
	buckets.clear();
	npc_zone_to_bucket.clear();
	npc_to_bucket.clear();
	npc_bucket_ids.clear();

	if (!TableExists("nms_loot_buckets") ||
		!TableExists("nms_loot_bucket_npcs") ||
		!TableExists("nms_loot_bucket_items")) {
		LogInfo("nms_loot_bucket* tables are missing; shared-bucket loot stays off");
		loaded = true;
		return;
	}

	tables_present = true;

	auto bucket_rows = content_db.QueryDatabase(
		"SELECT id, kind FROM nms_loot_buckets"
	);
	if (!bucket_rows.Success()) {
		LogError("Failed to load nms_loot_buckets: {}", bucket_rows.ErrorMessage());
		loaded = true;
		return;
	}

	for (auto row : bucket_rows) {
		NmsLootBucketInfo info;
		info.id = static_cast<uint32>(std::stoul(row[0]));
		info.raid = Strings::ToLower(row[1] ? row[1] : "") == "raid";
		buckets.emplace(info.id, std::move(info));
	}

	auto item_rows = content_db.QueryDatabase(
		"SELECT bucket_id, item_id FROM nms_loot_bucket_items"
	);
	if (!item_rows.Success()) {
		LogError("Failed to load nms_loot_bucket_items: {}", item_rows.ErrorMessage());
		loaded = true;
		return;
	}

	for (auto row : item_rows) {
		const auto bucket_id = static_cast<uint32>(std::stoul(row[0]));
		const auto item_id = static_cast<uint32>(std::stoul(row[1])) % 1000000;
		auto it = buckets.find(bucket_id);
		if (it != buckets.end()) {
			it->second.items.push_back(item_id);
		}
	}

	for (auto &entry : buckets) {
		auto &info = entry.second;
		std::sort(info.items.begin(), info.items.end());
		info.items.erase(std::unique(info.items.begin(), info.items.end()), info.items.end());
	}

	auto npc_rows = content_db.QueryDatabase(
		"SELECT bucket_id, npc_id, zone_sn FROM nms_loot_bucket_npcs"
	);
	if (!npc_rows.Success()) {
		LogError("Failed to load nms_loot_bucket_npcs: {}", npc_rows.ErrorMessage());
		loaded = true;
		return;
	}

	for (auto row : npc_rows) {
		const auto bucket_id = static_cast<uint32>(std::stoul(row[0]));
		const auto npc_id = static_cast<uint32>(std::stoul(row[1]));
		const std::string zone_sn = row[2] ? row[2] : "";
		if (!buckets.count(bucket_id)) {
			continue;
		}
		npc_zone_to_bucket[NpcZoneKey(npc_id, zone_sn)] = bucket_id;
		npc_bucket_ids[npc_id].insert(bucket_id);
		++member_count;
	}

	for (const auto &[npc_id, ids] : npc_bucket_ids) {
		if (ids.size() == 1) {
			npc_to_bucket[npc_id] = *ids.begin();
		}
	}

	loaded = true;
	LogInfo(
		"Loaded {} loot buckets, {} npc mappings, {} unique npc ids",
		buckets.size(),
		member_count,
		npc_to_bucket.size()
	);
}

const NmsLootBucketInfo *NmsGetLootBucket(uint32 npc_id, const char *zone_sn)
{
	if (!loaded || !tables_present || member_count == 0) {
		return nullptr;
	}

	if (zone_sn && zone_sn[0]) {
		auto it = npc_zone_to_bucket.find(NpcZoneKey(npc_id, zone_sn));
		if (it != npc_zone_to_bucket.end()) {
			auto b = buckets.find(it->second);
			return b == buckets.end() ? nullptr : &b->second;
		}
	}

	auto it = npc_to_bucket.find(npc_id);
	if (it == npc_to_bucket.end()) {
		return nullptr;
	}
	auto b = buckets.find(it->second);
	return b == buckets.end() ? nullptr : &b->second;
}

bool NmsLootBucketsReady()
{
	return loaded && tables_present && member_count > 0;
}

uint32 NmsLootBucketMemberCount()
{
	return member_count;
}

bool NmsLootBucketContainsItem(const NmsLootBucketInfo *bucket, uint32 item_id)
{
	if (!bucket) {
		return false;
	}
	const uint32 base_id = item_id % 1000000;
	for (const auto id : bucket->items) {
		if (id == base_id) {
			return true;
		}
	}
	return false;
}
