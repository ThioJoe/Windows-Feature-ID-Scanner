# scan-resources.py
# Records what a Windows build's files hold besides code, so builds can be compared by their icons, UI text, APIs, policies and so on.
# It only reads files: it runs against a Windows installation that isn't running, such as the VM's disk mounted on the runner after
# the scan.
#
# What it records, for each version of a file it hasn't seen in an earlier build (files are identified by their SHA-256):
#   Executables (DLL, EXE, SYS, the .mun files in SystemResources that hold system binaries' resources, en-US .mui files, visual
#   styles): the PE timestamp and image size (what the symbol server files a binary under), the file version, the exports, and a
#   hash of every resource. From the resources: icons, cursors, bitmaps and images (converted to PNG where they aren't PNG already,
#   and named by the hash of the original data), string tables, message tables, and dialog and menu text.
#   WinRT metadata (.winmd): its types and their members.
#   Fonts (Segoe Fluent Icons, Segoe MDL2 Assets, Segoe UI Emoji, Segoe UI Variable): the files, and a hash of each character's glyph.
#   Cursors (Windows\Cursors): each frame as PNG, with hotspots and timing.
#   Whole files: the shell's UI files (SystemApps, ShellExperiences, ImmersiveControlPanel, ShellComponents, SystemResources: images,
#   SVGs, Lottie and other JSON, web app files, compiled XAML, .pri, videos), Group Policy templates, wallpapers, sounds, themes,
#   PowerShell's inbox modules, servicing package manifests and scheduled tasks.
#   Registry (the SOFTWARE and SYSTEM hives): MDM/CSP policy definitions, services, ETW providers and WinRT activatable classes.
#
# Everything goes into a folder laid out like the repository's assets branch, where everything is stored once, by hash:
#   icons/<W>x<H>/<h>/<hash>.png, cursors/..., bitmaps/..., images/<W>x<H>/<h>/<hash>.<ext> (images/svg/... for SVGs),
#   files/<kind>/<h>/<hash><ext>, meta/<hh>/<hash>.json (what was read from a file version), registry/<hh>/<hash>.json,
#   builds/<build>/files.csv.gz (every file of the build: path, size, hash) and builds/<build>/index.json.gz (each file this script
#   reads, with the hashes of what it found in it, which is what comparing two builds starts from).
# <hash> is the first 16 hex digits of the SHA-256 of the original data, <h> its first digit and <hh> its first two.
#
#   python scripts/scan-resources.py --root F:\ --build 26300.10075-AMD64 --out <folder> [--inventory files.csv.gz] [--known known.txt]
#     --inventory   the file list the VM's check wrote (verify-windows-files.py --inventory), for builds/<build>/files.csv.gz
#     --known       the paths the assets branch has already (git ls-tree -r --name-only), which aren't written again

import argparse
import collections
import csv
import gzip
import hashlib
import io
import json
import mmap
import os
import re
import struct
import sys
import time
import zlib

def log(msg):
    print('[resources %s] %s' % (time.strftime('%H:%M:%S'), msg), flush=True)

def h16(data):
    return hashlib.sha256(data).hexdigest()[:16]

def digest(obj):
    """The hash of a JSON value, for comparing what two versions of a file hold"""
    return h16(json.dumps(obj, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode('utf-8'))

def file_sha256(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for block in iter(lambda: f.read(1 << 20), b''):
            h.update(block)
    return h.hexdigest()

# ---------------------------------------------------------------------------
# The output: new objects in the assets branch's layout
# ---------------------------------------------------------------------------

class Store:
    def __init__(self, out_dir, known):
        self.root = os.path.join(out_dir, 'assets')
        self.known = known  # Paths the assets branch has already
        self.written = set()
        self.counts = collections.Counter()
        self.bytes = collections.Counter()

    def has(self, path):
        return path in self.known or path in self.written

    def put(self, path, data, replace=False):
        """Writes data at path unless the branch has it already (or replace: a build's own files, which a rescan replaces). Returns
        the path."""
        if replace or not self.has(path):
            full = os.path.join(self.root, *path.split('/'))
            os.makedirs(os.path.dirname(full), exist_ok=True)
            # Written under a name of its own, then renamed: worker processes can find the same new image at the same time
            temp = '%s.%d.tmp' % (full, os.getpid())
            with open(temp, 'wb') as f:
                f.write(data)
            try:
                os.replace(temp, full)
            except PermissionError:
                # Windows refuses while another process replaces the same file, whose content is the same (it's named by it)
                if not os.path.exists(full) or replace:
                    raise
                os.remove(temp)
                return path
            self.written.add(path)
            kind = path.split('/', 1)[0]
            self.counts[kind] += 1
            self.bytes[kind] += len(data)
        return path

    def put_json(self, path, obj):
        if self.has(path):
            return path
        return self.put(path, json.dumps(obj, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode('utf-8'))

def meta_path(hash_):
    return 'meta/%s/%s.json' % (hash_[:2], hash_)

def part_path(hash_):
    return 'parts/%s/%s.json' % (hash_[:2], hash_)

def store_record(store, hash_, info, parts):
    """Stores what was read from a file version: each of its parts (exports, icons, strings, ...) on its own, named by its hash, so a
    part that a new version of the file has unchanged isn't stored again, and the rest (name, timestamp, version, ...) with the
    hashes of the parts in meta/. Returns the meta path and the parts' hashes."""
    header, digests = {}, {}
    for key, value in info.items():
        if key in parts:
            if value:
                digests[key] = digest(value)
                store.put_json(part_path(digests[key]), value)
        else:
            header[key] = value
    header['parts'] = digests
    return store.put_json(meta_path(hash_), header), digests

def image_path(kind, width, height, hash_, ext):
    return '%s/%dx%d/%s/%s.%s' % (kind, width, height, hash_[0], hash_, ext)

# ---------------------------------------------------------------------------
# Images: PNG writing, and Windows bitmaps (DIBs) to RGBA
# ---------------------------------------------------------------------------

PNG_SIGNATURE = b'\x89PNG\r\n\x1a\n'

def png_from_rows(width, height, rows):
    """A PNG (8-bit RGBA) from top-down rows of RGBA bytes"""
    def chunk(tag, data):
        return struct.pack('>I', len(data)) + tag + data + struct.pack('>I', zlib.crc32(tag + data) & 0xFFFFFFFF)
    raw = b''.join(b'\x00' + bytes(row) for row in rows)
    return (PNG_SIGNATURE + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0)) +
            chunk(b'IDAT', zlib.compress(raw, 9)) + chunk(b'IEND', b''))

def image_info(data):
    """(extension, width, height) of a PNG, GIF or JPEG, or None"""
    if data[:8] == PNG_SIGNATURE and len(data) >= 24:
        w, h = struct.unpack_from('>II', data, 16)
        return 'png', w, h
    if data[:6] in (b'GIF87a', b'GIF89a') and len(data) >= 10:
        w, h = struct.unpack_from('<HH', data, 6)
        return 'gif', w, h
    if data[:3] == b'\xFF\xD8\xFF':
        p = 2
        while p + 9 < len(data):
            if data[p] != 0xFF:
                p += 1
                continue
            marker = data[p + 1]
            if marker in (0xD8, 0x01) or 0xD0 <= marker <= 0xD7:
                p += 2
                continue
            length = struct.unpack_from('>H', data, p + 2)[0]
            if 0xC0 <= marker <= 0xCF and marker not in (0xC4, 0xC8, 0xCC):
                h, w = struct.unpack_from('>HH', data, p + 5)
                return 'jpg', w, h
            p += 2 + length
        return 'jpg', 0, 0
    return None

def png_rgba_size(data):
    """Width, height and bits per pixel of a PNG"""
    w, h, depth, color = struct.unpack_from('>IIBB', data, 16)
    channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}.get(color, 4)
    return w, h, depth * channels

def _rows_from_dib(data, width, height, bits, compression, palette, masks, pixel_offset, top_down):
    """Top-down RGBA rows (bytearrays) of a DIB's color data, with alpha 255 except for 32-bit pixels"""
    rows = []
    stride = ((width * bits + 31) // 32) * 4
    if compression in (1, 2):  # BI_RLE8, BI_RLE4: decode into 8-bit indices first
        indices = _decode_rle(data[pixel_offset:], width, height, 8 if compression == 1 else 4)
        stride, bits, source = width, 8, indices
        src_offset = 0
    else:
        source, src_offset = data, pixel_offset
    if bits <= 8:
        table_r = bytes(p[0] for p in palette) + bytes(256 - len(palette))
        table_g = bytes(p[1] for p in palette) + bytes(256 - len(palette))
        table_b = bytes(p[2] for p in palette) + bytes(256 - len(palette))
    for y in range(height):
        row_index = y if top_down else height - 1 - y
        start = src_offset + row_index * stride
        raw = source[start:start + stride]
        if len(raw) < stride:
            raw = bytes(raw) + bytes(stride - len(raw))
        out = bytearray(width * 4)
        if bits == 32:
            if masks and masks[:3] != (0xFF0000, 0xFF00, 0xFF):
                px = struct.unpack_from('<%dI' % width, raw)
                for x, v in enumerate(px):
                    out[4 * x:4 * x + 4] = bytes((_mask_value(v, masks[0]), _mask_value(v, masks[1]), _mask_value(v, masks[2]),
                                                  _mask_value(v, masks[3]) if len(masks) > 3 and masks[3] else 255))
            else:
                out[0::4] = raw[2:width * 4:4]
                out[1::4] = raw[1:width * 4:4]
                out[2::4] = raw[0:width * 4:4]
                out[3::4] = raw[3:width * 4:4]
        elif bits == 24:
            out[0::4] = raw[2:width * 3:3]
            out[1::4] = raw[1:width * 3:3]
            out[2::4] = raw[0:width * 3:3]
            out[3::4] = b'\xFF' * width
        elif bits == 16:
            m = masks or (0x7C00, 0x03E0, 0x001F)
            px = struct.unpack_from('<%dH' % width, raw)
            for x, v in enumerate(px):
                out[4 * x:4 * x + 4] = bytes((_mask_value(v, m[0]), _mask_value(v, m[1]), _mask_value(v, m[2]), 255))
        elif bits == 8:
            line = bytes(raw[:width])
            out[0::4] = line.translate(table_r)
            out[1::4] = line.translate(table_g)
            out[2::4] = line.translate(table_b)
            out[3::4] = b'\xFF' * width
        elif bits in (4, 2, 1):
            per_byte = 8 // bits
            mask = (1 << bits) - 1
            indices = bytearray(width)
            for x in range(width):
                byte = raw[x // per_byte]
                shift = 8 - bits * (x % per_byte + 1)
                indices[x] = (byte >> shift) & mask
            line = bytes(indices)
            out[0::4] = line.translate(table_r)
            out[1::4] = line.translate(table_g)
            out[2::4] = line.translate(table_b)
            out[3::4] = b'\xFF' * width
        else:
            raise ValueError('%d bits per pixel' % bits)
        rows.append(out)
    return rows

def _mask_value(value, mask):
    if not mask:
        return 0
    shift = (mask & -mask).bit_length() - 1
    top = mask >> shift
    return ((value & mask) >> shift) * 255 // top if top else 0

def _decode_rle(data, width, height, bits):
    """BI_RLE8/BI_RLE4 to bottom-up rows of 8-bit indices"""
    out = bytearray(width * height)
    x = y = p = 0
    while p + 1 < len(data) and y < height:
        count, value = data[p], data[p + 1]
        p += 2
        if count:
            for i in range(count):
                if x < width:
                    out[y * width + x] = value if bits == 8 else ((value >> 4) if i % 2 == 0 else (value & 0x0F))
                x += 1
        elif value == 0:
            x, y = 0, y + 1
        elif value == 1:
            break
        elif value == 2:
            if p + 1 >= len(data):
                break
            x += data[p]
            y += data[p + 1]
            p += 2
        else:
            for i in range(value):
                if bits == 8:
                    v = data[p + i] if p + i < len(data) else 0
                else:
                    b = data[p + i // 2] if p + i // 2 < len(data) else 0
                    v = (b >> 4) if i % 2 == 0 else (b & 0x0F)
                if x < width:
                    out[y * width + x] = v
                x += 1
            used = value if bits == 8 else (value + 1) // 2
            p += used + (used % 2)
    return bytes(out)

def dib_to_png(data, icon=False):
    """A DIB (an icon or cursor image, or a bitmap resource) as (png, width, height, bits per pixel). Icon images are twice as high as
    they are, for the AND mask that follows the colors, which gives transparency unless 32-bit colors have alpha of their own."""
    header_size = struct.unpack_from('<I', data, 0)[0]
    if header_size == 12:
        width, height, _, bits = struct.unpack_from('<HHHH', data, 4)
        compression, colors_used, palette_entry = 0, 0, 3
    else:
        width, height, _, bits, compression = struct.unpack_from('<iiHHI', data, 4)
        colors_used = struct.unpack_from('<I', data, 32)[0] if header_size >= 36 else 0
        palette_entry = 4
    top_down = height < 0
    height = abs(height)
    if icon:
        height //= 2
    if width <= 0 or height <= 0 or width > 16384 or height > 16384:
        raise ValueError('bad size %dx%d' % (width, height))
    offset = header_size
    masks = None
    if compression == 3 or compression == 6:  # BI_BITFIELDS, BI_ALPHABITFIELDS
        if header_size >= 52:
            masks = struct.unpack_from('<IIII' if header_size >= 56 else '<III', data, 40)
        else:
            count = 4 if compression == 6 else 3
            masks = struct.unpack_from('<%dI' % count, data, offset)
            offset += 4 * count
    elif compression not in (0, 1, 2):
        raise ValueError('compression %d' % compression)
    palette = []
    if bits <= 8:
        count = colors_used or (1 << bits)
        for i in range(count):
            b, g, r = data[offset + i * palette_entry:offset + i * palette_entry + 3]
            palette.append((r, g, b))
        offset += count * palette_entry
    rows = _rows_from_dib(data, width, height, bits, compression, palette, masks, offset, top_down)
    # 32-bit pixels whose alpha is all zero don't use it (older images): they're opaque, as other bit depths are
    alpha_used = bits == 32 and any(row[3::4].strip(b'\x00') for row in rows)
    if bits == 32 and not alpha_used:
        for row in rows:
            row[3::4] = b'\xFF' * width
    if icon and not alpha_used and compression == 0:
        # The AND mask: 1 bit per pixel, bottom-up, set where the image is transparent
        mask_offset = offset + ((width * bits + 31) // 32) * 4 * height
        mask_stride = ((width + 31) // 32) * 4
        for y in range(height):
            start = mask_offset + (height - 1 - y) * mask_stride
            line = data[start:start + mask_stride]
            if not line.strip(b'\x00'):
                continue
            row = rows[y]
            for x in range(min(width, len(line) * 8)):
                if line[x // 8] & (0x80 >> (x % 8)):
                    row[4 * x + 3] = 0
    return png_from_rows(width, height, rows), width, height, bits

# ---------------------------------------------------------------------------
# PE files
# ---------------------------------------------------------------------------

MACHINES = {0x14C: 'x86', 0x8664: 'AMD64', 0xAA64: 'ARM64', 0x1C4: 'ARM', 0xA641: 'ARM64EC', 0xA64E: 'ARM64X', 0: 'none'}
RT = {1: 'cursor', 2: 'bitmap', 3: 'icon', 4: 'menu', 5: 'dialog', 6: 'string', 7: 'fontdir', 8: 'font', 9: 'accelerator', 10: 'rcdata',
      11: 'messagetable', 12: 'groupcursor', 14: 'groupicon', 16: 'version', 17: 'dlginclude', 19: 'plugplay', 20: 'vxd',
      21: 'anicursor', 22: 'aniicon', 23: 'html', 24: 'manifest'}

class NotPe(ValueError):
    pass

class Pe:
    def __init__(self, data):
        self.data = data
        if data[:2] != b'MZ' or len(data) < 0x40:
            raise NotPe('not an MZ file')
        pe = struct.unpack_from('<I', data, 0x3C)[0]
        if data[pe:pe + 4] != b'PE\0\0':
            raise NotPe('not a PE file (16-bit, or not an executable)')
        self.machine, sections, self.timestamp = struct.unpack_from('<HHI', data, pe + 4)
        opt_size = struct.unpack_from('<H', data, pe + 20)[0]
        opt = pe + 24
        magic = struct.unpack_from('<H', data, opt)[0]
        if magic == 0x20B:
            dirs = opt + 112
        elif magic == 0x10B:
            dirs = opt + 96
        else:
            raise ValueError('optional header magic %#x' % magic)
        self.image_size = struct.unpack_from('<I', data, opt + 56)[0]
        count = struct.unpack_from('<I', data, dirs - 4)[0]
        self.dirs = [struct.unpack_from('<II', data, dirs + 8 * i) for i in range(min(count, 16))]
        self.sections = []
        for i in range(sections):
            vsize, va, raw_size, raw_ptr = struct.unpack_from('<IIII', data, opt + opt_size + 40 * i + 8)
            self.sections.append((va, max(vsize, raw_size), raw_size, raw_ptr))

    def offset(self, rva):
        for va, vsize, raw_size, raw_ptr in self.sections:
            if va <= rva < va + vsize:
                return raw_ptr + (rva - va) if rva - va < raw_size else None
        return rva if not self.sections and rva < len(self.data) else None

    def read(self, rva, size):
        off = self.offset(rva)
        if off is None:
            return b''
        return self.data[off:off + size]

    def directory(self, index):
        return self.dirs[index] if index < len(self.dirs) else (0, 0)

    def cstring(self, rva, limit=1024):
        off = self.offset(rva)
        if off is None:
            return ''
        end = self.data.find(b'\0', off, off + limit)
        return bytes(self.data[off:end if end >= 0 else off + limit]).decode('latin-1')

    def exports(self):
        rva, size = self.directory(0)
        if not rva or not size:
            return [], 0
        head = self.read(rva, 40)
        if len(head) < 40:
            return [], 0
        functions, names, functions_rva, names_rva, ordinals_rva = struct.unpack_from('<IIIII', head, 20)
        names = min(names, 65536)
        name_list = []
        named = set()
        name_rvas = self.read(names_rva, 4 * names)
        ordinals = self.read(ordinals_rva, 2 * names)
        for i in range(min(len(name_rvas) // 4, len(ordinals) // 2)):
            name_list.append(self.cstring(struct.unpack_from('<I', name_rvas, 4 * i)[0]))
            named.add(struct.unpack_from('<H', ordinals, 2 * i)[0])
        addresses = self.read(functions_rva, 4 * min(functions, 65536))
        unnamed = sum(1 for i in range(len(addresses) // 4) if i not in named and struct.unpack_from('<I', addresses, 4 * i)[0])
        return sorted(name_list), unnamed

    def resources(self):
        """Every resource: (type, name, language, data rva, size); type and name are ints or strings"""
        rva, size = self.directory(2)
        base = self.offset(rva) if rva else None
        if base is None:
            return []
        data = self.data
        out = []

        def entries(off):
            if off + 16 > len(data):
                return []
            named, ids = struct.unpack_from('<HH', data, off + 12)
            result = []
            for i in range(min(named + ids, 65536)):
                p = off + 16 + 8 * i
                if p + 8 > len(data):
                    break
                name, target = struct.unpack_from('<II', data, p)
                if name & 0x80000000:
                    q = base + (name & 0x7FFFFFFF)
                    length = struct.unpack_from('<H', data, q)[0]
                    name = bytes(data[q + 2:q + 2 + 2 * length]).decode('utf-16-le', 'replace')
                else:
                    name &= 0xFFFF
                result.append((name, target))
            return result

        for type_, t in entries(base):
            if not t & 0x80000000:
                continue
            for name, n in entries(base + (t & 0x7FFFFFFF)):
                if not n & 0x80000000:
                    continue
                for lang, leaf in entries(base + (n & 0x7FFFFFFF)):
                    if leaf & 0x80000000:
                        continue
                    p = base + leaf
                    if p + 8 > len(data):
                        continue
                    data_rva, data_size = struct.unpack_from('<II', data, p)
                    out.append((type_, name, lang, data_rva, data_size))
        return out

    def winmd(self):
        rva, size = self.directory(14)
        return bool(rva and size)

def key_of(value):
    return str(value)

# ---------------------------------------------------------------------------
# Resource formats
# ---------------------------------------------------------------------------

def read_sz(data, p):
    """A null-terminated UTF-16 string and the offset after it"""
    end = p
    while end + 1 < len(data) and (data[end] or data[end + 1]):
        end += 2
    return bytes(data[p:end]).decode('utf-16-le', 'replace'), end + 2

def read_sz_or_ord(data, p):
    first = struct.unpack_from('<H', data, p)[0] if p + 2 <= len(data) else 0
    if first == 0:
        return None, p + 2
    if first == 0xFFFF:
        return '#%d' % struct.unpack_from('<H', data, p + 2)[0], p + 4
    return read_sz(data, p)

def align4(p):
    return (p + 3) & ~3

def string_table(block, data):
    out = {}
    p = 0
    for i in range(16):
        if p + 2 > len(data):
            break
        length = struct.unpack_from('<H', data, p)[0]
        p += 2
        if length:
            out[(block - 1) * 16 + i] = bytes(data[p:p + 2 * length]).decode('utf-16-le', 'replace')
            p += 2 * length
    return out

def message_table(data):
    out = {}
    blocks = struct.unpack_from('<I', data, 0)[0]
    for b in range(min(blocks, 65536)):
        low, high, offset = struct.unpack_from('<III', data, 4 + 12 * b)
        p = offset
        for message in range(low, min(high, low + 100000) + 1):
            if p + 4 > len(data):
                break
            length, flags = struct.unpack_from('<HH', data, p)
            if length < 4:
                break
            raw = bytes(data[p + 4:p + length])
            text = raw.decode('utf-16-le', 'replace') if flags & 1 else raw.decode('cp1252', 'replace')
            out[message] = text.rstrip('\x00').rstrip('\r\n')
            p += length
    return out

CONTROL_CLASSES = {'#128': 'Button', '#129': 'Edit', '#130': 'Static', '#131': 'ListBox', '#132': 'ScrollBar', '#133': 'ComboBox'}

def dialog(data):
    extended = struct.unpack_from('<HH', data, 0) == (1, 0xFFFF)
    if extended:
        style = struct.unpack_from('<I', data, 12)[0]
        count = struct.unpack_from('<H', data, 16)[0]
        cx, cy = struct.unpack_from('<hh', data, 22)
        p = 26
    else:
        style = struct.unpack_from('<I', data, 0)[0]
        count = struct.unpack_from('<H', data, 8)[0]
        cx, cy = struct.unpack_from('<hh', data, 14)
        p = 18
    _, p = read_sz_or_ord(data, p)  # Menu
    _, p = read_sz_or_ord(data, p)  # Class
    title, p = read_sz(data, p)
    font = None
    if style & 0x40:  # DS_SETFONT (DS_SHELLFONT includes it)
        p += 6 if extended else 2
        font, p = read_sz(data, p)
    controls = []
    for _ in range(min(count, 4096)):
        p = align4(p)
        if p + (24 if extended else 18) > len(data):
            break
        if extended:
            control_id = struct.unpack_from('<i', data, p + 20)[0]
            p += 24
        else:
            control_id = struct.unpack_from('<H', data, p + 16)[0]
            p += 18
        cls, p = read_sz_or_ord(data, p)
        text, p = read_sz_or_ord(data, p)
        extra = struct.unpack_from('<H', data, p)[0] if p + 2 <= len(data) else 0
        p += 2 + extra
        controls.append([CONTROL_CLASSES.get(cls, cls), control_id, text])
    return {'title': title, 'size': [cx, cy], 'font': font, 'controls': controls}

def menu(data):
    """A menu's items as [path, id] (path: the texts of the item and the menus above it, joined by ' > ')"""
    items = []
    version = struct.unpack_from('<H', data, 0)[0]
    if version == 0:
        def walk(p, path, depth):
            while p + 2 <= len(data) and depth < 16:
                flags = struct.unpack_from('<H', data, p)[0]
                p += 2
                item_id = None
                if not flags & 0x10:
                    item_id = struct.unpack_from('<H', data, p)[0]
                    p += 2
                text, p = read_sz(data, p)
                separator = not text and not item_id and not flags & 0x10
                items.append([' > '.join(path + ['-' if separator else text]), item_id])
                if flags & 0x10:
                    p = walk(p, path + [text], depth + 1)
                if flags & 0x80:
                    break
            return p
        walk(4 + struct.unpack_from('<H', data, 2)[0], [], 0)
    elif version == 1:
        def walk_ex(p, path, depth):
            while p + 14 <= len(data) and depth < 16:
                item_type, _, item_id, flags = struct.unpack_from('<IIIH', data, p)
                p += 14
                text, p = read_sz(data, p)
                p = align4(p)
                items.append([' > '.join(path + ['-' if item_type & 0x800 else text]), item_id - (1 << 32) if item_id >= 1 << 31 else item_id])
                if flags & 0x01:
                    p = walk_ex(p + 4, path + [text], depth + 1)
                if flags & 0x80:
                    break
            return p
        walk_ex(4 + struct.unpack_from('<H', data, 2)[0], [], 0)
    return items

def file_version(data):
    i = bytes(data).find(struct.pack('<I', 0xFEEF04BD))
    if i < 0 or i + 16 > len(data):
        return None
    ms, ls = struct.unpack_from('<II', data, i + 8)
    return '%d.%d.%d.%d' % (ms >> 16, ms & 0xFFFF, ls >> 16, ls & 0xFFFF)

def icon_directory(data, cursor=False):
    """The entries of a group icon or group cursor resource: [(width, height, bits, image id)]"""
    _, kind, count = struct.unpack_from('<HHH', data, 0)
    entries = []
    for i in range(min(count, 256)):
        p = 6 + 14 * i
        if p + 14 > len(data):
            break
        if cursor:
            w, h, _, bits, _, image_id = struct.unpack_from('<HHHHIH', data, p)
            h //= 2
        else:
            w, h, _, _, _, bits, _, image_id = struct.unpack_from('<BBBBHHIH', data, p)
        entries.append((w or 256, h or 256, bits, image_id))
    return entries

def store_image(store, kind, data, cursor=False):
    """Stores an icon or cursor image (the data of an RT_ICON or RT_CURSOR resource, or an image of a .ico or .cur file) and returns
    [width, height, bits, hash], plus the hotspot for a cursor image"""
    hotspot = []
    if cursor:
        hotspot = list(struct.unpack_from('<HH', data, 0))
        data = data[4:]
    hash_ = h16(data)
    if data[:8] == PNG_SIGNATURE:
        w, h, bits = png_rgba_size(data)
        store.put(image_path(kind, w, h, hash_, 'png'), bytes(data))
    else:
        header_size, w, h = struct.unpack_from('<Iii', data, 0)
        bits = struct.unpack_from('<H', data, 14)[0] if header_size >= 40 else struct.unpack_from('<H', data, 10)[0]
        if header_size == 12:
            w, h = struct.unpack_from('<HH', data, 4)
        h = abs(h) // 2
        path = image_path(kind, w, h, hash_, 'png')
        if not store.has(path):
            png, w, h, bits = dib_to_png(data, icon=True)
            store.put(path, png)
    return [w, h, bits, hash_] + hotspot

def store_bitmap(store, data):
    hash_ = h16(data)
    header_size = struct.unpack_from('<I', data, 0)[0]
    if header_size == 12:
        w, h = struct.unpack_from('<HH', data, 4)
    else:
        w, h = struct.unpack_from('<ii', data, 4)
    w, h = abs(w), abs(h)
    path = image_path('bitmaps', w, h, hash_, 'png')
    if not store.has(path):
        try:
            png, w, h, _ = dib_to_png(data)
            store.put(path, png)
        except (ValueError, struct.error, IndexError):
            # Not one this script decodes: kept as a .bmp file, which browsers show too
            header = b'BM' + struct.pack('<IHHI', 14 + len(data), 0, 0, 14 + header_size)
            path = image_path('bitmaps', w, h, hash_, 'bmp')
            store.put(path, header + bytes(data))
    return [w, h, hash_]

def read_pe(store, data, name):
    """What an executable holds, as the JSON stored for its version"""
    pe = Pe(data)
    info = {'kind': 'pe', 'name': name, 'machine': MACHINES.get(pe.machine, '%#x' % pe.machine), 'timestamp': pe.timestamp,
            'imageSize': pe.image_size}
    exports, unnamed = pe.exports()
    if exports or unnamed:
        info['exports'] = exports
        if unnamed:
            info['exportsByOrdinal'] = unnamed
    resources = pe.resources()
    by_type = collections.defaultdict(list)
    table = []
    for type_, res_name, lang, rva, size in resources:
        content = pe.read(rva, size)
        if type_ != 16:
            table.append([type_, res_name, lang, size, h16(content)])
        by_type[type_].append((res_name, lang, content))
    if table:
        info['resources'] = sorted(table, key=lambda r: (str(r[0]), str(r[1]), r[2]))
    for _, _, content in by_type.get(16, [])[:1]:
        info['version'] = file_version(content)

    def preferred(items):
        """One language of each resource: en-US, neutral, or else the first"""
        chosen = {}
        for res_name, lang, content in items:
            rank = 0 if lang == 0x409 else 1 if lang in (0, 0x400, 0x800) else 2
            key = key_of(res_name)
            if key not in chosen or rank < chosen[key][0]:
                chosen[key] = (rank, res_name, content)
        return {k: (v[1], v[2]) for k, v in chosen.items()}

    errors = []
    for group_type, image_type, kind, cursor in ((14, 3, 'icons', False), (12, 1, 'cursors', True)):
        if group_type not in by_type:
            continue
        images = {}
        for res_name, lang, content in by_type.get(image_type, []):
            if res_name not in images or lang == 0x409:
                images[res_name] = content
        groups = {}
        for key, (res_name, content) in preferred(by_type[group_type]).items():
            entries = []
            try:
                for w, h, bits, image_id in icon_directory(content, cursor):
                    image = images.get(image_id)
                    if image is None:
                        continue
                    try:
                        entries.append(store_image(store, kind, image, cursor))
                    except (ValueError, struct.error, IndexError) as e:
                        errors.append('%s %s image %s: %s' % (kind, key, image_id, e))
            except (ValueError, struct.error) as e:
                errors.append('%s %s: %s' % (kind, key, e))
            groups[key] = entries
        info[kind] = groups
    if 2 in by_type:
        bitmaps = {}
        for key, (_, content) in preferred(by_type[2]).items():
            try:
                bitmaps[key] = store_bitmap(store, content)
            except (ValueError, struct.error, IndexError) as e:
                errors.append('bitmap %s: %s' % (key, e))
        info['bitmaps'] = bitmaps
    images = {}
    for type_, items in by_type.items():
        if type_ in (1, 2, 3, 12, 14):
            continue
        for key, (_, content) in preferred(items).items():
            found = image_info(content[:4096]) if len(content) >= 16 else None
            if found:
                ext, w, h = found
                hash_ = h16(content)
                store.put(image_path('images', w, h, hash_, ext), bytes(content))
                images['%s/%s' % (key_of(type_), key)] = [w, h, hash_, ext]
            elif content[:5] == b'<svg ' or content[:5] == b'<?xml' and b'<svg' in content[:512]:
                hash_ = h16(content)
                store.put('images/svg/%s/%s.svg' % (hash_[0], hash_), bytes(content))
                images['%s/%s' % (key_of(type_), key)] = [0, 0, hash_, 'svg']
    if images:
        info['images'] = images
    if 6 in by_type:
        strings = {}
        for _, (res_name, content) in sorted(preferred(by_type[6]).items(), key=lambda kv: str(kv[0])):
            if isinstance(res_name, int):
                strings.update(string_table(res_name, content))
        info['strings'] = {str(k): v for k, v in sorted(strings.items())}
    if 11 in by_type:
        messages = {}
        for _, (_, content) in preferred(by_type[11]).items():
            try:
                messages.update(message_table(content))
            except struct.error as e:
                errors.append('message table: %s' % e)
        info['messages'] = {str(k): v for k, v in sorted(messages.items())}
    for type_, kind, reader in ((5, 'dialogs', dialog), (4, 'menus', menu)):
        if type_ in by_type:
            found = {}
            for key, (_, content) in preferred(by_type[type_]).items():
                try:
                    found[key] = reader(content)
                except (struct.error, IndexError) as e:
                    errors.append('%s %s: %s' % (kind, key, e))
            info[kind] = found
    if errors:
        info['errors'] = errors[:50]
    return info

# Parts of a file's record that are compared on their own
PE_PARTS = ('exports', 'icons', 'cursors', 'bitmaps', 'images', 'strings', 'messages', 'dialogs', 'menus', 'resources', 'types')

# ---------------------------------------------------------------------------
# WinRT metadata (.winmd): ECMA-335 tables
# ---------------------------------------------------------------------------

# Coded indexes: (tag bits, the tables they point into, by tag)
CODED = {
    'TypeDefOrRef': (2, [2, 1, 27]), 'HasConstant': (2, [4, 8, 23]),
    'HasCustomAttribute': (5, [6, 4, 1, 2, 8, 9, 10, 0, 14, 23, 20, 17, 26, 27, 32, 35, 38, 39, 40, 42, 44, 43]),
    'HasFieldMarshal': (1, [4, 8]), 'HasDeclSecurity': (2, [2, 6, 32]), 'MemberRefParent': (3, [2, 1, 26, 6, 27]),
    'HasSemantics': (1, [20, 23]), 'MethodDefOrRef': (1, [6, 10]), 'MemberForwarded': (1, [4, 6]), 'Implementation': (2, [38, 35, 39]),
    'CustomAttributeType': (3, [None, None, 6, 10, None]), 'ResolutionScope': (2, [0, 26, 35, 1]), 'TypeOrMethodDef': (1, [2, 6]),
}
# Each table's columns: a byte count, 's'/'g'/'b' (an index into the string, GUID or blob heap), a table number (an index into it) or a
# coded index
TABLES = {
    0x00: [2, 's', 'g', 'g', 'g'], 0x01: ['ResolutionScope', 's', 's'], 0x02: [4, 's', 's', 'TypeDefOrRef', 0x04, 0x06], 0x03: [0x04],
    0x04: [2, 's', 'b'], 0x05: [0x06], 0x06: [4, 2, 2, 's', 'b', 0x08], 0x07: [0x08], 0x08: [2, 2, 's'], 0x09: [0x02, 'TypeDefOrRef'],
    0x0A: ['MemberRefParent', 's', 'b'], 0x0B: [2, 'HasConstant', 'b'], 0x0C: ['HasCustomAttribute', 'CustomAttributeType', 'b'],
    0x0D: ['HasFieldMarshal', 'b'], 0x0E: [2, 'HasDeclSecurity', 'b'], 0x0F: [2, 4, 0x02], 0x10: [4, 0x04], 0x11: ['b'],
    0x12: [0x02, 0x14], 0x13: [0x14], 0x14: [2, 's', 'TypeDefOrRef'], 0x15: [0x02, 0x17], 0x16: [0x17], 0x17: [2, 's', 'b'],
    0x18: [2, 0x06, 'HasSemantics'], 0x19: [0x02, 'MethodDefOrRef', 'MethodDefOrRef'], 0x1A: ['s'], 0x1B: ['b'],
    0x1C: [2, 'MemberForwarded', 's', 0x1A], 0x1D: [4, 0x04], 0x1E: [4, 4], 0x1F: [4], 0x20: [4, 2, 2, 2, 2, 4, 'b', 's', 's'],
    0x21: [4], 0x22: [4, 4, 4], 0x23: [2, 2, 2, 2, 4, 'b', 's', 's', 'b'], 0x24: [4, 0x23], 0x25: [4, 4, 4, 0x23], 0x26: [4, 's', 'b'],
    0x27: [4, 4, 's', 's', 'Implementation'], 0x28: [4, 4, 's', 'Implementation'], 0x29: [0x02, 0x02], 0x2A: [2, 2, 'TypeOrMethodDef', 's'],
    0x2B: ['MethodDefOrRef', 'b'], 0x2C: [0x2A, 'TypeDefOrRef'],
}
BASE_KINDS = {'System.Enum': 'enum', 'System.ValueType': 'struct', 'System.MulticastDelegate': 'delegate', 'System.Attribute': 'attribute'}

def read_winmd(pe, name):
    """The types a .winmd file defines, with the names of their members"""
    rva, size = pe.directory(14)
    cli = pe.read(rva, 72)
    md_rva, md_size = struct.unpack_from('<II', cli, 8)
    md = pe.read(md_rva, md_size)
    if md[:4] != b'BSJB':
        raise ValueError('no metadata')
    p = 16 + struct.unpack_from('<I', md, 12)[0]
    count = struct.unpack_from('<H', md, p + 2)[0]
    p += 4
    streams = {}
    for _ in range(count):
        offset, length = struct.unpack_from('<II', md, p)
        end = md.index(b'\0', p + 8)
        streams[md[p + 8:end].decode('latin-1')] = md[offset:offset + length]
        p = align4(end + 1)
    tables = streams.get('#~') or streams.get('#-')
    strings = streams.get('#Strings', b'')
    heap_sizes = tables[6]
    valid = struct.unpack_from('<Q', tables, 8)[0]
    p = 24
    rows = {}
    for t in range(64):
        if valid >> t & 1:
            rows[t] = struct.unpack_from('<I', tables, p)[0]
            p += 4
    sizes = {'s': 4 if heap_sizes & 1 else 2, 'g': 4 if heap_sizes & 2 else 2, 'b': 4 if heap_sizes & 4 else 2}

    def column_size(column):
        if isinstance(column, str) and column in sizes:
            return sizes[column]
        if isinstance(column, str):
            bits, targets = CODED[column]
            biggest = max(rows.get(t, 0) for t in targets if t is not None)
            return 2 if biggest < (1 << (16 - bits)) else 4
        return 2 if rows.get(column, 0) < 0x10000 else 4

    # Numbers in the schema are byte counts, except in these columns, where they're the table the column indexes
    INDEX_COLUMNS = {0x02: (4, 5), 0x03: (0,), 0x05: (0,), 0x06: (5,), 0x07: (0,), 0x09: (0,), 0x0F: (2,), 0x10: (1,), 0x12: (0, 1),
                     0x13: (0,), 0x15: (0, 1), 0x16: (0,), 0x18: (1,), 0x19: (0,), 0x1C: (3,), 0x1D: (1,), 0x24: (1,), 0x25: (3,),
                     0x29: (0, 1), 0x2C: (0,)}
    parsed = {}
    for t in sorted(rows):
        if t not in TABLES:
            raise ValueError('metadata table %#x' % t)
        widths = []
        for i, c in enumerate(TABLES[t]):
            if i in INDEX_COLUMNS.get(t, ()):
                widths.append(2 if rows.get(c, 0) < 0x10000 else 4)
            elif isinstance(c, int):
                widths.append(c)
            else:
                widths.append(column_size(c))
        row_size = sum(widths)
        fmt = '<' + ''.join({1: 'B', 2: 'H', 4: 'I'}[w] for w in widths)
        parsed[t] = [struct.unpack_from(fmt, tables, p + r * row_size) for r in range(rows[t])]
        p += row_size * rows[t]

    def string(index):
        end = strings.find(b'\0', index)
        return strings[index:end if end >= 0 else len(strings)].decode('utf-8', 'replace')

    typedefs = parsed.get(0x02, [])
    typerefs = parsed.get(0x01, [])

    def ranges(rows_, column, total):
        starts = [r[column] for r in rows_]
        return [(s, (starts[i + 1] if i + 1 < len(starts) else total + 1)) for i, s in enumerate(starts)]

    fields = parsed.get(0x04, [])
    methods = parsed.get(0x06, [])
    field_ranges = ranges(typedefs, 4, len(fields))
    method_ranges = ranges(typedefs, 5, len(methods))
    owned = collections.defaultdict(lambda: collections.defaultdict(list))
    for map_table, list_table, kind in ((0x15, 0x17, 'properties'), (0x12, 0x14, 'events')):
        maps = parsed.get(map_table, [])
        members = parsed.get(list_table, [])
        for (parent, *_), (start, end) in zip(maps, ranges(maps, 1, len(members))):
            for i in range(start, end):
                if 1 <= i <= len(members):
                    owned[parent][kind].append(string(members[i - 1][1]))
    enclosing = {nested: outer for nested, outer in parsed.get(0x29, [])}

    def full_name(index, depth=0):
        flags, type_name, namespace = typedefs[index - 1][:3]
        if index in enclosing and depth < 8:
            return full_name(enclosing[index], depth + 1) + '/' + string(type_name)
        ns = string(namespace)
        return (ns + '.' if ns else '') + string(type_name)

    def base_name(coded):
        tag, index = coded & 3, coded >> 2
        if tag == 1 and 1 <= index <= len(typerefs):
            ns = string(typerefs[index - 1][2])
            return (ns + '.' if ns else '') + string(typerefs[index - 1][1])
        if tag == 0 and 1 <= index <= len(typedefs):
            return full_name(index)
        return None

    types = {}
    for i, row in enumerate(typedefs, 1):
        flags, type_name, namespace, extends = row[:4]
        if string(type_name) == '<Module>':
            continue
        kind = 'interface' if flags & 0x20 else BASE_KINDS.get(base_name(extends), 'class')
        entry = {'kind': kind}
        start, end = method_ranges[i - 1]
        names = [string(methods[m - 1][3]) for m in range(start, end) if 1 <= m <= len(methods)
                 and (not methods[m - 1][2] & 0x800 or string(methods[m - 1][3]) == '.ctor')]
        if names:
            entry['methods'] = sorted(names)
        start, end = field_ranges[i - 1]
        names = [string(fields[f - 1][1]) for f in range(start, end) if 1 <= f <= len(fields) and string(fields[f - 1][1]) != 'value__']
        if names:
            entry['fields'] = names if kind == 'enum' else sorted(names)
        for kind_ in ('properties', 'events'):
            if owned[i][kind_]:
                entry[kind_] = sorted(owned[i][kind_])
        types[full_name(i)] = entry
    return {'kind': 'winmd', 'name': name, 'types': types}

# ---------------------------------------------------------------------------
# Fonts
# ---------------------------------------------------------------------------

FONT_FILES = {'segoeicons.ttf', 'segmdl2.ttf', 'seguiemj.ttf', 'seguivar.ttf'}

def read_font(data, name):
    """A hash of each character's glyph (its outline, its variations and its color layers), and of each named glyph (emoji sequences
    have no character of their own, only a glyph name)"""
    tables = {}
    for i in range(struct.unpack_from('>H', data, 4)[0]):
        tag, _, offset, length = struct.unpack_from('>4sIII', data, 12 + 16 * i)
        tables[tag.decode('latin-1')] = data[offset:offset + length]
    num_glyphs = struct.unpack_from('>H', tables['maxp'], 4)[0]
    cmap = read_cmap(tables['cmap'])
    outlines = [b''] * num_glyphs
    if 'glyf' in tables and 'loca' in tables:
        long_offsets = struct.unpack_from('>h', tables['head'], 50)[0]
        loca = tables['loca']
        offsets = (struct.unpack_from('>%dI' % (num_glyphs + 1), loca) if long_offsets else
                   [2 * x for x in struct.unpack_from('>%dH' % (num_glyphs + 1), loca)])
        glyf = tables['glyf']
        outlines = [glyf[offsets[g]:offsets[g + 1]] for g in range(num_glyphs)]
    variations = [b''] * num_glyphs
    if 'gvar' in tables:
        gvar = tables['gvar']
        count, flags, array = struct.unpack_from('>HHI', gvar, 12)
        offsets = (struct.unpack_from('>%dI' % (count + 1), gvar, 20) if flags & 1 else
                   [2 * x for x in struct.unpack_from('>%dH' % (count + 1), gvar, 20)])
        for g in range(min(count, num_glyphs)):
            variations[g] = gvar[array + offsets[g]:array + offsets[g + 1]]
    layers = collections.defaultdict(list)
    if 'COLR' in tables:
        colr = tables['COLR']
        version, base_count, base_offset, layer_offset, layer_count = struct.unpack_from('>HHIIH', colr, 0)
        for i in range(base_count):
            glyph, first, count = struct.unpack_from('>HHH', colr, base_offset + 6 * i)
            for j in range(first, min(first + count, layer_count)):
                layer_glyph, palette = struct.unpack_from('>HH', colr, layer_offset + 4 * j)
                layers[glyph].append(struct.pack('>H', palette) + bytes(outlines[layer_glyph] if layer_glyph < num_glyphs else b''))
        if version >= 1:
            list_offset = struct.unpack_from('>I', colr, 14)[0]
            if list_offset:
                count = struct.unpack_from('>I', colr, list_offset)[0]
                records = [struct.unpack_from('>HI', colr, list_offset + 4 + 6 * i) for i in range(count)]
                bounds = sorted({offset for _, offset in records}) + [len(colr) - list_offset]
                for glyph, offset in records:
                    end = bounds[bounds.index(offset) + 1]
                    layers[glyph].append(colr[list_offset + offset:list_offset + end])

    def glyph_hash(g):
        if g >= num_glyphs:
            return None
        return h16(bytes(outlines[g]) + b'|' + bytes(variations[g]) + b'|' + b'|'.join(bytes(x) for x in layers.get(g, [])))

    # Sequences of characters drawn as one glyph (emoji with skin tones, ZWJ sequences, flags): GSUB's ligatures
    first_codepoint = {}
    for c, g in sorted(cmap.items(), reverse=True):
        first_codepoint[g] = c
    sequences = {}
    for components, glyph in gsub_ligatures(tables.get('GSUB', b'')):
        if all(g in first_codepoint for g in components):
            key = ' '.join('%04X' % first_codepoint[g] for g in components)
            sequences.setdefault(key, glyph_hash(glyph))
    names = {}
    post = tables.get('post', b'')
    if len(post) >= 34 and struct.unpack_from('>I', post, 0)[0] == 0x00020000:
        count = struct.unpack_from('>H', post, 32)[0]
        indexes = struct.unpack_from('>%dH' % count, post, 34)
        p = 34 + 2 * count
        custom = []
        while p < len(post):
            length = post[p]
            custom.append(bytes(post[p + 1:p + 1 + length]).decode('latin-1'))
            p += 1 + length
        for g, index in enumerate(indexes):
            if index >= 258 and index - 258 < len(custom):
                names[custom[index - 258]] = glyph_hash(g)
    return {'kind': 'font', 'name': name, 'family': font_name(tables.get('name', b'')), 'glyphs': num_glyphs,
            'codepoints': {'%04X' % c: glyph_hash(g) for c, g in sorted(cmap.items())}, 'sequences': dict(sorted(sequences.items())),
            'names': dict(sorted(names.items()))}

def gsub_ligatures(gsub):
    """(component glyphs, ligature glyph) of every ligature substitution in a GSUB table"""
    if len(gsub) < 10:
        return []
    lookups = struct.unpack_from('>H', gsub, 8)[0]
    count = struct.unpack_from('>H', gsub, lookups)[0]
    found = []

    def coverage(offset):
        fmt, n = struct.unpack_from('>HH', gsub, offset)
        if fmt == 1:
            return list(struct.unpack_from('>%dH' % n, gsub, offset + 4))
        glyphs = []
        for i in range(n):
            start, end, _ = struct.unpack_from('>HHH', gsub, offset + 4 + 6 * i)
            glyphs.extend(range(start, end + 1))
        return glyphs

    def ligature_subtable(offset):
        fmt, cover, sets = struct.unpack_from('>HHH', gsub, offset)
        if fmt != 1:
            return
        firsts = coverage(offset + cover)
        for i in range(min(sets, len(firsts))):
            set_offset = offset + struct.unpack_from('>H', gsub, offset + 6 + 2 * i)[0]
            for j in range(struct.unpack_from('>H', gsub, set_offset)[0]):
                lig = set_offset + struct.unpack_from('>H', gsub, set_offset + 2 + 2 * j)[0]
                glyph, components = struct.unpack_from('>HH', gsub, lig)
                found.append(((firsts[i],) + struct.unpack_from('>%dH' % (components - 1), gsub, lig + 4), glyph))

    for i in range(count):
        lookup = lookups + struct.unpack_from('>H', gsub, lookups + 2 + 2 * i)[0]
        kind, _, subtables = struct.unpack_from('>HHH', gsub, lookup)
        for j in range(subtables):
            sub = lookup + struct.unpack_from('>H', gsub, lookup + 6 + 2 * j)[0]
            sub_kind = kind
            if kind == 7:  # Extension: the subtable is further on
                sub_kind, extension = struct.unpack_from('>HI', gsub, sub + 2)
                sub += extension
            if sub_kind == 4:
                ligature_subtable(sub)
    return found

def read_cmap(table):
    subtables = {}
    for i in range(struct.unpack_from('>H', table, 2)[0]):
        platform, encoding, offset = struct.unpack_from('>HHI', table, 4 + 8 * i)
        subtables[(platform, encoding, struct.unpack_from('>H', table, offset)[0])] = offset
    for choice in ((3, 10, 12), (0, 6, 12), (0, 4, 12), (3, 1, 4), (0, 3, 4), (0, 1, 4), (0, 0, 4), (3, 0, 4)):
        if choice in subtables:
            offset = subtables[choice]
            mapping = {}
            if choice[2] == 12:
                for i in range(struct.unpack_from('>I', table, offset + 12)[0]):
                    start, end, glyph = struct.unpack_from('>III', table, offset + 16 + 12 * i)
                    for c in range(start, min(end, start + 0x10000) + 1):
                        mapping[c] = glyph + c - start
            else:
                segments = struct.unpack_from('>H', table, offset + 6)[0] // 2
                ends = offset + 14
                starts = ends + 2 * segments + 2
                deltas = starts + 2 * segments
                range_offsets = deltas + 2 * segments
                for i in range(segments):
                    end, start = struct.unpack_from('>H', table, ends + 2 * i)[0], struct.unpack_from('>H', table, starts + 2 * i)[0]
                    delta = struct.unpack_from('>h', table, deltas + 2 * i)[0]
                    range_offset = struct.unpack_from('>H', table, range_offsets + 2 * i)[0]
                    for c in range(start, end + 1):
                        if c == 0xFFFF:
                            continue
                        if range_offset:
                            at = range_offsets + 2 * i + range_offset + 2 * (c - start)
                            g = struct.unpack_from('>H', table, at)[0] if at + 2 <= len(table) else 0
                            g = (g + delta) & 0xFFFF if g else 0
                        else:
                            g = (c + delta) & 0xFFFF
                        if g:
                            mapping[c] = g
            return mapping
    return {}

def font_name(table):
    if len(table) < 6:
        return None
    count, strings = struct.unpack_from('>HH', table, 2)
    for i in range(count):
        platform, encoding, language, name_id, length, offset = struct.unpack_from('>HHHHHH', table, 6 + 12 * i)
        if name_id == 4 and platform == 3 and language == 0x409:
            return bytes(table[strings + offset:strings + offset + length]).decode('utf-16-be', 'replace')
    return None

# ---------------------------------------------------------------------------
# Icon and cursor files (.ico, .cur, .ani)
# ---------------------------------------------------------------------------

def read_icon_file(store, data):
    """The images of an .ico or .cur file, stored with the icons or cursors"""
    _, kind, count = struct.unpack_from('<HHH', data, 0)
    frames = []
    for i in range(min(count, 256)):
        _, _, _, _, a, b, size, offset = struct.unpack_from('<BBBBHHII', data, 6 + 16 * i)
        image = data[offset:offset + size]
        if kind == 2:
            frames.append(store_image(store, 'cursors', struct.pack('<HH', a, b) + bytes(image), cursor=True))
        else:
            frames.append(store_image(store, 'icons', image))
    return kind, frames

def read_ani(store, data, name):
    if data[:4] != b'RIFF' or data[8:12] != b'ACON':
        raise ValueError('not an animated cursor')
    info = {'kind': 'ani', 'name': name, 'frames': []}
    p = 12
    while p + 8 <= len(data):
        tag, length = data[p:p + 4], struct.unpack_from('<I', data, p + 4)[0]
        body = data[p + 8:p + 8 + length]
        if tag == b'anih' and len(body) >= 36:
            _, frames, steps, _, _, _, _, rate, flags = struct.unpack_from('<9I', body, 0)
            info.update({'steps': steps, 'rate': rate, 'flags': flags})
        elif tag == b'rate':
            info['rates'] = list(struct.unpack_from('<%dI' % (len(body) // 4), body))
        elif tag == b'seq ':
            info['sequence'] = list(struct.unpack_from('<%dI' % (len(body) // 4), body))
        elif tag == b'LIST' and body[:4] == b'fram':
            q = 4
            while q + 8 <= len(body):
                inner, size = body[q:q + 4], struct.unpack_from('<I', body, q + 4)[0]
                if inner == b'icon':
                    info['frames'].append(read_icon_file(store, body[q + 8:q + 8 + size])[1])
                q += 8 + size + (size & 1)
        p += 8 + length + (length & 1)
    return info

# ---------------------------------------------------------------------------
# Registry hives (regf)
# ---------------------------------------------------------------------------

class Hive:
    def __init__(self, path):
        with open(path, 'rb') as f:
            self.data = f.read()
        if self.data[:4] != b'regf':
            raise ValueError('not a registry hive')
        self.root = struct.unpack_from('<I', self.data, 36)[0]

    def cell(self, offset):
        return 0x1000 + offset + 4

    def key(self, offset):
        d = self.data
        p = self.cell(offset)
        if d[p:p + 2] != b'nk':
            raise ValueError('not a key')
        flags = struct.unpack_from('<H', d, p + 2)[0]
        subkeys, subkey_list, values, value_list = struct.unpack_from('<I4xI4xII', d, p + 20)
        length = struct.unpack_from('<H', d, p + 72)[0]
        raw = d[p + 76:p + 76 + length]
        name = raw.decode('latin-1') if flags & 0x20 else raw.decode('utf-16-le', 'replace')
        return name, subkeys, subkey_list, values, value_list

    def children(self, offset):
        _, count, subkey_list, _, _ = self.key(offset)
        if not count or subkey_list == 0xFFFFFFFF:
            return []
        out = []

        def walk(list_offset, depth):
            p = self.cell(list_offset)
            sig, n = self.data[p:p + 2], struct.unpack_from('<H', self.data, p + 2)[0]
            if sig in (b'lf', b'lh'):
                out.extend(struct.unpack_from('<I', self.data, p + 4 + 8 * i)[0] for i in range(n))
            elif sig == b'li':
                out.extend(struct.unpack_from('<I', self.data, p + 4 + 4 * i)[0] for i in range(n))
            elif sig == b'ri' and depth < 4:
                for i in range(n):
                    walk(struct.unpack_from('<I', self.data, p + 4 + 4 * i)[0], depth + 1)
        walk(subkey_list, 0)
        return out

    def values(self, offset):
        _, _, _, count, value_list = self.key(offset)
        if not count or value_list == 0xFFFFFFFF:
            return {}
        d = self.data
        out = {}
        p = self.cell(value_list)
        for i in range(min(count, 100000)):
            q = self.cell(struct.unpack_from('<I', d, p + 4 * i)[0])
            if d[q:q + 2] != b'vk':
                continue
            length, size, data_offset, value_type, flags = struct.unpack_from('<HIIIH', d, q + 2)
            raw_name = d[q + 20:q + 20 + length]
            name = raw_name.decode('latin-1') if flags & 1 else raw_name.decode('utf-16-le', 'replace')
            if size & 0x80000000:
                raw = struct.pack('<I', data_offset)[:size & 0x7FFFFFFF]
            else:
                r = self.cell(data_offset)
                if size > 16344 and d[r:r + 2] == b'db':
                    segments, segment_list = struct.unpack_from('<HI', d, r + 2)
                    s = self.cell(segment_list)
                    raw = b''.join(d[self.cell(struct.unpack_from('<I', d, s + 4 * j)[0]):][:16344] for j in range(segments))[:size]
                else:
                    raw = d[r:r + size]
            out[name] = registry_value(value_type, raw)
        return out

    def find(self, path):
        offset = self.root
        for part in path.split('\\'):
            for child in self.children(offset):
                if self.key(child)[0].lower() == part.lower():
                    offset = child
                    break
            else:
                return None
        return offset

    def export(self, offset, depth):
        node = {}
        values = self.values(offset)
        if values:
            node['values'] = dict(sorted(values.items()))
        if depth > 0:
            keys = {}
            for child in self.children(offset):
                keys[self.key(child)[0]] = self.export(child, depth - 1)
            if keys:
                node['keys'] = dict(sorted(keys.items(), key=lambda kv: kv[0].lower()))
        return node

def registry_value(value_type, raw):
    if value_type in (1, 2):
        return raw.decode('utf-16-le', 'replace').split('\x00', 1)[0]
    if value_type == 7:
        return [s for s in raw.decode('utf-16-le', 'replace').split('\x00') if s]
    if value_type == 4 and len(raw) >= 4:
        return struct.unpack_from('<I', raw)[0]
    if value_type == 11 and len(raw) >= 8:
        return struct.unpack_from('<Q', raw)[0]
    return raw.hex() if len(raw) <= 64 else 'binary, %d bytes, %s' % (len(raw), h16(raw))

# The registry keys recorded: (hive, key, how many levels of subkeys)
REGISTRY_KEYS = {
    'policyManager': ('SOFTWARE', r'Microsoft\PolicyManager\default', 8),          # MDM/CSP policy definitions
    'etwProviders': ('SOFTWARE', r'Microsoft\Windows\CurrentVersion\WINEVT\Publishers', 1),
    'activatableClasses': ('SOFTWARE', r'Microsoft\WindowsRuntime\ActivatableClassId', 1),
    'services': ('SYSTEM', r'{controlset}\Services', 2),
}

def read_registry(config_dir, store):
    """The registry keys above, each stored by hash; returns {name: hash}"""
    found = {}
    hives = {}
    for name in ('SOFTWARE', 'SYSTEM'):
        path = os.path.join(config_dir, name)
        try:
            hives[name] = Hive(path)
        except (OSError, ValueError) as e:
            log('Registry hive %s: %s' % (name, e))
    if 'SYSTEM' in hives:
        select = hives['SYSTEM'].find('Select')
        current = hives['SYSTEM'].values(select).get('Current', 1) if select is not None else 1
        control_set = 'ControlSet%03d' % current
    for label, (hive_name, key, depth) in REGISTRY_KEYS.items():
        hive = hives.get(hive_name)
        if not hive:
            continue
        offset = hive.find(key.replace('{controlset}', control_set) if '{controlset}' in key else key)
        if offset is None:
            log('Registry: no %s\\%s' % (hive_name, key))
            continue
        tree = hive.export(offset, depth)
        hash_ = digest(tree)
        store.put_json('registry/%s/%s.json' % (hash_[:2], hash_), tree)
        found[label] = hash_
    return found

# ---------------------------------------------------------------------------
# Which files, and what is kept of each
# ---------------------------------------------------------------------------

PE_EXTENSIONS = {'.dll', '.exe', '.sys', '.cpl', '.ocx', '.scr', '.ax', '.drv', '.tsp', '.ime', '.efi', '.acm', '.com', '.mun', '.mui',
                 '.msstyles', '.winmd'}
IMAGE_EXTENSIONS = {'.png', '.jpg', '.jpeg', '.gif', '.bmp', '.svg', '.ico'}
# The shell's UI: every file but code (executables go through read_pe like all others)
SHELL_ROOTS = ('windows\\systemapps\\', 'windows\\shellexperiences\\', 'windows\\immersivecontrolpanel\\', 'windows\\shellcomponents\\',
               'windows\\systemresources\\')
SHELL_EXTENSIONS = {'.json', '.js', '.mjs', '.html', '.htm', '.css', '.xml', '.xbf', '.xaml', '.pri', '.webm', '.mp4', '.mkv', '.mp3',
                    '.wav', '.txt', '.resjson', '.resw', '.webp'}
# Folders with machine-specific or generated content (as verify-windows-files.py skips), Store apps, and Edge and Copilot, which
# update on their own
SKIP_DIRS = {'winsxs', 'softwaredistribution', 'logs', 'temp', 'prefetch', 'installer', 'serviceprofiles', 'panther', 'livekernelreports',
             'minidump', 'cbstemp', 'winevt', 'logfiles', 'sru', 'catroot2', 'wer', 'windowsapps'}
SKIP_PATHS = ('program files (x86)\\microsoft\\edge', 'program files (x86)\\microsoft\\copilot', 'program files (x86)\\microsoft\\temp',
              'windows\\assembly\\nativeimages')

def classify(rel):
    """What's kept of a file (its path relative to the installation's root, in lower case): 'pe', 'winmd', 'font', 'cursor', 'image',
    'file:<kind>' for a whole file, or None"""
    name = rel.rsplit('\\', 1)[-1]
    ext = os.path.splitext(name)[1]
    if rel.startswith('windows\\fonts\\'):
        return 'font' if name in FONT_FILES else None
    if rel.startswith('windows\\cursors\\'):
        return 'cursor' if ext in ('.cur', '.ani') else None
    if ext in PE_EXTENSIONS:
        if ext == '.mui' and '\\en-us\\' not in '\\' + rel:
            return None  # Only the English text
        return 'winmd' if ext == '.winmd' else 'pe'
    if rel.startswith('windows\\policydefinitions\\'):
        if (ext == '.admx' and rel.count('\\') == 2) or (ext == '.adml' and rel.startswith('windows\\policydefinitions\\en-us\\')):
            return 'file:policies'
        return None
    if rel.startswith('windows\\media\\'):
        return 'file:sounds' if ext == '.wav' else None
    if rel.startswith('windows\\web\\'):
        return 'image' if ext in IMAGE_EXTENSIONS else None
    if rel.startswith('windows\\resources\\themes\\'):
        return 'file:themes' if ext == '.theme' else None
    if rel.startswith('windows\\system32\\windowspowershell\\v1.0\\modules\\'):
        return 'file:powershell' if ext in ('.psd1', '.psm1', '.ps1', '.ps1xml', '.cdxml', '.xml') else None
    if rel.startswith('windows\\servicing\\packages\\'):
        return 'file:servicing' if ext == '.mum' else None
    if rel.startswith('windows\\system32\\tasks\\'):
        return 'file:tasks'
    if rel.startswith(SHELL_ROOTS):
        if ext in IMAGE_EXTENSIONS:
            return 'image'
        return 'file:shell' if ext in SHELL_EXTENSIONS else None
    return None

def is_lottie(data):
    try:
        value = json.loads(bytes(data).decode('utf-8-sig'))
    except (ValueError, UnicodeDecodeError):
        return False
    return isinstance(value, dict) and 'layers' in value and 'v' in value and ('fr' in value or 'op' in value)

def read_file(store, data, name, kind, hash_):
    """Reads one file version, stores what's kept of it, and returns its index entry: what kind of file it is, where its parts are in
    the assets branch, and the hashes of its parts ('d'), which are what tell two versions apart"""
    ext = os.path.splitext(name)[1].lower()
    if kind in ('pe', 'winmd'):
        try:
            info = read_pe(store, data, name)
        except NotPe:
            return {'kind': 'other'}
        if kind == 'winmd':
            pe = Pe(data)
            if pe.winmd():
                info.update(read_winmd(pe, name))
        info['size'] = len(data)
        meta, parts = store_record(store, hash_, info, PE_PARTS)
        return {'kind': info['kind'], 'meta': meta, 'd': parts}
    if kind == 'font':
        path = store.put('files/fonts/%s/%s%s' % (hash_[0], hash_, ext), bytes(data))
        meta, parts = store_record(store, hash_, read_font(data, name), ('codepoints', 'sequences', 'names'))
        return {'kind': 'font', 'file': path, 'meta': meta, 'd': parts}
    if kind == 'cursor' or (kind == 'image' and ext == '.ico'):
        if ext == '.ani':
            info = read_ani(store, data, name)
        else:
            icon_kind, frames = read_icon_file(store, data)
            info = {'kind': 'cursor' if icon_kind == 2 else 'ico', 'name': name, 'frames': [frames]}
        meta, parts = store_record(store, hash_, info, ('frames', 'rates', 'sequence'))
        return {'kind': info['kind'], 'meta': meta, 'd': parts}
    if kind == 'image':
        if ext == '.svg':
            return {'kind': 'image', 'file': store.put('images/svg/%s/%s.svg' % (hash_[0], hash_), bytes(data))}
        if ext == '.bmp' and data[:2] == b'BM':
            w, h, image_hash = store_bitmap(store, bytes(data[14:]))
            return {'kind': 'image', 'file': image_path('bitmaps', w, h, image_hash, 'png'), 'size': [w, h]}
        found = image_info(bytes(data[:1 << 20]))
        if not found:
            return {'kind': 'file', 'file': store.put('files/shell/%s/%s%s' % (hash_[0], hash_, ext), bytes(data))}
        image_ext, w, h = found
        return {'kind': 'image', 'file': store.put(image_path('images', w, h, hash_, image_ext), bytes(data)), 'size': [w, h]}
    category = kind.split(':', 1)[1]
    entry = {'kind': 'file', 'file': store.put('files/%s/%s/%s%s' % (category, hash_[0], hash_, ext), bytes(data))}
    if ext == '.json' and is_lottie(data):
        entry['lottie'] = True
    return entry

def walk(root, top):
    """(path, path relative to root) of every file under root\\top, outside the skipped folders"""
    stack = [os.path.join(root, top)]
    while stack:
        folder = stack.pop()
        try:
            entries = list(os.scandir(folder))
        except OSError:
            continue
        for e in entries:
            try:
                if e.is_symlink() or getattr(e, 'is_junction', lambda: False)():
                    continue
                rel = os.path.relpath(e.path, root).replace(os.sep, '\\')
                if e.is_dir(follow_symlinks=False):
                    if e.name.lower() not in SKIP_DIRS and not rel.lower().startswith(SKIP_PATHS):
                        stack.append(e.path)
                elif e.is_file(follow_symlinks=False):
                    yield e.path, rel
            except OSError:
                continue

# Each worker process keeps its own Store
_store = None

def _init_worker(out_dir, known):
    global _store
    _store = Store(out_dir, known)

def _work(task):
    path, rel, kind = task
    before = (collections.Counter(_store.counts), collections.Counter(_store.bytes))
    try:
        size = os.path.getsize(path)
        with open(path, 'rb') as f:
            data = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ) if size else b''
        try:
            hash_ = h16(data)
            entry = read_file(_store, data, os.path.basename(path), kind, hash_)
            error = None
        finally:
            if size:
                data.close()
    except Exception as e:  # One file's problem shouldn't stop the scan
        hash_, entry, error = None, None, '%s: %s' % (type(e).__name__, e)
    counts = _store.counts - before[0]
    sizes = _store.bytes - before[1]
    return rel, hash_, entry, error, counts, sizes

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', required=True, help='The root of the Windows installation (the drive with Windows, Program Files, ...)')
    parser.add_argument('--build', required=True, help='The build, as data/builds names it (such as 26300.10075-AMD64)')
    parser.add_argument('--out', required=True, help='Where the new objects go (<out>/assets, in the assets branch\'s layout)')
    parser.add_argument('--inventory', help='verify-windows-files.py\'s list of every file (files.csv.gz)')
    parser.add_argument('--known', help='The paths the assets branch has already, one per line')
    parser.add_argument('--hives', help='The folder with the SOFTWARE and SYSTEM registry hives (default: Windows\\System32\\config under --root)')
    parser.add_argument('--workers', type=int, default=os.cpu_count() or 1)
    args = parser.parse_args()

    started = time.time()
    os.makedirs(args.out, exist_ok=True)
    known = set()
    if args.known:
        with open(args.known, encoding='utf-8-sig') as f:
            known = {line.strip() for line in f if line.strip()}
    log('%d objects in the assets branch already' % len(known))
    tasks = []
    for top in ('Windows', 'Program Files', 'Program Files (x86)'):
        for path, rel in walk(args.root, top):
            kind = classify(rel.lower())
            if kind:
                tasks.append((path, rel, kind))
    log('%d files to read' % len(tasks))

    files, entries, errors = {}, {}, []
    counts, sizes = collections.Counter(), collections.Counter()
    done = 0
    if args.workers > 1:
        import concurrent.futures
        executor = concurrent.futures.ProcessPoolExecutor(args.workers, initializer=_init_worker, initargs=(args.out, known))
        results = executor.map(_work, tasks, chunksize=16)
    else:
        _init_worker(args.out, known)
        executor = None
        results = map(_work, tasks)
    for rel, hash_, entry, error, c, s in results:
        done += 1
        if error:
            errors.append('%s: %s' % (rel, error))
        else:
            files[rel] = hash_
            entries[hash_] = entry
        counts.update(c)
        sizes.update(s)
        if done % 2000 == 0:
            log('%d of %d files read' % (done, len(tasks)))
    if executor:
        executor.shutdown()
    store = Store(args.out, known)
    registry = read_registry(args.hives or os.path.join(args.root, 'Windows', 'System32', 'config'), store)
    counts.update(store.counts)
    sizes.update(store.bytes)

    # The build's files: every file the VM's check listed (it leaves out a few folders this script reads), and those read here
    listed = {}
    if args.inventory:
        with gzip.open(args.inventory, 'rt', encoding='utf-8-sig', newline='') as f:
            for row in csv.DictReader(f):
                rel = re.sub(r'^[A-Za-z]:[\\/]', '', row['path'])
                listed[rel] = (int(row['size']), row['sha256'][:16].lower())
    for rel, hash_ in files.items():
        if rel not in listed:
            listed[rel] = (None, hash_)
    out = io.StringIO()
    w = csv.writer(out, lineterminator='\n')
    w.writerow(['path', 'size', 'hash'])
    for rel in sorted(listed, key=str.lower):
        size, hash_ = listed[rel]
        w.writerow([rel, '' if size is None else size, hash_])
    build_dir = 'builds/%s' % args.build
    store.put(build_dir + '/files.csv.gz', gzip.compress(out.getvalue().encode('utf-8'), 9, mtime=0), replace=True)
    index = {'build': args.build, 'files': dict(sorted(files.items(), key=lambda kv: kv[0].lower())),
             'entries': dict(sorted(entries.items())), 'registry': registry}
    store.put(build_dir + '/index.json.gz',
              gzip.compress(json.dumps(index, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode('utf-8'), 9, mtime=0),
              replace=True)

    summary = {'build': args.build, 'files': len(files), 'fileVersions': len(entries), 'listed': len(listed), 'errors': errors[:200],
               'errorCount': len(errors), 'new': dict(sorted(counts.items())), 'newBytes': dict(sorted(sizes.items())),
               'seconds': round(time.time() - started)}
    with open(os.path.join(args.out, 'summary.json'), 'w', encoding='utf-8') as f:
        json.dump(summary, f, indent=1)
    log('Read %d files (%d versions) in %d s; %d errors; new: %s' % (len(files), len(entries), summary['seconds'], len(errors),
        ', '.join('%s %d (%.1f MB)' % (k, counts[k], sizes[k] / 1e6) for k in sorted(counts))))

if __name__ == '__main__':
    main()
