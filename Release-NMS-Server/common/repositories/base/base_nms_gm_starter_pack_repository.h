/**
 * DO NOT MODIFY THIS FILE
 *
 * This repository was automatically generated and is NOT to be modified directly.
 * Any repository modifications are meant to be made to the repository extending the base.
 * Any modifications to base repositories are to be made by the generator only
 *
 * @generator ./utils/scripts/generators/repository-generator.pl
 * @docs https://docs.eqemu.io/developer/repositories
 */

#ifndef EQEMU_BASE_NMS_GM_STARTER_PACK_REPOSITORY_H
#define EQEMU_BASE_NMS_GM_STARTER_PACK_REPOSITORY_H

#include "../../database.h"
#include "../../strings.h"
#include <ctime>

class BaseNmsGmStarterPackRepository {
public:
	struct NmsGmStarterPack {
		uint32_t    id;
		std::string bag;
		uint32_t    item_id;
		int16_t     charges;
		uint16_t    count;
		int16_t     sort;
		std::string note;
	};

	static std::string PrimaryKey()
	{
		return std::string("id");
	}

	static std::vector<std::string> Columns()
	{
		return {
			"id",
			"bag",
			"item_id",
			"charges",
			"`count`",
			"`sort`",
			"note",
		};
	}

	static std::vector<std::string> SelectColumns()
	{
		return {
			"id",
			"bag",
			"item_id",
			"charges",
			"`count`",
			"`sort`",
			"note",
		};
	}

	static std::string ColumnsRaw()
	{
		return std::string(Strings::Implode(", ", Columns()));
	}

	static std::string SelectColumnsRaw()
	{
		return std::string(Strings::Implode(", ", SelectColumns()));
	}

	static std::string TableName()
	{
		return std::string("nms_gm_starter_pack");
	}

	static std::string BaseSelect()
	{
		return fmt::format(
			"SELECT {} FROM {}",
			SelectColumnsRaw(),
			TableName()
		);
	}

	static std::string BaseInsert()
	{
		return fmt::format(
			"INSERT INTO {} ({}) ",
			TableName(),
			ColumnsRaw()
		);
	}

	static NmsGmStarterPack NewEntity()
	{
		NmsGmStarterPack e{};

		e.id       = 0;
		e.bag      = "";
		e.item_id  = 0;
		e.charges  = -1;
		e.count    = 1;
		e.sort     = 0;
		e.note     = "";

		return e;
	}

	static NmsGmStarterPack GetNmsGmStarterPack(
		const std::vector<NmsGmStarterPack> &nms_gm_starter_packs,
		int nms_gm_starter_pack_id
	)
	{
		for (auto &nms_gm_starter_pack : nms_gm_starter_packs) {
			if (nms_gm_starter_pack.id == nms_gm_starter_pack_id) {
				return nms_gm_starter_pack;
			}
		}

		return NewEntity();
	}

	static NmsGmStarterPack FindOne(
		Database& db,
		int nms_gm_starter_pack_id
	)
	{
		auto results = db.QueryDatabase(
			fmt::format(
				"{} WHERE {} = {} LIMIT 1",
				BaseSelect(),
				PrimaryKey(),
				nms_gm_starter_pack_id
			)
		);

		auto row = results.begin();
		if (results.RowCount() == 1) {
			NmsGmStarterPack e{};

			e.id      = row[0] ? static_cast<uint32_t>(strtoul(row[0], nullptr, 10)) : 0;
			e.bag     = row[1] ? row[1] : "";
			e.item_id = row[2] ? static_cast<uint32_t>(strtoul(row[2], nullptr, 10)) : 0;
			e.charges = row[3] ? static_cast<int16_t>(atoi(row[3])) : -1;
			e.count   = row[4] ? static_cast<uint16_t>(strtoul(row[4], nullptr, 10)) : 1;
			e.sort    = row[5] ? static_cast<int16_t>(atoi(row[5])) : 0;
			e.note    = row[6] ? row[6] : "";

			return e;
		}

		return NewEntity();
	}

	static int DeleteOne(
		Database& db,
		int nms_gm_starter_pack_id
	)
	{
		auto results = db.QueryDatabase(
			fmt::format(
				"DELETE FROM {} WHERE {} = {}",
				TableName(),
				PrimaryKey(),
				nms_gm_starter_pack_id
			)
		);

		return (results.Success() ? results.RowsAffected() : 0);
	}

	static int UpdateOne(
		Database& db,
		const NmsGmStarterPack &e
	)
	{
		std::vector<std::string> v;

		auto columns = Columns();

		v.push_back(columns[0] + " = " + std::to_string(e.id));
		v.push_back(columns[1] + " = '" + Strings::Escape(e.bag) + "'");
		v.push_back(columns[2] + " = " + std::to_string(e.item_id));
		v.push_back(columns[3] + " = " + std::to_string(e.charges));
		v.push_back(columns[4] + " = " + std::to_string(e.count));
		v.push_back(columns[5] + " = " + std::to_string(e.sort));
		v.push_back(columns[6] + " = '" + Strings::Escape(e.note) + "'");

		auto results = db.QueryDatabase(
			fmt::format(
				"UPDATE {} SET {} WHERE {} = {}",
				TableName(),
				Strings::Implode(", ", v),
				PrimaryKey(),
				e.id
			)
		);

		return (results.Success() ? results.RowsAffected() : 0);
	}

	static NmsGmStarterPack InsertOne(
		Database& db,
		NmsGmStarterPack e
	)
	{
		std::vector<std::string> v;

		v.push_back(std::to_string(e.id));
		v.push_back("'" + Strings::Escape(e.bag) + "'");
		v.push_back(std::to_string(e.item_id));
		v.push_back(std::to_string(e.charges));
		v.push_back(std::to_string(e.count));
		v.push_back(std::to_string(e.sort));
		v.push_back("'" + Strings::Escape(e.note) + "'");

		auto results = db.QueryDatabase(
			fmt::format(
				"{} VALUES ({})",
				BaseInsert(),
				Strings::Implode(",", v)
			)
		);

		if (results.Success()) {
			e.id = results.LastInsertedID();
			return e;
		}

		e = NewEntity();

		return e;
	}

	static int InsertMany(
		Database& db,
		const std::vector<NmsGmStarterPack> &entries
	)
	{
		std::vector<std::string> insert_chunks;

		for (auto &e: entries) {
			std::vector<std::string> v;

			v.push_back(std::to_string(e.id));
			v.push_back("'" + Strings::Escape(e.bag) + "'");
			v.push_back(std::to_string(e.item_id));
			v.push_back(std::to_string(e.charges));
			v.push_back(std::to_string(e.count));
			v.push_back(std::to_string(e.sort));
			v.push_back("'" + Strings::Escape(e.note) + "'");

			insert_chunks.push_back("(" + Strings::Implode(",", v) + ")");
		}

		std::vector<std::string> v;

		auto results = db.QueryDatabase(
			fmt::format(
				"{} VALUES {}",
				BaseInsert(),
				Strings::Implode(",", insert_chunks)
			)
		);

		return (results.Success() ? results.RowsAffected() : 0);
	}

	static std::vector<NmsGmStarterPack> All(Database& db)
	{
		std::vector<NmsGmStarterPack> all_entries;

		auto results = db.QueryDatabase(
			fmt::format(
				"{}",
				BaseSelect()
			)
		);

		all_entries.reserve(results.RowCount());

		for (auto row = results.begin(); row != results.end(); ++row) {
			NmsGmStarterPack e{};

			e.id      = row[0] ? static_cast<uint32_t>(strtoul(row[0], nullptr, 10)) : 0;
			e.bag     = row[1] ? row[1] : "";
			e.item_id = row[2] ? static_cast<uint32_t>(strtoul(row[2], nullptr, 10)) : 0;
			e.charges = row[3] ? static_cast<int16_t>(atoi(row[3])) : -1;
			e.count   = row[4] ? static_cast<uint16_t>(strtoul(row[4], nullptr, 10)) : 1;
			e.sort    = row[5] ? static_cast<int16_t>(atoi(row[5])) : 0;
			e.note    = row[6] ? row[6] : "";

			all_entries.push_back(e);
		}

		return all_entries;
	}

	static std::vector<NmsGmStarterPack> GetWhere(Database& db, const std::string &where_filter)
	{
		std::vector<NmsGmStarterPack> all_entries;

		auto results = db.QueryDatabase(
			fmt::format(
				"{} WHERE {}",
				BaseSelect(),
				where_filter
			)
		);

		all_entries.reserve(results.RowCount());

		for (auto row = results.begin(); row != results.end(); ++row) {
			NmsGmStarterPack e{};

			e.id      = row[0] ? static_cast<uint32_t>(strtoul(row[0], nullptr, 10)) : 0;
			e.bag     = row[1] ? row[1] : "";
			e.item_id = row[2] ? static_cast<uint32_t>(strtoul(row[2], nullptr, 10)) : 0;
			e.charges = row[3] ? static_cast<int16_t>(atoi(row[3])) : -1;
			e.count   = row[4] ? static_cast<uint16_t>(strtoul(row[4], nullptr, 10)) : 1;
			e.sort    = row[5] ? static_cast<int16_t>(atoi(row[5])) : 0;
			e.note    = row[6] ? row[6] : "";

			all_entries.push_back(e);
		}

		return all_entries;
	}

	static int DeleteWhere(Database& db, const std::string &where_filter)
	{
		auto results = db.QueryDatabase(
			fmt::format(
				"DELETE FROM {} WHERE {}",
				TableName(),
				where_filter
			)
		);

		return (results.Success() ? results.RowsAffected() : 0);
	}

	static int Truncate(Database& db)
	{
		auto results = db.QueryDatabase(
			fmt::format(
				"TRUNCATE TABLE {}",
				TableName()
			)
		);

		return (results.Success() ? results.RowsAffected() : 0);
	}

	static int64 GetMaxId(Database& db)
	{
		auto results = db.QueryDatabase(
			fmt::format(
				"SELECT COALESCE(MAX({}), 0) FROM {}",
				PrimaryKey(),
				TableName()
			)
		);

		return (results.Success() && results.begin()[0] ? strtoll(results.begin()[0], nullptr, 10) : 0);
	}

	static int64 Count(Database& db, const std::string &where_filter = "")
	{
		auto results = db.QueryDatabase(
			fmt::format(
				"SELECT COUNT(*) FROM {} {}",
				TableName(),
				(where_filter.empty() ? "" : "WHERE " + where_filter)
			)
		);

		return (results.Success() && results.begin()[0] ? strtoll(results.begin()[0], nullptr, 10) : 0);
	}

	static std::string BaseReplace()
	{
		return fmt::format(
			"REPLACE INTO {} ({}) ",
			TableName(),
			ColumnsRaw()
		);
	}

	static int ReplaceOne(
		Database& db,
		const NmsGmStarterPack &e
	)
	{
		std::vector<std::string> v;

		v.push_back(std::to_string(e.id));
		v.push_back("'" + Strings::Escape(e.bag) + "'");
		v.push_back(std::to_string(e.item_id));
		v.push_back(std::to_string(e.charges));
		v.push_back(std::to_string(e.count));
		v.push_back(std::to_string(e.sort));
		v.push_back("'" + Strings::Escape(e.note) + "'");

		auto results = db.QueryDatabase(
			fmt::format(
				"{} VALUES ({})",
				BaseReplace(),
				Strings::Implode(",", v)
			)
		);

		return (results.Success() ? results.RowsAffected() : 0);
	}

	static int ReplaceMany(
		Database& db,
		const std::vector<NmsGmStarterPack> &entries
	)
	{
		std::vector<std::string> insert_chunks;

		for (auto &e: entries) {
			std::vector<std::string> v;

			v.push_back(std::to_string(e.id));
			v.push_back("'" + Strings::Escape(e.bag) + "'");
			v.push_back(std::to_string(e.item_id));
			v.push_back(std::to_string(e.charges));
			v.push_back(std::to_string(e.count));
			v.push_back(std::to_string(e.sort));
			v.push_back("'" + Strings::Escape(e.note) + "'");

			insert_chunks.push_back("(" + Strings::Implode(",", v) + ")");
		}

		std::vector<std::string> v;

		auto results = db.QueryDatabase(
			fmt::format(
				"{} VALUES {}",
				BaseReplace(),
				Strings::Implode(",", insert_chunks)
			)
		);

		return (results.Success() ? results.RowsAffected() : 0);
	}
};

#endif //EQEMU_BASE_NMS_GM_STARTER_PACK_REPOSITORY_H
