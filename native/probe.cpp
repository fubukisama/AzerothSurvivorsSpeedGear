#include "pe_image.h"
#include <iostream>
#include <iomanip>
#include <cstring>
#include <algorithm>
int wmain(int argc,wchar_t** argv) {
    if(argc<2 || argc>3) {std::cerr<<"Usage: AZSSpeedGearProbe.exe <game.exe> [--selftest]\n";return 2;}
    std::string reason;auto image=azsg::PeImage::load_file(argv[1],reason);
    if(image.empty()) {std::cerr<<reason<<"\n";return 1;}
    azsg::PeImage view(image.data(),image.size());auto site=view.locate_simulation(reason);
    std::cout<<"x64="<<view.valid()<<" image_size="<<view.size()<<" scan="<<reason<<"\n";
    if(!site) return 1;
    std::cout<<std::hex<<"sleep_rva=0x"<<site->sleep_rva<<" return_rva=0x"<<site->return_rva<<std::dec<<" nanos="<<site->nanos<<"\n";
    if(argc==3 && std::wstring(argv[2])==L"--selftest") {
        auto modified=image;
        modified[site->return_rva-9]=0;
        azsg::PeImage unknown(modified.data(),modified.size());
        if(unknown.locate_simulation(reason)) {std::cerr<<"Changed-duration fail-closed test failed\n";return 1;}
        std::cout<<"changed-duration="<<reason<<" (refused)\n";
        modified=image;
        // Create a second structurally valid call in executable padding, preserving its target.
        const unsigned char padding[16]={0xcc,0xcc,0xcc,0xcc,0xcc,0xcc,0xcc,0xcc,0xcc,0xcc,0xcc,0xcc,0xcc,0xcc,0xcc,0xcc};
        auto* dos=reinterpret_cast<const IMAGE_DOS_HEADER*>(modified.data());
        auto* pe=reinterpret_cast<const IMAGE_NT_HEADERS64*>(modified.data()+dos->e_lfanew);
        auto* sec=IMAGE_FIRST_SECTION(pe);
        bool copied=false;
        for(unsigned s=0;s<pe->FileHeader.NumberOfSections && !copied;++s) {
            if(!(sec[s].Characteristics&IMAGE_SCN_MEM_EXECUTE)) continue;
            auto first=modified.begin()+sec[s].VirtualAddress,last=first+sec[s].Misc.VirtualSize;
            auto at=std::search(first,last,std::begin(padding),std::end(padding));
            if(at==last) continue;
            auto offset=static_cast<std::uint32_t>(at-modified.begin());
            std::memcpy(modified.data()+offset,image.data()+site->return_rva-12,12);
            auto delta=static_cast<std::int32_t>(static_cast<std::int64_t>(site->sleep_rva)-offset-12);
            std::memcpy(modified.data()+offset+8,&delta,4);copied=true;
        }
        if(!copied) {std::cerr<<"No executable fixture padding\n";return 1;}
        azsg::PeImage ambiguous(modified.data(),modified.size());
        if(ambiguous.locate_simulation(reason)) {std::cerr<<"Ambiguous-call fail-closed test failed\n";return 1;}
        std::cout<<"ambiguous-call="<<reason<<" (refused)\n";
        std::cout<<"scanner-negative-tests=passed\n";
    }
    return 0;
}
