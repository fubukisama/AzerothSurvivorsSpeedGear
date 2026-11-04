// Owned remote-CI process fixture, not a game or a local test entry point.
#include <windows.h>
#include <string>
int wmain(){
    wchar_t action[16]{},system[16]{};
    if(!GetEnvironmentVariableW(L"GITHUB_ACTIONS",action,16) || std::wstring(action)!=L"true" ||
       !GetEnvironmentVariableW(L"RUNNER_OS",system,16) || std::wstring(system)!=L"Windows")return 2;
    Sleep(8000);return 0;
}
