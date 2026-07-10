// ============================================================
// Mods.mm - النظام المتكامل الكامل (All-in-One)
// ============================================================

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <mach/mach.h>
#include <mach/vm_region.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <vector>
#include <string>
#include <cstring>
#include <mutex>
#include <unordered_map>
#include <atomic>
#include <shared_mutex>
#include <algorithm>
#include <sstream>
#include <functional>
#include <fstream>
#include <nlohmann/json.hpp>

using json = nlohmann::json;

// ============================================================
// 1. إعدادات الـ Debugging
// ============================================================
#define MOD_DEBUG 1
#if MOD_DEBUG
    #define MOD_LOG(fmt, ...) NSLog(@"[Mods] " fmt, ##__VA_ARGS__)
    #define MOD_LOG_PATTERN(fmt, ...) NSLog(@"[Scanner] " fmt, ##__VA_ARGS__)
    #define MOD_LOG_MEMORY(fmt, ...) NSLog(@"[Memory] " fmt, ##__VA_ARGS__)
    #define MOD_LOG_FEATURE(fmt, ...) NSLog(@"[Feature] " fmt, ##__VA_ARGS__)
#else
    #define MOD_LOG(fmt, ...)
    #define MOD_LOG_PATTERN(fmt, ...)
    #define MOD_LOG_MEMORY(fmt, ...)
    #define MOD_LOG_FEATURE(fmt, ...)
#endif

// ============================================================
// 2. هيكل التعديلات الأساسي
// ============================================================
struct Mods {
    bool aimbot = false;
    bool espWallhack = false;
    bool noRecoil = false;
    bool flyHack = false;
    bool jumpPower = false;
    
    // عناوين الميزات المكتشفة
    uintptr_t aimbotAddress = 0;
    uintptr_t espAddress = 0;
    uintptr_t recoilAddress = 0;
    uintptr_t flyAddress = 0;
    uintptr_t jumpAddress = 0;
};

Mods g_mods;

// ============================================================
// 3. بنية النمط (Pattern) مع Wildcards
// ============================================================
struct Pattern {
    std::vector<uint8_t> bytes;
    std::vector<bool> mask;
    std::string name;
    
    Pattern(const std::string& patternStr, const std::string& patternName = "") {
        name = patternName;
        parsePattern(patternStr);
    }
    
    Pattern(const std::vector<uint8_t>& patternBytes, 
            const std::vector<bool>& patternMask, 
            const std::string& patternName = "") {
        bytes = patternBytes;
        mask = patternMask;
        name = patternName;
    }
    
    void parsePattern(const std::string& patternStr) {
        bytes.clear(); mask.clear();
        if (patternStr.empty()) return;
        
        std::stringstream ss(patternStr);
        std::string token;
        while (ss >> token) {
            token.erase(std::remove(token.begin(), token.end(), ','), token.end());
            token.erase(std::remove(token.begin(), token.end(), ';'), token.end());
            
            if (token == "?" || token == "??" || token == "**" || token == ".." || token == "*") {
                bytes.push_back(0); mask.push_back(false);
            } else {
                if (token.length() == 2) {
                    char* endPtr;
                    uint8_t byte = (uint8_t)strtol(token.c_str(), &endPtr, 16);
                    if (*endPtr == '\0') { bytes.push_back(byte); mask.push_back(true); }
                    else { bytes.push_back(0); mask.push_back(false); }
                } else if (token.length() == 1 && token[0] == '?') {
                    bytes.push_back(0); mask.push_back(false);
                } else {
                    if (token.length() > 2 && token.substr(0, 2) == "0x") token = token.substr(2);
                    char* endPtr;
                    uint8_t byte = (uint8_t)strtol(token.c_str(), &endPtr, 16);
                    if (*endPtr == '\0' && token.length() <= 2) { bytes.push_back(byte); mask.push_back(true); }
                    else { bytes.push_back(0); mask.push_back(false); }
                }
            }
        }
    }
    
    size_t size() const { return bytes.size(); }
    bool isValid() const { return !bytes.empty() && bytes.size() == mask.size(); }
    bool hasWildcards() const { for (bool m : mask) if (!m) return true; return false; }
    std::string toString() const {
        std::stringstream ss;
        for (size_t i = 0; i < bytes.size(); i++) {
            if (mask[i]) { char hex[3]; snprintf(hex, sizeof(hex), "%02X", bytes[i]); ss << hex; }
            else ss << "??";
            if (i < bytes.size() - 1) ss << " ";
        }
        return ss.str();
    }
};

// ============================================================
// 4. تعريف MemoryRange
// ============================================================
struct MemoryRange {
    uintptr_t start, end;
    vm_prot_t protections;
    std::string name;
    MemoryRange(uintptr_t s = 0, uintptr_t e = 0, vm_prot_t p = 0, const std::string& n = "")
        : start(s), end(e), protections(p), name(n) {}
    size_t size() const { return end - start; }
    bool contains(uintptr_t address) const { return address >= start && address < end; }
    bool isReadable() const { return (protections & VM_PROT_READ) != 0; }
    bool isWritable() const { return (protections & VM_PROT_WRITE) != 0; }
    bool isExecutable() const { return (protections & VM_PROT_EXECUTE) != 0; }
};

// ============================================================
// 5. مدير الذاكرة (MemoryProtectionManager)
// ============================================================
class MemoryProtectionManager {
private:
    struct PageInfo { vm_address_t pageStart; vm_size_t pageSize; vm_prot_t protections; bool isValid; };
    mutable std::shared_mutex cacheMutex;
    std::unordered_map<uintptr_t, PageInfo> pageCache;
    std::atomic<size_t> cacheHits{0}, cacheMisses{0};
    
    mutable std::shared_mutex rangeCacheMutex;
    std::vector<MemoryRange> memoryRanges;
    std::atomic<bool> rangesCached{false};
    
    bool getPageInfoInternal(uintptr_t address, PageInfo& outInfo) {
        if (address == 0) { outInfo.isValid = false; return false; }
        mach_port_t task = mach_task_self();
        vm_region_basic_info_data_64_t info;
        mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t objectName = MACH_PORT_NULL;
        vm_address_t pageStart = (vm_address_t)address;
        vm_size_t pageSize = 0;
        kern_return_t kr = vm_region_64(task, &pageStart, &pageSize, VM_REGION_BASIC_INFO_64,
                                        (vm_region_info_64_t)&info, &count, &objectName);
        if (kr != KERN_SUCCESS) { outInfo.isValid = false; return false; }
        outInfo.pageStart = pageStart; outInfo.pageSize = pageSize;
        outInfo.protections = info.protection; outInfo.isValid = true;
        return true;
    }
    
    bool getPageInfoCached(uintptr_t address, PageInfo& outInfo) {
        if (address == 0) { outInfo.isValid = false; return false; }
        {
            std::shared_lock<std::shared_mutex> lock(cacheMutex);
            auto it = pageCache.find(address);
            if (it != pageCache.end() && it->second.isValid) {
                outInfo = it->second; cacheHits++; return true;
            }
        }
        std::unique_lock<std::shared_mutex> lock(cacheMutex);
        auto it = pageCache.find(address);
        if (it != pageCache.end() && it->second.isValid) {
            outInfo = it->second; cacheHits++; return true;
        }
        PageInfo newInfo;
        bool success = getPageInfoInternal(address, newInfo);
        if (success && newInfo.isValid) {
            pageCache[address] = newInfo; outInfo = newInfo; cacheMisses++; return true;
        }
        cacheMisses++; outInfo.isValid = false; return false;
    }

public:
    bool isMemoryReadable(uintptr_t address, size_t size) {
        if (address == 0 || size == 0) return false;
        PageInfo info; if (!getPageInfoCached(address, info)) return false;
        return (info.protections & VM_PROT_READ) != 0;
    }
    
    bool isMemoryWritable(uintptr_t address, size_t size) {
        if (address == 0 || size == 0) return false;
        PageInfo info; if (!getPageInfoCached(address, info)) return false;
        return (info.protections & VM_PROT_WRITE) != 0;
    }
    
    bool protectPageForWrite(uintptr_t address, size_t size, vm_prot_t& originalProtections) {
        if (address == 0 || size == 0) return false;
        PageInfo info; if (!getPageInfoCached(address, info)) return false;
        originalProtections = info.protections;
        if (info.protections & VM_PROT_EXECUTE) return true;
        kern_return_t kr = vm_protect(mach_task_self(), info.pageStart, info.pageSize, FALSE,
                                      VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
        return kr == KERN_SUCCESS;
    }
    
    bool restorePageProtections(uintptr_t address, vm_prot_t originalProtections) {
        if (address == 0) return false;
        PageInfo info; if (!getPageInfoCached(address, info)) return false;
        if (info.protections & VM_PROT_EXECUTE) return true;
        kern_return_t kr = vm_protect(mach_task_self(), info.pageStart, info.pageSize, FALSE, originalProtections);
        return kr == KERN_SUCCESS;
    }
    
    bool writeMemoryDirect(uintptr_t address, const void* data, size_t size) {
        if (address == 0 || data == NULL || size == 0) return false;
        kern_return_t kr = vm_write(mach_task_self(), (vm_address_t)address, (pointer_t)data, (mach_msg_type_number_t)size);
        if (kr == KERN_SUCCESS) return true;
        vm_prot_t originalProtections;
        if (!protectPageForWrite(address, size, originalProtections)) return false;
        if (originalProtections & VM_PROT_EXECUTE) {
            kr = vm_write(mach_task_self(), (vm_address_t)address, (pointer_t)data, (mach_msg_type_number_t)size);
            return kr == KERN_SUCCESS;
        }
        memcpy((void*)address, data, size);
        __builtin___clear_cache((char*)address, (char*)address + size);
        restorePageProtections(address, originalProtections);
        return true;
    }
    
    bool readMemoryDirect(uintptr_t address, void* buffer, size_t size) {
        if (address == 0 || buffer == NULL || size == 0) return false;
        vm_offset_t dataPtr = 0; mach_msg_type_number_t dataSize = 0;
        kern_return_t kr = vm_read(mach_task_self(), (vm_address_t)address, (mach_msg_type_number_t)size, &dataPtr, &dataSize);
        if (kr == KERN_SUCCESS && dataSize == size) {
            memcpy(buffer, (void*)dataPtr, size);
            vm_deallocate(mach_task_self(), dataPtr, dataSize);
            return true;
        }
        if (isMemoryReadable(address, size)) { memcpy(buffer, (void*)address, size); return true; }
        return false;
    }
    
    std::vector<MemoryRange> getMemoryRanges(bool refresh = false) {
        if (rangesCached.load() && !refresh) {
            std::shared_lock<std::shared_mutex> lock(rangeCacheMutex);
            return memoryRanges;
        }
        std::unique_lock<std::shared_mutex> lock(rangeCacheMutex);
        if (rangesCached.load() && !refresh) return memoryRanges;
        memoryRanges.clear();
        mach_port_t task = mach_task_self();
        vm_address_t address = 0;
        vm_size_t size = 0;
        vm_region_basic_info_data_64_t info;
        mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t objectName = MACH_PORT_NULL;
        while (true) {
            count = VM_REGION_BASIC_INFO_COUNT_64;
            kern_return_t kr = vm_region_64(task, &address, &size, VM_REGION_BASIC_INFO_64,
                                            (vm_region_info_64_t)&info, &count, &objectName);
            if (kr != KERN_SUCCESS) break;
            if (info.protection & VM_PROT_READ) {
                MemoryRange range; range.start = (uintptr_t)address; range.end = (uintptr_t)address + size;
                range.protections = info.protection; memoryRanges.push_back(range);
            }
            address += size;
        }
        rangesCached.store(true);
        return memoryRanges;
    }
    
    uintptr_t scanPatternInRange(uintptr_t startAddress, size_t size,
                                 const Pattern& pattern,
                                 std::function<void(float)> progressCallback = nullptr) {
        if (!pattern.isValid() || startAddress == 0 || size == 0) return 0;
        if (!isMemoryReadable(startAddress, size)) return 0;
        std::vector<uint8_t> memoryData; memoryData.resize(size);
        if (!readMemoryDirect(startAddress, memoryData.data(), size)) return 0;
        const uint8_t* data = memoryData.data();
        const std::vector<uint8_t>& patternBytes = pattern.bytes;
        const std::vector<bool>& patternMask = pattern.mask;
        size_t patternSize = pattern.size();
        size_t totalSteps = size - patternSize + 1;
        size_t stepsProcessed = 0;
        for (size_t i = 0; i <= size - patternSize; i++) {
            bool found = true;
            for (size_t j = 0; j < patternSize; j++) {
                if (patternMask[j] && data[i + j] != patternBytes[j]) { found = false; break; }
            }
            if (found) { return startAddress + i; }
            stepsProcessed++;
            if (progressCallback && stepsProcessed % 1000 == 0) progressCallback((float)stepsProcessed / totalSteps);
        }
        return 0;
    }
    
    uintptr_t scanPatternInAllRanges(const Pattern& pattern, bool skipExecutable = false,
                                     std::function<void(float)> progressCallback = nullptr) {
        if (!pattern.isValid()) return 0;
        auto ranges = getMemoryRanges();
        if (ranges.empty()) return 0;
        std::vector<MemoryRange> validRanges;
        for (const auto& range : ranges) {
            if (range.isReadable() && range.size() > pattern.size()) {
                if (skipExecutable && range.isExecutable()) continue;
                validRanges.push_back(range);
            }
        }
        float totalRanges = (float)validRanges.size(), rangesScanned = 0;
        for (const auto& range : validRanges) {
            if (progressCallback) progressCallback(rangesScanned / totalRanges);
            uintptr_t result = scanPatternInRange(range.start, range.size(), pattern);
            if (result != 0) return result;
            rangesScanned++;
        }
        if (progressCallback) progressCallback(1.0f);
        return 0;
    }
    
    uintptr_t findPattern(const std::string& pattern, uintptr_t startAddress = 0,
                          size_t size = 0, const std::string& patternName = "") {
        Pattern pat(pattern, patternName.empty() ? pattern : patternName);
        if (!pat.isValid()) return 0;
        if (startAddress == 0) return scanPatternInAllRanges(pat);
        else {
            if (size == 0) {
                auto ranges = getMemoryRanges();
                for (const auto& range : ranges) {
                    if (range.contains(startAddress)) { size = range.end - startAddress; break; }
                }
                if (size == 0) size = 0x1000000;
            }
            return scanPatternInRange(startAddress, size, pat);
        }
    }
    
    void printCacheStats() {
        size_t hits = cacheHits.load(), misses = cacheMisses.load();
        size_t total = hits + misses;
        MOD_LOG_MEMORY(@"📊 Cache: %zu hits (%.1f%%), %zu misses", hits, total > 0 ? (float)hits / total * 100 : 0, misses);
        auto ranges = getMemoryRanges();
        MOD_LOG_MEMORY(@"📍 %zu memory ranges found", ranges.size());
    }
    
    void clearCache() {
        { std::unique_lock<std::shared_mutex> lock(cacheMutex); pageCache.clear(); cacheHits = 0; cacheMisses = 0; }
        { std::unique_lock<std::shared_mutex> lock(rangeCacheMutex); memoryRanges.clear(); rangesCached.store(false); }
        MOD_LOG_MEMORY(@"🧹 All caches cleared");
    }
};

// ============================================================
// 6. Singleton لمدير الذاكرة
// ============================================================
static MemoryProtectionManager& getMemoryManager() {
    static MemoryProtectionManager manager;
    return manager;
}

// ============================================================
// 7. دوال Template للقراءة والكتابة
// ============================================================
template <typename T>
T readMemory(uintptr_t address) {
    T value = T();
    if (address == 0 || address < 0x1000) return value;
    auto& manager = getMemoryManager();
    vm_offset_t dataPtr = 0; mach_msg_type_number_t dataSize = 0;
    kern_return_t kr = vm_read(mach_task_self(), (vm_address_t)address, sizeof(T), &dataPtr, &dataSize);
    if (kr == KERN_SUCCESS && dataSize == sizeof(T)) {
        memcpy(&value, (void*)dataPtr, sizeof(T)); vm_deallocate(mach_task_self(), dataPtr, dataSize); return value;
    }
    if (manager.isMemoryReadable(address, sizeof(T))) { memcpy(&value, (void*)address, sizeof(T)); return value; }
    return value;
}

template <typename T>
bool writeMemory(uintptr_t address, T value) {
    if (address == 0 || address < 0x1000) return false;
    auto& manager = getMemoryManager();
    if (manager.isMemoryWritable(address, sizeof(T))) {
        memcpy((void*)address, &value, sizeof(T)); 
        __builtin___clear_cache((char*)address, (char*)address + sizeof(T));
        return true;
    }
    kern_return_t kr = vm_write(mach_task_self(), (vm_address_t)address, (pointer_t)&value, sizeof(T));
    if (kr == KERN_SUCCESS) return true;
    vm_prot_t originalProtections;
    if (!manager.protectPageForWrite(address, sizeof(T), originalProtections)) return false;
    if (originalProtections & VM_PROT_EXECUTE) {
        kr = vm_write(mach_task_self(), (vm_address_t)address, (pointer_t)&value, sizeof(T));
        return kr == KERN_SUCCESS;
    }
    memcpy((void*)address, &value, sizeof(T));
    __builtin___clear_cache((char*)address, (char*)address + sizeof(T));
    manager.restorePageProtections(address, originalProtections);
    return true;
}

// ============================================================
// 8. دوال مساعدة للذاكرة
// ============================================================
uintptr_t getBaseAddress() { return (uintptr_t)_dyld_get_image_header(0); }

bool getPageInfo(uintptr_t address, vm_address_t* pageStart, vm_size_t* pageSize, vm_prot_t* protections) {
    if (address == 0 || pageStart == NULL || pageSize == NULL || protections == NULL) return false;
    mach_port_t task = mach_task_self();
    vm_region_basic_info_data_64_t info;
    mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t objectName = MACH_PORT_NULL;
    *pageStart = (vm_address_t)address;
    kern_return_t kr = vm_region_64(task, pageStart, pageSize, VM_REGION_BASIC_INFO_64,
                                    (vm_region_info_64_t)&info, &count, &objectName);
    if (kr != KERN_SUCCESS) return false;
    *protections = info.protection;
    return true;
}

// ============================================================
// 9. دوال البحث في الموديولات
// ============================================================
uintptr_t find_pattern_in_module(const char* module_name, const char* pattern) {
    if (module_name == NULL || pattern == NULL) return 0;
    uint32_t imageCount = _dyld_image_count();
    for (uint32_t i = 0; i < imageCount; i++) {
        const char* name = _dyld_get_image_name(i);
        if (name == NULL) continue;
        std::string fullPath(name);
        size_t lastSlash = fullPath.find_last_of('/');
        std::string fileName = (lastSlash != std::string::npos) ? fullPath.substr(lastSlash + 1) : fullPath;
        std::string moduleLower = module_name, fileLower = fileName;
        std::transform(moduleLower.begin(), moduleLower.end(), moduleLower.begin(), ::tolower);
        std::transform(fileLower.begin(), fileLower.end(), fileLower.begin(), ::tolower);
        if (fileLower.find(moduleLower) != std::string::npos) {
            const struct mach_header_64* header = (const struct mach_header_64*)_dyld_get_image_header(i);
            if (header == NULL) continue;
            uintptr_t baseAddress = (uintptr_t)header;
            uintptr_t loadCommand = (uintptr_t)header + sizeof(struct mach_header_64);
            uint32_t ncmds = header->ncmds;
            size_t textSize = 0; uintptr_t textStart = 0;
            for (uint32_t j = 0; j < ncmds; j++) {
                struct load_command* cmd = (struct load_command*)loadCommand;
                if (cmd->cmd == LC_SEGMENT_64) {
                    struct segment_command_64* segment = (struct segment_command_64*)cmd;
                    if (strcmp(segment->segname, "__TEXT") == 0) {
                        textSize = (size_t)segment->vmsize;
                        textStart = (uintptr_t)segment->vmaddr + baseAddress;
                        break;
                    }
                }
                loadCommand += cmd->cmdsize;
            }
            if (textSize > 0) {
                uintptr_t result = getMemoryManager().findPattern(std::string(pattern), textStart, textSize);
                if (result != 0) return result;
            }
            uintptr_t lastEnd = baseAddress;
            loadCommand = (uintptr_t)header + sizeof(struct mach_header_64);
            for (uint32_t j = 0; j < ncmds; j++) {
                struct load_command* cmd = (struct load_command*)loadCommand;
                if (cmd->cmd == LC_SEGMENT_64) {
                    struct segment_command_64* segment = (struct segment_command_64*)cmd;
                    uintptr_t segEnd = (uintptr_t)segment->vmaddr + baseAddress + segment->vmsize;
                    if (segEnd > lastEnd) lastEnd = segEnd;
                }
                loadCommand += cmd->cmdsize;
            }
            size_t totalSize = lastEnd - baseAddress;
            if (totalSize > 0) {
                uintptr_t result = getMemoryManager().findPattern(std::string(pattern), baseAddress, totalSize);
                if (result != 0) return result;
            }
        }
    }
    return getMemoryManager().findPattern(std::string(pattern));
}

// ============================================================
// 10. بنية التوقيع (FoundSignature) والماسح التلقائي
// ============================================================
struct FoundSignature {
    std::string name, pattern, module, type, description;
    int offset = 0;
    uintptr_t address = 0;
    bool found = false, isEnabled = true, isActive = false;
};

class AutoSignatureScanner {
private:
    std::string signaturesFile;
    std::vector<FoundSignature> signatures;
    std::mutex scanMutex;
    time_t lastModified = 0;
    
    bool loadSignaturesFromJSON(const std::string& filePath) {
        std::ifstream file(filePath);
        if (!file.is_open()) {
            MOD_LOG_PATTERN(@"❌ Could not open: %s", filePath.c_str());
            return false;
        }
        try {
            json data = json::parse(file);
            std::string version = data.value("version", "1.0.0");
            MOD_LOG_PATTERN(@"📋 Loading signatures (v%s)", version.c_str());
            signatures.clear();
            for (const auto& sig : data["signatures"]) {
                FoundSignature fs;
                fs.name = sig.value("name", "Unnamed");
                fs.pattern = sig.value("pattern", "");
                fs.module = sig.value("module", "");
                fs.offset = sig.value("offset", 0);
                fs.type = sig.value("type", "function");
                fs.isEnabled = sig.value("isEnabled", true);
                fs.description = sig.value("description", "");
                if (!fs.pattern.empty()) {
                    signatures.push_back(fs);
                    MOD_LOG_PATTERN(@"   ✅ %s", fs.name.c_str());
                }
            }
            MOD_LOG_PATTERN(@"✅ Loaded %zu signatures", signatures.size());
            struct stat fileStat;
            if (stat(filePath.c_str(), &fileStat) == 0) lastModified = fileStat.st_mtime;
            return true;
        } catch (...) { MOD_LOG_PATTERN(@"❌ JSON parse error"); return false; }
    }
    
public:
    AutoSignatureScanner(const std::string& sigFile = "signatures.json") : signaturesFile(sigFile) {
        loadSignaturesFromJSON(sigFile);
    }
    
    void reload() { std::lock_guard<std::mutex> lock(scanMutex); loadSignaturesFromJSON(signaturesFile); }
    
    bool checkAndReloadIfChanged() {
        struct stat fileStat;
        if (stat(signaturesFile.c_str(), &fileStat) == 0 && fileStat.st_mtime != lastModified) {
            reload(); return true;
        }
        return false;
    }
    
    void scanAll() {
        std::lock_guard<std::mutex> lock(scanMutex);
        MOD_LOG_PATTERN(@"🔍 Scanning %zu signatures...", signatures.size());
        size_t found = 0, total = 0;
        for (auto& sig : signatures) {
            if (!sig.isEnabled) continue;
            total++;
            uintptr_t result = sig.module.empty() ?
                getMemoryManager().findPattern(sig.pattern, 0, 0, sig.name) :
                find_pattern_in_module(sig.module.c_str(), sig.pattern.c_str());
            sig.found = (result != 0);
            sig.address = result + sig.offset;
            sig.isActive = sig.found;
            
            // ============================================================
            // تحديث العناوين في g_mods عند اكتشافها
            // ============================================================
            if (sig.found) {
                found++;
                MOD_LOG_PATTERN(@"✅ %s at 0x%lx", sig.name.c_str(), sig.address);
                
                // ربط العناوين المكتشفة مع g_mods
                if (sig.name == "Aimbot") g_mods.aimbotAddress = sig.address;
                else if (sig.name == "ESP Wallhack") g_mods.espAddress = sig.address;
                else if (sig.name == "No Recoil") g_mods.recoilAddress = sig.address;
                else if (sig.name == "Fly Hack") g_mods.flyAddress = sig.address;
                else if (sig.name == "Jump Power") g_mods.jumpAddress = sig.address;
            } else {
                MOD_LOG_PATTERN(@"❌ %s not found", sig.name.c_str());
            }
        }
        MOD_LOG_PATTERN(@"✅ Found %zu/%zu", found, total);
    }
    
    std::vector<FoundSignature> getResults() const {
        std::lock_guard<std::mutex> lock(scanMutex); return signatures;
    }
    
    void runAutoScan() { scanAll(); }
    std::string getFilePath() const { return signaturesFile; }
};

// ============================================================
// 11. كائن الماسح العالمي وتهيئته
// ============================================================
static AutoSignatureScanner* g_scanner = nullptr;

void initScanner() {
    if (g_scanner == nullptr) {
        NSString* documentsPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
        NSString* sigPath = [documentsPath stringByAppendingPathComponent:@"signatures.json"];
        NSFileManager* fm = [NSFileManager defaultManager];
        if (![fm fileExistsAtPath:sigPath]) {
            NSString* bundlePath = [[NSBundle mainBundle] pathForResource:@"signatures" ofType:@"json"];
            if (bundlePath) [fm copyItemAtPath:bundlePath toPath:sigPath error:nil];
            else {
                NSString* defaultJSON = @"{\"version\":\"1.0.0\",\"game\":\"Roblox\",\"description\":\"Dynamic signatures\",\"signatures\":[]}";
                [defaultJSON writeToFile:sigPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
            }
        }
        g_scanner = new AutoSignatureScanner([sigPath UTF8String]);
        MOD_LOG(@"✅ Scanner initialized");
    }
}

// ============================================================
// 12. نظام ربط الميزات الفعلي (Feature Binding)
// ============================================================

// ============================================================
// 12a. تطبيق Aimbot
// ============================================================
void applyAimbot(bool enabled) {
    if (g_mods.aimbotAddress == 0) {
        MOD_LOG_FEATURE(@"⚠️ Aimbot address not found, run scanner first");
        return;
    }
    
    if (enabled) {
        // مثال: كتابة قيمة 1 لتفعيل الـ Aimbot
        uint8_t value = 1;
        if (writeMemory<uint8_t>(g_mods.aimbotAddress, value)) {
            MOD_LOG_FEATURE(@"✅ Aimbot enabled at 0x%lx", g_mods.aimbotAddress);
        } else {
            MOD_LOG_FEATURE(@"❌ Failed to enable Aimbot");
        }
    } else {
        // تعطيل: كتابة 0
        uint8_t value = 0;
        if (writeMemory<uint8_t>(g_mods.aimbotAddress, value)) {
            MOD_LOG_FEATURE(@"⏭️ Aimbot disabled");
        }
    }
}

// ============================================================
// 12b. تطبيق ESP Wallhack
// ============================================================
void applyESP(bool enabled) {
    if (g_mods.espAddress == 0) {
        MOD_LOG_FEATURE(@"⚠️ ESP address not found, run scanner first");
        return;
    }
    
    float value = enabled ? 1.0f : 0.0f;
    if (writeMemory<float>(g_mods.espAddress, value)) {
        MOD_LOG_FEATURE(@"%@ ESP at 0x%lx", enabled ? @"✅ Enabled" : @"⏭️ Disabled", g_mods.espAddress);
    } else {
        MOD_LOG_FEATURE(@"❌ Failed to apply ESP");
    }
}

// ============================================================
// 12c. تطبيق No Recoil
// ============================================================
void applyNoRecoil(bool enabled) {
    if (g_mods.recoilAddress == 0) {
        MOD_LOG_FEATURE(@"⚠️ No Recoil address not found, run scanner first");
        return;
    }
    
    float value = enabled ? 0.0f : 1.0f;
    if (writeMemory<float>(g_mods.recoilAddress, value)) {
        MOD_LOG_FEATURE(@"%@ No Recoil at 0x%lx", enabled ? @"✅ Enabled" : @"⏭️ Disabled", g_mods.recoilAddress);
    } else {
        MOD_LOG_FEATURE(@"❌ Failed to apply No Recoil");
    }
}

// ============================================================
// 12d. تطبيق Fly Hack
// ============================================================
void applyFlyHack(bool enabled) {
    if (g_mods.flyAddress == 0) {
        MOD_LOG_FEATURE(@"⚠️ Fly Hack address not found, run scanner first");
        return;
    }
    
    // مثال: تغيير قيمة الجاذبية أو تفعيل الطيران
    float value = enabled ? -10.0f : -30.0f; // تغيير قيمة الجاذبية
    if (writeMemory<float>(g_mods.flyAddress, value)) {
        MOD_LOG_FEATURE(@"%@ Fly Hack at 0x%lx", enabled ? @"✅ Enabled" : @"⏭️ Disabled", g_mods.flyAddress);
    } else {
        MOD_LOG_FEATURE(@"❌ Failed to apply Fly Hack");
    }
}

// ============================================================
// 12e. تطبيق Jump Power
// ============================================================
void applyJumpPower(bool enabled) {
    if (g_mods.jumpAddress == 0) {
        MOD_LOG_FEATURE(@"⚠️ Jump Power address not found, run scanner first");
        return;
    }
    
    float value = enabled ? 500.0f : 200.0f; // تغيير قوة القفز
    if (writeMemory<float>(g_mods.jumpAddress, value)) {
        MOD_LOG_FEATURE(@"%@ Jump Power at 0x%lx", enabled ? @"✅ Enabled" : @"⏭️ Disabled", g_mods.jumpAddress);
    } else {
        MOD_LOG_FEATURE(@"❌ Failed to apply Jump Power");
    }
}

// ============================================================
// 12f. تطبيق جميع الميزات (حسب الحالة الحالية)
// ============================================================
void applyAllMods() {
    MOD_LOG_FEATURE(@"🔄 Applying all mods...");
    applyAimbot(g_mods.aimbot);
    applyESP(g_mods.espWallhack);
    applyNoRecoil(g_mods.noRecoil);
    applyFlyHack(g_mods.flyHack);
    applyJumpPower(g_mods.jumpPower);
    MOD_LOG_FEATURE(@"✅ All mods applied");
}

// ============================================================
// 13. واجهة ImGui UI (مدمجة بالكامل)
// ============================================================
#include "imgui.h"

static std::vector<FoundSignature> uiResults;

void renderModsUI() {
    initScanner();
    
    if (ImGui::Begin("Mod Menu", nullptr, ImGuiWindowFlags_AlwaysAutoResize)) {
        
        // ============================================================
        // قسم التعديلات الأساسية
        // ============================================================
        if (ImGui::CollapsingHeader("Mods", ImGuiTreeNodeFlags_DefaultOpen)) {
            
            // عرض العناوين المكتشفة
            ImGui::TextDisabled("Aimbot: 0x%lx", g_mods.aimbotAddress);
            ImGui::TextDisabled("ESP: 0x%lx", g_mods.espAddress);
            ImGui::TextDisabled("No Recoil: 0x%lx", g_mods.recoilAddress);
            ImGui::TextDisabled("Fly: 0x%lx", g_mods.flyAddress);
            ImGui::TextDisabled("Jump: 0x%lx", g_mods.jumpAddress);
            ImGui::Separator();
            
            // أزرار التفعيل
            if (ImGui::Checkbox("Aimbot", &g_mods.aimbot)) {
                applyAimbot(g_mods.aimbot);
            }
            if (ImGui::Checkbox("ESP Wallhack", &g_mods.espWallhack)) {
                applyESP(g_mods.espWallhack);
            }
            if (ImGui::Checkbox("No Recoil", &g_mods.noRecoil)) {
                applyNoRecoil(g_mods.noRecoil);
            }
            if (ImGui::Checkbox("Fly Hack", &g_mods.flyHack)) {
                applyFlyHack(g_mods.flyHack);
            }
            if (ImGui::Checkbox("Jump Power", &g_mods.jumpPower)) {
                applyJumpPower(g_mods.jumpPower);
            }
            
            ImGui::Separator();
            if (ImGui::Button("Apply All Mods")) {
                applyAllMods();
            }
        }
        
        // ============================================================
        // قسم Auto Scanner
        // ============================================================
        if (ImGui::CollapsingHeader("🔍 Auto Scanner", ImGuiTreeNodeFlags_DefaultOpen)) {
            
            if (ImGui::Button("🔄 Reload JSON")) {
                g_scanner->reload();
                MOD_LOG(@"📋 Reloaded");
            }
            ImGui::SameLine();
            if (ImGui::Button("🚀 Scan All")) {
                uiResults.clear();
                g_scanner->runAutoScan();
                uiResults = g_scanner->getResults();
                MOD_LOG(@"✅ Scan complete: %zu signatures", uiResults.size());
                // تطبيق الميزات بعد المسح
                applyAllMods();
            }
            ImGui::SameLine();
            if (ImGui::Button("📊 Report")) {
                auto r = g_scanner->getResults();
                size_t found = 0;
                for (const auto& s : r) if (s.isEnabled && s.found) found++;
                MOD_LOG(@"📊 Found: %zu/%zu", found, r.size());
            }
            
            ImGui::TextDisabled("📁 %s", g_scanner->getFilePath().c_str());
            ImGui::Separator();
            
            auto results = uiResults.empty() ? g_scanner->getResults() : uiResults;
            size_t enabled = 0, found = 0;
            for (const auto& s : results) { if (s.isEnabled) { enabled++; if (s.found) found++; } }
            ImGui::Text("📋 %zu total, %zu enabled, %zu found", results.size(), enabled, found);
            
            if (!results.empty()) {
                if (ImGui::BeginTable("Table", 4, ImGuiTableFlags_Borders | ImGuiTableFlags_RowBg, ImVec2(0, 200))) {
                    ImGui::TableSetupColumn("Status", ImGuiTableColumnFlags_WidthFixed, 50.0f);
                    ImGui::TableSetupColumn("Name", ImGuiTableColumnFlags_WidthFixed, 100.0f);
                    ImGui::TableSetupColumn("Address", ImGuiTableColumnFlags_WidthFixed, 120.0f);
                    ImGui::TableSetupColumn("Actions", ImGuiTableColumnFlags_WidthStretch);
                    ImGui::TableHeadersRow();
                    for (const auto& sig : results) {
                        if (!sig.isEnabled) continue;
                        ImGui::TableNextRow();
                        ImGui::TableSetColumnIndex(0);
                        ImGui::TextColored(sig.found ? ImVec4(0,1,0,1) : ImVec4(1,0,0,1), sig.found ? "✅" : "❌");
                        ImGui::TableSetColumnIndex(1); ImGui::Text("%s", sig.name.c_str());
                        ImGui::TableSetColumnIndex(2);
                        if (sig.found) ImGui::TextColored(ImVec4(0,1,0,1), "0x%lx", sig.address);
                        else ImGui::TextColored(ImVec4(0.5f,0.5f,0.5f,1), "Not Found");
                        ImGui::TableSetColumnIndex(3);
                        if (sig.found) {
                            if (ImGui::SmallButton(("Copy##" + sig.name).c_str())) {
                                UIPasteboard* pb = [UIPasteboard generalPasteboard];
                                pb.string = [NSString stringWithFormat:@"0x%lx", sig.address];
                            }
                            ImGui::SameLine();
                            if (ImGui::SmallButton(("Read##" + sig.name).c_str())) {
                                uint32_t v = readMemory<uint32_t>(sig.address);
                                MOD_LOG(@"📖 %s: %u (0x%X)", sig.name.c_str(), v, v);
                            }
                            ImGui::SameLine();
                            if (ImGui::SmallButton(("Toggle##" + sig.name).c_str())) {
                                // تبديل حالة الميزة
                                if (sig.name == "Aimbot") {
                                    g_mods.aimbot = !g_mods.aimbot;
                                    applyAimbot(g_mods.aimbot);
                                } else if (sig.name == "ESP Wallhack") {
                                    g_mods.espWallhack = !g_mods.espWallhack;
                                    applyESP(g_mods.espWallhack);
                                } else if (sig.name == "No Recoil") {
                                    g_mods.noRecoil = !g_mods.noRecoil;
                                    applyNoRecoil(g_mods.noRecoil);
                                }
                            }
                        }
                    }
                    ImGui::EndTable();
                }
            }
        }
        
        // ============================================================
        // قسم Memory Info
        // ============================================================
        if (ImGui::CollapsingHeader("Memory Info")) {
            if (ImGui::Button("Refresh Stats")) getMemoryManager().printCacheStats();
            ImGui::SameLine();
            if (ImGui::Button("Clear Cache")) getMemoryManager().clearCache();
            ImGui::SameLine();
            if (ImGui::Button("Rescan Memory")) {
                getMemoryManager().getMemoryRanges(true);
                MOD_LOG(@"🔄 Memory rescanned");
            }
        }
    }
    ImGui::End();
}

// ============================================================
// 14. Constructor - نقطة الدخول الرئيسية (مكتمل ومغلق)
// ============================================================
__attribute__((constructor))
static void setup() {
    MOD_LOG(@"🚀 Mods All-in-One loaded");
    MOD_LOG(@"📱 Base: 0x%lx", getBaseAddress());
    
    // تهيئة الماسح التلقائي
    initScanner();
    
    // تحديث نطاقات الذاكرة
    getMemoryManager().getMemoryRanges(true);
    getMemoryManager().printCacheStats();
    
    // تأخير المسح التلقائي لضمان تحميل اللعبة بالكامل
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2.0 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        MOD_LOG(@"🔄 Running initial auto-scan...");
        g_scanner->runAutoScan();
        applyAllMods();
        MOD_LOG(@"✅ Initial setup complete");
    });
    
    MOD_LOG(@"✅ All systems ready");
}

// ============================================================
// 15. دوال Export للـ UI
// ============================================================
extern "C" {
    void render_mods_ui(void);
    void toggle_mod(const char* name, bool enabled);
}

void render_mods_ui(void) {
    renderModsUI();
}

void toggle_mod(const char* name, bool enabled) {
    std::string n(name);
    if (n == "aimbot") {
        g_mods.aimbot = enabled;
        applyAimbot(enabled);
    } else if (n == "esp") {
        g_mods.espWallhack = enabled;
        applyESP(enabled);
    } else if (n == "norecoil") {
        g_mods.noRecoil = enabled;
        applyNoRecoil(enabled);
    } else if (n == "fly") {
        g_mods.flyHack = enabled;
        applyFlyHack(enabled);
    } else if (n == "jump") {
        g_mods.jumpPower = enabled;
        applyJumpPower(enabled);
    }
    MOD_LOG_FEATURE(@"%s %s", enabled ? @"✅ Enabled" : @"⏭️ Disabled", name);
}

// ============================================================
// End of Mods.mm
// ============================================================

static int selectedLanguage = 0;
static bool languageSelected = false;

void drawMenu() {
    if (!languageSelected) {
        ImGui::Begin("RavFen Mod Menu", nullptr, ImGuiWindowFlags_AlwaysAutoResize | ImGuiWindowFlags_NoCollapse);
        ImGui::SetWindowSize(ImVec2(350, 200), ImGuiCond_FirstUseEver);
        ImGui::TextColored(ImVec4(0.8f, 0.2f, 0.2f, 1.0f), "RavFen Mod Menu");
        ImGui::Separator();
        ImGui::Text("Select Language / اختيار اللغة");
        ImGui::Spacing();
        if (ImGui::Button("English", ImVec2(150, 40))) {
            selectedLanguage = 0;
            languageSelected = true;
        }
        ImGui::SameLine();
        if (ImGui::Button("العربية", ImVec2(150, 40))) {
            selectedLanguage = 1;
            languageSelected = true;
        }
        ImGui::End();
        return;
    }

    ImGui::Begin("RavFen Mod Menu", nullptr, ImGuiWindowFlags_AlwaysAutoResize | ImGuiWindowFlags_NoCollapse);
    ImGui::SetWindowSize(ImVec2(350, 400), ImGuiCond_FirstUseEver);
    ImGui::TextColored(ImVec4(0.8f, 0.2f, 0.2f, 1.0f), "RavFen Mod Menu");
    ImGui::Separator();

    if (selectedLanguage == 0) {
        ImGui::Text("Mods");
        ImGui::Separator();
        if (ImGui::Checkbox("Aimbot", &g_mods.aimbot)) {
            applyAimbot(g_mods.aimbot);
        }
        if (ImGui::Checkbox("ESP Wallhack", &g_mods.espWallhack)) {
            applyESP(g_mods.espWallhack);
        }
        if (ImGui::Checkbox("No Recoil", &g_mods.noRecoil)) {
            applyNoRecoil(g_mods.noRecoil);
        }
        if (ImGui::Checkbox("Fly Hack", &g_mods.flyHack)) {
            applyFlyHack(g_mods.flyHack);
        }
        if (ImGui::Checkbox("Jump Power", &g_mods.jumpPower)) {
            applyJumpPower(g_mods.jumpPower);
        }
        ImGui::Separator();
        if (ImGui::Button("Apply All Changes", ImVec2(320, 40))) {
            applyAllMods();
        }
        ImGui::TextDisabled("Addresses:");
        ImGui::TextDisabled("Aimbot: 0x%lx", g_mods.aimbotAddress);
        ImGui::TextDisabled("ESP: 0x%lx", g_mods.espAddress);
        ImGui::TextDisabled("No Recoil: 0x%lx", g_mods.recoilAddress);
    } else {
        ImGui::Text("الميزات");
        ImGui::Separator();
        if (ImGui::Checkbox("ايم بوت", &g_mods.aimbot)) {
            applyAimbot(g_mods.aimbot);
        }
        if (ImGui::Checkbox("كشف أماكن", &g_mods.espWallhack)) {
            applyESP(g_mods.espWallhack);
        }
        if (ImGui::Checkbox("بدون ارتداد", &g_mods.noRecoil)) {
            applyNoRecoil(g_mods.noRecoil);
        }
        if (ImGui::Checkbox("تطير", &g_mods.flyHack)) {
            applyFlyHack(g_mods.flyHack);
        }
        if (ImGui::Checkbox("قفز عالي", &g_mods.jumpPower)) {
            applyJumpPower(g_mods.jumpPower);
        }
        ImGui::Separator();
        if (ImGui::Button("تطبيق جميع التغييرات", ImVec2(320, 40))) {
            applyAllMods();
        }
        ImGui::TextDisabled("العناوين:");
        ImGui::TextDisabled("ايم بوت: 0x%lx", g_mods.aimbotAddress);
        ImGui::TextDisabled("كشف أماكن: 0x%lx", g_mods.espAddress);
        ImGui::TextDisabled("بدون ارتداد: 0x%lx", g_mods.recoilAddress);
    }

    ImGui::End();
}
// داخل كود الـ UI الخاص بك (مثلاً عند الضغط على زر Aimbot)
if (ImGui::Checkbox("Aimbot", &g_mods.aimbot)) {
    applyAimbot(g_mods.aimbot); // هذا السطر هو "الجسْر" اللي يربط الواجهة بالذاكرة
}
