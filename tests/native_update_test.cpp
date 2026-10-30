// Remote Windows CI only. Spawn is injected: no PowerShell child, game or
// updater is executed. Real filesystem/CNG hashing operates on temporary files.
#include "native_update.h"

#include <shellapi.h>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

namespace {
namespace fs = std::filesystem;
unsigned checks = 0, failures = 0;
void check(bool value, const char* description) {
    ++checks;
    if (!value) { ++failures; std::cerr << "FAIL: " << description << '\n'; }
}
void write(const fs::path& path, const std::string& text) {
    fs::create_directories(path.parent_path());
    std::ofstream output(path, std::ios::binary | std::ios::trunc);
    output.write(text.data(), static_cast<std::streamsize>(text.size()));
    output.close();
    if (!output) throw std::runtime_error("fixture write failed");
}
struct Context {
    std::wstring skip, system;
    bool environment_ok = true, system_ok = true, create_ok = true, close_ok = true;
    unsigned environment_calls = 0, system_calls = 0, spawn_calls = 0, close_calls = 0;
    std::wstring application, command, directory;
    BOOL inherited = TRUE;
    DWORD flags = 0, startup_flags = 0;
    WORD show = SW_SHOW;
    bool mutable_buffer = false;
    std::vector<HANDLE> closed;
};
bool read_skip(void* pointer, std::wstring& value) noexcept {
    auto& state = *static_cast<Context*>(pointer);
    ++state.environment_calls;
    try { value = state.skip; return state.environment_ok; } catch (...) { return false; }
}
bool system_directory(void* pointer, std::wstring& value) noexcept {
    auto& state = *static_cast<Context*>(pointer);
    ++state.system_calls;
    try { value = state.system; return state.system_ok; } catch (...) { return false; }
}
bool create_process(void* pointer, const wchar_t* application, wchar_t* command,
                     BOOL inherit, DWORD flags, const wchar_t* directory,
                     STARTUPINFOW* startup, PROCESS_INFORMATION* process) noexcept {
    auto& state = *static_cast<Context*>(pointer);
    ++state.spawn_calls;
    try {
        state.application = application;
        state.command = command;
        state.directory = directory;
        state.inherited = inherit; state.flags = flags;
        state.startup_flags = startup->dwFlags; state.show = startup->wShowWindow;
        volatile wchar_t* writable = command;
        const auto original = writable[0]; writable[0] = L'X'; writable[0] = original;
        state.mutable_buffer = true;
        process->hProcess = reinterpret_cast<HANDLE>(static_cast<UINT_PTR>(101));
        process->hThread = reinterpret_cast<HANDLE>(static_cast<UINT_PTR>(102));
        return state.create_ok;
    } catch (...) { return false; }
}
bool close_handle(void* pointer, HANDLE handle) noexcept {
    auto& state = *static_cast<Context*>(pointer);
    ++state.close_calls;
    try { state.closed.push_back(handle); return state.close_ok; } catch (...) { return false; }
}
azsg::detail::NativeUpdateApi api(Context& state) {
    return {&state, read_skip, system_directory, create_process, close_handle};
}
std::vector<std::wstring> split(const std::wstring& command) {
    int count = 0;
    const auto values = CommandLineToArgvW(command.c_str(), &count);
    if (!values) throw std::runtime_error("command-line split failed");
    std::vector<std::wstring> result;
    for (int index = 0; index < count; ++index) result.emplace_back(values[index]);
    LocalFree(values);
    return result;
}
void quoting_tests() {
    const std::vector<std::wstring> values{
        L"", L"plain", L"with spaces", L"C:\\trailing\\", L"double\"quote",
        L"slash\\\"quote\\", L"& $() ' ; | ^ % !", L"\u65e5\u672c\u8a9e \\ \u00e4",
    };
    for (const auto& value : values) {
        const auto parsed = split(L"\"program.exe\" " + azsg::detail::quote_windows_argument(value));
        check(parsed.size() == 2 && parsed[1] == value, "Windows argument quoting round-trips exactly");
    }
    const auto command = azsg::detail::native_update_command_line(
        L"C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe",
        L"E:\\Game & data\\O'Brien\\NativeUpdate.ps1",
        L"E:\\Game $() ; data\\AzerothSurvivors.exe");
    const auto parsed = split(command);
    check(parsed.size() == 12 && parsed[8] == L"-File" &&
          parsed[9] == L"E:\\Game & data\\O'Brien\\NativeUpdate.ps1" &&
          parsed[10] == L"-GamePath" && parsed[11] == L"E:\\Game $() ; data\\AzerothSurvivors.exe",
          "File-mode command never treats path metacharacters as PowerShell code");
}
} // namespace

int wmain(int argc, wchar_t** argv) {
    if (argc != 2) { std::cerr << "Pass the source NativeUpdate.ps1 path from remote CTest.\n"; return 2; }
    wchar_t temporary[32768]{};
    const auto length = GetEnvironmentVariableW(L"RUNNER_TEMP", temporary, 32768);
    if (!length || length >= 32768) {
        std::cerr << "Remote CI RUNNER_TEMP is required; do not run on the user's PC.\n"; return 2;
    }
    const auto root = fs::path(temporary) / (L"AZSSpeedGear-native-update-" +
        std::to_wstring(GetCurrentProcessId()) + L"-" + std::to_wstring(GetTickCount64()));
    try {
        const auto game = root / L"Game & data" / L"AzerothSurvivors.exe";
        write(game, "synthetic-game-not-an-executable");
        const auto helper = game.parent_path() / L"benilla-config" / L"AddOns" /
                            L"AZSSpeedGear" / L"Updater" / L"NativeUpdate.ps1";
        Context state;
        state.system = (root / L"System32").wstring();
        const auto powershell = fs::path(state.system) / L"WindowsPowerShell" / L"v1.0" / L"powershell.exe";
        write(powershell, "synthetic-not-an-executable");
        auto platform = api(state);

        check(azsg::detail::start_native_update_with_api(root / L"AZSSpeedGearTestHost.exe", platform) == "skipped:not-game",
              "synthetic backend host never starts automatic updater");
        check(azsg::detail::start_native_update_with_api(L"AzerothSurvivors.exe", platform) == "skipped:not-game",
              "relative paths cannot trigger process launch");
        check(state.environment_calls == 0 && state.spawn_calls == 0, "non-game guard runs before environment or spawning");
        state.skip = L"1";
        check(azsg::detail::start_native_update_with_api(game, platform) == "skipped:environment",
              "exact skip value disables native update");
        check(state.spawn_calls == 0 && state.system_calls == 0, "skip does not inspect or spawn PowerShell");
        state.skip.clear();
        state.environment_ok = false;
        check(azsg::detail::start_native_update_with_api(game, platform) == "unavailable:environment",
              "environment API failure is nonfatal and does not launch");
        state.environment_ok = true;
        check(azsg::detail::start_native_update_with_api(game, platform) == "unavailable:helper",
              "missing helper is nonfatal and does not launch");
        write(helper, "tampered script");
        check(azsg::detail::start_native_update_with_api(game, platform) == "unavailable:helper-hash",
              "tampered helper cannot execute");
        write(helper, std::string(1024 * 1024 + 1, 'x'));
        check(azsg::detail::start_native_update_with_api(game, platform) == "unavailable:helper-size",
              "helper larger than one MiB cannot execute");
        check(state.spawn_calls == 0, "all missing/tampered/oversized cases leave spawning untouched");
        fs::remove(helper);
        fs::create_directory(helper);
        check(azsg::detail::start_native_update_with_api(game, platform) == "unavailable:helper",
              "a directory cannot masquerade as the ordinary helper file");
        fs::remove(helper);

        fs::copy_file(fs::path(argv[1]), helper, fs::copy_options::overwrite_existing);
        state.system_ok = false;
        check(azsg::detail::start_native_update_with_api(game, platform) == "unavailable:system-directory",
              "system-directory API failure is nonfatal");
        state.system_ok = true;
        fs::remove(powershell);
        check(azsg::detail::start_native_update_with_api(game, platform) == "unavailable:powershell",
              "missing system PowerShell is nonfatal and does not launch");
        write(powershell, "synthetic-not-an-executable");
        state.skip = L"01"; // Only the exact value "1" disables the feature.
        check(azsg::detail::start_native_update_with_api(game, platform) == "started",
              "compile-time hash-matching helper launches through injected spawn only");
        check(state.spawn_calls == 1, "matching helper produces one spawn call");
        check(state.application == powershell.wstring(), "explicit executable comes only from system-directory callback");
        check(state.directory == helper.parent_path().wstring(), "child directory is the verified helper directory");
        check(state.inherited == FALSE, "child inherits no native/game pipe handles");
        check(state.flags == CREATE_NO_WINDOW && (state.startup_flags & STARTF_USESHOWWINDOW) && state.show == SW_HIDE,
              "process is hidden by creation flags and startup info");
        check(state.mutable_buffer, "CreateProcess command line is writable");
        check(state.close_calls == 2 && state.closed.size() == 2, "thread and process handles close without waiting");
        const auto parsed = split(state.command);
        check(parsed.size() == 12 && parsed[0] == powershell.wstring() &&
              parsed[1] == L"-NoLogo" && parsed[2] == L"-NoProfile" &&
              parsed[3] == L"-ExecutionPolicy" && parsed[4] == L"Bypass" &&
              parsed[5] == L"-NonInteractive" && parsed[6] == L"-WindowStyle" && parsed[7] == L"Hidden" &&
              parsed[8] == L"-File" && parsed[9] == helper.wstring() &&
              parsed[10] == L"-GamePath" && parsed[11] == game.wstring(),
              "spawn passes exact absolute helper and game paths as separate arguments");
        state.create_ok = false;
        check(azsg::detail::start_native_update_with_api(game, platform) == "unavailable:spawn",
              "process creation failure leaves the game unaffected");
        check(state.close_calls == 4, "any returned handles are closed on create failure too");
        state.create_ok = true; state.close_ok = false;
        check(azsg::detail::start_native_update_with_api(game, platform) == "started",
              "handle-close failure does not throw into the game");
        quoting_tests();
        // No cleanup follows links or executes any fixture. Remote runner temp
        // owns the small fixture tree and removes it when its job ends.
    } catch (const std::exception& error) {
        ++failures; std::cerr << "FAIL: " << error.what() << '\n';
    }
    std::cout << "native_update checks=" << checks << " failures=" << failures << '\n';
    return failures ? 1 : 0;
}
