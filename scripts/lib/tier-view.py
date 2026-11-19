"""Keep a tier VM's store view: the VM sees only its own closure, not the whole tier store.

Usage (as root): tier-view.py <tier root> <view store dir> <closure dir> add|exact
                 tier-view.py --copy <paths file> <view store dir> add|exact

<closure dir> is the system's closure-info in the tier store (in-store path, e.g.
/nix/store/...-closure-info). Its store-paths list, plus the closure-info itself (the
VM loads its registration at boot), make up the view. Each path is recreated in the view
with hard links to the tier store's files, so the view costs directory entries, not data.

add    adds missing paths only: a running VM keeps everything it booted with.
exact  also removes what the closure no longer needs; only while the VM is stopped.

The tier store is written by a tier builder, so it is untrusted: every entry must be a
plain store path name, nothing is looked up outside <tier root>/nix/store, symlinks are
recreated as symlinks and never followed, and anything but files, directories and
symlinks is skipped. A path appears in the view only once complete (built under a
temporary name, then renamed).

--copy builds a tier builder's view of its own closure in the host store: <paths file>
lists the store paths (nix-store -qR of its runner, from the host). The host /nix/store is
a separate mount, which hard links cannot cross, so files are copied: reflinked where the
filesystem can (btrfs), plain copies otherwise.
"""

import fcntl
import os
import re
import shutil
import stat
import sys

FICLONE = 0x40049409
COPY = False
NAME = re.compile(r"^[0-9a-z]{32}-[A-Za-z0-9+._?=-]+$")
STORE = "/nix/store/"


def die(msg):
    print(f"tier-view: {msg}", file=sys.stderr)
    sys.exit(1)


def name_of(path):
    path = path.strip()
    if not path.startswith(STORE):
        return None
    name = path[len(STORE):]
    return name if NAME.match(name) else None


def clone(src, dst, mode):
    """Copy a file, as a reflink when the filesystem shares extents."""
    with open(src, "rb") as fi, open(dst, "xb") as fo:
        try:
            fcntl.ioctl(fo.fileno(), FICLONE, fi.fileno())
        except OSError:
            shutil.copyfileobj(fi, fo, 1 << 20)
    os.chmod(dst, mode & 0o555)


def copy_tree(src, dst):
    """Recreate src at dst: directories, hard-linked files, symlinks; never follows links."""
    st = os.lstat(src)
    if stat.S_ISLNK(st.st_mode):
        os.symlink(os.readlink(src), dst)
    elif stat.S_ISREG(st.st_mode):
        if COPY:
            clone(src, dst, stat.S_IMODE(st.st_mode))
        else:
            os.link(src, dst, follow_symlinks=False)
    elif stat.S_ISDIR(st.st_mode):
        os.mkdir(dst, 0o700)
        for entry in os.listdir(src):
            copy_tree(os.path.join(src, entry), os.path.join(dst, entry))
        os.chmod(dst, stat.S_IMODE(st.st_mode) & 0o555)
    # Device nodes, FIFOs and sockets never belong in a store path: skipped.


def remove(path):
    """Remove a view entry; store directories are read-only, so make them writable first."""
    if os.path.isdir(path) and not os.path.islink(path):
        for dirpath, dirnames, _ in os.walk(path):
            os.chmod(dirpath, 0o700)
        shutil.rmtree(path)
    else:
        os.unlink(path)


def main():
    global COPY
    usage = ("usage: tier-view.py <tier root> <view store dir> <closure dir> add|exact\n"
             "       tier-view.py --copy <paths file> <view store dir> add|exact")
    if len(sys.argv) == 5 and sys.argv[1] == "--copy" and sys.argv[4] in ("add", "exact"):
        COPY = True
        _, listing, view, mode = sys.argv[1:]
        src_store = STORE.rstrip("/")
        wanted = set()
    elif len(sys.argv) == 5 and sys.argv[4] in ("add", "exact"):
        root, view, closure, mode = sys.argv[1:]
        src_store = os.path.join(root, "nix/store")
        closure_name = name_of(closure)
        if closure_name is None or not closure_name.endswith("-closure-info"):
            die(f"not a closure-info path: {closure}")
        closure_dir = os.path.join(src_store, closure_name)
        listing = os.path.join(closure_dir, "store-paths")
        for p in (closure_dir, listing):
            if os.path.islink(p):
                die(f"refusing a symlink: {p}")
        wanted = {closure_name}
    else:
        die(usage)
    with open(listing, "rb") as fh:
        lines = fh.read().decode("utf-8", "replace").splitlines()

    for line in lines:
        if not line.strip():
            continue
        name = name_of(line)
        if name is None:
            die(f"not a store path in the closure list: {line[:120]!r}")
        wanted.add(name)

    os.makedirs(view, 0o755, exist_ok=True)
    present = set(os.listdir(view))
    added = removed = 0

    for entry in present:
        if entry.startswith(".tmp-"):
            remove(os.path.join(view, entry))
    for name in sorted(wanted - present):
        src = os.path.join(src_store, name)
        if not os.path.lexists(src):
            die(f"missing from {src_store}: {name}")
        tmp = os.path.join(view, f".tmp-{name}")
        copy_tree(src, tmp)
        os.rename(tmp, os.path.join(view, name))
        added += 1
    if mode == "exact":
        for name in sorted(present - wanted):
            if name.startswith(".tmp-"):
                continue
            remove(os.path.join(view, name))
            removed += 1

    print(f"{len(wanted)} paths in the view ({added} added, {removed} removed)")


main()
