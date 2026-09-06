#ifndef EQEMU_CHARACTER_CLASS_EXP_REPOSITORY_H
#define EQEMU_CHARACTER_CLASS_EXP_REPOSITORY_H

#include "../database.h"
#include "../strings.h"
#include "base/base_character_class_exp_repository.h"

class CharacterClassExpRepository: public BaseCharacterClassExpRepository {
public:

	/**
	 * This file was auto generated and can be modified and extended upon
	 *
	 * Base repository methods are automatically
	 * generated in the "base" version of this repository. The base repository
	 * is immutable and to be left untouched, while methods in this class
	 * are used as extension methods for more specific persistence-layer
	 * accessors or mutators.
	 *
	 * Base Methods (Subject to be expanded upon in time)
	 *
	 * Note: Not all tables are designed appropriately to fit functionality with all base methods
	 *
	 * InsertOne
	 * UpdateOne
	 * DeleteOne
	 * FindOne
	 * GetWhere(std::string where_filter)
	 * DeleteWhere(std::string where_filter)
	 * InsertMany
	 * All
	 *
	 * Example custom methods in a repository
	 *
	 * CharacterClassExpRepository::GetByZoneAndVersion(int zone_id, int zone_version)
	 * CharacterClassExpRepository::GetWhereNeverExpires()
	 * CharacterClassExpRepository::GetWhereXAndY()
	 * CharacterClassExpRepository::DeleteWhereXAndY()
	 *
	 * Most of the above could be covered by base methods, but if you as a developer
	 * find yourself re-using logic for other parts of the code, its best to just make a
	 * method that can be re-used easily elsewhere especially if it can use a base repository
	 * method and encapsulate filters there
	 */

	// Custom extended repository methods here

	/**
	 * Loads every class row for one character. Returns false when the query itself failed, so
	 * callers can tell "this character has no rows" apart from "the database did not answer"
	 * and avoid treating a failed read as an empty result.
	 */
	static bool GetForCharacter(
		Database &db,
		uint32_t character_id,
		std::vector<CharacterClassExp> &entries
	)
	{
		auto results = db.QueryDatabase(
			fmt::format(
				"{} WHERE `character_id` = {}",
				BaseSelect(),
				character_id
			)
		);

		if (!results.Success()) {
			return false;
		}

		entries.reserve(entries.size() + results.RowCount());

		for (auto row = results.begin(); row != results.end(); ++row) {
			CharacterClassExp e{};

			e.character_id = row[0] ? static_cast<uint32_t>(strtoul(row[0], nullptr, 10)) : 0;
			e.class_id     = row[1] ? static_cast<uint8_t>(strtoul(row[1], nullptr, 10)) : 0;
			e.class_exp    = row[2] ? strtoull(row[2], nullptr, 10) : 0;

			entries.push_back(e);
		}

		return true;
	}

	/**
	 * Inserts one row without disturbing an existing one. An ignored duplicate is a success,
	 * so this reports results.Success() rather than RowsAffected().
	 */
	static bool InsertIgnoreOne(Database &db, const CharacterClassExp &e, bool *inserted = nullptr)
	{
		auto results = db.QueryDatabase(
			fmt::format(
				"INSERT IGNORE INTO {} ({}) VALUES ({}, {}, {})",
				TableName(),
				ColumnsRaw(),
				e.character_id,
				static_cast<uint32_t>(e.class_id),
				e.class_exp
			)
		);

		if (inserted) {
			*inserted = results.Success() && results.RowsAffected() > 0;
		}

		return results.Success();
	}

	static bool SaveRows(Database &db, const std::vector<CharacterClassExp> &entries)
	{
		std::vector<std::string> insert_chunks;

		for (const auto &e : entries) {
			insert_chunks.push_back(
				fmt::format("({}, {}, {})", e.character_id, static_cast<uint32_t>(e.class_id), e.class_exp)
			);
		}

		auto results = db.QueryDatabase(
			fmt::format(
				"{} VALUES {}",
				BaseReplace(),
				Strings::Implode(",", insert_chunks)
			)
		);

		return results.Success();
	}
};

#endif //EQEMU_CHARACTER_CLASS_EXP_REPOSITORY_H
