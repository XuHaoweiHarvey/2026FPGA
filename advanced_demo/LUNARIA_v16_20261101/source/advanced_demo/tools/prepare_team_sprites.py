"""Prepare supplied pixel art and generate compact firmware sprites (Pillow).

--source-dir imports the five original reference images. Without it, regenerate
from the checked-in small PNGs. No board, Flash, RTL or background changes.
"""
import argparse
import hashlib
import json
from pathlib import Path
import struct

from PIL import Image, ImageDraw, ImageEnhance, ImageOps

ROOT = Path(__file__).resolve().parents[1]
ART = ROOT / "assets/team_sprites"
HEADER = ROOT / "software/interactive_demo/game_sprite_assets.h"
KEY = 0x00FF00FF
REFERENCES = {
    "player": "e7a76c556eb0d31b819f7f2d08ca467f.jpg",
    "enemy": "e9c0343a8e28b6b47206ed1a15eca800.png",
    "player_bullet": "ed4beeb6f0fb77c2c7a3063da6bf293a.jpg",
    "enemy_bullet": "3bfcf662f383233a6532f59fca761cdf.png",
    "explosion": "1a98282e469b737abdbdb8423cc7e556.jpg",
}
# Aligned source rectangles preserve the existing v6 atlas/DDR contract.
SLOTS = [("player", 64, 0, 32), ("enemy", 96, 0, 32),
         ("player_bullet", 128, 0, 16), ("enemy_bullet", 144, 0, 16)]
SLOTS += [(f"explosion_{i}", i * 32, 64, 32) for i in range(6)]


def argb(pixel):
    r, g, b, a = pixel
    return (a << 24) | (r << 16) | (g << 8) | b


def pixel_bytes(image):
    return b"".join(struct.pack("<I", argb(p)) for p in pixels_of(image))


def pixels_of(image):
    return image.get_flattened_data() if hasattr(image, "get_flattened_data") else image.getdata()


def remove_background(image, kind):
    image = image.convert("RGBA")
    pixels = []
    for r, g, b, unused in pixels_of(image):
        if kind == "white":
            clear = min(r, g, b) > 220 and max(r, g, b) - min(r, g, b) < 30
        elif kind == "blue":
            clear = b > r + 24 and g > r + 18
        else:
            clear = max(r, g, b) < 28
        pixels.append((0, 0, 0, 0) if clear else (r, g, b, 255))
    image.putdata(pixels)
    return image


def fit(image, size, margin=1):
    bounds = image.getbbox()
    if bounds is None:
        raise ValueError("Empty sprite after background removal")
    sprite = ImageOps.contain(image.crop(bounds), (size - margin * 2,) * 2,
                              Image.Resampling.NEAREST)
    tile = Image.new("RGBA", (size, size))
    tile.paste(sprite, ((size - sprite.width) // 2, (size - sprite.height) // 2))
    return tile


def quantize(image, color_key=False):
    """16 entries including transparent pixels; preserve real edge alpha."""
    source = image.convert("RGBA")
    # Separate opacity from color so invisible padding cannot consume colors.
    rgb = Image.new("RGB", image.size)
    rgb.paste(source.convert("RGB"))
    colors = rgb.quantize(colors=12, method=Image.Quantize.MEDIANCUT,
                          dither=Image.Dither.NONE).convert("RGB")
    out = Image.new("RGBA", image.size)
    rows = []
    for (r, g, b), (_, _, _, a) in zip(pixels_of(colors), pixels_of(source)):
        if not a:
            rows.append((255, 0, 255, 0) if color_key else (0, 0, 0, 0))
        else:
            # Binary opacity for Color Key; levels for hardware Alpha sprites.
            opacity = 255 if color_key or a >= 224 else 176 if a >= 128 else 88
            rows.append((r, g, b, opacity))
    out.putdata(rows)
    # RGB+alpha combinations may exceed 16; quantize RGBA together, reserving 0.
    if len(set(pixels_of(out))) > 16:
        visible = out.quantize(colors=15, method=Image.Quantize.FASTOCTREE,
                               dither=Image.Dither.NONE).convert("RGBA")
        values = []
        for original, reduced in zip(pixels_of(out), pixels_of(visible)):
            values.append(original if not original[3] else reduced)
        out.putdata(values)
    if len(set(pixels_of(out))) > 16:
        raise ValueError("Sprite needs more than 16 palette entries")
    return out


def import_references(folder):
    ART.mkdir(parents=True, exist_ok=True)
    provenance = {}
    for name, filename in REFERENCES.items():
        path = folder / filename
        provenance[name] = {"file": filename, "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
    for name in ("player", "enemy"):
        with Image.open(folder / REFERENCES[name]) as image:
            sprite = fit(remove_background(image, "white"), 32)
        if name == "enemy":
            opacity = sprite.getchannel("A")
            sprite = ImageEnhance.Brightness(sprite).enhance(1.55)
            sprite.putalpha(opacity)
            sprite = sprite.transpose(Image.Transpose.ROTATE_180)
        quantize(sprite, True).save(ART / (name + ".png"))
    for name in ("player_bullet", "enemy_bullet"):
        with Image.open(folder / REFERENCES[name]) as image:
            # Take the upper/main orb; the lower square is a reference swatch.
            image = image.crop((0, 0, image.width, image.height * 3 // 4))
            sprite = fit(remove_background(image, "black"), 16)
        pixels = []
        for r, g, b, a in pixels_of(sprite):
            brightness = max(r, g, b)
            pixels.append((r, g, b, 0 if not a else 112 if brightness < 120 else 255))
        sprite.putdata(pixels)
        quantize(sprite).save(ART / (name + ".png"))
    with Image.open(folder / REFERENCES["explosion"]) as image:
        for index in range(6):
            col, row = index % 3, index // 3
            cell = image.crop((col * 500, row * 600, (col + 1) * 500, (row + 1) * 600))
            sprite = fit(remove_background(cell, "blue"), 32)
            pixels = []
            for r, g, b, a in pixels_of(sprite):
                pixels.append((r, g, b, 0 if not a else 128 if max(r, g, b) < 80 else 255))
            sprite.putdata(pixels)
            quantize(sprite).save(ART / f"explosion_{index}.png")
    (ART / "sources.json").write_text(json.dumps(provenance, indent=2) + "\n", encoding="utf8")


def fnv(data):
    value = 2166136261
    for byte in data:
        value = ((value ^ byte) * 16777619) & 0xFFFFFFFF
    return value


def generate():
    text = ["/* Generated by tools/prepare_team_sprites.py; edit the small source PNGs. */",
            "#ifndef GAME_SPRITE_ASSETS_H", "#define GAME_SPRITE_ASSETS_H", "#include <stdint.h>",
            "#define GAME_TEAM_EXPLOSION_FRAMES 6u", "#define GAME_TEAM_EXPLOSION_SIZE 32u",
            "#define GAME_TEAM_EXPLOSION_DURATION_MS 420u",
            "#define GAME_TEAM_EXPLOSION_FRAME_MS (GAME_TEAM_EXPLOSION_DURATION_MS / GAME_TEAM_EXPLOSION_FRAMES)",
            "#define GAME_TEAM_ENEMY_BULLET_X 144u", "#define GAME_TEAM_EXPLOSION_Y 64u"]
    info, total = [], 0
    for name, x, y, size in SLOTS:
        with Image.open(ART / (name + ".png")) as image:
            image = image.convert("RGBA")
        if image.size != (size, size):
            raise ValueError(f"Wrong size for {name}")
        values = [argb(p) for p in pixels_of(image)]
        palette = sorted(set(values))
        if len(palette) > 16:
            raise ValueError(f"{name} has more than 16 colors")
        indices = [palette.index(p) for p in values]
        packed = [(indices[i] << 4) | indices[i + 1] for i in range(0, len(indices), 2)]
        text.append(f"static const uint32_t team_{name}_palette[] = {{")
        text.append("    " + ", ".join(f"UINT32_C(0x{v:08x})" for v in palette) + "\n};")
        text.append(f"static const uint8_t team_{name}_pixels[] = {{")
        text.extend("    " + ",".join(f"0x{v:02x}" for v in packed[i:i + 24]) + ","
                    for i in range(0, len(packed), 24))
        text.append("};")
        total += len(packed) + len(palette) * 4
        info.append(dict(name=name, x=x, y=y, size=size, colors=len(palette),
                         rgba_fnv1a=fnv(pixel_bytes(image))))
    text += ["typedef struct {", "    uint16_t x, y, size;",
             "    const uint32_t *palette;", "    const uint8_t *pixels;", "} game_team_sprite_t;",
             "static const game_team_sprite_t game_team_sprites[] = {"]
    for name, x, y, size in SLOTS:
        text.append(f"    {{{x}u, {y}u, {size}u, team_{name}_palette, team_{name}_pixels}},")
    text += ["};", f"#define GAME_TEAM_SPRITE_COUNT {len(SLOTS)}u",
             f"#define GAME_TEAM_PACKED_BYTES {total}u",
             "static inline uint32_t game_team_sprite_pixel(uint32_t x, uint32_t y) {",
             "    uint32_t i;",
             f"    if (x >= {max(x+s for _, x, _, s in SLOTS)}u || y >= {max(y+s for _, _, y, s in SLOTS)}u)",
             "        return UINT32_C(0x00ff00ff);",
             "    for (i = 0u; i < GAME_TEAM_SPRITE_COUNT; ++i) {",
             "        const game_team_sprite_t *s = &game_team_sprites[i];",
             "        if (x >= s->x && x - s->x < s->size && y >= s->y && y - s->y < s->size) {",
             "            uint32_t offset = (y - s->y) * s->size + x - s->x;",
             "            uint32_t pair = s->pixels[offset >> 1];",
             "            return s->palette[(offset & 1u) ? pair & 15u : pair >> 4];", "        }", "    }",
             "    return UINT32_C(0x00ff00ff);", "}",
             "static inline uint32_t game_team_explosion_frame(uint32_t now, uint32_t expires) {",
             "    uint32_t remaining = expires - now;",
             "    if ((int32_t)remaining <= 0) return GAME_TEAM_EXPLOSION_FRAMES;",
             "    return remaining >= GAME_TEAM_EXPLOSION_DURATION_MS ? 0u :",
             "        (GAME_TEAM_EXPLOSION_DURATION_MS - remaining) / GAME_TEAM_EXPLOSION_FRAME_MS;", "}",
             "static inline uint32_t game_team_explosion_alpha(uint32_t now, uint32_t expires) {",
             "    uint32_t remaining = expires - now;",
             "    if ((int32_t)remaining <= 0) return 0u;",
             "    return remaining >= GAME_TEAM_EXPLOSION_DURATION_MS ? 255u :",
             "        remaining * 255u / GAME_TEAM_EXPLOSION_DURATION_MS;", "}",
             "#endif", ""]
    return "\n".join(text), dict(packed_bytes=total, sprites=info)


def previews():
    canvas = Image.new("RGBA", (800, 360), (7, 16, 28, 255))
    draw = ImageDraw.Draw(canvas)
    draw.text((20, 12), "TEAM SPRITES / ACTUAL SMALL PNGs / 4x NEAREST PREVIEW", fill="white")
    for i, (name, x, y, size) in enumerate(SLOTS):
        with Image.open(ART / (name + ".png")) as image:
            image = image.convert("RGBA").resize((size * 4, size * 4), Image.Resampling.NEAREST)
        px, py = 20 + (i % 5) * 155, 50 + (i // 5) * 155
        canvas.alpha_composite(image, (px, py))
        draw.text((px, py + 130), name, fill=(190, 210, 235))
    canvas.convert("RGB").save(ART / "preview.png")
    frames = []
    for i in range(6):
        frame = Image.new("RGBA", (160, 160), (7, 16, 28, 255))
        with Image.open(ART / f"explosion_{i}.png") as image:
            image = image.convert("RGBA").resize((128, 128), Image.Resampling.NEAREST)
            image.putalpha(image.getchannel("A").point(lambda a: a * (6-i) // 6))
            frame.alpha_composite(image, (16, 16))
        frames.append(frame.convert("RGB"))
    frames[0].save(ART / "explosion_preview.gif", save_all=True, append_images=frames[1:],
                   duration=70, loop=0, disposal=2)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-dir", type=Path)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    if args.source_dir:
        if args.check:
            parser.error("--check does not import references")
        import_references(args.source_dir)
    header, info = generate()
    if args.check:
        if HEADER.read_text(encoding="utf8") != header:
            raise SystemExit("Generated header differs from source PNGs")
        print("PASS compact C header matches all 10 source PNGs")
    else:
        HEADER.write_text(header, encoding="utf8")
        (ART / "manifest.json").write_text(json.dumps(info, indent=2) + "\n", encoding="utf8")
        previews()
        print(f"Prepared 10 sprites, {info['packed_bytes']} packed bytes plus descriptors")


if __name__ == "__main__":
    main()
