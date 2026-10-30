#include "command.h"
#include "speed_clock.h"

#include <cstdint>
#include <iostream>
#include <limits>
#include <string>
#include <string_view>

namespace {
unsigned assertions = 0;
unsigned failures = 0;

void expect(bool condition, const char* message) {
    ++assertions;
    if (!condition) {
        ++failures;
        std::cerr << "FAIL: " << message << '\n';
    }
}

void test_continuity() {
    azsg::VirtualClock clock;
    expect(!clock.initialized(), "clock initially uninitialized");
    expect(clock.speed100() == 100, "default rate is 1x");
    expect(clock.sample(1000) == 1000, "first sample preserves origin");
    expect(clock.initialized(), "first sample initializes");
    expect(clock.advance(1010) == 1010, "1x advances naturally");
    expect(clock.set_speed(1015, 200), "2x accepted");
    expect(clock.sample(1015) == 1015, "change settles old rate without jump");
    expect(clock.sample(1020) == 1025, "2x affects only subsequent time");
    expect(clock.set_speed(1025, 25), "quarter speed accepted");
    expect(clock.sample(1025) == 1035, "second change settles preceding 2x");
    expect(clock.sample(1029) == 1036, "quarter speed affects future interval");
    expect(clock.set_speed(1030, 100), "restore normal rate");
    expect(clock.sample(1034) == 1040, "restore is continuous");
}

void test_fractional_reads() {
    azsg::VirtualClock frequent;
    azsg::VirtualClock batched;
    expect(frequent.set_speed(0, 25), "fraction clock rate accepted");
    expect(batched.set_speed(0, 25), "batched clock rate accepted");
    for (std::uint64_t tick = 1; tick <= 10003; ++tick) {
        expect(frequent.sample(tick) == tick / 4,
               "frequent quarter-speed samples retain fractional progress");
    }
    expect(frequent.sample(10003) == batched.sample(10003),
           "sample frequency does not change elapsed result");
    azsg::VirtualClock across_change;
    across_change.set_speed(0, 25);
    expect(across_change.sample(1) == 0, "one quarter tick retained");
    across_change.set_speed(1, 175);
    expect(across_change.sample(2) == 2, "fractions survive a rate change");
    expect(across_change.sample(3) == 3, "new fractional rate continues");
    expect(across_change.sample(4) == 5, "fractional rate accumulates exactly");
}

void test_backward_samples() {
    azsg::VirtualClock clock;
    expect(clock.sample(100) == 100, "backwards test starts");
    expect(clock.sample(90) == 100, "old sample cannot regress virtual time");
    expect(clock.sample(110) == 110, "old sample cannot double-count elapsed time");
    expect(clock.sample(110) == 110, "equal timestamp is a no-op");
    expect(clock.set_speed(105, 200), "stale change can set a valid rate");
    expect(clock.sample(115) == 120, "stale change applies from high-water mark");
    expect(!clock.set_speed(120, 24), "rate below range rejected");
    expect(!clock.set_speed(120, 1001), "rate above range rejected");
    expect(!clock.set_speed(120, 0), "zero rate rejected");
    expect(!clock.set_speed(120, std::numeric_limits<std::uint32_t>::max()),
           "oversized rate rejected");
    expect(clock.speed100() == 200, "invalid rates leave current rate intact");
    expect(clock.sample(120) == 130, "invalid changes leave real high-water intact");
}

void test_limits() {
    constexpr auto max = std::numeric_limits<std::uint64_t>::max();
    azsg::VirtualClock normal;
    normal.sample(0);
    expect(normal.sample(max) == max, "full-width 1x delta does not overflow");

    azsg::VirtualClock slow;
    slow.set_speed(0, 25);
    expect(slow.sample(max) == max / 4, "full-width slow delta splits multiplication");

    azsg::VirtualClock fast;
    fast.set_speed(0, 1000);
    expect(fast.sample(max) == max, "unrepresentable fast delta saturates");
    expect(fast.sample(1) == max, "saturated clock never wraps on backward input");

    azsg::VirtualClock near_limit;
    near_limit.set_speed(max - 5, 1000);
    expect(near_limit.sample(max - 4) == max, "virtual addition overflow saturates");
    expect(near_limit.sample(max) == max, "saturation remains monotonic");

    azsg::VirtualClock product_boundary;
    product_boundary.set_speed(0, 1000);
    const auto safe_delta = max / 10;
    expect(product_boundary.sample(safe_delta) == safe_delta * 10,
           "largest representable 10x delta is exact");
    expect(product_boundary.sample(safe_delta + 1) == max,
           "next 10x step saturates without wrapping");

    azsg::VirtualClock offset;
    offset.set_speed(37, 333);
    expect(offset.sample(137) == 370, "nonzero origin and fractional rate");
}

void test_protocol() {
    const auto command = azsg::parse_command("SG1|123|7|1793318400|250|1");
    expect(command.has_value(), "canonical command parses");
    if (command) {
        expect(command->session == 123 && command->sequence == 7 &&
                   command->unix_seconds == 1793318400 && command->speed100 == 250 &&
                   command->active,
               "canonical fields retain values");
    }
    const auto minimum = azsg::parse_command("SG1|1|1|1|25|0");
    expect(minimum && minimum->speed100 == 25 && !minimum->active,
           "lower rate and inactive flag parse");
    const auto maximum = azsg::parse_command(
        "SG1|18446744073709551615|18446744073709551615|18446744073709551615|1000|1");
    expect(maximum && maximum->sequence == std::numeric_limits<std::uint64_t>::max(),
           "full-width unsigned command fields parse exactly");
    expect(azsg::parse_command("SG1|0001|0002|0003|0100|0").has_value(),
           "decimal leading zeros remain decimal");
    constexpr std::string_view invalid[] = {
        "", "SG1", "SG1|", "SG2|1|1|1|100|1", "sg1|1|1|1|100|1",
        "SG10|1|1|1|100|1", " SG1|1|1|1|100|1", "SG1|1|1|1|100",
        "SG1|1|1|1|100|1|", "SG1|1|1|1|100|1|2", "SG1||1|1|100|1",
        "SG1|1||1|100|1", "SG1|1|1||100|1", "SG1|1|1|1||1",
        "SG1|1|1|1|100|", "SG1|0|1|1|100|1", "SG1|1|0|1|100|1",
        "SG1|1|1|0|100|1", "SG1|1|1|1|24|1", "SG1|1|1|1|1001|1",
        "SG1|1|1|1|100|2", "SG1|+1|1|1|100|1", "SG1|-1|1|1|100|1",
        "SG1|1|1|1|1.00|1", "SG1|1|1|1|1e2|1", "SG1|1|1|1|0x64|1",
        "SG1|1|1|1| 100|1", "SG1|1|1|1|100 |1", "SG1|1|1|1|100|1\n",
        "SG1|1|1|1|100|1\r", "SG1|1|1|1|100|true",
        "SG1|18446744073709551616|1|1|100|1",
        "SG1|1|18446744073709551616|1|100|1",
        "SG1|1|1|18446744073709551616|100|1",
        "SG1|1|1|1|18446744073709551616|1",
        "SG1|1|1|1|100|18446744073709551616",
    };
    for (const auto text : invalid) {
        expect(!azsg::parse_command(text), "malformed command rejected");
    }
    const std::string embedded_null("SG1|1|1|1|100|1\0garbage", 22);
    expect(!azsg::parse_command(embedded_null), "embedded NUL and tail rejected");
    const std::string non_ascii = "SG1|1|1|1|\xEF\xBC\x91\xEF\xBC\x90\xEF\xBC\x90|1";
    expect(!azsg::parse_command(non_ascii), "non-ASCII decimal lookalikes rejected");
}
} // namespace

int main() {
    test_continuity();
    test_fractional_reads();
    test_backward_samples();
    test_limits();
    test_protocol();
    std::cout << assertions << " assertions, " << failures << " failures\n";
    return failures == 0 ? 0 : 1;
}
