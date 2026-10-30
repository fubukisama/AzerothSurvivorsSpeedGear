// A tiny CI-only EXE, not game code. A static DWM import exercises DLL_PROCESS_ATTACH.
#include <windows.h>
#include <dwmapi.h>
#include <filesystem>
#include <fstream>
#include <string>
#include <vector>
#include <cstring>

int wmain(int argc,wchar_t** argv) {
    if(argc==2 && std::wstring(argv[1])==L"--exit-immediately") return 0;
    wchar_t executable[32768]{};GetModuleFileNameW(nullptr,executable,32768);
    const auto path=std::filesystem::path(executable),root=path.parent_path();
    BOOL enabled=FALSE;
    if(FAILED(DwmIsCompositionEnabled(&enabled))) return 2;
    // Confirm our direct-launch integration does not replace the EXE entrypoint.
    std::ifstream input(path,std::ios::binary);
    std::vector<unsigned char> disk{std::istreambuf_iterator<char>(input),std::istreambuf_iterator<char>()};
    if(disk.size()<sizeof(IMAGE_DOS_HEADER)) return 3;
    const auto* dos=reinterpret_cast<const IMAGE_DOS_HEADER*>(disk.data());
    const auto* pe=reinterpret_cast<const IMAGE_NT_HEADERS64*>(disk.data()+dos->e_lfanew);
    const auto entry=pe->OptionalHeader.AddressOfEntryPoint;
    const auto* sections=IMAGE_FIRST_SECTION(pe);
    bool checked=false;
    for(unsigned n=0;n<pe->FileHeader.NumberOfSections;++n) {
        if(entry>=sections[n].VirtualAddress && entry-sections[n].VirtualAddress+16<=sections[n].SizeOfRawData) {
            const auto offset=sections[n].PointerToRawData+entry-sections[n].VirtualAddress;
            if(offset+16>disk.size() || std::memcmp(disk.data()+offset,
                reinterpret_cast<const unsigned char*>(GetModuleHandleW(nullptr))+entry,16)!=0) return 4;
            checked=true;break;
        }
    }
    if(!checked) return 5;
    {std::ofstream marker(root/L"host.started");marker<<"DWM forwarded; original entrypoint unchanged\n";}
    const auto deadline=GetTickCount64()+40000;
    while(GetTickCount64()<deadline) {
        if(GetFileAttributesW((root/L"exit.request").c_str())!=INVALID_FILE_ATTRIBUTES) return 0;
        Sleep(20);
    }
    return 6;
}
