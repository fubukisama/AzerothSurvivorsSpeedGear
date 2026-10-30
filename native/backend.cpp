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
std::atomic<unsigned> speed{100};
std::atomic<std::uint64_t> simulationCalls{0};
std::uintptr_t imageBase=0;
azsg::SimulationSite site{};
std::filesystem::path root;
std::mutex logMutex;

void log(const std::string& text) {
    std::lock_guard<std::mutex> guard(logMutex);
    std::ofstream out(root/L"AZSSpeedGear.log",std::ios::app);
    SYSTEMTIME now{};GetLocalTime(&now);
    out<<now.wHour<<":"<<now.wMinute<<":"<<now.wSecond<<" "<<text<<"\n";
}
void setSpeed(unsigned next,const char* why) {
    {
        std::lock_guard<std::mutex> guard(clockMutex);
        if(speed.load(std::memory_order_relaxed)==next) return;
        LARGE_INTEGER qpc{};realQpc(&qpc);
        qpcClock.set_speed(static_cast<std::uint64_t>(qpc.QuadPart),next);
        auto ticks=realTick64();tickClock.set_speed(ticks,next);
        // timeGetTime is a wrapping 32-bit API: derive its elapsed ticks from the same real 64-bit clock.
        timeClock.set_speed(ticks,next);
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
    return static_cast<DWORD>(timeClock.sample(realTick64()));
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
std::string mailbox() {
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
    if(_wcsicmp(exe.filename().c_str(),L"AzerothSurvivors.exe")!=0 && _wcsicmp(exe.filename().c_str(),L"AZSSpeedGearTestHost.exe")!=0) return 0;
    root=exe.parent_path();
    log("AZSSpeedGear 0.1.0 start; default=1x; protocol=SG1");
    imageBase=reinterpret_cast<std::uintptr_t>(GetModuleHandleW(nullptr));
    auto* dos=reinterpret_cast<const IMAGE_DOS_HEADER*>(imageBase);
    auto* pe=reinterpret_cast<const IMAGE_NT_HEADERS64*>(imageBase+dos->e_lfanew);
    azsg::PeImage image(reinterpret_cast<const unsigned char*>(imageBase),pe->OptionalHeader.SizeOfImage);
    std::string reason;auto found=image.locate_simulation(reason);
    if(!found) {log("disabled: "+reason+"; game remains at 1x");return 0;}
    site=*found;
    log("scan=verified sleep_rva="+std::to_string(site.sleep_rva)+" return_rva="+std::to_string(site.return_rva)+" evidence="+reason);
    if(MH_Initialize()!=MH_OK) {log("disabled: minhook-init");return 0;}
    HMODULE kernel=GetModuleHandleW(L"kernel32.dll"),winmm=LoadLibraryExW(L"winmm.dll",nullptr,LOAD_LIBRARY_SEARCH_SYSTEM32);
    bool ok=create(kernel,"QueryPerformanceCounter",reinterpret_cast<void*>(hookedQpc),reinterpret_cast<void**>(&realQpc)) &&
        create(kernel,"GetTickCount",reinterpret_cast<void*>(hookedTick),reinterpret_cast<void**>(&realTick)) &&
        create(kernel,"GetTickCount64",reinterpret_cast<void*>(hookedTick64),reinterpret_cast<void**>(&realTick64)) &&
        create(winmm,"timeGetTime",reinterpret_cast<void*>(hookedTime),reinterpret_cast<void**>(&realTime)) &&
        MH_CreateHook(reinterpret_cast<void*>(imageBase+site.sleep_rva),reinterpret_cast<void*>(hookedRustSleep),reinterpret_cast<void**>(&realSleep))==MH_OK;
    if(ok) {
        LARGE_INTEGER qpc{};realQpc(&qpc);qpcClock.sample(qpc.QuadPart);
        auto ticks=realTick64();tickClock.sample(ticks);timeClock.sample(ticks);
        ok=MH_EnableHook(MH_ALL_HOOKS)==MH_OK;
    }
    if(!ok) { MH_DisableHook(MH_ALL_HOOKS);MH_Uninitialize();log("disabled: hooks-failed; game remains at 1x");return 0; }
    log("ready: waiting for fresh in-game AddOn heartbeat");
    std::string previous=mailbox();
    std::uint64_t lastBeat=0,currentSession=0,lastSequence=0;
    bool hadCommand=false;
    while(true) {
        Sleep(100);
        // Run this before parsing: malformed/replayed commands must never starve the watchdog.
        if(hadCommand && realTick64()-lastBeat>8000) {setSpeed(100,"heartbeat-timeout");hadCommand=false;}
        auto text=mailbox();
        if(!text.empty() && text!=previous) {
            previous=text;
            auto command=azsg::parse_command(text);
            auto now=unixSeconds();
            if(!command || command->unix_seconds>now+2 || now>command->unix_seconds+8) {setSpeed(100,"invalid-or-stale-command");continue;}
            if(command->session!=currentSession) {currentSession=command->session;lastSequence=0;setSpeed(100,"new-addon-session");}
            if(command->sequence<=lastSequence) continue;
            lastSequence=command->sequence;lastBeat=realTick64();hadCommand=true;
            setSpeed(command->active?command->speed100:100,command->active?"addon-playing":"addon-inactive");
        }
    }
}
}
void StartBackend(HMODULE) {
    auto thread=CreateThread(nullptr,0,worker,nullptr,0,nullptr);
    if(thread) CloseHandle(thread);
}
