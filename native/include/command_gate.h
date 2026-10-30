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
                // Re-reading a file is never evidence that Lua is still running.
                if(live_ && source==CommandSource::console && text==payload_) last_beat_=millis;
                return {};
            }
        }
        if(!current_ || next->session!=current_->session) {
            if(std::find(retired_.begin(),retired_.end(),next->session)!=retired_.end()) return {};
            if(current_) retired_[retired_index_++%retired_.size()]=current_->session;
        }
        current_=next;payload_=text;last_beat_=millis;live_=true;
        return next->active?next->speed100:100u;
    }
    bool expire(std::uint64_t millis) {
        if(live_ && millis>=last_beat_ && millis-last_beat_>8000) {live_=false;return true;}
        return false;
    }
private:
    std::optional<Command> current_;
    std::string payload_;
    std::array<std::uint64_t,64> retired_{};
    std::size_t retired_index_=0;
    std::uint64_t last_beat_=0;
    bool live_=false;
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
