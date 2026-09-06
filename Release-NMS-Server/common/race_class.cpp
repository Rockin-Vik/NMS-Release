#include "race_class.h"

#include "classes.h"
#include "races.h"

namespace {
constexpr int kTableRaceCount = 16;

constexpr bool kClassRaceLookupTable[Class::PLAYER_CLASS_COUNT][kTableRaceCount] = {
	/*                    Human Barbarian Erudite Woodelf Highelf Darkelf Halfelf Dwarf Troll Ogre Halfling Gnome Iksar Vahshir Froglok Drakkin */
	/* Warrior */       { true,  true,     false,  true,   false,  true,   true,   true,  true,  true, true,    true,  true,  true,   true,   true  },
	/* Cleric */        { true,  false,    true,   false,  true,   true,   true,   true,  false, false,true,    true,  false, false,  true,   true  },
	/* Paladin */       { true,  false,    true,   false,  true,   false,  true,   true,  false, false,true,    true,  false, false,  true,   true  },
	/* Ranger */        { true,  false,    false,  true,   false,  false,  true,   false, false, false,true,    false, false, false,  false,  true  },
	/* ShadowKnight */  { true,  false,    true,   false,  false,  true,   false,  false, true,  true, false,   true,  true,  false,  true,   true  },
	/* Druid */         { true,  false,    false,  true,   false,  false,  true,   false, false, false,true,    false, false, false,  false,  true  },
	/* Monk */          { true,  false,    false,  false,  false,  false,  false,  false, false, false,false,   false, true,  false,  false,  true  },
	/* Bard */          { true,  false,    false,  true,   false,  false,  true,   false, false, false,false,   false, false, true,   false,  true  },
	/* Rogue */         { true,  true,     false,  true,   false,  true,   true,   true,  false, false,true,    true,  false, true,   true,   true  },
	/* Shaman */        { false, true,     false,  false,  false,  false,  false,  false, true,  true, false,   false, true,  true,   true,   false },
	/* Necromancer */   { true,  false,    true,   false,  false,  true,   false,  false, false, false,false,   true,  true,  false,  true,   true  },
	/* Wizard */        { true,  false,    true,   false,  true,   true,   false,  false, false, false,false,   true,  false, false,  true,   true  },
	/* Magician */      { true,  false,    true,   false,  true,   true,   false,  false, false, false,false,   true,  false, false,  false,  true  },
	/* Enchanter */     { true,  false,    true,   false,  true,   true,   false,  false, false, false,false,   true,  false, false,  false,  true  },
	/* Beastlord */     { false, true,     false,  false,  false,  false,  false,  false, true,  true, false,   false, true,  true,   false,  false },
	/* Berserker */     { false, true,     false,  false,  false,  false,  false,  true,  true,  true, false,   false, false, true,   false,  false }
};
}

int GetRaceClassTableIndex(uint16 base_race_id)
{
	switch (base_race_id) {
	case IKSAR:
		return 12;
	case VAHSHIR:
		return 13;
	case FROGLOK:
		return 14;
	case DRAKKIN:
		return 15;
	default:
		return base_race_id >= 1 && base_race_id <= 12 ? base_race_id - 1 : -1;
	}
}

bool IsClassRaceCombinationAllowed(uint8 class_id, uint16 base_race_id)
{
	if (class_id < Class::Warrior || class_id > Class::Berserker) {
		return false;
	}

	const int race_index = GetRaceClassTableIndex(base_race_id);
	return race_index >= 0 && race_index < kTableRaceCount &&
		kClassRaceLookupTable[class_id - Class::Warrior][race_index];
}
