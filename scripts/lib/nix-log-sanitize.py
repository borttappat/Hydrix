"""Make a builder VM's log stream safe to render on the host terminal.

Builder output is untrusted. Lines are `@nix {json}` (Nix internal-json, for nom) or
plain protocol lines (OK/DONE/ERROR). JSON escapes such as \\u001b would reach the
terminal decoded. Nix colours its own messages, so colour codes (SGR: ESC [ digits and
semicolons, then m) are kept; every other escape sequence is removed whole, then any
remaining control or format character (carriage returns, bidi overrides). Newlines and
tabs stay. Lines that do not parse are dropped. Writes one line per input line, flushed,
for live rendering. It must never exit early: a broken pipe here would cut the build's
connection, so any line it cannot handle is skipped.
"""

import io
import json
import re
import sys
import unicodedata

KEEP = {"\n", "\t"}
SGR = re.compile(r"(\x1b\[[0-9;]{0,32}m)")
# CSI, OSC (BEL or ST terminated), DCS/SOS/PM/APC (ST terminated), or ESC plus one char.
ESCAPE = re.compile(
    r"\x1b(?:\[[0-?]*[ -/]*[@-~]|\][^\x07\x1b]*(?:\x07|\x1b\\)|[PX^_][^\x1b]*\x1b\\|.?)", re.S
)


def strip(s):
    s = ESCAPE.sub("", s)
    return "".join(c for c in s if c in KEEP or unicodedata.category(c) not in ("Cc", "Cf", "Cs"))


def clean(s):
    return "".join(p if SGR.fullmatch(p) else strip(p) for p in SGR.split(s))


def walk(v):
    if isinstance(v, str):
        return clean(v)
    if isinstance(v, list):
        return [walk(x) for x in v]
    if isinstance(v, dict):
        return {clean(k): walk(x) for k, x in v.items()}
    return v


out = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")
for raw in iter(sys.stdin.buffer.readline, b""):
    try:
        line = raw.decode("utf-8", "replace").rstrip("\r\n")
        if line.startswith("@nix "):
            line = "@nix " + json.dumps(walk(json.loads(line[5:])), ensure_ascii=False)
        else:
            line = clean(line)
        out.write(line + "\n")
        out.flush()
    except BrokenPipeError:
        break
    except Exception:
        continue
