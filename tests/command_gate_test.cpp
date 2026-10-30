#include "command_gate.h"
#include <iostream>

int main() {
    unsigned checks=0,failed=0;
    auto check=[&](bool value,const char* message){++checks;if(!value){++failed;std::cerr<<"FAIL "<<message<<'\n';}};
    azsg::CommandGate gate;
    using Source=azsg::CommandSource;
    check(gate.accept("SG1|100|1|1000|500|1",Source::console,1000,0)==500u,"console request accepted");
    check(!gate.accept("SG1|100|1|1000|100|1",Source::file,1001,1000),"same sequence different value rejected");
    check(gate.accept("SG1|100|3|1001|200|1",Source::console,1001,1000)==200u,"new sequence accepted");
    check(!gate.accept("SG1|100|2|1000|500|1",Source::file,1002,2000),"delayed old file ignored");
    check(!gate.accept("invalid",Source::file,1002,2000),"invalid text ignored");
    check(!gate.accept("SG1|100|4|900|500|1",Source::file,1002,2000),"stale new sequence ignored");
    check(!gate.expire(8999),"invalid/stale data does not reset speed prematurely");
    check(gate.expire(9001),"invalid/replayed files cannot starve watchdog");
    check(!gate.expire(20000),"expiry emitted once");
    check(!gate.accept("SG1|100|3|1001|200|1",Source::console,1020,20000),"expired replay cannot restart");
    check(gate.accept("SG1|100|5|1020|25|1",Source::file,1020,20000)==25u,"fresh file fallback recovers");
    gate.accept("SG1|100|5|1020|25|1",Source::file,1027,27000);
    check(gate.expire(28001),"file duplicate is not a pulse");
    check(gate.accept("SG1|200|1|1030|300|1",Source::console,1030,30000)==300u,"new Lua session accepted");
    check(!gate.accept("SG1|100|6|1030|25|1",Source::file,1030,30001),"retired session cannot undo current request");
    gate.accept("SG1|200|1|1030|300|1",Source::console,1037,37000);
    check(!gate.expire(38001),"live exact query refreshes heartbeat without dirtying config");
    gate.accept("SG1|200|1|1030|500|1",Source::console,1038,38000);
    gate.accept("SG1|200|1|1030|300|1",Source::console,1044,44000);
    check(gate.expire(45001),"modified or stale exact console query cannot refresh heartbeat");
    check(azsg::console_command("INFO console: CVar \"AZSSpeedGearCommand\" is \"SG1|1|2|3|100|0\"\r")=="SG1|1|2|3|100|0","actual console log grammar");
    check(azsg::console_command("console: CVar \"azsspeedgearcommand\" is \"SG1|1|2|3|100|1\"").has_value(),"CVar case-insensitive");
    check(!azsg::console_command("console: CVar \"other\" is \"SG1|1|2|3|500|1\""),"other log not a command");
    check(!azsg::console_command("console: CVar \"AZSSpeedGearCommandSuffix\" is \"SG1|1|2|3|500|1\""),"exact CVar required");
    check(!azsg::console_command("console: CVar \"AZSSpeedGearCommand\" is \"SG1|1|2|3|500|1junk\""),"strict payload required");
    std::cout<<checks<<" checks, "<<failed<<" failures\n";
    return failed?1:0;
}
