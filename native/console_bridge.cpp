#include <windows.h>
#include <algorithm>
#include <array>
#include <atomic>
#include <condition_variable>
#include <cstring>
#include <memory>
#include <mutex>
#include <new>
#include <string>
#include "console_bridge.h"
#include "command_gate.h"

namespace {
constexpr std::size_t chunk_capacity = 4096;
std::atomic<std::uint64_t> dropped_bytes{0};

class OwnedHandle {
public:
    explicit OwnedHandle(HANDLE value=INVALID_HANDLE_VALUE) noexcept : value_(value) {}
    ~OwnedHandle() { if(valid()) CloseHandle(value_); }
    OwnedHandle(const OwnedHandle&)=delete;
    OwnedHandle& operator=(const OwnedHandle&)=delete;
    HANDLE get() const noexcept { return value_; }
    bool valid() const noexcept { return value_ && value_!=INVALID_HANDLE_VALUE; }
    HANDLE release() noexcept { auto value=value_;value_=INVALID_HANDLE_VALUE;return value; }
    void reset(HANDLE value) noexcept {
        if(valid()) CloseHandle(value_);
        value_=value;
    }
private:
    HANDLE value_;
};

struct Capture {
    OwnedHandle read,original;
    void(*receive)(std::string_view)=nullptr;
    std::mutex mutex;
    std::condition_variable ready;
    std::array<char,azsg::console_bridge_queue_capacity> queue{};
    std::size_t head=0,size=0;
    bool reader_finished=false,forwarding_enabled=false,forwarding_failed=false;
    std::uint64_t forwarded=0,overflow=0,failed_bytes=0;
};

// Only installation/snapshot operations take this lock. Neither worker takes
// it; a writer can remain blocked without pinning any parser or snapshot lock.
std::mutex captures_mutex;
std::array<std::shared_ptr<Capture>,2> captures;
using ThreadArgument=std::shared_ptr<Capture>;

void enqueue(const std::shared_ptr<Capture>& capture,const char* bytes,std::size_t count) {
    {
        std::lock_guard<std::mutex> guard(capture->mutex);
        if(!capture->forwarding_enabled) {
            if(capture->forwarding_failed) {
                capture->failed_bytes+=count;
                dropped_bytes.fetch_add(count,std::memory_order_relaxed);
            }
            return;
        }
        // ReadFile is bounded to chunk_capacity, so count always fits the ring.
        const auto capacity=capture->queue.size();
        if(capture->size+count>capacity) {
            const auto discard=capture->size+count-capacity;
            capture->head=(capture->head+discard)%capacity;
            capture->size-=discard;
            capture->overflow+=discard;
            dropped_bytes.fetch_add(discard,std::memory_order_relaxed);
        }
        const auto tail=(capture->head+capture->size)%capacity;
        const auto first=(std::min)(count,capacity-tail);
        std::memcpy(capture->queue.data()+tail,bytes,first);
        std::memcpy(capture->queue.data(),bytes+first,count-first);
        capture->size+=count;
    }
    capture->ready.notify_one();
}

DWORD WINAPI forward_console(void* value) {
    std::unique_ptr<ThreadArgument> argument(static_cast<ThreadArgument*>(value));
    const auto capture=*argument;
    std::array<char,chunk_capacity> bytes{};
    while(true) {
        std::size_t count=0;
        {
            std::unique_lock<std::mutex> guard(capture->mutex);
            capture->ready.wait(guard,[&]{return capture->size || capture->reader_finished;});
            if(!capture->size && capture->reader_finished) return 0;
            count=(std::min)(capture->size,bytes.size());
            const auto first=(std::min)(count,capture->queue.size()-capture->head);
            std::memcpy(bytes.data(),capture->queue.data()+capture->head,first);
            std::memcpy(bytes.data()+first,capture->queue.data(),count-first);
            capture->head=(capture->head+count)%capture->queue.size();
            capture->size-=count;
        }
        DWORD offset=0;
        while(offset<count) {
            DWORD written=0;
            // Intentionally outside every mutex. A full inherited pipe or slow
            // console blocks only this channel's forwarder and its 4KiB chunk.
            const bool ok=WriteFile(capture->original.get(),bytes.data()+offset,
                                    static_cast<DWORD>(count-offset),&written,nullptr)!=FALSE;
            const bool valid_count=written<=count-offset;
            if(valid_count && written) {
                offset+=written;
                std::lock_guard<std::mutex> guard(capture->mutex);
                capture->forwarded+=written;
            }
            if(!ok || !written || !valid_count) {
                std::lock_guard<std::mutex> guard(capture->mutex);
                const auto lost=count-offset+capture->size;
                capture->failed_bytes+=lost;
                dropped_bytes.fetch_add(lost,std::memory_order_relaxed);
                capture->size=0;capture->head=0;
                capture->forwarding_enabled=false;capture->forwarding_failed=true;
                return 0;
            }
        }
    }
}

DWORD WINAPI read_console(void* value) {
    std::unique_ptr<ThreadArgument> argument(static_cast<ThreadArgument*>(value));
    const auto capture=*argument;
    char bytes[chunk_capacity];DWORD count=0;
    std::string line;bool oversized=false;
    while(ReadFile(capture->read.get(),bytes,sizeof(bytes),&count,nullptr) && count) {
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
        enqueue(capture,bytes,count);
    }
    {
        std::lock_guard<std::mutex> guard(capture->mutex);
        capture->reader_finished=true;
    }
    capture->ready.notify_one();
    return 0;
}

bool capture(DWORD channel,std::size_t slot,void(*receive)(std::string_view)) {
    if(captures[slot]) return true;
    const auto state=std::make_shared<Capture>();
    state->receive=receive;
    // Duplicate BEFORE creating pipes: an invalid/stale std-handle value cannot
    // accidentally be reused by our new pipe and turn forwarding into a loop.
    const auto original=GetStdHandle(channel);
    if(original && original!=INVALID_HANDLE_VALUE) {
        HANDLE duplicate=INVALID_HANDLE_VALUE;
        if(!DuplicateHandle(GetCurrentProcess(),original,GetCurrentProcess(),&duplicate,
                            0,FALSE,DUPLICATE_SAME_ACCESS)) return false;
        state->original.reset(duplicate);
        state->forwarding_enabled=true;
    }
    HANDLE input=INVALID_HANDLE_VALUE,output=INVALID_HANDLE_VALUE;
    if(!CreatePipe(&input,&output,nullptr,65536)) return false;
    state->read.reset(input);
    OwnedHandle output_handle(output);
    // Allocate all arguments before creating a worker, so allocation failure
    // cannot strand a waiting thread with an unpublished capture.
    auto read_argument=std::unique_ptr<ThreadArgument>(new(std::nothrow) ThreadArgument(state));
    auto write_argument=std::unique_ptr<ThreadArgument>(new(std::nothrow) ThreadArgument(state));
    if(!read_argument || !write_argument) return false;
    if(state->forwarding_enabled) {
        const auto writer=CreateThread(nullptr,0,forward_console,write_argument.get(),0,nullptr);
        if(!writer) return false;
        write_argument.release();CloseHandle(writer);
    }
    const auto reader=CreateThread(nullptr,0,read_console,read_argument.get(),0,nullptr);
    if(!reader) {
        {
            std::lock_guard<std::mutex> guard(state->mutex);
            state->reader_finished=true;
        }
        state->ready.notify_one();
        return false;
    }
    read_argument.release();CloseHandle(reader);
    // Publish only after both workers exist. On failure the still-owned output
    // handle closes, ReadFile reaches EOF and the forwarder is woken to exit.
    if(!SetStdHandle(channel,output)) return false;
    output_handle.release();
    captures[slot]=state;
    // Installed write handles and at most two workers per channel intentionally
    // live until process exit. No thread is forcibly terminated or detached
    // from storage it still uses; failed starts retain no dangling reader state.
    return true;
}
}
bool azsg::start_console_bridge(void(*receive)(std::string_view)) {
    if(!receive) return false;
    std::lock_guard<std::mutex> guard(captures_mutex);
    bool out=false,error=false;
    try {out=capture(STD_OUTPUT_HANDLE,0,receive);} catch(...) {}
    try {error=capture(STD_ERROR_HANDLE,1,receive);} catch(...) {}
    return out || error;
}

azsg::ConsoleBridgeStats azsg::console_bridge_stats() {
    ConsoleBridgeStats result;
    std::lock_guard<std::mutex> guard(captures_mutex);
    for(const auto& capture:captures) {
        if(!capture) continue;
        std::lock_guard<std::mutex> channel_guard(capture->mutex);
        ++result.installed_channels;
        result.queued_bytes+=capture->size;
        result.forwarded_bytes+=capture->forwarded;
        result.overflow_dropped_bytes+=capture->overflow;
        result.forwarding_error_bytes+=capture->failed_bytes;
    }
    return result;
}

std::uint64_t azsg::console_bridge_dropped_bytes() noexcept {
    return dropped_bytes.load(std::memory_order_relaxed);
}
