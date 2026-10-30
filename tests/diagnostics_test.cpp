#include <windows.h>
#include "diagnostics.h"
#include <filesystem>
#include <fstream>
#include <iostream>

static std::string read(const std::filesystem::path& path) {
    std::ifstream input(path,std::ios::binary);
    return {std::istreambuf_iterator<char>(input),std::istreambuf_iterator<char>()};
}
static void write(const std::filesystem::path& path,const std::string& text) {
    std::ofstream output(path,std::ios::binary|std::ios::trunc);output<<text;
}
int main() {
    unsigned checks=0,failed=0;
    auto check=[&](bool value,const char* reason){++checks;if(!value){++failed;std::cerr<<"FAIL "<<reason<<'\n';}};
    namespace fs=std::filesystem;
    const auto root=fs::temp_directory_path()/("AZSG-diagnostics-"+std::to_string(GetCurrentProcessId())+"-"+std::to_string(GetTickCount64()));
    fs::create_directories(root/L"benilla-config");
    const auto report=root/L"AZSSpeedGear-status.json";
    azsg::Diagnostics state;state.updated_unix=1800000000;
    auto text=azsg::diagnostics_json(state);
    check(text.find("\"product\":\"AzerothSurvivorsSpeedGear\"")!=std::string::npos,"fixed project name");
    check(text.find("\"transport\":\"disabled\"")!=std::string::npos,"initializing backend cannot appear connected");
    check(text.find("\"heartbeatAgeMs\":null")!=std::string::npos,"missing heartbeat remains unknown");
    state.backend=azsg::BackendState::ready;state.transport="console";state.speed100=200;state.heartbeat_age_ms=25;
    state.file_reads=3;state.dropped_bytes=120;
    check(azsg::write_diagnostics(root,state),"first status atomically written");
    check(read(report)==azsg::diagnostics_json(state),"status represents actual backend receipt and counters");
    check(!fs::exists(root/L"benilla-config"/L"AZSSpeedGear-runtime"/L"Status.tmp"),"successful replace leaves no staging file");
    state.transport="file";state.file_reads=4;
    check(azsg::write_diagnostics(root,state),"owned status replaced");
    check(read(report).find("\"transport\":\"file\"")!=std::string::npos,"fallback is visible");
    state.backend=azsg::BackendState::unsupported;
    check(azsg::write_diagnostics(root,state),"unsupported scanner report remains available");
    check(read(report).find("\"transport\":\"disabled\"")!=std::string::npos,"unsupported timing never reports connected");
    state.transport="console\"injection";state.speed100=0;state.backend=azsg::BackendState::ready;
    text=azsg::diagnostics_json(state);
    check(text.find("injection")==std::string::npos && text.find("\"speed100\":100")!=std::string::npos,"report enum/rate values are bounded");
    write(report,"unrelated user file");
    check(!azsg::write_diagnostics(root,state) && read(report)=="unrelated user file","unowned report not replaced");
    fs::remove(report);write(report,azsg::diagnostics_json(state));
    const auto alias=root/L"keep.json";
    check(CreateHardLinkW(alias.c_str(),report.c_str(),nullptr)!=0,"hard-link fixture created");
    check(!azsg::write_diagnostics(root,state),"hard-linked destination refused");
    fs::remove(alias);fs::remove(report);fs::create_directory(report);
    check(!azsg::write_diagnostics(root,state),"directory destination refused");
    check(!azsg::write_diagnostics(fs::path("relative-game-root"),state),"relative root refused");
    fs::remove_all(root);
    std::cout<<checks<<" checks, "<<failed<<" failures\n";return failed?1:0;
}
