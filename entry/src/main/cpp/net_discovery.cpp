// Native helpers for LAN discovery over interfaces that @ohos.net.socket can't target.
//
// Why this module exists: when the phone runs its own hotspot (SoftAP), the system's
// default data network is still cellular. Every UDP datagram sent through
// @ohos.net.socket follows the default route and leaves through cellular, so the
// LocalSend announce never reaches the devices attached to the hotspot —
// and netConnection.getAllNetsSync() does not even expose the SoftAP network to
// third-party apps, so there is no NetHandle to bind to either.
//
// Down here at POSIX level the interface is visible and usable:
//   * getifaddrs() enumerates ap0 / swlan0 and its 192.168.43.x address;
//   * bind()-ing the socket to that address plus IP_MULTICAST_IF forces the
//     kernel to route the datagram out through the hotspot interface.
// That makes the multicast announce (and the directed broadcast) reach peers on
// the hotspot without any new permission.
//
// VERIFICATION STATUS (2026-09-20): compile-verified only
// (`clang++ --target={aarch64,x86_64}-unknown-linux-ohos -std=c++17 -Wall -fsyntax-only`).
// NOT verified on a real device. The assumptions still unproven are: getifaddrs()
// exposing the SoftAP to a third-party app sandbox, IP_ADD_MEMBERSHIP accepting an
// explicit imr_interface, bind() to the multicast address being permitted, and the
// loopback-relayed datagram actually reaching the ArkTS socket. See
// docs/HOTSPOT_SHARING.md "验证状态".
#include <napi/native_api.h>
#include <hilog/log.h>

#include <arpa/inet.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <netinet/in.h>
// netdb.h: NI_MAXHOST / NI_NUMERICHOST used by getnameinfo() when enumerating
// interface addresses. Without it the module fails to compile outright.
#include <netdb.h>
#include <poll.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>

#include <atomic>
#include <cerrno>
#include <cstdio>
#include <cstring>
#include <string>
#include <thread>
#include <vector>

// Sockets kept open purely to hold multicast memberships on hotspot interfaces.
// A membership lives as long as the socket that requested it; closing the socket
// drops it. These are never read from — the kernel copies each matching datagram
// to every socket that joined the group on that port, so the ArkTS socket still
// receives its own copy.
std::vector<int> gJoinedFds;

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0xFF00
#define LOG_TAG "NETDISCOVERY"

#define ND_LOGI(...) OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG, __VA_ARGS__)
#define ND_LOGW(...) OH_LOG_Print(LOG_APP, LOG_WARN, LOG_DOMAIN, LOG_TAG, __VA_ARGS__)
#define ND_LOGE(...) OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG, __VA_ARGS__)

namespace {

bool ReadStringArg(napi_env env, napi_value value, std::string &out, size_t maxLen) {
    size_t len = 0;
    if (napi_get_value_string_utf8(env, value, nullptr, 0, &len) != napi_ok) {
        return false;
    }
    if (len == 0 || len > maxLen) {
        return false;
    }
    out.resize(len + 1, '\0');
    size_t copied = 0;
    if (napi_get_value_string_utf8(env, value, &out[0], len + 1, &copied) != napi_ok) {
        return false;
    }
    out.resize(copied);
    return true;
}

/**
 * getInterfaces(): [{ name: string, address: string }]
 *
 * Every IPv4 interface currently configured, loopback excluded. The ArkTS side
 * matches on `name` (ap0 / swlan0 / softap0 / rndis0 …) and on the address to
 * tell a hotspot interface apart from the cellular one.
 */
napi_value GetInterfaces(napi_env env, napi_callback_info /*info*/) {
    napi_value result = nullptr;
    napi_create_array(env, &result);

    struct ifaddrs *ifaddr = nullptr;
    if (getifaddrs(&ifaddr) != 0) {
        ND_LOGE("getifaddrs failed errno=%{public}d", errno);
        return result;
    }

    uint32_t index = 0;
    for (struct ifaddrs *ifa = ifaddr; ifa != nullptr; ifa = ifa->ifa_next) {
        if (ifa->ifa_addr == nullptr || ifa->ifa_addr->sa_family != AF_INET) {
            continue;
        }
        char host[NI_MAXHOST] = {0};
        if (getnameinfo(ifa->ifa_addr, sizeof(struct sockaddr_in), host, sizeof(host),
                        nullptr, 0, NI_NUMERICHOST) != 0) {
            continue;
        }
        if (strncmp(host, "127.", 4) == 0) {
            continue;
        }
        napi_value entry = nullptr;
        napi_value nameValue = nullptr;
        napi_value addressValue = nullptr;
        napi_create_object(env, &entry);
        napi_create_string_utf8(env, ifa->ifa_name, NAPI_AUTO_LENGTH, &nameValue);
        napi_create_string_utf8(env, host, NAPI_AUTO_LENGTH, &addressValue);
        napi_set_named_property(env, entry, "name", nameValue);
        napi_set_named_property(env, entry, "address", addressValue);
        napi_set_element(env, result, index, entry);
        index++;
    }
    freeifaddrs(ifaddr);
    ND_LOGI("getInterfaces returned %{public}u interfaces", index);
    return result;
}

/**
 * sendDatagram(target, port, ifaceAddress, data): boolean
 *
 * Sends one UDP datagram and forces it out through `ifaceAddress`:
 *   - bind() to that local address picks the route (critical for directed
 *     broadcast, which otherwise follows the default/cellular route);
 *   - IP_MULTICAST_IF selects the multicast egress interface;
 *   - SO_BROADCAST lets 192.168.x.255 targets through;
 *   - IP_MULTICAST_TTL>1 so the packet isn't dropped on the first hop.
 */
napi_value SendDatagram(napi_env env, napi_callback_info info) {
    size_t argc = 4;
    napi_value args[4] = {nullptr, nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    std::string target;
    std::string iface;
    std::string data;
    int32_t port = 0;
    if (argc < 4
        || !ReadStringArg(env, args[0], target, 64)
        || !ReadStringArg(env, args[2], iface, 64)
        || !ReadStringArg(env, args[3], data, 65536)
        || napi_get_value_int32(env, args[1], &port) != napi_ok
        || port <= 0 || port > 65535) {
        napi_value invalid = nullptr;
        napi_get_boolean(env, false, &invalid);
        return invalid;
    }

    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) {
        ND_LOGE("socket failed errno=%{public}d", errno);
        napi_value failed = nullptr;
        napi_get_boolean(env, false, &failed);
        return failed;
    }

    struct in_addr ifaceAddr;
    memset(&ifaceAddr, 0, sizeof(ifaceAddr));
    if (!iface.empty() && inet_pton(AF_INET, iface.c_str(), &ifaceAddr) == 1) {
        // Multicast egress interface.
        if (setsockopt(fd, IPPROTO_IP, IP_MULTICAST_IF, &ifaceAddr, sizeof(ifaceAddr)) != 0) {
            ND_LOGW("IP_MULTICAST_IF %{public}s failed errno=%{public}d", iface.c_str(), errno);
        }
        // Bind to the interface address: this is what actually pins the route for
        // unicast/broadcast targets, not just multicast.
        struct sockaddr_in src;
        memset(&src, 0, sizeof(src));
        src.sin_family = AF_INET;
        src.sin_addr = ifaceAddr;
        src.sin_port = 0;
        if (bind(fd, reinterpret_cast<struct sockaddr *>(&src), sizeof(src)) != 0) {
            ND_LOGW("bind %{public}s failed errno=%{public}d", iface.c_str(), errno);
        }
    }

    int broadcast = 1;
    if (setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &broadcast, sizeof(broadcast)) != 0) {
        ND_LOGW("SO_BROADCAST failed errno=%{public}d", errno);
    }
    unsigned char ttl = 4;
    if (setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, sizeof(ttl)) != 0) {
        ND_LOGW("IP_MULTICAST_TTL failed errno=%{public}d", errno);
    }

    struct sockaddr_in dst;
    memset(&dst, 0, sizeof(dst));
    dst.sin_family = AF_INET;
    dst.sin_port = htons(static_cast<uint16_t>(port));
    bool ok = inet_pton(AF_INET, target.c_str(), &dst.sin_addr) == 1;
    ssize_t sent = -1;
    if (ok) {
        sent = sendto(fd, data.data(), data.size(), 0,
                      reinterpret_cast<struct sockaddr *>(&dst), sizeof(dst));
    }
    if (sent < 0) {
        ND_LOGE("sendto %{public}s:%{public}d via %{public}s failed errno=%{public}d",
                target.c_str(), port, iface.c_str(), errno);
    } else {
        ND_LOGI("sent %{public}d bytes to %{public}s:%{public}d via %{public}s",
                static_cast<int>(sent), target.c_str(), port, iface.c_str());
    }
    close(fd);

    napi_value result = nullptr;
    napi_get_boolean(env, ok && sent == static_cast<ssize_t>(data.size()), &result);
    return result;
}

/**
 * joinMulticastOn(group, port, ifaceAddress): boolean
 *
 * Adds an IGMP membership for `group` on one specific interface. @ohos.net.socket's
 * MulticastSocket joins through the default network only, so while the phone shares
 * its hotspot the SoftAP interface never joins and announcements from the connected
 * PC are dropped by the kernel. Doing it down here with an explicit imr_interface
 * makes the kernel accept those datagrams on ap0.
 *
 * The socket is deliberately kept open (see gJoinedFds) and never read: the kernel
 * delivers a copy to every socket that joined the group on that port, so the ArkTS
 * socket still sees the announcement.
 */
napi_value JoinMulticastOn(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3] = {nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    std::string group;
    std::string iface;
    int32_t port = 0;
    if (argc < 3
        || !ReadStringArg(env, args[0], group, 64)
        || !ReadStringArg(env, args[2], iface, 64)
        || napi_get_value_int32(env, args[1], &port) != napi_ok
        || port <= 0 || port > 65535) {
        napi_value invalid = nullptr;
        napi_get_boolean(env, false, &invalid);
        return invalid;
    }

    struct in_addr groupAddr;
    struct in_addr ifaceAddr;
    memset(&groupAddr, 0, sizeof(groupAddr));
    memset(&ifaceAddr, 0, sizeof(ifaceAddr));
    if (inet_pton(AF_INET, group.c_str(), &groupAddr) != 1
        || inet_pton(AF_INET, iface.c_str(), &ifaceAddr) != 1) {
        napi_value invalid = nullptr;
        napi_get_boolean(env, false, &invalid);
        return invalid;
    }

    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) {
        ND_LOGE("join: socket failed errno=%{public}d", errno);
        napi_value failed = nullptr;
        napi_get_boolean(env, false, &failed);
        return failed;
    }

    int reuse = 1;
    if (setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse)) != 0) {
        ND_LOGW("join: SO_REUSEADDR failed errno=%{public}d", errno);
    }
    // This socket only *holds* the membership; nothing ever reads from it. Cap the
    // receive buffer so a chatty group (mDNS on 5353 especially) can't pile up an
    // unread backlog and push the host into UDP memory pressure, which would
    // throttle *other* sockets — including the system mDNS responder that
    // Windows Nearby Sharing depends on. Drops here are ours alone and harmless.
    int rcvbuf = 4096;
    setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcvbuf, sizeof(rcvbuf));
    struct sockaddr_in local;
    memset(&local, 0, sizeof(local));
    local.sin_family = AF_INET;
    // Membership holders must not compete with the ArkTS unicast reader.
    local.sin_addr = groupAddr;
    local.sin_port = htons(static_cast<uint16_t>(port));
    if (bind(fd, reinterpret_cast<struct sockaddr *>(&local), sizeof(local)) != 0) {
        ND_LOGE("join: bind :%{public}d failed errno=%{public}d", port, errno);
        close(fd);
        napi_value failed = nullptr;
        napi_get_boolean(env, false, &failed);
        return failed;
    }

    struct ip_mreq mreq;
    memset(&mreq, 0, sizeof(mreq));
    mreq.imr_multiaddr = groupAddr;
    mreq.imr_interface = ifaceAddr;
    bool joined = setsockopt(fd, IPPROTO_IP, IP_ADD_MEMBERSHIP, &mreq, sizeof(mreq)) == 0;
    if (joined) {
        gJoinedFds.push_back(fd);
        ND_LOGI("joined %{public}s on %{public}s (port %{public}d)", group.c_str(), iface.c_str(), port);
    } else {
        ND_LOGE("IP_ADD_MEMBERSHIP %{public}s on %{public}s failed errno=%{public}d",
                group.c_str(), iface.c_str(), errno);
        close(fd);
    }

    napi_value result = nullptr;
    napi_get_boolean(env, joined, &result);
    return result;
}

// ---------------------------------------------------------------------------
// Multicast relay: make announcements arriving on the hotspot reachable.
//
// Even after the hotspot interface joins the group, the *ArkTS* socket is the
// one whose 'message' handler feeds the device list — and it only joined the
// group on the default network. A datagram that arrives on ap0 therefore never
// reaches it, which is exactly why "the phone never sees the PC".
//
// The relay closes that gap without touching the ArkTS socket: it listens on the
// hotspot interface itself and re-injects every datagram as a loopback unicast
// to 127.0.0.1:<port>, where the ArkTS socket is the only listener.
//
// Two details make this safe:
//   * the listening socket binds to the *multicast address*, not 0.0.0.0, so it
//     stays out of the unicast lookup path — peer unicast replies still land on
//     the ArkTS socket exactly as before;
//   * only datagrams whose source is on the hotspot subnet are relayed, which
//     also breaks the relay's own loop (our injected copy comes from 127.0.0.1).
struct Relay {
    int fd = -1;
    std::atomic<bool> running{false};
    std::thread worker;
    std::string iface;
    std::string group;
    int port = 0;
};
Relay gRelay;

/** True when both addresses sit in the same /24 (text compare of the first 3 octets). */
bool SameSubnet(const std::string &a, const std::string &b) {
    auto thirdDot = [](const std::string &s) -> size_t {
        size_t n = 0;
        for (size_t i = 0; i < s.size() && n < 3; ++i) {
            if (s[i] == '.') {
                ++n;
            }
        }
        return n < 3 ? std::string::npos : s.find('.', s.find('.', s.find('.') + 1) + 1);
    };
    size_t ca = thirdDot(a);
    size_t cb = thirdDot(b);
    if (ca == std::string::npos || cb == std::string::npos) {
        return false;
    }
    return a.compare(0, ca, b, 0, cb) == 0;
}

/** Minimal JSON string escaping — the payload is re-parsed as JSON on the ArkTS side. */
std::string JsonQuote(const std::string &in) {
    std::string out = "\"";
    for (unsigned char c : in) {
        if (c == '"') {
            out += "\\\"";
        } else if (c == '\\') {
            out += "\\\\";
        } else if (c == '\n') {
            out += "\\n";
        } else if (c == '\r') {
            out += "\\r";
        } else if (c == '\t') {
            out += "\\t";
        } else if (c < 0x20) {
            char esc[8] = {0};
            snprintf(esc, sizeof(esc), "\\u%04x", c);
            out += esc;
        } else {
            out += static_cast<char>(c);
        }
    }
    out += "\"";
    return out;
}

void StopRelayInternal() {
    if (gRelay.running.load()) {
        gRelay.running.store(false);
        if (gRelay.worker.joinable()) {
            gRelay.worker.join();  // poll() timeout is 200 ms, so this returns quickly
        }
    }
    if (gRelay.fd >= 0) {
        close(gRelay.fd);
        gRelay.fd = -1;
    }
    gRelay.iface.clear();
    gRelay.group.clear();
    gRelay.port = 0;
}

void RelayLoop(int fd, int port, const std::string &ifaceNet) {
    int out = socket(AF_INET, SOCK_DGRAM, 0);
    if (out < 0) {
        ND_LOGE("relay: out socket failed errno=%{public}d", errno);
        return;
    }
    std::vector<char> buf(65536);
    while (gRelay.running.load()) {
        struct pollfd pfd;
        pfd.fd = fd;
        pfd.events = POLLIN;
        pfd.revents = 0;
        int ready = poll(&pfd, 1, 200);
        if (ready <= 0) {
            continue;
        }
        struct sockaddr_in src;
        memset(&src, 0, sizeof(src));
        socklen_t slen = sizeof(src);
        ssize_t n = recvfrom(fd, buf.data(), buf.size() - 1, 0,
                             reinterpret_cast<struct sockaddr *>(&src), &slen);
        if (n <= 0) {
            continue;
        }
        buf[n] = '\0';
        char from[INET_ADDRSTRLEN] = {0};
        inet_ntop(AF_INET, &src.sin_addr, from, sizeof(from));
        // Self filter: our own multicast announcements loop back (IP_MULTICAST_LOOP is on
        // by default) with the interface address as source. They are not peer announcements,
        // and the SameSubnet check below cannot exclude them because our own source address
        // IS on the hotspot subnet (真机 2026-09-20: every announce cycle produced one
        // "relayed ... from 192.0.2.10" line — our own packet, not a peer's).
        if (src.sin_addr.s_addr == inet_addr(ifaceNet.c_str())) {
            continue;
        }
        if (!SameSubnet(from, ifaceNet)) {
            continue;  // not from the hotspot subnet (also drops our own loopback copy)
        }
        std::string payload = "{\"__relay\":true,\"from\":";
        payload += JsonQuote(from);
        payload += ",\"port\":" + std::to_string(ntohs(src.sin_port));
        payload += ",\"data\":" + JsonQuote(std::string(buf.data(), static_cast<size_t>(n)));
        payload += "}";
        struct sockaddr_in dst;
        memset(&dst, 0, sizeof(dst));
        dst.sin_family = AF_INET;
        dst.sin_port = htons(static_cast<uint16_t>(port));
        inet_pton(AF_INET, "127.0.0.1", &dst.sin_addr);
        ssize_t sent = sendto(out, payload.data(), payload.size(), 0,
                              reinterpret_cast<struct sockaddr *>(&dst), sizeof(dst));
        if (sent < 0) {
            ND_LOGW("relay: inject failed errno=%{public}d", errno);
        } else {
            ND_LOGI("relayed %{public}d bytes from %{public}s to loopback:%{public}d",
                    static_cast<int>(n), from, port);
        }
    }
    close(out);
}

/**
 * startRelay(ifaceAddress, port, group): boolean
 *
 * Starts listening for `group` datagrams on the hotspot interface and re-injecting
 * them to 127.0.0.1:<port> so the ArkTS socket sees them. See the long comment
 * above for why binding to the multicast address (not 0.0.0.0) matters.
 */
napi_value StartRelay(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3] = {nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    std::string iface;
    std::string group;
    int32_t port = 0;
    if (argc < 3
        || !ReadStringArg(env, args[0], iface, 64)
        || !ReadStringArg(env, args[2], group, 64)
        || napi_get_value_int32(env, args[1], &port) != napi_ok
        || port <= 0 || port > 65535) {
        napi_value invalid = nullptr;
        napi_get_boolean(env, false, &invalid);
        return invalid;
    }
    if (gRelay.running.load() && gRelay.iface == iface && gRelay.group == group && gRelay.port == port) {
        napi_value already = nullptr;
        napi_get_boolean(env, true, &already);
        return already;
    }

    StopRelayInternal();

    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) {
        ND_LOGE("relay: socket failed errno=%{public}d", errno);
        napi_value failed = nullptr;
        napi_get_boolean(env, false, &failed);
        return failed;
    }
    int reuse = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));

    struct sockaddr_in local;
    memset(&local, 0, sizeof(local));
    local.sin_family = AF_INET;
    local.sin_port = htons(static_cast<uint16_t>(port));
    if (inet_pton(AF_INET, group.c_str(), &local.sin_addr) != 1
        || bind(fd, reinterpret_cast<struct sockaddr *>(&local), sizeof(local)) != 0) {
        ND_LOGE("relay: bind %{public}s:%{public}d failed errno=%{public}d", group.c_str(), port, errno);
        close(fd);
        napi_value failed = nullptr;
        napi_get_boolean(env, false, &failed);
        return failed;
    }

    struct in_addr ifaceAddr;
    memset(&ifaceAddr, 0, sizeof(ifaceAddr));
    struct in_addr groupAddr;
    memset(&groupAddr, 0, sizeof(groupAddr));
    if (inet_pton(AF_INET, iface.c_str(), &ifaceAddr) != 1
        || inet_pton(AF_INET, group.c_str(), &groupAddr) != 1) {
        close(fd);
        napi_value failed = nullptr;
        napi_get_boolean(env, false, &failed);
        return failed;
    }
    struct ip_mreq mreq;
    memset(&mreq, 0, sizeof(mreq));
    mreq.imr_multiaddr = groupAddr;
    mreq.imr_interface = ifaceAddr;
    if (setsockopt(fd, IPPROTO_IP, IP_ADD_MEMBERSHIP, &mreq, sizeof(mreq)) != 0) {
        ND_LOGE("relay: IP_ADD_MEMBERSHIP %{public}s on %{public}s failed errno=%{public}d",
                group.c_str(), iface.c_str(), errno);
        close(fd);
        napi_value failed = nullptr;
        napi_get_boolean(env, false, &failed);
        return failed;
    }

    gRelay.fd = fd;
    gRelay.iface = iface;
    gRelay.group = group;
    gRelay.port = port;
    gRelay.running.store(true);
    gRelay.worker = std::thread(RelayLoop, fd, port, iface);
    ND_LOGI("relay started on %{public}s for %{public}s:%{public}d", iface.c_str(), group.c_str(), port);

    napi_value ok = nullptr;
    napi_get_boolean(env, true, &ok);
    return ok;
}

/** stopRelay(): void — stops the relay thread and drops its socket. */
napi_value StopRelay(napi_env env, napi_callback_info /*info*/) {
    StopRelayInternal();
    ND_LOGI("relay stopped");
    napi_value undef = nullptr;
    napi_get_undefined(env, &undef);
    return undef;
}

/** leaveAllMulticast(): void — drops every membership held by joinMulticastOn(). */
napi_value LeaveAllMulticast(napi_env env, napi_callback_info /*info*/) {
    for (int fd : gJoinedFds) {
        close(fd);
    }
    size_t count = gJoinedFds.size();
    gJoinedFds.clear();
    ND_LOGI("left %{public}zu multicast memberships", count);
    napi_value undef = nullptr;
    napi_get_undefined(env, &undef);
    return undef;
}

}  // namespace

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        { "getInterfaces", nullptr, GetInterfaces, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "sendDatagram", nullptr, SendDatagram, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "joinMulticastOn", nullptr, JoinMulticastOn, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "leaveAllMulticast", nullptr, LeaveAllMulticast, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "startRelay", nullptr, StartRelay, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "stopRelay", nullptr, StopRelay, nullptr, nullptr, nullptr, napi_default, nullptr },
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}
EXTERN_C_END

static napi_module netDiscoveryModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "net_discovery",
    .nm_priv = nullptr,
    .reserved = { 0 },
};

extern "C" __attribute__((constructor)) void RegisterNetDiscoveryModule(void) {
    napi_module_register(&netDiscoveryModule);
}
