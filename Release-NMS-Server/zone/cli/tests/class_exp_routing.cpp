#include "../../class_exp_routing.h"

#include <limits>
#include <string>
#include <vector>

namespace {

std::string SerializeRows(const std::vector<uint64> &rows)
{
	std::string serialized = "[";
	for (size_t index = 0; index < rows.size(); ++index) {
		if (index != 0) {
			serialized += ",";
		}
		serialized += std::to_string(rows[index]);
	}
	return serialized + "]";
}

void RunClassExpRoutingCase(
	const std::string &description,
	std::vector<uint64> rows,
	int64 delta,
	uint64 cap,
	const std::string &expected_rows,
	uint64 expected_minimum
)
{
	const auto minimum = RouteClassExp(rows, delta, cap);
	RunTest(description + " rows", expected_rows, SerializeRows(rows));
	RunTest(description + " minimum", std::to_string(expected_minimum), std::to_string(minimum));
}

} // namespace

void ZoneCLI::TestClassExpRouting(int argc, char **argv, argh::parser &cmd, std::string &description)
{
	if (cmd[{"-h", "--help"}]) {
		return;
	}

	RunClassExpRoutingCase("Single laggard below next tier", {65, 65, 65, 1}, 10, 100, "[65,65,65,11]", 11);
	RunClassExpRoutingCase("Crosses next tier then splits", {650, 650, 650, 649}, 5, 1000, "[651,651,651,651]", 651);
	RunClassExpRoutingCase("Equalizes two rows", {100, 150}, 100, 1000, "[175,175]", 175);
	RunClassExpRoutingCase("Large gain crosses all tiers", {10, 20, 30}, 90, 100, "[50,50,50]", 50);
	RunClassExpRoutingCase("Negative delta lowers only the laggard", {65, 65, 65, 10}, -20, 100, "[65,65,65,0]", 0);
	RunClassExpRoutingCase("Cap clamps existing rows", {105, 100}, 1, 100, "[100,100]", 100);
	RunClassExpRoutingCase("Gain at cap is a no-op", {100, 100}, 10, 100, "[100,100]", 100);
	RunClassExpRoutingCase("Zero delta returns lagging minimum", {65, 65, 65, 1}, 0, 100, "[65,65,65,1]", 1);
	RunClassExpRoutingCase("Positive remainder uses lower indices", {10, 10, 10}, 2, 100, "[11,11,10]", 10);
	RunClassExpRoutingCase("Negative remainder uses lower indices", {10, 10, 10}, -2, 100, "[9,9,10]", 9);
	RunClassExpRoutingCase("Minimum signed delta floors safely", {5, 5}, std::numeric_limits<int64>::min(), 100, "[0,0]", 0);
	RunClassExpRoutingCase("Empty input", {}, 10, 100, "[]", 0);
}
