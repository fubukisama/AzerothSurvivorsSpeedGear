// Remote diagnostic: fixed QPC work, independently timed with OS FILETIME.
// Performance values are observations, not shared-runner correctness gates.
#include <windows.h>
#include <mmsystem.h>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

extern "C" void SimulationStep();
extern "C" __declspec(noinline) void FakeRustSleep(std::uint64_t seconds,std::uint32_t nanos) {
    const auto timer=CreateWaitableTimerExW(nullptr,nullptr,2,TIMER_ALL_ACCESS);
    if(!timer) {Sleep((nanos+999999)/1000000);return;}
    LARGE_INTEGER due{};due.QuadPart=-static_cast<LONGLONG>(seconds*10000000+nanos/100);
    if(SetWaitableTimer(timer,&due,0,nullptr,nullptr,FALSE)) WaitForSingleObject(timer,INFINITE);
    CloseHandle(timer);
}

namespace {
constexpr std::uint64_t calls_per_sample=16777216;
std::uint64_t ticks(const FILETIME& value) {
    return (std::uint64_t(value.dwHighDateTime)<<32)|value.dwLowDateTime;
}
std::uint64_t wall() {
    FILETIME value{};GetSystemTimePreciseAsFileTime(&value);return ticks(value);
}
std::uint64_t cpu() {
    FILETIME creation{},exit{},kernel{},user{};
    if(!GetProcessTimes(GetCurrentProcess(),&creation,&exit,&kernel,&user)) return 0;
    return ticks(kernel)+ticks(user);
}
double qpc_rate() {
    LARGE_INTEGER frequency{},before{},after{};
    QueryPerformanceFrequency(&frequency);
    const auto begin=wall();QueryPerformanceCounter(&before);
    Sleep(100);QueryPerformanceCounter(&after);
    const auto elapsed=wall()-begin;
    if(!elapsed || frequency.QuadPart<=0) return 0;
    return double(after.QuadPart-before.QuadPart)*10000000.0/double(elapsed)/double(frequency.QuadPart);
}

class Heartbeat {
public:
    Heartbeat() : thread_([this]{
        auto previous=wall();
        while(running_.load()) {
            const auto now=wall();
            if(now<previous || now-previous>=10000000) {send();previous=now;}
            Sleep(25);
        }
    }) {}
    ~Heartbeat() {running_=false;if(thread_.joinable()) thread_.join();}
    void target(unsigned value) {speed_=value;send();}
private:
    void send() {
        std::lock_guard<std::mutex> lock(mutex_);
        const auto payload="SG1|38613|"+std::to_string(++sequence_)+"|"+
            std::to_string(wall()/10000000-11644473600ull)+"|"+std::to_string(speed_.load())+"|1";
        const auto line="INFO console: CVar \"AZSSpeedGearCommand\" is \""+payload+"\"\r\n";
        DWORD written=0;
        WriteFile(GetStdHandle(STD_OUTPUT_HANDLE),line.data(),static_cast<DWORD>(line.size()),&written,nullptr);
    }
    std::atomic<bool> running_{true};
    std::atomic<unsigned> speed_{100};
    std::mutex mutex_;
    unsigned sequence_=0;
    std::thread thread_;
};

std::string readStatus(const std::filesystem::path& root) {
    const auto path=root/L"AZSSpeedGear-status.json";
    std::error_code error;const auto size=std::filesystem::file_size(path,error);
    if(error || size>16384) return {};
    std::ifstream file(path);
    return std::string(std::istreambuf_iterator<char>(file),std::istreambuf_iterator<char>());
}
bool settle(const std::filesystem::path& root,unsigned speed,Heartbeat* heartbeat) {
    if(heartbeat) heartbeat->target(speed);
    const auto deadline=wall()+80000000;
    do {
        const auto text=readStatus(root);
        const auto speed_field="\"speed100\":"+std::to_string(speed)+",";
        if(text.find("\"backend\":\"ready\"")!=std::string::npos && text.find(speed_field)!=std::string::npos) {
            const auto observed=qpc_rate();
            if(observed>speed/100.0*0.85 && observed<speed/100.0*1.15) return true;
        }
        Sleep(50);
    } while(wall()<deadline);
    return false;
}

struct Sample {
    std::string stage;
    unsigned threads=0;
    std::uint64_t calls=0,backwards=0,failures=0;
    double wall_ms=0,cpu_ms=0,observed_rate=0;
};
Sample run(std::string stage,unsigned threads) {
    const auto start_event=CreateEventW(nullptr,TRUE,FALSE,nullptr);
    if(!start_event) throw std::runtime_error("start event unavailable");
    std::atomic<unsigned> ready{0};
    std::vector<std::thread> workers;
    std::vector<std::uint64_t> backwards(threads,0),failures(threads,0),checksums(threads,0);
    for(unsigned index=0;index<threads;++index) workers.emplace_back([&,index]{
        ++ready;WaitForSingleObject(start_event,INFINITE);
        LARGE_INTEGER counter{};LONGLONG previous=0;
        for(std::uint64_t call=0;call<calls_per_sample/threads;++call) {
            if(!QueryPerformanceCounter(&counter)) ++failures[index];
            if(previous>counter.QuadPart) ++backwards[index];
            previous=counter.QuadPart;
        }
        checksums[index]=static_cast<std::uint64_t>(previous);
    });
    while(ready.load()!=threads) Sleep(1);
    const auto begin_cpu=cpu(),begin_wall=wall();
    SetEvent(start_event);
    for(auto& worker:workers) worker.join();
    const auto end_wall=wall(),end_cpu=cpu();
    CloseHandle(start_event);
    if(end_wall<=begin_wall || end_cpu<begin_cpu) throw std::runtime_error("independent timer unavailable");
    Sample result;result.stage=std::move(stage);result.threads=threads;result.calls=calls_per_sample;
    result.wall_ms=double(end_wall-begin_wall)/10000.0;
    result.cpu_ms=double(end_cpu-begin_cpu)/10000.0;
    for(unsigned index=0;index<threads;++index) {
        result.backwards+=backwards[index];result.failures+=failures[index];
        if(!checksums[index]) ++result.failures;
    }
    result.observed_rate=qpc_rate();
    return result;
}
}

int wmain(int argc,wchar_t** argv) {
    if(argc!=3) {std::cerr<<"usage: host --baseline|--hooked report.json\n";return 2;}
    const bool hooked=std::wstring(argv[1])==L"--hooked";
    if(!hooked && std::wstring(argv[1])!=L"--baseline") return 2;
    wchar_t executable[32768]{};GetModuleFileNameW(nullptr,executable,32768);
    const auto root=std::filesystem::path(executable).parent_path();
    // Retain the real scanner's independently linked 25ms sleep call and imports.
    // No mocked interception or direct mutation of VirtualClock is used here.
    volatile auto import_probe=GetTickCount()+GetTickCount64()+timeGetTime();(void)import_probe;
    std::filesystem::create_directories(root/L"benilla-config");
    {std::ofstream file(root/L"benilla-config"/L"config.toml");file<<"[cvars]\n";}
    std::unique_ptr<Heartbeat> heartbeat;
    if(hooked) {
        if(!LoadLibraryW((root/L"dwmapi.dll").c_str())) {std::cerr<<"production DLL load failed\n";return 3;}
        if(!settle(root,100,nullptr)) {std::cerr<<"production timing hooks not ready\n";return 4;}
        heartbeat=std::make_unique<Heartbeat>();
    }
    SimulationStep();
    std::vector<Sample> samples;
    bool valid=true;
    for(unsigned phase=0;phase<(hooked?3u:1u);++phase) {
        const unsigned wanted=phase==1?200:100;
        if(hooked && !settle(root,wanted,heartbeat.get())) {std::cerr<<"requested native rate not observed\n";return 5;}
        const std::string stage=!hooked?"baseline":phase==0?"hooked1":phase==1?"hooked2":"restored1";
        for(unsigned threads:{1u,2u,8u}) {
            if(hooked) heartbeat->target(wanted);
            auto sample=run(stage,threads);
            valid=valid && !sample.backwards && !sample.failures &&
                sample.observed_rate>wanted/100.0*0.85 && sample.observed_rate<wanted/100.0*1.15;
            samples.push_back(std::move(sample));
        }
    }
    heartbeat.reset();
    std::ofstream output{std::filesystem::path(argv[2])};
    output<<std::setprecision(10)<<"{\"schema\":1,\"hooked\":"<<(hooked?"true":"false")
          <<",\"validClockObservations\":"<<(valid?"true":"false")<<",\"samples\":[";
    bool first=true;
    for(const auto& sample:samples) {
        if(!first) output<<",";first=false;
        output<<"{\"stage\":\""<<sample.stage<<"\",\"threads\":"<<sample.threads<<",\"calls\":"<<sample.calls
              <<",\"wallMs\":"<<sample.wall_ms<<",\"processCpuMs\":"<<sample.cpu_ms
              <<",\"observedQpcRate\":"<<sample.observed_rate<<",\"backwards\":"<<sample.backwards
              <<",\"apiFailures\":"<<sample.failures<<"}";
    }
    output<<"]}\n";output.close();
    return valid?0:6;
}
