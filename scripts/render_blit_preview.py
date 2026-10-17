"""Convert testbench P3 pixels to PNG. Uses Python's standard library only."""

import argparse
from pathlib import Path
import struct
import zlib


def read_ppm(path):
    tokens = []
    for line in path.read_text(encoding="ascii").splitlines():
        tokens.extend(line.partition("#")[0].split())
    if len(tokens) < 4 or tokens[0] != "P3" or tokens[3] != "255":
        raise ValueError(f"Expected a P3/255 image: {path}")
    width, height = map(int, tokens[1:3])
    pixels = bytes(map(int, tokens[4:]))
    if width <= 0 or height <= 0 or len(pixels) != width * height * 3:
        raise ValueError(f"Invalid pixel count: {path}")
    return width, height, pixels


def png_chunk(tag, data):
    return struct.pack(">I", len(data)) + tag + data + struct.pack(
        ">I", zlib.crc32(tag + data) & 0xFFFFFFFF
    )


def write_png(path, width, height, pixels, scale):
    rows = []
    for y in range(height):
        row = b"".join(
            pixels[(y * width + x) * 3:(y * width + x + 1) * 3] * scale
            for x in range(width)
        )
        rows.extend([b"\0" + row] * scale)
    header = struct.pack(">IIBBBBB", width * scale, height * scale, 8, 2, 0, 0, 0)
    path.write_bytes(
        b"\x89PNG\r\n\x1a\n" + png_chunk(b"IHDR", header)
        + png_chunk(b"IDAT", zlib.compress(b"".join(rows))) + png_chunk(b"IEND", b"")
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    args = parser.parse_args()
    for name in ("checker_source", "checker_target"):
        width, height, pixels = read_ppm(args.directory / f"{name}.ppm")
        write_png(args.directory / f"{name}.png", width, height, pixels, 1)
        preview = args.directory / f"{name}_6x.png"
        write_png(preview, width, height, pixels, 6)
        print(f"Preview: {preview}")


if __name__ == "__main__":
    main()
