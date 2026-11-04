#pragma once

#include <atomic>
#include <cstdint>
#include <limits>
#include <thread>
#include "speed_clock.h"

namespace azsg {

// QPC readers share an immutable affine epoch, not the backend's clock mutex.
// Writers are externally serialized. An odd generation closes reader entry;
// draining accepted readers BEFORE reading the transition clock preserves its
// high-water/fraction semantics, including counter rollback around a change.
class QpcSnapshot {
public:
    struct Epoch {
        std::uint64_t real=0,virtual_time=0;
        std::uint32_t speed100=100,remainder=0;
        bool initialized=false;
    };

    static std::uint64_t evaluate(const Epoch& epoch,std::uint64_t real_now) noexcept {
        if(real_now<=epoch.real) return epoch.virtual_time;
        const auto delta=real_now-epoch.real;
        constexpr auto limit=std::numeric_limits<std::uint64_t>::max();
        const auto whole_hundreds=delta/100;
        const auto fraction=(delta%100)*epoch.speed100+epoch.remainder;
        if(epoch.speed100 && whole_hundreds>limit/epoch.speed100) return limit;
        const auto whole=whole_hundreds*epoch.speed100,part=fraction/100;
        if(whole>limit-part) return limit;
        const auto increment=whole+part;
        if(increment>limit-epoch.virtual_time) return limit;
        return epoch.virtual_time+increment;
    }

    void begin_update() noexcept {
        // Sequential consistency matters for the reader-entry handshake:
        // a reader cannot see the old generation while the writer also misses
        // its entry count and starts modifying the plain immutable fields.
        generation_.fetch_add(1);
        while(active_.load()!=0) std::this_thread::yield();
    }

    // Call only after begin_update, and after all backend clock/rate writes.
    void publish(const VirtualClock& clock) noexcept {
        epoch_={clock.real_anchor(),clock.virtual_anchor(),clock.speed100(),
                clock.fractional_remainder(),clock.initialized()};
        maximum(high_water_real_,epoch_.real);
        maximum(high_water_virtual_,epoch_.virtual_time);
        generation_.fetch_add(1);
    }

    std::uint64_t observed_real() const noexcept { return high_water_real_.load(); }
    bool updating() const noexcept { return (generation_.load()&1)!=0; }

    template<class ReadReal>
    bool read(ReadReal&& read_real,std::uint64_t& output) noexcept {
        for(;;) {
            const auto generation=generation_.load();
            if(generation&1) {std::this_thread::yield();continue;}
            active_.fetch_add(1);
            if(generation_.load()!=generation) {active_.fetch_sub(1);continue;}
            // A writer now waits for this reader. Finish this old epoch even
            // if it becomes odd; retrying while counted would deadlock it.
            if(!epoch_.initialized) {active_.fetch_sub(1);return false;}
            std::uint64_t actual=0;
            if(!read_real(actual)) {active_.fetch_sub(1);return false;}
            const auto real=maximum(high_water_real_,actual);
            output=maximum(high_water_virtual_,evaluate(epoch_,real));
            active_.fetch_sub(1);
            return true;
        }
    }

private:
    static_assert(std::atomic<std::uint64_t>::is_always_lock_free,
                  "The native x64 QPC path requires lock-free 64-bit atomics");
    static std::uint64_t maximum(std::atomic<std::uint64_t>& counter,std::uint64_t value) noexcept {
        auto previous=counter.load(std::memory_order_relaxed);
        while(previous<value && !counter.compare_exchange_weak(previous,value,
              std::memory_order_relaxed,std::memory_order_relaxed)) {}
        return previous>value?previous:value;
    }

    alignas(64) std::atomic<std::uint64_t> generation_{0};
    alignas(64) std::atomic<unsigned> active_{0};
    alignas(64) std::atomic<std::uint64_t> high_water_real_{0};
    std::atomic<std::uint64_t> high_water_virtual_{0};
    alignas(64) Epoch epoch_{};
};

} // namespace azsg
