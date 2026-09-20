/*
 * router-netlink-poller.c — queries WiFi and WireGuard state directly via
 * netlink, with no `iw`/`wg` subprocess involved.
 *
 * On this VM's single vCPU, every fork+exec has a real cost: the guest
 * kernel has to resolve the ELF binary and every shared library it needs,
 * and the router's entire /nix/store is virtiofs, so each path resolved is a
 * FUSE round trip to the host's virtiofsd, not a local block-cache hit.
 * Native netlink calls from an already-running process skip all of that -
 * no new process, no ELF loading, no virtiofs lookups, just a socket
 * write/read.
 *
 * Queries (same JSON output shape and cache file paths as
 * router-stats-server.c expects to read):
 *   - nl80211 NL80211_CMD_GET_INTERFACE for the associated SSID
 *   - WireGuard genl WG_CMD_GET_DEVICE, per configured interface, for peer
 *     stats
 * NetworkManager .nmconnection parsing is plain file I/O, kept in this same
 * process so wifi-sync-status.json's "connections" field is written
 * alongside "current" by one process rather than two.
 *
 * Not handled here: geo-lookup (curl to ipinfo.io/Mullvad's relay list,
 * cache-miss-only) and net-stats sampling (/proc/net/dev) - both stay as
 * separate services (router-geo-refresh, router-stats-poller); this binary
 * only covers the two netlink queries.
 *
 * Build:
 *   gcc -O2 -o router-netlink-poller router-netlink-poller.c -lmnl
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <dirent.h>
#include <time.h>
#include <arpa/inet.h>
#include <libmnl/libmnl.h>
#include <linux/genetlink.h>
#include <linux/nl80211.h>
#include <linux/wireguard.h>
#include <linux/if.h>

#define WIFI_CACHE "/tmp/wifi-sync-status.json"
#define WG_CACHE   "/tmp/wg-status.json"
#define WG_CONF_DIR "/etc/wireguard"

/* libmnl's MNL_SOCKET_BUFFER_SIZE is min(pagesize, 8192) - 4096 on 4K-page
 * systems. NL80211_CMD_GET_INTERFACE on a real card returns channel/width/
 * txpower/multicast-TXQ stats alongside the SSID, easily exceeding that;
 * netlink silently truncates oversized reads rather than erroring, so a
 * too-small buffer can drop attributes with no visible failure. WireGuard's
 * device dump also grows with peer count. Use a larger, explicit buffer for
 * both instead of the library default. */
#define NL_BUF_SIZE 32768
#define NM_DIR_RUN "/run/NetworkManager/system-connections"
#define NM_DIR_VAR "/var/lib/NetworkManager/system-connections"

/* ── JSON string escaping (matches the bash json_esc: backslash then quote) ── */

static void json_esc_fputs(const char *s, FILE *f) {
    if (!s) return;
    for (const unsigned char *p = (const unsigned char *)s; *p; p++) {
        if (*p == '\\' || *p == '"') fputc('\\', f);
        if (*p == '\n') { fputs("\\n", f); continue; }
        fputc(*p, f);
    }
}

/* ── Generic netlink family resolution (CTRL_CMD_GETFAMILY) ──────────────── */

struct family_result { int id; };

static int family_attr_cb(const struct nlattr *attr, void *data) {
    struct family_result *res = data;
    int type = mnl_attr_get_type(attr);
    if (type == CTRL_ATTR_FAMILY_ID) {
        if (mnl_attr_validate(attr, MNL_TYPE_U16) < 0) return MNL_CB_OK;
        res->id = mnl_attr_get_u16(attr);
    }
    return MNL_CB_OK;
}

static int family_msg_cb(const struct nlmsghdr *nlh, void *data) {
    mnl_attr_parse(nlh, sizeof(struct genlmsghdr), family_attr_cb, data);
    return MNL_CB_OK;
}

/* Resolves a genl family name ("nl80211", "wireguard") to its numeric id.
 * Returns -1 if the family isn't registered (module not loaded / kernel
 * doesn't support it) - callers must treat that as "no data available",
 * not fatal. */
static int resolve_family(struct mnl_socket *nl, const char *name) {
    char buf[NL_BUF_SIZE];
    unsigned int seq = time(NULL);
    unsigned int portid = mnl_socket_get_portid(nl);

    struct nlmsghdr *nlh = mnl_nlmsg_put_header(buf);
    nlh->nlmsg_type = GENL_ID_CTRL;
    nlh->nlmsg_flags = NLM_F_REQUEST | NLM_F_ACK;
    nlh->nlmsg_seq = seq;
    struct genlmsghdr *genl = mnl_nlmsg_put_extra_header(nlh, sizeof(*genl));
    genl->cmd = CTRL_CMD_GETFAMILY;
    genl->version = 1;
    mnl_attr_put_strz(nlh, CTRL_ATTR_FAMILY_NAME, name);

    if (mnl_socket_sendto(nl, nlh, nlh->nlmsg_len) < 0) return -1;

    struct family_result res = { .id = -1 };
    int ret = mnl_socket_recvfrom(nl, buf, sizeof(buf));
    while (ret > 0) {
        ret = mnl_cb_run(buf, ret, seq, portid, family_msg_cb, &res);
        if (ret <= 0) break;
        ret = mnl_socket_recvfrom(nl, buf, sizeof(buf));
    }
    return res.id;
}

/* ── nl80211: current SSID for a wireless interface ───────────────────────
 * Only reads NL80211_ATTR_SSID from NL80211_CMD_GET_INTERFACE - the other
 * attributes in the response (signal, bitrate, channel, txpower, ...) are
 * unused. */

struct ssid_result { char ssid[33]; int found; };

static int iface_attr_cb(const struct nlattr *attr, void *data) {
    struct ssid_result *res = data;
    int type = mnl_attr_get_type(attr);
    if (type == NL80211_ATTR_SSID && !res->found) {
        uint16_t len = mnl_attr_get_payload_len(attr);
        if (len > 32) len = 32;
        memcpy(res->ssid, mnl_attr_get_payload(attr), len);
        res->ssid[len] = '\0';
        res->found = 1;
    }
    return MNL_CB_OK;
}

static int iface_msg_cb(const struct nlmsghdr *nlh, void *data) {
    mnl_attr_parse(nlh, sizeof(struct genlmsghdr), iface_attr_cb, data);
    return MNL_CB_OK;
}

/* Dumps every wireless interface (no NL80211_ATTR_IFINDEX filter, since the
 * interface name isn't known ahead of time) and returns the first one
 * reporting an SSID, i.e. the first associated interface. */
static int get_wifi_ssid(struct mnl_socket *nl, int nl80211_id, char *out, size_t outlen) {
    char buf[NL_BUF_SIZE];
    unsigned int seq = time(NULL);
    unsigned int portid = mnl_socket_get_portid(nl);

    struct nlmsghdr *nlh = mnl_nlmsg_put_header(buf);
    nlh->nlmsg_type = nl80211_id;
    nlh->nlmsg_flags = NLM_F_REQUEST | NLM_F_DUMP;
    nlh->nlmsg_seq = seq;
    struct genlmsghdr *genl = mnl_nlmsg_put_extra_header(nlh, sizeof(*genl));
    genl->cmd = NL80211_CMD_GET_INTERFACE;
    genl->version = 0;

    out[0] = '\0';
    if (mnl_socket_sendto(nl, nlh, nlh->nlmsg_len) < 0) return -1;

    /* Must fully drain the dump (read until NLMSG_DONE, i.e. ret <= 0) even
     * after finding the SSID - this socket is reused for every call for the
     * life of the process, and any unread messages left behind here would
     * sit in its receive queue and desync every later read, on this and
     * every other request sharing the socket. */
    struct ssid_result res = { .found = 0 };
    int ret = mnl_socket_recvfrom(nl, buf, sizeof(buf));
    while (ret > 0) {
        ret = mnl_cb_run(buf, ret, seq, portid, iface_msg_cb, &res);
        if (ret <= 0) break;
        ret = mnl_socket_recvfrom(nl, buf, sizeof(buf));
    }
    if (res.found) snprintf(out, outlen, "%s", res.ssid);
    return 0;
}

/* ── WireGuard: peer stats per configured interface ───────────────────────
 * WG_CMD_GET_DEVICE identifies the device by WGDEVICE_A_IFNAME - there's no
 * "get all devices" command, so each configured interface needs its own
 * query. Interface names come from /etc/wireguard, one .conf file per
 * interface, which is also where read_server_comment (below) looks up each
 * interface's display name. */

struct wg_peer {
    char endpoint[64];
    long long handshake; /* unix seconds, 0 = never */
    unsigned long long rx, tx;
};

struct wg_dump_ctx {
    struct wg_peer peers[32];
    int count;
};

static void parse_peer_nested(struct nlattr *peer_attr, struct wg_peer *p) {
    struct nlattr *attr;
    memset(p, 0, sizeof(*p));
    mnl_attr_for_each_nested(attr, peer_attr) {
        int type = mnl_attr_get_type(attr);
        switch (type) {
        case WGPEER_A_ENDPOINT: {
            /* payload is a sockaddr_in or sockaddr_in6 */
            const struct sockaddr *sa = mnl_attr_get_payload(attr);
            if (sa->sa_family == AF_INET) {
                const struct sockaddr_in *sin = (const struct sockaddr_in *)sa;
                inet_ntop(AF_INET, &sin->sin_addr, p->endpoint, sizeof(p->endpoint));
            } else if (sa->sa_family == AF_INET6) {
                const struct sockaddr_in6 *sin6 = (const struct sockaddr_in6 *)sa;
                inet_ntop(AF_INET6, &sin6->sin6_addr, p->endpoint, sizeof(p->endpoint));
            }
            break;
        }
        case WGPEER_A_LAST_HANDSHAKE_TIME: {
            /* payload: struct { __u64 tv_sec; __u64 tv_nsec; } (wireguard.h: __kernel_timespec-shaped) */
            const long long *ts = mnl_attr_get_payload(attr);
            p->handshake = ts[0];
            break;
        }
        case WGPEER_A_RX_BYTES:
            p->rx = mnl_attr_get_u64(attr);
            break;
        case WGPEER_A_TX_BYTES:
            p->tx = mnl_attr_get_u64(attr);
            break;
        default:
            break;
        }
    }
}

static int wg_device_attr_cb(const struct nlattr *attr, void *data) {
    struct wg_dump_ctx *ctx = data;
    int type = mnl_attr_get_type(attr);
    if (type == WGDEVICE_A_PEERS) {
        struct nlattr *peer;
        mnl_attr_for_each_nested(peer, attr) {
            if (ctx->count >= 32) break;
            parse_peer_nested((struct nlattr *)peer, &ctx->peers[ctx->count]);
            ctx->count++;
        }
    }
    return MNL_CB_OK;
}

static int wg_device_msg_cb(const struct nlmsghdr *nlh, void *data) {
    mnl_attr_parse(nlh, sizeof(struct genlmsghdr), wg_device_attr_cb, data);
    return MNL_CB_OK;
}

static int wg_get_device_peers(struct mnl_socket *nl, int wg_id, const char *ifname, struct wg_dump_ctx *ctx) {
    char buf[NL_BUF_SIZE];
    unsigned int seq = time(NULL);
    unsigned int portid = mnl_socket_get_portid(nl);

    struct nlmsghdr *nlh = mnl_nlmsg_put_header(buf);
    nlh->nlmsg_type = wg_id;
    nlh->nlmsg_flags = NLM_F_REQUEST | NLM_F_DUMP;
    nlh->nlmsg_seq = seq;
    struct genlmsghdr *genl = mnl_nlmsg_put_extra_header(nlh, sizeof(*genl));
    genl->cmd = WG_CMD_GET_DEVICE;
    genl->version = 1;
    mnl_attr_put_strz(nlh, WGDEVICE_A_IFNAME, ifname);

    ctx->count = 0;
    if (mnl_socket_sendto(nl, nlh, nlh->nlmsg_len) < 0) return -1;

    int ret = mnl_socket_recvfrom(nl, buf, sizeof(buf));
    while (ret > 0) {
        ret = mnl_cb_run(buf, ret, seq, portid, wg_device_msg_cb, ctx);
        if (ret <= 0) break;
        ret = mnl_socket_recvfrom(nl, buf, sizeof(buf));
    }
    return 0;
}

/* Reads a "# Server: <name>" comment from the interface's .conf file as a
 * human-readable display name, falling back to the endpoint IP if absent. */
static void read_server_comment(const char *ifname, const char *fallback, char *out, size_t outlen) {
    char path[256];
    snprintf(path, sizeof(path), "%s/%s.conf", WG_CONF_DIR, ifname);
    strncpy(out, fallback, outlen - 1);
    out[outlen - 1] = '\0';
    FILE *f = fopen(path, "r");
    if (!f) return;
    char line[256];
    while (fgets(line, sizeof(line), f)) {
        if (strncmp(line, "# Server: ", 10) == 0) {
            size_t len = strcspn(line + 10, "\r\n");
            if (len >= outlen) len = outlen - 1;
            memcpy(out, line + 10, len);
            out[len] = '\0';
            break;
        }
    }
    fclose(f);
}

/* Read-only: /tmp/wg-loc-<ip> is populated by the separate router-geo-refresh
 * service (still bash+curl - geo lookups are a rare, cache-miss-only cost
 * against Mullvad's relay list / ipinfo.io, not the frequent per-tick netlink
 * sampling this program exists to replace, so there's no reason to also
 * reimplement an HTTPS client here). Returns "" if not yet cached - that
 * service runs independently and will fill it in on its own schedule. */
static void read_location_cache(const char *ip, char *out, size_t outlen) {
    char path[300];
    snprintf(path, sizeof(path), "/tmp/wg-loc-%s", ip);
    out[0] = '\0';
    FILE *f = fopen(path, "r");
    if (!f) return;
    if (fgets(out, outlen, f)) {
        size_t len = strcspn(out, "\r\n");
        out[len] = '\0';
    }
    fclose(f);
}

static void write_wg_json(struct mnl_socket *nl, int wg_id) {
    char tmp[] = "/tmp/wg-status.json.tmp";
    FILE *f = fopen(tmp, "w");
    if (!f) return;
    fputc('[', f);

    DIR *d = opendir(WG_CONF_DIR);
    int first = 1;
    time_t now = time(NULL);
    if (d) {
        struct dirent *e;
        while ((e = readdir(d))) {
            size_t nlen = strlen(e->d_name);
            if (nlen < 6 || strcmp(e->d_name + nlen - 5, ".conf") != 0) continue;
            char ifname[IFNAMSIZ];
            size_t iflen = nlen - 5;
            if (iflen >= sizeof(ifname)) iflen = sizeof(ifname) - 1;
            memcpy(ifname, e->d_name, iflen);
            ifname[iflen] = '\0';

            struct wg_dump_ctx ctx;
            if (wg_get_device_peers(nl, wg_id, ifname, &ctx) < 0) continue;

            for (int i = 0; i < ctx.count; i++) {
                struct wg_peer *p = &ctx.peers[i];
                if (p->endpoint[0] == '\0') continue; /* peer has never connected, nothing to report */
                long long age = p->handshake > 0 ? (long long)now - p->handshake : -1;
                char server[128];
                read_server_comment(ifname, p->endpoint, server, sizeof(server));
                char location[128];
                read_location_cache(p->endpoint, location, sizeof(location));

                if (!first) fputc(',', f);
                first = 0;
                fprintf(f, "{\"iface\":\"%s\",\"endpoint\":\"%s\",\"handshake\":%lld,\"rx\":%llu,\"tx\":%llu,\"server\":\"",
                        ifname, p->endpoint, age, p->rx, p->tx);
                json_esc_fputs(server, f);
                fputs("\",\"location\":\"", f);
                json_esc_fputs(location, f);
                fputs("\"}", f);
            }
        }
        closedir(d);
    }

    fputc(']', f);
    fclose(f);
    rename(tmp, WG_CACHE);
}

/* ── NetworkManager .nmconnection parsing - pure file I/O, kept alongside
 * the SSID query so one process owns the whole wifi-sync-status.json file */

struct nm_conn { char ssid[128]; char psk[128]; };

static int nm_scan_dir(const char *dir, struct nm_conn *out, int max, int count) {
    DIR *d = opendir(dir);
    if (!d) return count;
    struct dirent *e;
    while ((e = readdir(d)) && count < max) {
        size_t nlen = strlen(e->d_name);
        if (nlen < 14 || strcmp(e->d_name + nlen - 13, ".nmconnection") != 0) continue;
        char path[512];
        snprintf(path, sizeof(path), "%s/%s", dir, e->d_name);
        FILE *f = fopen(path, "r");
        if (!f) continue;
        char ssid[128] = "", psk[128] = "", line[256];
        while (fgets(line, sizeof(line), f)) {
            size_t len = strcspn(line, "\r\n");
            line[len] = '\0';
            /* explicit precision (not just sizeof-bounded "%s"): silences
             * -Wformat-truncation by telling the compiler the truncation is
             * intentional and bounded, not an overlooked overflow */
            if (strncmp(line, "ssid=", 5) == 0) snprintf(ssid, sizeof(ssid), "%.*s", (int)sizeof(ssid) - 1, line + 5);
            else if (strncmp(line, "psk=", 4) == 0) snprintf(psk, sizeof(psk), "%.*s", (int)sizeof(psk) - 1, line + 4);
        }
        fclose(f);
        if (ssid[0] && psk[0]) {
            int dup = 0;
            for (int i = 0; i < count; i++) if (strcmp(out[i].ssid, ssid) == 0) { dup = 1; break; }
            if (!dup) {
                snprintf(out[count].ssid, sizeof(out[count].ssid), "%s", ssid);
                snprintf(out[count].psk, sizeof(out[count].psk), "%s", psk);
                count++;
            }
        }
    }
    closedir(d);
    return count;
}

static void write_wifi_json(struct mnl_socket *nl, int nl80211_id) {
    char ssid[33] = "";
    get_wifi_ssid(nl, nl80211_id, ssid, sizeof(ssid));

    struct nm_conn conns[64];
    int count = 0;
    count = nm_scan_dir(NM_DIR_RUN, conns, 64, count); /* /run/ (active runtime connections) takes precedence over /var/lib (persisted) for same-SSID dedup */
    count = nm_scan_dir(NM_DIR_VAR, conns, 64, count);

    char tmp[] = "/tmp/wifi-sync-status.json.tmp";
    FILE *f = fopen(tmp, "w");
    if (!f) return;
    fputs("{\"current\":\"", f);
    json_esc_fputs(ssid, f);
    fputs("\",\"connections\":[", f);
    for (int i = 0; i < count; i++) {
        if (i) fputc(',', f);
        fputs("{\"ssid\":\"", f);
        json_esc_fputs(conns[i].ssid, f);
        fputs("\",\"psk\":\"", f);
        json_esc_fputs(conns[i].psk, f);
        fputs("\"}", f);
    }
    fputs("]}", f);
    fclose(f);
    rename(tmp, WIFI_CACHE);
}

int main(int argc, char **argv) {
    int interval = 10;
    if (argc > 1) {
        int v = atoi(argv[1]);
        if (v > 0) interval = v;
    }
    /* hydrix.router.polling.enableWgStatus - WiFi sampling is unconditional,
     * WireGuard sampling is opt-out. */
    int wg_enabled = 1;
    if (argc > 2) wg_enabled = atoi(argv[2]) != 0;

    struct mnl_socket *nl = mnl_socket_open(NETLINK_GENERIC);
    if (!nl) { perror("mnl_socket_open"); return 1; }
    if (mnl_socket_bind(nl, 0, MNL_SOCKET_AUTOPID) < 0) { perror("mnl_socket_bind"); return 1; }

    int nl80211_id = resolve_family(nl, NL80211_GENL_NAME);
    int wg_id = wg_enabled ? resolve_family(nl, WG_GENL_NAME) : -1;

    for (;;) {
        if (nl80211_id >= 0) write_wifi_json(nl, nl80211_id);
        if (wg_enabled && wg_id >= 0) write_wg_json(nl, wg_id);
        /* Families might appear later (module loaded after us) - retry resolution
         * each tick if we don't have an id yet, cheap and self-healing. */
        if (nl80211_id < 0) nl80211_id = resolve_family(nl, NL80211_GENL_NAME);
        if (wg_enabled && wg_id < 0) wg_id = resolve_family(nl, WG_GENL_NAME);
        sleep(interval);
    }

    mnl_socket_close(nl);
    return 0;
}
