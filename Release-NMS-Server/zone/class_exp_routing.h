#ifndef EQEMU_ZONE_CLASS_EXP_ROUTING_H
#define EQEMU_ZONE_CLASS_EXP_ROUTING_H

#include "../common/types.h"
#include <vector>

uint64 RouteClassExp(std::vector<uint64> &rows, int64 delta, uint64 cap);

#endif
