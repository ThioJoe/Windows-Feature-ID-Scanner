#!/usr/bin/env python3
# analyze-images.py
# Reads the images of the resource data in the assets branch (icons/, cursors/, bitmaps/ and images/, not SVGs) for the site, which
# gets two things from it (derived/images.json):
#
# - samePixels: for each kind, the hash of every image that has the pixels of another with a smaller hash, mapped to the smallest.
#   scan-resources.py stores an image that's a PNG (or GIF, JPEG) in the executable as it is, and one that's a bitmap as a PNG it makes,
#   the same way each time. A PNG can be compressed again, or lose its metadata, with nothing in it changing: Edge's icons in 26300.9711
#   have the pixels of 26200.6899's in smaller files without their DPI chunk. Their hashes differ, so a comparison would count them as
#   changed; the site compares images by these instead.
# - light: for each kind, the hashes of the images that are almost all white (at least 90% of the pixels that aren't fully transparent
#   have a brightness of 245 or more), which the site shows on a darker checkerboard than the others.
#
# The images take a few seconds (about 22,000 icons and cursors, 9,000 others). It needs Pillow, which the site's workflow installs
# for it.
#
#   python scripts/analyze-images.py --assets <checkout of the assets branch's image folders> --out derived/images.json

import argparse
import collections
import hashlib
import json
import os
import sys

from PIL import Image, ImageChops

KINDS = ('icons', 'cursors', 'bitmaps', 'images')
EXTENSIONS = ('.png', '.gif', '.jpg')
LIGHT_LEVEL = 245  # Brightness (0-255) from which a pixel counts as white
LIGHT_SHARE = 0.9  # Share of the visible pixels that must be white


def main():
    parser = argparse.ArgumentParser(description="Find the resource data's images with the same pixels in different files, and the white ones.")
    parser.add_argument('--assets', required=True, help='A checkout of the assets branch (its icons/, cursors/, bitmaps/ and images/ are read)')
    parser.add_argument('--out', required=True, help='The JSON file to write')
    args = parser.parse_args()

    white = [255 if v >= LIGHT_LEVEL else 0 for v in range(256)]
    visible = [0] + [255] * 255
    same, light, total, errors = {}, {}, 0, []
    for kind in KINDS:
        groups, light[kind] = collections.defaultdict(list), []
        for folder, _, names in os.walk(os.path.join(args.assets, kind)):
            for name in names:
                stem, ext = os.path.splitext(name)
                if ext not in EXTENSIONS:
                    continue
                total += 1
                try:
                    with Image.open(os.path.join(folder, name)) as image:
                        pixels = image.convert('RGBA')
                except Exception as e:  # One file's problem shouldn't stop the rest: that image is compared by its file
                    errors.append('%s/%s: %s' % (kind, name, e))
                    continue
                groups[(pixels.size, hashlib.sha256(pixels.tobytes()).digest())].append(stem)
                shown = pixels.getchannel('A').point(visible)
                count = shown.histogram()[255]
                if count and ImageChops.multiply(shown, pixels.convert('L').point(white)).histogram()[255] >= LIGHT_SHARE * count:
                    light[kind].append(stem)
        same[kind] = {h: min(hashes) for hashes in groups.values() if len(hashes) > 1 for h in hashes if h != min(hashes)}
        light[kind].sort()
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, 'w', encoding='utf-8', newline='\n') as f:
        json.dump({'samePixels': same, 'light': light}, f, separators=(',', ':'), sort_keys=True)
    print('[images] %d images read, %d errors' % (total, len(errors)))
    for kind in KINDS:
        print('[images] %s: %d with the pixels of another, %d almost all white' % (kind, len(same[kind]), len(light[kind])))
    for e in errors[:20]:
        print('[images] ' + e)
    return 0


if __name__ == '__main__':
    sys.exit(main())
