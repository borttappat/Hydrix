"""vm-dev fix: build a per-package flake, diagnose the failure, edit flake.nix, repeat.

Each round builds with full logs, turns recognised errors into issues, resolves
every issue to a concrete flake.nix edit and applies them. Dependency issues
carry a ranked candidate list (curated map, then nix-locate, then name probes),
filtered to attributes that exist in the package's own pinned nixpkgs. When the
same issue comes back after a candidate was added, that candidate is removed
again and the next one is tried.
"""

import argparse
import difflib
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

PLACEHOLDER = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

# ── Curated maps: file/name -> nixpkgs attrs (relative to pkgs) ──────────────

HEADERS = {
    "ncurses.h": ["ncurses"], "curses.h": ["ncurses"], "panel.h": ["ncurses"],
    "menu.h": ["ncurses"], "form.h": ["ncurses"], "term.h": ["ncurses"],
    "ncursesw/": ["ncurses"], "openssl/": ["openssl"], "zlib.h": ["zlib"],
    "curl/": ["curl"], "sqlite3.h": ["sqlite"], "readline/": ["readline"],
    "png.h": ["libpng"], "jpeglib.h": ["libjpeg"], "turbojpeg.h": ["libjpeg_turbo"],
    "tiffio.h": ["libtiff"], "gif_lib.h": ["giflib"], "webp/": ["libwebp"],
    "X11/": ["libx11", "xorg.libX11"], "xcb/": ["libxcb", "xorg.libxcb"],
    "xkbcommon/": ["libxkbcommon"], "wayland-client.h": ["wayland"],
    "SDL.h": ["SDL2"], "SDL2/": ["SDL2"], "SDL3/": ["sdl3"], "raylib.h": ["raylib"],
    "GL/gl.h": ["libGL"], "GL/glu.h": ["libGLU"], "GL/glew.h": ["glew"],
    "GLFW/": ["glfw"], "EGL/": ["libGL"], "vulkan/": ["vulkan-headers", "vulkan-loader"],
    "pcre.h": ["pcre"], "pcre2.h": ["pcre2"], "uuid/": ["libuuid"],
    "libusb.h": ["libusb1"], "libusb-1.0/": ["libusb1"], "json-c/": ["json_c"],
    "jansson.h": ["jansson"], "cjson/": ["cjson"], "yaml.h": ["libyaml"],
    "expat.h": ["expat"], "lzma.h": ["xz"], "zstd.h": ["zstd"], "lz4.h": ["lz4"],
    "bzlib.h": ["bzip2"], "archive.h": ["libarchive"], "gmp.h": ["gmp"],
    "mpfr.h": ["mpfr"], "ffi.h": ["libffi"], "event2/": ["libevent"], "ev.h": ["libev"],
    "uv.h": ["libuv"], "magic.h": ["file"], "pcap.h": ["libpcap"], "pcap/": ["libpcap"],
    "glib.h": ["glib"], "gtk/": ["gtk3", "gtk4"], "cairo.h": ["cairo"],
    "ft2build.h": ["freetype"], "fontconfig/": ["fontconfig"], "alsa/": ["alsa-lib"],
    "pulse/": ["libpulseaudio"], "pipewire/": ["pipewire"], "sys/capability.h": ["libcap"],
    "dbus/": ["dbus"], "systemd/": ["systemd"], "libudev.h": ["systemd"],
    "security/pam_appl.h": ["linux-pam", "pam"], "gcrypt.h": ["libgcrypt"],
    "gpg-error.h": ["libgpg-error"], "sodium.h": ["libsodium"], "lua.h": ["lua"],
    "Python.h": ["python3"], "libxml/": ["libxml2"], "libxslt/": ["libxslt"],
    "ldap.h": ["openldap"], "krb5.h": ["krb5"], "libssh/": ["libssh"],
    "libssh2.h": ["libssh2"], "git2.h": ["libgit2"], "fftw3.h": ["fftw"],
    "boost/": ["boost"], "Eigen/": ["eigen"], "fmt/": ["fmt"], "spdlog/": ["spdlog"],
    "nlohmann/": ["nlohmann_json"], "gtest/": ["gtest"], "sndfile.h": ["libsndfile"],
    "portaudio.h": ["portaudio"], "opus/": ["libopus"], "vorbis/": ["libvorbis"],
    "ogg/": ["libogg"], "FLAC/": ["flac"], "libavcodec/": ["ffmpeg"],
    "libavformat/": ["ffmpeg"], "libavutil/": ["ffmpeg"], "hidapi/": ["hidapi"],
    "libevdev/": ["libevdev"], "libinput.h": ["libinput"], "pci/": ["pciutils"],
    "sensors/": ["lm_sensors"], "bpf/": ["libbpf"], "libelf.h": ["elfutils"],
    "gelf.h": ["elfutils"], "capstone/": ["capstone"], "unicorn/": ["unicorn"],
    "yara.h": ["yara"], "maxminddb.h": ["libmaxminddb"], "seccomp.h": ["libseccomp"],
    "libmnl/": ["libmnl"], "libnftnl/": ["libnftnl"], "libnet.h": ["libnet"],
    "netlink/": ["libnl"], "libnotify/": ["libnotify"], "argp.h": ["argp-standalone"],
}

LIBS = {
    "ncurses": ["ncurses"], "ncursesw": ["ncurses"], "tinfo": ["ncurses"],
    "curses": ["ncurses"], "panel": ["ncurses"], "panelw": ["ncurses"],
    "menu": ["ncurses"], "menuw": ["ncurses"], "form": ["ncurses"], "formw": ["ncurses"],
    "ssl": ["openssl"], "crypto": ["openssl"], "z": ["zlib"], "curl": ["curl"],
    "sqlite3": ["sqlite"], "readline": ["readline"], "png": ["libpng"],
    "jpeg": ["libjpeg"], "X11": ["libx11", "xorg.libX11"], "GL": ["libGL"],
    "GLU": ["libGLU"], "GLEW": ["glew"], "glfw": ["glfw"], "SDL2": ["SDL2"],
    "SDL2_image": ["SDL2_image"], "SDL2_ttf": ["SDL2_ttf"], "SDL2_mixer": ["SDL2_mixer"],
    "raylib": ["raylib"], "lua": ["lua"], "pcap": ["libpcap"], "magic": ["file"],
    "cap": ["libcap"], "udev": ["systemd"], "asound": ["alsa-lib"],
    "pulse": ["libpulseaudio"], "sodium": ["libsodium"], "uv": ["libuv"],
    "event": ["libevent"], "bz2": ["bzip2"], "lzma": ["xz"], "zstd": ["zstd"],
    "archive": ["libarchive"], "ffi": ["libffi"], "gmp": ["gmp"], "pcre": ["pcre"],
    "pcre2-8": ["pcre2"], "uuid": ["libuuid"], "usb-1.0": ["libusb1"],
    "json-c": ["json_c"], "yaml": ["libyaml"], "expat": ["expat"], "xml2": ["libxml2"],
    "elf": ["elfutils"], "bpf": ["libbpf"], "seccomp": ["libseccomp"],
    "gcrypt": ["libgcrypt"], "gpg-error": ["libgpg-error"], "crypt": ["libxcrypt"],
    "argp": ["argp-standalone"],
}
# Part of glibc or the compiler: a missing one means static linking, not a missing package.
LIBC_LIBS = {"m", "c", "pthread", "dl", "rt", "util", "resolv", "stdc++", "gcc", "gcc_s"}

PKGCONFIG = {
    "openssl": ["openssl"], "libssl": ["openssl"], "libcrypto": ["openssl"],
    "zlib": ["zlib"], "libcurl": ["curl"], "sqlite3": ["sqlite"],
    "ncurses": ["ncurses"], "ncursesw": ["ncurses"], "tinfo": ["ncurses"],
    "panel": ["ncurses"], "menu": ["ncurses"], "form": ["ncurses"],
    "gtk+-3.0": ["gtk3"], "gtk4": ["gtk4"], "glib-2.0": ["glib"],
    "gobject-2.0": ["glib"], "gio-2.0": ["glib"], "x11": ["libx11", "xorg.libX11"],
    "xcb": ["libxcb", "xorg.libxcb"], "xkbcommon": ["libxkbcommon"],
    "wayland-client": ["wayland"], "wayland-server": ["wayland"],
    "wayland-cursor": ["wayland"], "wayland-egl": ["wayland"],
    "wayland-protocols": ["wayland-protocols"], "wayland-scanner": ["wayland-scanner"],
    "dbus-1": ["dbus"], "libudev": ["systemd"], "libsystemd": ["systemd"],
    "alsa": ["alsa-lib"], "libpulse": ["libpulseaudio"], "libpipewire-0.3": ["pipewire"],
    "fontconfig": ["fontconfig"], "freetype2": ["freetype"], "cairo": ["cairo"],
    "pango": ["pango"], "gdk-pixbuf-2.0": ["gdk-pixbuf"], "libpng": ["libpng"],
    "libjpeg": ["libjpeg"], "sdl2": ["SDL2"], "libusb-1.0": ["libusb1"],
    "libssh2": ["libssh2"], "libgit2": ["libgit2"], "libzstd": ["zstd"],
    "liblzma": ["xz"], "libffi": ["libffi"], "libxml-2.0": ["libxml2"],
    "egl": ["libGL"], "gl": ["libGL"], "glesv2": ["libGL"], "vulkan": ["vulkan-loader"],
    "libsodium": ["libsodium"], "libseccomp": ["libseccomp"], "libcap": ["libcap"],
    "libpcap": ["libpcap"], "libnl-3.0": ["libnl"], "oniguruma": ["oniguruma"],
    "libevdev": ["libevdev"], "libinput": ["libinput"], "libdrm": ["libdrm"],
    "gbm": ["libgbm", "mesa"], "libavcodec": ["ffmpeg"], "libavformat": ["ffmpeg"],
    "libavutil": ["ffmpeg"], "libswscale": ["ffmpeg"], "mpv": ["mpv"],
    "libnotify": ["libnotify"], "libsecret-1": ["libsecret"],
    "webkit2gtk-4.1": ["webkitgtk_4_1"], "libsoup-3.0": ["libsoup_3"],
    "json-glib-1.0": ["json-glib"], "uuid": ["libuuid"], "blkid": ["util-linux"],
    "mount": ["util-linux"], "libarchive": ["libarchive"], "expat": ["expat"],
    "libelf": ["elfutils"], "libbpf": ["libbpf"],
}

TOOLS = {
    "pkg-config": ["pkg-config"], "pkgconf": ["pkg-config"], "cmake": ["cmake"],
    "ninja": ["ninja"], "meson": ["meson"], "autoreconf": ["autoreconfHook"],
    "autoconf": ["autoreconfHook"], "automake": ["autoreconfHook"],
    "aclocal": ["autoreconfHook"], "libtoolize": ["autoreconfHook"],
    "python": ["python3"], "python3": ["python3"], "perl": ["perl"],
    "bison": ["bison"], "yacc": ["bison"], "flex": ["flex"], "lex": ["flex"],
    "makeinfo": ["texinfo"], "git": ["git"], "msgfmt": ["gettext"],
    "xgettext": ["gettext"], "xxd": ["xxd", "unixtools.xxd"], "scdoc": ["scdoc"],
    "asciidoc": ["asciidoc"], "a2x": ["asciidoc"], "asciidoctor": ["asciidoctor"],
    "pandoc": ["pandoc"], "help2man": ["help2man"], "cargo": ["cargo"],
    "rustc": ["rustc"], "go": ["go"], "nasm": ["nasm"], "yasm": ["yasm"],
    "gperf": ["gperf"], "wayland-scanner": ["wayland-scanner"],
    "glib-compile-resources": ["glib"], "glib-compile-schemas": ["glib"],
    "desktop-file-validate": ["desktop-file-utils"], "protoc": ["protobuf"],
    "zip": ["zip"], "unzip": ["unzip"], "which": ["which"], "file": ["file"],
    "m4": ["m4"], "bc": ["bc"], "sassc": ["sassc"], "doxygen": ["doxygen"],
    "scons": ["scons"], "gn": ["gn"], "ld.lld": ["lld"], "clang": ["clang"],
    "zig": ["zig"], "nim": ["nim"], "ruby": ["ruby"], "node": ["nodejs"],
    "npm": ["nodejs"], "java": ["jdk"], "javac": ["jdk"], "mvn": ["maven"],
    "gradle": ["gradle"], "lua": ["lua"], "luajit": ["luajit"], "installShellCompletion": ["installShellFiles"],
}
# Always present in stdenv, or not something a dependency can fix.
TOOL_SKIP = {"make", "gcc", "cc", "g++", "c++", "ld", "ar", "sh", "bash", "install",
             "cp", "mv", "rm", "mkdir", "sudo", "ldconfig", "true", "false", "test"}

CMAKE = {
    "OpenSSL": ["openssl"], "ZLIB": ["zlib"], "CURL": ["curl"], "Curses": ["ncurses"],
    "PNG": ["libpng"], "JPEG": ["libjpeg"], "X11": ["libx11", "xorg.libX11"],
    "Boost": ["boost"], "SQLite3": ["sqlite"], "LibXml2": ["libxml2"], "BZip2": ["bzip2"],
    "LibLZMA": ["xz"], "Freetype": ["freetype"], "Fontconfig": ["fontconfig"],
    "OpenGL": ["libGL"], "GLEW": ["glew"], "SDL2": ["SDL2"], "glfw3": ["glfw"],
    "Intl": ["gettext"], "Iconv": ["libiconv"], "LibArchive": ["libarchive"],
    "Readline": ["readline"], "GTest": ["gtest"], "fmt": ["fmt"], "spdlog": ["spdlog"],
    "nlohmann_json": ["nlohmann_json"], "Vulkan": ["vulkan-headers", "vulkan-loader"],
    "ALSA": ["alsa-lib"], "PCAP": ["libpcap"], "LibSSH": ["libssh"], "Libssh2": ["libssh2"],
    "zstd": ["zstd"], "PkgConfig": ["pkg-config"],
}
CMAKE_NATIVE = {"PkgConfig", "Doxygen", "Git", "BISON", "FLEX", "Gettext", "Python",
                "Python3", "PythonInterp", "Perl"}
CMAKE_NATIVE_ATTR = {"Doxygen": "doxygen", "Git": "git", "BISON": "bison", "FLEX": "flex",
                     "Gettext": "gettext", "Python": "python3", "Python3": "python3",
                     "PythonInterp": "python3", "Perl": "perl", "PkgConfig": "pkg-config"}
CMAKE_IGNORE = {"Threads"}

# Rust -sys crates: (buildInputs, nativeBuildInputs)
RUST_SYS = {
    "openssl-sys": (["openssl"], ["pkg-config"]),
    "libsqlite3-sys": (["sqlite"], ["pkg-config"]),
    "alsa-sys": (["alsa-lib"], ["pkg-config"]),
    "libudev-sys": (["systemd"], ["pkg-config"]),
    "libdbus-sys": (["dbus"], ["pkg-config"]),
    "servo-fontconfig-sys": (["fontconfig"], ["pkg-config"]),
    "yeslogic-fontconfig-sys": (["fontconfig"], ["pkg-config"]),
    "freetype-sys": (["freetype"], ["pkg-config"]),
    "x11": (["libx11"], ["pkg-config"]),
    "xcb": (["libxcb"], ["pkg-config", "python3"]),
    "libgit2-sys": (["libgit2"], ["pkg-config"]),
    "zstd-sys": (["zstd"], ["pkg-config"]),
    "bzip2-sys": (["bzip2"], ["pkg-config"]),
    "lzma-sys": (["xz"], ["pkg-config"]),
    "onig_sys": (["oniguruma"], ["pkg-config"]),
    "libz-sys": (["zlib"], ["pkg-config"]),
    "glib-sys": (["glib"], ["pkg-config"]),
    "gtk-sys": (["gtk3"], ["pkg-config"]),
    "gdk-sys": (["gtk3"], ["pkg-config"]),
    "wayland-sys": (["wayland"], ["pkg-config"]),
    "libusb1-sys": (["libusb1"], ["pkg-config"]),
    "pcap-sys": (["libpcap"], []),
    "libssh2-sys": (["libssh2", "openssl"], ["pkg-config"]),
    "curl-sys": (["curl", "openssl"], ["pkg-config"]),
    "clang-sys": ([], ["rustPlatform.bindgenHook"]),
    "bindgen": ([], ["rustPlatform.bindgenHook"]),
    "prost-build": ([], ["protobuf"]),
}

PYMODULES = {
    "yaml": "pyyaml", "PIL": "pillow", "bs4": "beautifulsoup4", "cv2": "opencv4",
    "sklearn": "scikit-learn", "skimage": "scikit-image", "Crypto": "pycryptodome",
    "Cryptodome": "pycryptodomex", "dateutil": "python-dateutil", "dotenv": "python-dotenv",
    "git": "gitpython", "magic": "python-magic", "jwt": "pyjwt", "serial": "pyserial",
    "usb": "pyusb", "nmap": "python-nmap", "OpenSSL": "pyopenssl", "google": "protobuf",
    "attr": "attrs", "zmq": "pyzmq", "gi": "pygobject3", "dbus": "dbus-python",
    "wx": "wxpython", "Xlib": "xlib", "socks": "pysocks", "telegram": "python-telegram-bot",
    "discord": "discordpy", "docx": "python-docx", "pptx": "python-pptx", "fitz": "pymupdf",
    "OpenGL": "pyopengl", "ldap": "python-ldap", "Levenshtein": "levenshtein",
    "slugify": "python-slugify", "multipart": "python-multipart", "jose": "python-jose",
    "ruamel": "ruamel-yaml", "pkg_resources": "setuptools", "distutils": "setuptools",
    "typing_extensions": "typing-extensions", "importlib_metadata": "importlib-metadata",
    "websocket": "websocket-client", "Bio": "biopython", "ldap3": "ldap3",
    "impacket": "impacket", "scapy": "scapy", "pwn": "pwntools", "netifaces": "netifaces",
}
# Build backends go in build-system, not dependencies.
PYBACKENDS = {
    "hatchling": "hatchling", "hatch_vcs": "hatch-vcs", "hatch-vcs": "hatch-vcs",
    "hatch_fancy_pypi_readme": "hatch-fancy-pypi-readme", "poetry": "poetry-core",
    "poetry-core": "poetry-core", "flit_core": "flit-core", "flit-core": "flit-core",
    "flit_scm": "flit-scm", "setuptools": "setuptools", "setuptools_scm": "setuptools-scm",
    "setuptools-scm": "setuptools-scm", "pdm": "pdm-backend", "pdm-backend": "pdm-backend",
    "scikit_build_core": "scikit-build-core", "scikit-build-core": "scikit-build-core",
    "mesonpy": "meson-python", "meson-python": "meson-python", "wheel": "wheel",
    "Cython": "cython", "cython": "cython", "versioneer": "versioneer",
}

# ── Small helpers ─────────────────────────────────────────────────────────────

def say(msg=""):
    print(msg, flush=True)


def run(cmd, cwd=None):
    return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)


def clean_log(raw):
    """Drop nix's `pkg> ` / `       > ` prefixes so patterns see compiler output."""
    out = []
    for line in raw.splitlines():
        line = re.sub(r"^[\w.+-]+> ", "", line)
        line = re.sub(r"^\s+> ?", "", line)
        out.append(line)
    return "\n".join(out)


def uniq(seq):
    seen, out = set(), []
    for x in seq:
        if x and x not in seen:
            seen.add(x)
            out.append(x)
    return out


def map_lookup(table, key):
    """Exact key, then the longest directory prefix (`openssl/` for `openssl/ssl.h`)."""
    if key in table:
        return list(table[key])
    best = ""
    for k in table:
        if k.endswith("/") and key.startswith(k) and len(k) > len(best):
            best = k
    return list(table[best]) if best else []


OUTPUTS = {"out", "dev", "lib", "bin", "man", "doc", "static", "devdoc", "info", "debug", "py", "modules"}
LOCATE_SKIP = ("tests.", "pkgsStatic", "pkgsCross", "pkgsi686Linux", "pkgsMusl",
               "pkgsLLVM", "pkgsx86_64Darwin", "pkgsExtraHardening", "pkgsLLVMLibc")


def locate(path, hint):
    """Rank nix-locate hits for a file at a package root; [] without nix-locate."""
    if not shutil.which("nix-locate"):
        return []
    res = run(["nix-locate", "--minimal", "--at-root", "--whole-name", path])
    if res.returncode != 0:
        return []
    names = []
    for attr in res.stdout.split():
        if attr.startswith("(") or attr.startswith(LOCATE_SKIP):
            continue
        parts = attr.split(".")
        if len(parts) > 1 and parts[-1] in OUTPUTS:
            parts = parts[:-1]
        names.append(".".join(parts))
    if not names:
        return []
    # Versioned variants (openssl_3, openssl_3_5) vote for their base attr.
    votes = {}
    for n in names:
        votes[n] = votes.get(n, 0) + 1
        base = re.sub(r"(_\d[\d_]*)$", "", n)
        if base != n:
            votes[base] = votes.get(base, 0) + 1
    hint = hint.lower()

    def score(n):
        low = n.lower()
        tier = 0 if low in (hint, "lib" + hint) else 1 if hint in low else 2
        return (tier, -votes[n], bool(re.search(r"\d", n)), n.count("."), len(n))

    return sorted(votes, key=score)[:6]


def stem_probes(name):
    s = name.lower()
    return uniq([name, s, "lib" + s, s.replace("_", "-"), s.replace("-", "_")])


def pymod_probes(mod):
    s = mod.lower()
    return uniq([mod, s, s.replace("_", "-"), s.replace("-", "_"), "py" + s, "python-" + s])

# ── flake.nix editing ─────────────────────────────────────────────────────────

class Flake:
    def __init__(self, path):
        self.path = path
        self.text = path.read_text()
        self.kind = self._kind()

    def _kind(self):
        t = self.text
        if "withPackages (ps:" in t:
            return "python-script"
        if "buildPythonApplication" in t or "buildPythonPackage" in t:
            return "python"
        if "buildRustPackage" in t:
            return "rust"
        if re.search(r"buildGo\d*Module", t):
            return "go"
        if "callCabal2nix" in t or "bundlerApp" in t:
            return "opaque"
        return "stdenv"

    def save(self):
        self.path.write_text(self.text)

    def _anchor(self):
        """Line after which new derivation attributes go, and its indent."""
        for pat in (r'^([ \t]*)version = "[^"]*";[ \t]*\n', r'^([ \t]*)pname = "[^"]*";[ \t]*\n'):
            m = re.search(pat, self.text, re.M)
            if m:
                return m.end(), m.group(1)
        return None, None

    def insert_attr(self, line):
        pos, indent = self._anchor()
        if pos is None:
            return False
        self.text = self.text[:pos] + indent + line + "\n" + self.text[pos:]
        return True

    def replace_once(self, old, new):
        if old not in self.text:
            return False
        self.text = self.text.replace(old, new, 1)
        return True

    def has_attr(self, attr):
        return re.search(r"^[ \t]*" + re.escape(attr) + r"\s*=", self.text, re.M) is not None

    def set_attr(self, attr, value):
        pat = r"^([ \t]*)" + re.escape(attr) + r"\s*=.*;[ \t]*$"
        if re.search(pat, self.text, re.M):
            new = re.sub(pat, lambda m: f"{m.group(1)}{attr} = {value};", self.text, count=1, flags=re.M)
            changed = new != self.text
            self.text = new
            return changed
        return self.insert_attr(f"{attr} = {value};")

    def _list_span(self, opener):
        """(start, end, with-scope) of an uncommented list's contents."""
        for m in re.finditer(opener, self.text, re.M):
            line_start = self.text.rfind("\n", 0, m.start()) + 1
            if "#" in self.text[line_start:m.start()]:
                continue
            depth, i = 1, m.end()
            while i < len(self.text) and depth:
                c = self.text[i]
                if c == "[":
                    depth += 1
                elif c == "]":
                    depth -= 1
                i += 1
            scope = m.groupdict().get("scope")
            return m.end(), i - 1, scope
        return None

    def _list_opener(self, attr):
        if attr == "pyenv":
            return r"withPackages\s*\(ps:\s*with (?P<scope>ps);\s*\["
        return r"^[ \t]*" + re.escape(attr) + r"\s*=\s*(?:with (?P<scope>[\w.]+);\s*)?\["

    @staticmethod
    def _render(item, scope):
        """item is relative to pkgs (e.g. python3Packages.rich) or a literal string."""
        if item.startswith('"'):
            return item
        rel = {None: None, "pkgs": "", "ps": "python3Packages"}.get(scope, scope.removeprefix("pkgs.") if scope else None)
        if rel is None:
            return "pkgs." + item
        if rel == "":
            return item
        if item.startswith(rel + "."):
            return item[len(rel) + 1:]
        return "pkgs." + item

    @staticmethod
    def _drop(body, token):
        return re.sub(r"\s?(?<![\w.\-\"'])" + re.escape(token) + r"(?![\w.\-\"'])", "", body, count=1)

    def contains(self, attr, item):
        span = self._list_span(self._list_opener(attr))
        return bool(span) and self._render(item, span[2]) in self.list_items(attr)

    def list_items(self, attr):
        span = self._list_span(self._list_opener(attr))
        if not span:
            return []
        body = re.sub(r"#.*", "", self.text[span[0]:span[1]])
        return body.split()

    def add_item(self, attr, item, default_scope="pkgs"):
        span = self._list_span(self._list_opener(attr))
        if span:
            start, end, scope = span
            token = self._render(item, scope)
            if token in self.list_items(attr):
                return False
            self.text = self.text[:start] + " " + token + self.text[start:]
            return True
        if attr == "pyenv":
            return False
        scope_txt = f"with {default_scope}; " if default_scope else ""
        token = self._render(item, default_scope)
        return self.insert_attr(f"{attr} = {scope_txt}[ {token} ];")

    def remove_item(self, attr, item):
        span = self._list_span(self._list_opener(attr))
        if not span:
            return False
        start, end, scope = span
        token = self._render(item, scope)
        body = self.text[start:end]
        new = self._drop(body, token)
        if new == body:
            return False
        self.text = self.text[:start] + new + self.text[end:]
        return True

    def remove_everywhere(self, name):
        """Drop an unknown attribute name from every input list (after an eval error)."""
        changed = False
        for attr in ("buildInputs", "nativeBuildInputs", "propagatedBuildInputs",
                     "dependencies", "build-system", "pyenv"):
            for token in self.list_items(attr):
                if token.split(".")[-1] == name:
                    span = self._list_span(self._list_opener(attr))
                    new = self._drop(self.text[span[0]:span[1]], token)
                    self.text = self.text[:span[0]] + new + self.text[span[1]:]
                    changed = True
        return changed

    def add_cflags(self, flags):
        m = re.search(r'^([ \t]*)env\.NIX_CFLAGS_COMPILE = "([^"]*)";', self.text, re.M)
        have = m.group(2).split() if m else []
        new = uniq(have + flags)
        if new == have:
            return False
        if m:
            self.text = self.text[:m.start()] + f'{m.group(1)}env.NIX_CFLAGS_COMPILE = "{" ".join(new)}";' + self.text[m.end():]
            return True
        return self.insert_attr(f'env.NIX_CFLAGS_COMPILE = "{" ".join(new)}";')

    def replace_install_phase(self, name):
        if "vm-dev-stamp" in self.text:
            return False
        lines_pre = ["preBuild = ''", "  touch .vm-dev-stamp", "'';"]
        lines_inst = [
            "installPhase = ''",
            "  runHook preInstall",
            "  mkdir -p $out/bin",
            f"  if [ -f {name} ] && [ -x {name} ]; then",
            f"    install -Dm755 {name} $out/bin/{name}",
            "  else",
            "    find . -type f -perm -u+x -newer .vm-dev-stamp ! -name '*.so*' ! -name '*.o' ! -name '*.a' \\",
            "      -exec install -Dm755 -t $out/bin {} +",
            "  fi",
            "  [ -n \"$(ls -A $out/bin)\" ] || { echo 'vm-dev: the build produced no executables' >&2; exit 1; }",
            "  runHook postInstall",
            "'';",
        ]
        m = re.search(r"^([ \t]*)installPhase = ''.*?^[ \t]*'';[ \t]*\n", self.text, re.M | re.S)
        if m:
            indent = m.group(1)
            block = "".join(indent + l + "\n" for l in lines_pre + lines_inst)
            self.text = self.text[:m.start()] + block + self.text[m.end():]
            return True
        pos, indent = self._anchor()
        if pos is None:
            return False
        self.text = self.text[:pos] + "".join(indent + l + "\n" for l in lines_pre + lines_inst) + self.text[pos:]
        return True

# ── Issues ────────────────────────────────────────────────────────────────────

class Dep:
    """A missing dependency; candidates are tried in order across rounds."""

    def __init__(self, key, why, attr, candidates, scope="pkgs", extra=()):
        self.key, self.why, self.attr = key, why, attr
        self.candidates, self.scope = candidates, scope
        self.extra = list(extra)  # (attr, item) pairs that always accompany a fix


class Edit:
    """A one-shot edit; fn(flake) -> bool."""

    def __init__(self, key, why, fn):
        self.key, self.why, self.fn = key, why, fn


def dep_list_attr(flake, native):
    if flake.kind == "python-script":
        return "pyenv" if not native else "nativeBuildInputs"
    if flake.kind == "python":
        return "nativeBuildInputs" if native else "buildInputs"
    return "nativeBuildInputs" if native else "buildInputs"


def py_deps_attr(flake):
    if flake.kind == "python-script":
        return "pyenv"
    return "propagatedBuildInputs" if flake.has_attr("propagatedBuildInputs") else "dependencies"


def diagnose(log, flake, name, pkg_dir, system):
    issues = []
    lib_attr = dep_list_attr(flake, native=False)
    nat_attr = dep_list_attr(flake, native=True)

    # Fixed-output hash mismatches (source, cargo/go/npm/maven deps)
    specified = re.findall(r"specified:\s*(sha256-[A-Za-z0-9+/=]+)", log)
    got = re.findall(r"got:\s*(sha256-[A-Za-z0-9+/=]+)", log)
    pairs = list(zip(specified, got)) or [(PLACEHOLDER, g) for g in got[:1]]
    for spec, real in pairs:
        issues.append(Edit(f"hash:{real}", f"hash mismatch -> {real}",
                           lambda f, spec=spec, real=real: f.replace_once(spec, real) or f.replace_once(PLACEHOLDER, real)))

    # Nix evaluation errors: drop names that do not exist
    for bad in uniq(re.findall(r"undefined variable '([^']+)'", log) +
                    re.findall(r"attribute '([^']+)' missing", log)):
        issues.append(Edit(f"undefined:{bad}", f"'{bad}' is not a nixpkgs attribute, removing it",
                           lambda f, bad=bad: f.remove_everywhere(bad)))

    # C/C++ headers
    for h in uniq(re.findall(r"fatal error: '?([\w./+-]+\.h(?:pp|h)?)'?(?::| file not found)", log)):
        stem = Path(h).stem
        top = h.split("/")[0] if "/" in h else ""
        cands = map_lookup(HEADERS, h) + locate(f"/include/{h}", stem) + stem_probes(stem)
        if top:
            cands += stem_probes(top)
        issues.append(Dep(f"header:{h}", f"missing header {h}", lib_attr, uniq(cands)))

    # Linker
    for l in uniq(re.findall(r"cannot find -l([\w+.-]+)", log)):
        if l in LIBC_LIBS:
            continue
        cands = map_lookup(LIBS, l) + locate(f"/lib/lib{l}.so", l) + stem_probes(l)
        issues.append(Dep(f"lib:{l}", f"missing library -l{l}", lib_attr, uniq(cands)))

    # pkg-config modules (pkg-config, configure, meson, cargo build scripts)
    pcs = re.findall(r"Package '?([\w.+-]+)'?,? (?:was not found in the pkg-config search path|required by '[^']*', not found)", log)
    pcs += re.findall(r"No package '([\w.+-]+)' found", log)
    pcs += re.findall(r'Dependency "([\w.+-]+)" not found', log)
    pcs += re.findall(r"Run-time dependency ([\w.+-]+) found: NO", log)
    pcs += re.findall(r"The system library `([\w.+-]+)` required by crate", log)
    for req in re.findall(r"Package requirements \((.*?)\) were not met", log):
        pcs += [t for t in re.split(r"[\s,]+", req) if t and not re.match(r"^[<>=!\d.]+$", t)]
    for pc in uniq(pcs):
        cands = map_lookup(PKGCONFIG, pc) + locate(f"/lib/pkgconfig/{pc}.pc", pc) + \
            locate(f"/share/pkgconfig/{pc}.pc", pc) + stem_probes(re.sub(r"[-.]?\d[\d.]*$", "", pc))
        issues.append(Dep(f"pc:{pc}", f"pkg-config module {pc} not found", lib_attr, uniq(cands),
                          extra=[(nat_attr, "pkg-config")]))
    if re.search(r"pkg_check_modules|PKG_CHECK_MODULES|Could NOT find PkgConfig|"
                                    r"pkg-config.*(?:command not found|No such file)|"
                                    r"The pkg-config command could not be found", log):
        issues.append(Dep("tool:pkg-config", "pkg-config not available", nat_attr, ["pkg-config"]))

    # CMake find_package
    for mod in uniq(re.findall(r"Could NOT find (\w+)", log) +
                    re.findall(r'provided by "?(\w+)"? with any', log) +
                    re.findall(r'package configuration file provided by\s+"(\w+)"', log)):
        if mod in CMAKE_IGNORE or mod == "PkgConfig":
            continue
        native = mod in CMAKE_NATIVE
        cands = ([CMAKE_NATIVE_ATTR[mod]] if native else []) + map_lookup(CMAKE, mod) + \
            locate(f"/lib/cmake/{mod}/{mod}Config.cmake", mod) + \
            locate(f"/lib/cmake/{mod}/{mod.lower()}-config.cmake", mod) + stem_probes(mod)
        issues.append(Dep(f"cmake:{mod}", f"CMake package {mod} not found",
                          nat_attr if native else lib_attr, uniq(cands)))
    if "Compatibility with CMake < 3.5 has been removed" in log:
        issues.append(Edit("cmake-policy", "project targets CMake < 3.5, setting policy minimum",
                           lambda f: f.add_item("cmakeFlags", '"-DCMAKE_POLICY_VERSION_MINIMUM=3.5"', default_scope=None)))

    # Missing build tools
    tools = re.findall(r"\b(?:ba)?sh: (?:line \d+: )?([\w.+-]+): (?:command )?not found", log)
    tools += re.findall(r"make(?:\[\d+\])?: ([\w.+-]+): (?:No such file or directory|Command not found)", log)
    tools += re.findall(r"Program '([\w.+-]+)' not found", log)
    tools += re.findall(r"env: ['‘]?([\w.+-]+)['’]?: No such file or directory", log)
    tools += re.findall(r"Could not find (?:program|executable) ['\"]?([\w.+-]+)", log)
    for t in uniq(tools):
        if t in TOOL_SKIP or t == "pkg-config":
            continue
        cands = map_lookup(TOOLS, t) + locate(f"/bin/{t}", t) + stem_probes(t)
        issues.append(Dep(f"tool:{t}", f"missing build tool {t}", nat_attr, uniq(cands)))
    if re.search(r"bad interpreter: No such file or directory|/usr/bin/env.*No such file", log):
        issues.append(Edit("shebangs", "scripts use FHS interpreters, patching shebangs",
                           lambda f: not f.has_attr("postPatch") and f.insert_attr("postPatch = \"patchShebangs .\";")))
    if re.search(r"possibly undefined macro: (AC_|AM_|LT_)|autoreconf: not found|configure: No such file", log):
        issues.append(Dep("tool:autoreconf", "configure script must be generated", nat_attr, ["autoreconfHook"]))

    # Rust -sys crates and bindgen
    for crate in uniq(re.findall(r"failed to run custom build command for `([\w-]+) v", log)):
        libs, natives = RUST_SYS.get(crate, ([], []))
        for n in natives:
            issues.append(Dep(f"tool:{n}", f"crate {crate} needs {n}", "nativeBuildInputs", [n]))
        for l in libs:
            issues.append(Dep(f"rustsys:{l}", f"crate {crate} needs {l}", "buildInputs", [l]))
    if re.search(r"Unable to find libclang|couldn't find any valid shared libraries matching: \['libclang", log):
        issues.append(Dep("tool:bindgen", "bindgen needs libclang", "nativeBuildInputs", ["rustPlatform.bindgenHook"]))
    if "Could not find directory of OpenSSL installation" in log:
        issues.append(Dep("rustsys:openssl", "crate openssl-sys needs openssl", "buildInputs", ["openssl"],
                          extra=[("nativeBuildInputs", "pkg-config")]))

    # Compiler strictness of newer gcc on older C code
    flags = []
    if re.search(r"error: .*\[-Werror", log):
        flags.append("-Wno-error")
    for w in uniq(re.findall(r"error: .*\[-W(implicit-function-declaration|incompatible-pointer-types|"
                             r"int-conversion|implicit-int|return-mismatch|declaration-missing-parameter-type)\]", log)):
        flags.append(f"-Wno-error={w}")
    if re.search(r"cannot be defined via 'typedef'|expected identifier or '\(' before '(?:true|false|bool)'|"
                 r"'bool' cannot|two or more data types in declaration specifiers.*bool|"
                 r"too many arguments to function.*; expected 0", log):
        flags.append("-std=gnu17")
    if "multiple definition of" in log:
        flags.append("-fcommon")
    if flags:
        issues.append(Edit("cflags:" + " ".join(flags), "relaxing compiler errors: " + " ".join(flags),
                           lambda f, flags=flags: f.add_cflags(flags)))
    if "-Werror=format-security" in log:
        issues.append(Edit("hardening:format", "format-security hardening, disabling it",
                           lambda f: f.add_item("hardeningDisable", '"format"', default_scope=None)))
    if "_FORTIFY_SOURCE requires compiling with optimization" in log:
        issues.append(Edit("hardening:fortify", "fortify hardening, disabling it",
                           lambda f: f.add_item("hardeningDisable", '"fortify"', default_scope=None)))

    # Python
    deps_attr = py_deps_attr(flake)
    missing_build = re.search(r"Missing dependencies:\n((?:\s+\S.*\n?)+)", log)
    build_mods = []
    if missing_build:
        build_mods = [re.split(r"[<>=!~; \[]", l.strip())[0] for l in missing_build.group(1).splitlines() if l.strip()]
    build_mods += re.findall(r"Cannot import '([\w.]+?)(?:\.build|\.api|\.masonry\.api|\.buildapi)?'", log)
    for mod in uniq(build_mods):
        top = mod.split(".")[0]
        cands = ["python3Packages." + c for c in uniq([PYBACKENDS.get(mod, ""), PYBACKENDS.get(top, "")] + pymod_probes(top))]
        issues.append(Dep(f"pybuild:{top}", f"python build backend {top} missing", "build-system", cands,
                          scope="pkgs.python3Packages"))
    runtime = re.findall(r"^\s*- ([\w.\-\[\]]+?)(?:[<>=!~].*)? not installed", log, re.M)
    runtime += re.findall(r"(?:ModuleNotFoundError|ImportError): No module named '([\w.]+)'", log)
    for mod in uniq(runtime):
        top = mod.split(".")[0].split("[")[0]
        if top in PYBACKENDS and top not in ("setuptools",):
            continue
        cands = ["python3Packages." + c for c in uniq([PYMODULES.get(top, "")] + pymod_probes(top))]
        issues.append(Dep(f"pydep:{top}", f"python module {top} missing", deps_attr, cands,
                          scope="pkgs.python3Packages"))
    if re.search(r"not satisfied by version", log) and flake.kind == "python":
        issues.append(Edit("relaxdeps", "pinned python versions differ from nixpkgs, relaxing",
                           lambda f: f.set_attr("pythonRelaxDeps", "true")))

    # Go: nested modules, test-only or example packages break the default ./...
    if flake.kind == "go" and not flake.has_attr("subPackages") and re.search(
            r"does not contain package|no non-test Go files|build constraints exclude all Go files|"
            r"no Go files in", log):
        def set_sub(f):
            mains = go_main_packages(pkg_dir)
            return bool(mains) and f.set_attr("subPackages", "[ " + " ".join(f'"{m}"' for m in mains) + " ]")
        issues.append(Edit("go-subpackages", "building only the module's main packages", set_sub))
    m = re.search(r"go\.mod requires go >= ([\d.]*\d)", log)
    if flake.kind == "go" and m:
        need = m.group(1)
        issues.append(Edit(f"go-version:{need}", f"go.mod needs Go {need}",
                           lambda f, need=need: go_toolchain(f, pkg_dir, system, need)))

    # Toolchain older than the project needs: only this package's own pin moves.
    if re.search(r"requires rustc [\d.]+ or newer|rustc [\d.]+ is not supported by the following package|"
                 r"Python [\d.]+ is not supported|feature `[\w-]+` is required", log):
        issues.append(Edit("toolchain-old", "toolchain too old, pinning this package to nixos-unstable",
                           lambda f: pin_nixpkgs(pkg_dir, system, ref=UNSTABLE)))

    # Phase-level failures
    phases = re.findall(r"Running phase: (\w+)", log)
    last = phases[-1] if phases else ""
    if last in ("checkPhase", "pytestCheckPhase", "cargoCheckHook", "goCheckPhase") and not issues:
        issues.append(Edit("nocheck", f"tests fail in the sandbox ({last}), disabling them",
                           lambda f: f.set_attr("doCheck", "false")))
    if last == "installCheckPhase" and not issues:
        issues.append(Edit("noinstallcheck", "install checks fail, disabling them",
                           lambda f: f.set_attr("doInstallCheck", "false")))
    if "vm-dev: the build produced no executables" in log:
        issues.append(Edit("noexe", "the build produced no executables (library only, or built "
                           "outside the source root): write installPhase by hand", lambda f: False))
    elif flake.kind == "stdenv" and (
        re.search(r"cp: cannot stat|cp: missing destination|failed to produce output path|"
                  r"No rule to make target 'install'|cannot create (?:regular file|directory) '/usr", log)
        or (last == "installPhase" and not issues)):
        issues.append(Edit("install", "installPhase does not find the built binary, auto-detecting it",
                           lambda f: f.replace_install_phase(name)))
    # Several patterns can report the same problem; keep the first of each.
    return list({i.key: i for i in reversed(issues)}.values())[::-1]

def go_toolchain(flake, pkg_dir, system, need):
    """Pick a Go builder whose toolchain satisfies go.mod from the pinned nixpkgs, or
    move this package's pin to nixos-unstable once."""
    req = tuple(int(x) for x in need.split("."))
    major, minor = req[0], req[1] if len(req) > 1 else 0
    attrs = ["go"] + [f"go_{major}_{v}" for v in range(minor, minor + 8)]
    lst = " ".join(f'"{a}"' for a in attrs)
    expr = (f"ps: builtins.listToAttrs (map (n: {{ name = n; value = let r = builtins.tryEval "
            f"(ps.${{n}}.version or null); in if r.success then r.value else null; }}) [ {lst} ])")
    res = run(["nix", "eval", "--inputs-from", ".", "--json", f"nixpkgs#legacyPackages.{system}",
               "--apply", expr], cwd=pkg_dir)
    try:
        versions = {k: v for k, v in json.loads(res.stdout).items() if v}
    except ValueError:
        versions = {}
    ok = lambda v: tuple(int(x) for x in re.findall(r"\d+", v)[:3]) >= req
    if "go" in versions and ok(versions["go"]):
        builder = "buildGoModule"
    else:
        fits = [a for a in attrs[1:] if a in versions and ok(versions[a])]
        builder = f"buildGo{major}{fits[-1].rsplit('_', 1)[1]}Module" if fits else None
    if builder:
        new = re.sub(r"pkgs\.buildGo\d*Module", "pkgs." + builder, flake.text, count=1)
        changed, flake.text = new != flake.text, new
        return changed
    if not pin_nixpkgs(pkg_dir, system, ref=UNSTABLE):
        return False
    flake.text = re.sub(r"pkgs\.buildGo\d*Module", "pkgs.buildGoModule", flake.text, count=1)
    return True


# ── Source inspection ─────────────────────────────────────────────────────────

def source_dir(pkg_dir):
    """Store path of the package's fetched source."""
    res = run(["nix", "build", ".#default.src", "--no-link", "--print-out-paths"], cwd=pkg_dir)
    path = res.stdout.strip().splitlines()[-1] if res.returncode == 0 and res.stdout.strip() else ""
    return Path(path) if path and Path(path).is_dir() else None


GO_SKIP_DIRS = {"vendor", "testdata", ".git", "node_modules", "third_party"}
GO_AUX = re.compile(r"(^|/)(tests?|e2e|integration|examples?|_examples|samples?|demos?|internal|tools|hack|scripts|benchmarks?)(/|$)")


def go_main_packages(pkg_dir):
    """`package main` directories of the root module, preferring the root and cmd/."""
    src = source_dir(pkg_dir)
    if not src:
        return []
    mains = []
    for d, dirs, files in os.walk(src):
        d = Path(d)
        rel = d.relative_to(src).as_posix()
        # Subdirectories with their own go.mod are separate modules.
        dirs[:] = [x for x in dirs if x not in GO_SKIP_DIRS and not (d / x / "go.mod").exists()]
        for f in files:
            if f.endswith(".go") and not f.endswith("_test.go"):
                try:
                    head = (d / f).read_text(errors="ignore")[:4096]
                except OSError:
                    continue
                if re.search(r"^package main\b", head, re.M):
                    mains.append("." if rel == "." else rel)
                    break
    preferred = [m for m in mains if m == "." or m == "cmd" or m.startswith("cmd/")]
    if preferred:
        return sorted(preferred)
    return sorted([m for m in mains if not GO_AUX.search(m)] or mains)


# ── Candidate validation ──────────────────────────────────────────────────────

def existing(pkg_dir, system, names, drv=True):
    """Subset of names (relative to pkgs) that exist in the flake's nixpkgs (as derivations if drv)."""
    names = [n for n in uniq(names) if re.match(r"^[A-Za-z_][\w.+-]*$", n)]
    if not names:
        return set()
    lst = " ".join('"' + n + '"' for n in names)
    expr = ("ps: let lib = ps.lib; ok = n: let v = lib.attrByPath (lib.splitString \".\" n) null ps; "
            f"r = builtins.tryEval (v != null && {'lib.isDerivation v' if drv else 'true'}); in r.success && r.value; "
            f"in builtins.filter ok [ {lst} ]")
    res = run(["nix", "eval", "--inputs-from", ".", "--json",
               f"nixpkgs#legacyPackages.{system}", "--apply", expr], cwd=pkg_dir)
    if res.returncode != 0:
        # Unable to check (no lock yet, offline): trust curated names only.
        return set(names)
    return set(json.loads(res.stdout))

# ── Main loop ─────────────────────────────────────────────────────────────────

def system_nixpkgs():
    """Store path the NixOS system registry maps `nixpkgs` to (the VM's own nixpkgs)."""
    try:
        reg = json.loads(Path("/etc/nix/registry.json").read_text())
    except (OSError, ValueError):
        return None
    for f in reg.get("flakes", []):
        if f.get("from", {}).get("id") == "nixpkgs" and f.get("to", {}).get("type") == "path":
            return f["to"]["path"]
    return None


def locked_nixpkgs(pkg_dir):
    try:
        lock = json.loads((pkg_dir / "flake.lock").read_text())
        node = lock["nodes"]["root"]["inputs"]["nixpkgs"]
        return lock["nodes"][node]["locked"]
    except (OSError, ValueError, KeyError, TypeError):
        return {}


def is_pinned(locked):
    return locked.get("type") == "github" and bool(locked.get("rev")) and bool(locked.get("narHash"))


def system_pin():
    """github ref of the VM's own nixpkgs: already in the store, so pinning to it is free."""
    path = system_nixpkgs()
    try:
        rev = json.loads(run(["nixos-version", "--json"]).stdout)["nixpkgsRevision"]
    except (ValueError, KeyError):
        rev = ""
    if not path or not re.fullmatch(r"[0-9a-f]{40}", rev or ""):
        return None
    nar = run(["nix", "hash", "path", path]).stdout.strip()
    return f"github:NixOS/nixpkgs/{rev}?narHash={nar.replace('+', '%2B').replace('/', '%2F').replace('=', '%3D')}"


UNSTABLE = "github:NixOS/nixpkgs/nixos-unstable"


def pin_nixpkgs(pkg_dir, system, ref=None, force=False):
    """Lock nixpkgs to an exact github rev + narHash. vm-sync push copies this pin into
    package.nix, so the host builds with exactly the nixpkgs tested here."""
    if 'inputs.nixpkgs.url = "nixpkgs";' not in (pkg_dir / "flake.nix").read_text():
        if not (pkg_dir / "flake.lock").exists():
            run(["nix", "flake", "lock"], cwd=pkg_dir)
        return True
    if force or ref or not is_pinned(locked_nixpkgs(pkg_dir)):
        ref = ref or system_pin()
        if not ref:
            say("Error: cannot determine the system nixpkgs revision to pin to")
            return False
        res = run(["nix", "flake", "lock", "--override-input", "nixpkgs", ref], cwd=pkg_dir)
        if res.returncode != 0:
            say(f"Error: could not pin nixpkgs to {ref.split('?')[0]}:")
            say(res.stderr.strip())
            return False
    go = run(["nix", "eval", "--inputs-from", ".", "--raw", f"nixpkgs#legacyPackages.{system}.go.version"], cwd=pkg_dir)
    say(f"  nixpkgs: {locked_nixpkgs(pkg_dir).get('rev', '?')[:12]} (go {go.stdout.strip() or '?'})")
    return True


def pin_src(flake):
    """Turn `rev = "<branch>"` of fetchFromGitHub into the commit it points at now."""
    changed = False
    pat = r'owner = "([^"]+)";\s*repo = "([^"]+)";\s*rev = "([^"]+)";\s*hash = "([^"]+)";'
    for owner, repo, rev, old_hash in set(re.findall(pat, flake.text)):
        if re.fullmatch(r"[0-9a-f]{40}", rev):
            continue
        res = run(["nix", "flake", "prefetch", "--json", f"github:{owner}/{repo}/{rev}"])
        try:
            info = json.loads(res.stdout)
            commit, new_hash = info["locked"]["rev"], info["hash"]
        except (ValueError, KeyError):
            say(f"  warning: could not resolve {owner}/{repo} {rev} to a commit (offline?)")
            continue
        flake.text = flake.text.replace(f'rev = "{rev}";', f'rev = "{commit}";')
        if new_hash != old_hash:
            flake.text = flake.text.replace(old_hash, new_hash)
            say(f"  source: {rev} moved upstream, pinned to {commit[:12]} (new hash)")
        else:
            say(f"  source: {rev} pinned to commit {commit[:12]}")
        changed = True
    return changed


def build(pkg_dir, log_path):
    res = run(["nix", "build", ".#default", "-L"], cwd=pkg_dir)
    raw = res.stdout + res.stderr
    log_path.write_text(raw)
    return res.returncode == 0, raw


def error_tail(raw, n=25):
    lines = [l for l in clean_log(raw).splitlines() if l.strip()]
    hits = [i for i, l in enumerate(lines) if re.search(r"error|Error|ERROR|failed", l)]
    if hits:
        start = max(0, hits[0] - 3)
        return "\n".join(lines[start:start + n])
    return "\n".join(lines[-n:])


def main_program_hint(pkg_dir, flake, name):
    bindir = pkg_dir / "result" / "bin"
    if "mainProgram" in flake.text or not bindir.is_dir():
        return
    exes = sorted(p.name for p in bindir.iterdir() if not p.name.startswith("."))
    if name in exes or not exes:
        return
    if len(exes) == 1:
        flake.set_attr("meta.mainProgram", f'"{exes[0]}"')
        flake.save()
        say(f"  fixed: binary is named {exes[0]}, set meta.mainProgram")
    else:
        say(f"  note: several binaries ({', '.join(exes)}); run one with: nix run {pkg_dir}#default -- or set meta.mainProgram")


def main():
    ap = argparse.ArgumentParser(prog="vm-dev fix", description=__doc__.splitlines()[0])
    ap.add_argument("pkg", help="package name under ~/dev/packages, or a directory")
    ap.add_argument("--max", type=int, default=10, help="maximum build rounds (default 10)")
    ap.add_argument("-n", "--dry-run", action="store_true", help="diagnose once, change nothing")
    ap.add_argument("--lock-only", action="store_true", help="only make sure nixpkgs and the source are pinned")
    ap.add_argument("--update", action="store_true", help="re-pin nixpkgs to the VM's current system nixpkgs")
    args = ap.parse_args()

    pkg_dir = Path(args.pkg) if "/" in args.pkg else Path.home() / "dev" / "packages" / args.pkg
    pkg_dir = pkg_dir.resolve()
    flake_path = pkg_dir / "flake.nix"
    if not flake_path.is_file():
        say(f"Error: no flake.nix at {pkg_dir}")
        return 1
    name = pkg_dir.name
    log_path = pkg_dir / "build.log"
    original = flake_path.read_text()
    m = re.search(r'system = "([^"]+)";', original)
    system = m.group(1) if m else run(["nix", "eval", "--impure", "--raw", "--expr", "builtins.currentSystem"]).stdout or "x86_64-linux"

    # Build against the VM's system nixpkgs (what the host uses for staged packages).
    if 'inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";' in original:
        flake_path.write_text(original.replace('inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";',
                                               'inputs.nixpkgs.url = "nixpkgs";'))
        say("  fix: nixpkgs is now pinned in flake.lock instead of following nixos-unstable")
    if not pin_nixpkgs(pkg_dir, system, force=args.update):
        return 1
    src_flake = Flake(flake_path)
    if pin_src(src_flake):
        src_flake.save()
    if args.lock_only or args.update:
        return 0

    tried = {}     # issue key -> candidates already added in an earlier round
    done = set()   # one-shot edits already applied
    unresolved = []
    ok = False

    for rnd in range(1, args.max + 1):
        say(f"[{rnd}] building {name}...")
        ok, raw = build(pkg_dir, log_path)
        flake = Flake(flake_path)
        if ok:
            say(f"[{rnd}] build succeeded")
            main_program_hint(pkg_dir, flake, name)
            break

        issues = diagnose(clean_log(raw), flake, name, pkg_dir, system)
        deps = [i for i in issues if isinstance(i, Dep)]
        valid = existing(pkg_dir, system, [c for d in deps for c in d.candidates] +
                         [x for d in deps for _, x in d.extra])

        changed, unresolved = [], []
        for issue in issues:
            if isinstance(issue, Edit):
                if issue.key in done:
                    unresolved.append(issue.why + " (already applied, still failing)")
                    continue
                if args.dry_run or issue.fn(flake):
                    done.add(issue.key)
                    changed.append(issue.why)
                else:
                    unresolved.append(issue.why + " (no automatic edit applies)")
                continue
            prev = tried.setdefault(issue.key, [])
            # An earlier candidate did not fix it: take it back out.
            if prev and not args.dry_run:
                flake.remove_item(issue.attr, prev[-1])
            nxt = None
            for c in issue.candidates:
                if c in prev or c not in valid:
                    continue
                if flake.contains(issue.attr, c) and not prev:
                    prev.append(c)  # already declared and still failing: wrong package
                    continue
                nxt = c
                break
            if not nxt:
                unresolved.append(f"{issue.why} (no matching nixpkgs package found)")
                continue
            prev.append(nxt)
            if not args.dry_run:
                flake.add_item(issue.attr, nxt, issue.scope)
                for attr, x in issue.extra:
                    if x in valid:
                        flake.add_item(attr, x)
            changed.append(f"{issue.why} -> {issue.attr} += {nxt}")

        for c in changed:
            say(f"  fix: {c}")
        for u in unresolved:
            say(f"  unresolved: {u}")
        if args.dry_run:
            if not issues:
                say("  no known error pattern recognised")
                say(error_tail(raw))
            return 1
        if not changed:
            if not issues:
                say("  no known error pattern recognised")
            say("")
            say(error_tail(raw))
            break
        flake.save()

    final = flake_path.read_text()
    if final != original:
        (pkg_dir / "flake.nix.bak").write_text(original)
        say("")
        say("Changes to flake.nix (previous version in flake.nix.bak):")
        for line in difflib.unified_diff(original.splitlines(), final.splitlines(),
                                         "flake.nix.bak", "flake.nix", lineterm="", n=1):
            say("  " + line)
    say("")
    if ok:
        say(f"Run:   vm-dev run {name}")
        say(f"Stage: vm-sync push --name {name}")
        return 0
    say(f"Still failing. Full log: {log_path}")
    say(f"Edit by hand: vm-dev edit {name}, then vm-dev fix {name} again")
    if not shutil.which("nix-locate"):
        say("Tip: with nix-locate (nix-index-database) installed, unknown headers/libraries resolve automatically")
    return 1


if __name__ == "__main__":
    sys.exit(main())
