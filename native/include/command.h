#pragma once

#include <array>
#include <cstdint>
#include <limits>
#include <optional>
#include <string_view>

namespace azsg {

struct Command {
    std::uint64_t session;
    std::uint64_t sequence;
    std::uint64_t unix_seconds;
    std::uint32_t speed100;
    bool active;
};

namespace detail {

inline std::optional<std::uint64_t> parse_decimal(std::string_view text) noexcept {
    if (text.empty()) {
        return std::nullopt;
    }
    std::uint64_t value = 0;
    constexpr auto limit = std::numeric_limits<std::uint64_t>::max();
    for (const char ch : text) {
        if (ch < '0' || ch > '9') {
            return std::nullopt;
        }
        const auto digit = static_cast<std::uint64_t>(ch - '0');
        if (value > (limit - digit) / 10) {
            return std::nullopt;
        }
        value = value * 10 + digit;
    }
    return value;
}

} // namespace detail

// SG1|session|sequence|unixSeconds|speed100|active
// Grammar is ASCII decimal only. Time freshness, session changes and sequence
// ordering are policy checks for the native mailbox consumer, not this parser.
inline std::optional<Command> parse_command(std::string_view text) noexcept {
    if (text.size() < 4 || text.substr(0, 4) != "SG1|") {
        return std::nullopt;
    }
    text.remove_prefix(4);
    std::array<std::uint64_t, 5> values{};
    for (std::size_t index = 0; index < values.size(); ++index) {
        const auto separator = text.find('|');
        const bool last = index + 1 == values.size();
        if ((!last && separator == std::string_view::npos) ||
            (last && separator != std::string_view::npos)) {
            return std::nullopt;
        }
        const auto part = last ? text : text.substr(0, separator);
        const auto value = detail::parse_decimal(part);
        if (!value) {
            return std::nullopt;
        }
        values[index] = *value;
        if (!last) {
            text.remove_prefix(separator + 1);
        }
    }
    if (values[0] == 0 || values[1] == 0 || values[2] == 0 ||
        values[3] < 25 || values[3] > 1000 || values[4] > 1) {
        return std::nullopt;
    }
    return Command{values[0], values[1], values[2],
                   static_cast<std::uint32_t>(values[3]), values[4] == 1};
}

} // namespace azsg
