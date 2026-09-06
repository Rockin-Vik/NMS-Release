#ifndef EQEMU_RACE_CLASS_H
#define EQEMU_RACE_CLASS_H

#include "types.h"

int GetRaceClassTableIndex(uint16 base_race_id);
bool IsClassRaceCombinationAllowed(uint8 class_id, uint16 base_race_id);

#endif // EQEMU_RACE_CLASS_H
