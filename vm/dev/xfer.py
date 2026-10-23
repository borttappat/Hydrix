"""hydrix-xfer: streaming, end-to-end encrypted file transfer between VMs.

The stream on the bridge networks is age(zstd(tar)). The host generates an
X25519 identity per transfer: the source VM only gets the public recipient,
the receiving VM gets the identity over vsock (a second line on its agent
connection, never argv or environment). The files VM in the middle only sees
ciphertext and never holds a key, so it can neither read nor forge a stream.

age authenticates every 64 KiB chunk and the end of the stream, so a modified,
reordered or truncated stream fails decryption. The receiver extracts into a
staging directory and only moves the result into place on COMMIT, which the
host sends after the source and receiver report the same ciphertext SHA-256.

Subcommands print status lines on stdout:
  LISTENING [SIZE=<bytes>] [FREE=<bytes>]   listener ready (send, recv)
  PROGRESS <bytes>                          relay only, every PROGRESS_EVERY s
  WARN: <text>
  OK SHA256=<hex> BYTES=<n> [SKIPPED=<n>]   or   ERROR: <text>
"""

import argparse
import base64
import hashlib
import json
import os
import re
import shutil
import signal
import socket
import subprocess
import sys
import tarfile
import threading
import time

CHUNK = 1 << 20
ACCEPT_TIMEOUT = 60
IDLE_TIMEOUT = 120
PROGRESS_EVERY = 1.0
STAGING = ".hydrix-xfer"
IDENTITY_RE = re.compile(r"AGE-SECRET-KEY-1[0-9A-Z]{58}")
RECIPIENT_RE = re.compile(r"age1[0-9a-z]{58}")
ID_RE = re.compile(r"[0-9a-f]{16}")
SHA_RE = re.compile(r"[0-9a-f]{64}")


CHILDREN = []


class Fail(Exception):
    pass


def spawn(*args, **kw):
    p = subprocess.Popen(*args, **kw)
    CHILDREN.append(p)
    return p


def say(line):
    sys.stdout.write(line + "\n")
    sys.stdout.flush()


def b64(value):
    try:
        return base64.b64decode(value, validate=True).decode()
    except Exception:
        raise Fail("malformed argument")


def rel_parts(rel):
    """Split a root-relative path, refusing absolute paths and '..'."""
    rel = rel.strip("/") if rel else ""
    if rel.startswith("/"):
        raise Fail(f"absolute path: {rel}")
    parts = [p for p in rel.split("/") if p not in ("", ".")]
    if ".." in parts:
        raise Fail(f"'..' in path: {rel}")
    return parts


def inside(root, rel):
    """Resolve rel under root; symlinks may not lead outside root."""
    root = os.path.realpath(root)
    full = os.path.realpath(os.path.join(root, *rel_parts(rel)))
    if full != root and not full.startswith(root + os.sep):
        raise Fail(f"path leaves {root}: {rel}")
    return full


def check_name(name):
    if not name or "/" in name or name in (".", ".."):
        raise Fail(f"invalid name: {name!r}")
    return name


def staging_dir(root, xid):
    if not ID_RE.fullmatch(xid):
        raise Fail("invalid transfer id")
    return os.path.join(root, STAGING, xid)


def write_pid(state):
    if state:
        os.makedirs(state, exist_ok=True)
        with open(os.path.join(state, "xfer.pid"), "w") as f:
            f.write(str(os.getpid()))


def clear_pid(state):
    if state:
        try:
            path = os.path.join(state, "xfer.pid")
            with open(path) as f:
                if f.read().strip() == str(os.getpid()):
                    os.unlink(path)
        except OSError:
            pass


def peer_tuple(spec):
    host, _, port = spec.rpartition(":")
    try:
        socket.inet_aton(host)
        return host, int(port)
    except (OSError, ValueError):
        raise Fail(f"invalid address: {spec}")


def listen_one(port, allow, ready):
    """Accept one connection from `allow`; others are closed and ignored."""
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        srv.bind(("0.0.0.0", port))
    except OSError as e:
        raise Fail(f"cannot listen on port {port}: {e.strerror}")
    srv.listen(4)
    say(ready)
    deadline = time.monotonic() + ACCEPT_TIMEOUT
    try:
        while True:
            left = deadline - time.monotonic()
            if left <= 0:
                raise Fail("no connection from the files VM")
            srv.settimeout(left)
            try:
                conn, addr = srv.accept()
            except socket.timeout:
                continue
            if addr[0] == allow:
                conn.settimeout(IDLE_TIMEOUT)
                return conn
            conn.close()
    finally:
        srv.close()


def connect(spec):
    try:
        conn = socket.create_connection(peer_tuple(spec), timeout=10)
    except OSError as e:
        raise Fail(f"cannot connect to {spec}: {e.strerror or e}")
    conn.settimeout(IDLE_TIMEOUT)
    return conn


def tail(data):
    """The line of a child's stderr that says what went wrong."""
    lines = [l.strip() for l in data.decode(errors="replace").splitlines() if l.strip()]
    errors = [l for l in lines if ": error:" in l or l.startswith("tar:")]
    return (errors or lines or [""])[0]


def reap(procs, grace=0):
    """Wait up to `grace` seconds for procs to exit on their own, then kill."""
    deadline = time.monotonic() + grace
    for p in procs:
        try:
            p.wait(timeout=max(0, deadline - time.monotonic()))
        except subprocess.TimeoutExpired:
            pass
    for p in procs:
        if p.poll() is None:
            p.kill()
            p.wait()


def drain_stderr(procs):
    """Collect each child's stderr in a thread so a full pipe never stalls it."""
    out = {}

    def read(key, p):
        out[key] = p.stderr.read()

    threads = [threading.Thread(target=read, args=(k, p), daemon=True) for k, p in procs.items()]
    for t in threads:
        t.start()
    return out, threads


def tree_size(path):
    if not os.path.isdir(path) or os.path.islink(path):
        return os.lstat(path).st_size
    total = 0
    for dirpath, _, files in os.walk(path):
        for f in files:
            try:
                st = os.lstat(os.path.join(dirpath, f))
            except OSError:
                continue
            total += st.st_size
    return total


def cmd_send(a):
    if not RECIPIENT_RE.fullmatch(a.recipient):
        raise Fail("invalid recipient")
    rel = b64(a.path_b64)
    parts = rel_parts(rel)
    if not parts:
        raise Fail("source path is empty")
    parent = inside(a.root, "/".join(parts[:-1]))
    name = parts[-1]
    full = os.path.join(parent, name)
    if os.path.islink(full):
        raise Fail(f"source is a symlink, give the path it points to: {rel}")
    if not os.path.exists(full):
        raise Fail(f"source not found: {rel}")

    conn = listen_one(a.listen, a.allow, f"LISTENING SIZE={tree_size(full)}")
    tar = spawn(
        ["tar", "--create", "--file=-", "--format=pax", "--directory", parent, "--", name],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )
    zstd = spawn(["zstd", "-q", "-1", "-T0", "-c"],
                 stdin=tar.stdout, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    tar.stdout.close()
    age = spawn(["age", "--encrypt", "--recipient", a.recipient],
                stdin=zstd.stdout, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    zstd.stdout.close()
    procs = {"tar": tar, "zstd": zstd, "age": age}
    stderr, readers = drain_stderr(procs)
    digest, sent = hashlib.sha256(), 0
    try:
        while True:
            chunk = age.stdout.read(CHUNK)
            if not chunk:
                break
            digest.update(chunk)
            conn.sendall(chunk)
            sent += len(chunk)
        conn.shutdown(socket.SHUT_WR)
    except OSError as e:
        raise Fail(f"stream to the files VM broke: {e.strerror or e}")
    finally:
        conn.close()
        age.stdout.close()
        reap(procs.values(), grace=10)
        for t in readers:
            t.join()
    for key, p in procs.items():
        if p.returncode != 0:
            raise Fail(f"{key} failed: {tail(stderr.get(key, b''))}")
    say(f"OK SHA256={digest.hexdigest()} BYTES={sent}")


def extract(stream, dest, name, skipped):
    """Extract a tar stream into dest. Only regular files and directories
    under `name` are created; links and special files are skipped."""
    with tarfile.open(fileobj=stream, mode="r|", bufsize=CHUNK) as tf:
        for m in tf:
            parts = m.name.split("/")
            while parts and parts[-1] == "":
                parts.pop()
            if (not parts or parts[0] != name or m.name.startswith("/")
                    or any(p in ("", ".", "..") for p in parts)):
                raise Fail(f"archive member outside '{name}': {m.name!r}")
            target = os.path.join(dest, *parts)
            if m.isdir():
                os.makedirs(target, mode=0o755, exist_ok=True)
                if not os.path.isdir(target) or os.path.islink(target):
                    raise Fail(f"archive member clashes: {m.name!r}")
            elif m.isreg():
                os.makedirs(os.path.dirname(target), mode=0o755, exist_ok=True)
                mode = 0o755 if m.mode & 0o111 else 0o644
                fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, mode)
                src = tf.extractfile(m)
                with os.fdopen(fd, "wb") as out:
                    while True:
                        buf = src.read(CHUNK)
                        if not buf:
                            break
                        out.write(buf)
                os.utime(target, (m.mtime, m.mtime))
            else:
                skipped.append(m.name)
    while stream.read(CHUNK):
        pass


def cmd_recv(a):
    identity = sys.stdin.readline().strip()
    if not IDENTITY_RE.fullmatch(identity):
        raise Fail("missing or invalid identity")
    name = check_name(b64(a.name_b64))
    dest_rel = "/".join(rel_parts(b64(a.dest_b64)))
    root = os.path.realpath(a.root)
    dest = inside(root, dest_rel)
    if os.path.lexists(os.path.join(dest, name)):
        raise Fail(f"destination exists: {os.path.join(dest_rel, name)}")
    if os.path.lexists(dest) and not os.path.isdir(dest):
        raise Fail(f"destination is not a directory: {dest_rel}")

    shutil.rmtree(os.path.join(root, STAGING), ignore_errors=True)
    stage = staging_dir(root, a.id)
    data = os.path.join(stage, "data")
    os.makedirs(data, mode=0o700)
    done = False
    try:
        free = shutil.disk_usage(stage).free
        conn = listen_one(a.listen, a.allow, f"LISTENING FREE={free}")

        # The identity reaches age through a pipe, never argv or a file.
        rfd, wfd = os.pipe()
        os.write(wfd, (identity + "\n").encode())
        os.close(wfd)
        age = spawn(["age", "--decrypt", "--identity", f"/dev/fd/{rfd}"],
                    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                    pass_fds=(rfd,))
        os.close(rfd)
        zstd = spawn(["zstd", "-q", "-d", "-c"],
                     stdin=age.stdout, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        age.stdout.close()
        procs = {"age": age, "zstd": zstd}
        stderr, readers = drain_stderr(procs)

        digest, got, feed_err = hashlib.sha256(), [0], []

        def feed():
            try:
                while True:
                    chunk = conn.recv(CHUNK)
                    if not chunk:
                        break
                    digest.update(chunk)
                    got[0] += len(chunk)
                    age.stdin.write(chunk)
            except (OSError, ValueError) as e:
                feed_err.append(e)
            finally:
                try:
                    age.stdin.close()
                except OSError:
                    pass

        feeder = threading.Thread(target=feed, daemon=True)
        feeder.start()
        skipped, failure = [], None
        try:
            extract(zstd.stdout, data, name, skipped)
        except Fail as e:
            failure = str(e)
        except (tarfile.TarError, OSError) as e:
            failure = f"extraction failed: {e}"
        finally:
            if failure:
                # Unblock the feeder and let the pipeline collapse.
                try:
                    conn.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
            zstd.stdout.close()
            reap(procs.values(), grace=10)
            feeder.join()
            conn.close()
            for t in readers:
                t.join()

        age_err = tail(stderr.get("age", b""))
        if age.returncode != 0 and not failure:
            failure = f"decryption failed: {age_err}"
        elif age.returncode != 0 and "broken pipe" not in age_err.lower():
            failure = f"decryption failed: {age_err} ({failure})"
        if not failure and feed_err:
            e = feed_err[0]
            failure = f"stream from the files VM broke: {getattr(e, 'strerror', None) or e}"
        if not failure and zstd.returncode != 0:
            failure = f"decompression failed: {tail(stderr.get('zstd', b''))}"
        if not failure and not os.path.lexists(os.path.join(data, name)):
            failure = "archive was empty"
        if failure:
            raise Fail(failure)

        sha = digest.hexdigest()
        with open(os.path.join(stage, "result.json"), "w") as f:
            json.dump({"sha256": sha, "name": name, "dest": dest_rel}, f)
        for s in skipped[:5]:
            say(f"WARN: skipped link or special file: {s}")
        done = True
        say(f"OK SHA256={sha} BYTES={got[0]} SKIPPED={len(skipped)}")
    finally:
        if not done:
            shutil.rmtree(os.path.join(root, STAGING), ignore_errors=True)


def cmd_commit(a):
    if not SHA_RE.fullmatch(a.sha256):
        raise Fail("invalid checksum")
    root = os.path.realpath(a.root)
    stage = staging_dir(root, a.id)
    try:
        with open(os.path.join(stage, "result.json")) as f:
            result = json.load(f)
    except (OSError, ValueError):
        raise Fail("no completed transfer with this id")
    try:
        if result["sha256"] != a.sha256:
            raise Fail("checksum does not match the source")
        name = check_name(result["name"])
        dest = inside(root, result["dest"])
        os.makedirs(dest, mode=0o755, exist_ok=True)
        dest = inside(root, result["dest"])
        target = os.path.join(dest, name)
        if os.path.lexists(target):
            raise Fail(f"destination exists: {target}")
        os.rename(os.path.join(stage, "data", name), target)
    finally:
        shutil.rmtree(stage, ignore_errors=True)
        try:
            os.rmdir(os.path.dirname(stage))
        except OSError:
            pass
    say("OK")


def cmd_abort(a):
    if a.state:
        try:
            with open(os.path.join(a.state, "xfer.pid")) as f:
                pid = int(f.read().strip())
            if pid != os.getpid():
                os.kill(pid, signal.SIGTERM)
        except (OSError, ValueError):
            pass
    shutil.rmtree(os.path.join(os.path.realpath(a.root), STAGING), ignore_errors=True)
    say("OK")


def cmd_relay(a):
    src = connect(a.src)
    dst = connect(a.dst)
    digest, moved, last = hashlib.sha256(), 0, time.monotonic()
    try:
        while True:
            chunk = src.recv(CHUNK)
            if not chunk:
                break
            digest.update(chunk)
            dst.sendall(chunk)
            moved += len(chunk)
            now = time.monotonic()
            if now - last >= PROGRESS_EVERY:
                say(f"PROGRESS {moved}")
                last = now
        dst.shutdown(socket.SHUT_WR)
    except OSError as e:
        raise Fail(f"relay broke after {moved} bytes: {e.strerror or e}")
    finally:
        src.close()
        dst.close()
    say(f"OK SHA256={digest.hexdigest()} BYTES={moved}")


def main():
    p = argparse.ArgumentParser(prog="hydrix-xfer")
    p.add_argument("--state", default="")
    sub = p.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("send")
    s.add_argument("--root", required=True)
    s.add_argument("--path-b64", required=True)
    s.add_argument("--recipient", required=True)
    s.add_argument("--listen", type=int, required=True)
    s.add_argument("--allow", required=True)

    r = sub.add_parser("recv")
    r.add_argument("--root", required=True)
    r.add_argument("--id", required=True)
    r.add_argument("--name-b64", required=True)
    r.add_argument("--dest-b64", required=True)
    r.add_argument("--listen", type=int, required=True)
    r.add_argument("--allow", required=True)

    c = sub.add_parser("commit")
    c.add_argument("--root", required=True)
    c.add_argument("--id", required=True)
    c.add_argument("--sha256", required=True)

    x = sub.add_parser("abort")
    x.add_argument("--root", required=True)

    y = sub.add_parser("relay")
    y.add_argument("--src", required=True)
    y.add_argument("--dst", required=True)

    a = p.parse_args()
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    os.umask(0o022)
    long_running = a.cmd in ("send", "recv", "relay")
    if long_running:
        write_pid(a.state)
    try:
        {"send": cmd_send, "recv": cmd_recv, "commit": cmd_commit,
         "abort": cmd_abort, "relay": cmd_relay}[a.cmd](a)
    except Fail as e:
        say(f"ERROR: {e}")
        sys.exit(1)
    except socket.timeout:
        say(f"ERROR: no data for {IDLE_TIMEOUT}s")
        sys.exit(1)
    finally:
        reap(CHILDREN)
        if long_running:
            clear_pid(a.state)


if __name__ == "__main__":
    main()
