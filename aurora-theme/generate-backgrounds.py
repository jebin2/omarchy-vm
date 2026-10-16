import subprocess, tempfile, os, sys
W, H = 3840, 2400
OUT = sys.argv[1]

def mesh(name, cols, rows, grid, blur=90):
    lines = ["# ImageMagick pixel enumeration: %d,%d,255,srgb" % (cols, rows)]
    for y in range(rows):
        for x in range(cols):
            h = grid[y][x].lstrip('#')
            r, g, b = int(h[0:2],16), int(h[2:4],16), int(h[4:6],16)
            lines.append("%d,%d: (%d,%d,%d)" % (x, y, r, g, b))
    f = tempfile.NamedTemporaryFile('w', suffix='.txt', delete=False)
    f.write("\n".join(lines) + "\n"); f.close()
    dst = os.path.join(OUT, name)
    subprocess.run(["magick", f.name, "-filter", "Gaussian", "-define", "filter:blur=1.7",
                    "-resize", "%dx%d!" % (W, H), "-blur", "0x%d" % blur, "PNG24:" + dst], check=True)
    os.unlink(f.name)
    return dst

def grain(path, amount=0.5):
    noise = path + ".noise.png"
    subprocess.run(["magick", "-size", "%dx%d" % (W, H), "xc:gray50",
                    "-attenuate", str(amount), "+noise", "Gaussian",
                    "-colorspace", "Gray", "PNG24:" + noise], check=True)
    subprocess.run(["magick", path, noise, "-compose", "overlay", "-composite",
                    "PNG24:" + path], check=True)
    os.unlink(noise)

# 1 — aurora drift: teal->violet diagonal bloom over deep midnight
mesh("1-aurora-drift.png", 6, 4, [
 ["#0a0e1c","#12224a","#1d4a78","#2a5f8c","#17304f","#0a0e1c"],
 ["#0b1024","#1c3f6e","#3f86b8","#5aa8cf","#2b4a7a","#0c1122"],
 ["#090c18","#14203f","#3a3070","#6a4fa8","#2a2350","#0a0d1a"],
 ["#06080f","#080b16","#0c1020","#10142a","#090c17","#06080f"]])

# 2 — aurora ridge: one luminous band low on a near-black field
mesh("2-aurora-ridge.png", 5, 5, [
 ["#06080f","#070a13","#080b16","#070a13","#06080f"],
 ["#070a14","#0a1020","#0d1830","#0a1224","#070a14"],
 ["#0a1526","#1a4a6e","#4fb0d8","#2a6a96","#0c1a2e"],
 ["#0d1830","#2e2f6a","#7d63c8","#3a3576","#0e1630"],
 ["#06080f","#080b18","#0b0f22","#080b18","#06080f"]])

# 3 — aurora void: minimal, one soft corner glow
mesh("3-aurora-void.png", 4, 3, [
 ["#12305a","#0b1728","#070a14","#06080f"],
 ["#0a1424","#080d1a","#06080f","#06080f"],
 ["#070a13","#06080f","#05070c","#05070c"]])

# 4 — aurora bloom: violet-heavy, centred
mesh("4-aurora-bloom.png", 5, 4, [
 ["#06080f","#0a0e20","#101538","#0a0e20","#06080f"],
 ["#090d1c","#1e2456","#4a3f9a","#1f2558","#090d1c"],
 ["#080b18","#23386e","#5a8fd0","#24396f","#080b18"],
 ["#06080f","#080b16","#0b1226","#080b16","#06080f"]])

for n in sorted(os.listdir(OUT)):
    if not n.endswith(".png"):
        continue
    p = os.path.join(OUT, n)
    grain(p, 0.5)
    # Lift saturation so the teal/violet separate after the heavy blur.
    sat = "100,125,100" if "void" in n else "102,138,100"
    args = ["magick", p, "-modulate", sat]
    if "void" not in n:
        args += ["-sigmoidal-contrast", "2x40%"]
    args += ["-quality", "93", p[:-4] + ".jpg"]
    subprocess.run(args, check=True)
    os.unlink(p)
print("done")
