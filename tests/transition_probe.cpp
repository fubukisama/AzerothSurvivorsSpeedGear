// Isolated diagnostic host for the REAL dwmapi.dll. Link simulation_fixture.asm
// and winmm.lib, name the executable AZSSpeedGearTestHost.exe, and run it from
// a NEW artifacts/transition-probe-* directory containing only this EXE and the
// built DLL. It never launches or opens the real game or the user's APPDATA.
#include <windows.h>
#include <mmsystem.h>

#include <algorithm>
#include <atomic>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

extern "C" void SimulationStep();
extern "C" __declspec(noinline) void FakeRustSleep(std::uint64_t seconds,
                                                   std::uint32_t nanos) {
    const auto timer = CreateWaitableTimerExW(nullptr, nullptr, 2, TIMER_ALL_ACCESS);
    if (!timer) { Sleep((nanos + 999999) / 1000000); return; }
    LARGE_INTEGER due{};
    due.QuadPart = -static_cast<LONGLONG>(seconds * 10000000 + nanos / 100);
    if (!SetWaitableTimer(timer, &due, 0, nullptr, nullptr, FALSE)) {
        CloseHandle(timer); return;
    }
    WaitForSingleObject(timer, INFINITE);
    CloseHandle(timer);
}

namespace {
namespace fs = std::filesystem;
using Wall = std::uint64_t;

// This reference is NOT one of the APIs intercepted by the backend. Do not use
// std::chrono::steady_clock here: on Windows it would use the hooked QPC.
Wall wall() {
    FILETIME value{};
    GetSystemTimePreciseAsFileTime(&value);
    return (Wall(value.dwHighDateTime) << 32) | value.dwLowDateTime;
}
double milliseconds(Wall later, Wall earlier) {
    return later >= earlier ? double(later - earlier) / 10000.0 : -1.0;
}
std::string read_text(const fs::path& file) {
    std::ifstream stream(file, std::ios::binary);
    return std::string(std::istreambuf_iterator<char>(stream), {});
}
struct Sample {
    Wall before{}, after{};
    LONGLONG qpc{};
    ULONGLONG tick64{};
    DWORD tick{}, multimedia{};
    int phase{};
};
Sample sample(int phase) {
    Sample result;
    result.phase = phase;
    result.before = wall();
    LARGE_INTEGER counter{};
    QueryPerformanceCounter(&counter);
    result.qpc = counter.QuadPart;
    result.tick64 = GetTickCount64();
    result.tick = GetTickCount();
    result.multimedia = timeGetTime();
    result.after = wall();
    return result;
}
struct Step {
    Wall begin{}, end{};
    LONGLONG qpc_begin{}, qpc_end{};
    unsigned requested{};
};
struct Request {
    unsigned sequence{}, speed{};
    Wall issued{}, published{}, acknowledged{};
};
struct Summary {
    unsigned qpc_backwards = 0, tick64_backwards = 0, qpc_spikes = 0;
    double max_qpc_frame_ms = 0, max_qpc_envelope_ratio = 0;
    double short_gap_multimedia_step_ms = 0, short_gap_tick_step_ms = 0;
};
Summary summarize(const std::vector<Sample>& values, double qpc_frequency,
                  int phase_filter = -999) {
    Summary summary;
    for (std::size_t index = 1; index < values.size(); ++index) {
        const auto& previous = values[index - 1];
        const auto& current = values[index];
        if (phase_filter != -999 &&
            (previous.phase != phase_filter || current.phase != phase_filter)) continue;
        const auto envelope = milliseconds(current.after, previous.before);
        const auto qpc_ms = double(current.qpc - previous.qpc) * 1000.0 / qpc_frequency;
        if (current.qpc < previous.qpc) ++summary.qpc_backwards;
        if (current.tick64 < previous.tick64) ++summary.tick64_backwards;
        summary.max_qpc_frame_ms = (std::max)(summary.max_qpc_frame_ms, qpc_ms);
        if (envelope > 0) {
            summary.max_qpc_envelope_ratio =
                (std::max)(summary.max_qpc_envelope_ratio, qpc_ms / envelope);
            // All requested rates are <=5x. Enclose both API call sequences in
            // the real-time interval so preemption is not mistaken for a jump.
            if (qpc_ms > envelope * 5.25 + 0.1) ++summary.qpc_spikes;
        }
        if (envelope > 0 && envelope < 3.0) {
            summary.short_gap_multimedia_step_ms = (std::max)(
                summary.short_gap_multimedia_step_ms,
                double(static_cast<DWORD>(current.multimedia - previous.multimedia)));
            summary.short_gap_tick_step_ms = (std::max)(
                summary.short_gap_tick_step_ms,
                double(current.tick64 - previous.tick64));
        }
    }
    return summary;
}
void print_summary(const char* name, const Summary& summary) {
    std::cout << name << " qpc_backwards=" << summary.qpc_backwards
              << " tick64_backwards=" << summary.tick64_backwards
              << " qpc_spikes=" << summary.qpc_spikes
              << " max_qpc_frame_ms=" << summary.max_qpc_frame_ms
              << " max_qpc_envelope_ratio=" << summary.max_qpc_envelope_ratio
              << " short_gap_timeGetTime_step_ms=" << summary.short_gap_multimedia_step_ms
              << " short_gap_tick64_step_ms=" << summary.short_gap_tick_step_ms << '\n';
}
bool publish(const fs::path& config, const Request& request) {
    const auto staging = config.parent_path() / L"probe-command.tmp";
    {
        std::ofstream output(staging, std::ios::binary | std::ios::trunc);
        const auto unix_seconds = request.issued / 10000000 - 11644473600ull;
        output << "[cvars]\nazsspeedgearcommand = \"SG1|123456789|"
               << request.sequence << '|' << unix_seconds << '|'
               << request.speed << "|1\"\n";
        output.close();
        if (!output) return false;
    }
    return MoveFileExW(staging.c_str(), config.c_str(),
                       MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH) != FALSE;
}
} // namespace

int wmain(int argc, wchar_t** argv) {
    unsigned hold_ms = 350, cycles = 3;
    if (argc > 1) hold_ms = static_cast<unsigned>(_wtoi(argv[1]));
    if (argc > 2) cycles = static_cast<unsigned>(_wtoi(argv[2]));
    if (hold_ms < 120 || hold_ms > 5000 || cycles < 1 || cycles > 20) {
        std::cerr << "Usage: AZSSpeedGearTestHost.exe [hold-ms 120..5000] [cycles 1..20]\n";
        return 2;
    }
    wchar_t executable[32768]{};
    GetModuleFileNameW(nullptr, executable, 32768);
    const fs::path own_exe(executable);
    const auto root = own_exe.parent_path();
    const auto config = root / L"benilla-config" / L"config.toml";
    if (_wcsicmp(own_exe.filename().c_str(), L"AZSSpeedGearTestHost.exe") != 0 ||
        fs::exists(root / L"AzerothSurvivors.exe") || fs::exists(config)) {
        std::cerr << "Use the required test-host name and a fresh isolated directory.\n";
        return 2;
    }
    fs::create_directories(config.parent_path());
    { std::ofstream output(config); output << "[cvars]\n"; }
    LARGE_INTEGER frequency{};
    QueryPerformanceFrequency(&frequency);
    timeBeginPeriod(1);
    std::cout << std::fixed << std::setprecision(3);

    std::vector<Sample> baseline, samples;
    auto until = wall() + 8000000;
    while (wall() < until) { baseline.push_back(sample(-2)); Sleep(1); }

    const auto dll = LoadLibraryW((root / L"dwmapi.dll").c_str());
    if (!dll) { std::cerr << "DLL load failed: " << GetLastError() << '\n'; return 2; }
    const auto log_file = root / L"AZSSpeedGear.log";
    until = wall() + 100000000;
    bool ready = false;
    while (wall() < until) {
        const auto log = read_text(log_file);
        if (log.find("ready: waiting") != std::string::npos) { ready = true; break; }
        if (log.find("disabled:") != std::string::npos) break;
        Sleep(10);
    }
    if (!ready) {
        std::cerr << "Backend did not become ready:\n" << read_text(log_file);
        return 2;
    }

    std::atomic<bool> running{true};
    std::atomic<unsigned> requested{100};
    std::vector<Step> steps;
    std::thread simulation([&] {
        while (running.load()) {
            Step current;
            current.requested = requested.load();
            current.begin = wall();
            LARGE_INTEGER begin{}, end{};
            QueryPerformanceCounter(&begin);
            SimulationStep();
            QueryPerformanceCounter(&end);
            current.end = wall();
            current.qpc_begin = begin.QuadPart;
            current.qpc_end = end.QuadPart;
            steps.push_back(current);
        }
    });

    std::vector<Request> requests;
    const unsigned plan[] = {500, 50, 300, 100};
    std::size_t consumed_log = read_text(log_file).size();
    Wall next_log_read = 0;
    unsigned sequence = 0;
    auto observe = [&](int phase, Wall deadline) {
        while (wall() < deadline) {
            samples.push_back(sample(phase));
            const auto now = wall();
            if (now >= next_log_read) {
                next_log_read = now + 100000; // 10 real milliseconds.
                const auto log = read_text(log_file);
                if (log.size() > consumed_log) {
                    std::istringstream lines(log.substr(consumed_log));
                    std::string line;
                    while (std::getline(lines, line)) {
                        const auto position = line.find("speed100=");
                        if (position == std::string::npos ||
                            line.find("reason=addon-file") == std::string::npos) continue;
                        const auto value = static_cast<unsigned>(std::stoul(line.substr(position + 9)));
                        for (auto it = requests.rbegin(); it != requests.rend(); ++it) {
                            if (!it->acknowledged && it->speed == value) {
                                it->acknowledged = wall();
                                break;
                            }
                        }
                    }
                    // An incomplete trailing line is harmless for these small,
                    // single-line flushed native logs; no synthetic ack is made.
                    consumed_log = log.size();
                }
            }
            Sleep(1);
        }
    };
    observe(-1, wall() + 6000000); // Hooked but still at default 1x.
    for (unsigned cycle = 0; cycle < cycles; ++cycle) {
        for (const unsigned speed : plan) {
            Request command{++sequence, speed, wall(), 0, 0};
            requested.store(speed);
            if (!publish(config, command)) {
                std::cerr << "Atomic command publish failed: " << GetLastError() << '\n';
                running = false; simulation.join(); return 2;
            }
            command.published = wall();
            requests.push_back(command);
            observe(static_cast<int>(sequence), command.published + Wall(hold_ms) * 10000);
        }
    }
    running = false;
    simulation.join();
    timeEndPeriod(1);

    const auto pre = summarize(baseline, double(frequency.QuadPart));
    const auto native_default = summarize(samples, double(frequency.QuadPart), -1);
    const auto transitions = summarize(samples, double(frequency.QuadPart));
    print_summary("before_DLL_1x", pre);
    print_summary("native_default_1x", native_default);
    print_summary("transitions", transitions);
    unsigned missing_acks = 0;
    double maximum_latency = 0;
    for (const auto& request : requests) {
        const auto latency = request.acknowledged
            ? milliseconds(request.acknowledged, request.published) : -1.0;
        if (!request.acknowledged) ++missing_acks;
        else maximum_latency = (std::max)(maximum_latency, latency);
        std::cout << "request seq=" << request.sequence << " speed=" << request.speed / 100.0
                  << " file_publish_ms=" << milliseconds(request.published, request.issued)
                  << " native_log_ack_ms=" << latency << '\n';
    }
    double minimum_step = 1e20, maximum_step = 0;
    for (const auto& step : steps) {
        const auto duration = milliseconds(step.end, step.begin);
        minimum_step = (std::min)(minimum_step, duration);
        maximum_step = (std::max)(maximum_step, duration);
    }
    std::cout << "simulation steps=" << steps.size() << " min_real_step_ms=" << minimum_step
              << " max_real_step_ms=" << maximum_step << " max_native_ack_ms=" << maximum_latency
              << " missing_acks=" << missing_acks << '\n';

    std::ofstream clock_csv(root / L"transition-clock-samples.csv");
    clock_csv << "phase,wall_before_100ns,wall_after_100ns,qpc,tick64,tick32,timeGetTime\n";
    for (const auto& value : samples)
        clock_csv << value.phase << ',' << value.before << ',' << value.after << ',' << value.qpc
                  << ',' << value.tick64 << ',' << value.tick << ',' << value.multimedia << '\n';
    std::ofstream step_csv(root / L"transition-step-samples.csv");
    step_csv << "requested100,wall_begin_100ns,wall_end_100ns,qpc_begin,qpc_end\n";
    for (const auto& value : steps)
        step_csv << value.requested << ',' << value.begin << ',' << value.end << ','
                 << value.qpc_begin << ',' << value.qpc_end << '\n';

    // A concrete baseline-sensitive red condition, separate from QPC continuity:
    // replacing a <=3ms multimedia clock with >=8ms steps at default 1x is a
    // real clock-resolution regression even if its long-term slope stays 1x.
    const bool multimedia_regression = pre.short_gap_multimedia_step_ms <= 3.0 &&
                                      native_default.short_gap_multimedia_step_ms >= 8.0;
    std::cout << "multimedia_resolution_regression=" << (multimedia_regression ? 1 : 0) << '\n';
    return transitions.qpc_backwards || transitions.tick64_backwards || transitions.qpc_spikes ||
           missing_acks || multimedia_regression ? 1 : 0;
}
