"""Fill pywal's scheme cache for every wallpaper in the given directories.

Calls pywal's own colors.get() with the same arguments `wal -i` passes
(backend=None, saturate=None, dark), so each cache file lands under exactly
the name walrgb/randomwalrgb look up, holding exactly the palette they would
have generated. Nothing is applied: no wallpaper, templates or reloads.

pywal keys the cache on the image path only, so an image newer than its cache
file (replaced in place under the same name) is regenerated. Passes repeat
until one finds nothing to do, picking up images added mid-run. An image
modified in the last few seconds may still be downloading or copying, so it
waits until it settles. Images pywal cannot make a palette from (near
monochrome; stock `wal` fails on them too) are recorded with their mtime and
skipped until the file changes.
"""
import json
import logging
import os
import sys
import time

from pywal import colors
from pywal.settings import CACHE_DIR

# Same extensions pywal's image.get_image_dir() picks from for randomwalrgb.
FILE_TYPES = (".png", ".jpg", ".jpeg", ".jpe", ".gif")
FAILED_FILE = os.path.join(CACHE_DIR, "precache-failed.json")
SETTLE_SECONDS = 3


def cache_file(img):
    return os.path.join(*colors.cache_fname(img, None, False, CACHE_DIR, None))


def readable(path):
    # A run killed mid-write leaves a truncated file that wal would crash on.
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def stale_images(dirs, failed):
    for img_dir in dirs:
        if not os.path.isdir(img_dir):
            continue
        for entry in sorted(os.scandir(img_dir), key=lambda e: e.name):
            if not (entry.is_file() and entry.name.lower().endswith(FILE_TYPES)):
                continue
            img = os.path.abspath(entry.path)
            mtime = entry.stat().st_mtime
            if failed.get(img) == mtime:
                continue
            cached = cache_file(img)
            if (not os.path.isfile(cached)
                    or os.path.getmtime(cached) < mtime
                    or "colors" not in (readable(cached) or {})):
                yield img, cached, mtime


def main():
    logging.basicConfig(format="%(message)s", level=logging.WARNING)
    dirs = sys.argv[1:]
    failed = readable(FAILED_FILE) or {}

    while True:
        todo = list(stale_images(dirs, failed))
        if not todo:
            break
        ready = [t for t in todo if time.time() - t[2] >= SETTLE_SECONDS]
        if not ready:
            time.sleep(SETTLE_SECONDS)
            continue
        for img, cached, mtime in ready:
            if os.path.isfile(cached):
                os.remove(cached)
            start = time.monotonic()
            try:
                colors.get(img, False, None, sat=None)
            except (Exception, SystemExit) as err:
                failed[img] = mtime
                print(f"failed {img}: {err}", flush=True)
                continue
            failed.pop(img, None)
            print(f"cached {img} ({time.monotonic() - start:.1f}s)", flush=True)

    # Drop records of images that no longer exist.
    failed = {img: m for img, m in failed.items() if os.path.isfile(img)}
    tmp = FAILED_FILE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(failed, f)
    os.replace(tmp, FAILED_FILE)


if __name__ == "__main__":
    main()
