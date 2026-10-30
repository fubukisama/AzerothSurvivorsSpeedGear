#include <windows.h>
#include <memory>
#include <string>
#include "console_bridge.h"
#include "command_gate.h"

namespace {
struct Capture {
    HANDLE read=nullptr,original=nullptr;
    void(*receive)(std::string_view)=nullptr;
};
DWORD WINAPI read_console(void* value) {
    std::unique_ptr<Capture> capture(static_cast<Capture*>(value));
    char bytes[4096];DWORD count=0;
    std::string line;bool oversized=false;
    while(ReadFile(capture->read,bytes,sizeof(bytes),&count,nullptr) && count) {
        for(DWORD n=0;n<count;++n) {
            if(bytes[n]=='\n') {
                if(!oversized) {
                    if(auto command=azsg::console_command(line)) capture->receive(*command);
                }
                line.clear();oversized=false;
            } else if(!oversized) {
                if(line.size()<4096) line+=bytes[n];else {line.clear();oversized=true;}
            }
        }
        if(capture->original && capture->original!=INVALID_HANDLE_VALUE) {
            DWORD offset=0,written=0;
            while(offset<count && WriteFile(capture->original,bytes+offset,count-offset,&written,nullptr) && written) offset+=written;
        }
    }
    CloseHandle(capture->read);
    return 0;
}
bool capture(DWORD channel,void(*receive)(std::string_view)) {
    HANDLE input=nullptr,output=nullptr;
    if(!CreatePipe(&input,&output,nullptr,65536)) return false;
    auto original=GetStdHandle(channel);
    if(!SetStdHandle(channel,output)) {CloseHandle(input);CloseHandle(output);return false;}
    auto state=std::make_unique<Capture>();state->read=input;state->original=original;state->receive=receive;
    auto thread=CreateThread(nullptr,0,read_console,state.get(),0,nullptr);
    if(!thread) {
        SetStdHandle(channel,original);CloseHandle(input);CloseHandle(output);return false;
    }
    state.release();CloseHandle(thread);
    // Windows closes the installed write handle when the process exits.
    return true;
}
}
bool azsg::start_console_bridge(void(*receive)(std::string_view)) {
    auto out=capture(STD_OUTPUT_HANDLE,receive);
    auto error=capture(STD_ERROR_HANDLE,receive);
    return out || error;
}
