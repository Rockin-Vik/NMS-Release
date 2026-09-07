#include "hero_tab.h"

#include "MQ2Main.h"

#include <cstdio>
#include <cstring>
#include <string>

extern VOID SendEQMessage(DWORD PacketType, PVOID pData, DWORD Length);

namespace {
	const uint16_t kOpHeroRequest = 0x140C;
	const uint32_t kHeroAdd = 1;
	const uint32_t kHeroRemove = 2;
	// Custom:MaxMulticlasses default. Only used to grey out rows; the server is authoritative.
	const int kMaxClasses = 4;
	const COLORREF kWhite = 0xFFFFFFFF;
	const COLORREF kGrey = 0xFFA0A0A0;
	const COLORREF kGreen = 0xFF80FF80;

#pragma pack(push, 1)
	struct HeroRequest_Struct {
		uint32_t op;       // kHeroAdd / kHeroRemove
		uint32_t class_id; // 1..16
	};
#pragma pack(pop)

	int g_selectedClass = 0;

	// Widgets are looked up by ScreenID on every use: the inventory window is rebuilt on
	// /loadskin and the pointers must never be cached across that.
	CXWnd *Child(const char *screen_id)
	{
		if (!ppInventoryWnd || !pInventoryWnd) {
			return nullptr;
		}
		return ((CSidlScreenWnd *)pInventoryWnd)->GetChildItem((PCHAR)screen_id);
	}

	CListWnd *ClassList() { return (CListWnd *)Child("Hero_ClassList"); }
	CStmlWnd *InfoBox() { return (CStmlWnd *)Child("Hero_Info"); }
	CXWnd *AddButton() { return Child("Hero_AddButton"); }
	CXWnd *RemoveButton() { return Child("Hero_RemoveButton"); }

	int CountBits(uint32_t mask)
	{
		int count = 0;
		while (mask) {
			count += mask & 1u;
			mask >>= 1;
		}
		return count;
	}

	bool Held(uint32_t mask, int class_id)
	{
		return class_id >= 1 && class_id <= 16 && (mask & (1u << (class_id - 1))) != 0;
	}

	const char *ClassName(int class_id)
	{
		if (!pEverQuest || class_id < 1 || class_id > 16) {
			return "Unknown";
		}
		return (const char *)pEverQuest->GetClassDesc(class_id);
	}

	int EffectiveLevel()
	{
		if (pLocalPlayer && pLocalPlayer->Data.pSpawn) {
			return pLocalPlayer->Data.pSpawn->Level;
		}
		return 0;
	}

	std::string HeldSummary(uint32_t mask)
	{
		std::string out;
		for (int class_id = 1; class_id <= 16; ++class_id) {
			if (!Held(mask, class_id)) {
				continue;
			}
			char part[32];
			sprintf_s(part, "%s %d", NMS_GetClassAbbr(class_id), NMS_GetClassLevel(class_id));
			if (!out.empty()) {
				out += ", ";
			}
			out += part;
		}
		return out.empty() ? "none" : out;
	}

	void RenderInfo(uint32_t mask)
	{
		CStmlWnd *info = InfoBox();
		if (!info) {
			return;
		}

		const int held_count = CountBits(mask);
		// _TRUNCATE, not sprintf_s: HeldSummary grows ~9 bytes per held class, so a large
		// Custom:MaxMulticlasses (or a GM-built character) overruns a fixed buffer, and
		// sprintf_s answers an overrun by invoking the invalid-parameter handler, which in
		// a release CRT terminates the client.
		char head[512];
		_snprintf_s(head, _TRUNCATE, "<c \"#FFFF00\">Level %d</c>  Classes %d of %d: %s<br>",
			EffectiveLevel(), held_count, kMaxClasses, HeldSummary(mask).c_str());

		std::string text = head;
		if (g_selectedClass >= 1 && g_selectedClass <= 16) {
			text += "<c \"#FFFF00\">";
			text += ClassName(g_selectedClass);
			text += "</c>: ";
			if (Held(mask, g_selectedClass)) {
				text += "held. Remove drops it and you lose access to its spells, disciplines, skills and abilities. "
					"The first removal is free; after that it costs 10 Echo of Memory and starts a 7-day lockout.<br>";
			} else if (held_count >= kMaxClasses) {
				text += "you are at the class cap. Remove a class before adding another.<br>";
			} else {
				text += "available. Add is free; the class joins at your current level.<br>";
			}
		} else {
			text += "Select a class, then press Add Class or Remove Class.<br>";
		}
		text += "The guildmasters and the Vision of Ayonae in the Bazaar offer the same choices.";

		CXStr stml(text.c_str());
		info->SetSTMLText(stml, true, NULL);
	}

	void RenderList(uint32_t mask)
	{
		CListWnd *list = ClassList();
		if (!list) {
			return;
		}

		list->DeleteAll();
		const bool at_cap = CountBits(mask) >= kMaxClasses;
		int reselect = -1;

		// Held classes first, then the rest in class-id order.
		for (int pass = 0; pass < 2; ++pass) {
			for (int class_id = 1; class_id <= 16; ++class_id) {
				const bool held = Held(mask, class_id);
				if ((pass == 0) != held) {
					continue;
				}

				char level[16] = "";
				const char *status = "Available";
				COLORREF color = kWhite;
				if (held) {
					sprintf_s(level, "%d", NMS_GetClassLevel(class_id));
					status = "Held";
					color = kGreen;
				} else if (at_cap) {
					status = "At cap";
					color = kGrey;
				}

				const int row = list->AddString(ClassName(class_id), color, (uint32_t)class_id, NULL);
				CXStr level_text(level);
				CXStr status_text(status);
				list->SetItemText(row, 1, &level_text);
				list->SetItemText(row, 2, &status_text);
				list->SetItemColor(row, 1, color);
				list->SetItemColor(row, 2, color);
				list->SetItemData(row, (uint32_t)class_id);
				if (class_id == g_selectedClass) {
					reselect = row;
				}
			}
		}

		if (reselect >= 0) {
			list->SetCurSel(reselect);
		}
	}

	void Say(const char *msg)
	{
		char buf[256];
		strncpy_s(buf, msg, _TRUNCATE);
		WriteChatColor(buf, CONCOLOR_RED);
	}

	void SendRequest(uint32_t op, int class_id)
	{
		HeroRequest_Struct req;
		req.op = op;
		req.class_id = (uint32_t)class_id;
		SendEQMessage(kOpHeroRequest, &req, sizeof(req));
	}
}

void HeroTab_OnStatsUpdated()
{
	if (!ppInventoryWnd || !pInventoryWnd) {
		return;
	}

	// OP_ServerAuthStats is not only the bulk push - the server also sends 2-entry HP,
	// mana and endurance updates, several times a second in combat. Rebuilding the tab
	// on each one meant a DeleteAll plus 16 AddString plus a full STML re-parse per tick,
	// window closed or not, and DeleteAll also yanked the scroll position back. Only the
	// class mask and the level are on display, so redraw when one of them actually moves.
	static uint32_t s_lastMask  = 0xFFFFFFFFu;
	static int      s_lastLevel = -1;

	const uint32_t mask  = NMS_GetClassesBitmask();
	const int      level = EffectiveLevel();
	if (mask == s_lastMask && level == s_lastLevel) {
		return;
	}
	s_lastMask  = mask;
	s_lastLevel = level;

	RenderList(mask);
	RenderInfo(mask);
}

bool HeroTab_HandleClick(void * /*thisPtr*/, void *sender)
{
	if (!sender || !ppInventoryWnd || !pInventoryWnd) {
		return false;
	}

	CListWnd *list = ClassList();
	if (list && sender == (void *)list) {
		const int sel = list->GetCurSel();
		g_selectedClass = sel >= 0 ? (int)list->GetItemData(sel) : 0;
		RenderInfo(NMS_GetClassesBitmask());
		return false; // let the list keep its selection
	}

	const bool add = sender == (void *)AddButton();
	const bool remove = !add && sender == (void *)RemoveButton();
	if (!add && !remove) {
		return false;
	}

	const uint32_t mask = NMS_GetClassesBitmask();
	if (g_selectedClass < 1 || g_selectedClass > 16) {
		Say("Select a class in the list first.");
		return true;
	}

	if (add) {
		if (Held(mask, g_selectedClass)) {
			Say("You already hold that class.");
		} else if (CountBits(mask) >= kMaxClasses) {
			Say("You are at the class cap. Remove a class before adding another.");
		} else {
			SendRequest(kHeroAdd, g_selectedClass);
		}
		return true;
	}

	if (!Held(mask, g_selectedClass)) {
		Say("You do not hold that class.");
	} else if (CountBits(mask) <= 1) {
		Say("You cannot remove your last class.");
	} else {
		SendRequest(kHeroRemove, g_selectedClass);
	}
	return true;
}
