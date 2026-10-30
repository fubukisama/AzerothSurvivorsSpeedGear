#pragma once
#include <cstddef>
#include <cstdint>
#include <string_view>
namespace azsg {
// Observe only this addon's ConsoleExec CVar query; normal forwarding preserves
// every byte without changing the original output stream's contents.
// Forwarding uses one independent worker and a fixed-size ring per channel. A
// blocked original output cannot block command parsing. Normal output is kept
// byte-for-byte; on overload, the oldest queued log bytes are discarded after
// their commands have already been parsed. An in-flight write is not discarded.
// The DLL and installed handles are process-lifetime, not dynamically unloaded.
// No game VM or version-specific ABI is accessed. Repeated starts are idempotent.
bool start_console_bridge(void(*receive)(std::string_view));

inline constexpr std::size_t console_bridge_queue_capacity = 256 * 1024;
struct ConsoleBridgeStats {
    std::uint64_t queued_bytes = 0;
    std::uint64_t forwarded_bytes = 0;
    std::uint64_t overflow_dropped_bytes = 0;
    std::uint64_t forwarding_error_bytes = 0;
    unsigned installed_channels = 0;
};
// Diagnostics take only short in-memory locks; no disk or output writes occur.
ConsoleBridgeStats console_bridge_stats();
// Overflow plus bytes lost after an original output has failed. Channels that
// had no original output (normal for Explorer-launched GUI games) are excluded.
std::uint64_t console_bridge_dropped_bytes() noexcept;
}
