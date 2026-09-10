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
	const COLORREF kWhite = 0xFFFFFFFF;
	const COLORREF kGreen = 0xFF80FF80;
	const COLORREF kGold  = 0xFFE0C060; // current: played before, level kept, not in play

#pragma pack(push, 1)
	struct HeroRequest_Struct {
		uint32_t op;       // kHeroAdd / kHeroRemove
		uint32_t class_id; // 1..16
	};
#pragma pack(pop)

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

	// The class the player has highlighted in the list right now. Read at click time so
	// keyboard selection counts too; nothing is cached.
	int SelectedClass()
	{
		CListWnd *list = ClassList();
		if (!list) {
			return 0;
		}
		const int sel = list->GetCurSel();
		if (sel < 0) {
			return 0;
		}
		const int class_id = (int)list->GetItemData(sel);
		return (class_id >= 1 && class_id <= 16) ? class_id : 0;
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

	// The server owns the class cap (Custom:MaxMulticlasses) and the join level (the catch-up
	// rule); the tab never second-guesses them. Refusals come back as the same red lines the
	// guildmasters and the Vision of Ayonae give.
	void RenderInfo(uint32_t mask)
	{
		CStmlWnd *info = InfoBox();
		if (!info) {
			return;
		}

		char head[64];
		sprintf_s(head, "<c \"#FFFF00\">Level %d</c>  Active classes: %d", EffectiveLevel(), CountBits(mask));

		std::string text = head;
		text += " (";
		text += HeldSummary(mask);
		text += ")<br>";

		const int selected = SelectedClass();
		if (selected) {
			text += "<c \"#FFFF00\">";
			text += ClassName(selected);
			text += "</c>: ";
			if (Held(mask, selected)) {
				text += "active. Remove drops it; everything it earned is kept and returns when you add it again.<br>";
			} else if (NMS_GetClassLevel(selected) > 0) {
				char kept[96];
				sprintf_s(kept, "current at level %d, not in play. Add is free and brings it back at that level.<br>", NMS_GetClassLevel(selected));
				text += kept;
			} else {
				text += "never played. Add is free.<br>";
			}
		} else {
			text += "Select a class, then press Add Class or Remove Class.<br>";
		}
		text += "The guildmasters and the Vision of Ayonae in the Bazaar make the same changes.";

		CXStr stml(text.c_str());
		info->SetSTMLText(stml, true, NULL);
	}

	void RenderList(uint32_t mask)
	{
		CListWnd *list = ClassList();
		if (!list) {
			return;
		}

		const int keep = SelectedClass();
		list->DeleteAll();
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
					status = "Active";
					color = kGreen;
				} else if (NMS_GetClassLevel(class_id) > 0) {
					// The server sends the row level for a dropped class too; it was held once.
					sprintf_s(level, "%d", NMS_GetClassLevel(class_id));
					status = "Current";
					color = kGold;
				}

				const int row = list->AddString(ClassName(class_id), color, (uint32_t)class_id, NULL);
				if (row < 0) {
					continue;
				}
				CXStr level_text(level);
				CXStr status_text(status);
				list->SetItemText(row, 1, &level_text);
				list->SetItemText(row, 2, &status_text);
				list->SetItemColor(row, 1, color);
				list->SetItemColor(row, 2, color);
				list->SetItemData(row, (uint32_t)class_id);
				if (class_id == keep) {
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
	// mana and endurance updates, several times a second in combat. Rebuilding the tab on
	// each one meant a DeleteAll plus 16 AddString plus a full STML re-parse per tick,
	// window closed or not, and DeleteAll also yanked the scroll position back.
	//
	// Nothing on this tab can change while it is not on screen, so the hidden case costs two
	// int compares. While it IS on screen the selection is also watched, because RenderInfo
	// now reads the highlighted row and a keyboard selection raises no XWM_LCLICK for
	// HeroTab_HandleClick to catch.
	// The memo must also break when the WIDGET changes underneath it, not only when the
	// data does. RenderList has no other caller, so a /loadskin - which rebuilds the
	// inventory window and hands back a fresh, empty Hero_ClassList - would otherwise leave
	// the tab blank for the rest of the session, with an unchanged mask and level. The list
	// pointer is only ever compared, never dereferenced while stale. Level 0 means
	// pLocalPlayer is gone (character select, zoning), so coming back into the world redraws.
	static uint32_t   s_lastMask  = 0xFFFFFFFFu;
	static int        s_lastLevel = -1;
	static int        s_lastSel   = -1;
	static CListWnd  *s_lastList  = NULL;
	static bool       s_dirty     = true;

	const uint32_t mask  = NMS_GetClassesBitmask();
	const int      level = EffectiveLevel();
	if (mask != s_lastMask || level != s_lastLevel) {
		s_lastMask  = mask;
		s_lastLevel = level;
		s_dirty     = true;
	}
	if (level == 0) {
		s_dirty = true;
	}

	if (!((CXWnd *)pInventoryWnd)->IsReallyVisible()) {
		return;
	}

	CListWnd *list = ClassList();
	if (list != s_lastList) {
		s_lastList = list;
		s_dirty    = true;
	}
	if (!list) {
		return;
	}

	const int selected = SelectedClass();
	if (!s_dirty && selected == s_lastSel) {
		return;
	}
	s_lastSel = selected;
	s_dirty   = false;

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
		RenderInfo(NMS_GetClassesBitmask());
		return false; // let the list keep its selection
	}

	const bool add = sender == (void *)AddButton();
	const bool remove = !add && sender == (void *)RemoveButton();
	if (!add && !remove) {
		return false;
	}

	const uint32_t mask = NMS_GetClassesBitmask();
	const int selected = SelectedClass();
	if (!selected) {
		Say("Select a class in the list first.");
		return true;
	}

	if (add) {
		if (Held(mask, selected)) {
			Say("You already hold that class.");
		} else {
			SendRequest(kHeroAdd, selected);
		}
		return true;
	}

	if (!Held(mask, selected)) {
		Say("You do not hold that class.");
	} else if (CountBits(mask) <= 1) {
		Say("You cannot remove your last class.");
	} else {
		SendRequest(kHeroRemove, selected);
	}
	return true;
}
