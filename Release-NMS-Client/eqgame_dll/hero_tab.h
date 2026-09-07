#pragma once

#include <cstdint>

// NMS Hero tab: the inventory window's unused Shrouds page (IW_AltCharProgPage in
// EQUI_Inventory.xml) repurposed as the multiclass panel. Lists the sixteen classes with the
// levels the character holds, and sends OP_HeroRequest (0x140C) to add or drop one. The server
// answers with the regular bulk stats packet, which is what redraws the tab.

// Called by MQ2Labels.cpp after the stat map has been refreshed from OP_ServerAuthStats.
void HeroTab_OnStatsUpdated();

// Called from the CSidlScreenWnd::WndNotification detour on XWM_LCLICK. Returns true when the
// click belonged to a Hero tab button and has been handled (the caller suppresses the default).
bool HeroTab_HandleClick(void *thisPtr, void *sender);

// Provided by MQ2Labels.cpp, where the stat map and the class tables are file-local.
uint32_t NMS_GetClassesBitmask();
int NMS_GetClassLevel(int class_id);
const char *NMS_GetClassAbbr(int class_id);
