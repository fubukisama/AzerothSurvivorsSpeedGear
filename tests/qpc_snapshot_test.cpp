#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <iostream>
#include <limits>
#include <thread>
#include <vector>
#include "qpc_snapshot.h"

namespace {
unsigned failures=0,checks=0;
void check(bool condition,const char* message) {
    ++checks;if(!condition) {++failures;std::cerr<<"FAIL: "<<message<<"\n";}
}
azsg::QpcSnapshot::Epoch epoch(const azsg::VirtualClock& clock) {
    return {clock.real_anchor(),clock.virtual_anchor(),clock.speed100(),
            clock.fractional_remainder(),clock.initialized()};
}
template<class Predicate> bool until(Predicate predicate) {
    const auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(3);
    while(!predicate()) {
        if(std::chrono::steady_clock::now()>=deadline) return false;
        std::this_thread::yield();
    }
    return true;
}
}

int main() {
    azsg::QpcSnapshot uninitialized;
    std::uint64_t output=91;unsigned raw_calls=0;
    check(!uninitialized.read([&](std::uint64_t& value){++raw_calls;value=100;return true;},output)
          && output==91 && raw_calls==0,"uninitialized snapshot refuses before touching the raw API");

    // Differential checks use the existing mutable clock as an independent
    // sequential oracle. Read cadence, remainder and rate changes must agree.
    for(unsigned rate:{25u,50u,100u,200u,333u,500u,1000u}) {
        azsg::VirtualClock writer,reference;
        writer.sample(1001);reference.sample(1001);
        writer.set_speed(1001,rate);reference.set_speed(1001,rate);
        azsg::QpcSnapshot snapshot;
        snapshot.begin_update();snapshot.publish(writer);
        std::uint64_t physical=1001;
        for(unsigned step=0;step<12000;++step) {
            physical+=1+step%7;
            const auto raw=step%19==0?physical-30:physical;
            const auto success=snapshot.read([&](std::uint64_t& value){value=raw;return true;},output);
            check(success && output==reference.sample(raw),"snapshot equals original clock across reads and rollback");
            if(step%31==0) {
                const auto next=step%3==0?25u:step%3==1?200u:1000u;
                snapshot.begin_update();
                writer.set_speed((std::max)(raw,snapshot.observed_real()),next);
                snapshot.publish(writer);reference.set_speed(raw,next);
            }
        }
        output=71;
        check(!snapshot.read([](std::uint64_t&){return false;},output) && output==71,
              "failed raw QPC does not modify the caller's output");
        check(snapshot.read([&](std::uint64_t& value){value=physical+1;return true;},output),
              "failed raw query releases its reader slot");
        snapshot.begin_update();snapshot.publish(writer);
    }

    constexpr auto maximum=std::numeric_limits<std::uint64_t>::max();
    for(unsigned rate:{25u,100u,333u,1000u}) {
        for(auto base:{std::uint64_t(0),maximum/3,maximum-109}) {
            azsg::VirtualClock reference;reference.sample(base);reference.set_speed(base,rate);
            const auto immutable=epoch(reference);
            for(auto raw:{base,base<maximum-1?base+1:base,maximum-1,maximum}) {
                const auto expected=reference.sample(raw);
                check(azsg::QpcSnapshot::evaluate(immutable,raw)==expected,
                      "closed-form evaluation matches original overflow saturation and fractional carry");
            }
        }
    }
    azsg::VirtualClock fractional;fractional.sample(1000);fractional.set_speed(1000,25);fractional.sample(1001);
    check(fractional.fractional_remainder()==25 && azsg::QpcSnapshot::evaluate(epoch(fractional),1004)==1001,
          "published quarter-speed fraction survives quantized raw ticks");

    // Hold an old reader across a pending rate change. The writer must sample its
    // transition only after that reader has published the higher raw timestamp.
    azsg::QpcSnapshot handover;
    handover.begin_update();handover.publish(fractional);
    std::atomic<bool> old_entered{false},release_old{false},transition_read{false},published{false},new_started{false};
    std::atomic<bool> new_read_during_update{false};
    std::uint64_t old_value=0,new_value=0;
    std::thread old_reader([&]{handover.read([&](std::uint64_t& raw){
        old_entered=true;while(!release_old.load()) std::this_thread::yield();raw=1005;return true;
    },old_value);});
    check(until([&]{return old_entered.load();}),"old reader entered its published epoch");
    std::thread publisher([&]{
        handover.begin_update();transition_read=true;
        fractional.set_speed((std::max)(std::uint64_t(1002),handover.observed_real()),200);
        handover.publish(fractional);published=true;
    });
    check(until([&]{return handover.updating();}),"writer closes admission while old reader is active");
    check(!transition_read.load(),"transition timestamp is sampled after quiescence, not before");
    std::thread new_reader([&]{new_started=true;handover.read([&](std::uint64_t& raw){
        new_read_during_update=handover.updating();raw=1006;return true;
    },new_value);});
    check(until([&]{return new_started.load();}),"new reader attempts the closed epoch");
    release_old=true;
    old_reader.join();publisher.join();new_reader.join();
    check(published.load() && !new_read_during_update.load(),"new reader waits for complete publication");
    check(old_value==1001 && new_value==1003 && fractional.real_anchor()==1005,
          "handover retains old fraction and higher observed time across a backward transition clock");

    azsg::VirtualClock stress_writer;stress_writer.sample(1000);
    azsg::QpcSnapshot stress;stress.begin_update();stress.publish(stress_writer);
    std::atomic<std::uint64_t> actual{1000};
    std::atomic<unsigned> backwards{0},api_failures{0};
    std::atomic<bool> go{false};
    std::vector<std::thread> readers;
    for(unsigned index=0;index<8;++index) readers.emplace_back([&]{
        while(!go.load()) std::this_thread::yield();
        std::uint64_t previous=0,value=0;
        for(unsigned query=0;query<12000;++query) {
            if(!stress.read([&](std::uint64_t& raw){raw=actual.fetch_add(1);return true;},value)) ++api_failures;
            if(value<previous) ++backwards;previous=value;
        }
    });
    go=true;
    for(unsigned update=0;update<500;++update) {
        stress.begin_update();
        const auto raw=actual.fetch_add(1);
        const unsigned rate=update%3==0?25u:update%3==1?1000u:100u;
        stress_writer.set_speed((std::max)(raw,stress.observed_real()),rate);
        stress.publish(stress_writer);
    }
    for(auto& reader:readers) reader.join();
    check(!backwards.load() && !api_failures.load(),"eight concurrent readers remain monotonic through 500 rate changes");
    std::cout<<"QPC snapshot: "<<checks<<" checks, "<<failures<<" failures\n";
    return failures?1:0;
}
