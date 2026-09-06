#include "../client.h"
#include "../zonedb.h"

#include "../../common/repositories/nms_gm_starter_pack_repository.h"

#include <algorithm>
#include <set>

void command_gmpack(Client *c, const Seperator *sep)
{
	Client *t = c;
	if (c->GetTarget() && c->GetTarget()->IsClient() && c->GetGM()) {
		t = c->GetTarget()->CastToClient();
	}

	const auto argument = Strings::ToLower(sep->arg[1]);
	std::vector<std::string> bag_names;
	if (argument.empty() || argument == "all") {
		bag_names = { "worn", "weapons", "clickies" };
	} else if (
		argument == "worn" ||
		argument == "extras" ||
		argument == "weapons" ||
		argument == "clickies"
	) {
		bag_names = { argument };
	} else {
		c->Message(
			Chat::Yellow,
			"Usage: #gmpack [all|worn|extras|weapons|clickies]  (all = worn + weapons + clickies; extras is the alt set)"
		);
		return;
	}

	auto rows = NmsGmStarterPackRepository::All(content_db);
	if (rows.empty()) {
		c->Message(
			Chat::Yellow,
			"nms_gm_starter_pack is empty or missing - run the custom database migration (v31) first."
		);
		return;
	}

	std::stable_sort(
		rows.begin(),
		rows.end(),
		[](const auto &left, const auto &right) {
			if (left.sort != right.sort) {
				return left.sort < right.sort;
			}

			return left.id < right.id;
		}
	);

	auto box_row = std::find_if(
		rows.begin(),
		rows.end(),
		[](const auto &row) {
			return row.bag == "box";
		}
	);
	if (box_row == rows.end()) {
		c->Message(Chat::Yellow, "nms_gm_starter_pack has no 'box' row; cannot summon.");
		return;
	}

	const EQ::ItemData *box_item = database.GetItem(box_row->item_id);
	if (!box_item) {
		c->Message(
			Chat::Yellow,
			fmt::format(
				"GM Starter Box item [{}] is not in the item store - migrate v30 and rerun shared_memory.",
				box_row->item_id
			).c_str()
		);
		return;
	}

	std::set<uint32> lore_ids_placed;
	std::set<int32>  lore_groups_placed;
	bool             first_summary = true;

	for (const auto &bag_name : bag_names) {
		EQ::ItemInstance *bag = database.CreateItem(box_row->item_id, 1);
		if (!bag || !bag->IsClassBag()) {
			c->Message(
				Chat::Yellow,
				fmt::format("Failed to create GM Starter Box [{}]", box_row->item_id).c_str()
			);
			safe_delete(bag);
			return;
		}

		uint32 placed          = 0;
		uint32 skipped_lore    = 0;
		uint32 skipped_missing = 0;
		uint32 skipped_full    = 0;

		for (const auto &row : rows) {
			if (row.bag != bag_name) {
				continue;
			}

			const EQ::ItemData *item = database.GetItem(row.item_id);
			if (!item) {
				skipped_missing++;
				c->Message(
					Chat::Yellow,
					fmt::format("  missing from item store: [{}] {}", row.item_id, row.note).c_str()
				);
				continue;
			}

			const bool is_lore = item->LoreFlag && item->LoreGroup != 0;
			const bool lore_conflict =
				t->CheckLoreConflict(item) ||
				(is_lore && item->LoreGroup == -1 && lore_ids_placed.count(item->ID)) ||
				(is_lore && item->LoreGroup > 0 && lore_groups_placed.count(item->LoreGroup));
			if (lore_conflict) {
				skipped_lore++;
				c->Message(
					Chat::Yellow,
					fmt::format("  skipped lore item: {} [{}]", item->Name, item->ID).c_str()
				);
				continue;
			}

			const uint16 count = row.count ? row.count : 1;
			for (uint16 copy = 0; copy < count; ++copy) {
				const uint8 slot = bag->FirstOpenSlot();
				if (slot == 0xff) {
					skipped_full++;
					break;
				}

				EQ::ItemInstance *inst = database.CreateItem(row.item_id, row.charges);
				if (!inst) {
					skipped_missing++;
					break;
				}

				bag->PutItem(slot, *inst);
				safe_delete(inst);
				placed++;

				if (is_lore) {
					if (item->LoreGroup == -1) {
						lore_ids_placed.insert(item->ID);
					} else if (item->LoreGroup > 0) {
						lore_groups_placed.insert(item->LoreGroup);
					}
					break;
				}
			}
		}

		if (placed == 0) {
			safe_delete(bag);
			c->Message(
				Chat::Yellow,
				fmt::format(
					"GM Starter Box [{}]: nothing to place (lore {} / missing {})",
					bag_name,
					skipped_lore,
					skipped_missing
				).c_str()
			);
			continue;
		}

		if (!t->AutoPutLootInInventory(*bag, false, true)) {
			c->Message(
				Chat::Yellow,
				fmt::format(
					"GM Starter Box [{}]: no free inventory slot or cursor; stopping.",
					bag_name
				).c_str()
			);
			safe_delete(bag);
			return;
		}
		safe_delete(bag);

		const auto summary = fmt::format(
			"GM Starter Box [{}]: placed {}, skipped lore {}, missing {}, bag full {}",
			bag_name,
			placed,
			skipped_lore,
			skipped_missing,
			skipped_full
		);
		c->Message(
			Chat::White,
			(t != c && first_summary ? fmt::format("{}: {}", t->GetCleanName(), summary) : summary).c_str()
		);
		first_summary = false;
	}
}
