"""Hydrix vault backend (protocol v2), shared by the vault VM agent and the host backend.

One request per invocation, read from stdin: `VERB [arg ...]` on one line, every argument
base64-encoded. The reply is `OK` or `ERROR <message>`, followed by data lines in which every
free-text field is base64-encoded.

The master password lives in one tmpfs file only (`--session-file`: /run/vault-session in the
vault VM, $XDG_RUNTIME_DIR for the host backend), mode 0600. It reaches keepassxc-cli on stdin,
never on a command line, and is never logged or echoed. LOCK and an idle timeout delete it.
"""

import argparse
import base64
import os
import re
import subprocess
import sys
import time
import xml.etree.ElementTree as ET

KPCLI = "@keepassxc_cli@"
MAX_REQUEST = 65536
FIELDS = {"title": "Title", "username": "UserName", "password": "Password", "url": "URL", "notes": "Notes"}


class Fail(Exception):
    pass


def b64e(text):
    return base64.b64encode(text.encode()).decode()


def b64d(text):
    try:
        return base64.b64decode(text, validate=True).decode()
    except (ValueError, UnicodeDecodeError):
        raise Fail("malformed argument")


def clean(text, limit=200):
    """Make keepassxc-cli messages safe to send back: printable, one line, short."""
    text = re.sub(r"[\x00-\x1f\x7f]+", " ", text).strip()
    return text[:limit] or "failed"


def check_path(path):
    if not path or len(path) > 512 or path.startswith("/") or path.endswith("/"):
        raise Fail("invalid entry path")
    if re.search(r"[\x00-\x1f\x7f]", path) or ".." in path.split("/"):
        raise Fail("invalid entry path")
    return path


def check_line(value, what, limit=4096):
    if len(value) > limit or re.search(r"[\x00-\x1f\x7f]", value):
        raise Fail(f"invalid {what}")
    return value


# --- session stores ----------------------------------------------------------------------


class FileSession:
    """Master password in a tmpfs file. Idle timeout via the file's mtime."""

    def __init__(self, path, timeout):
        self.path, self.timeout = path, timeout

    def get(self):
        try:
            st = os.stat(self.path)
        except FileNotFoundError:
            return None
        if time.time() - st.st_mtime > self.timeout:
            self.clear()
            return None
        with open(self.path) as f:
            return f.read()

    def put(self, password):
        os.makedirs(os.path.dirname(self.path), mode=0o700, exist_ok=True)
        fd = os.open(self.path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            f.write(password)

    def touch(self):
        os.utime(self.path)

    def clear(self):
        try:
            os.unlink(self.path)
        except FileNotFoundError:
            pass


# --- keepassxc-cli -----------------------------------------------------------------------


class Vault:
    def __init__(self, db, session):
        self.db, self.session = db, session

    def run(self, args, password, extra=(), check=True):
        """keepassxc-cli with the master password (and any extra secrets) on stdin."""
        stdin = "\n".join([password, *extra]) + "\n"
        res = subprocess.run([KPCLI, args[0], "-q", *args[1:]], input=stdin,
                             capture_output=True, text=True, timeout=60)
        if check and res.returncode != 0:
            raise Fail(clean(res.stderr.splitlines()[0] if res.stderr else "keepassxc-cli failed"))
        return res

    def unlocked(self):
        password = self.session.get()
        if password is None:
            raise Fail("vault is locked")
        self.session.touch()
        return password

    def entries(self, password):
        """(path, title, username, url) for every entry outside the recycle bin."""
        xml = self.run(["export", "-f", "xml", self.db], password).stdout
        root = ET.fromstring(xml)
        recycle = (root.findtext("Meta/RecycleBinUUID") or "").strip()
        out = []

        def walk(group, prefix):
            if recycle and (group.findtext("UUID") or "").strip() == recycle:
                return
            for entry in group.findall("Entry"):
                fields = {s.findtext("Key"): s.findtext("Value") or "" for s in entry.findall("String")}
                title = fields.get("Title", "")
                out.append((prefix + title, title, fields.get("UserName", ""), fields.get("URL", "")))
            for sub in group.findall("Group"):
                walk(sub, prefix + (sub.findtext("Name") or "") + "/")

        top = root.find("Root/Group")
        if top is not None:
            walk(top, "")
        return out

    def ensure_group(self, password, path):
        parts = path.split("/")[:-1]
        for i in range(1, len(parts) + 1):
            self.run(["mkdir", self.db, "/".join(parts[:i])], password, check=False)

    # verbs

    def STATUS(self):
        password = self.session.get()
        if password is None:
            return ["LOCKED"]
        return [f"UNLOCKED {len(self.entries(password))}"]

    def UNLOCK(self, password):
        if not os.path.exists(self.db):
            raise Fail("no database yet (use INIT)")
        if self.run(["ls", self.db], password, check=False).returncode != 0:
            raise Fail("wrong password")
        self.session.put(password)
        return []

    def INIT(self, password):
        if os.path.exists(self.db):
            raise Fail("database already exists")
        if len(password) < 8:
            raise Fail("master password too short")
        os.makedirs(os.path.dirname(self.db), exist_ok=True)
        res = subprocess.run([KPCLI, "db-create", "-q", "-p", self.db], input=f"{password}\n{password}\n",
                             capture_output=True, text=True, timeout=120)
        if res.returncode != 0:
            raise Fail(clean(res.stderr or "db-create failed"))
        self.session.put(password)
        return []

    def LOCK(self):
        self.session.clear()
        return []

    def LIST(self):
        password = self.unlocked()
        # "-" stands for an empty field (not a base64 character), so fields never collapse.
        return [" ".join(b64e(x) or "-" for x in row) for row in self.entries(password)]

    def GET(self, path, field):
        password = self.unlocked()
        check_path(path)
        if field == "totp":
            res = self.run(["show", "-t", self.db, path], password)
        elif field in FIELDS:
            res = self.run(["show", "-s", "-a", FIELDS[field], self.db, path], password)
        else:
            raise Fail("unknown field")
        value = res.stdout[:-1] if res.stdout.endswith("\n") else res.stdout
        return [b64e(value)]

    def ADD(self, path, username, url, notes, secret):
        password = self.unlocked()
        check_path(path)
        check_line(username, "username")
        check_line(url, "URL")
        if len(notes) > 65536:
            raise Fail("notes too long")
        generated = not secret
        if generated:
            secret = self.GEN("32")[0]
            secret = b64d(secret)
        check_line(secret, "password")
        self.ensure_group(password, path)
        args = ["add", "-p", "-u", username, "--url", url]
        if notes:
            args += ["--notes", notes]
        self.run(args + [self.db, path], password, extra=[secret])
        return [b64e(secret)] if generated else []

    def EDIT(self, path, field, value):
        password = self.unlocked()
        check_path(path)
        if field == "password":
            check_line(value, "password")
            self.run(["edit", "-p", self.db, path], password, extra=[value])
        elif field in ("username", "url", "title"):
            check_line(value, field)
            if field == "title" and ("/" in value or not value):
                raise Fail("invalid title (use MOVE for groups)")
            flag = {"username": "-u", "url": "--url", "title": "-t"}[field]
            self.run(["edit", flag, value, self.db, path], password)
        elif field == "notes":
            if len(value) > 65536:
                raise Fail("notes too long")
            self.run(["edit", "--notes", value, self.db, path], password)
        else:
            raise Fail("unknown field")
        return []

    def MOVE(self, path, newpath):
        password = self.unlocked()
        check_path(path)
        check_path(newpath)
        old_group, _, _ = path.rpartition("/")
        new_group, _, new_title = newpath.rpartition("/")
        current = path
        if new_group != old_group:
            self.ensure_group(password, newpath)
            self.run(["mv", self.db, path, new_group or "/"], password)
            current = (new_group + "/" if new_group else "") + path.rpartition("/")[2]
        if current != newpath:
            self.run(["edit", "-t", new_title, self.db, current], password)
        return []

    def RM(self, path):
        password = self.unlocked()
        check_path(path)
        self.run(["rm", self.db, path], password)
        return []

    def GEN(self, length="32"):
        if not re.fullmatch(r"[0-9]{1,3}", length) or not 8 <= int(length) <= 128:
            raise Fail("length must be 8-128")
        res = subprocess.run([KPCLI, "generate", "-q", "-L", length, "-l", "-U", "-n", "-s"],
                             capture_output=True, text=True, timeout=30)
        if res.returncode != 0:
            raise Fail("generate failed")
        return [b64e(res.stdout.strip())]

    def MERGE(self, name):
        password = self.unlocked()
        if not re.fullmatch(r"\.?[A-Za-z0-9_-]+\.kdbx", name):
            raise Fail("invalid merge file name")
        other = os.path.join(os.path.dirname(self.db), name)
        if not os.path.isfile(other) or os.path.islink(other):
            raise Fail("merge file not found")
        res = self.run(["merge", "-s", self.db, other], password)
        return [b64e(clean(res.stdout or "merged", 2000))]


VERBS = {
    "PING": (0, False), "STATUS": (0, False), "UNLOCK": (1, True), "INIT": (1, True), "LOCK": (0, False),
    "LIST": (0, False), "GET": (2, True), "ADD": (5, True), "EDIT": (3, True), "MOVE": (2, True),
    "RM": (1, True), "GEN": (1, True), "MERGE": (1, True),
}


def handle(vault, line):
    # Only the line ending is stripped: an empty argument encodes as an empty field.
    parts = line.rstrip("\r\n").split(" ")
    verb, raw = parts[0], parts[1:]
    if verb not in VERBS:
        raise Fail("unknown command")
    nargs, _ = VERBS[verb]
    if verb == "GEN" and not raw:
        raw = [b64e("32")]
    if len(raw) != nargs:
        raise Fail(f"{verb} takes {nargs} arguments")
    args = [b64d(a) for a in raw]
    if verb == "PING":
        return ["PONG"]
    return getattr(vault, verb)(*args)


def main():
    ap = argparse.ArgumentParser(description="Hydrix vault backend (one request on stdin)")
    ap.add_argument("--db", required=True)
    ap.add_argument("--timeout", type=int, default=300)
    ap.add_argument("--session-file", required=True)
    ap.add_argument("--expire", action="store_true", help="only drop an idle session, then exit")
    opts = ap.parse_args()

    try:
        session = FileSession(opts.session_file, opts.timeout)
        if opts.expire:
            session.get()
            return
        line = sys.stdin.readline(MAX_REQUEST)
        out = handle(Vault(opts.db, session), line)
        sys.stdout.write("\n".join(["OK", *out]) + "\n")
    except Fail as e:
        sys.stdout.write(f"ERROR {e}\n")
    except subprocess.TimeoutExpired:
        sys.stdout.write("ERROR keepassxc-cli timed out\n")
    except ET.ParseError:
        sys.stdout.write("ERROR could not read the database export\n")


if __name__ == "__main__":
    main()
