#include "class_exp_routing.h"

#include <algorithm>

namespace {

uint64 NegativeMagnitude(int64 delta)
{
	return static_cast<uint64>(-(delta + 1)) + 1;
}

} // namespace

uint64 RouteClassExp(std::vector<uint64> &rows, int64 delta, uint64 cap)
{
	if (rows.empty()) {
		return 0;
	}

	for (auto &row : rows) {
		row = std::min(row, cap);
	}

	auto current_min = *std::min_element(rows.begin(), rows.end());
	if (delta == 0 || (delta > 0 && current_min == cap)) {
		return current_min;
	}

	std::vector<size_t> minimum_indices;
	const auto collect_minimum_indices = [&]() {
		minimum_indices.clear();
		for (size_t index = 0; index < rows.size(); ++index) {
			if (rows[index] == current_min) {
				minimum_indices.push_back(index);
			}
		}
	};

	collect_minimum_indices();

	if (delta < 0) {
		const auto magnitude = NegativeMagnitude(delta);
		const auto count = static_cast<uint64>(minimum_indices.size());
		const auto maximum_reduction =
			current_min <= magnitude / count ? current_min * count : magnitude;
		const auto equal_reduction = maximum_reduction / count;
		const auto remainder = maximum_reduction % count;

		// Deterministic remainder: lower original vector indices receive it first.
		for (size_t position = 0; position < minimum_indices.size(); ++position) {
			rows[minimum_indices[position]] -=
				equal_reduction + (static_cast<uint64>(position) < remainder ? 1 : 0);
		}

		return *std::min_element(rows.begin(), rows.end());
	}

	auto budget = static_cast<uint64>(delta);
	while (budget > 0 && current_min < cap) {
		collect_minimum_indices();
		const auto count = static_cast<uint64>(minimum_indices.size());
		auto next_tier = cap;
		for (const auto row : rows) {
			if (row > current_min && row < next_tier) {
				next_tier = row;
			}
		}

		const auto gap = next_tier - current_min;
		if (gap > budget / count) {
			const auto equal_gain = budget / count;
			const auto remainder = budget % count;

			// Deterministic remainder: lower original vector indices receive it first.
			for (size_t position = 0; position < minimum_indices.size(); ++position) {
				rows[minimum_indices[position]] +=
					equal_gain + (static_cast<uint64>(position) < remainder ? 1 : 0);
			}
			break;
		}

		const auto cost = gap * count;
		for (const auto index : minimum_indices) {
			rows[index] = next_tier;
		}
		budget -= cost;
		current_min = next_tier;
	}

	return *std::min_element(rows.begin(), rows.end());
}
