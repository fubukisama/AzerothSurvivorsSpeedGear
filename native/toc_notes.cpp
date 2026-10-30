#include "toc_notes.h"
#include "toc_notes_identity.h"

#include <windows.h>
#include <cstddef>

namespace azsg {
namespace {
constexpr std::size_t maximum_toc = 16 * 1024;
constexpr std::size_t path_capacity = 2048;
constexpr auto& original = AZSG_TOC_TEMPLATE;
constexpr std::size_t original_size = sizeof(original) - 1;
static_assert(original_size > 0 && original_size <= maximum_toc, "TOC template must fit the bounded synchronizer.");
constexpr char languages[14][3] = {
    "en", "zh", "ja", "pl", "cs", "de", "pt", "es", "fr", "ro", "tr", "ru", "uk", "ko"
};
struct Range { std::size_t begin = 0, size = 0; };
struct TemplateInfo { Range notes, translations[14]; };

bool equal_bytes(const char* left, const char* right, std::size_t size) noexcept {
    for (std::size_t index = 0; index < size; ++index) if (left[index] != right[index]) return false;
    return true;
}
void copy_bytes(char* destination, const char* source, std::size_t size) noexcept {
    for (std::size_t index = 0; index < size; ++index) destination[index] = source[index];
}
bool find_value(const char* key, std::size_t key_size, Range& result) noexcept {
    unsigned matches = 0;
    for (std::size_t start = 0; start < original_size;) {
        auto end = start;
        while (end < original_size && original[end] != '\n') ++end;
        auto text_end = end;
        if (text_end > start && original[text_end - 1] == '\r') --text_end;
        if (text_end - start >= key_size && equal_bytes(original + start, key, key_size)) {
            auto value = start + key_size;
            while (value < text_end && (original[value] == ' ' || original[value] == '\t')) ++value;
            if (value == text_end || text_end - value > 1024) return false;
            result.begin = value; result.size = text_end - value; ++matches;
        }
        start = end < original_size ? end + 1 : original_size;
    }
    return matches == 1;
}
bool template_info(TemplateInfo& info) noexcept {
    constexpr char notes_key[] = "## Notes:";
    constexpr char translated_key[] = "## X-AZSG-Notes-";
    if (!find_value(notes_key, sizeof(notes_key) - 1, info.notes)) return false;
    for (unsigned language = 0; language < 14; ++language) {
        char key[32]{};
        std::size_t length = sizeof(translated_key) - 1;
        copy_bytes(key, translated_key, length);
        key[length++] = languages[language][0]; key[length++] = languages[language][1]; key[length++] = ':';
        if (!find_value(key, length, info.translations[language])) return false;
    }
    const auto english = info.translations[0];
    return english.size == info.notes.size &&
           equal_bytes(original + english.begin, original + info.notes.begin, english.size);
}
bool current_notes(const char* data, std::size_t size, const TemplateInfo& info, Range& notes) noexcept {
    if (!data || size > maximum_toc) return false;
    const auto suffix = info.notes.begin + info.notes.size;
    const auto suffix_size = original_size - suffix;
    for (const auto& translation : info.translations) {
        if (size != original_size - info.notes.size + translation.size) continue;
        if (!equal_bytes(data, original, info.notes.begin) ||
            !equal_bytes(data + info.notes.begin, original + translation.begin, translation.size) ||
            !equal_bytes(data + info.notes.begin + translation.size, original + suffix, suffix_size)) continue;
        notes.begin = info.notes.begin; notes.size = translation.size; return true;
    }
    return false;
}
bool compose(const char* data, std::size_t size, Range notes, Range desired,
             char* output, std::size_t& output_size) noexcept {
    if (size < notes.size || size - notes.size + desired.size > maximum_toc) return false;
    copy_bytes(output, data, notes.begin);
    copy_bytes(output + notes.begin, original + desired.begin, desired.size);
    const auto suffix = notes.begin + notes.size;
    copy_bytes(output + notes.begin + desired.size, data + suffix, size - suffix);
    output_size = size - notes.size + desired.size;
    return true;
}
bool whitespace(char value) noexcept {
    return value == ' ' || value == '\t' || value == '\n' || value == '\r' || value == '\v' || value == '\f';
}
unsigned language_index(const char* data, std::size_t size) noexcept {
    auto begin = std::size_t{0};
    while (begin < size && whitespace(data[begin])) ++begin;
    while (size > begin && whitespace(data[size - 1])) --size;
    if (size - begin >= 3 && static_cast<unsigned char>(data[begin]) == 0xef &&
        static_cast<unsigned char>(data[begin + 1]) == 0xbb && static_cast<unsigned char>(data[begin + 2]) == 0xbf) {
        begin += 3;
        while (begin < size && whitespace(data[begin])) ++begin;
    }
    if (size - begin == 2) for (unsigned index = 0; index < 14; ++index)
        if (data[begin] == languages[index][0] && data[begin + 1] == languages[index][1]) return index;
    return 0;
}

std::size_t bounded_length(const wchar_t* value) noexcept {
    if (!value) return path_capacity;
    std::size_t size = 0;
    while (size < path_capacity && value[size]) ++size;
    return size;
}
bool copy_path(wchar_t* destination, const wchar_t* source) noexcept {
    const auto size = bounded_length(source);
    if (size >= path_capacity) return false;
    for (std::size_t index = 0; index <= size; ++index) destination[index] = source[index];
    return true;
}
bool append_path(wchar_t* path, const wchar_t* suffix) noexcept {
    auto size = bounded_length(path);
    const auto extra = bounded_length(suffix);
    if (size >= path_capacity || extra >= path_capacity) return false;
    if (size && path[size - 1] != '\\' && path[size - 1] != '/') {
        if (size + 1 >= path_capacity) return false;
        path[size++] = '\\'; path[size] = 0;
    }
    if (size + extra >= path_capacity) return false;
    for (std::size_t index = 0; index <= extra; ++index) path[size + index] = suffix[index];
    return true;
}
bool append_pid(wchar_t* path) noexcept {
    auto size = bounded_length(path);
    if (size >= path_capacity) return false;
    auto value = GetCurrentProcessId();
    wchar_t reverse[10]; unsigned count = 0;
    do { reverse[count++] = static_cast<wchar_t>(L'0' + value % 10); value /= 10; } while (value);
    constexpr wchar_t suffix[] = L".tmp";
    if (size + count + 4 >= path_capacity) return false;
    while (count) path[size++] = reverse[--count];
    for (unsigned index = 0; index < 5; ++index) path[size + index] = suffix[index];
    return true;
}
bool separator(wchar_t value) noexcept { return value == '\\' || value == '/'; }
bool safe_path(const wchar_t* path, bool allow_missing) noexcept {
    const auto size = bounded_length(path);
    if (size < 3 || size >= path_capacity || path[1] != ':' || !separator(path[2]) ||
        !((path[0] >= 'A' && path[0] <= 'Z') || (path[0] >= 'a' && path[0] <= 'z'))) return false;
    // No UNC, device paths, network-mapped drives, dot traversal or ADS paths.
    wchar_t drive[4] = {path[0], L':', L'\\', 0};
    const auto type = GetDriveTypeW(drive);
    if (type != DRIVE_FIXED && type != DRIVE_REMOVABLE && type != DRIVE_RAMDISK) return false;
    for (std::size_t begin = 3; begin < size;) {
        auto end = begin;
        while (end < size && !separator(path[end])) { if (path[end] == ':') return false; ++end; }
        if (end == begin || (end - begin == 1 && path[begin] == '.') ||
            (end - begin == 2 && path[begin] == '.' && path[begin + 1] == '.')) return false;
        begin = end + 1;
    }
    wchar_t current[path_capacity];
    if (!copy_path(current, path)) return false;
    for (std::size_t end = 3; end <= size; ++end) {
        if (end < size && !separator(current[end])) continue;
        const auto saved = current[end]; current[end] = 0;
        const auto attributes = GetFileAttributesW(current);
        current[end] = saved;
        if (attributes == INVALID_FILE_ATTRIBUTES) {
            const auto error = GetLastError();
            return allow_missing && (error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND);
        }
        if (attributes & FILE_ATTRIBUTE_REPARSE_POINT) return false;
        if (end < size && !(attributes & FILE_ATTRIBUTE_DIRECTORY)) return false;
    }
    return true;
}
enum class ReadResult { read, missing, too_large, failed };
ReadResult read_file(const wchar_t* path, char* data, DWORD maximum, DWORD& count) noexcept {
    count = 0;
    const auto file = CreateFileW(path, GENERIC_READ,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr, OPEN_EXISTING,
        FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_SEQUENTIAL_SCAN, nullptr);
    if (file == INVALID_HANDLE_VALUE) {
        const auto error = GetLastError();
        return error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND ? ReadResult::missing : ReadResult::failed;
    }
    BY_HANDLE_FILE_INFORMATION info{}; LARGE_INTEGER size{};
    ReadResult result = ReadResult::failed;
    if (GetFileInformationByHandle(file, &info) && GetFileType(file) == FILE_TYPE_DISK &&
        !(info.dwFileAttributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)) &&
        GetFileSizeEx(file, &size) && size.QuadPart >= 0) {
        if (static_cast<ULONGLONG>(size.QuadPart) > maximum) result = ReadResult::too_large;
        else if (ReadFile(file, data, maximum, &count, nullptr) &&
                 GetFileSizeEx(file, &size) && size.QuadPart == static_cast<LONGLONG>(count)) result = ReadResult::read;
    }
    CloseHandle(file);
    return result;
}
void remove_own_temporary(const wchar_t* path) noexcept {
    if (safe_path(path, false)) DeleteFileW(path);
}

TocNotesResult refresh_raw(const wchar_t* game_root, const wchar_t* language_file) noexcept {
    struct Storage {
        wchar_t toc[path_capacity], runtime[path_capacity], temporary[path_capacity];
        char current[maximum_toc], output[maximum_toc], language[64];
    } storage;
    TemplateInfo info{};
    if (!template_info(info) || !copy_path(storage.toc, game_root) ||
        !append_path(storage.toc, L"benilla-config\\AddOns\\AZSSpeedGear\\AZSSpeedGear.toc") ||
        !safe_path(storage.toc, false)) return TocNotesResult::skipped;
    DWORD current_size = 0;
    if (read_file(storage.toc, storage.current, static_cast<DWORD>(maximum_toc), current_size) != ReadResult::read)
        return TocNotesResult::skipped;
    Range notes{};
    if (!current_notes(storage.current, current_size, info, notes)) return TocNotesResult::skipped;
    unsigned language = 0;
    if (language_file) {
        if (!safe_path(language_file, true)) return TocNotesResult::skipped;
        DWORD size = 0;
        const auto result = read_file(language_file, storage.language, 64, size);
        if (result == ReadResult::failed) return TocNotesResult::skipped;
        if (result == ReadResult::read) language = language_index(storage.language, size);
    }
    const auto desired = info.translations[language];
    if (notes.size == desired.size && equal_bytes(storage.current + notes.begin, original + desired.begin, notes.size))
        return TocNotesResult::unchanged;
    std::size_t output_size = 0;
    if (!compose(storage.current, current_size, notes, desired, storage.output, output_size) ||
        !copy_path(storage.runtime, game_root) || !append_path(storage.runtime, L"benilla-config\\AZSSpeedGear-runtime") ||
        !safe_path(storage.runtime, true)) return TocNotesResult::skipped;
    if (!CreateDirectoryW(storage.runtime, nullptr) && GetLastError() != ERROR_ALREADY_EXISTS)
        return TocNotesResult::skipped;
    if (!safe_path(storage.runtime, false) || !copy_path(storage.temporary, storage.runtime) ||
        !append_path(storage.temporary, L"TocNotes-") || !append_pid(storage.temporary) ||
        !safe_path(storage.temporary, true)) return TocNotesResult::skipped;
    // CREATE_NEW never truncates a pre-existing file or an outside hard-link.
    const auto temporary = CreateFileW(storage.temporary, GENERIC_WRITE, 0, nullptr,
        CREATE_NEW, FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
    if (temporary == INVALID_HANDLE_VALUE) return TocNotesResult::skipped;
    DWORD written = 0;
    BY_HANDLE_FILE_INFORMATION temporary_info{};
    const bool ordinary = GetFileInformationByHandle(temporary, &temporary_info) &&
        GetFileType(temporary) == FILE_TYPE_DISK && temporary_info.nNumberOfLinks == 1 &&
        !(temporary_info.dwFileAttributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT));
    const bool complete = ordinary && WriteFile(temporary, storage.output, static_cast<DWORD>(output_size), &written, nullptr) &&
                           written == output_size && FlushFileBuffers(temporary);
    CloseHandle(temporary);
    if (!complete) { remove_own_temporary(storage.temporary); return TocNotesResult::skipped; }
    // Refuse custom changes made while the new inode was being prepared. Every
    // unchanged byte still has to match the immutable compiled template.
    DWORD latest_size = 0; Range latest_notes{};
    if (!safe_path(storage.toc, false) ||
        read_file(storage.toc, storage.current, static_cast<DWORD>(maximum_toc), latest_size) != ReadResult::read ||
        !current_notes(storage.current, latest_size, info, latest_notes) ||
        !safe_path(storage.temporary, false)) {
        remove_own_temporary(storage.temporary); return TocNotesResult::skipped;
    }
    if (latest_notes.size == desired.size && equal_bytes(storage.current + latest_notes.begin, original + desired.begin, desired.size)) {
        remove_own_temporary(storage.temporary); return TocNotesResult::unchanged;
    }
    if (!MoveFileExW(storage.temporary, storage.toc, MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) {
        remove_own_temporary(storage.temporary); return TocNotesResult::skipped;
    }
    return TocNotesResult::written;
}

bool game_filename(const wchar_t* filename) noexcept {
    constexpr wchar_t expected[] = L"AzerothSurvivors.exe";
    for (std::size_t index = 0; index < sizeof(expected) / sizeof(expected[0]); ++index) {
        auto actual = filename[index], wanted = expected[index];
        if (actual >= 'A' && actual <= 'Z') actual = static_cast<wchar_t>(actual + ('a' - 'A'));
        if (wanted >= 'A' && wanted <= 'Z') wanted = static_cast<wchar_t>(wanted + ('a' - 'A'));
        if (actual != wanted) return false;
        if (!wanted) return true;
    }
    return false;
}
} // namespace

std::optional<std::string> canonical_toc(std::string_view data) noexcept {
    try {
        TemplateInfo info{}; Range notes{};
        if (!template_info(info) || !current_notes(data.data(), data.size(), info, notes)) return std::nullopt;
        char output[maximum_toc]; std::size_t size = 0;
        if (!compose(data.data(), data.size(), notes, info.translations[0], output, size)) return std::nullopt;
        return std::string(output, size);
    } catch (...) { return std::nullopt; }
}

TocNotesResult refresh_toc_notes(const std::filesystem::path& game_root,
                                 const std::filesystem::path& language_file) noexcept {
    return refresh_raw(game_root.c_str(), language_file.c_str());
}

TocNotesResult initialize_toc_notes_before_entry() noexcept {
    wchar_t executable[path_capacity], language[path_capacity];
    const auto length = GetModuleFileNameW(nullptr, executable, static_cast<DWORD>(path_capacity));
    if (!length || length >= path_capacity) return TocNotesResult::skipped;
    std::size_t slash = 0;
    for (std::size_t index = 0; index < length; ++index) if (separator(executable[index])) slash = index;
    if (!slash || !game_filename(executable + slash + 1)) return TocNotesResult::skipped;
    executable[slash == 2 ? 3 : slash] = 0;
    const auto appdata = GetEnvironmentVariableW(L"APPDATA", language, static_cast<DWORD>(path_capacity));
    if (!appdata || appdata >= path_capacity || !append_path(language, L"wenilla-rogue\\language.txt"))
        return refresh_raw(executable, nullptr);
    return refresh_raw(executable, language);
}
} // namespace azsg
