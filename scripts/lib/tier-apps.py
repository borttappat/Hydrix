"""List a tier VM's GUI apps from its tier store, for the host launcher.

Usage: tier-apps.py <tier root> <tier system path> <username>

The tier store is written by a tier builder, so it is untrusted. Every symlink is
resolved inside <tier root> and must stay under /nix/store there; names lose control
and format characters and are capped; commands must be plain program names. Prints
"name<TAB>command" lines, sorted, as the launcher's list_vm_apps does for host-store VMs:
.desktop entries with NoDisplay, Hidden or Terminal set to true are skipped.
"""

import os
import re
import sys
import unicodedata

STORE = "/nix/store"
MAX_FILES = 4000
MAX_BYTES = 64 * 1024
CMD = re.compile(r"^[A-Za-z0-9._+-]{1,64}$")

root, tier_system, user = sys.argv[1], sys.argv[2], sys.argv[3]


def resolve(path):
    """Resolve an absolute in-store path inside root; None if it leaves /nix/store."""
    parts = [p for p in path.split("/") if p]
    cur = []
    hops = 0
    while parts:
        part = parts.pop(0)
        if part == ".":
            continue
        if part == "..":
            if cur:
                cur.pop()
            continue
        cur.append(part)
        inner = "/" + "/".join(cur)
        if not (inner + "/").startswith(STORE + "/") and inner not in ("/nix", STORE):
            return None
        host = root + inner
        if os.path.islink(host):
            hops += 1
            if hops > 40:
                return None
            target = os.readlink(host)
            cur.pop()
            if target.startswith("/"):
                cur = []
            parts = [p for p in target.split("/") if p] + parts
    inner = "/" + "/".join(cur)
    return inner if (inner + "/").startswith(STORE + "/") else None


def clean(s):
    return "".join(c for c in s if unicodedata.category(c) not in ("Cc", "Cf")).strip()[:100]


def entries(directory):
    inner = resolve(directory)
    if inner is None or not os.path.isdir(root + inner):
        return
    for name in sorted(os.listdir(root + inner))[:MAX_FILES]:
        if name.endswith(".desktop"):
            f = resolve(inner + "/" + name)
            if f and os.path.isfile(root + f):
                yield root + f


apps = {}
for d in (
    f"{tier_system}/system/etc/profiles/per-user/{user}/share/applications",
    f"{tier_system}/system/sw/share/applications",
):
    for path in entries(d):
        with open(path, "rb") as fh:
            text = fh.read(MAX_BYTES).decode("utf-8", "replace")
        if re.search(r"^(NoDisplay|Hidden|Terminal)=true", text, re.M):
            continue
        name = re.search(r"^Name=(.*)$", text, re.M)
        exe = re.search(r"^Exec=(.*)$", text, re.M)
        if not (name and exe):
            continue
        first = exe.group(1).split()
        cmd = first[0].rsplit("/", 1)[-1] if first else ""
        name = clean(name.group(1))
        if name and CMD.match(cmd):
            apps.setdefault(name, cmd)

for name in sorted(apps):
    print(f"{name}\t{apps[name]}")
