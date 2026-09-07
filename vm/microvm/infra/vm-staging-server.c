/*
 * vm-staging-server.c — persistent vsock server for host package sync
 *
 * Replaces `socat VSOCK-LISTEN:14502,reuseaddr,fork EXEC:handler`. Every
 * incoming connection to that pattern forks a new socat child, execs a
 * shell, execs the actual payload - on a low-vCPU guest that fork+exec
 * chain (and the virtiofs round trips it causes while resolving
 * /nix/store paths for each new process) is a measurable CPU cost,
 * independent of how cheap the payload itself is.
 *
 * This process starts once, holds the vsock listener open, and answers
 * `list`/`dev` (the two commands waybar's periodic sync poll actually
 * hits) directly via opendir/stat - no process ever forked for those.
 * `get`/`info`/`unstage` are rare, human-triggered actions (not on the
 * polling path), so they still shell out to `tar`/`du`/`rm` via
 * fork+execvp - that cost doesn't recur every poll cycle.
 *
 * Build:
 *   gcc -O2 -o vm-staging-server vm-staging-server.c
 *
 * Protocol: client connects, sends one command line, gets one response
 * (or, for `get`, a raw tar stream), connection closes.
 *
 *   list            -> {"packages":[...],"vm":"<name>","type":"<type>"}
 *   dev             -> {"packages":[{"name":...,"staged":bool},...],"vm":...,"type":...}
 *   info <pkg>      -> {"name":...,"size":N,"vm":...,"type":...}
 *   get <pkg>       -> raw tar stream of the package directory
 *   unstage <pkg>   -> {"ok":true,"unstaged":"<pkg>"} or {"error":"not found"}
 */

#include <dirent.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

#ifndef AF_VSOCK
#define AF_VSOCK 40
#endif
#define VMADDR_CID_ANY ((unsigned int)-1U)
#define VSOCK_PORT 14502

struct sockaddr_vm {
    unsigned short svm_family;
    unsigned short svm_reserved1;
    unsigned int   svm_port;
    unsigned int   svm_cid;
    unsigned char  svm_zero[4];
};

static char staging_dir[512];
static char dev_dir[512];
static char vm_name[128];
static char vm_type[64];

static int has_file(const char *dir, const char *name) {
    char path[2048];
    struct stat st;
    snprintf(path, sizeof(path), "%s/%s", dir, name);
    return stat(path, &st) == 0;
}

/* Recursively sums file sizes under path - replaces `du -sb`. */
static long long dir_size(const char *path) {
    DIR *d = opendir(path);
    if (!d) return 0;
    long long total = 0;
    struct dirent *ent;
    while ((ent = readdir(d)) != NULL) {
        if (!strcmp(ent->d_name, ".") || !strcmp(ent->d_name, "..")) continue;
        char child[1024];
        snprintf(child, sizeof(child), "%s/%s", path, ent->d_name);
        struct stat st;
        if (lstat(child, &st) != 0) continue;
        if (S_ISDIR(st.st_mode)) {
            total += dir_size(child);
        } else {
            total += st.st_size;
        }
    }
    closedir(d);
    return total;
}

static void send_all(int fd, const char *data, size_t len) {
    size_t off = 0;
    while (off < len) {
        ssize_t w = send(fd, data + off, len - off, 0);
        if (w <= 0) return;
        off += (size_t)w;
    }
}

static void send_str(int fd, const char *s) { send_all(fd, s, strlen(s)); }

static int run_exec(char *const argv[], int out_fd) {
    pid_t pid = fork();
    if (pid < 0) return -1;
    if (pid == 0) {
        if (out_fd >= 0) dup2(out_fd, STDOUT_FILENO);
        execvp(argv[0], argv);
        _exit(127);
    }
    int status = 0;
    waitpid(pid, &status, 0);
    return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
}

/* list: JSON array of staged package dirs containing package.nix. */
static void cmd_list(int fd) {
    char out[8192];
    size_t off = (size_t)snprintf(out, sizeof(out), "{\"packages\":[");
    int first = 1;

    DIR *d = opendir(staging_dir);
    if (d) {
        struct dirent *ent;
        while ((ent = readdir(d)) != NULL) {
            if (ent->d_name[0] == '.') continue;
            char sub[1024];
            snprintf(sub, sizeof(sub), "%s/%s", staging_dir, ent->d_name);
            if (!has_file(sub, "package.nix")) continue;
            off += (size_t)snprintf(out + off, sizeof(out) - off, "%s\"%s\"",
                                     first ? "" : ",", ent->d_name);
            first = 0;
        }
        closedir(d);
    }
    off += (size_t)snprintf(out + off, sizeof(out) - off,
                             "],\"vm\":\"%s\",\"type\":\"%s\"}", vm_name, vm_type);
    send_all(fd, out, off);
}

/* dev: JSON array of dev packages (containing flake.nix) with staged status. */
static void cmd_dev(int fd) {
    char out[8192];
    size_t off = (size_t)snprintf(out, sizeof(out), "{\"packages\":[");
    int first = 1;

    DIR *d = opendir(dev_dir);
    if (d) {
        struct dirent *ent;
        while ((ent = readdir(d)) != NULL) {
            if (ent->d_name[0] == '.') continue;
            char sub[1024];
            snprintf(sub, sizeof(sub), "%s/%s", dev_dir, ent->d_name);
            if (!has_file(sub, "flake.nix")) continue;
            char staged_check[1024];
            snprintf(staged_check, sizeof(staged_check), "%s/%s", staging_dir, ent->d_name);
            int staged = has_file(staged_check, "package.nix");
            off += (size_t)snprintf(out + off, sizeof(out) - off,
                                     "%s{\"name\":\"%s\",\"staged\":%s}",
                                     first ? "" : ",", ent->d_name, staged ? "true" : "false");
            first = 0;
        }
        closedir(d);
    }
    off += (size_t)snprintf(out + off, sizeof(out) - off,
                             "],\"vm\":\"%s\",\"type\":\"%s\"}", vm_name, vm_type);
    send_all(fd, out, off);
}

static void cmd_info(int fd, const char *pkg) {
    char pkg_dir[1024];
    snprintf(pkg_dir, sizeof(pkg_dir), "%s/%s", staging_dir, pkg);
    if (!has_file(pkg_dir, "package.nix")) {
        send_str(fd, "{\"error\":\"not found\"}");
        return;
    }
    long long size = dir_size(pkg_dir);
    char out[512];
    int n = snprintf(out, sizeof(out), "{\"name\":\"%s\",\"size\":%lld,\"vm\":\"%s\",\"type\":\"%s\"}",
                      pkg, size, vm_name, vm_type);
    send_all(fd, out, (size_t)n);
}

/* get: rare/interactive - fine to exec tar, streaming straight to the socket. */
static void cmd_get(int fd, const char *pkg) {
    char pkg_dir[1024];
    snprintf(pkg_dir, sizeof(pkg_dir), "%s/%s", staging_dir, pkg);
    if (!has_file(pkg_dir, "package.nix")) {
        fprintf(stderr, "ERROR: package '%s' not found\n", pkg);
        return;
    }
    char *argv[] = {"tar", "cf", "-", "-C", staging_dir, (char *)pkg, NULL};
    run_exec(argv, fd);
}

/* unstage: rare/interactive - fine to exec rm -rf. */
static void cmd_unstage(int fd, const char *pkg) {
    char pkg_dir[1024];
    snprintf(pkg_dir, sizeof(pkg_dir), "%s/%s", staging_dir, pkg);
    struct stat st;
    if (stat(pkg_dir, &st) != 0) {
        send_str(fd, "{\"error\":\"not found\"}");
        return;
    }
    char *argv[] = {"rm", "-rf", pkg_dir, NULL};
    run_exec(argv, -1);
    char out[256];
    int n = snprintf(out, sizeof(out), "{\"ok\":true,\"unstaged\":\"%s\"}", pkg);
    send_all(fd, out, (size_t)n);
}

static void handle_conn(int cfd) {
    struct timeval tv = {.tv_sec = 5, .tv_usec = 0};
    setsockopt(cfd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    char buf[512] = {0};
    ssize_t n = recv(cfd, buf, sizeof(buf) - 1, 0);
    if (n <= 0) { close(cfd); return; }
    buf[n] = 0;
    char *nl = strpbrk(buf, "\r\n");
    if (nl) *nl = 0;

    char *arg = strchr(buf, ' ');
    if (arg) { *arg = 0; arg++; }

    if (!strcmp(buf, "list")) {
        cmd_list(cfd);
    } else if (!strcmp(buf, "dev")) {
        cmd_dev(cfd);
    } else if (!strcmp(buf, "info") && arg) {
        cmd_info(cfd, arg);
    } else if (!strcmp(buf, "get") && arg) {
        cmd_get(cfd, arg);
    } else if (!strcmp(buf, "unstage") && arg) {
        cmd_unstage(cfd, arg);
    } else {
        send_str(cfd, "{\"error\":\"unknown command\",\"commands\":[\"list\",\"get <pkg>\",\"info <pkg>\",\"dev\",\"unstage <pkg>\"]}");
    }
    close(cfd);
}

int main(int argc, char *argv[]) {
    if (argc < 4) {
        fprintf(stderr, "usage: %s <staging_dir> <dev_dir> <vm_name> [vm_type]\n", argv[0]);
        return 1;
    }
    snprintf(staging_dir, sizeof(staging_dir), "%s", argv[1]);
    snprintf(dev_dir, sizeof(dev_dir), "%s", argv[2]);
    snprintf(vm_name, sizeof(vm_name), "%s", argv[3]);
    snprintf(vm_type, sizeof(vm_type), "%s", argc > 4 ? argv[4] : "");

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

    fprintf(stderr, "vm-staging-server listening on vsock:%d\n", VSOCK_PORT);

    for (;;) {
        int cfd = accept(lfd, NULL, NULL);
        if (cfd < 0) continue;
        handle_conn(cfd);
    }
    return 0;
}
