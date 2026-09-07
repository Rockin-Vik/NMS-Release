#ifndef NMS_VAULT_H
#define NMS_VAULT_H

#include "../common/types.h"
#include <string>
#include <vector>

class Client;
class Mob;
struct StatBonuses;
namespace EQ {
	class ItemInstance;
	struct ItemData;
}

static constexpr int NMS_VAULT_SLOT_MIN = 1;
static constexpr int NMS_VAULT_SLOT_MAX = 83;
static constexpr int NMS_VAULT_CLICKY_BEGIN = 61;
static constexpr int NMS_VAULT_CLICKY_END = 80;
static constexpr int NMS_VAULT_PROC_PRIMARY = 81;
static constexpr int NMS_VAULT_PROC_SECONDARY = 82;
static constexpr int NMS_VAULT_PROC_RANGED = 83;

struct NmsVaultItem {
	int      slot = 0;
	int      bag_slot = 0;
	uint32   item_id = 0;
	int16    charges = 0;
	uint32   aug[6] = {0, 0, 0, 0, 0, 0};
};

bool NmsVaultEnabled();
int NmsVaultPageForSlot(int slot);
bool NmsVaultSlotValid(int slot);
bool NmsVaultTablesReady();

bool NmsVaultLoad(uint32 character_id, std::vector<NmsVaultItem> &out);
const NmsVaultItem *NmsVaultFind(const std::vector<NmsVaultItem> &items, int slot, int bag_slot);
bool NmsVaultSaveItem(uint32 character_id, const NmsVaultItem &item);
bool NmsVaultDeleteItem(uint32 character_id, int slot, int bag_slot);

void NmsVaultSendRefresh(Client *c, int open_page);
void NmsVaultHandlePage(Client *c, int page);
void NmsVaultHandleDeposit(Client *c, int slot);
void NmsVaultHandleWithdraw(Client *c, int slot, int quantity);
void NmsVaultHandleDepositBagItem(Client *c, int slot, int bag_slot);
void NmsVaultHandleWithdrawBagItem(Client *c, int slot, int bag_slot, int quantity);
void NmsVaultHandleBank(Client *c);
void NmsVaultHandleMerchant(Client *c);

void NmsVaultOnZoneIn(Client *c);
void NmsVaultOnMerchantEnd(Client *c);
void NmsVaultRefreshCache(Client *c);
void NmsVaultApplyClickies(Client *c);
const EQ::ItemData *NmsVaultProcItem(Client *c, uint16 hand);
void NmsVaultApplyLockerBonuses(Client *c, StatBonuses *b);
bool NmsVaultBankAccess(Client *c);
bool NmsVaultIsMerchant(Client *c, uint16 entity_id);
int NmsVaultTryDepositInstance(Client *c, EQ::ItemInstance *inst);

#endif
