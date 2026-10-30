// Run only in remote Windows CI. Links the production console_bridge.cpp without
// loading a game, MinHook, or the installed dwmapi.dll. All pipes are test-owned.
#include <windows.h>
#include <algorithm>
#include <atomic>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>
#include "command.h"
#include "console_bridge.h"

namespace {
std::atomic<std::uint64_t> commands{0},last_sequence{0};
HANDLE report_output=INVALID_HANDLE_VALUE;

void report(const std::string& text) {
    DWORD written=0;
    if(report_output && report_output!=INVALID_HANDLE_VALUE)
        WriteFile(report_output,text.data(),static_cast<DWORD>(text.size()),&written,nullptr);
}
void receive(std::string_view payload) {
    if(const auto parsed=azsg::parse_command(payload)) {
        last_sequence.store(parsed->sequence,std::memory_order_relaxed);
        commands.fetch_add(1,std::memory_order_relaxed);
    }
}
std::string command(std::uint64_t sequence) {
    return "console: CVar \"AZSSpeedGearCommand\" is \"SG1|1|"+
           std::to_string(sequence)+"|1|500|1\"\r\n";
}
bool write_all(HANDLE handle,const std::string& bytes) {
    std::size_t offset=0;
    while(offset<bytes.size()) {
        DWORD written=0;
        if(!WriteFile(handle,bytes.data()+offset,static_cast<DWORD>(bytes.size()-offset),
                      &written,nullptr) || !written) return false;
        offset+=written;
    }
    return true;
}
bool wait_for_count(std::uint64_t expected,DWORD milliseconds) {
    const auto deadline=GetTickCount64()+milliseconds;
    while(GetTickCount64()<deadline) {
        if(commands.load(std::memory_order_relaxed)>=expected) return true;
        Sleep(1);
    }
    return commands.load(std::memory_order_relaxed)>=expected;
}

struct ReadState {
    HANDLE handle=INVALID_HANDLE_VALUE;
    std::size_t expected=0;
    std::string bytes;
    bool ok=true;
};
DWORD WINAPI read_normal(void* pointer) {
    std::unique_ptr<std::shared_ptr<ReadState>> argument(
        static_cast<std::shared_ptr<ReadState>*>(pointer));
    const auto state=*argument;
    char buffer[4096];
    while(state->bytes.size()<state->expected) {
        DWORD count=0;
        const auto wanted=static_cast<DWORD>((std::min)(
            sizeof(buffer),state->expected-state->bytes.size()));
        if(!ReadFile(state->handle,buffer,wanted,&count,nullptr) || !count) {
            state->ok=false;return 0;
        }
        state->bytes.append(buffer,count);
    }
    return 0;
}
struct ProducerState {
    HANDLE handle=INVALID_HANDLE_VALUE;
    std::uint64_t count=0;
    bool ok=true;
};
DWORD WINAPI produce(void* pointer) {
    std::unique_ptr<std::shared_ptr<ProducerState>> argument(
        static_cast<std::shared_ptr<ProducerState>*>(pointer));
    const auto state=*argument;
    for(std::uint64_t index=2;index<=state->count+1;++index) {
        if(!write_all(state->handle,command(index))) {state->ok=false;break;}
    }
    return 0;
}
struct FillState {
    HANDLE handle=INVALID_HANDLE_VALUE;
    std::string bytes=std::string(1024*1024,'B');
};
DWORD WINAPI fill_original(void* pointer) {
    std::unique_ptr<std::shared_ptr<FillState>> argument(
        static_cast<std::shared_ptr<FillState>*>(pointer));
    write_all((*argument)->handle,(*argument)->bytes);
    return 0;
}
} // namespace

int main() {
    // Reporting bypasses the deliberately blocked stdout installed below.
    if(!DuplicateHandle(GetCurrentProcess(),GetStdHandle(STD_OUTPUT_HANDLE),
                        GetCurrentProcess(),&report_output,0,FALSE,DUPLICATE_SAME_ACCESS))
        return 2;
    unsigned checks=0,failures=0;
    auto check=[&](bool value,const char* description) {
        ++checks;
        if(!value) {++failures;report(std::string("FAIL: ")+description+"\n");}
    };
    HANDLE blocked_read=INVALID_HANDLE_VALUE,blocked_write=INVALID_HANDLE_VALUE;
    HANDLE normal_read=INVALID_HANDLE_VALUE,normal_write=INVALID_HANDLE_VALUE;
    if(!CreatePipe(&blocked_read,&blocked_write,nullptr,4096) ||
       !CreatePipe(&normal_read,&normal_write,nullptr,4096)) {
        report("FAIL: create fixture pipes\n");return 2;
    }
    // A separate producer attempts far more than the original pipe's 4KiB
    // requested quota. Never risk blocking the assertion thread during setup.
    // Its read end is retained but NEVER drained throughout the regression.
    const auto filler=std::make_shared<FillState>();filler->handle=blocked_write;
    auto* filler_argument=new std::shared_ptr<FillState>(filler);
    const auto filler_thread=CreateThread(nullptr,0,fill_original,filler_argument,0,nullptr);
    if(!filler_thread) {delete filler_argument;report("FAIL: original pipe filler\n");return 2;}
    DWORD initial_available=0;
    const auto fill_deadline=GetTickCount64()+3000;
    while(GetTickCount64()<fill_deadline) {
        if(PeekNamedPipe(blocked_read,nullptr,0,nullptr,&initial_available,nullptr) &&
           initial_available && WaitForSingleObject(filler_thread,0)==WAIT_TIMEOUT) break;
        Sleep(1);
    }
    Sleep(50);
    if(!initial_available || WaitForSingleObject(filler_thread,0)!=WAIT_TIMEOUT ||
       !SetStdHandle(STD_OUTPUT_HANDLE,blocked_write) ||
       !SetStdHandle(STD_ERROR_HANDLE,normal_write)) {
        report("FAIL: prepare blocked original output\n");return 2;
    }
    check(azsg::start_console_bridge(receive),"bridge starts");
    const auto installed_out=GetStdHandle(STD_OUTPUT_HANDLE);
    const auto installed_error=GetStdHandle(STD_ERROR_HANDLE);
    check(azsg::start_console_bridge(receive),"repeated start succeeds");
    check(GetStdHandle(STD_OUTPUT_HANDLE)==installed_out &&
          GetStdHandle(STD_ERROR_HANDLE)==installed_error,"repeated start does not nest pipes");

    const std::string normal_payload=std::string("normal output: alpha\r\nbeta\n")+
        std::string("binary\0tail",11)+"\nUTF-8: \xE6\xB5\x8B\xE8\xAF\x95\n";
    const auto normal=std::make_shared<ReadState>();
    normal->handle=normal_read;normal->expected=normal_payload.size();
    auto* normal_argument=new std::shared_ptr<ReadState>(normal);
    const auto normal_thread=CreateThread(nullptr,0,read_normal,normal_argument,0,nullptr);
    if(!normal_thread) {delete normal_argument;report("FAIL: normal output reader\n");return 2;}
    check(write_all(installed_error,normal_payload),"normal stderr writes");
    const auto normal_done=WaitForSingleObject(normal_thread,5000);
    check(normal_done==WAIT_OBJECT_0,"normal stderr forwarder finishes");
    if(normal_done==WAIT_OBJECT_0)
        check(normal->ok && normal->bytes==normal_payload,"normal forwarding preserves every byte");

    check(write_all(installed_out,command(1)),"first command writes");
    check(wait_for_count(1,3000),"first command parsed before original write blocks");
    Sleep(50);
    const auto producer=std::make_shared<ProducerState>();
    producer->handle=installed_out;producer->count=20000;
    auto* producer_argument=new std::shared_ptr<ProducerState>(producer);
    const auto producer_thread=CreateThread(nullptr,0,produce,producer_argument,0,nullptr);
    if(!producer_thread) {delete producer_argument;report("FAIL: command producer\n");return 2;}
    const auto producer_done=WaitForSingleObject(producer_thread,10000);
    check(producer_done==WAIT_OBJECT_0,"blocked original does not block new command writes");
    if(producer_done==WAIT_OBJECT_0) check(producer->ok,"all command writes complete");
    check(wait_for_count(producer->count+1,3000),"all commands parsed while original stays blocked");
    check(last_sequence.load(std::memory_order_relaxed)==producer->count+1,
          "latest command reaches callback under log backpressure");
    DWORD available=0;
    check(PeekNamedPipe(blocked_read,nullptr,0,nullptr,&available,nullptr)!=FALSE &&
          available>=initial_available && WaitForSingleObject(filler_thread,0)==WAIT_TIMEOUT,
          "original pipe remains blocked throughout regression");
    if(normal_done==WAIT_OBJECT_0) {
        // A permanently failed original output must also stop consuming queue
        // memory, and its unforwarded bytes must reach the public diagnostic.
        CloseHandle(normal_read);normal_read=INVALID_HANDLE_VALUE;
        const std::string after_close="after original stderr closed\n";
        const auto before=azsg::console_bridge_stats().forwarding_error_bytes;
        check(write_all(installed_error,after_close),"closed original does not block captured stderr");
        const auto deadline=GetTickCount64()+3000;
        while(GetTickCount64()<deadline &&
              azsg::console_bridge_stats().forwarding_error_bytes<before+after_close.size()) Sleep(1);
        check(azsg::console_bridge_stats().forwarding_error_bytes>=before+after_close.size(),
              "failed original output counts discarded bytes");
    }
    const auto stats=azsg::console_bridge_stats();
    check(stats.installed_channels==2,"stdout and stderr each captured once");
    check(stats.queued_bytes<=2*azsg::console_bridge_queue_capacity,"log queue stays bounded");
    check(stats.overflow_dropped_bytes>0,"bounded overload uses explicit oldest-log discard");
    check(azsg::console_bridge_dropped_bytes()>=stats.overflow_dropped_bytes,
          "public dropped-byte counter includes overflow");
    report("console_bridge checks="+std::to_string(checks)+" failures="+
           std::to_string(failures)+" commands="+
           std::to_string(commands.load(std::memory_order_relaxed))+" queued="+
           std::to_string(stats.queued_bytes)+" dropped="+
           std::to_string(azsg::console_bridge_dropped_bytes())+"\n");

    // Close fixture read ends to release any blocked forwarder. Thread storage
    // is shared-owned, including red paths where the producer itself is blocked.
    CloseHandle(blocked_read);
    if(normal_read!=INVALID_HANDLE_VALUE) CloseHandle(normal_read);
    CancelSynchronousIo(filler_thread);
    if(producer_done!=WAIT_OBJECT_0) CancelSynchronousIo(producer_thread);
    if(normal_done!=WAIT_OBJECT_0) CancelSynchronousIo(normal_thread);
    CloseHandle(filler_thread);CloseHandle(producer_thread);CloseHandle(normal_thread);
    // Capture threads and installed pipe handles are intentionally process-life.
    // Avoid running unrelated CRT flushing against the controlled std handles.
    ExitProcess(failures?1u:0u);
}
