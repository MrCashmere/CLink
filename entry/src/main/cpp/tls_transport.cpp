// LocalSend TLS transport (NAPI) — mbedTLS over a native POSIX socket, event-driven.
//
// THREADING MODEL:
//   Each connection gets its own worker thread. The mbedTLS handshake, all ssl_read
//   and all ssl_write run on that thread (never on the JS thread). Data/close are
//   delivered to ArkTS through a napi_threadsafe_function. send() enqueues bytes and
//   wakes the worker via a pipe; close() requests shutdown the same way.
//
//   This means the JS side never blocks on TLS I/O.
//
// SOCKET OWNERSHIP (no @ohos.net.socket in the TLS data path):
//   The earlier design handed an @ohos.net.socket fd (getSocketFd) to mbedTLS, but the
//   framework keeps an event loop on that fd, so both it and mbedTLS recv() from the
//   same descriptor and the handshake stalls. Here the native module creates the socket
//   itself with POSIX calls (connect / listen / accept), so mbedTLS owns the fd
//   exclusively. ArkTS only sees opaque handles.
//
// SCOPE / CAVEATS:
//   - Written against mbedTLS 3.6.0 (vendored under entry/src/main/cpp/mbedtls).
//   - Channel ownership is shared (std::shared_ptr) between the worker thread, the
//     registry map, and any in-flight ArkTS send()/close() call. Channels are removed
//     from the map and freed only once their last reference drops, so a send()/close()
//     racing the worker's teardown cannot touch freed memory.

#include "napi/native_api.h"

#include <mbedtls/ssl.h>
#include <mbedtls/ssl_ciphersuites.h>
#include <mbedtls/net_sockets.h>
#include <mbedtls/entropy.h>
#include <mbedtls/ctr_drbg.h>
#include <mbedtls/error.h>
#include <mbedtls/x509_crt.h>
#include <mbedtls/pk.h>
#include <psa/crypto.h>

#include <algorithm>
#include <chrono>
#include <deque>
#include <map>
#include <memory>
#include <mutex>
#include <atomic>
#include <string>
#include <thread>
#include <vector>
#include <cstring>
#include <cerrno>
#include <cstdio>
#include <fcntl.h>
#include <poll.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <hilog/log.h>

namespace {

constexpr int CONNECT_TIMEOUT_MS = 8000;
constexpr size_t MAX_QUEUED_WRITE_BYTES = 1024 * 1024;
constexpr size_t WRITE_RECORD_BYTES = 16 * 1024;
constexpr int CLOSE_DRAIN_TIMEOUT_MS = 4000;
// An idle worker (handshake or read loop) must never block forever in poll(-1): a peer
// that connects and then goes silent would pin a worker thread and leak the channel.
constexpr int HANDSHAKE_TIMEOUT_MS = 15000;
constexpr int READ_IDLE_TIMEOUT_MS = 120000;
// When we tear down a connection we must emit a TLS close_notify before closing the
// socket. reqwest/rustls treats a TCP FIN without close_notify as a truncation
// ("peer closed connection without sending TLS close_notify" / "unexpected EOF") and
// fails — which is exactly what the LocalSend sender (OPPO) reports. On a healthy
// connection this writes in one syscall (no stall); the timeout only bounds the rare
// case where the peer has stopped reading and the send buffer is full.
constexpr int CLOSE_NOTIFY_RETRY_MS = 250;

// Native diagnostic logging. The TLS handshake runs on a worker thread and this module
// previously emitted no hilog at all, so any handshake stall/failure on device was
// unobservable. These let a hilog capture tell us exactly what mbedTLS returns.
constexpr unsigned int TLS_LOG_DOMAIN = 0xD000D;
static const char *const TLS_LOG_TAG = "TlsNative";
#define TLS_LOGI(fmt, ...) OH_LOG_Print(LOG_APP, LOG_INFO, TLS_LOG_DOMAIN, TLS_LOG_TAG, fmt, ##__VA_ARGS__)
#define TLS_LOGE(fmt, ...) OH_LOG_Print(LOG_APP, LOG_ERROR, TLS_LOG_DOMAIN, TLS_LOG_TAG, fmt, ##__VA_ARGS__)

// ---- custom BIO over an OS socket fd ----
static int io_send(void *ctx, const unsigned char *buf, size_t len) {
    int fd = *static_cast<int *>(ctx);
    long sent = send(fd, buf, len, 0);
    if (sent < 0) {
        if (errno == EAGAIN || errno == EWOULDBLOCK) return MBEDTLS_ERR_SSL_WANT_WRITE;
        return MBEDTLS_ERR_NET_SEND_FAILED;
    }
    return static_cast<int>(sent);
}

static int io_recv(void *ctx, unsigned char *buf, size_t len) {
    int fd = *static_cast<int *>(ctx);
    long got = recv(fd, buf, len, 0);
    if (got == 0) return MBEDTLS_ERR_SSL_PEER_CLOSE_NOTIFY;
    if (got < 0) {
        if (errno == EAGAIN || errno == EWOULDBLOCK) return MBEDTLS_ERR_SSL_WANT_READ;
        return MBEDTLS_ERR_NET_RECV_FAILED;
    }
    return static_cast<int>(got);
}

static bool SetNonBlocking(int fd) {
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags < 0) return false;
    return fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0;
}

// ---- native socket helpers (skipping @ohos.net.socket entirely) ----
static int TcpConnectAddr(const struct sockaddr *addr, socklen_t addrlen, int timeoutMs) {
    int fd = socket(addr->sa_family, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    SetNonBlocking(fd);
    int rc = connect(fd, addr, addrlen);
    if (rc < 0 && errno != EINPROGRESS) { ::close(fd); return -1; }
    if (rc < 0) {
        struct pollfd pfd = { fd, POLLOUT, 0 };
        int pr = poll(&pfd, 1, timeoutMs);
        if (pr <= 0) { ::close(fd); return -1; }
        int soerr = 0;
        socklen_t slen = sizeof(soerr);
        if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &soerr, &slen) != 0 || soerr != 0) {
            ::close(fd); return -1;
        }
    }
    return fd;
}

static int TcpConnect(const std::string &host, int port, int timeoutMs) {
    struct addrinfo hints = {};
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    char portstr[16];
    snprintf(portstr, sizeof(portstr), "%d", port);
    struct addrinfo *res = nullptr;
    if (getaddrinfo(host.c_str(), portstr, &hints, &res) != 0) return -1;
    int fd = -1;
    for (struct addrinfo *ai = res; ai != nullptr; ai = ai->ai_next) {
        fd = TcpConnectAddr(ai->ai_addr, ai->ai_addrlen, timeoutMs);
        if (fd >= 0) break;
    }
    freeaddrinfo(res);
    return fd;
}

static int TcpListen(int port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    struct sockaddr_in addr = {};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    addr.sin_port = htons(static_cast<uint16_t>(port));
    if (bind(fd, reinterpret_cast<struct sockaddr *>(&addr), sizeof(addr)) != 0) {
        ::close(fd); return -1;
    }
    if (listen(fd, 32) != 0) { ::close(fd); return -1; }
    return fd;
}

static std::string PeerIp(int fd) {
    struct sockaddr_storage ss = {};
    socklen_t len = sizeof(ss);
    if (getpeername(fd, reinterpret_cast<struct sockaddr *>(&ss), &len) != 0) return "";
    char ip[INET6_ADDRSTRLEN] = {0};
    if (ss.ss_family == AF_INET) {
        inet_ntop(AF_INET, &reinterpret_cast<struct sockaddr_in *>(&ss)->sin_addr, ip, sizeof(ip));
    } else if (ss.ss_family == AF_INET6) {
        inet_ntop(AF_INET6, &reinterpret_cast<struct sockaddr_in6 *>(&ss)->sin6_addr, ip, sizeof(ip));
    }
    return ip;
}

// ---- per-connection channel ----
struct NativeEvent {
    enum Kind { DATA, CLOSED } kind;
    std::vector<unsigned char> bytes;
    char msg[256] = {0};
};

struct Channel {
    int fd = -1;
    int handle = 0;
    bool is_server = false;
    napi_threadsafe_function tsfn = nullptr;

    mbedtls_ssl_context ssl;
    mbedtls_ssl_config conf;
    mbedtls_entropy_context entropy;
    mbedtls_ctr_drbg_context drbg;
    mbedtls_x509_crt own_cert;
    mbedtls_pk_context own_key;
    mbedtls_x509_crt ca;

    std::thread worker;
    std::mutex mtx;
    std::deque<std::vector<unsigned char>> writeQ;
    size_t queuedWriteBytes = 0;
    std::atomic<bool> closeReq{false};

    int wakeFd[2] = {-1, -1};   // [0] read, [1] write

    Channel()
        : ssl{}, conf{}, entropy{}, drbg{}, own_cert{}, own_key{}, ca{} {
        mbedtls_ssl_init(&ssl);
        mbedtls_ssl_config_init(&conf);
        mbedtls_entropy_init(&entropy);
        mbedtls_ctr_drbg_init(&drbg);
        mbedtls_x509_crt_init(&own_cert);
        mbedtls_pk_init(&own_key);
        mbedtls_x509_crt_init(&ca);
    }

    ~Channel() {
        mbedtls_ssl_free(&ssl);
        mbedtls_ssl_config_free(&conf);
        mbedtls_ctr_drbg_free(&drbg);
        mbedtls_entropy_free(&entropy);
        mbedtls_x509_crt_free(&own_cert);
        mbedtls_pk_free(&own_key);
        mbedtls_x509_crt_free(&ca);
        if (fd >= 0) ::close(fd);
        if (wakeFd[0] >= 0) { ::close(wakeFd[0]); ::close(wakeFd[1]); }
    }
};

std::map<int, std::shared_ptr<Channel>> g_channels;
std::mutex g_mutex;
int g_next_handle = 1;

int AddChannel(std::shared_ptr<Channel> c) {
    std::lock_guard<std::mutex> lk(g_mutex);
    int h = g_next_handle++;
    g_channels[h] = c;
    c->handle = h;
    return h;
}

std::shared_ptr<Channel> GetChannel(int handle) {
    std::lock_guard<std::mutex> lk(g_mutex);
    auto it = g_channels.find(handle);
    return it == g_channels.end() ? nullptr : it->second;
}

void RemoveChannel(int handle) {
    std::lock_guard<std::mutex> lk(g_mutex);
    g_channels.erase(handle);
}

// ---- listening socket state (native accept loop) ----
struct AcceptEvent {
    int fd = -1;
    std::string peerIp;
};

struct ListenState {
    std::atomic<int> listenFd{-1};
    int handle = 0;
    std::atomic<bool> running{true};
    napi_threadsafe_function tsfn = nullptr;
    std::thread thread;
};

std::map<int, ListenState *> g_listeners;
int g_next_listen_handle = 1;

int AddListener(ListenState *ls) {
    std::lock_guard<std::mutex> lk(g_mutex);
    int h = g_next_listen_handle++;
    g_listeners[h] = ls;
    ls->handle = h;
    return h;
}

ListenState *GetListener(int handle) {
    std::lock_guard<std::mutex> lk(g_mutex);
    auto it = g_listeners.find(handle);
    return it == g_listeners.end() ? nullptr : it->second;
}

void RemoveListener(int handle) {
    std::lock_guard<std::mutex> lk(g_mutex);
    g_listeners.erase(handle);
}

// call_js for a per-connection event: (chunk?:ArrayBuffer, err?:string). null chunk = closed.
void TsfnCallBytes(napi_env env, napi_value js_cb, void * /*context*/, void *data) {
    std::unique_ptr<NativeEvent> ev(static_cast<NativeEvent *>(data));
    if (env == nullptr || js_cb == nullptr) return;
    napi_value arg0, arg1;
    if (ev->kind == NativeEvent::CLOSED) {
        napi_get_null(env, &arg0);
        if (ev->msg[0] != '\0') {
            napi_create_string_utf8(env, ev->msg, NAPI_AUTO_LENGTH, &arg1);
        } else {
            napi_get_null(env, &arg1);
        }
    } else {
        void *arr = nullptr;
        napi_create_arraybuffer(env, ev->bytes.size(), &arr, &arg0);
        if (arr && !ev->bytes.empty()) std::memcpy(arr, ev->bytes.data(), ev->bytes.size());
        napi_get_null(env, &arg1);
    }
    napi_value global;
    napi_get_global(env, &global);
    napi_value ret;
    napi_value args[2] = {arg0, arg1};
    napi_call_function(env, global, js_cb, 2, args, &ret);
}

// call_js for the listening socket: notifies ArkTS of an accepted raw fd + peer ip.
void TsfnCallAccept(napi_env env, napi_value js_cb, void * /*context*/, void *data) {
    std::unique_ptr<AcceptEvent> ev(static_cast<AcceptEvent *>(data));
    if (env == nullptr || js_cb == nullptr) {
        ::close(ev->fd);
        return;
    }
    napi_value arg1, arg2;
    napi_create_int32(env, ev->fd, &arg1);
    napi_create_string_utf8(env, ev->peerIp.c_str(), NAPI_AUTO_LENGTH, &arg2);
    napi_value global;
    napi_get_global(env, &global);
    napi_value ret;
    napi_value args[2] = { arg1, arg2 };
    napi_call_function(env, global, js_cb, 2, args, &ret);
}

void WakeWorker(Channel *c) {
    if (c->wakeFd[1] >= 0) {
        unsigned char b = 1;
        ssize_t unused = write(c->wakeFd[1], &b, 1);
        (void)unused;
    }
}

void Emit(Channel *c, NativeEvent::Kind kind, const unsigned char *bytes, size_t len, const char *msg = nullptr) {
    NativeEvent *ev = new NativeEvent();
    ev->kind = kind;
    if (kind == NativeEvent::DATA && len > 0) {
        ev->bytes.assign(bytes, bytes + len);
    }
    if (msg != nullptr) {
        snprintf(ev->msg, sizeof(ev->msg), "%s", msg);
    }
    if (c->tsfn == nullptr || napi_call_threadsafe_function(c->tsfn, ev, napi_tsfn_blocking) != napi_ok) {
        delete ev;
    }
}

void ReleaseTsfn(Channel *c) {
    if (c->tsfn != nullptr) {
        napi_release_threadsafe_function(c->tsfn, napi_tsfn_release);
        c->tsfn = nullptr;
    }
}

// Poll until the fd is ready for the direction mbedTLS wants, or the wake pipe fires.
// Returns: 0 = fd ready, 1 = woken, -1 = poll error, -2 = timed out.
int WaitFor(Channel *c, int want, int timeoutMs = -1) {
    struct pollfd pfds[2];
    pfds[0].fd = c->fd;
    pfds[0].events = (want == MBEDTLS_ERR_SSL_WANT_WRITE) ? POLLOUT : POLLIN;
    pfds[0].revents = 0;
    pfds[1].fd = c->wakeFd[0];
    pfds[1].events = POLLIN;
    pfds[1].revents = 0;

    int ret = poll(pfds, 2, timeoutMs);
    if (ret == 0) return -2;   // timed out
    if (ret < 0) return -1;
    if (pfds[1].revents & POLLIN) {
        unsigned char drain[64];
        while (read(c->wakeFd[0], drain, sizeof(drain)) > 0) {}
        return 1;
    }
    return (pfds[0].revents & (POLLIN | POLLOUT | POLLHUP | POLLERR)) ? 0 : -1;
}

// Best-effort TLS close_notify before teardown. Without it, a rustls/reqwest peer
// interprets the abrupt socket close as a truncation ("peer closed connection without
// sending TLS close_notify") and surfaces a client error even though the transfer itself
// succeeded. mbedtls_ssl_close_notify can return WANT_READ/WANT_WRITE until the alert
// record is written; we poll for the readiness with a bounded budget and then give up.
static void BestEffortCloseNotify(Channel *c) {
    if (c->fd < 0) return;
    int ret = mbedtls_ssl_close_notify(&c->ssl);
    for (int i = 0;
         i < 6 && (ret == MBEDTLS_ERR_SSL_WANT_READ || ret == MBEDTLS_ERR_SSL_WANT_WRITE);
         ++i) {
        int w = WaitFor(c, ret, CLOSE_NOTIFY_RETRY_MS);
        if (w != 0) break;   // woken / poll error / timed out — abandon the alert
        ret = mbedtls_ssl_close_notify(&c->ssl);
    }
    if (ret != 0 && ret != MBEDTLS_ERR_SSL_WANT_READ && ret != MBEDTLS_ERR_SSL_WANT_WRITE) {
        TLS_LOGI("%{public}s close_notify ret=%{public}d", c->is_server ? "srv" : "cli", ret);
    }
}

// Worker: handshake (client or server) then read/write loop. Owns the channel entirely.
static const char *PeerAlertName(unsigned char code);  // defined below with the other helpers

void WorkerMain(std::shared_ptr<Channel> c) {
    SetNonBlocking(c->fd);

    int ret = MBEDTLS_ERR_SSL_WANT_READ;
    bool handshakeTimedOut = false;
    const auto handshakeDeadline = std::chrono::steady_clock::now() +
                                   std::chrono::milliseconds(HANDSHAKE_TIMEOUT_MS);
    while (!c->closeReq.load()) {
        ret = mbedtls_ssl_handshake(&c->ssl);
        if (ret == 0) break;
        if (ret == MBEDTLS_ERR_SSL_WANT_READ || ret == MBEDTLS_ERR_SSL_WANT_WRITE) {
            auto left = std::chrono::duration_cast<std::chrono::milliseconds>(
                handshakeDeadline - std::chrono::steady_clock::now()).count();
            int w = left > 0 ? WaitFor(c.get(), ret, static_cast<int>(left)) : -2;
            if (w == 1) continue;
            if (w == -2) { handshakeTimedOut = true; TLS_LOGE("handshake timed out after %{public}dms", HANDSHAKE_TIMEOUT_MS); break; }
            if (w < 0) break;
            continue;
        }
        break;   // fatal handshake error
    }
    if (ret != 0 || c->closeReq.load()) {
        const char *side = c->is_server ? "srv" : "cli";
        char errmsg[256] = {0};
        if (handshakeTimedOut) {
            snprintf(errmsg, sizeof(errmsg), "handshake timed out");
            TLS_LOGE("%{public}s %{public}s", side, errmsg);
        } else if (ret != 0) {
            char desc[192] = {0};
            mbedtls_strerror(ret, desc, sizeof(desc));
            snprintf(errmsg, sizeof(errmsg), "handshake failed ret=0x%04X %s", (unsigned)ret, desc);
            // On a peer fatal alert mbedTLS leaves the alert in in_msg: [0]=level, [1]=description.
            if (ret == MBEDTLS_ERR_SSL_FATAL_ALERT_MESSAGE &&
                c->ssl.MBEDTLS_PRIVATE(in_msg) != nullptr) {
                unsigned char lvl = c->ssl.MBEDTLS_PRIVATE(in_msg)[0];
                unsigned char a = c->ssl.MBEDTLS_PRIVATE(in_msg)[1];
                char extra[80];
                snprintf(extra, sizeof(extra), " peer-alert-level=%u peer-alert=%s(%u)",
                         lvl, PeerAlertName(a), a);
                strncat(errmsg, extra, sizeof(errmsg) - strlen(errmsg) - 1);
            }
            TLS_LOGE("%{public}s handshake failed ret=%{public}d (%{public}s)", side, ret, errmsg);
        } else {
            TLS_LOGI("%{public}s handshake aborted (close during handshake)", side);
            snprintf(errmsg, sizeof(errmsg), "handshake aborted");
        }
        Emit(c.get(), NativeEvent::CLOSED, nullptr, 0, errmsg);
        RemoveChannel(c->handle);
        ReleaseTsfn(c.get());
        return;
    }
    TLS_LOGI("%{public}s handshake OK ver=%{public}s cipher=%{public}s",
             c->is_server ? "srv" : "cli",
             mbedtls_ssl_get_version(&c->ssl),
             mbedtls_ssl_get_ciphersuite(&c->ssl));

    unsigned char buf[16384];
    char loopErr[256] = {0};
    std::vector<unsigned char> pending;
    size_t offset = 0;
    auto closeDeadline = std::chrono::steady_clock::time_point::max();
    bool graceful = false;
    while (true) {
        const bool closing = c->closeReq.load();
        if (closing && closeDeadline == std::chrono::steady_clock::time_point::max()) {
            closeDeadline = std::chrono::steady_clock::now() +
                            std::chrono::milliseconds(CLOSE_DRAIN_TIMEOUT_MS);
        }
        if (std::chrono::steady_clock::now() >= closeDeadline) break;
        if (pending.empty()) {
            std::lock_guard<std::mutex> lk(c->mtx);
            if (!c->writeQ.empty()) {
                pending = std::move(c->writeQ.front());
                c->writeQ.pop_front();
                offset = 0;
            }
        }
        int want = MBEDTLS_ERR_SSL_WANT_READ;
        if (!pending.empty()) {
            // WANT_READ/WANT_WRITE must retry with the same pointer and length.
            // Producers append to writeQ; only this worker owns pending.
            size_t count = std::min(WRITE_RECORD_BYTES, pending.size() - offset);
            int n = mbedtls_ssl_write(&c->ssl, pending.data() + offset, count);
            if (n > 0) {
                {
                    std::lock_guard<std::mutex> lk(c->mtx);
                    c->queuedWriteBytes -= static_cast<size_t>(n);
                }
                offset += static_cast<size_t>(n);
                if (offset == pending.size()) pending.clear();
                continue;
            }
            if (n != MBEDTLS_ERR_SSL_WANT_READ && n != MBEDTLS_ERR_SSL_WANT_WRITE) {
                mbedtls_strerror(n, loopErr, sizeof(loopErr));
                break;
            }
            want = n;
        } else if (closing) {
            graceful = true;
            break;
        } else {
            int n = mbedtls_ssl_read(&c->ssl, buf, sizeof(buf));
            if (n > 0) {
                Emit(c.get(), NativeEvent::DATA, buf, static_cast<size_t>(n));
                // More plaintext can already be buffered inside mbedTLS.
                continue;
            }
            if (n != MBEDTLS_ERR_SSL_WANT_READ && n != MBEDTLS_ERR_SSL_WANT_WRITE) {
                if (n == MBEDTLS_ERR_SSL_PEER_CLOSE_NOTIFY) graceful = true;
                else if (n < 0) mbedtls_strerror(n, loopErr, sizeof(loopErr));
                break;
            }
            want = n;
        }

        int timeout = READ_IDLE_TIMEOUT_MS;
        if (closing) {
            auto left = std::chrono::duration_cast<std::chrono::milliseconds>(
                closeDeadline - std::chrono::steady_clock::now()).count();
            if (left <= 0) break;
            timeout = static_cast<int>(left);
        }
        int wait = WaitFor(c.get(), want, timeout);
        if (wait < 0) {
            snprintf(loopErr, sizeof(loopErr), "%s", wait == -2 ? "TLS I/O timeout" : "TLS poll failed");
            break;
        }
    }
    {
        std::lock_guard<std::mutex> lk(c->mtx);
        c->closeReq = true;
    }
    if (graceful) BestEffortCloseNotify(c.get());

    Emit(c.get(), NativeEvent::CLOSED, nullptr, 0, (loopErr[0] != '\0') ? loopErr : nullptr);
    RemoveChannel(c->handle);
    ReleaseTsfn(c.get());
}

// Native accept loop: accepts raw sockets and notifies ArkTS, which then calls accept()
// on each fd to run the mbedTLS server handshake. No @ohos.net.socket in the loop.
void AcceptLoop(ListenState *ls) {
    while (ls->running.load()) {
        int listenFd = ls->listenFd.load();
        if (listenFd < 0) break;
        struct pollfd pfd = { listenFd, POLLIN, 0 };
        int r = poll(&pfd, 1, 200);
        if (r < 0) {
            if (errno == EINTR) continue;
            break;
        }
        if (r == 0) continue;
        if (!(pfd.revents & POLLIN)) continue;
        int clientFd = accept(listenFd, nullptr, nullptr);
        if (clientFd < 0) {
            if (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) continue;
            break;
        }
        AcceptEvent *ev = new AcceptEvent();
        ev->fd = clientFd;
        ev->peerIp = PeerIp(clientFd);
        TLS_LOGI("accept fd=%{public}d peerIp=%{public}s", clientFd, ev->peerIp.c_str());
        if (ls->tsfn != nullptr) {
            napi_call_threadsafe_function(ls->tsfn, ev, napi_tsfn_blocking);
        } else {
            ::close(clientFd);
            delete ev;
        }
    }
    // Only the thread that wins the atomic exchange closes the fd (StopListen may race us).
    int fd = ls->listenFd.exchange(-1);
    if (fd >= 0) ::close(fd);
}

void Throw(napi_env env, const char *msg) {
    napi_throw_error(env, nullptr, msg);
}

bool OptString(napi_env env, napi_value obj, const char *key, std::string &out) {
    bool has = false;
    if (napi_has_named_property(env, obj, key, &has) != napi_ok || !has) return false;
    napi_value v;
    if (napi_get_named_property(env, obj, key, &v) != napi_ok) return false;
    napi_valuetype t;
    if (napi_typeof(env, v, &t) != napi_ok || t != napi_string) return false;
    size_t len = 0;
    if (napi_get_value_string_utf8(env, v, nullptr, 0, &len) != napi_ok) return false;
    std::vector<char> buf(len + 1);
    if (napi_get_value_string_utf8(env, v, buf.data(), buf.size(), &len) != napi_ok) return false;
    out.assign(buf.data(), len);
    return true;
}

bool OptBool(napi_env env, napi_value obj, const char *key, bool def) {
    bool has = false;
    if (napi_has_named_property(env, obj, key, &has) != napi_ok || !has) return def;
    napi_value v;
    if (napi_get_named_property(env, obj, key, &v) != napi_ok) return def;
    bool b = def;
    if (napi_get_value_bool(env, v, &b) != napi_ok) return def;
    return b;
}

// True if s is a dotted IPv4 literal. Such a value must NOT be sent as TLS SNI
// (RFC 6066 forbids IP literals in server_name), and some peers abort a
// ClientHello that carries an IP there.
static bool LooksLikeIpLiteral(const std::string &s) {
    if (s.empty()) return false;
    for (char ch : s) {
        if (!(ch == '.' || (ch >= '0' && ch <= '9'))) return false;
    }
    return true;
}

// Map a TLS alert description byte (RFC 8446 §6.2 -> TLS 1.2 RFC 5246 §7.2) to a name,
// for diagnostics when the peer rejects our handshake with a fatal alert.
static const char *PeerAlertName(unsigned char code) {
    switch (code) {
        case 0: return "close_notify";
        case 10: return "unexpected_message";
        case 20: return "bad_record_mac";
        case 21: return "decryption_failed";
        case 22: return "record_overflow";
        case 30: return "decompression_failure";
        case 40: return "handshake_failure";
        case 42: return "bad_certificate";
        case 43: return "unsupported_certificate";
        case 44: return "certificate_revoked";
        case 45: return "certificate_expired";
        case 46: return "certificate_unknown";
        case 47: return "illegal_parameter";
        case 48: return "unknown_ca";
        case 49: return "access_denied";
        case 50: return "decode_error";
        case 51: return "decrypt_error";
        case 70: return "protocol_version";
        case 71: return "insufficient_security";
        case 80: return "internal_error";
        case 90: return "user_canceled";
        case 100: return "no_renegotiation";
        case 110: return "unsupported_extension";
        case 112: return "unrecognized_name";
        case 113: return "bad_certificate_status_response";
        case 116: return "certificate_required";
        case 120: return "no_application_protocol";  // ALPN
        default: return "unknown_alert";
    }
}

// Build an mbedTLS channel for an already-open fd, then spawn the worker.
// onEvent must be a JS function; the channel's tsfn wraps it (data ArrayBuffer | null=closed).
std::shared_ptr<Channel> SetupChannel(int fd, bool is_server, napi_env env, napi_value opts,
                                      napi_value onEvent, std::string &outErr) {
    if (fd < 0) { outErr = "bad fd"; return nullptr; }

    std::string host, certPem, keyPem;
    bool skipVerify = OptBool(env, opts, "skipVerify", false);
    bool requestClient = OptBool(env, opts, "requestClientCert", false);
    OptString(env, opts, "host", host);
    OptString(env, opts, "certPem", certPem);
    OptString(env, opts, "keyPem", keyPem);

    std::shared_ptr<Channel> c = std::make_shared<Channel>();
    c->fd = fd;
    c->is_server = is_server;

    int ret = mbedtls_ctr_drbg_seed(&c->drbg, mbedtls_entropy_func, &c->entropy, nullptr, 0);
    if (ret != 0) { outErr = "drbg"; return nullptr; }

    ret = mbedtls_ssl_config_defaults(&c->conf,
                                      is_server ? MBEDTLS_SSL_IS_SERVER : MBEDTLS_SSL_IS_CLIENT,
                                      MBEDTLS_SSL_TRANSPORT_STREAM,
                                      MBEDTLS_SSL_PRESET_DEFAULT);
    if (ret != 0) { outErr = "conf"; return nullptr; }
    mbedtls_ssl_conf_rng(&c->conf, mbedtls_ctr_drbg_random, &c->drbg);

    if (is_server) {
        if (certPem.empty() || keyPem.empty()) {
            outErr = "missing cert/key"; return nullptr;
        }
        if (mbedtls_x509_crt_parse(&c->own_cert, (const unsigned char *)certPem.c_str(),
                                   certPem.size() + 1) < 0 ||
            mbedtls_pk_parse_key(&c->own_key, (const unsigned char *)keyPem.c_str(),
                                 keyPem.size() + 1, nullptr, 0,
                                 mbedtls_ctr_drbg_random, &c->drbg) != 0) {
            outErr = "cert/key parse"; return nullptr;
        }
        mbedtls_ssl_conf_authmode(&c->conf, requestClient ? MBEDTLS_SSL_VERIFY_OPTIONAL
                                                          : MBEDTLS_SSL_VERIFY_NONE);
        mbedtls_ssl_conf_ca_chain(&c->conf, &c->ca, nullptr);
        mbedtls_ssl_conf_own_cert(&c->conf, &c->own_cert, &c->own_key);
    } else {
        std::string caPem;
        OptString(env, opts, "serverCA", caPem);
        bool verifyRequired = !skipVerify;
        mbedtls_ssl_conf_authmode(&c->conf, verifyRequired ? MBEDTLS_SSL_VERIFY_REQUIRED
                                                           : MBEDTLS_SSL_VERIFY_NONE);
        // Offer both TLS 1.2 and 1.3. The peer's HTTPS server rejected a TLS-1.2-only
        // ClientHello with a fatal alert (it wants TLS 1.3), so we must NOT cap to 1.2.
        mbedtls_ssl_conf_min_tls_version(&c->conf, MBEDTLS_SSL_VERSION_TLS1_2);
        mbedtls_ssl_conf_max_tls_version(&c->conf, MBEDTLS_SSL_VERSION_TLS1_3);
        // Load caller-supplied trust roots only. Unverified LocalSend peers do
        // not need a common certificate embedded in the application.
        if (!caPem.empty()) {
            if (mbedtls_x509_crt_parse(&c->ca, (const unsigned char *)caPem.c_str(),
                                      caPem.size() + 1) < 0) {
                outErr = "ca parse"; return nullptr;
            }
            mbedtls_ssl_conf_ca_chain(&c->conf, &c->ca, nullptr);
        }
        // LocalSend speaks HTTP/1.1 over TLS; advertise ALPN so the peer offers a
        // selected protocol instead of rejecting an unnegotiated handshake.
        static const char *kAlpn[] = {"http/1.1", nullptr};
        mbedtls_ssl_conf_alpn_protocols(&c->conf, kAlpn);
        std::string certPemClient, keyPemClient;
        OptString(env, opts, "certPem", certPemClient);
        OptString(env, opts, "keyPem", keyPemClient);
        if (!certPemClient.empty() && !keyPemClient.empty()) {
            if (mbedtls_x509_crt_parse(&c->own_cert, (const unsigned char *)certPemClient.c_str(),
                                       certPemClient.size() + 1) < 0 ||
                mbedtls_pk_parse_key(&c->own_key, (const unsigned char *)keyPemClient.c_str(),
                                     keyPemClient.size() + 1, nullptr, 0,
                                     mbedtls_ctr_drbg_random, &c->drbg) != 0) {
                outErr = "client cert/key parse"; return nullptr;
            }
            mbedtls_ssl_conf_own_cert(&c->conf, &c->own_cert, &c->own_key);
        }
    }

    ret = mbedtls_ssl_setup(&c->ssl, &c->conf);
    if (ret != 0) { outErr = "ssl setup"; return nullptr; }
    if (!is_server && !host.empty() && !LooksLikeIpLiteral(host)) {
        // SNI is only valid for hostnames, not IP literals (RFC 6066), and some
        // peers reject a ClientHello carrying an IP in server_name. The peer cert is
        // not verified anyway (VERIFY_NONE), so omitting SNI for IP targets is safe.
        if (mbedtls_ssl_set_hostname(&c->ssl, host.c_str()) != 0) {
            outErr = "hostname"; return nullptr;
        }
    }
    mbedtls_ssl_set_bio(&c->ssl, &c->fd, io_send, io_recv, nullptr);

    if (pipe(c->wakeFd) != 0) {
        outErr = "pipe"; return nullptr;
    }
    SetNonBlocking(c->wakeFd[0]);
    SetNonBlocking(c->wakeFd[1]);

    napi_value asyncName;
    napi_create_string_utf8(env, "tls_transport", NAPI_AUTO_LENGTH, &asyncName);
    if (napi_create_threadsafe_function(env, onEvent, nullptr, asyncName, 64, 1,
                                        nullptr, nullptr, nullptr, TsfnCallBytes, &c->tsfn) != napi_ok) {
        outErr = "event callback setup failed";
        return nullptr;
    }

    AddChannel(c);   // sets c->handle; the caller reads c->handle after SetupChannel returns

    c->worker = std::thread(WorkerMain, c);
    c->worker.detach();

    return c;
}

// TCP/DNS dialing must not block the ArkTS thread. SetupChannel transfers the fd to
// the connection worker, where the TLS handshake and all socket I/O take place.
struct ConnectWork {
    std::string host;
    int port = 0;
    int fd = -1;
    napi_ref opts = nullptr;
    napi_ref callback = nullptr;
    napi_async_work work = nullptr;
    napi_deferred deferred = nullptr;
    ~ConnectWork() { if (fd >= 0) ::close(fd); }
};

static void ReleaseConnectWork(napi_env env, ConnectWork *job) {
    if (job->opts != nullptr) napi_delete_reference(env, job->opts);
    if (job->callback != nullptr) napi_delete_reference(env, job->callback);
    if (job->work != nullptr) napi_delete_async_work(env, job->work);
}

static void RejectConnect(napi_env env, napi_deferred deferred, const std::string &reason) {
    napi_value message, error;
    napi_create_string_utf8(env, reason.c_str(), reason.size(), &message);
    napi_create_error(env, nullptr, message, &error);
    napi_reject_deferred(env, deferred, error);
}

static void ExecuteConnect(napi_env, void *data) {
    auto *job = static_cast<ConnectWork *>(data);
    job->fd = TcpConnect(job->host, job->port, CONNECT_TIMEOUT_MS);
}

static void CompleteConnect(napi_env env, napi_status status, void *data) {
    std::unique_ptr<ConnectWork> job(static_cast<ConnectWork *>(data));
    napi_value opts, onEvent;
    std::shared_ptr<Channel> c;
    std::string err = "TCP connect failed";
    if (status == napi_ok && job->fd >= 0
        && napi_get_reference_value(env, job->opts, &opts) == napi_ok
        && napi_get_reference_value(env, job->callback, &onEvent) == napi_ok) {
        int fd = job->fd;
        job->fd = -1;
        c = SetupChannel(fd, false, env, opts, onEvent, err);
    }
    if (c == nullptr) {
        RejectConnect(env, job->deferred, err);
    } else {
        napi_value handle;
        napi_create_int32(env, c->handle, &handle);
        napi_resolve_deferred(env, job->deferred, handle);
    }
    ReleaseConnectWork(env, job.get());
}

napi_value Connect(napi_env env, napi_callback_info info) {
    size_t argc = 4;
    napi_value args[4];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    size_t len = 0;
    int32_t port = 0;
    napi_valuetype optType, cbType;
    if (argc != 4 || napi_get_value_string_utf8(env, args[0], nullptr, 0, &len) != napi_ok ||
        len == 0 || len > 255 || napi_get_value_int32(env, args[1], &port) != napi_ok ||
        port <= 0 || port > 65535 || napi_typeof(env, args[2], &optType) != napi_ok || optType != napi_object ||
        napi_typeof(env, args[3], &cbType) != napi_ok || cbType != napi_function) {
        Throw(env, "bad TLS connect args");
        return nullptr;
    }
    auto job = std::make_unique<ConnectWork>();
    std::vector<char> buf(len + 1);
    napi_get_value_string_utf8(env, args[0], buf.data(), buf.size(), &len);
    job->host.assign(buf.data(), len);
    job->port = port;
    napi_value promise, resource;
    if (napi_create_promise(env, &job->deferred, &promise) != napi_ok) {
        Throw(env, "TLS promise setup failed");
        return nullptr;
    }
    napi_create_string_utf8(env, "tls_connect", NAPI_AUTO_LENGTH, &resource);
    if (napi_create_reference(env, args[2], 1, &job->opts) != napi_ok ||
        napi_create_reference(env, args[3], 1, &job->callback) != napi_ok ||
        napi_create_async_work(env, nullptr, resource, ExecuteConnect, CompleteConnect, job.get(), &job->work) != napi_ok ||
        napi_queue_async_work(env, job->work) != napi_ok) {
        RejectConnect(env, job->deferred, "could not start TLS connection");
        ReleaseConnectWork(env, job.get());
    } else {
        job.release();
    }
    return promise;
}

// Server per-connection: mbedTLS server handshake on an accepted fd (from native listen).
napi_value Accept(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t fd = -1;
    napi_get_value_int32(env, args[0], &fd);
    napi_value opts = args[1];
    napi_value onEvent = args[2];
    if (fd < 0 || argc < 3) { Throw(env, "bad args"); return nullptr; }

    std::string err;
    std::shared_ptr<Channel> c = SetupChannel(fd, true, env, opts, onEvent, err);
    if (c == nullptr) {
        TLS_LOGE("server setup fd=%{public}d failed: %{public}s", fd, err.c_str());
        // ~Channel() already closed fd on the error path; do not close it again.
        Throw(env, err.c_str()); return nullptr;
    }
    napi_value handle;
    napi_create_int32(env, c->handle, &handle);
    return handle;
}

// Server: native listen(port) + accept loop. Notifies ArkTS of each accepted fd.
napi_value Listen(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t port = 0;
    napi_get_value_int32(env, args[0], &port);
    // args[1] = opts (certPem/keyPem used later in accept), ignored here.
    napi_value onAccept = args[2];
    if (port <= 0 || argc < 3) { Throw(env, "bad args"); return nullptr; }

    int listenFd = TcpListen(port);
    if (listenFd < 0) {
        TLS_LOGE("listen port=%{public}d failed", port);
        Throw(env, "tcp listen failed"); return nullptr;
    }
    TLS_LOGI("listen port=%{public}d -> listenFd=%{public}d", port, listenFd);

    ListenState *ls = new ListenState();
    ls->listenFd = listenFd;

    napi_value asyncName;
    napi_create_string_utf8(env, "tls_transport", NAPI_AUTO_LENGTH, &asyncName);
    napi_create_threadsafe_function(env, onAccept, nullptr, asyncName, 0, 1,
                                    nullptr, nullptr, nullptr, TsfnCallAccept, &ls->tsfn);

    int handle = AddListener(ls);
    ls->thread = std::thread(AcceptLoop, ls);

    napi_value h;
    napi_create_int32(env, handle, &h);
    return h;
}

napi_value StopListen(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t handle = -1;
    napi_get_value_int32(env, args[0], &handle);
    ListenState *ls = GetListener(handle);
    if (ls) {
        ls->running = false;
        int fd = ls->listenFd.exchange(-1);
        if (fd >= 0) ::close(fd);
        // Wait for the accept loop to fully exit before releasing the tsfn / freeing ls.
        if (ls->thread.joinable()) ls->thread.join();
        if (ls->tsfn != nullptr) {
            napi_release_threadsafe_function(ls->tsfn, napi_tsfn_release);
            ls->tsfn = nullptr;
        }
        RemoveListener(handle);
        delete ls;
    }
    napi_value undef;
    napi_get_undefined(env, &undef);
    return undef;
}

napi_value Send(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t handle = -1;
    napi_get_value_int32(env, args[0], &handle);
    std::shared_ptr<Channel> c = GetChannel(handle);
    if (!c) { Throw(env, "bad handle"); return nullptr; }

    void *buffer = nullptr;
    size_t len = 0;
    if (napi_get_arraybuffer_info(env, args[1], &buffer, &len) != napi_ok) {
        Throw(env, "bad buffer"); return nullptr;
    }
    int32_t queued = 1;
    {
        std::lock_guard<std::mutex> lk(c->mtx);
        if (c->closeReq) {
            queued = -1;
        } else if (len > MAX_QUEUED_WRITE_BYTES - c->queuedWriteBytes) {
            queued = 0;
        } else if (len > 0) {
            const auto *p = static_cast<const unsigned char *>(buffer);
            c->writeQ.emplace_back(p, p + len);
            c->queuedWriteBytes += len;
        }
    }
    if (queued > 0) WakeWorker(c.get());
    napi_value result;
    napi_create_int32(env, queued, &result);
    return result;
}

napi_value Close(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t handle = -1;
    napi_get_value_int32(env, args[0], &handle);
    std::shared_ptr<Channel> c = GetChannel(handle);
    if (c) {
        {
            std::lock_guard<std::mutex> lk(c->mtx);
            c->closeReq = true;
        }
        WakeWorker(c.get());
    }
    napi_value undef;
    napi_get_undefined(env, &undef);
    return undef;
}

}  // namespace

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports) {
    // mbedTLS 3.x with MBEDTLS_PSA_CRYPTO_C routes TLS 1.3 and several ciphers
    // through PSA. PSA must be initialized once before any operation; otherwise
    // the first handshake fails immediately (PSA_ERROR_BAD_STATE) on both sides.
    if (psa_crypto_init() != PSA_SUCCESS) {
        TLS_LOGE("psa_crypto_init() failed");
    }
    napi_property_descriptor desc[] = {
        { "connect",    nullptr, Connect,    nullptr, nullptr, nullptr, napi_default, nullptr },
        { "accept",     nullptr, Accept,     nullptr, nullptr, nullptr, napi_default, nullptr },
        { "listen",     nullptr, Listen,     nullptr, nullptr, nullptr, napi_default, nullptr },
        { "stopListen", nullptr, StopListen, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "send",       nullptr, Send,       nullptr, nullptr, nullptr, napi_default, nullptr },
        { "close",      nullptr, Close,      nullptr, nullptr, nullptr, napi_default, nullptr },
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}
EXTERN_C_END

static napi_module tlsModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "tls_transport",
    .nm_priv = nullptr,
    .reserved = { 0 },
};

extern "C" __attribute__((constructor)) void RegisterTlsTransportModule(void) {
    napi_module_register(&tlsModule);
}
