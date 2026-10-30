#include <windows.h>
#include <array>
#include <string>
#include "toc_notes.h"

void StartBackend(HMODULE self);
namespace {
struct Export { const char* name; unsigned ordinal; };
constexpr Export exports[] = {
#include "proxy_exports.inc"
};
std::array<FARPROC, sizeof(exports)/sizeof(exports[0])> functions{};
INIT_ONCE once=INIT_ONCE_STATIC_INIT;
BOOL CALLBACK resolve(PINIT_ONCE,void*,void**) {
    wchar_t directory[MAX_PATH]{};
    auto length=GetSystemDirectoryW(directory,MAX_PATH);
    if(!length || length>=MAX_PATH) return FALSE;
    std::wstring path=std::wstring(directory)+L"\\dwmapi.dll";
    HMODULE system=LoadLibraryExW(path.c_str(),nullptr,LOAD_LIBRARY_SEARCH_SYSTEM32);
    if(!system) return FALSE;
    for(std::size_t i=0;i<functions.size();++i)
        functions[i]=GetProcAddress(system,exports[i].name ? exports[i].name : MAKEINTRESOURCEA(exports[i].ordinal));
    return TRUE;
}
}
extern "C" FARPROC ProxyGetFunction(unsigned index) {
    if(index>=functions.size() || !InitOnceExecuteOnce(&once,resolve,nullptr,nullptr) || !functions[index])
        RaiseFailFastException(nullptr,nullptr,0);
    return functions[index];
}
BOOL WINAPI DllMain(HMODULE self,DWORD reason,LPVOID reserved) {
    if(reason==DLL_PROCESS_ATTACH) {
        DisableThreadLibraryCalls(self);
        // Bounded Kernel32-only metadata IO, before the EXE reads addon notes.
        // No network, crypto provider, waiting, or entrypoint patch is involved.
        if(reserved) azsg::initialize_toc_notes_before_entry();
        StartBackend(self);
    }
    return TRUE;
}
