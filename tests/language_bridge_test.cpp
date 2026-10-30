#include "language_bridge.h"

#include <windows.h>
#include <winioctl.h>
#include <array>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <string>
#include <vector>

namespace {
namespace fs = std::filesystem;
unsigned checks = 0;
unsigned failures = 0;

void expect(bool condition, const char* message) {
    ++checks;
    if (!condition) {
        ++failures;
        std::cerr << "FAIL: " << message << '\n';
    }
}

void write(const fs::path& file, const std::string& text) {
    fs::create_directories(file.parent_path());
    std::ofstream stream(file, std::ios::binary | std::ios::trunc);
    stream << text;
    stream.close();
    if (!stream) throw std::runtime_error("fixture write failed");
}

std::string read(const fs::path& file) {
    std::ifstream stream(file, std::ios::binary);
    return std::string(std::istreambuf_iterator<char>(stream), {});
}

std::string expected(const char* language) {
    return std::string("-- AZSSpeedGear runtime locale hint\n") +
           "AZSSpeedGearNativeLocale = \"" + language + "\";\n";
}

struct Fixture {
    fs::path root, game, language, addon, hint, runtime, staging;
    explicit Fixture(const fs::path& base, const char* name, bool with_toc = true)
        : root(base / name), game(root / L"game"), language(root / L"profile" / L"language.txt"),
          addon(game / L"benilla-config" / L"AddOns" / L"AZSSpeedGear"),
          hint(addon / L"NativeLocale.lua"),
          runtime(game / L"benilla-config" / L"AZSSpeedGear-runtime"),
          staging(runtime / L"NativeLocale.tmp") {
        fs::create_directories(game);
        if (with_toc) write(addon / L"AZSSpeedGear.toc", "## Interface: 11200\n");
    }
    azsg::LanguageHintResult refresh() const {
        return azsg::refresh_language_hint(game, language);
    }
};

// A directory junction does not require enabling developer mode or granting the
// symlink privilege. RemoveDirectoryW removes just the junction at cleanup.
bool junction(const fs::path& link, const fs::path& target) {
    fs::create_directories(link);
    const HANDLE handle = CreateFileW(link.c_str(), GENERIC_WRITE,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
        OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
    if (handle == INVALID_HANDLE_VALUE) return false;
    struct MountPoint {
        DWORD tag;
        WORD data_length;
        WORD reserved;
        WORD substitute_offset;
        WORD substitute_length;
        WORD print_offset;
        WORD print_length;
        wchar_t paths[1];
    };
    const auto print = fs::absolute(target).wstring();
    const auto substitute = L"\\??\\" + print;
    const std::size_t path_bytes = (substitute.size() + 1 + print.size() + 1) * sizeof(wchar_t);
    std::vector<unsigned char> data(offsetof(MountPoint, paths) + path_bytes, 0);
    auto* buffer = reinterpret_cast<MountPoint*>(data.data());
    buffer->tag = IO_REPARSE_TAG_MOUNT_POINT;
    buffer->data_length = static_cast<WORD>(8 + path_bytes);
    buffer->substitute_length = static_cast<WORD>(substitute.size() * sizeof(wchar_t));
    buffer->print_offset = static_cast<WORD>((substitute.size() + 1) * sizeof(wchar_t));
    buffer->print_length = static_cast<WORD>(print.size() * sizeof(wchar_t));
    std::memcpy(buffer->paths, substitute.c_str(), (substitute.size() + 1) * sizeof(wchar_t));
    std::memcpy(reinterpret_cast<unsigned char*>(buffer->paths) + buffer->print_offset,
                print.c_str(), (print.size() + 1) * sizeof(wchar_t));
    DWORD returned = 0;
    const bool result = DeviceIoControl(handle, FSCTL_SET_REPARSE_POINT,
        data.data(), static_cast<DWORD>(data.size()), nullptr, 0, &returned, nullptr) != FALSE;
    CloseHandle(handle);
    return result;
}

void parser_tests() {
    constexpr std::array<const char*, 14> codes{
        "en", "pl", "cs", "de", "pt", "es", "fr", "ro", "tr", "ru", "uk", "zh", "ja", "ko"
    };
    for (const auto* code : codes) {
        const auto parsed = azsg::parse_game_language(code);
        expect(parsed && *parsed == code, "every supported language parses");
        const auto padded = azsg::parse_game_language(std::string(" \t\r\n") + code + "\n ");
        expect(padded && *padded == code, "surrounding whitespace is trimmed");
        const auto bom = azsg::parse_game_language(std::string("\xEF\xBB\xBF") + code + "\r\n");
        expect(bom && *bom == code, "UTF-8 BOM is trimmed");
    }
    expect(azsg::parse_game_language(" \xEF\xBB\xBF\tzh \n") == std::optional<std::string>("zh"),
           "BOM after leading whitespace is accepted");
    expect(azsg::parse_game_language("zh" + std::string(62, ' ')).has_value(),
           "64-byte input accepted when trimmed code is valid");
    const std::vector<std::string> invalid{
        "", " ", "ZH", "en_US", "zh-CN", "unknown", "en\nja", "zh;", "\"zh\"",
        "zh\"; os.execute(\"bad\")", "return 'zh'", std::string(65, ' '),
        "zh" + std::string(63, ' '), std::string("zh\0", 3), std::string("\xFF\xFEz\0h\0", 6)
    };
    for (const auto& input : invalid)
        expect(!azsg::parse_game_language(input), "invalid or oversized language rejected");
}

void file_tests(const fs::path& base) {
    Fixture fixture(base, "valid");
    constexpr std::array<const char*, 14> codes{
        "en", "pl", "cs", "de", "pt", "es", "fr", "ro", "tr", "ru", "uk", "zh", "ja", "ko"
    };
    for (const auto* code : codes) {
        write(fixture.language, code);
        expect(fixture.refresh() == azsg::LanguageHintResult::written, "language change writes hint");
        expect(read(fixture.hint) == expected(code), "hint contains only fixed code assignment");
        expect(!fs::exists(fixture.staging), "successful move leaves no staging file");
        const auto old_time = fs::file_time_type::clock::now() - std::chrono::hours(24);
        fs::last_write_time(fixture.hint, old_time);
        expect(fixture.refresh() == azsg::LanguageHintResult::unchanged, "same locale is not rewritten");
        expect(fs::last_write_time(fixture.hint) == old_time, "unchanged hint keeps timestamp");
    }
    expect(azsg::refresh_language_hint(fixture.game / L"", fixture.language) ==
               azsg::LanguageHintResult::unchanged,
           "a trailing game directory separator is accepted");
    write(fixture.language, "zh\"; error('injection')");
    expect(fixture.refresh() == azsg::LanguageHintResult::skipped, "injection input skipped");
    expect(read(fixture.hint) == expected("ko"), "injection cannot overwrite prior hint");
    write(fixture.language, std::string(65, 'x'));
    expect(fixture.refresh() == azsg::LanguageHintResult::skipped, "oversized file skipped");
    expect(read(fixture.hint) == expected("ko"), "oversized file preserves prior hint");
    fs::remove(fixture.language);
    expect(fixture.refresh() == azsg::LanguageHintResult::skipped, "missing file skipped");
    expect(read(fixture.hint) == expected("ko"), "missing file preserves prior hint");

    Fixture no_toc(base, "no-toc", false);
    write(no_toc.language, "zh");
    expect(no_toc.refresh() == azsg::LanguageHintResult::skipped, "missing TOC prevents write");
    expect(!fs::exists(no_toc.addon), "missing TOC does not create addon directory");
    expect(!fs::exists(no_toc.runtime), "missing TOC does not create runtime directory");

    Fixture bad_first(base, "bad-first");
    write(bad_first.language, "invalid");
    expect(bad_first.refresh() == azsg::LanguageHintResult::skipped, "invalid initial file skipped");
    expect(!fs::exists(bad_first.hint) && !fs::exists(bad_first.runtime),
           "invalid initial file creates no output");

    Fixture stale(base, "stale-stage");
    write(stale.language, "pl");
    write(stale.staging, "partial old write");
    expect(stale.refresh() == azsg::LanguageHintResult::written, "regular stale staging recovers");
    expect(read(stale.hint) == expected("pl") && !fs::exists(stale.staging),
           "recovery writes complete fixed hint");
}

void junction_tests(const fs::path& base) {
    Fixture runtime_link(base, "runtime-link");
    write(runtime_link.language, "zh");
    const auto outside = runtime_link.root / L"outside";
    fs::create_directories(outside);
    const bool linked = junction(runtime_link.runtime, outside);
    expect(linked, "runtime directory junction fixture created");
    if (linked) {
        expect(runtime_link.refresh() == azsg::LanguageHintResult::skipped,
               "runtime directory junction refused");
        expect(!fs::exists(outside / L"NativeLocale.tmp") && !fs::exists(runtime_link.hint),
               "runtime link target not written");
        expect(RemoveDirectoryW(runtime_link.runtime.c_str()) != FALSE,
               "runtime junction removed without traversing");
    }

    Fixture addon_link(base, "addon-link", false);
    write(addon_link.language, "ja");
    const auto external_addon = addon_link.root / L"outside-addon";
    write(external_addon / L"AZSSpeedGear.toc", "## Interface: 11200\n");
    fs::create_directories(addon_link.addon.parent_path());
    const bool addon_linked = junction(addon_link.addon, external_addon);
    expect(addon_linked, "addon directory junction fixture created");
    if (addon_linked) {
        expect(addon_link.refresh() == azsg::LanguageHintResult::skipped,
               "addon directory junction refused");
        expect(!fs::exists(external_addon / L"NativeLocale.lua"), "linked addon target not written");
        expect(RemoveDirectoryW(addon_link.addon.c_str()) != FALSE,
               "addon junction removed without traversing");
    }

    Fixture language_link(base, "language-link");
    const auto external_profile = language_link.root / L"outside-profile";
    write(external_profile / L"language.txt", "cs");
    const bool language_linked = junction(language_link.language.parent_path(), external_profile);
    expect(language_linked, "language directory junction fixture created");
    if (language_linked) {
        expect(language_link.refresh() == azsg::LanguageHintResult::skipped,
               "language parent junction refused");
        expect(!fs::exists(language_link.hint), "linked language does not produce hint");
        expect(RemoveDirectoryW(language_link.language.parent_path().c_str()) != FALSE,
               "language junction removed without traversing");
    }
}

} // namespace

int main() {
    const auto parent = fs::current_path();
    const auto base = parent / (L"language-bridge-test-" + std::to_wstring(GetCurrentProcessId()) +
                                L"-" + std::to_wstring(GetTickCount64()));
    try {
        if (fs::exists(base)) throw std::runtime_error("test directory already exists");
        fs::create_directories(base);
        parser_tests();
        file_tests(base);
        junction_tests(base);
        // Every junction is removed explicitly above before this owned tree is
        // removed. Ensure cleanup cannot escape the freshly created test parent.
        if (base.parent_path() != parent || base.filename().wstring().find(L"language-bridge-test-") != 0)
            throw std::runtime_error("invalid cleanup target");
        for (const auto& entry : fs::recursive_directory_iterator(base)) {
            const DWORD attrs = GetFileAttributesW(entry.path().c_str());
            if (attrs != INVALID_FILE_ATTRIBUTES && (attrs & FILE_ATTRIBUTE_REPARSE_POINT))
                throw std::runtime_error("unremoved junction: refusing recursive cleanup");
        }
        fs::remove_all(base);
    } catch (const std::exception& error) {
        ++failures;
        std::cerr << "FAIL: " << error.what() << '\n';
    }
    std::cout << checks << " language bridge assertions, " << failures << " failures\n";
    return failures == 0 ? 0 : 1;
}
