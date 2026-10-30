#include <windows.h>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <string>

extern "C" void SimulationStep();
extern "C" __declspec(noinline) void FakeRustSleep(std::uint64_t seconds,std::uint32_t nanos) {
    auto timer=CreateWaitableTimerExW(nullptr,nullptr,2,TIMER_ALL_ACCESS);
    LARGE_INTEGER due{};due.QuadPart=-static_cast<LONGLONG>(seconds*10000000+nanos/100);
    if(timer && SetWaitableTimer(timer,&due,0,nullptr,nullptr,FALSE)) WaitForSingleObject(timer,INFINITE);
    if(timer) CloseHandle(timer);
}
static std::uint64_t wall() {
    FILETIME ft{};GetSystemTimePreciseAsFileTime(&ft);
    return (std::uint64_t(ft.dwHighDateTime)<<32)|ft.dwLowDateTime;
}
static double rate() {
    LARGE_INTEGER a{},b{},frequency{};QueryPerformanceFrequency(&frequency);
    auto begin=wall();QueryPerformanceCounter(&a);Sleep(12);QueryPerformanceCounter(&b);
    return double(b.QuadPart-a.QuadPart)*10000000.0/double(wall()-begin)/double(frequency.QuadPart);
}
static void console(const std::string& command,DWORD channel,bool split=false) {
    auto line="2026-10-30T00:00:00 INFO benilla_app::console: console: CVar \"AZSSpeedGearCommand\" is \""+command+"\"\r\n";
    DWORD written=0;auto handle=GetStdHandle(channel);
    if(split) {
        WriteFile(handle,line.data(),33,&written,nullptr);
        WriteFile(handle,line.data()+33,static_cast<DWORD>(line.size()-33),&written,nullptr);
    } else WriteFile(handle,line.data(),static_cast<DWORD>(line.size()),&written,nullptr);
}
int wmain() {
    wchar_t name[32768]{};GetModuleFileNameW(nullptr,name,32768);
    auto root=std::filesystem::path(name).parent_path();
    std::filesystem::create_directories(root/L"benilla-config");
    auto config=root/L"benilla-config"/L"config.toml";
    {std::ofstream out(config);out<<"[cvars]\n";}
    if(!LoadLibraryW((root/L"dwmapi.dll").c_str())) return 2;
    Sleep(500);
    unsigned failures=0,seq=0;double maximum=0;
    std::string previous;
    for(unsigned speed:{500u,25u,300u,50u,100u,200u,500u,100u}) {
        auto payload="SG1|456|"+std::to_string(++seq)+"|"+std::to_string(wall()/10000000-11644473600ull)+"|"+std::to_string(speed)+"|1";
        auto start=wall();console(payload,seq%2?STD_OUTPUT_HANDLE:STD_ERROR_HANDLE,seq%2==0);
        bool accepted=false;
        do {
            auto measured=rate();
            if(measured>speed/100.0*0.8 && measured<speed/100.0*1.2) {accepted=true;break;}
        } while(wall()-start<4000000);
        auto latency=(wall()-start)/10000.0;maximum=(std::max)(maximum,latency);
        if(!accepted) {++failures;std::cerr<<"FAIL console delivery speed="<<speed<<" latency_ms="<<latency<<"\n";}
        // An old config save must not undo a command already received on the console.
        if(!previous.empty()) {std::ofstream out(config);out<<"[cvars]\nazsspeedgearcommand = \""<<previous<<"\"\n";}
        Sleep(150);
        auto observed=rate();
        if(observed<speed/100.0*0.8 || observed>speed/100.0*1.2) {++failures;std::cerr<<"FAIL delayed file changed speed="<<speed<<"\n";}
        previous=payload;
    }
    // Missing console output still has a functional file fallback.
    auto payload="SG1|456|"+std::to_string(++seq)+"|"+std::to_string(wall()/10000000-11644473600ull)+"|300|1";
    {std::ofstream out(config);out<<"[cvars]\nazsspeedgearcommand = \""<<payload<<"\"\n";}
    Sleep(1250); // A recently healthy console permits at most one file scan/second.
    if(rate()<2.5) {++failures;std::cerr<<"FAIL file fallback\n";}
    std::cout<<"fast_bridge_failures="<<failures<<" maximum_delivery_ms="<<maximum<<"\n";
    return failures?1:0;
}
