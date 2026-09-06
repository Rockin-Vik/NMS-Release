#ifndef NMS_LOOT_BUCKETS_H
#define NMS_LOOT_BUCKETS_H

#include "../common/types.h"

#include <vector>

struct NmsLootBucketInfo {
	uint32              id = 0;
	bool                raid = false;
	std::vector<uint32> items;
};

void NmsLoadLootBuckets();
const NmsLootBucketInfo *NmsGetLootBucket(uint32 npc_id, const char *zone_sn);
bool NmsLootBucketsReady();
uint32 NmsLootBucketMemberCount();
bool NmsLootBucketContainsItem(const NmsLootBucketInfo *bucket, uint32 item_id);

#endif
