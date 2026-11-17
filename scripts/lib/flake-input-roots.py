"""GC roots for the flake inputs a host has fetched.

A lockdown host evaluates offline, so a garbage collection must not take an input source
it cannot download again. Rooting every input in flake.lock would force fetching inputs
evaluation never touches (a git input only one option uses, a test-only dependency), so
this roots only those already in the store: each locked input's store path follows from
its narHash (fixed-output, recursive sha256, name "source").

usage: flake-input-roots.py <nix bin dir> <flake.lock> <roots dir>

The roots directory then holds exactly one link per fetched input of this lock file;
links for inputs the lock no longer has are removed, so their old sources become
collectable after an update.
"""
import json
import os
import re
import subprocess
import sys

NAME = re.compile(r"^[A-Za-z0-9_.-]+$")
SRI = re.compile(r"^sha256-[A-Za-z0-9+/]{43}=$")
STORE_PATH = re.compile(r"^/nix/store/[0-9a-z]{32}-source$")


def run(nix_bin, *args):
    out = subprocess.run([os.path.join(nix_bin, args[0]), *args[1:]],
                         check=True, capture_output=True, text=True).stdout
    return out.split()


def main():
    nix_bin, lock_file, roots = sys.argv[1:4]
    with open(lock_file) as f:
        lock = json.load(f)
    root = lock.get("root")
    wanted = {}
    for name, node in lock.get("nodes", {}).items():
        nar = (node.get("locked") or {}).get("narHash")
        if name == root or not nar or not NAME.match(name) or not SRI.match(nar):
            continue
        wanted[name] = nar

    paths = {}
    if wanted:
        names = list(wanted)
        hashes = run(nix_bin, "nix", "--extra-experimental-features", "nix-command",
                     "hash", "convert", "--hash-algo", "sha256", "--to", "nix32",
                     *[wanted[n] for n in names])
        for name, h in zip(names, hashes):
            path = run(nix_bin, "nix-store", "--print-fixed-path", "--recursive",
                       "sha256", h, "source")[0]
            if STORE_PATH.match(path) and os.path.isdir(path) and not os.path.islink(path):
                paths[name] = path

    os.makedirs(roots, mode=0o755, exist_ok=True)
    for entry in os.listdir(roots):
        link = os.path.join(roots, entry)
        if entry not in paths and os.path.islink(link):
            os.unlink(link)
    for name, path in paths.items():
        link = os.path.join(roots, name)
        if os.path.islink(link) and os.readlink(link) == path:
            continue
        tmp = link + ".tmp"
        if os.path.lexists(tmp):
            os.unlink(tmp)
        os.symlink(path, tmp)
        os.replace(tmp, link)
    print(f"{len(paths)} of {len(wanted)} flake inputs rooted (the rest are not fetched)")


if __name__ == "__main__":
    main()
