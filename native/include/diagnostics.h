#pragma once
#include <cstdint>
#include <filesystem>
#include <optional>
#include <string>

namespace azsg {
enum class BackendState { initializing,ready,unsupported,hooks_failed };
struct Diagnostics {
    BackendState backend=BackendState::initializing;
    std::string transport="waiting";
    unsigned speed100=100;
    std::uint64_t updated_unix=0,file_reads=0,dropped_bytes=0;
    std::optional<std::uint64_t> heartbeat_age_ms;
};
std::string diagnostics_json(const Diagnostics& state);
// Optional atomic report outside the addon sandbox. Never called from a clock
// hook or a console reader; a failed diagnostic write cannot stop the game.
bool write_diagnostics(const std::filesystem::path& root,const Diagnostics& state) noexcept;
}
