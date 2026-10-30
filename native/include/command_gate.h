#pragma once
#include "command.h"
#include <algorithm>
#include <array>
#include <string>

namespace azsg {
enum class CommandSource { file, console };

// Shared by both transports. A delayed file must never undo a newer console request.
// Call under the backend's command mutex; all deadlines use the unhooked clock.
class CommandGate {
public:
    std::optional<unsigned> accept(std::string_view text,CommandSource source,
                                   std::uint64_t unix_now,std::uint64_t millis) {
        auto next=parse_command(text);
        if(!next) return {};
        if((next->unix_seconds>unix_now && next->unix_seconds-unix_now>2) ||
           (unix_now>next->unix_seconds && unix_now-next->unix_seconds>8)) return {};
        if(current_ && next->session==current_->session) {
            if(next->sequence<current_->sequence) return {};
            if(next->sequence==current_->sequence) {
                // A synchronous query of the exact current CVar is a live pulse.
                // Re-reading a file cannot keep the watchdog alive. Allow only
                // its first exact, fresh echo to bridge a lost-console handoff:
                // at 0.25x the game's save debounce can take four real seconds.
                if(live_ && source==CommandSource::console && text==payload_) {
                    last_beat_=millis;last_console_=millis;source_=source;
                } else if(live_ && source==CommandSource::file && text==payload_ && !file_echo_seen_) {
                    file_echo_seen_=true;
                    if(source_==CommandSource::console && !console_healthy(millis)) {
                        last_beat_=millis;source_=CommandSource::file;
                    }
                }
                return {};
            }
        }
        if(!current_ || next->session!=current_->session) {
            if(std::find(retired_.begin(),retired_.end(),next->session)!=retired_.end()) return {};
            if(current_) retired_[retired_index_++%retired_.size()]=current_->session;
        }
        current_=next;payload_=text;last_beat_=millis;live_=true;source_=source;
        file_echo_seen_=source==CommandSource::file;
        if(source==CommandSource::console) last_console_=millis;
        return next->active?next->speed100:100u;
    }
    bool expire(std::uint64_t millis) {
        if(live_ && millis>=last_beat_ && millis-last_beat_>8000) {live_=false;return true;}
        return false;
    }
    bool console_healthy(std::uint64_t millis) const noexcept {
        return live_ && source_==CommandSource::console && millis>=last_console_ && millis-last_console_<=2500;
    }
    const char* transport(std::uint64_t millis) const noexcept {
        if(!current_) return "waiting";
        if(!live_) return "stale";
        if(source_==CommandSource::file) return "file";
        return console_healthy(millis)?"console":"degraded";
    }
    std::optional<std::uint64_t> heartbeat_age(std::uint64_t millis) const noexcept {
        if(!current_) return {};
        return millis>=last_beat_?millis-last_beat_:0;
    }
private:
    std::optional<Command> current_;
    std::string payload_;
    std::array<std::uint64_t,64> retired_{};
    std::size_t retired_index_=0;
    std::uint64_t last_beat_=0;
    std::uint64_t last_console_=0;
    CommandSource source_=CommandSource::file;
    bool live_=false;
    bool file_echo_seen_=false;
};

// Keep watchdog checks frequent; throttle only the fallback file IO. A missing
// console pulse returns to 100ms polling without waiting for the 8s watchdog.
class FallbackPoller {
public:
    bool due(std::uint64_t millis,bool console_healthy) noexcept {
        const std::uint64_t interval=console_healthy?1000:100;
        if(!last_ || millis<*last_ || millis-*last_>=interval) {last_=millis;return true;}
        return false;
    }
private:
    std::optional<std::uint64_t> last_;
};

inline std::optional<std::string_view> console_command(std::string_view line) {
    constexpr std::string_view prefix="console: CVar \"", key="azsspeedgearcommand", between="\" is \"";
    auto at=line.find(prefix);if(at==std::string_view::npos) return {};
    line.remove_prefix(at+prefix.size());
    if(line.size()<key.size()+between.size()) return {};
    for(std::size_t n=0;n<key.size();++n) {
        auto ch=line[n];if(ch>='A' && ch<='Z') ch=static_cast<char>(ch-'A'+'a');
        if(ch!=key[n]) return {};
    }
    line.remove_prefix(key.size());
    if(line.substr(0,between.size())!=between) return {};
    line.remove_prefix(between.size());
    auto end=line.find('"');if(end==std::string_view::npos || end>128) return {};
    auto payload=line.substr(0,end);
    if(!parse_command(payload)) return {};
    return payload;
}
}
