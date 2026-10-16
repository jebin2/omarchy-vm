#!/usr/bin/env python3
"""Generate the Dragon Ball Z theme backgrounds.

Two techniques:
  * mesh    -- a tiny hex grid upscaled through a Gaussian filter, for calm fields.
  * burst   -- random vertical stripes bent into rays with -distort Polar, masked
               by a radial falloff, for power-up auras.
"""
import os, subprocess, sys, tempfile

W, H = 3840, 2400
OUT = sys.argv[1] if len(sys.argv) > 1 else "backgrounds"
os.makedirs(OUT, exist_ok=True)
run = lambda *a: subprocess.run(list(a), check=True)


def tmp(ext=".png"):
    f = tempfile.NamedTemporaryFile(suffix=ext, delete=False)
    f.close()
    return f.name


def mesh(grid, blur=90):
    """Smooth colour field from a small grid of hex values."""
    rows, cols = len(grid), len(grid[0])
    lines = ["# ImageMagick pixel enumeration: %d,%d,255,srgb" % (cols, rows)]
    for y in range(rows):
        for x in range(cols):
            h = grid[y][x].lstrip("#")
            lines.append("%d,%d: (%d,%d,%d)" % (x, y, int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16)))
    src, dst = tmp(".txt"), tmp()
    open(src, "w").write("\n".join(lines) + "\n")
    run("magick", src, "-filter", "Gaussian", "-define", "filter:blur=1.7",
        "-resize", "%dx%d!" % (W, H), "-blur", "0x%d" % blur, "PNG24:" + dst)
    os.unlink(src)
    return dst


def burst(cx, cy, disc, dark, bright, gamma=0.45, seed=None):
    """Radial rays centred on (cx, cy) as a fraction of the canvas.

    `disc` is the ray disc's diameter in px; it is deliberately larger than the
    canvas so its hard circular edge never enters frame.
    """
    stripes, rays, mask, out = tmp(), tmp(), tmp(), tmp()
    args = ["magick", "-size", "900x1", "xc:"]
    if seed is not None:
        args += ["-seed", str(seed)]
    run(*(args + ["+noise", "Random", "-colorspace", "Gray", "-blur", "0x3",
                  "-auto-level", "-resize", "%dx1!" % disc,
                  "-resize", "%dx%d!" % (disc, disc), stripes]))
    run("magick", stripes, "-virtual-pixel", "horizontal-tile", "-distort", "Polar", "0", rays)
    # Falloff: bright at the core, gone before the disc edge.
    run("magick", "-size", "%dx%d" % (disc, disc), "radial-gradient:white-black",
        "-gamma", str(gamma), mask)
    run("magick", rays, mask, "-compose", "multiply", "-composite",
        "+level-colors", "%s,%s" % (dark, bright), out)
    # Crop the canvas out of the disc so the centre lands where we asked.
    ox, oy = int(disc / 2 - W * cx), int(disc / 2 - H * cy)
    cropped = tmp()
    run("magick", out, "-crop", "%dx%d+%d+%d" % (W, H, ox, oy), "+repage", cropped)
    for f in (stripes, rays, mask, out):
        os.unlink(f)
    return cropped


def orb(cx, cy, size, dark, bright, gamma=0.35):
    """A soft glowing sphere of ki."""
    g, out = tmp(), tmp()
    run("magick", "-size", "%dx%d" % (size, size), "radial-gradient:white-black",
        "-gamma", str(gamma), "+level-colors", "%s,%s" % (dark, bright), g)
    run("magick", "-size", "%dx%d" % (W, H), "xc:black", g,
        "-geometry", "+%d+%d" % (int(W * cx - size / 2), int(H * cy - size / 2)),
        "-compose", "screen", "-composite", out)
    os.unlink(g)
    return out


def finish(layers, name, sat="100,115,100", grain=0.5):
    """Screen the layers together, grain, save as jpg."""
    cur = layers[0]
    for extra in layers[1:]:
        nxt = tmp()
        run("magick", cur, extra, "-compose", "screen", "-composite", nxt)
        cur = nxt
    noise = tmp()
    run("magick", "-size", "%dx%d" % (W, H), "xc:gray50", "-attenuate", str(grain),
        "+noise", "Gaussian", "-colorspace", "Gray", "PNG24:" + noise)
    dst = os.path.join(OUT, name)
    run("magick", cur, noise, "-compose", "overlay", "-composite",
        "-modulate", sat, "-quality", "93", dst)
    print("  ->", dst)


print("1/4 super-saiyan")
finish([mesh([["#0d0a08", "#151009", "#1b140b", "#151009", "#0d0a08"],
              ["#100c09", "#1e160c", "#2a1e0e", "#1e160c", "#100c09"],
              ["#161009", "#2c1f0e", "#43300f", "#2c1f0e", "#161009"],
              ["#0d0a08", "#171009", "#20170b", "#171009", "#0d0a08"]]),
        burst(0.5, 0.72, 6400, "#000000", "#9a5f0d", gamma=0.30, seed=7),
        orb(0.5, 0.72, 2800, "#000000", "#d69a30", gamma=0.26)],
       "1-super-saiyan.jpg", sat="100,120,100")

print("2/4 kamehameha")
finish([mesh([["#05070c", "#060910", "#070b16", "#060910", "#05070c"],
              ["#060910", "#0a1526", "#102640", "#0a1526", "#060910"],
              ["#081120", "#123046", "#1d5f8f", "#123046", "#081120"],
              ["#05070c", "#070b14", "#0a1220", "#070b14", "#05070c"]]),
        burst(0.62, 0.5, 6400, "#000000", "#1d5f92", gamma=0.40, seed=13),
        orb(0.62, 0.5, 2200, "#000000", "#78bce8", gamma=0.28)],
       "2-kamehameha.jpg", sat="100,125,100")

print("3/4 namek-sky")
finish([mesh([["#0a1410", "#0f2016", "#16301c", "#12261a", "#0a1410"],
              ["#0d1c13", "#1b3f24", "#2c6636", "#1e4628", "#0d1c13"],
              ["#0b1711", "#14301b", "#204925", "#16341d", "#0b1711"],
              ["#070f0c", "#0a170f", "#0d1e13", "#0a170f", "#070f0c"]])],
       "3-namek-sky.jpg", sat="100,118,100")

print("4/4 ki-charge")
finish([mesh([["#0a0806", "#0f0b08", "#130e09", "#0f0b08", "#0a0806"],
              ["#0e0a07", "#20150c", "#33210e", "#20150c", "#0e0a07"],
              ["#130d08", "#3a2410", "#6b3d13", "#3a2410", "#130d08"],
              ["#0a0806", "#120c08", "#1a110a", "#120c08", "#0a0806"]]),
        orb(0.5, 0.60, 3600, "#000000", "#8a4a14", gamma=0.32)],
       "4-ki-charge.jpg", sat="100,122,100")
