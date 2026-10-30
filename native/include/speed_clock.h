#pragma once

#include <cstdint>
#include <limits>

namespace azsg {

// Extend an unsigned wrapping millisecond API without changing its native
// resolution or origin. Sample under the same lock that protects VirtualClock;
// the real API must be monotonic modulo 2^32 and sampled at least once per wrap.
class WrappingCounter32 {
public:
    std::uint64_t sample(std::uint32_t raw) noexcept {
        if (!initialized_) {
            previous_ = raw;
            extended_ = raw;
            initialized_ = true;
            return extended_;
        }
        const auto delta = static_cast<std::uint32_t>(raw - previous_);
        previous_ = raw;
        constexpr auto limit = std::numeric_limits<std::uint64_t>::max();
        if (delta > limit - extended_) extended_ = limit;
        else extended_ += delta;
        return extended_;
    }
private:
    std::uint32_t previous_ = 0;
    std::uint64_t extended_ = 0;
    bool initialized_ = false;
};

// Integer version of the continuous-clock approach used by AZS Speed Controller
// (MIT, AZS Speed Controller contributors). The caller must hold its clock lock
// BEFORE reading real time. This class deliberately performs no synchronization.
class VirtualClock {
public:
    static constexpr std::uint32_t minimum_speed100 = 25;
    static constexpr std::uint32_t maximum_speed100 = 1000;

    // A new clock starts in the real clock's coordinate system, without a jump.
    std::uint64_t sample(std::uint64_t real_now) noexcept {
        if (!initialized_) {
            real_ = virtual_ = real_now;
            initialized_ = true;
            return virtual_;
        }
        // Keep the high-water mark. Moving it backwards would count an interval
        // twice when an old or anomalous sample is followed by a current sample.
        if (real_now <= real_) {
            return virtual_;
        }
        const auto delta = real_now - real_;
        real_ = real_now;

        // Split BEFORE multiplication: delta * speed100 can overflow even when
        // the final quotient is representable. Carry hundredths between reads.
        constexpr auto limit = std::numeric_limits<std::uint64_t>::max();
        const auto whole_hundreds = delta / 100;
        const auto fraction = (delta % 100) * speed100_ + remainder_;
        if (whole_hundreds > limit / speed100_) {
            virtual_ = limit;
            remainder_ = 0;
            return virtual_;
        }
        const auto scaled_whole = whole_hundreds * speed100_;
        const auto scaled_fraction = fraction / 100;
        if (scaled_whole > limit - scaled_fraction) {
            virtual_ = limit;
            remainder_ = 0;
            return virtual_;
        }
        const auto increment = scaled_whole + scaled_fraction;
        if (increment > limit - virtual_) {
            virtual_ = limit;
            remainder_ = 0;
            return virtual_;
        }
        virtual_ += increment;
        remainder_ = static_cast<std::uint32_t>(fraction % 100);
        return virtual_;
    }

    std::uint64_t advance(std::uint64_t real_now) noexcept {
        return sample(real_now);
    }

    // Settle elapsed time at the OLD rate, then apply the new rate. If an
    // anomalous timestamp goes backwards, the change starts at the high-water
    // mark rather than rewriting elapsed history. Invalid rates do nothing.
    bool set_speed(std::uint64_t real_now, std::uint32_t speed100) noexcept {
        if (speed100 < minimum_speed100 || speed100 > maximum_speed100) {
            return false;
        }
        sample(real_now);
        speed100_ = speed100;
        return true;
    }

    std::uint32_t speed100() const noexcept { return speed100_; }
    bool initialized() const noexcept { return initialized_; }

private:
    std::uint64_t real_ = 0;
    std::uint64_t virtual_ = 0;
    std::uint32_t speed100_ = 100;
    std::uint32_t remainder_ = 0;
    bool initialized_ = false;
};

} // namespace azsg
