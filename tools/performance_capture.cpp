// Optional passive collector. It never starts a game, injects input/code,
// captures pixels, reads process memory contents or writes inside the game.
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0602
#endif
#include <windows.h>
#include <tlhelp32.h>
#include <psapi.h>
#include <pdh.h>
#include <pdhmsg.h>
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <filesystem>
#include <iomanip>
#include <iostream>
#include <limits>
#include <optional>
#include <regex>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

namespace {
namespace fs=std::filesystem;
struct Handle {
    HANDLE value=INVALID_HANDLE_VALUE;
    Handle()=default; explicit Handle(HANDLE h):value(h){}
    Handle(const Handle&)=delete;Handle& operator=(const Handle&)=delete;
    ~Handle(){if(value && value!=INVALID_HANDLE_VALUE)CloseHandle(value);}
};
std::uint64_t ticks(const FILETIME& f){return (std::uint64_t(f.dwHighDateTime)<<32)|f.dwLowDateTime;}
std::uint64_t wall(){FILETIME f{};GetSystemTimePreciseAsFileTime(&f);return ticks(f);}
std::wstring finalPath(HANDLE h){
    std::wstring result(32768,L'\0');
    const auto n=GetFinalPathNameByHandleW(h,result.data(),static_cast<DWORD>(result.size()),FILE_NAME_NORMALIZED|VOLUME_NAME_DOS);
    if(!n || n>=result.size())throw std::runtime_error("canonical_path_unavailable");
    result.resize(n);
    if(result.rfind(L"\\\\?\\UNC\\",0)==0)result=L"\\\\"+result.substr(8);
    else if(result.rfind(L"\\\\?\\",0)==0)result=result.substr(4);
    return result;
}
std::wstring canonicalFile(const fs::path& p){
    Handle file(CreateFileW(p.c_str(),FILE_READ_ATTRIBUTES,FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE,
        nullptr,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,nullptr));
    BY_HANDLE_FILE_INFORMATION info{};
    if(file.value==INVALID_HANDLE_VALUE || !GetFileInformationByHandle(file.value,&info) || (info.dwFileAttributes&FILE_ATTRIBUTE_DIRECTORY))
        throw std::runtime_error("game_file_unavailable");
    return finalPath(file.value);
}
bool equalPath(const std::wstring& a,const std::wstring& b){return _wcsicmp(a.c_str(),b.c_str())==0;}
bool inside(const std::wstring& p,const std::wstring& root){
    const auto prefix=root+L"\\";
    return equalPath(p,root) || (p.size()>=prefix.size() && _wcsnicmp(p.c_str(),prefix.c_str(),prefix.size())==0);
}
std::wstring imagePath(HANDLE process){
    std::wstring path(32768,L'\0');DWORD length=static_cast<DWORD>(path.size());
    if(!QueryFullProcessImageNameW(process,0,path.data(),&length))return {};
    path.resize(length);try{return canonicalFile(path);}catch(...){return {};}
}
HANDLE target(DWORD requested,const std::wstring& game,DWORD& pid,std::string& reason){
    if(requested){
        HANDLE h=OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION|SYNCHRONIZE,FALSE,requested);
        if(!h){reason="process_query_denied_or_missing";return INVALID_HANDLE_VALUE;}
        if(!equalPath(imagePath(h),game)){CloseHandle(h);reason="pid_image_mismatch";return INVALID_HANDLE_VALUE;}
        if(WaitForSingleObject(h,0)!=WAIT_TIMEOUT){CloseHandle(h);reason="process_already_exited";return INVALID_HANDLE_VALUE;}
        pid=requested;return h;
    }
    Handle snapshot(CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS,0));
    if(snapshot.value==INVALID_HANDLE_VALUE){reason="process_inventory_unavailable";return INVALID_HANDLE_VALUE;}
    PROCESSENTRY32W entry{};entry.dwSize=sizeof(entry);HANDLE found=INVALID_HANDLE_VALUE;
    if(Process32FirstW(snapshot.value,&entry))do{
        if(_wcsicmp(entry.szExeFile,L"AzerothSurvivors.exe")!=0)continue;
        HANDLE h=OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION|SYNCHRONIZE,FALSE,entry.th32ProcessID);
        if(!h)continue;
        if(!equalPath(imagePath(h),game) || WaitForSingleObject(h,0)!=WAIT_TIMEOUT){CloseHandle(h);continue;}
        if(found!=INVALID_HANDLE_VALUE){CloseHandle(h);CloseHandle(found);reason="multiple_matching_processes";return INVALID_HANDLE_VALUE;}
        found=h;pid=entry.th32ProcessID;
    }while(Process32NextW(snapshot.value,&entry));
    if(found==INVALID_HANDLE_VALUE)reason="no_matching_process";
    return found;
}
std::wstring safeOutput(const fs::path& output,const fs::path& gameRoot){
    if(!output.is_absolute() || output.filename().empty() || output.filename().wstring().find(L':')!=std::wstring::npos)
        throw std::runtime_error("absolute_output_file_required");
    Handle parent(CreateFileW(output.parent_path().c_str(),FILE_READ_ATTRIBUTES,
        FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE,nullptr,OPEN_EXISTING,FILE_FLAG_BACKUP_SEMANTICS,nullptr));
    BY_HANDLE_FILE_INFORMATION parentInfo{};
    if(parent.value==INVALID_HANDLE_VALUE || !GetFileInformationByHandle(parent.value,&parentInfo) ||
       !(parentInfo.dwFileAttributes&FILE_ATTRIBUTE_DIRECTORY))throw std::runtime_error("output_directory_must_exist");
    const auto directory=finalPath(parent.value);
    if(inside(directory,gameRoot.wstring()))throw std::runtime_error("output_inside_game_refused");
    return (fs::path(directory)/output.filename()).wstring();
}
std::string optionalNumber(const std::optional<double>& n){
    if(!n || !std::isfinite(*n))return "null";
    std::ostringstream out;out<<std::fixed<<std::setprecision(4)<<*n;return out.str();
}
struct Metric {std::optional<double> value;std::string status="unsupported";std::uint32_t code=0;};
bool pidInstance(const wchar_t* instance,DWORD pid){
    if(!instance)return false;
    const auto prefix=L"pid_"+std::to_wstring(pid)+L"_";
    return _wcsnicmp(instance,prefix.c_str(),prefix.size())==0;
}
class Gpu {
    struct Counter {PDH_HCOUNTER handle=nullptr;PDH_STATUS add=PDH_CSTATUS_NO_COUNTER;};
    PDH_HQUERY query_=nullptr;Counter util_,dedicated_,shared_;PDH_STATUS collect_=ERROR_SUCCESS;
    static Metric read(const Counter& c,DWORD pid,bool only3d){
        Metric out;out.code=static_cast<std::uint32_t>(c.add);
        if(!c.handle || c.add!=ERROR_SUCCESS)return out;
        DWORD bytes=0,count=0;
        auto status=PdhGetFormattedCounterArrayW(c.handle,PDH_FMT_DOUBLE,&bytes,&count,nullptr);
        if(status!=PDH_MORE_DATA){out.status="counter_read_unavailable";out.code=static_cast<std::uint32_t>(status);return out;}
        if(bytes==0 || bytes>4*1024*1024 || count>32768){out.status="buffer_limit";return out;}
        std::vector<unsigned char> buffer(bytes);
        auto* items=reinterpret_cast<PDH_FMT_COUNTERVALUE_ITEM_W*>(buffer.data());
        status=PdhGetFormattedCounterArrayW(c.handle,PDH_FMT_DOUBLE,&bytes,&count,items);
        if(status!=ERROR_SUCCESS || count>32768){out.status="counter_read_unavailable";out.code=static_cast<std::uint32_t>(status);return out;}
        bool matching=false;double maximum=0;
        for(DWORD i=0;i<count;++i){
            if(!pidInstance(items[i].szName,pid))continue;
            std::wstring name=items[i].szName;
            if(only3d && name.find(L"engtype_3D")==std::wstring::npos && name.find(L"engtype_3d")==std::wstring::npos)continue;
            matching=true;
            const auto& value=items[i].FmtValue;
            if(value.CStatus!=PDH_CSTATUS_VALID_DATA && value.CStatus!=PDH_CSTATUS_NEW_DATA)continue;
            const auto n=value.doubleValue;
            if(!std::isfinite(n) || n<0 || n>9e15 || (only3d && n>100.001))continue;
            maximum=std::max(maximum,n);out.value=maximum;
        }
        out.status=out.value?"available":matching?"invalid_or_warming_up":"no_matching_instance";
        out.code=0;return out;
    }
public:
    Gpu(){
        if(PdhOpenQueryW(nullptr,0,&query_)!=ERROR_SUCCESS)return;
        util_.add=PdhAddEnglishCounterW(query_,L"\\GPU Engine(*)\\Utilization Percentage",0,&util_.handle);
        dedicated_.add=PdhAddEnglishCounterW(query_,L"\\GPU Process Memory(*)\\Dedicated Usage",0,&dedicated_.handle);
        shared_.add=PdhAddEnglishCounterW(query_,L"\\GPU Process Memory(*)\\Shared Usage",0,&shared_.handle);
    }
    ~Gpu(){if(query_)PdhCloseQuery(query_);}
    std::vector<Metric> sample(DWORD pid){
        if(query_)collect_=PdhCollectQueryData(query_);
        if(!query_ || collect_!=ERROR_SUCCESS){Metric m;m.status="query_unavailable";m.code=static_cast<std::uint32_t>(collect_);return {m,m,m};}
        return {read(util_,pid,true),read(dedicated_,pid,false),read(shared_,pid,false)};
    }
};
std::string metricJson(const Metric& m){return "{\"value\":"+optionalNumber(m.value)+",\"status\":\""+m.status+"\",\"code\":"+std::to_string(m.code)+"}";}

std::optional<std::uint64_t> jsonInteger(const std::string& text,const char* key){
    const std::regex pattern(std::string("\"")+key+"\"\\s*:\\s*([0-9]{1,16})\\s*(?:[,}])");
    std::smatch match;if(!std::regex_search(text,match,pattern))return {};
    try{return std::stoull(match[1].str());}catch(...){return {};}
}
std::optional<std::string> jsonEnum(const std::string& text,const char* key,const std::vector<std::string>& allowed){
    const std::regex pattern(std::string("\"")+key+"\"\\s*:\\s*\"([a-z_]{1,32})\"");
    std::smatch match;if(!std::regex_search(text,match,pattern))return {};
    const auto value=match[1].str();return std::find(allowed.begin(),allowed.end(),value)!=allowed.end()?std::optional<std::string>(value):std::nullopt;
}
std::string nativeJson(const fs::path& root,std::uint64_t at){
    const auto path=root/L"AZSSpeedGear-status.json";
    Handle file(CreateFileW(path.c_str(),GENERIC_READ,FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE,
        nullptr,OPEN_EXISTING,FILE_FLAG_OPEN_REPARSE_POINT,nullptr));
    BY_HANDLE_FILE_INFORMATION info{};
    if(file.value==INVALID_HANDLE_VALUE || !GetFileInformationByHandle(file.value,&info))return "{\"status\":\"missing_or_unavailable\"}";
    if(info.dwFileAttributes&(FILE_ATTRIBUTE_DIRECTORY|FILE_ATTRIBUTE_REPARSE_POINT) || info.nNumberOfLinks!=1 || info.nFileSizeHigh || info.nFileSizeLow>16384)
        return "{\"status\":\"unsupported_file\"}";
    std::string text(info.nFileSizeLow,'\0');DWORD count=0;
    if(!ReadFile(file.value,text.data(),static_cast<DWORD>(text.size()),&count,nullptr) || count!=text.size())return "{\"status\":\"read_unavailable\"}";
    if(text.find("\"product\":\"AzerothSurvivorsSpeedGear\"")==std::string::npos || jsonInteger(text,"schema")!=1)
        return "{\"status\":\"unsupported_document\"}";
    const auto speed=jsonInteger(text,"speed100");
    const auto backend=jsonEnum(text,"backend",{"ready","initializing","unsupported","hooks_failed","disabled"});
    const auto transport=jsonEnum(text,"transport",{"waiting","console","file","degraded","stale","disabled"});
    const auto age=jsonInteger(text,"heartbeatAgeMs");
    const auto written=ticks(info.ftLastWriteTime);
    const bool future=written>at;
    std::ostringstream out;out<<"{\"status\":\"observed\",\"speed100\":";
    if(speed && *speed>=25 && *speed<=1000)out<<*speed;else out<<"null";
    out<<",\"backend\":"<<(backend?"\""+*backend+"\"":"null")<<",\"transport\":"<<(transport?"\""+*transport+"\"":"null");
    out<<",\"heartbeatAgeMs\":";if(age && *age<=1000000000000ull)out<<*age;else out<<"null";
    out<<",\"fileAgeMs\":"<<(future?0:(at-written)/10000)<<",\"fileTimestampInFuture\":"<<(future?"true":"false")<<"}";
    return out.str();
}

struct Options {fs::path game,output;unsigned seconds=480;DWORD pid=0;};
unsigned integer(const wchar_t* value,unsigned low,unsigned high){
    std::size_t used=0;const auto n=std::stoull(value,&used);
    if(used!=std::wstring(value).size() || n<low || n>high)throw std::runtime_error("invalid_numeric_argument");
    return static_cast<unsigned>(n);
}
Options parse(int argc,wchar_t** argv){
    Options o;
    for(int i=1;i<argc;++i){
        const std::wstring key=argv[i];if(i+1>=argc)throw std::runtime_error("missing_argument_value");
        if(key==L"--game-path")o.game=argv[++i];
        else if(key==L"--output")o.output=argv[++i];
        else if(key==L"--seconds")o.seconds=integer(argv[++i],3,600);
        else if(key==L"--pid")o.pid=integer(argv[++i],1,std::numeric_limits<DWORD>::max());
        else throw std::runtime_error("unknown_argument");
    }
    if(o.game.empty() || o.output.empty())throw std::runtime_error("game_path_and_output_required");
    return o;
}
void writeNew(const std::wstring& path,const std::string& text){
    Handle output(CreateFileW(path.c_str(),GENERIC_WRITE,0,nullptr,CREATE_NEW,FILE_ATTRIBUTE_NORMAL|FILE_FLAG_OPEN_REPARSE_POINT,nullptr));
    if(output.value==INVALID_HANDLE_VALUE)throw std::runtime_error("output_already_exists_or_unavailable");
    DWORD count=0;if(!WriteFile(output.value,text.data(),static_cast<DWORD>(text.size()),&count,nullptr) || count!=text.size() || !FlushFileBuffers(output.value))
        throw std::runtime_error("output_write_failed");
}
}

int wmain(int argc,wchar_t** argv){
    try{
        const auto options=parse(argc,argv);
        const auto canonical=canonicalFile(options.game);
        if(_wcsicmp(fs::path(canonical).filename().c_str(),L"AzerothSurvivors.exe")!=0)throw std::runtime_error("game_filename_required");
        const auto root=fs::path(canonical).parent_path();
        const auto output=safeOutput(options.output,root);
        DWORD pid=0;std::string reason;
        Handle process(target(options.pid,canonical,pid,reason));
        const auto logical=std::max<DWORD>(1,GetActiveProcessorCount(ALL_PROCESSOR_GROUPS));
        const auto began=GetTickCount64();const auto startedFileTime=wall();
        std::vector<std::string> rows;rows.reserve(options.seconds+1);
        bool havePrevious=false;std::uint64_t previousCpu=0,previousWall=0;
        if(process.value!=INVALID_HANDLE_VALUE){
            Gpu gpu;ULONGLONG next=began;const auto deadline=began+options.seconds*1000ull;
            reason="requested_interval_completed";
            while(rows.size()<601){
                if(WaitForSingleObject(process.value,0)!=WAIT_TIMEOUT){reason="process_exited";break;}
                const auto current=GetTickCount64();
                if(current<next){
                    if(WaitForSingleObject(process.value,static_cast<DWORD>(std::min<ULONGLONG>(1000,next-current)))==WAIT_OBJECT_0){reason="process_exited";break;}
                    continue;
                }
                const auto at=wall();FILETIME creation{},exit{},kernel{},user{};
                const bool cpuOkay=GetProcessTimes(process.value,&creation,&exit,&kernel,&user)!=FALSE;
                const auto cpuTicks=cpuOkay?ticks(kernel)+ticks(user):0;
                const bool discontinuity=havePrevious && at<=previousWall;
                std::optional<double> cpuOne,cpuMachine;
                if(cpuOkay && havePrevious && !discontinuity && cpuTicks>=previousCpu){
                    cpuOne=100.0*double(cpuTicks-previousCpu)/double(at-previousWall);cpuMachine=*cpuOne/logical;
                }
                PROCESS_MEMORY_COUNTERS_EX memory{};memory.cb=sizeof(memory);
                const bool memoryOkay=GetProcessMemoryInfo(process.value,reinterpret_cast<PROCESS_MEMORY_COUNTERS*>(&memory),sizeof(memory))!=FALSE;
                const auto graphics=gpu.sample(pid);
                std::ostringstream row;row<<std::fixed<<std::setprecision(4)<<"{\"fileTime\":"<<at<<",\"elapsedMs\":"<<(current-began);
                row<<",\"cpuStatus\":\""<<(cpuOkay?"available":"query_unavailable")<<"\",\"processCpuMs\":";
                if(cpuOkay)row<<double(cpuTicks)/10000.0;else row<<"null";
                row<<",\"cpuPercentOneCore\":"<<optionalNumber(cpuOne)<<",\"cpuPercentMachine\":"<<optionalNumber(cpuMachine);
                row<<",\"clockDiscontinuity\":"<<(discontinuity?"true":"false")<<",\"memoryStatus\":\""<<(memoryOkay?"available":"query_unavailable")<<"\",\"privateBytes\":";
                if(memoryOkay)row<<memory.PrivateUsage;else row<<"null";
                row<<",\"workingSetBytes\":";if(memoryOkay)row<<memory.WorkingSetSize;else row<<"null";
                row<<",\"gpu3dMaxPercent\":"<<metricJson(graphics[0])<<",\"gpuDedicatedMaxBytes\":"<<metricJson(graphics[1]);
                row<<",\"gpuSharedMaxBytes\":"<<metricJson(graphics[2])<<",\"native\":"<<nativeJson(root,at)<<"}";
                rows.push_back(row.str());
                if(cpuOkay){previousCpu=cpuTicks;previousWall=at;havePrevious=true;}
                if(current>=deadline)break;
                next=current+1000;
            }
        }
        const auto state=rows.empty()?"blocked":reason=="requested_interval_completed"?"observed":"partial";
        std::ostringstream report;report<<"{\"schema\":1,\"product\":\"AzerothSurvivorsPerformanceCapture\",\"purpose\":\"passive normal-play observations, not an automated test\",\"status\":\""<<state<<"\",\"reason\":\""<<reason<<"\",\"pid\":"<<pid;
        report<<",\"requestedSeconds\":"<<options.seconds<<",\"sampleCount\":"<<rows.size()<<",\"logicalProcessors\":"<<logical<<",\"startedFileTime\":"<<startedFileTime;
        report<<",\"clock\":\"unhooked collector FILETIME; monotonic host scheduling\",\"gpuAggregation\":\"maximum matching PID instance, not summed across duplicate engines/adapters\",\"gameLaunched\":false,\"inputInjected\":false,\"memoryContentsRead\":false,\"samples\":[";
        for(std::size_t i=0;i<rows.size();++i){if(i)report<<',';report<<rows[i];}report<<"]}\n";
        writeNew(output,report.str());std::cout<<"status="<<state<<" samples="<<rows.size()<<"\n";
        return rows.empty()?2:0;
    }catch(const std::exception&){std::cerr<<"performance_capture_arguments_or_environment_unavailable\n";return 2;}
}
