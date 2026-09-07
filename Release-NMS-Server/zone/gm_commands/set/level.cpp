#include "../../bot.h"
#include "../../client.h"

void SetLevel(Client *c, const Seperator *sep)
{
	const auto arguments = sep->argnum;
	if (arguments < 2 || !sep->IsNumber(2)) {
		c->Message(Chat::White, "Usage: #set level [Level]");
		return;
	}

	Mob* t = c;
	if (c->GetTarget()) {
		t = c->GetTarget();
	}

	const int max_level       = RuleI(Character, MaxLevel);
	const int requested_level = Strings::ToInt(sep->arg[2]);

	if (c != t && c->Admin() < RuleI(GM, MinStatusToLevelTarget)) {
		c->Message(Chat::White, "Your status is not high enough to change another person's level.");
		return;
	}

	// Validate the full integer before narrowing to uint8. `#level 326` is 70
	// modulo 256 and would otherwise pass a 1..MaxLevel check.
	if (t->IsClient()) {
		if (requested_level < 1 || requested_level > max_level) {
			c->Message(Chat::Red, fmt::format("Level must be between 1 and {}.", max_level).c_str());
			return;
		}
	} else if (requested_level < 1 || requested_level > 255) {
		c->Message(Chat::Red, "Level must be between 1 and 255.");
		return;
	}

	t->SetLevel(static_cast<uint8>(requested_level), true);

	if (t->IsClient()) {
		for (const auto& s : EQ::skills::GetSkillTypeMap()) {
			const uint16 max_skill_value = t->CastToClient()->MaxSkill(s.first);
			if (t->GetSkill(s.first) > max_skill_value) {
				t->CastToClient()->SetSkill(s.first, max_skill_value);
			}
		}

		t->CastToClient()->SendLevelAppearance();

		if (RuleB(Bots, Enabled) && RuleB(Bots, BotLevelsWithOwner)) {
			Bot::LevelBotWithClient(t->CastToClient(), t->GetLevel(), true);
		}
	}
}
