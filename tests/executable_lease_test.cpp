#include <windows.h>
#include <filesystem>
#include <iostream>
#include <string>
#include <vector>

static bool spawn(const std::filesystem::path& file,PROCESS_INFORMATION& process) {
    auto command=L"\""+file.wstring()+L"\" --exit-immediately";
    std::vector<wchar_t> mutable_command(command.begin(),command.end());mutable_command.push_back(0);
    STARTUPINFOW startup{};startup.cb=sizeof(startup);
    return CreateProcessW(file.c_str(),mutable_command.data(),nullptr,nullptr,FALSE,CREATE_NO_WINDOW,
                          nullptr,file.parent_path().c_str(),&startup,&process)!=FALSE;
}
int wmain(int argc,wchar_t** argv) {
    if(argc!=2) return 2;
    namespace fs=std::filesystem;
    const auto root=fs::temp_directory_path()/(L"AZSG-lease-"+std::to_wstring(GetCurrentProcessId()));
    fs::create_directory(root);
    const auto file=root/L"owned-fixture.exe";
    fs::copy_file(argv[1],file,fs::copy_options::none);
    const auto lease=CreateFileW(file.c_str(),GENERIC_READ,0,nullptr,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,nullptr);
    if(lease==INVALID_HANDLE_VALUE) return 3;
    PROCESS_INFORMATION blocked{};
    const bool unexpectedly_started=spawn(file,blocked);
    const auto failure=GetLastError();
    if(unexpectedly_started) {
        WaitForSingleObject(blocked.hProcess,5000);CloseHandle(blocked.hThread);CloseHandle(blocked.hProcess);
    }
    CloseHandle(lease);
    PROCESS_INFORMATION normal{};
    const bool started=spawn(file,normal);
    DWORD exit=999;
    if(started) {
        WaitForSingleObject(normal.hProcess,5000);GetExitCodeProcess(normal.hProcess,&exit);
        CloseHandle(normal.hThread);CloseHandle(normal.hProcess);
    }
    const bool ok=!unexpectedly_started && (failure==ERROR_SHARING_VIOLATION || failure==ERROR_ACCESS_DENIED) && started && exit==0;
    std::cout<<"exclusive read lease blocked startup="<<!unexpectedly_started<<" error="<<failure
             <<" startup after release="<<started<<" exit="<<exit<<"\n";
    fs::remove(file);fs::remove(root);return ok?0:1;
}
