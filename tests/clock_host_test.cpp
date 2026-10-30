#include <windows.h>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <thread>

extern "C" void SimulationStep();
extern "C" __declspec(noinline) void FakeRustSleep(std::uint64_t seconds,std::uint32_t nanos) {
    auto timer=CreateWaitableTimerExW(nullptr,nullptr,2,TIMER_ALL_ACCESS);
    if(!timer) {Sleep((nanos+999999)/1000000);return;}
    LARGE_INTEGER due{};due.QuadPart=-static_cast<LONGLONG>(seconds*10000000+nanos/100);
    if(!SetWaitableTimer(timer,&due,0,nullptr,nullptr,FALSE)) {CloseHandle(timer);return;}
    WaitForSingleObject(timer,INFINITE);
    CloseHandle(timer);
}
std::uint64_t wall() {
    FILETIME ft{};GetSystemTimePreciseAsFileTime(&ft);
    return (std::uint64_t(ft.dwHighDateTime)<<32)|ft.dwLowDateTime;
}
int wmain() {
    wchar_t exe[32768]{};GetModuleFileNameW(nullptr,exe,32768);
    auto root=std::filesystem::path(exe).parent_path();
    std::filesystem::create_directories(root/L"benilla-config");
    auto config=root/L"benilla-config"/L"config.toml";
    {std::ofstream out(config);out<<"[cvars]\n";}
    auto dll=LoadLibraryW((root/L"dwmapi.dll").c_str());
    if(!dll) {std::cerr<<"DLL load failed "<<GetLastError()<<"\n";return 1;}
    using DwmEnabled=HRESULT(WINAPI*)(BOOL*);
    auto fn=reinterpret_cast<DwmEnabled>(GetProcAddress(dll,"DwmIsCompositionEnabled"));
    BOOL enabled=FALSE;
    if(!fn || FAILED(fn(&enabled))) {std::cerr<<"DWM forwarding failed\n";return 1;}
    Sleep(1000);
    std::atomic<bool> running{true};std::atomic<unsigned long long> count{0};
    std::thread simulation([&]{while(running.load()){SimulationStep();++count;}});
    unsigned seq=0;
    auto command=[&](unsigned speed,bool active){
        std::ofstream out(config,std::ios::trunc);
        auto unix=(wall()/10000000)-11644473600ull;
        out<<"[cvars]\nazsspeedgearcommand = \"SG1|999|"<<++seq<<"|"<<unix<<"|"<<speed<<"|"<<(active?1:0)<<"\"\n";
    };
    auto sample=[&](unsigned millis){
        auto startCount=count.load(),startWall=wall();
        Sleep(millis);
        return double(count.load()-startCount)*10000000.0/double(wall()-startWall);
    };
    auto normal=sample(1500);
    command(200,true);Sleep(400);auto twice=sample(1500);
    command(500,true);Sleep(400);auto five=sample(1500);
    command(50,true);Sleep(400);auto half=sample(1500);
    command(500,false);Sleep(400);auto inactive=sample(1500);
    command(200,true);Sleep(400);
    // Continuously changing, replayed commands are not a heartbeat and must not bypass expiry.
    for(unsigned n=0;n<85;++n) {
        std::ofstream out(config,std::ios::trunc);
        auto unix=(wall()/10000000)-11644473600ull;
        out<<"[cvars]\nazsspeedgearcommand = \"SG1|999|1|"<<unix<<"|"<<(200+n%2)<<"|1\"\n";
        out.close();Sleep(100);
    }
    auto watchdog=sample(1000);
    running=false;simulation.join();
    std::cout<<"normal="<<normal<<" twice="<<twice<<" five="<<five<<" half="<<half
             <<" inactive="<<inactive<<" watchdog="<<watchdog<<" DWM="<<enabled<<"\n";
    auto ratio=[&](double rate,double expected){return rate/normal>expected*0.72 && rate/normal<expected*1.3;};
    bool ok=normal>25 && ratio(twice,2) && ratio(five,5) && ratio(half,0.5) && ratio(inactive,1) && ratio(watchdog,1);
    if(!ok) std::cerr<<"Native integration speed/restore check failed\n";
    return ok?0:1;
}
