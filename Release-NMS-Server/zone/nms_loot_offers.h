#ifndef NMS_LOOT_OFFERS_H
#define NMS_LOOT_OFFERS_H

#include "../common/types.h"
#include <string>
#include <vector>

class Client;
class Corpse;
class EQApplicationPacket;
class NPC;

enum class NmsLootAction : uint32 {
	None = 0,
	Keep = 1,
	Sell = 2,
	Tribute = 3,
	Bank = 4,
	Vault = 5,
	Destroy = 6,
	Pass = 7,
	ReturnToPasser = 9
};

struct NmsLootOffer {
	uint32      id = 0;
	uint32      character_id = 0;
	uint32      zone_id = 0;
	uint32      instance_id = 0;
	uint32      corpse_id = 0;
	uint64      corpse_serial = 0;
	uint32      item_id = 0;
	uint32      icon = 0;
	int16       charges = 1;
	uint8       bonus = 0;
	std::string name;
	uint32      aug[6] = {0, 0, 0, 0, 0, 0};
	bool        passed = false;
	std::string passed_from;
	int         expire_remaining = 0;
};

bool NmsLootOffersEnabled();
bool NmsLootOfferTablesReady();

void NmsLootOfferOnCorpseOpen(Client *c, Corpse *corpse);
void NmsLootOfferOnCorpseCreated(Corpse *corpse, Client *credit, NPC *source);
void NmsLootOfferRestoreOnZoneIn(Client *c);
void NmsLootOfferHandleDecision(Client *c, const EQApplicationPacket *app);
bool NmsLootOfferApply(Client *c, const NmsLootOffer &offer, NmsLootAction action, const std::string &pass_to);
struct LootItem;
void NmsLootOfferForgetCorpseItem(uint32 character_id, uint32 corpse_id, const LootItem *item);

#endif
