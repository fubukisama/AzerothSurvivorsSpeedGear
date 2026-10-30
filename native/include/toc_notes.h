#pragma once

#include <filesystem>
#include <optional>
#include <string>
#include <string_view>

namespace azsg {
enum class TocNotesResult { skipped, unchanged, written };

// Accept only the exact compiled TOC with one Notes value selected from its
// fourteen own translations. Returns those bytes with English Notes restored.
std::optional<std::string> canonical_toc(std::string_view data) noexcept;

TocNotesResult refresh_toc_notes(const std::filesystem::path& game_root,
                                 const std::filesystem::path& language_file) noexcept;

// For static-import DLL attachment only. Kernel32, fixed stack storage and
// bounded local-file IO; no heap, private lock, thread, network or EP changes.
TocNotesResult initialize_toc_notes_before_entry() noexcept;
} // namespace azsg
