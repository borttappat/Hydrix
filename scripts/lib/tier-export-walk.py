"""Which host store paths a tier system can be given instead of built.

Reads `nix derivation show -r` JSON on stdin; argv[1] is the tier system's .drv.
Walks the graph from the top as substitution does: when every output a derivation is
needed for exists in the host store, those outputs are printed and the walk stops
there; otherwise it continues into the derivation's inputs.
"""

import json
import os
import sys


def base(path):
    return path.rsplit("/", 1)[-1]


data = json.load(sys.stdin)
drvs = {base(k): v for k, v in data.get("derivations", data).items()}
root = base(sys.argv[1])

need = {root: set(drvs[root]["outputs"])}
work = [root]
found = set()

while work:
    name = work.pop()
    drv = drvs[name]
    outs = [drv["outputs"][o].get("path") for o in need[name]]
    if all(p and os.path.exists("/nix/store/" + base(p)) for p in outs):
        found.update("/nix/store/" + base(p) for p in outs)
        continue
    inputs = drv.get("inputs", {}).get("drvs") or drv.get("inputDrvs", {})
    for dep, spec in inputs.items():
        dep = base(dep)
        wanted = set(spec.get("outputs", []) if isinstance(spec, dict) else spec)
        have = need.setdefault(dep, set())
        if not wanted <= have:
            have |= wanted
            work.append(dep)

print("\n".join(sorted(found)))
