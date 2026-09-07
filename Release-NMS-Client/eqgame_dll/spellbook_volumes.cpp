#include "spellbook_volumes.h"

#include "MQ2Main.h"

#include <cstring>
#include <string.h>
#include <windows.h>

extern bool g_scribeInProgress;
extern bool g_scribeTimerActive;

namespace {
	const uint16_t kOpPlayerProfile = 0x6506;
	const uint16_t kOpMemorizeSpell = 0x217c;
	const uint16_t kOpSwapSpell = 0x0efa;
	const uint16_t kOpDeleteSpell = 0x3358;
	const uint32_t kEmptySlot = 0xFFFFFFFF;
	const uint32_t kGemCount = 16;
	const uint32_t kMemScribe = 0;
	const uint32_t kTimestamp2Count = 100;
	const uint32_t kBookCountThisServer = 2880;
	const uint32_t kBookCountLegacy = 720;
	const size_t kTimestamp2Bytes = 4 + static_cast<size_t>(kTimestamp2Count) * 4;
	const size_t kLikely2880ProfileBytes = 22000;

	uint32_t g_nmsSpellBook[NMS_SPELLBOOK_SIZE];
	int g_nmsBookVolume = 0;

	void LogBook(const char *msg)
	{
		OutputDebugStringA(msg);
	}

	bool BusyScribing()
	{
		return g_scribeInProgress || g_scribeTimerActive;
	}

	bool LooksLikeTimestamp2(const char *buf, size_t size, size_t off)
	{
		if (off + kTimestamp2Bytes > size) {
			return false;
		}

		uint32_t count = 0;
		memcpy(&count, buf + off, 4);
		if (count != kTimestamp2Count) {
			return false;
		}

		for (uint32_t i = 0; i < kTimestamp2Count; i++) {
			uint32_t zero = 0;
			memcpy(&zero, buf + off + 4 + (i * 4), 4);
			if (zero != 0) {
				return false;
			}
		}

		return true;
	}

	bool FindSpellbook(const char *buf, size_t size, size_t *count_off, uint32_t *book_count)
	{
		if (!buf || !count_off || !book_count || size < kTimestamp2Bytes + 8) {
			return false;
		}

		for (size_t off = 0; off + kTimestamp2Bytes + 8 <= size; off += 4) {
			if (!LooksLikeTimestamp2(buf, size, off)) {
				continue;
			}

			const size_t book_off = off + kTimestamp2Bytes;
			uint32_t count = 0;
			memcpy(&count, buf + book_off, 4);
			if (count != kBookCountThisServer && count != kBookCountLegacy) {
				continue;
			}

			const size_t book_bytes = static_cast<size_t>(count) * 4;
			if (book_off + 4 + book_bytes + 4 > size) {
				continue;
			}

			uint32_t gem_count = 0;
			memcpy(&gem_count, buf + book_off + 4 + book_bytes, 4);
			if (gem_count != kGemCount) {
				continue;
			}

			*count_off = book_off;
			*book_count = count;
			return true;
		}

		return false;
	}

	void CopyVolumeToCharInfo()
	{
		// GetCharInfo2() dereferences pCharData and pCI2 unconditionally, so testing its
		// result is too late - check the chain first. This runs from the OP_PlayerProfile
		// handler, while the client is still building CHARINFO2.
		if (!ppCharData || !pCharData || !((PCHARINFO)pCharData)->pCI2) {
			return;
		}

		PCHARINFO2 ci2 = GetCharInfo2();
		if (!ci2) {
			return;
		}

		const int base = g_nmsBookVolume * NMS_BOOK_VOLUME;
		for (int i = 0; i < NMS_BOOK_VOLUME; i++) {
			ci2->SpellBook[i] = g_nmsSpellBook[base + i];
		}
	}

	bool BookWindowVisible()
	{
		return ppSpellBookWnd && pSpellBookWnd && ((CXWnd *)pSpellBookWnd)->IsReallyVisible();
	}

	void RefreshBookWindow()
	{
		CopyVolumeToCharInfo();
		if (!ppSpellBookWnd || !pSpellBookWnd) {
			return;
		}

		if (BookWindowVisible()) {
			((CXWnd *)pSpellBookWnd)->Show(true, true, false);
			return;
		}

		if (pEverQuest && pLocalPlayer) {
			pEverQuest->InterpretCmd((EQPlayer *)pLocalPlayer, "/book");
		}
	}

	bool SlotInVolume(int slot)
	{
		const int base = g_nmsBookVolume * NMS_BOOK_VOLUME;
		return slot >= base && slot < base + NMS_BOOK_VOLUME;
	}

	void AdoptVolumeForSlot(int slot)
	{
		if (slot < 0 || slot >= NMS_SPELLBOOK_SIZE) {
			return;
		}

		const int volume = slot / NMS_BOOK_VOLUME;
		if (volume == g_nmsBookVolume) {
			return;
		}

		g_nmsBookVolume = volume;
		RefreshBookWindow();
	}
}

void SpellbookVolumes_Reset()
{
	for (int i = 0; i < NMS_SPELLBOOK_SIZE; i++) {
		g_nmsSpellBook[i] = kEmptySlot;
	}
	g_nmsBookVolume = 0;
}

bool SpellbookVolumes_SetVolume(int volume_one_based)
{
	if (volume_one_based < 1 || volume_one_based > 4) {
		return false;
	}

	if (BusyScribing()) {
		return false;
	}

	g_nmsBookVolume = volume_one_based - 1;
	RefreshBookWindow();
	return true;
}

bool SpellbookVolumes_HandleBookCommand(const char *args)
{
	if (!args || !args[0]) {
		return false;
	}

	const int volume = atoi(args);
	if (volume < 1 || volume > 4) {
		return false;
	}

	if (BusyScribing()) {
		char busy[] = "You cannot change spellbook volumes while scribing.";
		WriteChatColor(busy, CONCOLOR_RED);
		return true;
	}

	SpellbookVolumes_SetVolume(volume);
	char msg[64];
	sprintf_s(msg, "Spellbook volume %d (pages 1-90).", volume);
	WriteChatColor(msg, CONCOLOR_YELLOW);
	return true;
}

SpellbookIncomingResult SpellbookVolumes_OnIncoming(uint16_t opcode, char *buf, size_t *size)
{
	if (!buf || !size || *size == 0) {
		return SpellbookIncomingPass;
	}

	if (opcode == kOpPlayerProfile) {
		size_t count_off = 0;
		uint32_t book_count = 0;
		if (!FindSpellbook(buf, *size, &count_off, &book_count)) {
			char miss[160];
			sprintf_s(
				miss,
				"NMS spellbook: profile book not found (size %u). Pass would smash CHARINFO2.",
				static_cast<unsigned>(*size)
			);
			LogBook(miss);
			// Drop the previous character/zone state. g_nmsSpellBook is static storage, so
			// before any successful scan it is all zeros while the empty marker is
			// 0xFFFFFFFF - a later /book N would copy 720 zeros into CHARINFO2 and show
			// spell id 0 in every slot. A stale g_nmsBookVolume would also keep being added
			// to outgoing scribe/delete/swap slots, landing writes on the wrong server slot.
			SpellbookVolumes_Reset();
			if (*size >= kLikely2880ProfileBytes) {
				return SpellbookIncomingSuppress;
			}
			return SpellbookIncomingPass;
		}

		SpellbookVolumes_Reset();
		const uint32_t copy_count = book_count < NMS_SPELLBOOK_SIZE ? book_count : NMS_SPELLBOOK_SIZE;
		memcpy(g_nmsSpellBook, buf + count_off + 4, copy_count * 4);
		CopyVolumeToCharInfo();

		if (book_count != kBookCountThisServer) {
			return SpellbookIncomingPass;
		}

		const size_t src_tail = count_off + 4 + static_cast<size_t>(book_count) * 4;
		const size_t dst_tail = count_off + 4 + 720 * 4;
		if (src_tail > *size) {
			LogBook("NMS spellbook: 2880-slot profile tail is truncated; suppressing.");
			return SpellbookIncomingSuppress;
		}

		const size_t tail_len = *size - src_tail;
		uint32_t visible = 720;
		memcpy(buf + count_off, &visible, 4);
		memcpy(buf + count_off + 4, g_nmsSpellBook, 720 * 4);
		if (tail_len && src_tail != dst_tail) {
			memmove(buf + dst_tail, buf + src_tail, tail_len);
		}
		*size = dst_tail + tail_len;
		return SpellbookIncomingPass;
	}

	if (opcode == kOpMemorizeSpell) {
		if (*size < 12) {
			return SpellbookIncomingPass;
		}

		uint32_t slot = 0;
		uint32_t spell_id = 0;
		uint32_t scribing = 0;
		memcpy(&slot, buf, 4);
		memcpy(&spell_id, buf + 4, 4);
		memcpy(&scribing, buf + 8, 4);

		if (scribing != kMemScribe) {
			return SpellbookIncomingPass;
		}

		if (slot < NMS_SPELLBOOK_SIZE) {
			g_nmsSpellBook[slot] = spell_id;
		}

		if (!SlotInVolume(static_cast<int>(slot))) {
			AdoptVolumeForSlot(static_cast<int>(slot));
		}

		if (SlotInVolume(static_cast<int>(slot))) {
			const uint32_t relative = slot - (g_nmsBookVolume * NMS_BOOK_VOLUME);
			memcpy(buf, &relative, 4);
			return SpellbookIncomingPass;
		}

		CopyVolumeToCharInfo();
		return SpellbookIncomingSuppress;
	}

	if (opcode == kOpDeleteSpell) {
		if (*size < 2) {
			return SpellbookIncomingPass;
		}

		int16_t slot = 0;
		memcpy(&slot, buf, 2);
		if (slot >= 0 && slot < NMS_SPELLBOOK_SIZE) {
			g_nmsSpellBook[slot] = kEmptySlot;
		}

		if (SlotInVolume(slot)) {
			const int16_t relative = static_cast<int16_t>(slot - (g_nmsBookVolume * NMS_BOOK_VOLUME));
			memcpy(buf, &relative, 2);
			return SpellbookIncomingPass;
		}

		CopyVolumeToCharInfo();
		return SpellbookIncomingSuppress;
	}

	if (opcode == kOpSwapSpell) {
		if (*size < 8) {
			return SpellbookIncomingPass;
		}

		uint32_t from_slot = 0;
		uint32_t to_slot = 0;
		memcpy(&from_slot, buf, 4);
		memcpy(&to_slot, buf + 4, 4);

		if (from_slot < NMS_SPELLBOOK_SIZE && to_slot < NMS_SPELLBOOK_SIZE) {
			const uint32_t tmp = g_nmsSpellBook[from_slot];
			g_nmsSpellBook[from_slot] = g_nmsSpellBook[to_slot];
			g_nmsSpellBook[to_slot] = tmp;
		}

		const bool from_in = SlotInVolume(static_cast<int>(from_slot));
		const bool to_in = SlotInVolume(static_cast<int>(to_slot));
		if (from_in && to_in) {
			const uint32_t rel_from = from_slot - (g_nmsBookVolume * NMS_BOOK_VOLUME);
			const uint32_t rel_to = to_slot - (g_nmsBookVolume * NMS_BOOK_VOLUME);
			memcpy(buf, &rel_from, 4);
			memcpy(buf + 4, &rel_to, 4);
			return SpellbookIncomingPass;
		}

		CopyVolumeToCharInfo();
		return SpellbookIncomingSuppress;
	}

	return SpellbookIncomingPass;
}

bool SpellbookVolumes_OnOutgoing(uint16_t opcode, char *buf, size_t size)
{
	if (!buf) {
		return false;
	}

	if (opcode == kOpMemorizeSpell) {
		if (size < 14) {
			return false;
		}

		uint32_t scribing = 0;
		memcpy(&scribing, buf + 2 + 8, 4);
		if (scribing != kMemScribe) {
			return false;
		}

		uint32_t slot = 0;
		memcpy(&slot, buf + 2, 4);
		slot += g_nmsBookVolume * NMS_BOOK_VOLUME;
		memcpy(buf + 2, &slot, 4);
		return false;
	}

	if (opcode == kOpDeleteSpell) {
		if (size < 4) {
			return false;
		}

		int16_t slot = 0;
		memcpy(&slot, buf + 2, 2);
		slot = static_cast<int16_t>(slot + (g_nmsBookVolume * NMS_BOOK_VOLUME));
		memcpy(buf + 2, &slot, 2);
		return false;
	}

	if (opcode == kOpSwapSpell) {
		if (size < 10) {
			return false;
		}

		uint32_t from_slot = 0;
		uint32_t to_slot = 0;
		memcpy(&from_slot, buf + 2, 4);
		memcpy(&to_slot, buf + 6, 4);
		from_slot += g_nmsBookVolume * NMS_BOOK_VOLUME;
		to_slot += g_nmsBookVolume * NMS_BOOK_VOLUME;
		memcpy(buf + 2, &from_slot, 4);
		memcpy(buf + 6, &to_slot, 4);
		return false;
	}

	return false;
}
