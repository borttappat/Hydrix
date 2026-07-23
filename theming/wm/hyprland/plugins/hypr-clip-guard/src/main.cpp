#include <hyprland/src/plugins/PluginAPI.hpp>
#include <hyprland/src/plugins/HookSystem.hpp>
#include <hyprland/src/managers/SeatManager.hpp>
#include <hyprland/src/protocols/core/DataDevice.hpp>
#include <hyprland/src/protocols/PrimarySelection.hpp>
#include <hyprland/src/protocols/DataDeviceWlr.hpp>
#include <hyprland/src/protocols/ExtDataDevice.hpp>
#include <hyprland/src/protocols/core/Compositor.hpp>
#include <hyprland/src/protocols/XDGShell.hpp>
#include <hyprland/src/Compositor.hpp>
#include <hyprland/src/event/EventBus.hpp>

#include <wayland-server-core.h>
#include <cstring>
#include <unordered_map>
#include <string>
#include <atomic>
#include <array>
#include <cstdio>
#include <sys/time.h>

static HANDLE                                      s_handle = nullptr;
static std::unordered_map<wl_client*, std::string>  s_clientGroup;
static std::unordered_map<pid_t, std::string>       s_pidGroup;
static std::string                                  s_selSourceGroup  = "host";
static std::string                                  s_priSourceGroup  = "host";

struct HookStats {
    std::atomic<uint64_t> allowed{0};
    std::atomic<uint64_t> blocked{0};
};
static HookStats s_statsData, s_statsPri, s_statsWlr, s_statsExt;

static std::string nowTimestamp() {
    struct timeval tv;
    gettimeofday(&tv, nullptr);
    struct tm tm;
    localtime_r(&tv.tv_sec, &tm);
    char buf[32];
    snprintf(buf, sizeof(buf), "%02d:%02d:%02d.%03ld",
             tm.tm_hour, tm.tm_min, tm.tm_sec, tv.tv_usec / 1000);
    return buf;
}

struct EventEntry {
    std::string ts;
    std::string hook;
    std::string srcGroup;
    std::string dstGroup;
    pid_t       dstPid;
    bool        allowed;
};
static std::array<EventEntry, 256> s_eventLog;
static std::atomic<uint64_t>       s_eventIdx{0};

static void logEvent(const std::string& hook, const std::string& src, const std::string& dst, pid_t pid, bool allowed) {
    auto idx = s_eventIdx.fetch_add(1) % s_eventLog.size();
    s_eventLog[idx] = {nowTimestamp(), hook, src, dst, pid, allowed};
}

static CHyprSignalListener s_windowOpenListener;
static CHyprSignalListener s_windowTitleListener;
static CHyprSignalListener s_windowCloseListener;

static WP<IDataSource>     s_lastSelWP;
static WP<IDataSource>     s_lastPriWP;

static CFunctionHook*      s_hookDataSend    = nullptr;
static CFunctionHook*      s_hookPriSend     = nullptr;
static CFunctionHook*      s_hookWlrSend     = nullptr;
static CFunctionHook*      s_hookExtSend     = nullptr;
static CFunctionHook*      s_hookExtInit     = nullptr;
static CFunctionHook*      s_hookWlrInit     = nullptr;

static std::string extractVmGroup(const std::string& title) {
    if (title.size() < 3 || title[0] != '[')
        return "host";
    auto end = title.find(']', 1);
    if (end == std::string::npos || end == 1)
        return "host";
    return title.substr(1, end - 1);
}

static pid_t getPid(wl_client* cl) {
    pid_t pid = 0;
    if (cl)
        wl_client_get_credentials(cl, &pid, nullptr, nullptr);
    return pid;
}

static pid_t getPpid(pid_t pid) {
    if (pid <= 0)
        return 0;
    char path[64];
    snprintf(path, sizeof(path), "/proc/%d/stat", pid);
    FILE* f = fopen(path, "r");
    if (!f)
        return 0;
    pid_t ppid = 0;
    char buf[4096];
    if (fgets(buf, sizeof(buf), f)) {
        char* p = strrchr(buf, ')');
        if (p) {
            char state;
            sscanf(p + 2, "%c %d", &state, &ppid);
        }
    }
    fclose(f);
    return ppid;
}

static wl_client* clientFromWindow(PHLWINDOW w) {
    if (!w)
        return nullptr;
    auto xdg = w->m_xdgSurface.lock();
    if (xdg) {
        auto surf = xdg->m_surface.lock();
        if (surf)
            return surf->client();
    }
    return nullptr;
}

static void tagClient(wl_client* cl, const std::string& group) {
    s_clientGroup[cl] = group;
    if (group != "host") {
        pid_t pid = getPid(cl);
        if (pid > 0) {
            s_pidGroup[pid] = group;
            pid_t ppid = getPpid(pid);
            if (ppid > 1)
                s_pidGroup[ppid] = group;
        }
    }
}

static void onWindowOpen(PHLWINDOW w) {
    if (!w)
        return;
    auto* cl = clientFromWindow(w);
    if (!cl)
        return;
    tagClient(cl, extractVmGroup(w->m_title));
}

static void onWindowTitle(PHLWINDOW w) {
    if (!w)
        return;
    auto* cl = clientFromWindow(w);
    if (!cl)
        return;
    tagClient(cl, extractVmGroup(w->m_title));
}

static void onWindowClose(PHLWINDOW w) {
    if (!w)
        return;
    auto* cl = clientFromWindow(w);
    if (cl)
        s_clientGroup.erase(cl);
}

static std::string groupForClient(wl_client* cl) {
    if (!cl)
        return "host";
    auto it = s_clientGroup.find(cl);
    if (it != s_clientGroup.end())
        return it->second;
    pid_t pid = getPid(cl);
    if (pid > 0) {
        auto pit = s_pidGroup.find(pid);
        if (pit != s_pidGroup.end()) {
            s_clientGroup[cl] = pit->second;
            return pit->second;
        }
        pid_t ppid = getPpid(pid);
        if (ppid > 1) {
            auto ppit = s_pidGroup.find(ppid);
            if (ppit != s_pidGroup.end()) {
                s_clientGroup[cl] = ppit->second;
                return ppit->second;
            }
        }
    }
    return "host";
}

static std::string groupFromKeyboardFocus() {
    auto surf = g_pSeatManager->m_state.keyboardFocus.lock();
    if (surf)
        return groupForClient(surf->client());
    return "host";
}

static std::string groupForSource(SP<IDataSource> src, const std::string& cached) {
    if (!src)
        return cached;

    auto* raw = src.get();

    if (auto* s = dynamic_cast<CWLDataSourceResource*>(raw)) {
        auto dev = s->m_device.lock();
        if (dev)
            return groupForClient(dev->client());
    }
    if (auto* s = dynamic_cast<CPrimarySelectionSource*>(raw)) {
        auto dev = s->m_device.lock();
        if (dev)
            return groupForClient(dev->client());
    }
    if (auto* s = dynamic_cast<CWLRDataSource*>(raw)) {
        auto dev = s->m_device.lock();
        if (dev)
            return groupForClient(dev->client());
    }
    if (auto* s = dynamic_cast<CExtDataSource*>(raw)) {
        auto dev = s->m_device.lock();
        if (dev)
            return groupForClient(dev->client());
    }

    return cached;
}

static void seedSelSource(SP<IDataSource> sel) {
    auto prev = s_lastSelWP.lock();
    if (sel != prev) {
        s_lastSelWP = sel;
        s_selSourceGroup = groupFromKeyboardFocus();
    }
}

static void seedPriSource(SP<IDataSource> sel) {
    auto prev = s_lastPriWP.lock();
    if (sel != prev) {
        s_lastPriWP = sel;
        s_priSourceGroup = groupFromKeyboardFocus();
    }
}

static bool shouldAllow(const std::string& srcGroup, const std::string& dstGroup) {
    if (srcGroup == dstGroup) return true;
    if (dstGroup == "host") return true;
    if (srcGroup == "host") return dstGroup == groupFromKeyboardFocus();
    return false;
}

// Hook: CWLDataDeviceProtocol::sendSelectionToDevice(SP<IDataDevice>, SP<IDataSource>)
typedef void (*tSendSelData)(void*, SP<IDataDevice>, SP<IDataSource>);
static void hkSendSelectionToDevice(void* thisptr, SP<IDataDevice> dev, SP<IDataSource> sel) {
    auto wlDev = dev->getWayland();
    if (wlDev) {
        seedSelSource(sel);
        auto* cl = wlDev->client();
        std::string dstGroup = groupForClient(cl);
        std::string srcGroup = groupForSource(sel, s_selSourceGroup);
        s_selSourceGroup = srcGroup;

        if (!shouldAllow(srcGroup, dstGroup)) {
            s_statsData.blocked++;
            logEvent("data", srcGroup, dstGroup, getPid(cl), false);
            return;
        }
        s_statsData.allowed++;
        logEvent("data", srcGroup, dstGroup, getPid(cl), true);
    }

    auto orig = (tSendSelData)s_hookDataSend->m_original;
    orig(thisptr, dev, sel);
}

// Hook: CPrimarySelectionProtocol::sendSelectionToDevice(SP<CPrimarySelectionDevice>, SP<IDataSource>)
typedef void (*tSendPriSel)(void*, SP<CPrimarySelectionDevice>, SP<IDataSource>);
static void hkSendPrimarySelectionToDevice(void* thisptr, SP<CPrimarySelectionDevice> dev, SP<IDataSource> sel) {
    if (dev) {
        seedPriSource(sel);
        auto* cl = dev->client();
        std::string dstGroup = groupForClient(cl);
        std::string srcGroup = groupForSource(sel, s_priSourceGroup);
        s_priSourceGroup = srcGroup;

        if (!shouldAllow(srcGroup, dstGroup)) {
            s_statsPri.blocked++;
            logEvent("pri", srcGroup, dstGroup, getPid(cl), false);
            return;
        }
        s_statsPri.allowed++;
        logEvent("pri", srcGroup, dstGroup, getPid(cl), true);
    }

    auto orig = (tSendPriSel)s_hookPriSend->m_original;
    orig(thisptr, dev, sel);
}

// Hook: CDataDeviceWLRProtocol::sendSelectionToDevice(SP<CWLRDataDevice>, SP<IDataSource>, bool)
typedef void (*tSendWlrSel)(void*, SP<CWLRDataDevice>, SP<IDataSource>, bool);
static void hkSendWlrSelectionToDevice(void* thisptr, SP<CWLRDataDevice> dev, SP<IDataSource> sel, bool primary) {
    if (dev) {
        if (primary) seedPriSource(sel); else seedSelSource(sel);
        auto* cl = dev->client();
        std::string dstGroup = groupForClient(cl);
        std::string srcGroup = groupForSource(sel, primary ? s_priSourceGroup : s_selSourceGroup);
        (primary ? s_priSourceGroup : s_selSourceGroup) = srcGroup;

        if (!shouldAllow(srcGroup, dstGroup)) {
            s_statsWlr.blocked++;
            logEvent("wlr", srcGroup, dstGroup, getPid(cl), false);
            return;
        }
        s_statsWlr.allowed++;
        logEvent("wlr", srcGroup, dstGroup, getPid(cl), true);
    }

    auto orig = (tSendWlrSel)s_hookWlrSend->m_original;
    orig(thisptr, dev, sel, primary);
}

// Hook: CExtDataDeviceProtocol::sendSelectionToDevice(SP<CExtDataDevice>, SP<IDataSource>, bool)
typedef void (*tSendExtSel)(void*, SP<CExtDataDevice>, SP<IDataSource>, bool);
static void hkSendExtSelectionToDevice(void* thisptr, SP<CExtDataDevice> dev, SP<IDataSource> sel, bool primary) {
    if (dev) {
        if (primary) seedPriSource(sel); else seedSelSource(sel);
        auto* cl = dev->client();
        std::string dstGroup = groupForClient(cl);
        std::string srcGroup = groupForSource(sel, primary ? s_priSourceGroup : s_selSourceGroup);
        (primary ? s_priSourceGroup : s_selSourceGroup) = srcGroup;

        if (!shouldAllow(srcGroup, dstGroup)) {
            s_statsExt.blocked++;
            logEvent("ext", srcGroup, dstGroup, getPid(cl), false);
            return;
        }
        s_statsExt.allowed++;
        logEvent("ext", srcGroup, dstGroup, getPid(cl), true);
    }

    auto orig = (tSendExtSel)s_hookExtSend->m_original;
    orig(thisptr, dev, sel, primary);
}

// Hook: CExtDataDevice::sendInitialSelections() — bypasses sendSelectionToDevice
typedef void (*tSendInitial)(void*);
static void hkExtSendInitialSelections(void* thisptr) {
    auto* self = reinterpret_cast<CExtDataDevice*>(thisptr);
    auto* cl = self->client();
    std::string dstGroup = groupForClient(cl);

    if (dstGroup == "host" ||
        (shouldAllow(s_selSourceGroup, dstGroup) && shouldAllow(s_priSourceGroup, dstGroup))) {
        logEvent("ext-init", s_selSourceGroup, dstGroup, getPid(cl), true);
        auto orig = (tSendInitial)s_hookExtInit->m_original;
        orig(thisptr);
        return;
    }
    s_statsExt.blocked++;
    logEvent("ext-init", s_selSourceGroup, dstGroup, getPid(cl), false);
}

// Hook: CWLRDataDevice::sendInitialSelections() — bypasses sendSelectionToDevice
static void hkWlrSendInitialSelections(void* thisptr) {
    auto* self = reinterpret_cast<CWLRDataDevice*>(thisptr);
    auto* cl = self->client();
    std::string dstGroup = groupForClient(cl);

    if (dstGroup == "host" ||
        (shouldAllow(s_selSourceGroup, dstGroup) && shouldAllow(s_priSourceGroup, dstGroup))) {
        logEvent("wlr-init", s_selSourceGroup, dstGroup, getPid(cl), true);
        auto orig = (tSendInitial)s_hookWlrInit->m_original;
        orig(thisptr);
        return;
    }
    s_statsWlr.blocked++;
    logEvent("wlr-init", s_selSourceGroup, dstGroup, getPid(cl), false);
}

static std::string handleHyprctl(eHyprCtlOutputFormat fmt, std::string req) {
    std::string out;

    uint64_t totalBlocked = s_statsData.blocked + s_statsPri.blocked + s_statsWlr.blocked + s_statsExt.blocked;
    uint64_t totalAllowed = s_statsData.allowed + s_statsPri.allowed + s_statsWlr.allowed + s_statsExt.allowed;

    if (fmt == eHyprCtlOutputFormat::FORMAT_NORMAL) {
        out = "clip-guard status\n";
        out += "  selection source: " + s_selSourceGroup + "\n";
        out += "  primary source:   " + s_priSourceGroup + "\n";
        out += "  totals: " + std::to_string(totalBlocked) + " blocked, " + std::to_string(totalAllowed) + " allowed\n";
        out += "  per-hook:\n";
        out += "    data:  " + std::to_string(s_statsData.allowed.load()) + " allowed, " + std::to_string(s_statsData.blocked.load()) + " blocked\n";
        out += "    pri:   " + std::to_string(s_statsPri.allowed.load()) + " allowed, " + std::to_string(s_statsPri.blocked.load()) + " blocked\n";
        out += "    wlr:   " + std::to_string(s_statsWlr.allowed.load()) + " allowed, " + std::to_string(s_statsWlr.blocked.load()) + " blocked\n";
        out += "    ext:   " + std::to_string(s_statsExt.allowed.load()) + " allowed, " + std::to_string(s_statsExt.blocked.load()) + " blocked\n";
        out += "  client groups:\n";
        for (auto& [cl, grp] : s_clientGroup) {
            pid_t pid = getPid(cl);
            pid_t ppid = getPpid(pid);
            out += "    " + std::to_string((uintptr_t)cl) + " -> " + grp + " (pid " + std::to_string(pid) + ", ppid " + std::to_string(ppid) + ")\n";
        }
        out += "  pid map:\n";
        for (auto& [pid, grp] : s_pidGroup) {
            out += "    pid " + std::to_string(pid) + " -> " + grp + "\n";
        }
        out += "  recent events (newest first):\n";
        uint64_t idx = s_eventIdx.load();
        uint64_t count = std::min(idx, (uint64_t)s_eventLog.size());
        for (uint64_t i = 0; i < count; i++) {
            auto& e = s_eventLog[(idx - 1 - i) % s_eventLog.size()];
            out += "    " + e.ts + " [" + e.hook + "] " + e.srcGroup + " -> " + e.dstGroup
                 + " (pid " + std::to_string(e.dstPid) + ") "
                 + (e.allowed ? "ALLOWED" : "BLOCKED") + "\n";
        }
    } else {
        out = "{\"selectionSource\":\"" + s_selSourceGroup + "\","
              "\"primarySource\":\"" + s_priSourceGroup + "\","
              "\"blocked\":" + std::to_string(totalBlocked) + ","
              "\"allowed\":" + std::to_string(totalAllowed) + "}";
    }

    return out;
}

APICALL EXPORT std::string PLUGIN_API_VERSION() {
    return HYPRLAND_API_VERSION;
}

APICALL EXPORT PLUGIN_DESCRIPTION_INFO PLUGIN_INIT(HANDLE handle) {
    s_handle = handle;

    const auto ver = HyprlandAPI::getHyprlandVersion(handle);
    HyprlandAPI::addNotification(handle, "[clip-guard] loaded for Hyprland " + ver.tag, CHyprColor{0.2, 0.8, 0.4, 1.0}, 3000);

    s_windowOpenListener  = Event::bus()->m_events.window.open.listen(onWindowOpen);
    s_windowTitleListener = Event::bus()->m_events.window.title.listen(onWindowTitle);
    s_windowCloseListener = Event::bus()->m_events.window.close.listen(onWindowClose);

    for (auto& w : g_pCompositor->m_windows) {
        if (!w)
            continue;
        auto* cl = clientFromWindow(w);
        if (cl)
            tagClient(cl, extractVmGroup(w->m_title));
    }

    auto matches = HyprlandAPI::findFunctionsByName(handle, "sendSelectionToDevice");

    for (auto& m : matches) {
        if (m.demangled.contains("CWLDataDeviceProtocol")) {
            s_hookDataSend = HyprlandAPI::createFunctionHook(handle, m.address, (void*)hkSendSelectionToDevice);
            if (s_hookDataSend)
                s_hookDataSend->hook();
        }
        if (m.demangled.contains("CPrimarySelectionProtocol")) {
            s_hookPriSend = HyprlandAPI::createFunctionHook(handle, m.address, (void*)hkSendPrimarySelectionToDevice);
            if (s_hookPriSend)
                s_hookPriSend->hook();
        }
        if (m.demangled.contains("CDataDeviceWLRProtocol")) {
            s_hookWlrSend = HyprlandAPI::createFunctionHook(handle, m.address, (void*)hkSendWlrSelectionToDevice);
            if (s_hookWlrSend)
                s_hookWlrSend->hook();
        }
        if (m.demangled.contains("CExtDataDeviceProtocol")) {
            s_hookExtSend = HyprlandAPI::createFunctionHook(handle, m.address, (void*)hkSendExtSelectionToDevice);
            if (s_hookExtSend)
                s_hookExtSend->hook();
        }
    }

    auto initMatches = HyprlandAPI::findFunctionsByName(handle, "sendInitialSelections");
    for (auto& m : initMatches) {
        if (m.demangled.contains("CExtDataDevice")) {
            s_hookExtInit = HyprlandAPI::createFunctionHook(handle, m.address, (void*)hkExtSendInitialSelections);
            if (s_hookExtInit)
                s_hookExtInit->hook();
        }
        if (m.demangled.contains("CWLRDataDevice")) {
            s_hookWlrInit = HyprlandAPI::createFunctionHook(handle, m.address, (void*)hkWlrSendInitialSelections);
            if (s_hookWlrInit)
                s_hookWlrInit->hook();
        }
    }

    int hooked = 0;
    if (s_hookDataSend) hooked++;
    if (s_hookPriSend) hooked++;
    if (s_hookWlrSend) hooked++;
    if (s_hookExtSend) hooked++;
    if (s_hookExtInit) hooked++;
    if (s_hookWlrInit) hooked++;

    HyprlandAPI::addNotification(handle, "[clip-guard] hooked " + std::to_string(hooked) + "/6 clipboard methods", CHyprColor{0.2, 0.8, 0.4, 1.0}, 3000);

    HyprlandAPI::registerHyprCtlCommand(handle, SHyprCtlCommand{
        .name  = "clipguard",
        .exact = false,
        .fn    = handleHyprctl,
    });

    return {"hypr-clip-guard", "VM clipboard isolation", "hydrix", "0.1.0"};
}

APICALL EXPORT void PLUGIN_EXIT() {
    if (s_hookDataSend)
        s_hookDataSend->unhook();
    if (s_hookPriSend)
        s_hookPriSend->unhook();
    if (s_hookWlrSend)
        s_hookWlrSend->unhook();
    if (s_hookExtSend)
        s_hookExtSend->unhook();
    if (s_hookExtInit)
        s_hookExtInit->unhook();
    if (s_hookWlrInit)
        s_hookWlrInit->unhook();

    s_windowOpenListener.reset();
    s_windowTitleListener.reset();
    s_windowCloseListener.reset();

    s_clientGroup.clear();
    s_pidGroup.clear();
}
