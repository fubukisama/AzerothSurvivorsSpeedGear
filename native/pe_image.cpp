#include "pe_image.h"
#include <algorithm>
#include <array>
#include <cstring>
#include <fstream>
#include <limits>
#include <set>

namespace azsg {
bool PeImage::contains(std::uint64_t rva,std::uint64_t length) const { return rva <= size_ && length <= size_-rva; }
PeImage::PeImage(const unsigned char* base,std::size_t size):base_(base),size_(size) {
    if(!base_ || size_<sizeof(IMAGE_DOS_HEADER)) return;
    const auto* dos=reinterpret_cast<const IMAGE_DOS_HEADER*>(base_);
    if(dos->e_magic!=IMAGE_DOS_SIGNATURE || dos->e_lfanew<0 || !contains(dos->e_lfanew,sizeof(IMAGE_NT_HEADERS64))) return;
    pe_=reinterpret_cast<const IMAGE_NT_HEADERS64*>(base_+dos->e_lfanew);
    if(pe_->Signature!=IMAGE_NT_SIGNATURE || pe_->FileHeader.Machine!=IMAGE_FILE_MACHINE_AMD64 ||
       pe_->OptionalHeader.Magic!=IMAGE_NT_OPTIONAL_HDR64_MAGIC || pe_->OptionalHeader.SizeOfImage>size_ ||
       pe_->FileHeader.NumberOfSections==0 || pe_->FileHeader.NumberOfSections>96) return;
    auto sectionRva=std::uint64_t(dos->e_lfanew)+offsetof(IMAGE_NT_HEADERS64,OptionalHeader)+pe_->FileHeader.SizeOfOptionalHeader;
    if(!contains(sectionRva,std::uint64_t(pe_->FileHeader.NumberOfSections)*sizeof(IMAGE_SECTION_HEADER))) return;
    valid_=true;
}
bool PeImage::executable(std::uint32_t rva) const {
    if(!valid_) return false;
    auto* section=IMAGE_FIRST_SECTION(pe_);
    for(unsigned i=0;i<pe_->FileHeader.NumberOfSections;++i) {
        if((section[i].Characteristics & IMAGE_SCN_MEM_EXECUTE) && rva>=section[i].VirtualAddress &&
           std::uint64_t(rva)-section[i].VirtualAddress<section[i].Misc.VirtualSize) return true;
    }
    return false;
}
std::optional<std::pair<std::uint32_t,std::uint32_t>> PeImage::function(std::uint32_t rva) const {
    const auto& dir=pe_->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_EXCEPTION];
    if(!contains(dir.VirtualAddress,dir.Size) || dir.Size%sizeof(RUNTIME_FUNCTION)) return {};
    const auto* entries=reinterpret_cast<const RUNTIME_FUNCTION*>(base_+dir.VirtualAddress);
    for(std::size_t i=0;i<dir.Size/sizeof(RUNTIME_FUNCTION);++i) {
        if(entries[i].BeginAddress==rva && entries[i].EndAddress>rva && contains(rva,entries[i].EndAddress-rva))
            return std::make_pair(rva,entries[i].EndAddress);
    }
    return {};
}
std::vector<std::uint32_t> PeImage::import_slots(const char* name) const {
    std::vector<std::uint32_t> slots;
    const auto& dir=pe_->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT];
    if(!contains(dir.VirtualAddress,dir.Size) || !dir.VirtualAddress) return slots;
    for(std::uint32_t at=dir.VirtualAddress; contains(at,sizeof(IMAGE_IMPORT_DESCRIPTOR)) && at<dir.VirtualAddress+dir.Size; at+=sizeof(IMAGE_IMPORT_DESCRIPTOR)) {
        const auto* desc=reinterpret_cast<const IMAGE_IMPORT_DESCRIPTOR*>(base_+at);
        if(!desc->Name) break;
        if(!desc->OriginalFirstThunk) continue;
        for(std::uint32_t n=0;n<65536;++n) {
            auto lookup=std::uint64_t(desc->OriginalFirstThunk)+n*8ull;
            if(!contains(lookup,8)) break;
            auto value=*reinterpret_cast<const std::uint64_t*>(base_+lookup);
            if(!value) break;
            if(value & IMAGE_ORDINAL_FLAG64 || !contains(value,2+std::strlen(name)+1)) continue;
            if(std::memcmp(base_+value+2,name,std::strlen(name)+1)==0 && contains(std::uint64_t(desc->FirstThunk)+n*8ull,8))
                slots.push_back(desc->FirstThunk+n*8);
        }
    }
    return slots;
}
std::optional<SimulationSite> PeImage::locate_simulation(std::string& reason) const {
    if(!valid_) { reason="invalid-x64-pe"; return {}; }
    const std::array<const char*,3> required={"CreateWaitableTimerExW","SetWaitableTimer","WaitForSingleObject"};
    std::array<std::vector<std::uint32_t>,3> iats;
    for(unsigned i=0;i<3;++i) {
        iats[i]=import_slots(required[i]);
        if(iats[i].empty()) { reason=std::string("missing-import:")+required[i]; return {}; }
    }
    std::vector<SimulationSite> sites;
    auto* section=IMAGE_FIRST_SECTION(pe_);
    for(unsigned s=0;s<pe_->FileHeader.NumberOfSections;++s) {
        if(!(section[s].Characteristics & IMAGE_SCN_MEM_EXECUTE)) continue;
        std::uint64_t begin=section[s].VirtualAddress,end=begin+section[s].Misc.VirtualSize;
        if(end>size_) continue;
        for(std::uint64_t at=begin;at+12<end;++at) {
            const auto* p=base_+at;
            // Rust Duration(0, 25_000_000), followed by a direct call. Both common XOR encodings.
            if(!((p[0]==0x31 || p[0]==0x33) && p[1]==0xc9 && p[2]==0xba &&
                 p[3]==0x40 && p[4]==0x78 && p[5]==0x7d && p[6]==0x01 && p[7]==0xe8)) continue;
            std::int32_t rel; std::memcpy(&rel,p+8,4);
            std::int64_t target=static_cast<std::int64_t>(at+12)+rel;
            bool resolved=true;
            for(unsigned hop=0;hop<4;++hop) {
                if(target<0 || !contains(target,5) || !executable(static_cast<std::uint32_t>(target))) { resolved=false;break; }
                if(base_[target]!=0xe9) break;
                std::int32_t jump; std::memcpy(&jump,base_+target+1,4);target+=5+jump;
                if(hop==3) resolved=false;
            }
            if(!resolved) continue;
            auto bounds=function(static_cast<std::uint32_t>(target));
            if(!bounds || bounds->second-bounds->first<128 || bounds->second-bounds->first>4096) continue;
            std::array<bool,3> seen{};
            for(std::uint32_t pos=bounds->first;pos+6<=bounds->second;++pos) {
                if(base_[pos]!=0xff || base_[pos+1]!=0x15) continue;
                std::int32_t displacement;std::memcpy(&displacement,base_+pos+2,4);
                std::int64_t slot=static_cast<std::int64_t>(pos)+6+displacement;
                for(unsigned n=0;n<3;++n)
                    if(std::find(iats[n].begin(),iats[n].end(),slot)!=iats[n].end()) seen[n]=true;
            }
            if(std::all_of(seen.begin(),seen.end(),[](bool v){return v;}))
                sites.push_back({static_cast<std::uint32_t>(target),static_cast<std::uint32_t>(at+12),25000000});
        }
    }
    if(sites.size()!=1) { reason="simulation-candidate-count:"+std::to_string(sites.size());return {}; }
    reason="unique-duration-call+unwind+3-imports";return sites.front();
}
std::vector<unsigned char> PeImage::load_file(const std::wstring& path,std::string& error) {
    std::ifstream in(path,std::ios::binary|std::ios::ate);
    if(!in) { error="cannot-open-file";return {}; }
    auto length=in.tellg();
    if(length<sizeof(IMAGE_DOS_HEADER) || length>1024ll*1024*1024) { error="bad-file-size";return {}; }
    std::vector<unsigned char> file(static_cast<std::size_t>(length));in.seekg(0);in.read(reinterpret_cast<char*>(file.data()),length);
    if(!in) { error="cannot-read-file";return {}; }
    auto* dos=reinterpret_cast<const IMAGE_DOS_HEADER*>(file.data());
    if(dos->e_magic!=IMAGE_DOS_SIGNATURE || dos->e_lfanew<0 || std::uint64_t(dos->e_lfanew)+sizeof(IMAGE_NT_HEADERS64)>file.size()) { error="bad-dos-header";return {}; }
    auto* pe=reinterpret_cast<const IMAGE_NT_HEADERS64*>(file.data()+dos->e_lfanew);
    auto sectionOffset=std::uint64_t(dos->e_lfanew)+offsetof(IMAGE_NT_HEADERS64,OptionalHeader)+pe->FileHeader.SizeOfOptionalHeader;
    if(pe->Signature!=IMAGE_NT_SIGNATURE || pe->OptionalHeader.SizeOfImage<4096 || pe->OptionalHeader.SizeOfImage>1024u*1024*1024 ||
       pe->OptionalHeader.SizeOfHeaders>file.size() || pe->OptionalHeader.SizeOfHeaders>pe->OptionalHeader.SizeOfImage ||
       sectionOffset+std::uint64_t(pe->FileHeader.NumberOfSections)*sizeof(IMAGE_SECTION_HEADER)>file.size()) { error="bad-pe-header";return {}; }
    std::vector<unsigned char> image(pe->OptionalHeader.SizeOfImage,0);
    std::memcpy(image.data(),file.data(),pe->OptionalHeader.SizeOfHeaders);
    auto* section=IMAGE_FIRST_SECTION(pe);
    for(unsigned i=0;i<pe->FileHeader.NumberOfSections;++i) {
        if(std::uint64_t(section[i].PointerToRawData)+section[i].SizeOfRawData>file.size() || std::uint64_t(section[i].VirtualAddress)+section[i].SizeOfRawData>image.size()) { error="bad-section";return {}; }
        std::memcpy(image.data()+section[i].VirtualAddress,file.data()+section[i].PointerToRawData,section[i].SizeOfRawData);
    }
    return image;
}
}
