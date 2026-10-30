#pragma once
#include <windows.h>
#include <cstdint>
#include <optional>
#include <string>
#include <vector>

namespace azsg {
struct SimulationSite {
    std::uint32_t sleep_rva = 0;
    std::uint32_t return_rva = 0;
    std::uint32_t nanos = 25000000;
};
class PeImage {
public:
    PeImage(const unsigned char* base, std::size_t size);
    bool valid() const { return valid_; }
    std::optional<SimulationSite> locate_simulation(std::string& reason) const;
    static std::vector<unsigned char> load_file(const std::wstring& path, std::string& error);
    std::size_t size() const { return size_; }
private:
    const unsigned char* base_;
    std::size_t size_;
    bool valid_ = false;
    const IMAGE_NT_HEADERS64* pe_ = nullptr;
    bool contains(std::uint64_t rva, std::uint64_t length) const;
    bool executable(std::uint32_t rva) const;
    std::optional<std::pair<std::uint32_t,std::uint32_t>> function(std::uint32_t rva) const;
    std::vector<std::uint32_t> import_slots(const char* name) const;
};
}
