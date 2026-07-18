/*
 * vm-metrics.c — VM metrics collector + vsock server
 *
 * Reads CPU/RAM/disk/uptime/processes/tunnel directly from /proc and
 * local FS. Zero external binary calls — pure syscalls only.
 *
 * Build:
 *   gcc -O2 -o vm-metrics vm-metrics.c -lpthread
 *
 * Usage:
 *   ./vm-metrics [interval]          — print metrics to stdout (test mode)
 *   ./vm-metrics --serve [interval]  — write snapshot + serve vsock:14501
 *
 * Snapshot format (key=value, one per line):
 *   cpu=<percent>   ram=<percent>   fs=<percent>   uptime=<XH YM>
 *   top=<comm pct>  topmem=<comm MB>
 *   syncdev=<n>     syncstg=<n>     tun=<iface|none>
 *
 * Vsock commands: all | cpu | ram | fs | uptime | top | topmem | tun | sync
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <dirent.h>
#include <sys/statvfs.h>
#include <sys/socket.h>
#include <pthread.h>
#include <ctype.h>

/* vsock constants — defined manually to avoid linux/vm_sockets.h conflicts */
#ifndef AF_VSOCK
#define AF_VSOCK 40
#endif
#define VMADDR_CID_ANY  ((unsigned int)-1U)
#define VSOCK_PORT      14501

struct sockaddr_vm {
    unsigned short svm_family;
    unsigned short svm_reserved1;
    unsigned int   svm_port;
    unsigned int   svm_cid;
    unsigned char  svm_zero[4];
};

#define MAX_PROCS  4096
#define COMM_LEN   16    /* kernel TASK_COMM_LEN: 15 chars + NUL */
#define SNAP_TMP_SUFFIX ".tmp"

/* read_top_procs() walks all of /proc every call (3 file opens per process) —
 * too expensive to run on every tick. Only rescan every TOP_SCAN_EVERY ticks;
 * cpu/ram/fs stay on the fast `interval` cadence since those are cheap. */
#define TOP_SCAN_EVERY 6

static long sc_clk_tck;
static long sc_page_kb;
static char snap_path[256];   /* empty = stdout mode */

/* ── CPU ───────────────────────────────────────────────────────────────── */

typedef struct {
    long long user, nice, sys, idle, iowait, irq, softirq, steal;
} CpuStat;

static int read_cpu_stat(CpuStat *s) {
    FILE *f = fopen("/proc/stat", "r");
    if (!f) return -1;
    int ok = fscanf(f, "cpu %lld %lld %lld %lld %lld %lld %lld %lld",
                    &s->user, &s->nice, &s->sys, &s->idle,
                    &s->iowait, &s->irq, &s->softirq, &s->steal) == 8;
    fclose(f);
    return ok ? 0 : -1;
}

static int cpu_percent(const CpuStat *a, const CpuStat *b) {
    long long idle_a  = a->idle + a->iowait;
    long long idle_b  = b->idle + b->iowait;
    long long total_a = a->user + a->nice + a->sys + idle_a
                      + a->irq + a->softirq + a->steal;
    long long total_b = b->user + b->nice + b->sys + idle_b
                      + b->irq + b->softirq + b->steal;
    long long dt = total_b - total_a;
    long long di = idle_b  - idle_a;
    if (dt <= 0) return 0;
    int pct = (int)(100 - di * 100 / dt);
    return pct < 0 ? 0 : pct > 100 ? 100 : pct;
}

/* ── RAM ───────────────────────────────────────────────────────────────── */

static int ram_percent(void) {
    FILE *f = fopen("/proc/meminfo", "r");
    if (!f) return 0;
    long long total = 0, available = 0;
    char key[64]; long long val;
    while (fscanf(f, "%63s %lld kB\n", key, &val) == 2) {
        if (!strcmp(key, "MemTotal:"))         total     = val;
        else if (!strcmp(key, "MemAvailable:")) available = val;
    }
    fclose(f);
    if (total <= 0) return 0;
    int pct = (int)((total - available) * 100 / total);
    return pct < 0 ? 0 : pct > 100 ? 100 : pct;
}

/* ── Disk ──────────────────────────────────────────────────────────────── */

static int fs_percent(void) {
    struct statvfs st;
    const char *paths[] = { "/home", "/", NULL };
    for (int i = 0; paths[i]; i++) {
        if (statvfs(paths[i], &st) == 0 && st.f_blocks > 0) {
            unsigned long used = st.f_blocks - st.f_bfree;
            return (int)(used * 100 / st.f_blocks);
        }
    }
    return 0;
}

/* ── Uptime ────────────────────────────────────────────────────────────── */

static void uptime_str(char *buf, size_t n) {
    FILE *f = fopen("/proc/uptime", "r");
    if (!f) { snprintf(buf, n, "0H 0M"); return; }
    double secs = 0;
    fscanf(f, "%lf", &secs);
    fclose(f);
    long s = (long)secs;
    long h = s / 3600, m = (s % 3600) / 60;
    if (h >= 24) snprintf(buf, n, "%ldD %ldH", h / 24, h % 24);
    else         snprintf(buf, n, "%ldH %ldM", h, m);
}

/* ── Process tracking ──────────────────────────────────────────────────── */

typedef struct { unsigned int pid; long long ticks; } ProcTick;

static ProcTick prev_ticks[MAX_PROCS];
static int      prev_count = 0;

static long long lookup_prev(unsigned int pid) {
    for (int i = 0; i < prev_count; i++)
        if (prev_ticks[i].pid == pid) return prev_ticks[i].ticks;
    return -1;
}

static void store_prev(unsigned int pid, long long ticks) {
    for (int i = 0; i < prev_count; i++) {
        if (prev_ticks[i].pid == pid) { prev_ticks[i].ticks = ticks; return; }
    }
    if (prev_count < MAX_PROCS) {
        prev_ticks[prev_count].pid   = pid;
        prev_ticks[prev_count].ticks = ticks;
        prev_count++;
    }
}

static int read_proc_ticks(unsigned int pid, long long *out) {
    char path[64];
    snprintf(path, sizeof(path), "/proc/%u/stat", pid);
    FILE *f = fopen(path, "r");
    if (!f) return -1;
    char buf[512];
    if (!fgets(buf, sizeof(buf), f)) { fclose(f); return -1; }
    fclose(f);
    /* comm can contain spaces — find the last ')' to safely skip it */
    char *p = strrchr(buf, ')');
    if (!p) return -1;
    p++;
    long long u, s;
    /* after ')': state ppid pgrp session tty tpgid flags
       minflt cminflt majflt cmajflt utime stime — skip 11, read 2 */
    if (sscanf(p, " %*c %*d %*d %*d %*d %*d %*u %*u %*u %*u %*u %lld %lld",
               &u, &s) == 2) {
        *out = u + s;
        return 0;
    }
    return -1;
}

static void read_top_procs(int interval, char *top_cpu, char *top_mem) {
    DIR *dp = opendir("/proc");
    if (!dp) { strcpy(top_cpu, "- 0"); strcpy(top_mem, "- 0"); return; }

    char      best_cpu_comm[COMM_LEN] = "-";
    long long best_delta = 0;
    char      best_mem_comm[COMM_LEN] = "-";
    long      best_mem_mb = 0;

    struct dirent *de;
    while ((de = readdir(dp))) {
        const char *name = de->d_name;
        int is_pid = (name[0] >= '1' && name[0] <= '9');
        for (int i = 1; is_pid && name[i]; i++)
            if (!isdigit((unsigned char)name[i])) is_pid = 0;
        if (!is_pid) continue;

        unsigned int pid = (unsigned int)atoi(name);
        char path[64], comm[COMM_LEN];

        snprintf(path, sizeof(path), "/proc/%u/comm", pid);
        FILE *f = fopen(path, "r");
        if (!f) continue;
        if (!fgets(comm, sizeof(comm), f)) { fclose(f); continue; }
        fclose(f);
        comm[strcspn(comm, "\n")] = 0;

        long long ticks;
        if (read_proc_ticks(pid, &ticks) == 0) {
            long long prev = lookup_prev(pid);
            store_prev(pid, ticks);
            if (prev >= 0) {
                long long delta = ticks - prev;
                if (delta > best_delta) {
                    best_delta = delta;
                    strncpy(best_cpu_comm, comm, COMM_LEN - 1);
                    best_cpu_comm[COMM_LEN - 1] = 0;
                }
            }
        }

        snprintf(path, sizeof(path), "/proc/%u/statm", pid);
        f = fopen(path, "r");
        if (!f) continue;
        long size_pages, rss_pages;
        if (fscanf(f, "%ld %ld", &size_pages, &rss_pages) == 2) {
            long rss_mb = rss_pages * sc_page_kb / 1024;
            if (rss_mb > best_mem_mb) {
                best_mem_mb = rss_mb;
                strncpy(best_mem_comm, comm, COMM_LEN - 1);
                best_mem_comm[COMM_LEN - 1] = 0;
            }
        }
        fclose(f);
    }
    closedir(dp);

    int cpu_pct = (int)(best_delta * 100 / ((long long)interval * sc_clk_tck));
    if (cpu_pct > 999) cpu_pct = 999;
    snprintf(top_cpu, 48, "%s %d", best_cpu_comm, cpu_pct);
    snprintf(top_mem, 48, "%s %ld", best_mem_comm, best_mem_mb);
}

/* ── Tunnel ────────────────────────────────────────────────────────────── */

static void read_tun(char *buf, size_t n) {
    FILE *f = fopen("/proc/net/dev", "r");
    if (!f) { snprintf(buf, n, "none"); return; }
    char line[256];
    fgets(line, sizeof(line), f);
    fgets(line, sizeof(line), f);
    while (fgets(line, sizeof(line), f)) {
        char *colon = strchr(line, ':');
        if (!colon) continue;
        *colon = 0;
        char *iface = line;
        while (*iface == ' ') iface++;
        if ((strncmp(iface, "tun", 3) == 0 && isdigit((unsigned char)iface[3])) ||
            (strncmp(iface, "wg",  2) == 0 && isdigit((unsigned char)iface[2])) ||
            (strncmp(iface, "tap", 3) == 0 && isdigit((unsigned char)iface[3]))) {
            snprintf(buf, n, "%s", iface);
            fclose(f);
            return;
        }
    }
    fclose(f);
    snprintf(buf, n, "none");
}

/* ── Package counts ────────────────────────────────────────────────────── */

static int pkg_count(const char *base, const char *sub, const char *fname) {
    char path[512];
    snprintf(path, sizeof(path), "%s/%s", base, sub);
    DIR *dp = opendir(path);
    if (!dp) return 0;
    int count = 0;
    struct dirent *de;
    while ((de = readdir(dp))) {
        if (de->d_name[0] == '.') continue;
        char fpath[576];
        snprintf(fpath, sizeof(fpath), "%s/%s/%s", path, de->d_name, fname);
        if (access(fpath, F_OK) == 0) count++;
    }
    closedir(dp);
    return count;
}

/* ── Snapshot write ────────────────────────────────────────────────────── */

static void write_snapshot(int cpu, int ram, int fs, const char *up,
                            const char *top_cpu, const char *top_mem,
                            int dev, int stg, const char *tun) {
    char tmp[300];
    snprintf(tmp, sizeof(tmp), "%s%s", snap_path, SNAP_TMP_SUFFIX);
    FILE *f = fopen(tmp, "w");
    if (!f) return;
    fprintf(f, "cpu=%d\nram=%d\nfs=%d\nuptime=%s\ntop=%s\ntopmem=%s\n"
               "syncdev=%d\nsyncstg=%d\ntun=%s\n",
            cpu, ram, fs, up, top_cpu, top_mem, dev, stg, tun);
    fclose(f);
    rename(tmp, snap_path);
}

/* ── Snapshot field lookup ─────────────────────────────────────────────── */

static int snap_get(const char *key, char *out, size_t out_len) {
    FILE *f = fopen(snap_path, "r");
    if (!f) return -1;
    char line[256];
    size_t klen = strlen(key);
    while (fgets(line, sizeof(line), f)) {
        if (strncmp(line, key, klen) == 0 && line[klen] == '=') {
            char *val = line + klen + 1;
            size_t vlen = strlen(val);
            while (vlen > 0 && (val[vlen-1] == '\n' || val[vlen-1] == '\r'))
                vlen--;
            if (vlen >= out_len) vlen = out_len - 1;
            memcpy(out, val, vlen);
            out[vlen] = 0;
            fclose(f);
            return 0;
        }
    }
    fclose(f);
    return -1;
}

/* ── Vsock server ──────────────────────────────────────────────────────── */

#define FALLBACK "cpu=0\nram=0\nfs=0\nuptime=0H 0M\ntop=- 0\ntopmem=- 0\n" \
                 "syncdev=0\nsyncstg=0\ntun=none\n"

static void handle_conn(int cfd) {
    struct timeval tv = { .tv_sec = 2, .tv_usec = 0 };
    setsockopt(cfd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    char cmd[64];
    int n = (int)recv(cfd, cmd, sizeof(cmd) - 1, 0);
    if (n <= 0) { close(cfd); return; }
    cmd[n] = 0;
    /* strip trailing whitespace/newlines */
    for (int i = n - 1; i >= 0 && (cmd[i] == '\n' || cmd[i] == '\r' || cmd[i] == ' '); i--)
        cmd[i] = 0;

    if (strcmp(cmd, "all") == 0) {
        FILE *f = fopen(snap_path, "rb");
        if (!f) {
            send(cfd, FALLBACK, sizeof(FALLBACK) - 1, 0);
        } else {
            char buf[512];
            size_t r;
            while ((r = fread(buf, 1, sizeof(buf), f)) > 0)
                send(cfd, buf, r, 0);
            fclose(f);
        }
    } else if (strcmp(cmd, "sync") == 0) {
        char dev[32] = "0", stg[32] = "0";
        snap_get("syncdev", dev, sizeof(dev));
        snap_get("syncstg", stg, sizeof(stg));
        char resp[72];
        snprintf(resp, sizeof(resp), "%s %s\n", dev, stg);
        send(cfd, resp, strlen(resp), 0);
    } else {
        /* single field */
        const char *fallback = "0";
        if (!strcmp(cmd, "uptime"))                        fallback = "0H 0M";
        else if (!strcmp(cmd, "top") || !strcmp(cmd, "topmem")) fallback = "- 0";
        else if (!strcmp(cmd, "tun"))                      fallback = "none";

        char val[128];
        if (snap_get(cmd, val, sizeof(val)) < 0)
            strncpy(val, fallback, sizeof(val) - 1);

        char resp[144];
        snprintf(resp, sizeof(resp), "%s\n", val);
        send(cfd, resp, strlen(resp), 0);
    }
    close(cfd);
}

static void *server_thread(void *arg) {
    (void)arg;

    int lfd = socket(AF_VSOCK, SOCK_STREAM, 0);
    if (lfd < 0) { perror("vsock socket"); return NULL; }

    int opt = 1;
    setsockopt(lfd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

    struct sockaddr_vm addr;
    memset(&addr, 0, sizeof(addr));
    addr.svm_family = AF_VSOCK;
    addr.svm_cid    = VMADDR_CID_ANY;
    addr.svm_port   = VSOCK_PORT;

    if (bind(lfd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        perror("vsock bind"); close(lfd); return NULL;
    }
    if (listen(lfd, 8) < 0) {
        perror("vsock listen"); close(lfd); return NULL;
    }

    fprintf(stderr, "vsock server listening on port %d\n", VSOCK_PORT);

    for (;;) {
        int cfd = accept(lfd, NULL, NULL);
        if (cfd < 0) continue;
        handle_conn(cfd);
    }
    return NULL;
}

/* ── Main ──────────────────────────────────────────────────────────────── */

int main(int argc, char *argv[]) {
    sc_clk_tck = sysconf(_SC_CLK_TCK);
    sc_page_kb  = sysconf(_SC_PAGESIZE) / 1024;

    int serve    = 0;
    int interval = 5;

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--serve")) {
            serve = 1;
            snprintf(snap_path, sizeof(snap_path), "/run/vm-metrics-snapshot");
        } else {
            int v = atoi(argv[i]);
            if (v > 0) interval = v;
        }
    }

    const char *home = getenv("HOME");
    if (!home || home[0] == 0) home = "/home/hydrix";

    if (serve) {
        pthread_t tid;
        if (pthread_create(&tid, NULL, server_thread, NULL) != 0) {
            perror("pthread_create");
            return 1;
        }
        pthread_detach(tid);
    }

    /* Prime deltas — without this, first sample shows cpu=0 / top=- 0 */
    CpuStat cpu_prev;
    read_cpu_stat(&cpu_prev);
    char top_cpu[48] = "- 0", top_mem[48] = "- 0";
    read_top_procs(interval, top_cpu, top_mem);
    int tick = 1; /* starts at 1: next full top-procs rescan lands at TOP_SCAN_EVERY
                     ticks after the priming call above, keeping the elapsed-time
                     math below accurate in steady state */

    for (;;) {
        sleep((unsigned)interval);

        CpuStat cpu_curr;
        read_cpu_stat(&cpu_curr);
        int cpu = cpu_percent(&cpu_prev, &cpu_curr);
        cpu_prev = cpu_curr;

        char up[32], tun[32];
        uptime_str(up, sizeof(up));
        if (tick % TOP_SCAN_EVERY == 0) {
            read_top_procs(interval * TOP_SCAN_EVERY, top_cpu, top_mem);
        }
        tick++;
        read_tun(tun, sizeof(tun));

        int dev = pkg_count(home, "dev/packages", "flake.nix");
        int stg = pkg_count(home, "staging",      "package.nix");
        int ram = ram_percent();
        int fs  = fs_percent();

        if (serve) {
            write_snapshot(cpu, ram, fs, up, top_cpu, top_mem, dev, stg, tun);
        } else {
            printf("cpu=%d\nram=%d\nfs=%d\nuptime=%s\ntop=%s\ntopmem=%s\n"
                   "syncdev=%d\nsyncstg=%d\ntun=%s\n\n",
                   cpu, ram, fs, up, top_cpu, top_mem, dev, stg, tun);
            fflush(stdout);
        }
    }
    return 0;
}
