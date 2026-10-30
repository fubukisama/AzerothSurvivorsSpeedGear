// Remote Windows CI only. No game is launched and no real APPDATA is changed.
#include "toc_notes.h"
#include <windows.h>
#include <chrono>
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
std::string read(const fs::path& path) {
    std::ifstream stream(path, std::ios::binary);
    if (!stream) throw std::runtime_error("fixture read failed");
    return std::string(std::istreambuf_iterator<char>(stream), {});
}
void write(const fs::path& path, const std::string& bytes) {
    fs::create_directories(path.parent_path());
    std::ofstream stream(path, std::ios::binary | std::ios::trunc);
    stream.write(bytes.data(), static_cast<std::streamsize>(bytes.size())); stream.close();
    if (!stream) throw std::runtime_error("fixture write failed");
}
std::pair<std::size_t, std::size_t> value_range(const std::string& toc, const std::string& key) {
    const auto at = toc.find(key);
    if (at == std::string::npos || (at && toc[at - 1] != '\n')) throw std::runtime_error("template key missing");
    auto begin = at + key.size();
    while (begin < toc.size() && (toc[begin] == ' ' || toc[begin] == '\t')) ++begin;
    auto end = toc.find('\n', begin); if (end == std::string::npos) end = toc.size();
    if (end > begin && toc[end - 1] == '\r') --end;
    return {begin, end - begin};
}
std::string with_notes(const std::string& toc, const std::string& notes) {
    const auto range = value_range(toc, "## Notes:");
    auto result = toc; result.replace(range.first, range.second, notes); return result;
}
std::string translation(const std::string& toc, const std::string& language) {
    const auto range = value_range(toc, "## X-AZSG-Notes-" + language + ":");
    return toc.substr(range.first, range.second);
}
} // namespace

int wmain(int argc, wchar_t** argv) {
    if (argc != 2) { std::cerr << "Pass the real source TOC from remote CTest.\n"; return 2; }
    wchar_t temporary[2048]{};
    const auto length = GetEnvironmentVariableW(L"RUNNER_TEMP", temporary, 2048);
    if (!length || length >= 2048) { std::cerr << "Remote RUNNER_TEMP is required.\n"; return 2; }
    const auto root = fs::path(temporary) / (L"AZSSpeedGear-toc-notes-" +
        std::to_wstring(GetCurrentProcessId()) + L"-" + std::to_wstring(GetTickCount64()));
    try {
        const auto source = read(fs::path(argv[1]));
        const auto original = azsg::canonical_toc(source);
        check(original && *original == source, "source TOC exactly matches compiled English template");
        const auto game = root / L"game";
        const auto toc = game / L"benilla-config" / L"AddOns" / L"AZSSpeedGear" / L"AZSSpeedGear.toc";
        const auto language = root / L"profile" / L"language.txt";
        write(toc, source);
        const std::vector<std::string> languages{
            "en", "zh", "ja", "pl", "cs", "de", "pt", "es", "fr", "ro", "tr", "ru", "uk", "ko"
        };
        for (const auto& code : languages) {
            write(language, code);
            const auto result = azsg::refresh_toc_notes(game, language);
            check(result == azsg::TocNotesResult::written || result == azsg::TocNotesResult::unchanged,
                  "supported game setting synchronizes Notes");
            const auto expected = with_notes(source, translation(source, code));
            const auto actual = read(toc);
            check(actual == expected, "only ordinary Notes value changes; all other bytes stay exact");
            const auto canonical = azsg::canonical_toc(actual);
            check(canonical && *canonical == source, "every language canonicalizes to the same English bytes");
            const auto old_time = fs::file_time_type::clock::now() - std::chrono::hours(24);
            fs::last_write_time(toc, old_time);
            check(azsg::refresh_toc_notes(game, language) == azsg::TocNotesResult::unchanged,
                  "same language does not rewrite TOC");
            check(fs::last_write_time(toc) == old_time, "unchanged TOC preserves mtime");
        }
        for (const auto& invalid : {std::string("unknown"), std::string("zh;bad"), std::string(65, 'x')}) {
            write(toc, with_notes(source, translation(source, "zh")));
            write(language, invalid);
            check(azsg::refresh_toc_notes(game, language) == azsg::TocNotesResult::written,
                  "unknown or oversized language falls back to English");
            check(read(toc) == source, "fallback retains exact original template");
        }
        write(language, " \xEF\xBB\xBF\tja\r\n");
        check(azsg::refresh_toc_notes(game, language) == azsg::TocNotesResult::written &&
              read(toc) == with_notes(source, translation(source, "ja")), "bounded language read accepts BOM and whitespace");
        write(toc, with_notes(source, "user custom Notes"));
        write(language, "zh");
        check(azsg::refresh_toc_notes(game, language) == azsg::TocNotesResult::skipped,
              "unrecognized custom Notes are never overwritten");
        check(read(toc) == with_notes(source, "user custom Notes"), "custom Notes remain untouched");
        check(!azsg::canonical_toc(read(toc)), "canonicalizer rejects malicious/custom Notes");
        const auto malicious = with_notes(source, translation(source, "zh") + "\ninjected.lua");
        write(toc, malicious);
        check(azsg::refresh_toc_notes(game, language) == azsg::TocNotesResult::skipped && read(toc) == malicious,
              "Notes newline injection is refused without modifying the file");
        const auto base_notes = value_range(source, "## Notes:");
        bool all_other_bytes_rejected = true;
        for (std::size_t index = 0; index < source.size(); ++index) {
            if (index >= base_notes.first && index < base_notes.first + base_notes.second) continue;
            auto mutation = source;
            mutation[index] = static_cast<char>(static_cast<unsigned char>(mutation[index]) ^ 1u);
            if (azsg::canonical_toc(mutation)) { all_other_bytes_rejected = false; break; }
        }
        check(all_other_bytes_rejected, "a mutation at every non-Notes byte is rejected");
        auto changed = source;
        changed.replace(changed.find("## Title:"), 2, "#!");
        write(toc, changed);
        check(azsg::refresh_toc_notes(game, language) == azsg::TocNotesResult::skipped && read(toc) == changed,
              "non-Notes template modification is refused");
        check(!azsg::canonical_toc(source + "extra.lua\n"), "extra Lua file cannot pass canonical identity");
        check(!azsg::canonical_toc(std::string(16 * 1024 + 1, 'x')), "oversized TOC refused");

        write(toc, source);
        const auto outside = root / L"outside-hardlink.toc";
        check(CreateHardLinkW(outside.c_str(), toc.c_str(), nullptr) != FALSE, "hardlink fixture created");
        check(azsg::refresh_toc_notes(game, language) == azsg::TocNotesResult::written,
              "atomic replacement localizes owned TOC");
        check(read(outside) == source, "other hardlink name is not modified or truncated");
        const auto expected_zh = with_notes(source, translation(source, "zh"));
        check(read(toc) == expected_zh, "replaced target has selected Notes");
        const auto no_toc_game = root / L"no-toc";
        fs::create_directories(no_toc_game);
        check(azsg::refresh_toc_notes(no_toc_game, language) == azsg::TocNotesResult::skipped,
              "absent addon is not created");
        check(azsg::initialize_toc_notes_before_entry() == azsg::TocNotesResult::skipped,
              "non-game test process does not inspect or modify real APPDATA");
        // Fixture files remain under remote runner temp; no recursive traversal
        // or cleanup through a user-supplied path is performed.
    } catch (const std::exception& error) {
        ++failures; std::cerr << "FAIL: " << error.what() << '\n';
    }
    std::cout << "toc_notes checks=" << checks << " failures=" << failures << '\n';
    return failures ? 1 : 0;
}
