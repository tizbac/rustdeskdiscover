// rustdesk-discoveryd - RustDesk LAN peer discovery daemon for OpenWrt.
//
// Discovers RustDesk clients on the local network using the same protocol as
// the RustDesk desktop client (UDP broadcast "ping" / unicast "pong" on port
// 21119, protobuf-encoded) and stores the results in a JSON file that the
// LuCI web UI reads.
//
// This source deliberately uses only the C/C++ standard library (POSIX
// sockets) so it can be built with the OpenWrt SDK (musl toolchain) without
// any external dependencies.
#define _POSIX_C_SOURCE 200809L

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <netinet/in.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/types.h>
#include <unistd.h>

#include <map>
#include <string>
#include <vector>

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------
static const int kRendezvousPort = 21116;
static const int kBroadcastPort = kRendezvousPort + 3; // 21119
static const int kCollectTimeoutMs = 3000;             // how long to wait for pongs
static const char *kOutFile = "/tmp/rustdesk_peers.json";
static volatile sig_atomic_t g_running = 1;

// Ping message: RendezvousMessage { peer_discovery: PeerDiscovery { cmd: "ping" } }
// field 22 (length-delimited) -> varint tag 0xb2 0x01, inner len 6.
static const unsigned char kPingMsg[] = {0xb2, 0x01, 0x06, 0x0a, 0x04, 0x70, 0x69, 0x6e, 0x67};
static const size_t kPingLen = sizeof(kPingMsg);

// ---------------------------------------------------------------------------
// Minimal protobuf varint / length-delimited parsing
// ---------------------------------------------------------------------------
struct Field {
    int number;
    std::string value; // for length-delimited (wire type 2) fields
};

// Decode a proto3 message into a vector of length-delimited fields.
static bool decode_protobuf(const unsigned char *data, size_t len,
                            std::vector<Field> &out) {
    size_t pos = 0;
    while (pos < len) {
        // tag varint
        uint64_t tag = 0;
        int shift = 0;
        bool complete = false;
        size_t start = pos;
        while (pos < len && shift < 70) {
            unsigned char b = data[pos++];
            tag |= (uint64_t)(b & 0x7f) << shift;
            shift += 7;
            if (!(b & 0x80)) {
                complete = true;
                break;
            }
        }
        if (!complete || pos > len)
            return false;
        (void)start;

        int field_number = (int)(tag >> 3);
        int wire_type = (int)(tag & 0x7);
        switch (wire_type) {
        case 0: { // varint
            while (pos < len && (data[pos] & 0x80))
                pos++;
            if (pos < len)
                pos++;
            break;
        }
        case 1: // 64-bit
            pos += 8;
            break;
        case 2: { // length-delimited
            uint64_t flen = 0;
            shift = 0;
            bool fcomplete = false;
            while (pos < len && shift < 70) {
                unsigned char b = data[pos++];
                flen |= (uint64_t)(b & 0x7f) << shift;
                shift += 7;
                if (!(b & 0x80)) {
                    fcomplete = true;
                    break;
                }
            }
            if (!fcomplete || flen > (uint64_t)(len - pos))
                return false;
            Field f;
            f.number = field_number;
            f.value.assign((const char *)data + pos, (size_t)flen);
            out.push_back(f);
            pos += (size_t)flen;
            break;
        }
        case 5: // 32-bit
            pos += 4;
            break;
        default:
            return false;
        }
        if (pos > len)
            return false;
    }
    return true;
}

// Find a length-delimited field by number.
static const std::string *get_field(const std::vector<Field> &fields, int number) {
    for (size_t i = 0; i < fields.size(); i++) {
        if (fields[i].number == number)
            return &fields[i].value;
    }
    return NULL;
}

// ---------------------------------------------------------------------------
// Peer model
// ---------------------------------------------------------------------------
struct Peer {
    std::string id;
    std::string hostname;
    std::string mac;
    std::string username;
    std::string platform;
    std::string ip;
    uint64_t first_seen;
    uint64_t last_seen;
};

struct PeerMap {
    std::map<std::string, Peer> by_key; // key = id, else mac, else ip
};

static std::string json_escape(const std::string &s) {
    std::string out;
    for (size_t i = 0; i < s.size(); i++) {
        unsigned char c = (unsigned char)s[i];
        switch (c) {
        case '"': out += "\\\""; break;
        case '\\': out += "\\\\"; break;
        case '\b': out += "\\b"; break;
        case '\f': out += "\\f"; break;
        case '\n': out += "\\n"; break;
        case '\r': out += "\\r"; break;
        case '\t': out += "\\t"; break;
        default:
            if (c < 0x20) {
                char tmp[8];
                snprintf(tmp, sizeof(tmp), "\\u%04x", c);
                out += tmp;
            } else {
                out += (char)c;
            }
        }
    }
    return out;
}

// ---------------------------------------------------------------------------
// Discovery
// ---------------------------------------------------------------------------
static uint64_t now_ms() {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (uint64_t)tv.tv_sec * 1000u + (uint64_t)(tv.tv_usec / 1000);
}

// Collect broadcast addresses for all non-loopback IPv4 interfaces.
static std::vector<std::string> gather_broadcast_addrs() {
    std::vector<std::string> out;
    struct ifaddrs *ifa = NULL;
    if (getifaddrs(&ifa) != 0)
        return out;
    for (struct ifaddrs *p = ifa; p; p = p->ifa_next) {
        if (!p->ifa_addr || p->ifa_addr->sa_family != AF_INET)
            continue;
        if (!(p->ifa_flags & IFF_UP) || (p->ifa_flags & IFF_LOOPBACK))
            continue;
        struct sockaddr_in *sin = (struct sockaddr_in *)p->ifa_addr;
        struct sockaddr_in *mask = (struct sockaddr_in *)p->ifa_netmask;
        struct in_addr bcast;
        bcast.s_addr = sin->sin_addr.s_addr | ~mask->sin_addr.s_addr;
        char buf[INET_ADDRSTRLEN];
        if (inet_ntop(AF_INET, &bcast, buf, sizeof(buf)))
            out.push_back(buf);
    }
    freeifaddrs(ifa);
    return out;
}

// Send discovery pings on a dedicated multicast/broadcast socket.
static void send_pings(int sock) {
    std::vector<std::string> bcasts = gather_broadcast_addrs();
    struct sockaddr_in dst;
    memset(&dst, 0, sizeof(dst));
    dst.sin_family = AF_INET;
    dst.sin_port = htons(kBroadcastPort);

    for (size_t i = 0; i < bcasts.size(); i++) {
        if (inet_pton(AF_INET, bcasts[i].c_str(), &dst.sin_addr) != 1)
            continue;
        sendto(sock, kPingMsg, kPingLen, 0, (struct sockaddr *)&dst, sizeof(dst));
    }
}

// ---------------------------------------------------------------------------
// JSON output
// ---------------------------------------------------------------------------
static int write_peers(const PeerMap &pm) {
    FILE *f = fopen(kOutFile, "w");
    if (!f)
        return -1;

    uint64_t now = now_ms();
    fprintf(f, "{\"updated_ms\":%llu,\"peers\":[",
            (unsigned long long)now);

    bool first = true;
    for (std::map<std::string, Peer>::const_iterator it = pm.by_key.begin();
         it != pm.by_key.end(); ++it) {
        const Peer &p = it->second;
        // drop peers not seen for > 60s
        if (now - p.last_seen > 60000)
            continue;
        if (!first)
            fprintf(f, ",");
        first = false;

        fprintf(f, "{");
        fprintf(f, "\"id\":\"%s\",", json_escape(p.id).c_str());
        fprintf(f, "\"hostname\":\"%s\",", json_escape(p.hostname).c_str());
        fprintf(f, "\"mac\":\"%s\",", json_escape(p.mac).c_str());
        fprintf(f, "\"username\":\"%s\",", json_escape(p.username).c_str());
        fprintf(f, "\"platform\":\"%s\",", json_escape(p.platform).c_str());
        fprintf(f, "\"ip\":\"%s\"", json_escape(p.ip).c_str());
        fprintf(f, "}");
    }
    fprintf(f, "]}\n");
    fclose(f);
    return 0;
}

static void handle_signal(int sig) {
    (void)sig;
    g_running = 0;
}

// ---------------------------------------------------------------------------
// Main loop
// ---------------------------------------------------------------------------
int main(int argc, char **argv) {
    // Parse --once / --wait for headless testing.
    bool once = false;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--once") == 0)
            once = true;
        else if (strcmp(argv[i], "--out") == 0 && i + 1 < argc)
            kOutFile = argv[++i];
        else {
            fprintf(stderr, "usage: %s [--once] [--out FILE]\n", argv[0]);
            return 1;
        }
    }

    signal(SIGTERM, handle_signal);
    signal(SIGINT, handle_signal);
    signal(SIGHUP, handle_signal);

    // Listening socket (bind ephemeral; replies come back to source port).
    int sock = socket(AF_INET, SOCK_DGRAM, 0);
    if (sock < 0) {
        perror("socket");
        return 1;
    }
    int one = 1;
    setsockopt(sock, SOL_SOCKET, SO_BROADCAST, &one, sizeof(one));

    struct sockaddr_in bind_addr;
    memset(&bind_addr, 0, sizeof(bind_addr));
    bind_addr.sin_family = AF_INET;
    bind_addr.sin_addr.s_addr = htonl(INADDR_ANY);
    bind_addr.sin_port = 0; // ephemeral
    if (bind(sock, (struct sockaddr *)&bind_addr, sizeof(bind_addr)) < 0) {
        perror("bind");
        return 1;
    }

    PeerMap pm;

    // Immediate first scan, then periodic.
    uint64_t next_scan = 0;
    while (g_running) {
        uint64_t t = now_ms();
        if (t >= next_scan) {
            send_pings(sock);
            next_scan = t + kCollectTimeoutMs;
        }

        struct pollfd pfd;
        pfd.fd = sock;
        pfd.events = POLLIN;
        int pr = poll(&pfd, 1, 200);
        if (pr < 0) {
            if (errno == EINTR)
                continue;
            break;
        }
        if (pr == 0)
            continue;

        unsigned char buf[2048];
        struct sockaddr_in src;
        socklen_t srclen = sizeof(src);
        ssize_t n = recvfrom(sock, buf, sizeof(buf), 0,
                             (struct sockaddr *)&src, &srclen);
        if (n <= 0)
            continue;

        std::vector<Field> outer;
        if (!decode_protobuf(buf, (size_t)n, outer))
            continue;
        const std::string *pd = get_field(outer, 22);
        if (!pd)
            continue;
        std::vector<Field> inner;
        if (!decode_protobuf((const unsigned char *)pd->data(), pd->size(), inner))
            continue;

        const std::string *cmd = get_field(inner, 1);
        if (!cmd || *cmd != "pong")
            continue;

        Peer p;
        if (const std::string *v = get_field(inner, 3)) p.id = *v;       // id
        if (const std::string *v = get_field(inner, 5)) p.hostname = *v; // hostname
        if (const std::string *v = get_field(inner, 2)) p.mac = *v;      // mac
        if (const std::string *v = get_field(inner, 4)) p.username = *v; // username
        if (const std::string *v = get_field(inner, 6)) p.platform = *v; // platform

        char ipbuf[INET_ADDRSTRLEN];
        if (!inet_ntop(AF_INET, &src.sin_addr, ipbuf, sizeof(ipbuf)))
            continue;
        p.ip = ipbuf;

        if (p.id.empty() && p.hostname.empty())
            continue;

        p.first_seen = now_ms();
        p.last_seen = p.first_seen;

        std::string key = !p.id.empty() ? p.id : (!p.mac.empty() ? p.mac : p.ip);
        std::map<std::string, Peer>::iterator it = pm.by_key.find(key);
        if (it == pm.by_key.end()) {
            pm.by_key[key] = p;
        } else {
            it->second = p;
            it->second.last_seen = p.last_seen;
        }

        write_peers(pm);

        if (once)
            break;
    }

    write_peers(pm);
    close(sock);
    return 0;
}
