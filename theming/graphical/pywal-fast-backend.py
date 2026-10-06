

# Appended to pywal/backends/wal.py by theming/graphical/pywal.nix.
#
# Same palette as the stock gen_colors above, less work. Stock re-runs the
# whole `convert img -resize 25% -colors N` pipeline for every N from 16 up
# to 35 until ImageMagick returns more than 16 colors, so a low-color
# wallpaper decodes and Lanczos-resizes the full-size image up to 20 times.
# Here the resize runs once into a floating-point MIFF (lossless for
# ImageMagick's HDRI float pixels, so quantizing it gives byte-identical
# colors; `-depth 8` must come after `-unique-colors`, or near-identical
# colors merge and change the count), and if N=16 falls short, N=17..35 are quantized in parallel and the
# smallest N that succeeds wins, exactly the N the stock loop would stop at.
import concurrent.futures
import os
import tempfile


def gen_colors(img):
    """Format the output from imagemagick into a list
       of hex colors."""
    magick_command = has_im()

    with tempfile.TemporaryDirectory(prefix="pywal-") as tmp:
        small = os.path.join(tmp, "small.miff")
        subprocess.check_call([*magick_command, img + "[0]", "-resize", "25%",
                               "-define", "quantum:format=floating-point",
                               "-depth", "32", small])

        def quantize(color_count):
            return subprocess.check_output(
                [*magick_command, small, "-colors", str(color_count),
                 "-unique-colors", "-depth", "8", "txt:-"]).splitlines()

        raw_colors = quantize(16)

        if len(raw_colors) <= 16:
            logging.warning("Imagemagick couldn't generate a palette.")
            logging.warning("Trying larger palette sizes 17-35 in parallel")

            with concurrent.futures.ThreadPoolExecutor(os.cpu_count()) as pool:
                for raw in pool.map(quantize, range(17, 36)):
                    if len(raw) > 16:
                        raw_colors = raw
                        break
                else:
                    logging.error("Imagemagick couldn't generate a suitable palette.")
                    sys.exit(1)

    return [re.search("#.{6}", str(col)).group(0) for col in raw_colors[1:]]
