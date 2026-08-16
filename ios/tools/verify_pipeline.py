#!/usr/bin/env python3
"""Reference port of the app's dithering and packing, for testing and tuning.

This mirrors, line for line, the algorithm the iOS app ships:

    InkColor.swift          ink RGB values, YCbCr transform, CHROMA_WEIGHT
    AtkinsonDitherer.swift  error diffusion and palette matching
    PixelPacker.swift       2 bits per pixel, 4 pixels per byte

Keep the two in sync: tune a constant here, confirm the result, then copy the
number into the Swift file it came from. Nothing outside the standard library
is needed for the self-test and the sweep; --image additionally needs Pillow
(pip install pillow).

    python3 verify_pipeline.py                      # regression self-test
    python3 verify_pipeline.py --sweep              # chroma weight sweep
    python3 verify_pipeline.py --image photo.jpg    # dither a real photo

Note: with --image the scaling step uses Pillow's Lanczos filter while the app
uses Core Graphics, so a real photo can differ from the app's output by a pixel
here and there. The dithering and packing themselves are exact.
"""

import argparse
import struct
import sys
import zlib

# --- constants mirrored from Swift -----------------------------------------

WIDTH = 212                        # PanelSpec.width
HEIGHT = 104                       # PanelSpec.height
PIXELS_PER_BYTE = 4                # PanelSpec.pixelsPerByte
PAYLOAD_BYTES = WIDTH * HEIGHT // PIXELS_PER_BYTE   # 5512

BLACK, WHITE, RED = 0b00, 0b01, 0b10                # InkColor raw values

INK_RGB = {                                         # InkColor.displayRGB
    BLACK: (22, 22, 26),
    WHITE: (244, 243, 238),
    RED: (198, 48, 44),
}
INK_NAME = {BLACK: "black", WHITE: "white", RED: "red"}

PALETTES = {                                        # PaletteMode.inks
    "classic": [BLACK, WHITE],
    "accent": [BLACK, WHITE, RED],
}

CHROMA_WEIGHT = 2.0                                 # YCbCr.chromaWeight

# Atkinson: 1/8 of the error to each of six neighbours, 2/8 discarded.
ATKINSON = ((1, 0), (2, 0), (-1, 1), (0, 1), (1, 1), (0, 2))
ERROR_DIVISOR = 8


# --- the algorithm ----------------------------------------------------------

def ycbcr(rgb):
    """Convert an (r, g, b) triple to a (y, cb, cr) triple, BT.601 full range.

        y   luma          overall brightness, a weighted average of r, g and b
        cb  chroma blue   blue minus y, i.e. how far blue sits from brightness
        cr  chroma red    red minus y, i.e. how far red sits from brightness

    Both chroma values are rescaled to fit plus or minus 128 and offset so that
    neutral sits at 128, which means any grey - black, mid grey, white - lands
    at cb = cr = 128 and is separated from the others by luma alone.
    """
    r, g, b = rgb
    return (0.299 * r + 0.587 * g + 0.114 * b,
            -0.168736 * r - 0.331264 * g + 0.5 * b + 128,
            0.5 * r - 0.418688 * g - 0.081312 * b + 128)


# Squared 3-D distance between two (y, cb, cr) points; the square root is
# skipped because callers only ever compare results, never use the magnitude.
# chroma_weight multiplies the two colour terms, stretching the colour axes
# relative to brightness before the comparison. That weight is near-zero for
# black and white, which sit within a few units of any grey on both colour
# axes, so it only meaningfully penalises red - which is what keeps neutral
# tones from picking up red ink.
def distance_squared(a, b, chroma_weight):
    dy, dcb, dcr = a[0] - b[0], a[1] - b[1], a[2] - b[2]
    return dy * dy + chroma_weight * (dcb * dcb + dcr * dcr)


def dither(rgba, width, height, palette, chroma_weight=CHROMA_WEIGHT):
    """Atkinson error diffusion onto `palette`. Returns one ink per pixel."""
    count = width * height
    work = []
    for i in range(count):
        work.extend((float(rgba[i * 4]), float(rgba[i * 4 + 1]), float(rgba[i * 4 + 2])))

    ink_rgb = [INK_RGB[ink] for ink in palette]
    ink_ycc = [ycbcr(rgb) for rgb in ink_rgb]
    out = [palette[0]] * count

    for y in range(height):
        for x in range(width):
            base = (y * width + x) * 3
            old = (work[base], work[base + 1], work[base + 2])

            target = ycbcr(old)
            best, best_distance = 0, float("inf")
            for index, candidate in enumerate(ink_ycc):
                d = distance_squared(target, candidate, chroma_weight)
                if d < best_distance:
                    best_distance, best = d, index

            out[y * width + x] = palette[best]

            chosen = ink_rgb[best]
            share = [(old[i] - chosen[i]) / ERROR_DIVISOR for i in range(3)]

            for dx, dy in ATKINSON:
                nx, ny = x + dx, y + dy
                if nx < 0 or nx >= width or ny >= height:
                    continue
                n = (ny * width + nx) * 3
                for i in range(3):
                    work[n + i] += share[i]

    return out


def pack(pixels):
    """4 pixels per byte, most significant bits first."""
    if len(pixels) != WIDTH * HEIGHT:
        raise ValueError(f"expected {WIDTH * HEIGHT} pixels, got {len(pixels)}")
    out = bytearray(PAYLOAD_BYTES)
    for i in range(PAYLOAD_BYTES):
        p = i * PIXELS_PER_BYTE
        out[i] = (pixels[p] << 6) | (pixels[p + 1] << 4) | (pixels[p + 2] << 2) | pixels[p + 3]
    return bytes(out)


def unpack(payload):
    pixels = []
    for byte in payload:
        pixels += [(byte >> 6) & 3, (byte >> 4) & 3, (byte >> 2) & 3, byte & 3]
    return pixels


# --- inputs and outputs -----------------------------------------------------

def flat(rgb):
    """A full panel of one colour, as an RGBA raster."""
    return bytearray(bytes(rgb) + b"\xff") * (WIDTH * HEIGHT)


def ramp():
    """Left-to-right black-to-white grey ramp."""
    buf = bytearray()
    for _ in range(HEIGHT):
        for x in range(WIDTH):
            v = x * 255 // (WIDTH - 1)
            buf += bytes((v, v, v, 255))
    return buf


def load_image(path):
    """Centre crop to the panel aspect, downsample, rotate portrait shots."""
    try:
        from PIL import Image, ImageOps
    except ImportError:
        sys.exit("--image needs Pillow:  pip install pillow")

    image = ImageOps.exif_transpose(Image.open(path)).convert("RGB")
    portrait = image.height > image.width
    aspect = HEIGHT / WIDTH if portrait else WIDTH / HEIGHT

    w, h = image.size
    if w / h > aspect:
        cropped = int(round(h * aspect))
        box = ((w - cropped) // 2, 0, (w - cropped) // 2 + cropped, h)
    else:
        cropped = int(round(w / aspect))
        box = (0, (h - cropped) // 2, w, (h - cropped) // 2 + cropped)

    image = image.crop(box).resize((HEIGHT, WIDTH) if portrait else (WIDTH, HEIGHT),
                                   Image.LANCZOS)
    if portrait:
        image = image.rotate(-90, expand=True)      # clockwise, the app's default

    rgb = image.tobytes()
    buf = bytearray()
    for i in range(0, len(rgb), 3):
        buf += rgb[i:i + 3] + b"\xff"
    return buf


def write_png(path, pixels, scale=4):
    """Nearest-neighbour PNG of the dithered result, stdlib only."""
    rows = []
    for y in range(HEIGHT):
        row = bytearray()
        for x in range(WIDTH):
            row += bytes(INK_RGB[pixels[y * WIDTH + x]]) * scale
        rows.extend([bytes(row)] * scale)

    raw = b"".join(b"\x00" + row for row in rows)

    def chunk(tag, data):
        return (struct.pack(">I", len(data)) + tag + data
                + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", WIDTH * scale, HEIGHT * scale, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(raw, 9))
    png += chunk(b"IEND", b"")
    with open(path, "wb") as handle:
        handle.write(png)


def ink_mix(pixels):
    total = len(pixels)
    return {ink: pixels.count(ink) * 100.0 / total for ink in (BLACK, WHITE, RED)}


def describe(label, pixels):
    mix = ink_mix(pixels)
    print(f"  {label:26s} black {mix[BLACK]:5.1f}%   white {mix[WHITE]:5.1f}%   red {mix[RED]:5.1f}%")


# --- commands ---------------------------------------------------------------

def self_test(chroma_weight):
    """Regression checks. Non-zero exit if any of them break."""
    print(f"self-test at chroma weight {chroma_weight}\n")
    failures = []

    def check(condition, message):
        if not condition:
            failures.append(message)

    check(WIDTH % PIXELS_PER_BYTE == 0, "panel width is not a whole number of bytes")

    accent, classic = PALETTES["accent"], PALETTES["classic"]

    ramp_classic = dither(ramp(), WIDTH, HEIGHT, classic, chroma_weight)
    describe("ramp / classic", ramp_classic)
    check(len(pack(ramp_classic)) == PAYLOAD_BYTES, "classic payload is not 5512 bytes")
    check(RED not in ramp_classic, "classic palette emitted red ink")

    ramp_accent = dither(ramp(), WIDTH, HEIGHT, accent, chroma_weight)
    describe("ramp / accent", ramp_accent)
    payload = pack(ramp_accent)
    check(len(payload) == PAYLOAD_BYTES, "accent payload is not 5512 bytes")
    check(unpack(payload) == ramp_accent, "pack/unpack round trip mismatch")

    grey = dither(flat((128, 128, 128)), WIDTH, HEIGHT, accent, chroma_weight)
    describe("flat 50% grey / accent", grey)
    check(ink_mix(grey)[RED] == 0, "neutral grey picked up red ink - chroma weight too low")

    red = dither(flat((220, 30, 30)), WIDTH, HEIGHT, accent, chroma_weight)
    describe("flat red / accent", red)
    check(ink_mix(red)[RED] > 95, "saturated red barely used red ink - chroma weight too high")

    warm = dither(flat((190, 90, 80)), WIDTH, HEIGHT, accent, chroma_weight)
    describe("warm brick tone / accent", warm)
    check(ink_mix(warm)[RED] > 70, "warm tones lost most of their red ink")

    print()
    if failures:
        for message in failures:
            print(f"  FAIL  {message}")
        return 1
    print("  all checks passed")
    return 0


def sweep(weights):
    """How the chroma weight trades grey speckle against red on warm tones."""
    accent = PALETTES["accent"]
    grey_raster, ramp_raster, warm_raster = flat((128, 128, 128)), ramp(), flat((190, 90, 80))

    print("  weight | ramp red% | flat grey red% | warm tone red% | ramp dark quarter white%")
    print("  " + "-" * 78)
    for weight in weights:
        ramp_px = dither(ramp_raster, WIDTH, HEIGHT, accent, weight)
        grey_px = dither(grey_raster, WIDTH, HEIGHT, accent, weight)
        warm_px = dither(warm_raster, WIDTH, HEIGHT, accent, weight)

        dark = [ramp_px[y * WIDTH + x] for y in range(HEIGHT) for x in range(WIDTH // 4)]
        dark_white = dark.count(WHITE) * 100.0 / len(dark)

        print(f"  {weight:6.1f} | {ink_mix(ramp_px)[RED]:9.1f} | {ink_mix(grey_px)[RED]:14.1f} "
              f"| {ink_mix(warm_px)[RED]:14.1f} | {dark_white:23.1f}")
    print("\n  Lower weight speckles neutral greys with red; higher weight costs red on")
    print("  warm tones for no further gain. The shipped value is "
          f"{CHROMA_WEIGHT} (InkColor.swift).")
    return 0


def run_image(path, palette_name, chroma_weight, out_png, out_payload, scale):
    raster = load_image(path)
    palette = PALETTES[palette_name]
    pixels = dither(raster, WIDTH, HEIGHT, palette, chroma_weight)
    describe(f"{path} / {palette_name}", pixels)

    payload = pack(pixels)
    if out_png:
        write_png(out_png, pixels, scale)
        print(f"  wrote {out_png} ({WIDTH * scale} x {HEIGHT * scale})")
    if out_payload:
        with open(out_payload, "wb") as handle:
            handle.write(payload)
        print(f"  wrote {out_payload} ({len(payload)} bytes)")
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--image", metavar="PATH", help="dither a real photo instead of test fields")
    parser.add_argument("--palette", choices=sorted(PALETTES), default="accent")
    parser.add_argument("--weight", type=float, default=CHROMA_WEIGHT,
                        metavar="W", help=f"chroma weight (default {CHROMA_WEIGHT})")
    parser.add_argument("--sweep", action="store_true", help="compare a range of chroma weights")
    parser.add_argument("--weights", type=float, nargs="+",
                        default=[0.0, 0.5, 1.0, 2.0, 4.0, 10.0], metavar="W",
                        help="values for --sweep")
    parser.add_argument("--out", metavar="PNG", default="preview.png",
                        help="preview image for --image (default preview.png)")
    parser.add_argument("--payload", metavar="BIN",
                        help="also write the raw 5512 byte payload")
    parser.add_argument("--scale", type=int, default=4, help="preview magnification")
    args = parser.parse_args()

    if args.sweep:
        return sweep(args.weights)
    if args.image:
        return run_image(args.image, args.palette, args.weight, args.out, args.payload, args.scale)
    return self_test(args.weight)


if __name__ == "__main__":
    sys.exit(main())
