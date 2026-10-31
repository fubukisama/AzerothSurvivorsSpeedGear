#include <windows.h>
#include <array>
#include <string_view>
#include "diagnostics.h"

namespace {
constexpr std::string_view signature="{\"product\":\"AzerothSurvivorsSpeedGear\",\"schema\":1,";
const char* backend_name(azsg::BackendState state) {
    switch(state) {
    case azsg::BackendState::ready:return "ready";
    case azsg::BackendState::unsupported:return "unsupported";
    case azsg::BackendState::hooks_failed:return "hooks_failed";
    default:return "initializing";
    }
}
bool safe_path(const std::filesystem::path& path) {
    if(!path.is_absolute()) return false;
    std::filesystem::path current;
    for(const auto& component:path) {
        current/=component;
        const auto attributes=GetFileAttributesW(current.c_str());
        if(attributes==INVALID_FILE_ATTRIBUTES) {
            const auto error=GetLastError();
            return error==ERROR_FILE_NOT_FOUND || error==ERROR_PATH_NOT_FOUND;
        }
        if(attributes&FILE_ATTRIBUTE_REPARSE_POINT) return false;
    }
    return true;
}
bool owned_report(const std::filesystem::path& path) {
    auto handle=CreateFileW(path.c_str(),GENERIC_READ,FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE,
                            nullptr,OPEN_EXISTING,FILE_FLAG_OPEN_REPARSE_POINT,nullptr);
    if(handle==INVALID_HANDLE_VALUE) return GetLastError()==ERROR_FILE_NOT_FOUND;
    BY_HANDLE_FILE_INFORMATION information{};std::array<char,128> bytes{};DWORD count=0;
    const bool owned=GetFileInformationByHandle(handle,&information) &&
        !(information.dwFileAttributes&(FILE_ATTRIBUTE_DIRECTORY|FILE_ATTRIBUTE_REPARSE_POINT)) &&
        information.nNumberOfLinks==1 && information.nFileSizeHigh==0 && information.nFileSizeLow<16384 &&
        ReadFile(handle,bytes.data(),static_cast<DWORD>(signature.size()),&count,nullptr) &&
        count==signature.size() && std::string_view(bytes.data(),count)==signature;
    CloseHandle(handle);return owned;
}
}

std::string azsg::diagnostics_json(const Diagnostics& state) {
    constexpr std::array<std::string_view,6> modes{"waiting","console","file","degraded","stale","disabled"};
    std::string_view mode="waiting";
    for(const auto candidate:modes) if(candidate==state.transport) mode=candidate;
    if(state.backend!=BackendState::ready) mode="disabled";
    const auto rate=state.speed100>=25 && state.speed100<=1000?state.speed100:100;
    return std::string(signature)+"\"version\":\"0.7.3\",\"updatedUnix\":"+std::to_string(state.updated_unix)+
        ",\"backend\":\""+backend_name(state.backend)+"\",\"transport\":\""+std::string(mode)+
        "\",\"speed100\":"+std::to_string(rate)+",\"heartbeatAgeMs\":"+
        (state.heartbeat_age_ms?std::to_string(*state.heartbeat_age_ms):"null")+
        ",\"fileReads\":"+std::to_string(state.file_reads)+",\"consoleForwardDroppedBytes\":"+
        std::to_string(state.dropped_bytes)+"}\n";
}

bool azsg::write_diagnostics(const std::filesystem::path& root,const Diagnostics& state) noexcept {
    try {
        const auto runtime=root/L"benilla-config"/L"AZSSpeedGear-runtime";
        const auto staging=runtime/L"Status.tmp",destination=root/L"AZSSpeedGear-status.json";
        if(!safe_path(root) || !safe_path(runtime) || !safe_path(staging) ||
           !safe_path(destination) || !owned_report(destination)) return false;
        if(!CreateDirectoryW(runtime.c_str(),nullptr) && GetLastError()!=ERROR_ALREADY_EXISTS) return false;
        if(!safe_path(runtime) || !safe_path(staging)) return false;
        const auto attributes=GetFileAttributesW(staging.c_str());
        if(attributes!=INVALID_FILE_ATTRIBUTES && ((attributes&FILE_ATTRIBUTE_DIRECTORY) || !DeleteFileW(staging.c_str()))) return false;
        auto output=CreateFileW(staging.c_str(),GENERIC_WRITE,0,nullptr,CREATE_NEW,
                               FILE_ATTRIBUTE_NORMAL|FILE_FLAG_OPEN_REPARSE_POINT,nullptr);
        if(output==INVALID_HANDLE_VALUE) return false;
        const auto bytes=diagnostics_json(state);DWORD count=0;
        const bool complete=WriteFile(output,bytes.data(),static_cast<DWORD>(bytes.size()),&count,nullptr) && count==bytes.size();
        CloseHandle(output);
        if(complete && safe_path(destination) && owned_report(destination) && safe_path(staging) &&
           MoveFileExW(staging.c_str(),destination.c_str(),MOVEFILE_REPLACE_EXISTING|MOVEFILE_WRITE_THROUGH)) return true;
        DeleteFileW(staging.c_str());return false;
    } catch(...) {return false;}
}
