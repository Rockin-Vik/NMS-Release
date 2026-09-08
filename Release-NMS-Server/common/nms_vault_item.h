#ifndef NMS_VAULT_ITEM_H
#define NMS_VAULT_ITEM_H

#include "types.h"

static constexpr uint32 NMS_VAULT_ARMORY_ITEM_ID = 9011013;

// 9011013 % 1000000 == 11013, which is also stock Boots of Quickness.
// Upgrade tiers keep that remainder; only this custom id and higher copies count.
inline bool NmsVaultIsArmoryItem(uint32 item_id)
{
	return item_id >= NMS_VAULT_ARMORY_ITEM_ID
		&& (item_id % 1000000u) == (NMS_VAULT_ARMORY_ITEM_ID % 1000000u);
}

#endif
