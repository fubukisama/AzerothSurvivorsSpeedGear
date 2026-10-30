#pragma once

#include <windows.h>
#include <filesystem>
#include <string>

namespace azsg {

// Called only from the ordinary backend worker, never DllMain or a timing hook.
// All failures are returned as a short status; no game is started or stopped.
std::string start_native_update(const std::filesystem::path& exe_path) noexcept;

namespace detail {
// Test-only dependency seam. Production always uses the WinAPI implementation
// and the script SHA-256 embedded by CMake; the expected hash is not injectable.
struct NativeUpdateApi {
    void* context = nullptr;
    bool (*read_skip_value)(void*, std::wstring&) noexcept = nullptr;
    bool (*system_directory)(void*, std::wstring&) noexcept = nullptr;
    bool (*create_process)(void*, const wchar_t*, wchar_t*, BOOL, DWORD,
                           const wchar_t*, STARTUPINFOW*, PROCESS_INFORMATION*) noexcept = nullptr;
    bool (*close_handle)(void*, HANDLE) noexcept = nullptr;
};

std::wstring quote_windows_argument(const std::wstring& value);
std::wstring native_update_command_line(const std::filesystem::path& application,
                                        const std::filesystem::path& helper,
                                        const std::filesystem::path& game);
std::string start_native_update_with_api(const std::filesystem::path& exe_path,
                                         const NativeUpdateApi& api) noexcept;
} // namespace detail
} // namespace azsg
