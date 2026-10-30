#pragma once
#include <string_view>
namespace azsg {
// Observe only this addon's ConsoleExec CVar query and forward all bytes unchanged.
// Process-lifetime worker threads; no game VM or version-specific ABI is accessed.
bool start_console_bridge(void(*receive)(std::string_view));
}
