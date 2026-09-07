#pragma once

#include <cstddef>
#include <cstdint>

#ifndef NMS_SPELLBOOK_SIZE
#define NMS_SPELLBOOK_SIZE 2880
#define NMS_BOOK_VOLUME 720
#endif

enum SpellbookIncomingResult {
	SpellbookIncomingPass = 0,
	SpellbookIncomingSuppress = 1,
};

void SpellbookVolumes_Reset();
bool SpellbookVolumes_SetVolume(int volume_one_based);

SpellbookIncomingResult SpellbookVolumes_OnIncoming(uint16_t opcode, char *buf, size_t *size);
bool SpellbookVolumes_OnOutgoing(uint16_t opcode, char *buf, size_t size);
bool SpellbookVolumes_HandleBookCommand(const char *args);
