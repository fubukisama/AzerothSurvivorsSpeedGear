#include "native_update.h"
#include "native_update_identity.h"

#include <bcrypt.h>
#include <array>
#include <cstdint>
#include <cwchar>
#include <string_view>
#include <utility>
#include <vector>

namespace azsg {
namespace {
constexpr std::uint64_t maximum_helper_bytes = 1024 * 1024;
constexpr std::string_view expected_hash = AZSG_NATIVE_UPDATE_SCRIPT_SHA256;
static_assert(expected_hash.size() == 64, "Configure the native updater script SHA-256 first.");

class FileHandle {
public:
    explicit FileHandle(HANDLE value) noexcept : value_(value) {}
    ~FileHandle() { if (value_ != INVALID_HANDLE_VALUE) CloseHandle(value_); }
    FileHandle(const FileHandle&) = delete;
    FileHandle& operator=(const FileHandle&) = delete;
    HANDLE get() const noexcept { return value_; }
    bool valid() const noexcept { return value_ != INVALID_HANDLE_VALUE; }
private:
    HANDLE value_;
};

struct HashHandles {
    BCRYPT_ALG_HANDLE algorithm = nullptr;
    BCRYPT_HASH_HANDLE hash = nullptr;
    // CNG uses this storage until BCryptDestroyHash has completed. Keep it as a
    // member so it outlives the destructor body that destroys the hash handle.
    std::vector<unsigned char> object;
    ~HashHandles() {
        if (hash) BCryptDestroyHash(hash);
        if (algorithm) BCryptCloseAlgorithmProvider(algorithm, 0);
    }
};

bool safe_existing_path(const std::filesystem::path& path) {
    if (!path.is_absolute() || path.root_path().empty()) return false;
    auto current = path.root_path();
    const auto root_attributes = GetFileAttributesW(current.c_str());
    if (root_attributes == INVALID_FILE_ATTRIBUTES ||
        !(root_attributes & FILE_ATTRIBUTE_DIRECTORY) ||
        (root_attributes & FILE_ATTRIBUTE_REPARSE_POINT)) return false;
    for (const auto& part : path.relative_path()) {
        if (part.empty()) continue;
        if (part == L"." || part == L"..") return false;
        current /= part;
        const auto attributes = GetFileAttributesW(current.c_str());
        if (attributes == INVALID_FILE_ATTRIBUTES ||
            (attributes & FILE_ATTRIBUTE_REPARSE_POINT)) return false;
    }
    return true;
}

bool regular_existing_file(const std::filesystem::path& path) {
    if (!safe_existing_path(path)) return false;
    const auto attributes = GetFileAttributesW(path.c_str());
    return attributes != INVALID_FILE_ATTRIBUTES &&
           !(attributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT));
}

int hex_digit(char value) noexcept {
    if (value >= '0' && value <= '9') return value - '0';
    if (value >= 'a' && value <= 'f') return value - 'a' + 10;
    if (value >= 'A' && value <= 'F') return value - 'A' + 10;
    return -1;
}

enum class HelperHash { matched, mismatch, too_large, unavailable };
HelperHash verify_helper(HANDLE file) {
    BY_HANDLE_FILE_INFORMATION information{};
    LARGE_INTEGER size{};
    if (!GetFileInformationByHandle(file, &information) ||
        (information.dwFileAttributes &
         (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)) ||
        GetFileType(file) != FILE_TYPE_DISK || !GetFileSizeEx(file, &size) || size.QuadPart < 0)
        return HelperHash::unavailable;
    if (static_cast<std::uint64_t>(size.QuadPart) > maximum_helper_bytes)
        return HelperHash::too_large;

    HashHandles handles;
    if (BCryptOpenAlgorithmProvider(&handles.algorithm, BCRYPT_SHA256_ALGORITHM,
                                    nullptr, 0) < 0) return HelperHash::unavailable;
    DWORD object_size = 0, obtained = 0;
    if (BCryptGetProperty(handles.algorithm, BCRYPT_OBJECT_LENGTH,
                          reinterpret_cast<PUCHAR>(&object_size), sizeof(object_size),
                          &obtained, 0) < 0 || obtained != sizeof(object_size) ||
        object_size == 0 || object_size > maximum_helper_bytes) return HelperHash::unavailable;
    handles.object.resize(object_size);
    if (BCryptCreateHash(handles.algorithm, &handles.hash, handles.object.data(), object_size,
                         nullptr, 0, 0) < 0) return HelperHash::unavailable;
    std::array<unsigned char, 65536> buffer{};
    std::uint64_t total = 0;
    while (true) {
        DWORD count = 0;
        if (!ReadFile(file, buffer.data(), static_cast<DWORD>(buffer.size()), &count, nullptr))
            return HelperHash::unavailable;
        if (!count) break;
        total += count;
        if (total > maximum_helper_bytes || total > static_cast<std::uint64_t>(size.QuadPart))
            return HelperHash::too_large;
        if (BCryptHashData(handles.hash, buffer.data(), count, 0) < 0)
            return HelperHash::unavailable;
    }
    if (total != static_cast<std::uint64_t>(size.QuadPart)) return HelperHash::unavailable;
    std::array<unsigned char, 32> digest{};
    if (BCryptFinishHash(handles.hash, digest.data(), static_cast<ULONG>(digest.size()), 0) < 0)
        return HelperHash::unavailable;
    for (std::size_t index = 0; index < digest.size(); ++index) {
        const auto high = hex_digit(expected_hash[index * 2]);
        const auto low = hex_digit(expected_hash[index * 2 + 1]);
        if (high < 0 || low < 0) return HelperHash::unavailable;
        if (digest[index] != static_cast<unsigned char>((high << 4) | low))
            return HelperHash::mismatch;
    }
    return HelperHash::matched;
}

bool read_skip(void*, std::wstring& value) noexcept {
    try {
        value.clear();
        SetLastError(ERROR_SUCCESS);
        const auto needed = GetEnvironmentVariableW(L"AZSSPEEDGEAR_SKIP_UPDATE", nullptr, 0);
        if (!needed) return GetLastError() == ERROR_ENVVAR_NOT_FOUND || GetLastError() == ERROR_SUCCESS;
        if (needed > 32768) return false;
        std::wstring buffer(needed, L'\0');
        SetLastError(ERROR_SUCCESS);
        const auto length = GetEnvironmentVariableW(L"AZSSPEEDGEAR_SKIP_UPDATE", buffer.data(), needed);
        if (!length) return GetLastError() == ERROR_ENVVAR_NOT_FOUND || GetLastError() == ERROR_SUCCESS;
        if (length >= needed) return false;
        buffer.resize(length);
        value = std::move(buffer);
        return true;
    } catch (...) { return false; }
}

bool system_directory(void*, std::wstring& value) noexcept {
    try {
        std::array<wchar_t, 32768> buffer{};
        const auto length = GetSystemDirectoryW(buffer.data(), static_cast<UINT>(buffer.size()));
        if (!length || length >= buffer.size()) return false;
        value.assign(buffer.data(), length);
        return true;
    } catch (...) { return false; }
}

bool create_process(void*, const wchar_t* application, wchar_t* command,
                     BOOL inherit, DWORD flags, const wchar_t* directory,
                     STARTUPINFOW* startup, PROCESS_INFORMATION* process) noexcept {
    return CreateProcessW(application, command, nullptr, nullptr, inherit, flags,
                          nullptr, directory, startup, process) != FALSE;
}
bool close_handle(void*, HANDLE handle) noexcept { return CloseHandle(handle) != FALSE; }

} // namespace

std::wstring detail::quote_windows_argument(const std::wstring& value) {
    std::wstring result(1, L'"');
    std::size_t slashes = 0;
    for (const auto ch : value) {
        if (ch == L'\\') { ++slashes; continue; }
        if (ch == L'"') {
            result.append(slashes * 2 + 1, L'\\');
            result += L'"';
        } else {
            result.append(slashes, L'\\');
            result += ch;
        }
        slashes = 0;
    }
    result.append(slashes * 2, L'\\');
    result += L'"';
    return result;
}

std::wstring detail::native_update_command_line(const std::filesystem::path& application,
                                                const std::filesystem::path& helper,
                                                const std::filesystem::path& game) {
    return quote_windows_argument(application.wstring()) +
           L" -NoLogo -NoProfile -ExecutionPolicy Bypass -NonInteractive -WindowStyle Hidden -File " +
           quote_windows_argument(helper.wstring()) + L" -GamePath " +
           quote_windows_argument(game.wstring());
}

std::string detail::start_native_update_with_api(const std::filesystem::path& exe_path,
                                                 const NativeUpdateApi& api) noexcept {
    try {
        if (!exe_path.is_absolute() ||
            _wcsicmp(exe_path.filename().c_str(), L"AzerothSurvivors.exe") != 0)
            return "skipped:not-game";
        if (!api.read_skip_value || !api.system_directory || !api.create_process || !api.close_handle)
            return "unavailable:api";
        std::wstring skip;
        if (!api.read_skip_value(api.context, skip)) return "unavailable:environment";
        if (skip == L"1") return "skipped:environment";
        if (!regular_existing_file(exe_path)) return "unavailable:game-path";
        const auto helper = exe_path.parent_path() / L"benilla-config" / L"AddOns" /
                            L"AZSSpeedGear" / L"Updater" / L"NativeUpdate.ps1";
        if (!regular_existing_file(helper)) return "unavailable:helper";
        // Deny writes and renames while hashing and creating the child. The
        // updater itself only replaces installed files after all games exit.
        FileHandle script(CreateFileW(helper.c_str(), GENERIC_READ, FILE_SHARE_READ,
            nullptr, OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_SEQUENTIAL_SCAN, nullptr));
        if (!script.valid()) return "unavailable:helper-read";
        switch (verify_helper(script.get())) {
            case HelperHash::matched: break;
            case HelperHash::mismatch: return "unavailable:helper-hash";
            case HelperHash::too_large: return "unavailable:helper-size";
            default: return "unavailable:helper-read";
        }

        std::wstring system;
        if (!api.system_directory(api.context, system)) return "unavailable:system-directory";
        const std::filesystem::path system_path(system);
        if (!system_path.is_absolute()) return "unavailable:system-directory";
        const auto application = system_path / L"WindowsPowerShell" / L"v1.0" / L"powershell.exe";
        if (!regular_existing_file(application)) return "unavailable:powershell";
        const auto command_line = native_update_command_line(application, helper, exe_path);
        if (command_line.size() >= 32767) return "unavailable:command-line";
        std::vector<wchar_t> command(command_line.begin(), command_line.end());
        command.push_back(L'\0'); // CreateProcessW may mutate the buffer.
        STARTUPINFOW startup{};
        startup.cb = sizeof(startup);
        startup.dwFlags = STARTF_USESHOWWINDOW;
        startup.wShowWindow = SW_HIDE;
        PROCESS_INFORMATION process{};
        const auto directory = helper.parent_path().wstring();
        const bool created = api.create_process(api.context, application.c_str(), command.data(),
            FALSE, CREATE_NO_WINDOW, directory.c_str(), &startup, &process);
        // No waits, polling, shell, PATH lookup or inherited handles. Child
        // failures are independent of the running game's startup and clocks.
        if (process.hThread && process.hThread != INVALID_HANDLE_VALUE)
            api.close_handle(api.context, process.hThread);
        if (process.hProcess && process.hProcess != INVALID_HANDLE_VALUE)
            api.close_handle(api.context, process.hProcess);
        return created ? "started" : "unavailable:spawn";
    } catch (...) { return {}; } // Default string construction is nonthrowing.
}

std::string start_native_update(const std::filesystem::path& exe_path) noexcept {
    const detail::NativeUpdateApi api{nullptr, read_skip, system_directory, create_process, close_handle};
    return detail::start_native_update_with_api(exe_path, api);
}

} // namespace azsg
