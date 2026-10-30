#include "language_bridge.h"

#include <windows.h>
#include <array>
#include <cstddef>
#include <string>
#include <vector>

namespace azsg {
namespace {

bool whitespace(char value) noexcept {
    return value == ' ' || value == '\t' || value == '\r' || value == '\n' ||
           value == '\v' || value == '\f';
}

std::string_view trim(std::string_view value) noexcept {
    while (!value.empty() && whitespace(value.front())) value.remove_prefix(1);
    while (!value.empty() && whitespace(value.back())) value.remove_suffix(1);
    return value;
}

// Check every existing component, including the caller-supplied root's parents.
// Do not canonicalize first: that would erase a junction from the path we check.
bool safe_path(const std::filesystem::path& path, bool allow_missing_tail) {
    if (!path.is_absolute() || path.root_path().empty()) return false;
    const auto root = path.root_path();
    const DWORD root_attributes = GetFileAttributesW(root.c_str());
    if (root_attributes == INVALID_FILE_ATTRIBUTES ||
        !(root_attributes & FILE_ATTRIBUTE_DIRECTORY) ||
        (root_attributes & FILE_ATTRIBUTE_REPARSE_POINT)) return false;

    std::vector<std::filesystem::path> components;
    for (const auto& component : path.relative_path()) {
        if (component.empty()) continue; // A harmless trailing directory separator.
        if (component == L"." || component == L"..") return false;
        components.push_back(component);
    }
    auto current = root;
    for (std::size_t index = 0; index < components.size(); ++index) {
        current /= components[index];
        const DWORD attributes = GetFileAttributesW(current.c_str());
        if (attributes == INVALID_FILE_ATTRIBUTES) {
            const DWORD error = GetLastError();
            return allow_missing_tail &&
                   (error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND);
        }
        if (attributes & FILE_ATTRIBUTE_REPARSE_POINT) return false;
        if (index + 1 < components.size() && !(attributes & FILE_ATTRIBUTE_DIRECTORY))
            return false;
    }
    return true;
}

bool regular_file(const std::filesystem::path& path) noexcept {
    const DWORD attributes = GetFileAttributesW(path.c_str());
    return attributes != INVALID_FILE_ATTRIBUTES &&
           !(attributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT));
}

bool directory(const std::filesystem::path& path) noexcept {
    const DWORD attributes = GetFileAttributesW(path.c_str());
    return attributes != INVALID_FILE_ATTRIBUTES &&
           (attributes & FILE_ATTRIBUTE_DIRECTORY) &&
           !(attributes & FILE_ATTRIBUTE_REPARSE_POINT);
}

class FileHandle {
public:
    explicit FileHandle(HANDLE handle) noexcept : handle_(handle) {}
    ~FileHandle() { close(); }
    FileHandle(const FileHandle&) = delete;
    FileHandle& operator=(const FileHandle&) = delete;
    HANDLE get() const noexcept { return handle_; }
    bool valid() const noexcept { return handle_ != INVALID_HANDLE_VALUE; }
    void close() noexcept {
        if (valid()) {
            CloseHandle(handle_);
            handle_ = INVALID_HANDLE_VALUE;
        }
    }
private:
    HANDLE handle_;
};

// Check the size and read at most limit bytes. OPEN_REPARSE_POINT makes a
// replaced final path fail the handle check too; a second size check rejects a
// file that grew while it was being read.
std::optional<std::string> read_small(const std::filesystem::path& path,
                                     DWORD limit) {
    FileHandle file(CreateFileW(path.c_str(), GENERIC_READ,
                               FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                               nullptr, OPEN_EXISTING,
                               FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT,
                               nullptr));
    if (!file.valid()) return std::nullopt;
    BY_HANDLE_FILE_INFORMATION information{};
    if (!GetFileInformationByHandle(file.get(), &information) ||
        (information.dwFileAttributes &
         (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)) ||
        information.nFileSizeHigh != 0 || information.nFileSizeLow > limit)
        return std::nullopt;
    std::string bytes(static_cast<std::size_t>(limit), '\0');
    DWORD count = 0;
    LARGE_INTEGER final_size{};
    if (!ReadFile(file.get(), bytes.data(), limit, &count, nullptr) ||
        !GetFileSizeEx(file.get(), &final_size) || final_size.QuadPart < 0 ||
        final_size.QuadPart > limit || static_cast<ULONGLONG>(final_size.QuadPart) != count)
        return std::nullopt;
    bytes.resize(count);
    return bytes;
}

LanguageHintResult refresh(const std::filesystem::path& game_root,
                           const std::filesystem::path& language_file) {
    if (!safe_path(language_file, false) || !regular_file(language_file))
        return LanguageHintResult::skipped;
    const auto input = read_small(language_file, 64);
    if (!input) return LanguageHintResult::skipped;
    const auto language = parse_game_language(*input);
    if (!language) return LanguageHintResult::skipped;

    const auto addon = game_root / L"benilla-config" / L"AddOns" / L"AZSSpeedGear";
    const auto toc = addon / L"AZSSpeedGear.toc";
    const auto hint = addon / L"NativeLocale.lua";
    const auto runtime = game_root / L"benilla-config" / L"AZSSpeedGear-runtime";
    const auto staging = runtime / L"NativeLocale.tmp";
    if (!safe_path(game_root, false) || !directory(game_root) ||
        !safe_path(toc, false) || !regular_file(toc) ||
        !safe_path(hint, true) || !safe_path(runtime, true) ||
        !safe_path(staging, true)) return LanguageHintResult::skipped;

    const DWORD hint_attributes = GetFileAttributesW(hint.c_str());
    if (hint_attributes != INVALID_FILE_ATTRIBUTES && !regular_file(hint))
        return LanguageHintResult::skipped;
    const std::string expected = "-- AZSSpeedGear runtime locale hint\n"
                                 "AZSSpeedGearNativeLocale = \"" + *language + "\";\n";
    const auto previous = read_small(hint, 256);
    if (previous && *previous == expected) return LanguageHintResult::unchanged;

    if (!CreateDirectoryW(runtime.c_str(), nullptr) && GetLastError() != ERROR_ALREADY_EXISTS)
        return LanguageHintResult::skipped;
    if (!safe_path(runtime, false) || !directory(runtime) || !safe_path(staging, true))
        return LanguageHintResult::skipped;

    // Recover a stale staging file from an interrupted prior write. Delete the
    // name before CREATE_NEW rather than truncating a possibly hard-linked file.
    const DWORD staging_attributes = GetFileAttributesW(staging.c_str());
    if (staging_attributes != INVALID_FILE_ATTRIBUTES) {
        if (!regular_file(staging) || !DeleteFileW(staging.c_str()))
            return LanguageHintResult::skipped;
    }
    FileHandle output(CreateFileW(staging.c_str(), GENERIC_WRITE, 0, nullptr,
                                 CREATE_NEW,
                                 FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT,
                                 nullptr));
    if (!output.valid()) return LanguageHintResult::skipped;
    DWORD written = 0;
    const bool complete = WriteFile(output.get(), expected.data(),
                                    static_cast<DWORD>(expected.size()), &written, nullptr) &&
                          written == expected.size() && FlushFileBuffers(output.get());
    output.close();
    if (!complete || !safe_path(toc, false) || !regular_file(toc) ||
        !safe_path(hint, true) || !safe_path(staging, false) ||
        !MoveFileExW(staging.c_str(), hint.c_str(),
                     MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) {
        // No recursive operation; only this module's exact temporary filename.
        DeleteFileW(staging.c_str());
        return LanguageHintResult::skipped;
    }
    return LanguageHintResult::written;
}

} // namespace

std::optional<std::string> parse_game_language(std::string_view input) {
    if (input.size() > 64) return std::nullopt;
    input = trim(input);
    if (input.size() >= 3 && input.substr(0, 3) == "\xEF\xBB\xBF") {
        input.remove_prefix(3);
        input = trim(input);
    }
    constexpr std::array<std::string_view, 14> languages{
        "en", "pl", "cs", "de", "pt", "es", "fr", "ro", "tr", "ru", "uk", "zh", "ja", "ko"
    };
    for (const auto language : languages) {
        if (input == language) return std::string(language);
    }
    return std::nullopt;
}

LanguageHintResult refresh_language_hint(const std::filesystem::path& game_root,
                                         const std::filesystem::path& language_file) noexcept {
    try {
        return refresh(game_root, language_file);
    } catch (...) {
        // Locale synchronization is optional and must never abort the game.
        return LanguageHintResult::skipped;
    }
}

} // namespace azsg
