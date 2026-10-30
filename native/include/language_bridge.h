#pragma once

#include <filesystem>
#include <optional>
#include <string>
#include <string_view>

namespace azsg {

// Only the game's fourteen exact language codes are accepted. A UTF-8 BOM and
// surrounding ASCII whitespace are permitted, with a 64-byte input ceiling.
std::optional<std::string> parse_game_language(std::string_view input);

enum class LanguageHintResult {
    skipped,   // Missing/invalid input, unsafe path, missing addon, or an IO error.
    unchanged, // Valid input; the existing hint already has the exact content.
    written    // A complete hint was flushed and atomically installed.
};

// Intended for the backend's ordinary worker, never a timing hook. The caller
// supplies the language file location; this module does not inspect APPDATA.
LanguageHintResult refresh_language_hint(
    const std::filesystem::path& game_root,
    const std::filesystem::path& language_file) noexcept;

} // namespace azsg
