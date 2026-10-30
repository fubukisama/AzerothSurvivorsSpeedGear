// Remote Windows CI diagnostic only. Link the real dwmapi.dll and the existing
// simulation_fixture.asm, name this EXE AZSSpeedGearTestHost.exe, and run from a
// fresh isolated folder. No actual game, APPDATA, UI or network is used.
//
// A: fixed 25ms advancement per simulation step.
// B: independently measured QPC elapsed time per simulation step.
// C: HYPOTHETICAL reuse of a rendered frame's QPC delta on every simulation step.
// A and B must scale once. C illustrates a possible mixed-clock game design;
// its result is reported, NEVER treated as evidence of the real game's design.
#include <windows.h>
#include <atomic>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <string>
#include <thread>

extern "C" void SimulationStep();
extern "C" __declspec(noinline) void FakeRustSleep(std::uint64_t seconds, std::uint32_t nanos) {
    const auto timer = CreateWaitableTimerExW(nullptr, nullptr, 2, TIMER_ALL_ACCESS);
    if (!timer) { Sleep((nanos + 999999) / 1000000); return; }
    LARGE_INTEGER due{};
    due.QuadPart = -static_cast<LONGLONG>(seconds * 10000000 + nanos / 100);
    if (!SetWaitableTimer(timer, &due, 0, nullptr, nullptr, FALSE)) { CloseHandle(timer); return; }
    WaitForSingleObject(timer, INFINITE);
    CloseHandle(timer);
}

namespace {
namespace fs = std::filesystem;
std::uint64_t wall() {
    FILETIME value{}; GetSystemTimePreciseAsFileTime(&value);
    return (std::uint64_t(value.dwHighDateTime) << 32) | value.dwLowDateTime;
}
std::uint64_t qpc() {
    LARGE_INTEGER value{}; QueryPerformanceCounter(&value);
    return static_cast<std::uint64_t>(value.QuadPart);
}
std::string read(const fs::path& path) {
    std::ifstream stream(path, std::ios::binary);
    return std::string(std::istreambuf_iterator<char>(stream), {});
}
struct Counters {
    std::atomic<std::uint64_t> steps{0}, elapsed_ticks{0}, cached_frame_ticks{0}, frame_delta{0}, backwards{0};
    std::atomic<std::uint64_t> maximum_step_ticks{0}, hypothetical_large_elapsed_steps{0};
};
struct Row {
    double seconds = 0, steps_per_second = 0, fixed_rate = 0;
    double elapsed_rate = 0, direct_qpc_rate = 0, hypothetical_cached_rate = 0;
};
Row observe(Counters& counters, double frequency, unsigned milliseconds) {
    const auto start_steps = counters.steps.load();
    const auto start_elapsed = counters.elapsed_ticks.load();
    const auto start_cached = counters.cached_frame_ticks.load();
    const auto start_wall = wall(), start_qpc = qpc();
    Sleep(milliseconds); // Kernel Sleep is not the intercepted Rust sleep.
    const auto end_qpc = qpc(), end_wall = wall();
    Row row;
    row.seconds = double(end_wall - start_wall) / 10000000.0;
    row.steps_per_second = double(counters.steps.load() - start_steps) / row.seconds;
    row.fixed_rate = row.steps_per_second * 0.025;
    row.elapsed_rate = double(counters.elapsed_ticks.load() - start_elapsed) / frequency / row.seconds;
    row.direct_qpc_rate = double(end_qpc - start_qpc) / frequency / row.seconds;
    row.hypothetical_cached_rate = double(counters.cached_frame_ticks.load() - start_cached) / frequency / row.seconds;
    return row;
}
bool withinTolerance(double actual, double target, double tolerance) {
    return actual >= target * (1.0 - tolerance) && actual <= target * (1.0 + tolerance);
}
} // namespace

int wmain() {
    wchar_t actions[8]{};
    const auto actions_length = GetEnvironmentVariableW(L"GITHUB_ACTIONS", actions, 8);
    if (actions_length != 4 || actions[0] != L't' || actions[1] != L'r' ||
        actions[2] != L'u' || actions[3] != L'e' || actions[4] != 0) {
        std::cerr << "This diagnostic is restricted to remote GitHub Actions.\n"; return 2;
    }
    wchar_t temporary[32768]{};
    const auto temporary_length = GetEnvironmentVariableW(L"RUNNER_TEMP", temporary, 32768);
    if (!temporary_length || temporary_length >= 32768) {
        std::cerr << "Only run this model in remote Windows CI.\n"; return 2;
    }
    wchar_t executable[32768]{};
    GetModuleFileNameW(nullptr, executable, 32768);
    const fs::path exe(executable);
    const auto root = exe.parent_path();
    const auto config = root / L"benilla-config" / L"config.toml";
    if (_wcsicmp(exe.filename().c_str(), L"AZSSpeedGearTestHost.exe") != 0 ||
        fs::exists(root / L"AzerothSurvivors.exe") || fs::exists(config)) {
        std::cerr << "Use the test-host name and a fresh isolated directory.\n"; return 2;
    }
    fs::create_directories(config.parent_path());
    { std::ofstream output(config); output << "[cvars]\n"; }
    if (!LoadLibraryW((root / L"dwmapi.dll").c_str())) {
        std::cerr << "Cannot load diagnostic DLL.\n"; return 2;
    }
    const auto deadline = wall() + 100000000;
    bool ready = false;
    while (wall() < deadline) {
        const auto log = read(root / L"AZSSpeedGear.log");
        if (log.find("ready: waiting") != std::string::npos) { ready = true; break; }
        if (log.find("disabled:") != std::string::npos) break;
        Sleep(10);
    }
    if (!ready) { std::cerr << "Backend not ready:\n" << read(root / L"AZSSpeedGear.log"); return 2; }
    LARGE_INTEGER frequency{}; QueryPerformanceFrequency(&frequency);
    Counters counters;
    std::atomic<bool> running{true};
    std::thread render([&] {
        auto previous = qpc();
        while (running.load()) {
            // Represents real display cadence. This choice is an explicit MODEL
            // assumption, not recovered evidence about Azeroth Survivors.
            Sleep(16);
            const auto now = qpc();
            if (now < previous) ++counters.backwards;
            counters.frame_delta.store(now >= previous ? now - previous : 0);
            previous = now;
        }
    });
    std::thread simulation([&] {
        auto previous = qpc();
        std::uint64_t elapsed = 0, cached = 0;
        while (running.load()) {
            SimulationStep();
            const auto now = qpc();
            if (now < previous) ++counters.backwards;
            const auto delta = now >= previous ? now - previous : 0;
            elapsed += delta;
            if (delta > counters.maximum_step_ticks.load()) counters.maximum_step_ticks.store(delta);
            // An old in-flight long sleep can straddle a new faster QPC slope.
            // Record the resulting per-step delta rather than conflating this
            // with a backward/jumping QPC or a confirmed game physics defect.
            if (double(delta) / double(frequency.QuadPart) > 0.100)
                ++counters.hypothetical_large_elapsed_steps;
            cached += counters.frame_delta.load();
            previous = now;
            counters.elapsed_ticks.store(elapsed);
            counters.cached_frame_ticks.store(cached);
            ++counters.steps;
        }
    });
    unsigned sequence = 0;
    auto command = [&](unsigned speed) {
        const auto staging = config.parent_path() / L"consistency-command.tmp";
        {
            std::ofstream output(staging, std::ios::binary | std::ios::trunc);
            output << "[cvars]\nazsspeedgearcommand = \"SG1|7654321|" << ++sequence << '|'
                   << wall() / 10000000 - 11644473600ull << '|' << speed << "|1\"\n";
        }
        return MoveFileExW(staging.c_str(), config.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH) != FALSE;
    };
    std::cout << std::fixed << std::setprecision(4);
    unsigned failures = 0;
    Row baseline;
    for (const auto speed : {100u, 200u, 500u, 50u, 300u, 100u}) {
        if (!command(speed)) { ++failures; break; }
        Sleep(450); // Exclude file transport and one in-flight old sleep.
        const auto row = observe(counters, double(frequency.QuadPart), 1600);
        if (speed == 100u && baseline.seconds == 0) baseline = row;
        const auto target = speed / 100.0;
        const auto fixed_ratio = row.fixed_rate / baseline.fixed_rate;
        const auto elapsed_ratio = row.elapsed_rate / baseline.elapsed_rate;
        const auto cached_ratio = row.hypothetical_cached_rate / baseline.hypothetical_cached_rate;
        const bool fixed_ok = withinTolerance(fixed_ratio, target, 0.25);
        const bool elapsed_ok = withinTolerance(row.elapsed_rate, target, 0.25);
        const bool qpc_ok = withinTolerance(row.direct_qpc_rate, target, 0.10);
        if (!fixed_ok || !elapsed_ok || !qpc_ok) ++failures;
        std::cout << "target=" << target << " steps_per_second=" << row.steps_per_second
                  << " fixed_step_ratio=" << fixed_ratio << " independent_elapsed_ratio=" << elapsed_ratio
                  << " independent_elapsed_absolute=" << row.elapsed_rate << " direct_qpc_rate=" << row.direct_qpc_rate
                  << " HYPOTHETICAL_cached_frame_ratio=" << cached_ratio
                  << " positive_models=" << (fixed_ok && elapsed_ok && qpc_ok ? "pass" : "FAIL") << '\n';
    }
    command(100);
    running.store(false); simulation.join(); render.join();
    if (counters.backwards.load()) ++failures;
    std::cout << "speed_consistency_failures=" << failures << " qpc_backwards=" << counters.backwards.load()
              << " model_max_single_step_elapsed_ms="
              << double(counters.maximum_step_ticks.load()) * 1000.0 / double(frequency.QuadPart)
              << " hypothetical_large_elapsed_steps=" << counters.hypothetical_large_elapsed_steps.load()
              << " cached_model_is_hypothesis_not_game_evidence=1\n";
    return failures ? 1 : 0;
}
