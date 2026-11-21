"""GC roots for the flake inputs a host has fetched.

A lockdown host evaluates offline, so a garbage collection must not take an input source
it cannot download again. Rooting every input in flake.lock would force fetching inputs
evaluation never touches (a git input only one option uses, a test-only dependency), so
this roots only those already in the store: each locked input's store path follows from
its narHash (fixed-output, recursive sha256, name "source").

usage: flake-input-roots.py <nix bin dir> <flake.lock> <roots dir>
       flake-input-roots.py --list-fetch <nix bin dir> <flake.lock>

--list-fetch prints, one per line, the profile pins a lockdown host cannot evaluate yet: their
source is not in the store, or (a pinned flake) one of its own locked inputs is not.
"flake=<ref>" is a pinned flake (fetched with every input of its lock), "tree=<ref>" any other
source. Only github sources with a full rev are listed (the builder fetches nothing else);
others go to stderr as a warning. shard builder update hands the list to the builder (FETCH).

The roots directory then holds exactly one link per fetched input of this lock file;
links for inputs the lock no longer has are removed, so their old sources become
collectable after an update.

The same goes for sources a profile fetches during evaluation, pinned by narHash in its
own files (profiles/<profile>/**/*.nix, next to flake.lock): no lock file of this flake lists
them, and evaluating that profile offline needs them as much as an input. Two forms:
builtins.fetchTree { ... narHash = "..."; } (vm-sync packages), rooted as
pin-<profile>-<file>-<n>, and builtins.getFlake "<ref>?narHash=..." (a flake only that
profile uses, so other users of the config never fetch it), rooted with the inputs of its
own flake.lock as pin-<profile>-<file>-<n>[-<input>].
"""
import glob
import json
import os
import re
import subprocess
import sys
import urllib.parse

NAME = re.compile(r"^[A-Za-z0-9_.-]+$")
SRI = re.compile(r"^sha256-[A-Za-z0-9+/]{43}=$")
STORE_PATH = re.compile(r"^/nix/store/[0-9a-z]{32}-source$")
FETCH_TREE = re.compile(r"builtins\.fetchTree\s*\{(.*?)\}", re.S)
NAR_HASH = re.compile(r'narHash\s*=\s*"([^"]+)"')
GET_FLAKE = re.compile(r'builtins\.getFlake\s+"([^"]+)"')


GITHUB_REF = re.compile(r"^github:[A-Za-z0-9._-]+/[A-Za-z0-9._-]+/[0-9a-f]{40}$")
ATTR = re.compile(r'(\w+)\s*=\s*"([^"]*)"\s*;')


def fetch_ref(body, nar, is_flake):
    """A github flake reference the builder can fetch with this narHash, or None."""
    if is_flake:
        base = urllib.parse.urlsplit(body)
        base = f"{base.scheme}:{base.path}" if base.scheme else ""
    else:
        attrs = dict(ATTR.findall(body))
        base = ""
        if attrs.get("type") == "github" and attrs.get("owner") and attrs.get("repo"):
            base = f"github:{attrs['owner']}/{attrs['repo']}/{attrs.get('rev', '')}"
    if not GITHUB_REF.match(base):
        return None
    return f"{base}?narHash={urllib.parse.quote(nar, safe='')}"


def profile_pins(flake_dir):
    """(name, narHash, is_flake, ref) for every source a profile file pins by narHash."""
    pins = []
    for path in sorted(glob.glob(os.path.join(flake_dir, "profiles/*/**/*.nix"), recursive=True)):
        rel = os.path.relpath(path, os.path.join(flake_dir, "profiles"))
        profile = rel.split(os.sep, 1)[0]
        stem = os.path.splitext(os.path.basename(path))[0]
        try:
            with open(path) as f:
                text = f.read()
        except OSError:
            continue
        found = [(m.start(), m.group(1), False) for m in FETCH_TREE.finditer(text)]
        found += [(m.start(), m.group(1), True) for m in GET_FLAKE.finditer(text)]
        for n, (_, body, is_flake) in enumerate(sorted(found)):
            if is_flake:
                query = urllib.parse.parse_qs(urllib.parse.urlsplit(body).query)
                nar = (query.get("narHash") or [""])[0]
            else:
                m = NAR_HASH.search(body)
                nar = m.group(1) if m else ""
            name = f"pin-{profile}-{stem}-{n}"
            if SRI.match(nar) and NAME.match(name):
                pins.append((name, nar, is_flake, fetch_ref(body, nar, is_flake)))
    return pins


def store_paths(nix_bin, wanted):
    """name -> store path, for the narHashes already fetched into the store."""
    paths = {}
    if not wanted:
        return paths
    names = list(wanted)
    hashes = run(nix_bin, "nix", "--extra-experimental-features", "nix-command",
                 "hash", "convert", "--hash-algo", "sha256", "--to", "nix32",
                 *[wanted[n] for n in names])
    for name, h in zip(names, hashes):
        path = run(nix_bin, "nix-store", "--print-fixed-path", "--recursive",
                   "sha256", h, "source")[0]
        if STORE_PATH.match(path) and os.path.isdir(path) and not os.path.islink(path):
            paths[name] = path
    return paths


def lock_hashes(lock_file):
    """input name -> narHash of every locked input in a flake.lock."""
    with open(lock_file) as f:
        lock = json.load(f)
    root = lock.get("root")
    out = {}
    for name, node in lock.get("nodes", {}).items():
        nar = (node.get("locked") or {}).get("narHash")
        if name != root and nar and NAME.match(name) and SRI.match(nar):
            out[name] = nar
    return out


def run(nix_bin, *args):
    out = subprocess.run([os.path.join(nix_bin, args[0]), *args[1:]],
                         check=True, capture_output=True, text=True).stdout
    return out.split()


def nested_inputs(pins, paths):
    """name-input -> narHash for every input locked by a pinned flake already in the store."""
    nested = {}
    for name, _, is_flake, _ in pins:
        sub_lock = os.path.join(paths.get(name, ""), "flake.lock")
        if is_flake and name in paths and os.path.isfile(sub_lock) and not os.path.islink(sub_lock):
            nested.update({f"{name}-{i}": nar for i, nar in lock_hashes(sub_lock).items()})
    return nested


def list_fetch(nix_bin, lock_file):
    pins = profile_pins(os.path.dirname(os.path.abspath(lock_file)))
    paths = store_paths(nix_bin, {name: nar for name, nar, _, _ in pins})
    nested = nested_inputs(pins, paths)
    have = store_paths(nix_bin, nested)
    listed = set()
    for name, _, is_flake, ref in pins:
        missing = name not in paths or (
            is_flake and any(k.startswith(name + "-") and k not in have for k in nested))
        if not missing:
            continue
        if ref is None:
            print(f"{name}: not a github source with a full rev, fetch it by hand", file=sys.stderr)
            continue
        line = f"{'flake' if is_flake else 'tree'}={ref}"
        if line not in listed:
            listed.add(line)
            print(line)


def main():
    if sys.argv[1:2] == ["--list-fetch"]:
        list_fetch(*sys.argv[2:4])
        return
    nix_bin, lock_file, roots = sys.argv[1:4]
    wanted = lock_hashes(lock_file)
    inputs = len(wanted)
    pins = profile_pins(os.path.dirname(os.path.abspath(lock_file)))
    wanted.update({name: nar for name, nar, _, _ in pins})
    paths = store_paths(nix_bin, wanted)

    # A pinned flake's own inputs: from its flake.lock, once its source is in the store.
    nested = nested_inputs(pins, paths)
    paths.update(store_paths(nix_bin, nested))
    pin_names = {name for name, _, _, _ in pins} | set(nested)

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
    rooted_pins = sum(1 for n in paths if n in pin_names)
    msg = f"{len(paths) - rooted_pins} of {inputs} flake inputs rooted (the rest are not fetched)"
    if pin_names:
        msg += f", {rooted_pins} of {len(pin_names)} profile pins"
    print(msg)


if __name__ == "__main__":
    main()
