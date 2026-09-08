// SPIKE (throwaway branch aa-timer-spike, never merged).
// Manual control of dynamic AA timer ids so the RoF2 client's shared-timer behaviour can be probed.
// Spec: Release-NMS-Deploy/specs/2026-09-08-aa-reuse-timer-ids.md section 3.

#include <algorithm>
#include "../client.h"
#include "../zone.h"
#include "../../common/ptimer.h"

static void aaspike_usage(Client *c)
{
	c->Message(Chat::White, "#aaspike show                    - mapping rows (aa_id -> timer id) for the target, reloaded from the database");
	c->Message(Chat::White, "#aaspike timers                  - running AA persistent timers for the target (index, remaining seconds)");
	c->Message(Chat::White, "#aaspike table                   - re-send the whole AA table to the target without a re-zone");
	c->Message(Chat::White, "#aaspike set <aa_id> <timer_id>  - give an ability a timer id (replaces any row holding that id)");
	c->Message(Chat::White, "#aaspike clear <aa_id>|all       - delete a mapping row (or every row); running cooldowns are left alone");
	c->Message(Chat::White, "#aaspike sentinel <n>|none       - what an ability with no row is sent as (none = untimed); zone-wide, default 0");
	c->Message(Chat::White, "#aaspike resend <aa_id> [index]  - re-send the target's owned rank of that ability in place, optionally with a forced index");
}

void command_aaspike(Client *c, const Seperator *sep)
{
	if (!sep->argnum) {
		aaspike_usage(c);
		return;
	}

	Client *t = c;
	if (c->GetTarget() && c->GetTarget()->IsClient()) {
		t = c->GetTarget()->CastToClient();
	}

	const std::string sub = Strings::ToLower(sep->arg[1]);

	if (sub == "show") {
		t->GetDynamicAATimers();
		std::vector<std::pair<int, int>> rows(t->m_aa_timers_cache.begin(), t->m_aa_timers_cache.end());
		std::sort(rows.begin(), rows.end(), [](const auto &a, const auto &b) { return a.second < b.second; });
		c->Message(Chat::White, fmt::format("{} mapping rows for {} (sentinel {}):",
			rows.size(), c->GetTargetDescription(t), Client::s_spike_sentinel < 0 ? "none" : std::to_string(Client::s_spike_sentinel)).c_str());
		for (const auto &row : rows) {
			auto ability = zone->GetAlternateAdvancementAbility(row.first);
			c->Message(Chat::White, fmt::format("  timer {:>4}  aa {:>6}  {}", row.second, row.first, ability ? ability->name : "(not in catalog)").c_str());
		}
		return;
	}

	if (sub == "timers") {
		int count = 0;
		for (auto it = t->GetPTimers().begin(); it != t->GetPTimers().end(); ++it) {
			PersistentTimer *cur = it->second;
			if (cur->GetType() < pTimerAAStart || cur->GetType() > pTimerAAEnd) {
				continue;
			}
			++count;
			c->Message(Chat::White, fmt::format("  index {:>4}  type {}  remaining {}s{}",
				cur->GetType() - pTimerAAStart, cur->GetType(), cur->GetRemainingTime(),
				cur->GetRemainingTime() == 0 ? "  (expired, still in memory)" : "").c_str());
		}
		c->Message(Chat::White, fmt::format("{} AA persistent timers in memory for {}.", count, c->GetTargetDescription(t)).c_str());
		return;
	}

	if (sub == "table") {
		t->SendAlternateAdvancementTable();
		c->Message(Chat::White, fmt::format("Re-sent the AA table to {}.", c->GetTargetDescription(t)).c_str());
		return;
	}

	if (sub == "set") {
		if (!sep->IsNumber(2) || !sep->IsNumber(3)) {
			aaspike_usage(c);
			return;
		}
		const int aa_id    = Strings::ToInt(sep->arg[2]);
		const int timer_id = Strings::ToInt(sep->arg[3]);
		if (!zone->GetAlternateAdvancementAbility(aa_id)) {
			c->Message(Chat::Red, fmt::format("No AA ability with id {} in the catalog.", aa_id).c_str());
			return;
		}
		if (timer_id < 0 || timer_id > (pTimerAAEnd - pTimerAAStart)) {
			c->Message(Chat::Red, fmt::format("Timer id must be 0..{}.", pTimerAAEnd - pTimerAAStart).c_str());
			return;
		}
		t->SpikeSetTimer(aa_id, timer_id);
		c->Message(Chat::White, fmt::format("aa {} -> timer {} for {}. Re-zone, #aaspike table, or #aaspike resend to send it.",
			aa_id, timer_id, c->GetTargetDescription(t)).c_str());
		return;
	}

	if (sub == "clear") {
		if (!strcasecmp(sep->arg[2], "all")) {
			t->SpikeClearAllTimers();
			c->Message(Chat::White, fmt::format("Deleted every mapping row for {}.", c->GetTargetDescription(t)).c_str());
			return;
		}
		if (!sep->IsNumber(2)) {
			aaspike_usage(c);
			return;
		}
		const int aa_id = Strings::ToInt(sep->arg[2]);
		t->SpikeClearTimer(aa_id);
		c->Message(Chat::White, fmt::format("Deleted the mapping row for aa {} on {}.", aa_id, c->GetTargetDescription(t)).c_str());
		return;
	}

	if (sub == "sentinel") {
		if (!strcasecmp(sep->arg[2], "none")) {
			Client::s_spike_sentinel = -1;
		} else if (sep->IsNumber(2)) {
			Client::s_spike_sentinel = Strings::ToInt(sep->arg[2]);
		} else {
			aaspike_usage(c);
			return;
		}
		c->Message(Chat::White, fmt::format("Sentinel is now {} for every client in this zone. Re-send the table to apply it.",
			Client::s_spike_sentinel < 0 ? "none (untimed)" : std::to_string(Client::s_spike_sentinel)).c_str());
		return;
	}

	if (sub == "resend") {
		if (!sep->IsNumber(2)) {
			aaspike_usage(c);
			return;
		}
		const int aa_id = Strings::ToInt(sep->arg[2]);
		auto ability = zone->GetAlternateAdvancementAbility(aa_id);
		if (!ability) {
			c->Message(Chat::Red, fmt::format("No AA ability with id {} in the catalog.", aa_id).c_str());
			return;
		}

		// Same choice of rank as SendAlternateAdvancementTable: the owned rank, or rank 1 when unowned.
		uint32 charges = 0;
		const uint32 owned = t->GetAA(ability->first_rank_id, &charges);
		const int level = owned ? static_cast<int>(owned) : 1;

		if (sep->IsNumber(3)) {
			Client::s_spike_force_aa_id = aa_id;
			Client::s_spike_force_index = Strings::ToInt(sep->arg[3]);
		}
		t->SendAlternateAdvancementRank(aa_id, level);
		Client::s_spike_force_aa_id = 0;
		Client::s_spike_force_index = -1;

		c->Message(Chat::White, fmt::format("Re-sent aa {} ({}) rank {} to {}{}.",
			aa_id, ability->name, level, c->GetTargetDescription(t),
			sep->IsNumber(3) ? fmt::format(" with index {}", sep->arg[3]) : "").c_str());
		return;
	}

	aaspike_usage(c);
}
