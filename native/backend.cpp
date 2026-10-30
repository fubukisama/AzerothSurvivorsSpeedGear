// Clock interception adapted from AZS Speed Controller (MIT); see third_party notices.
#include <windows.h>
#include <mmsystem.h>
#include <intrin.h>
#include <MinHook.h>
#include <atomic>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <mutex>
#include <sstream>
#include <string>
#include <algorithm>
#include "pe_image.h"
#include "speed_clock.h"
#include "command.h"
#include "command_gate.h"
#include "console_bridge.h"
#include "language_bridge.h"
#include "diagnostics.h"

namespace {
using QpcFn=BOOL(WINAPI*)(LARGE_INTEGER*);
using TickFn=DWORD(WINAPI*)();
using Tick64Fn=ULONGLONG(WINAPI*)();
using TimeFn=DWORD(WINAPI*)();
using SleepFn=void(*)(std::uint64_t,std::uint32_t);
QpcFn realQpc=nullptr;
TickFn realTick=nullptr;
Tick64Fn realTick64=nullptr;
TimeFn realTime=nullptr;
SleepFn realSleep=nullptr;
std::mutex clockMutex;
azsg::VirtualClock qpcClock,tickClock,timeClock;
azsg::WrappingCounter32 multimediaCounter;
std::atomic<unsigned> speed{100};
std::atomic<std::uint64_t> simulationCalls{0};
std::uintptr_t imageBase=0;
azsg::SimulationSite site{};
std::filesystem::path root;
std::mutex logMutex;
bool productionGame = false;
std::mutex commandMutex;
azsg::CommandGate commandGate;
std::atomic<azsg::BackendState> backendState{azsg::BackendState::initializing};
std::atomic<std::uint64_t> fileReads{0};

void log(const std::string& text) {
    std::lock_guard<std::mutex> guard(logMutex);
    std::ofstream out(root/L"AZSSpeedGear.log",std::ios::app);
    SYSTEMTIME now{};GetLocalTime(&now);
    out<<now.wHour<<":"<<now.wMinute<<":"<<now.wSecond<<" "<<text<<"\n";
}
DWORD WINAPI languageWorker(void*) {
    std::filesystem::path languageFile;
    if(productionGame) {
        wchar_t appdata[32768]{};
        auto length=GetEnvironmentVariableW(L"APPDATA",appdata,32768);
        if(!length || length>=32768) return 0;
        languageFile=std::filesystem::path(appdata)/L"wenilla-rogue"/L"language.txt";
    } else {
        languageFile=root/L"language-test.txt";
    }
    while(true) {
        if(azsg::refresh_language_hint(root,languageFile)==azsg::LanguageHintResult::written)
            log("locale-hint updated from native game language setting");
        Sleep(1000);
    }
}
void setSpeed(unsigned next,const char* why) {
    {
        std::lock_guard<std::mutex> guard(clockMutex);
        if(speed.load(std::memory_order_relaxed)==next) return;
        LARGE_INTEGER qpc{};realQpc(&qpc);
        qpcClock.set_speed(static_cast<std::uint64_t>(qpc.QuadPart),next);
        auto ticks=realTick64();tickClock.set_speed(ticks,next);
        // Keep multimedia timer resolution; GetTickCount64 can quantize to 16ms.
        timeClock.set_speed(multimediaCounter.sample(realTime()),next);
        speed.store(next,std::memory_order_release);
    }
    log("speed100="+std::to_string(next)+" reason="+why+" simulation_calls="+std::to_string(simulationCalls.load()));
}
BOOL WINAPI hookedQpc(LARGE_INTEGER* out) {
    if(!out) return realQpc(out);
    std::lock_guard<std::mutex> guard(clockMutex);
    LARGE_INTEGER actual{};if(!realQpc(&actual)) return FALSE;
    out->QuadPart=static_cast<LONGLONG>(qpcClock.sample(static_cast<std::uint64_t>(actual.QuadPart)));return TRUE;
}
DWORD WINAPI hookedTick() {
    std::lock_guard<std::mutex> guard(clockMutex);
    return static_cast<DWORD>(tickClock.sample(realTick64()));
}
ULONGLONG WINAPI hookedTick64() {
    std::lock_guard<std::mutex> guard(clockMutex);
    return tickClock.sample(realTick64());
}
DWORD WINAPI hookedTime() {
    std::lock_guard<std::mutex> guard(clockMutex);
    return static_cast<DWORD>(timeClock.sample(multimediaCounter.sample(realTime())));
}
__declspec(noinline) void hookedRustSleep(std::uint64_t seconds,std::uint32_t nanos) {
    auto caller=reinterpret_cast<std::uintptr_t>(_ReturnAddress());
    if(caller==imageBase+site.return_rva && seconds==0 && nanos==site.nanos) {
        simulationCalls.fetch_add(1,std::memory_order_relaxed);
        nanos=static_cast<std::uint32_t>((std::uint64_t(nanos)*100)/speed.load(std::memory_order_acquire));
    }
    realSleep(seconds,nanos);
}
std::uint64_t unixSeconds() {
    FILETIME ft{};GetSystemTimeAsFileTime(&ft);
    return ((std::uint64_t(ft.dwHighDateTime)<<32)|ft.dwLowDateTime)/10000000-11644473600ull;
}
DWORD WINAPI diagnosticsWorker(void* parameter) {
    const auto ticks=reinterpret_cast<Tick64Fn>(parameter);
    std::string previous;
    while(true) {
        azsg::Diagnostics state;
        state.backend=backendState.load(std::memory_order_acquire);
        {
            std::lock_guard<std::mutex> guard(commandMutex);
            const auto now=ticks();
            state.transport=commandGate.transport(now);
            state.heartbeat_age_ms=commandGate.heartbeat_age(now);
            state.speed100=speed.load(std::memory_order_acquire);
        }
        if(state.backend!=azsg::BackendState::ready) state.transport="disabled";
        state.updated_unix=unixSeconds();state.file_reads=fileReads.load(std::memory_order_relaxed);
        state.dropped_bytes=azsg::console_bridge_dropped_bytes();
        if(state.transport!=previous) {previous=state.transport;log("transport="+previous);}
        azsg::write_diagnostics(root,state);
        Sleep(1000);
    }
}
void startDiagnostics(azsg::BackendState state,Tick64Fn ticks) {
    backendState.store(state,std::memory_order_release);
    const auto thread=CreateThread(nullptr,0,diagnosticsWorker,reinterpret_cast<void*>(ticks),0,nullptr);
    if(thread) CloseHandle(thread);
}
void receiveCommand(std::string_view text,azsg::CommandSource source) {
    std::lock_guard<std::mutex> guard(commandMutex);
    if(auto next=commandGate.accept(text,source,unixSeconds(),realTick64()))
        setSpeed(*next,source==azsg::CommandSource::console?"addon-console":"addon-file");
}
void receiveConsole(std::string_view text) {receiveCommand(text,azsg::CommandSource::console);}
std::string mailbox() {
    fileReads.fetch_add(1,std::memory_order_relaxed);
    const auto file=root/L"benilla-config"/L"config.toml";
    std::error_code error;auto length=std::filesystem::file_size(file,error);
    if(error || length>1024*1024) return {};
    std::ifstream in(file);std::string line;
    while(std::getline(in,line)) {
        auto equal=line.find('=');if(equal==std::string::npos) continue;
        std::string key=line.substr(0,equal);
        key.erase(std::remove_if(key.begin(),key.end(),[](unsigned char c){return c==' ' || c=='\t' || c=='"';}),key.end());
        std::transform(key.begin(),key.end(),key.begin(),[](unsigned char c){return static_cast<char>(std::tolower(c));});
        if(key!="azsspeedgearcommand") continue;
        auto first=line.find('"',equal+1),last=line.find_last_of('"');
        if(first==std::string::npos || last<=first) return {};
        return line.substr(first+1,last-first-1);
    }
    return {};
}
bool create(HMODULE module,const char* name,void* replacement,void** original) {
    auto address=module?GetProcAddress(module,name):nullptr;
    return address && MH_CreateHook(reinterpret_cast<void*>(address),replacement,original)==MH_OK;
}
DWORD WINAPI worker(void*) {
    wchar_t executable[32768]{};GetModuleFileNameW(nullptr,executable,32768);
    auto exe=std::filesystem::path(executable);
    // The proxy forwards DWM normally in all other processes (including our test host).
    productionGame=_wcsicmp(exe.filename().c_str(),L"AzerothSurvivors.exe")==0;
    if(!productionGame && _wcsicmp(exe.filename().c_str(),L"AZSSpeedGearTestHost.exe")!=0) return 0;
    root=exe.parent_path();
    log("AzerothSurvivorsSpeedGear 0.5.0 start; default=1x; protocol=SG1");
    // Locale synchronization remains available even if a future timing layout is refused.
    auto localeThread=CreateThread(nullptr,0,languageWorker,nullptr,0,nullptr);
    if(localeThread) CloseHandle(localeThread);
    imageBase=reinterpret_cast<std::uintptr_t>(GetModuleHandleW(nullptr));
    auto* dos=reinterpret_cast<const IMAGE_DOS_HEADER*>(imageBase);
    auto* pe=reinterpret_cast<const IMAGE_NT_HEADERS64*>(imageBase+dos->e_lfanew);
    azsg::PeImage image(reinterpret_cast<const unsigned char*>(imageBase),pe->OptionalHeader.SizeOfImage);
    std::string reason;auto found=image.locate_simulation(reason);
    if(!found) {
        log("disabled: "+reason+"; game remains at 1x");
        startDiagnostics(azsg::BackendState::unsupported,GetTickCount64);return 0;
    }
    site=*found;
    log("scan=verified sleep_rva="+std::to_string(site.sleep_rva)+" return_rva="+std::to_string(site.return_rva)+" evidence="+reason);
    if(MH_Initialize()!=MH_OK) {
        log("disabled: minhook-init");startDiagnostics(azsg::BackendState::hooks_failed,GetTickCount64);return 0;
    }
    HMODULE kernel=GetModuleHandleW(L"kernel32.dll"),winmm=LoadLibraryExW(L"winmm.dll",nullptr,LOAD_LIBRARY_SEARCH_SYSTEM32);
    bool ok=create(kernel,"QueryPerformanceCounter",reinterpret_cast<void*>(hookedQpc),reinterpret_cast<void**>(&realQpc)) &&
        create(kernel,"GetTickCount",reinterpret_cast<void*>(hookedTick),reinterpret_cast<void**>(&realTick)) &&
        create(kernel,"GetTickCount64",reinterpret_cast<void*>(hookedTick64),reinterpret_cast<void**>(&realTick64)) &&
        create(winmm,"timeGetTime",reinterpret_cast<void*>(hookedTime),reinterpret_cast<void**>(&realTime)) &&
        MH_CreateHook(reinterpret_cast<void*>(imageBase+site.sleep_rva),reinterpret_cast<void*>(hookedRustSleep),reinterpret_cast<void**>(&realSleep))==MH_OK;
    if(ok) {
        LARGE_INTEGER qpc{};realQpc(&qpc);qpcClock.sample(qpc.QuadPart);
        auto ticks=realTick64();tickClock.sample(ticks);
        {
            std::lock_guard<std::mutex> guard(clockMutex);
            timeClock.sample(multimediaCounter.sample(realTime()));
        }
        ok=MH_EnableHook(MH_ALL_HOOKS)==MH_OK;
    }
    if(!ok) {
        MH_DisableHook(MH_ALL_HOOKS);MH_Uninitialize();log("disabled: hooks-failed; game remains at 1x");
        startDiagnostics(azsg::BackendState::hooks_failed,GetTickCount64);return 0;
    }
    log("ready: waiting for fresh in-game AddOn heartbeat");
    log(azsg::start_console_bridge(receiveConsole)?"control-capture=installed; awaiting validated receipt":"control-capture=unavailable; file fallback");
    startDiagnostics(azsg::BackendState::ready,realTick64);
    std::string previous=mailbox();
    azsg::FallbackPoller filePoller;
    while(true) {
        Sleep(100);
        bool poll=false;
        {
            std::lock_guard<std::mutex> guard(commandMutex);
            const auto now=realTick64();
            if(commandGate.expire(now)) setSpeed(100,"heartbeat-timeout");
            poll=filePoller.due(now,commandGate.console_healthy(now));
        }
        if(!poll) continue;
        auto text=mailbox();
        if(!text.empty() && text!=previous) {
            previous=text;
            receiveCommand(text,azsg::CommandSource::file);
        }
    }
}
}
void StartBackend(HMODULE) {
    auto thread=CreateThread(nullptr,0,worker,nullptr,0,nullptr);
    if(thread) CloseHandle(thread);
}
