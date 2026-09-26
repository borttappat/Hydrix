/*
 * router-stats-server.c — persistent vsock server for router polled data
 *
 * Replaces three `socat VSOCK-LISTEN:PORT,fork EXEC:handler` listeners
 * (wifi-sync, net-stats-vsock, wg-status-vsock) with one long-lived process
 * that holds a single vsock listener open and answers every connection with
 * no new process ever forked or exec'd.
 *
 * Serves cached JSON written by three unchanged background sampler services
 * (wifi-sync-poller, net-stats-poller, wg-status-poller) - this binary is
 * the serving side only, not the sampling side.
 *
 * Build:
 *   gcc -O2 -o router-stats-server router-stats-server.c
 *
 * Protocol: client connects, sends one command line (ADD/REMOVE send two
 * more lines after), gets one response, connection closes.
 *
 *   PING            -> "PONG"
 *   POLL | STATUS   -> contents of /tmp/wifi-sync-status.json
 *   NET             -> contents of /tmp/net-stats.json
 *   WG              -> contents of /tmp/wg-status.json
 *   ALL             -> {"wifi":<wifi>,"net":<net>,"wg":<wg>,"vpn":<vpn>}
 *   VPN             -> {"<network>":"<wg-iface|direct|blocked>",...} from
 *                      vpn-assign's state dir
 *   VPNSET\n<on|off> <network> -> vpn-assign on|off <network>, then
 *                      {"ok":bool,"vpn":<vpn>}
 *   ADD\n<ssid>\n<psk>    -> nmcli device wifi connect / connection add
 *   REMOVE\n<ssid>        -> nmcli con delete
 *   WEATHER\n<lats> <lons> -> contents of /tmp/weather.json; records the
 *                            coordinate list in /tmp/weather-request for
 *                            router-weather to fetch (the host has no
 *                            internet of its own in lockdown mode)
 */

#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <fcntl.h>
#include <dirent.h>

#ifndef AF_VSOCK
#define AF_VSOCK 40
#endif
#define VMADDR_CID_ANY ((unsigned int)-1U)
#define VSOCK_PORT 14506

struct sockaddr_vm {
    unsigned short svm_family;
    unsigned short svm_reserved1;
    unsigned int   svm_port;
    unsigned int   svm_cid;
    unsigned char  svm_zero[4];
};

#define WIFI_CACHE "/tmp/wifi-sync-status.json"
#define NET_CACHE  "/tmp/net-stats.json"
#define WG_CACHE   "/tmp/wg-status.json"
#define WX_CACHE   "/tmp/weather.json"
#define WX_REQUEST "/tmp/weather-request"
#define VPN_STATE  "/var/lib/hydrix-vpn"

#define WIFI_DEFAULT "{\"current\":\"\",\"connections\":[]}"
#define NET_DEFAULT  "{\"wan\":{\"iface\":\"\",\"rx\":0,\"tx\":0},\"vms\":[]}"
#define WG_DEFAULT   "[]"
#define WX_DEFAULT   "{}"

#define BUF_MAX 65536

/* Reads a whole file into buf (NUL-terminated), falls back to def if the
 * file is missing/empty. Returns the length written into buf. */
static size_t read_cache(const char *path, const char *def, char *buf, size_t bufsz) {
    FILE *f = fopen(path, "rb");
    if (!f) {
        size_t n = strlen(def);
        memcpy(buf, def, n + 1);
        return n;
    }
    size_t n = fread(buf, 1, bufsz - 1, f);
    fclose(f);
    while (n > 0 && (buf[n - 1] == '\n' || buf[n - 1] == '\r')) n--;
    if (n == 0) {
        n = strlen(def);
        memcpy(buf, def, n + 1);
        return n;
    }
    buf[n] = 0;
    return n;
}

static void send_all(int fd, const char *data, size_t len) {
    size_t off = 0;
    while (off < len) {
        ssize_t w = send(fd, data + off, len - off, 0);
        if (w <= 0) return;
        off += (size_t)w;
    }
}

/* Runs argv[0] directly via fork/execvp (argv array, no shell) so ssid/psk
 * or network names can never be interpreted as shell syntax. Returns the
 * command's exit code, or -1 on fork/exec failure. */
static int run_cmd(char *const argv[]) {
    pid_t pid = fork();
    if (pid < 0) return -1;
    if (pid == 0) {
        int devnull = open("/dev/null", O_WRONLY);
        if (devnull >= 0) {
            dup2(devnull, STDOUT_FILENO);
            dup2(devnull, STDERR_FILENO);
        }
        execvp(argv[0], argv);
        _exit(127);
    }
    int status = 0;
    waitpid(pid, &status, 0);
    return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
}

static void handle_add(const char *ssid, const char *psk, char *out, size_t outsz) {
    size_t ssid_len = strlen(ssid), psk_len = strlen(psk);
    if (ssid_len == 0 || psk_len == 0) {
        snprintf(out, outsz, "{\"ok\":false,\"error\":\"missing ssid or password\"}");
        return;
    }
    if (psk_len < 8 || (psk_len > 63 && psk_len != 64)) {
        snprintf(out, outsz,
                 "{\"ok\":false,\"error\":\"PSK must be 8-63 chars (or 64-char hex hash), got %zu\"}",
                 psk_len);
        return;
    }

    char *connect_argv[] = {
        "nmcli", "device", "wifi", "connect", (char *)ssid, "password", (char *)psk, NULL,
    };
    if (run_cmd(connect_argv) == 0) {
        snprintf(out, outsz, "{\"ok\":true,\"connected\":true}");
        return;
    }

    char *add_argv[] = {
        "nmcli", "connection", "add",
        "type", "wifi", "con-name", (char *)ssid, "ssid", (char *)ssid,
        "wifi-sec.key-mgmt", "wpa-psk", "wifi-sec.psk", (char *)psk,
        "connection.autoconnect", "yes", NULL,
    };
    if (run_cmd(add_argv) == 0) {
        snprintf(out, outsz, "{\"ok\":true,\"connected\":false}");
        return;
    }
    snprintf(out, outsz, "{\"ok\":false,\"error\":\"failed to add connection\"}");
}

/* Records the requested coordinate list ("<lat>,<lat> <lon>,<lon>") for
 * router-weather's path unit, rewriting the file only when it changes so a
 * repeated poll doesn't retrigger a fetch. Restricted to digits and ".,- "
 * since the fetcher splices it into a URL. */
static void handle_weather(const char *query, char *out, size_t outsz) {
    size_t len = strlen(query);
    int ok = len > 0 && strchr(query, ' ') != NULL;
    for (size_t i = 0; ok && i < len; i++)
        ok = isdigit((unsigned char)query[i]) || strchr(".,- ", query[i]) != NULL;
    if (!ok) {
        snprintf(out, outsz, "{\"error\":\"invalid weather query\"}");
        return;
    }

    char cur[256];
    read_cache(WX_REQUEST, "", cur, sizeof(cur));
    if (strcmp(cur, query) != 0) {
        FILE *f = fopen(WX_REQUEST, "w");
        if (f) {
            fprintf(f, "%s\n", query);
            fclose(f);
        }
    }
    read_cache(WX_CACHE, WX_DEFAULT, out, outsz);
}

static int valid_network(const char *s) {
    size_t len = strlen(s);
    if (len == 0 || len > 32) return 0;
    for (size_t i = 0; i < len; i++)
        if (!islower((unsigned char)s[i]) && !isdigit((unsigned char)s[i]) && s[i] != '-')
            return 0;
    return 1;
}

/* Collects vpn-assign's per-network assignment files into a JSON object.
 * Values are the file's first word, kept only if it is a plain identifier. */
static void read_assignments(char *buf, size_t bufsz) {
    size_t off = (size_t)snprintf(buf, bufsz, "{");
    DIR *d = opendir(VPN_STATE);
    if (d) {
        const char *sep = "";
        struct dirent *e;
        while ((e = readdir(d)) != NULL) {
            char net[64];
            const char *dot = strstr(e->d_name, ".assignment");
            size_t nlen = dot ? (size_t)(dot - e->d_name) : 0;
            if (!dot || dot[11] != 0 || nlen == 0 || nlen >= sizeof(net)) continue;
            memcpy(net, e->d_name, nlen);
            net[nlen] = 0;
            if (!valid_network(net)) continue;

            char path[256], val[64];
            snprintf(path, sizeof(path), "%s/%s", VPN_STATE, e->d_name);
            read_cache(path, "", val, sizeof(val));
            val[strcspn(val, " \t\r\n")] = 0;
            int ok = val[0] != 0;
            for (char *c = val; ok && *c; c++)
                ok = isalnum((unsigned char)*c) || *c == '-' || *c == '_';
            if (!ok) continue;

            int n = snprintf(buf + off, bufsz - off, "%s\"%s\":\"%s\"", sep, net, val);
            if (n < 0 || (size_t)n >= bufsz - off) break;
            off += (size_t)n;
            sep = ",";
        }
        closedir(d);
    }
    if (off + 2 <= bufsz) {
        buf[off++] = '}';
        buf[off] = 0;
    } else {
        snprintf(buf, bufsz, "{}");
    }
}

/* "<on|off> <network>": routes the network through its wg-<network> tunnel
 * or straight out the WAN via vpn-assign, then reports every assignment. */
static void handle_vpnset(const char *arg, char *out, size_t outsz) {
    char action[8] = "", net[64] = "";
    if (sscanf(arg, "%7s %63s", action, net) != 2
        || (strcmp(action, "on") && strcmp(action, "off"))
        || !valid_network(net)) {
        snprintf(out, outsz, "{\"ok\":false,\"error\":\"usage: VPNSET\\non|off <network>\"}");
        return;
    }
    char *argv[] = {"vpn-assign", action, net, NULL};
    int rc = run_cmd(argv);
    char vpn[4096];
    read_assignments(vpn, sizeof(vpn));
    snprintf(out, outsz, "{\"ok\":%s,\"vpn\":%s}", rc == 0 ? "true" : "false", vpn);
}

static void handle_remove(const char *ssid, char *out, size_t outsz) {
    if (strlen(ssid) == 0) {
        snprintf(out, outsz, "{\"ok\":false,\"error\":\"missing ssid\"}");
        return;
    }
    char *argv[] = {"nmcli", "con", "delete", (char *)ssid, NULL};
    if (run_cmd(argv) == 0) {
        snprintf(out, outsz, "{\"ok\":true}");
    } else {
        snprintf(out, outsz, "{\"ok\":false,\"error\":\"connection not found: %s\"}", ssid);
    }
}

/* Reads one request off cfd: first line is the command, ADD/REMOVE carry
 * one/two more lines, WEATHER/VPNSET one. Stops as soon as it has enough lines for the command
 * it saw, so a one-line POLL/STATUS/PING/NET/WG/ALL doesn't block waiting
 * for a peer that already sent its full request and is waiting on a reply. */
static int read_request(int cfd, char lines[3][256]) {
    size_t buflen = 0;
    int nlines = 0;
    int need = 1;

    struct timeval tv = {.tv_sec = 3, .tv_usec = 0};
    setsockopt(cfd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    for (;;) {
        char chunk[512];
        ssize_t r = recv(cfd, chunk, sizeof(chunk), 0);
        if (r <= 0) break;
        for (ssize_t i = 0; i < r && nlines < 3; i++) {
            char c = chunk[i];
            if (c == '\n') {
                lines[nlines][buflen < 255 ? buflen : 255] = 0;
                nlines++;
                buflen = 0;
                if (nlines == 1) {
                    char up[16];
                    size_t k = 0;
                    for (; lines[0][k] && k < 15; k++)
                        up[k] = (char)toupper((unsigned char)lines[0][k]);
                    up[k] = 0;
                    if (!strcmp(up, "ADD") || !strcmp(up, "REMOVE")) need = 3;
                    else if (!strcmp(up, "WEATHER") || !strcmp(up, "VPNSET")) need = 2;
                }
                if (nlines >= need) goto done;
            } else if (buflen < 255) {
                lines[nlines][buflen++] = c;
            }
        }
    }
done:
    if (buflen > 0 && nlines < 3) {
        lines[nlines][buflen < 255 ? buflen : 255] = 0;
        nlines++;
    }
    for (int i = nlines; i < 3; i++) lines[i][0] = 0;
    return nlines;
}

static void to_upper_inplace(char *s) {
    for (; *s; s++) *s = (char)toupper((unsigned char)*s);
}

static void handle_conn(int cfd) {
    char lines[3][256];
    read_request(cfd, lines);
    to_upper_inplace(lines[0]);

    char out[BUF_MAX];

    if (!strcmp(lines[0], "PING")) {
        send_all(cfd, "PONG", 4);
    } else if (!strcmp(lines[0], "POLL") || !strcmp(lines[0], "STATUS")) {
        size_t n = read_cache(WIFI_CACHE, WIFI_DEFAULT, out, sizeof(out));
        send_all(cfd, out, n);
    } else if (!strcmp(lines[0], "NET")) {
        size_t n = read_cache(NET_CACHE, NET_DEFAULT, out, sizeof(out));
        send_all(cfd, out, n);
    } else if (!strcmp(lines[0], "WG")) {
        size_t n = read_cache(WG_CACHE, WG_DEFAULT, out, sizeof(out));
        send_all(cfd, out, n);
    } else if (!strcmp(lines[0], "ALL")) {
        char wifi[BUF_MAX / 4], net[BUF_MAX / 4], wg[BUF_MAX / 4], vpn[4096];
        read_cache(WIFI_CACHE, WIFI_DEFAULT, wifi, sizeof(wifi));
        read_cache(NET_CACHE, NET_DEFAULT, net, sizeof(net));
        read_cache(WG_CACHE, WG_DEFAULT, wg, sizeof(wg));
        read_assignments(vpn, sizeof(vpn));
        int n = snprintf(out, sizeof(out), "{\"wifi\":%s,\"net\":%s,\"wg\":%s,\"vpn\":%s}",
                         wifi, net, wg, vpn);
        if (n > 0) send_all(cfd, out, (size_t)n);
    } else if (!strcmp(lines[0], "ADD")) {
        handle_add(lines[1], lines[2], out, sizeof(out));
        send_all(cfd, out, strlen(out));
    } else if (!strcmp(lines[0], "REMOVE")) {
        handle_remove(lines[1], out, sizeof(out));
        send_all(cfd, out, strlen(out));
    } else if (!strcmp(lines[0], "VPN")) {
        read_assignments(out, sizeof(out));
        send_all(cfd, out, strlen(out));
    } else if (!strcmp(lines[0], "VPNSET")) {
        handle_vpnset(lines[1], out, sizeof(out));
        send_all(cfd, out, strlen(out));
    } else if (!strcmp(lines[0], "WEATHER")) {
        handle_weather(lines[1], out, sizeof(out));
        send_all(cfd, out, strlen(out));
    } else {
        const char *err = "{\"error\":\"unknown command\"}";
        send_all(cfd, err, strlen(err));
    }
    close(cfd);
}

int main(void) {
    int lfd = socket(AF_VSOCK, SOCK_STREAM, 0);
    if (lfd < 0) { perror("vsock socket"); return 1; }

    int opt = 1;
    setsockopt(lfd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

    struct sockaddr_vm addr;
    memset(&addr, 0, sizeof(addr));
    addr.svm_family = AF_VSOCK;
    addr.svm_cid    = VMADDR_CID_ANY;
    addr.svm_port   = VSOCK_PORT;

    if (bind(lfd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        perror("vsock bind"); return 1;
    }
    if (listen(lfd, 16) < 0) {
        perror("vsock listen"); return 1;
    }

    fprintf(stderr, "router-stats-server listening on vsock:%d\n", VSOCK_PORT);

    for (;;) {
        int cfd = accept(lfd, NULL, NULL);
        if (cfd < 0) continue;
        handle_conn(cfd);
    }
    return 0;
}
