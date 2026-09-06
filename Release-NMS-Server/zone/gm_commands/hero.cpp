#include "../client.h"

namespace {

Client *GetHeroTarget(Client *c)
{
	if (c->GetTarget() && c->GetTarget()->IsClient()) {
		return c->GetTarget()->CastToClient();
	}

	return c;
}

void ShowHeroUsage(Client *c)
{
	c->Message(Chat::White, "Usage: #hero [show]");
	c->Message(Chat::White, "Usage: #hero set [Class ID] [Level]");
	c->Message(Chat::White, "Usage: #hero setall [Level]");
}

void ShowHeroStatus(Client *c, Client *t)
{
	c->Message(
		Chat::White,
		fmt::format("Hero class experience for {}:", c->GetTargetDescription(t)).c_str()
	);

	const uint32 classes = t->GetClassesBits();
	for (uint8 class_id = Class::Warrior; class_id <= Class::Berserker; ++class_id) {
		if (!(classes & GetPlayerClassBit(class_id))) {
			continue;
		}

		c->Message(
			Chat::White,
			fmt::format(
				"{} ({}): level {}, experience {}",
				GetClassIDName(class_id),
				class_id,
				t->GetClassLevel(class_id),
				Strings::Commify(t->GetClassExp(class_id))
			).c_str()
		);
	}

	c->Message(
		Chat::White,
		fmt::format(
			"Effective level: {}, reward level: {}, catching up: {}",
			t->GetLevel(),
			t->GetRewardLevel(),
			t->IsCatchingUp() ? "yes" : "no"
		).c_str()
	);
}

} // namespace

void command_hero(Client *c, const Seperator *sep)
{
	const auto arguments = sep->argnum;
	const bool show = !arguments || (arguments == 1 && Strings::EqualFold(sep->arg[1], "show"));

	if (
		!show &&
		!Strings::EqualFold(sep->arg[1], "set") &&
		!Strings::EqualFold(sep->arg[1], "setall")
	) {
		ShowHeroUsage(c);
		return;
	}

	Client *t = GetHeroTarget(c);
	if (!t) {
		return;
	}

	if (show) {
		ShowHeroStatus(c, t);
		return;
	}

	const int max_level = RuleI(Character, MaxLevel);

	if (Strings::EqualFold(sep->arg[1], "set")) {
		if (arguments != 3 || !sep->IsNumber(2) || !sep->IsNumber(3)) {
			c->Message(Chat::White, "Usage: #hero set [Class ID] [Level]");
			return;
		}

		const int class_id = Strings::ToInt(sep->arg[2]);
		const int level    = Strings::ToInt(sep->arg[3]);

		if (class_id < Class::Warrior || class_id > Class::Berserker) {
			c->Message(Chat::Red, "Class ID must be between 1 and 16.");
			return;
		}

		if (!(t->GetClassesBits() & GetPlayerClassBit(class_id))) {
			c->Message(
				Chat::Red,
				fmt::format(
					"{} held classes do not include {} ({}).",
					c->GetTargetDescription(t, TargetDescriptionType::UCYour),
					GetClassIDName(class_id),
					class_id
				).c_str()
			);
			return;
		}

		if (level < 1 || level > max_level) {
			c->Message(Chat::Red, fmt::format("Level must be between 1 and {}.", max_level).c_str());
			return;
		}

		const auto class_exp = t->GetEXPForLevel(level);
		if (!t->SetClassExp(static_cast<uint8>(class_id), class_exp)) {
			c->Message(Chat::Red, "The held class has no class experience row to update.");
			return;
		}

		t->SetEXP(ExpSource::GM, t->GetEXP(), t->GetAAXP());
		t->Save();

		c->Message(
			Chat::White,
			fmt::format(
				"Set {} {} class to level {} ({} experience).",
				c->GetTargetDescription(t, TargetDescriptionType::LCYour),
				GetClassIDName(class_id),
				level,
				Strings::Commify(t->GetClassExp(static_cast<uint8>(class_id)))
			).c_str()
		);
		return;
	}

	if (arguments != 2 || !sep->IsNumber(2)) {
		c->Message(Chat::White, "Usage: #hero setall [Level]");
		return;
	}

	const int level = Strings::ToInt(sep->arg[2]);
	if (level < 1 || level > max_level) {
		c->Message(Chat::Red, fmt::format("Level must be between 1 and {}.", max_level).c_str());
		return;
	}

	t->SetLevel(static_cast<uint8>(level), true);
	c->Message(
		Chat::White,
		fmt::format(
			"Set all of {} held classes to level {}.",
			c->GetTargetDescription(t, TargetDescriptionType::LCYour),
			level
		).c_str()
	);
}
