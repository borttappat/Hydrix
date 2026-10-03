/*
 * router-netlink-poller.c: keeps /tmp/wifi-sync-status.json (associated SSID
 * plus NetworkManager's saved connections) current, for router-stats-server
 * to serve.
 *
 * Event-driven, no timer: it blocks until the kernel reports a WiFi change
 * (nl80211 "mlme"/"config" multicast: connect, disconnect, roam, interface
 * added/removed) or a NetworkManager connection file changes (inotify on
 * both system-connections directories), then rewrites the file once.
 *
 * On this VM's single vCPU every fork/exec is a real cost (ELF and library
 * resolution over the virtiofs-backed /nix/store), so the SSID comes from a
 * native nl80211 query rather than `iw`.
 *
 * WireGuard status and network throughput are not handled here:
 * router-stats-server reads them when the host asks.
 *
 * Build:
 *   gcc -O2 -o router-netlink-poller router-netlink-poller.c -lmnl
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <dirent.h>
#include <errno.h>
#include <poll.h>
#include <sys/inotify.h>
#include <linux/nl80211.h>
#include "router-netlink.h"

#define WIFI_CACHE "/tmp/wifi-sync-status.json"
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
    if (nl80211_id >= 0) get_wifi_ssid(nl, nl80211_id, ssid, sizeof(ssid));

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

/* Watches both NM connection directories. A directory that doesn't exist
 * yet can't be watched; returns how many are missing so the caller retries. */
static int watch_nm_dirs(int ifd, int wd[2]) {
    const char *dirs[2] = {NM_DIR_RUN, NM_DIR_VAR};
    int missing = 0;
    for (int i = 0; i < 2; i++) {
        if (wd[i] >= 0) continue;
        wd[i] = inotify_add_watch(ifd, dirs[i],
                                  IN_CREATE | IN_DELETE | IN_CLOSE_WRITE | IN_MOVED_FROM |
                                  IN_MOVED_TO | IN_DELETE_SELF | IN_MOVE_SELF);
        if (wd[i] < 0) missing++;
    }
    return missing;
}

/* Reads everything pending on a non-blocking fd. inotify events that report
 * a watched directory going away clear its watch so it is re-added. */
static void drain_inotify(int ifd, int wd[2]) {
    char buf[4096] __attribute__((aligned(__alignof__(struct inotify_event))));
    ssize_t n;
    while ((n = read(ifd, buf, sizeof(buf))) > 0) {
        for (char *p = buf; p < buf + n;) {
            struct inotify_event *ev = (struct inotify_event *)p;
            if (ev->mask & (IN_IGNORED | IN_DELETE_SELF | IN_MOVE_SELF))
                for (int i = 0; i < 2; i++)
                    if (wd[i] == ev->wd) wd[i] = -1;
            p += sizeof(*ev) + ev->len;
        }
    }
}

static void drain_socket(struct mnl_socket *ev) {
    char buf[NL_BUF_SIZE];
    while (recv(mnl_socket_get_fd(ev), buf, sizeof(buf), MSG_DONTWAIT) > 0) {}
}

/* Joins nl80211's mlme and config multicast groups on a socket used only for
 * events, so they never interleave with query replies on the query socket. */
static struct mnl_socket *open_event_socket(struct mnl_socket *q) {
    struct family_result fam = {.ngroups = 2, .group_names = {"mlme", "config"}};
    if (resolve_family(q, NL80211_GENL_NAME, &fam) < 0) return NULL;
    struct mnl_socket *ev = mnl_socket_open(NETLINK_GENERIC);
    if (!ev) return NULL;
    if (mnl_socket_bind(ev, 0, MNL_SOCKET_AUTOPID) < 0) {
        mnl_socket_close(ev);
        return NULL;
    }
    int joined = 0;
    for (int i = 0; i < fam.ngroups; i++) {
        int g = fam.group_ids[i];
        if (g >= 0 && mnl_socket_setsockopt(ev, NETLINK_ADD_MEMBERSHIP, &g, sizeof(g)) == 0)
            joined++;
    }
    if (!joined) {
        mnl_socket_close(ev);
        return NULL;
    }
    return ev;
}

int main(void) {
    struct mnl_socket *nl = mnl_socket_open(NETLINK_GENERIC);
    if (!nl) { perror("mnl_socket_open"); return 1; }
    if (mnl_socket_bind(nl, 0, MNL_SOCKET_AUTOPID) < 0) { perror("mnl_socket_bind"); return 1; }

    int ifd = inotify_init1(IN_NONBLOCK | IN_CLOEXEC);
    if (ifd < 0) { perror("inotify_init1"); return 1; }
    int wd[2] = {-1, -1};

    struct family_result fam = {.ngroups = 0};
    int nl80211_id = resolve_family(nl, NL80211_GENL_NAME, &fam);
    struct mnl_socket *ev = nl80211_id >= 0 ? open_event_socket(nl) : NULL;

    for (;;) {
        int missing = watch_nm_dirs(ifd, wd);
        write_wifi_json(nl, nl80211_id);

        /* Only time out while something is still missing (the nl80211
         * family, its event socket, or an NM directory); otherwise sleep
         * until an event arrives. */
        int retry = missing || nl80211_id < 0 || !ev;
        struct pollfd pfd[2] = {
            {.fd = ifd, .events = POLLIN},
            {.fd = ev ? mnl_socket_get_fd(ev) : -1, .events = POLLIN},
        };
        if (poll(pfd, 2, retry ? 30000 : -1) < 0 && errno != EINTR) {
            perror("poll");
            return 1;
        }

        /* Connect/disconnect and NM's file rewrites arrive in bursts; let
         * them settle, then rewrite once. */
        usleep(300000);
        drain_inotify(ifd, wd);
        if (ev) drain_socket(ev);

        if (nl80211_id < 0) nl80211_id = resolve_family(nl, NL80211_GENL_NAME, &fam);
        if (nl80211_id >= 0 && !ev) ev = open_event_socket(nl);
    }
}
