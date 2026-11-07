# scan-symbols.py
# Finds Windows feature names and their IDs by reading the public symbols (PDBs) of the system's binaries.
#
# How it works:
#   1. Enumerates PE images (dll/exe/sys/...) under the scan roots and reads each image's CodeView record (PDB name + GUID/age).
#   2. Downloads each unique PDB from the Microsoft symbol server (or uses an existing local symbol store).
#   3. Reads the PDB's global symbol records and looks for the symbols that WIL feature staging emits:
#        Feature_<Name>__descriptor           C++ wil::Feature descriptor: { state*, UINT32 id, lastUsedTickCount* }
#        Feature_<Name>__private_descriptor   C-style descriptor: { featureState*, reporting*, traits*, UINT32 id, ... }
#        __WilFeatureTraits_Feature_<Name>::id  S_CONSTANT, only present in PDBs that include more than publics
#   4. For descriptor symbols, reads the feature ID out of the image file at the symbol's RVA. C++ features without a descriptor (older
#      WIL) get their ID from the code of their GetCurrentFeatureEnabledState, which passes it to GetFeatureEnabledState.
#   5. For binaries with features, decodes their ARM64 or x64 code to find the functions that check each feature, plus dependencies,
#      default states and hints about what the feature does (see "Usage analysis" below).
#
# Only the Python standard library is used, so it runs on any GitHub-hosted Windows runner (x64 or ARM64) without installing anything.
# mach2 (the tool this replaces) is retired and fails on current PDBs with "The operation completed successfully., system:0".

import argparse
import base64
import bisect
import concurrent.futures
import http.client
import json
import mmap
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse
import urllib.request

DEFAULT_SYMBOL_SERVER = 'https://msdl.microsoft.com/download/symbols'
USER_AGENT = 'Microsoft-Symbol-Server/10.0.0.0'
RESULTS_CACHE_VERSION = 3

IMAGE_EXTENSIONS = {'.dll', '.exe', '.sys', '.cpl', '.ocx', '.scr', '.ax', '.drv', '.tsp', '.ime', '.efi', '.acm'}

# (path, recursive). Paths that don't exist are skipped.
def default_roots():
    windir = os.environ.get('SystemRoot', r'C:\Windows')
    program_files = os.environ.get('ProgramFiles', r'C:\Program Files')
    return [
        (windir, False),                                        # explorer.exe and friends
        (os.path.join(windir, 'System32'), True),
        (os.path.join(windir, 'SystemApps'), True),
        (os.path.join(windir, 'ImmersiveControlPanel'), True),
        (os.path.join(windir, 'ShellComponents'), True),
        (os.path.join(windir, 'ShellExperiences'), True),
        (os.path.join(windir, 'PrintDialog'), True),
        (os.path.join(windir, 'UUS'), True),
        (os.path.join(program_files, 'WindowsApps'), True),    # Inbox app packages (Start, Taskbar, etc.); readable when elevated
    ]

# Directory names skipped while recursing. DriverStore holds third-party drivers (no public symbols) and duplicates of System32\drivers.
SKIP_DIR_NAMES = {'driverstore', 'winsxs', 'catroot', 'catroot2', 'logfiles', 'sru', 'wdi', 'config', 'spool', 'tasks', 'winevt'}

# ---------------------------------------------------------------------------
# PE images
# ---------------------------------------------------------------------------

class PeInfo:
    __slots__ = ('path', 'ptr_size', 'image_base', 'image_size', 'sections', 'pdb_name', 'pdb_key')

def read_pe_info(path):
    """Returns a PeInfo with the CodeView (RSDS) PDB reference, or None if the file isn't a PE with one."""
    try:
        with open(path, 'rb') as f:
            head = f.read(4096)
            if len(head) < 0x40 or head[:2] != b'MZ':
                return None
            pe_off = struct.unpack_from('<I', head, 0x3C)[0]
            if pe_off + 0x200 > len(head):
                f.seek(0)
                head = f.read(pe_off + 0x400)
            if head[pe_off:pe_off + 4] != b'PE\0\0':
                return None
            num_sections = struct.unpack_from('<H', head, pe_off + 6)[0]
            opt_size = struct.unpack_from('<H', head, pe_off + 20)[0]
            opt = pe_off + 24
            magic = struct.unpack_from('<H', head, opt)[0]
            if magic == 0x20B:
                ptr_size = 8
                image_base = struct.unpack_from('<Q', head, opt + 24)[0]
                data_dirs = opt + 112
            elif magic == 0x10B:
                ptr_size = 4
                image_base = struct.unpack_from('<I', head, opt + 28)[0]
                data_dirs = opt + 96
            else:
                return None
            image_size = struct.unpack_from('<I', head, opt + 56)[0]
            num_dirs = struct.unpack_from('<I', head, data_dirs - 4)[0]
            if num_dirs <= 6:
                return None
            debug_rva, debug_size = struct.unpack_from('<II', head, data_dirs + 6 * 8)
            sec_off = opt + opt_size
            if sec_off + num_sections * 40 > len(head):
                f.seek(0)
                head = f.read(sec_off + num_sections * 40)
            sections = []
            for i in range(num_sections):
                vsize, va, raw_size, raw_ptr = struct.unpack_from('<IIII', head, sec_off + i * 40 + 8)
                sections.append((va, max(vsize, raw_size), raw_size, raw_ptr))
            if not debug_rva or not debug_size:
                return None
            debug_off = rva_to_offset(sections, debug_rva)
            if debug_off is None:
                return None
            f.seek(debug_off)
            debug_dir = f.read(min(debug_size, 28 * 32))
            for i in range(len(debug_dir) // 28):
                dbg_type, data_size, _, data_ptr = struct.unpack_from('<IIII', debug_dir, i * 28 + 12)
                if dbg_type != 2 or data_size < 25:  # IMAGE_DEBUG_TYPE_CODEVIEW
                    continue
                f.seek(data_ptr)
                cv = f.read(min(data_size, 1024))
                if cv[:4] != b'RSDS':
                    continue
                d1, d2, d3 = struct.unpack_from('<IHH', cv, 4)
                age = struct.unpack_from('<I', cv, 20)[0]
                raw_name = cv[24:].split(b'\0', 1)[0].decode('utf-8', 'replace')
                pdb_name = re.split(r'[\\/]', raw_name)[-1]
                if not pdb_name:
                    continue
                info = PeInfo()
                info.path = path
                info.ptr_size = ptr_size
                info.image_base = image_base
                info.image_size = image_size
                info.sections = sections
                info.pdb_name = pdb_name
                info.pdb_key = '%08X%04X%04X%s%X' % (d1, d2, d3, cv[12:20].hex().upper(), age)
                return info
    except OSError:
        return None
    return None

def rva_to_offset(sections, rva):
    for va, vsize, raw_size, raw_ptr in sections:
        if va <= rva < va + vsize:
            delta = rva - va
            if delta >= raw_size:
                return None  # Uninitialized data, not backed by the file
            return raw_ptr + delta
    return None

def read_image_u32s(info, rvas):
    """Reads ptr_size*4 bytes at each RVA. Returns {rva: bytes}."""
    out = {}
    length = info.ptr_size * 4
    with open(info.path, 'rb') as f:
        for rva in sorted(set(rvas)):
            off = rva_to_offset(info.sections, rva)
            if off is None:
                continue
            f.seek(off)
            data = f.read(length)
            if len(data) == length:
                out[rva] = data
    return out

def enumerate_images(roots):
    for root, recursive in roots:
        if not os.path.isdir(root):
            continue
        if not recursive:
            try:
                with os.scandir(root) as it:
                    for entry in it:
                        if entry.is_file(follow_symlinks=False) and os.path.splitext(entry.name)[1].lower() in IMAGE_EXTENSIONS:
                            yield entry.path
            except OSError:
                pass
            continue
        stack = [root]
        while stack:
            current = stack.pop()
            try:
                with os.scandir(current) as it:
                    for entry in it:
                        try:
                            if entry.is_dir(follow_symlinks=False):
                                if entry.name.lower() not in SKIP_DIR_NAMES:
                                    stack.append(entry.path)
                            elif entry.is_file(follow_symlinks=False) and os.path.splitext(entry.name)[1].lower() in IMAGE_EXTENSIONS:
                                yield entry.path
                        except OSError:
                            pass
            except OSError:
                pass

# ---------------------------------------------------------------------------
# PDB (MSF 7.0) reading - only what's needed to walk the global symbol records
# ---------------------------------------------------------------------------

MSF7_MAGIC = b'Microsoft C/C++ MSF 7.00\r\n\x1aDS\x00\x00\x00'

S_CONSTANT = 0x1107
S_LDATA32 = 0x110C
S_GDATA32 = 0x110D
S_PUB32 = 0x110E

NUMERIC_LEAF_FORMATS = {0x8000: '<b', 0x8001: '<h', 0x8002: '<H', 0x8003: '<i', 0x8004: '<I', 0x8009: '<q', 0x800A: '<Q'}

RE_CPP_DESCRIPTOR = re.compile(r'^Feature_(\w+?)__descriptor$')
RE_C_DESCRIPTOR = re.compile(r'^Feature_(\w+?)__private_descriptor$')
RE_TRAITS_ID = re.compile(r'__WilFeatureTraits_Feature_(\w+?)>?::id$')
RE_CPP_STATE_FUNCTION = re.compile(r'^\?GetCurrent(?:FeatureEnabled|Variant)State@\?\$FeatureImpl@U__Wil(?:External)?FeatureTraits_Feature_(\w+?)@@@')

class Pdb:
    def __init__(self, path):
        self._file = open(path, 'rb')
        try:
            self._mm = mmap.mmap(self._file.fileno(), 0, access=mmap.ACCESS_READ)
        except Exception:
            self._file.close()
            raise
        mm = self._mm
        if mm[:32] != MSF7_MAGIC:
            self.close()
            raise ValueError('not an MSF 7.0 PDB')
        self.block_size, _, _, dir_bytes, _, block_map_addr = struct.unpack_from('<6I', mm, 32)
        bs = self.block_size
        n_dir_blocks = (dir_bytes + bs - 1) // bs
        dir_blocks = struct.unpack_from('<%dI' % n_dir_blocks, mm, block_map_addr * bs)
        directory = b''.join(mm[b * bs:(b + 1) * bs] for b in dir_blocks)[:dir_bytes]
        num_streams = struct.unpack_from('<I', directory, 0)[0]
        sizes = struct.unpack_from('<%dI' % num_streams, directory, 4)
        pos = 4 + 4 * num_streams
        self.streams = []
        for size in sizes:
            if size == 0xFFFFFFFF:
                self.streams.append((0, ()))
                continue
            n = (size + bs - 1) // bs
            self.streams.append((size, struct.unpack_from('<%dI' % n, directory, pos)))
            pos += 4 * n

    def close(self):
        try:
            self._mm.close()
        finally:
            self._file.close()

    def stream(self, index):
        if index >= len(self.streams):
            return b''
        size, blocks = self.streams[index]
        bs = self.block_size
        mm = self._mm
        return b''.join(mm[b * bs:(b + 1) * bs] for b in blocks)[:size]

    def feature_symbols(self):
        """Yields (kind, name, rva_or_value): kind is 'cpp', 'c' (descriptor RVAs), 'code' (the RVA of a C++ feature's
        GetCurrentFeatureEnabledState or GetCurrentVariantState) or 'const' (ID value)."""
        dbi = self.stream(3)
        if len(dbi) < 64:
            return
        (sym_record_stream,) = struct.unpack_from('<H', dbi, 20)
        mod_size, sc_size, sm_size, src_size, tsm_size = struct.unpack_from('<5i', dbi, 24)
        dbg_size, ec_size = struct.unpack_from('<ii', dbi, 48)
        dbg_off = 64 + mod_size + sc_size + sm_size + src_size + tsm_size + ec_size
        dbg_streams = struct.unpack_from('<%dH' % (dbg_size // 2), dbi, dbg_off) if dbg_size >= 2 else ()
        section_vas = []
        if len(dbg_streams) > 5 and dbg_streams[5] != 0xFFFF:
            sh = self.stream(dbg_streams[5])
            section_vas = [struct.unpack_from('<I', sh, i * 40 + 12)[0] for i in range(len(sh) // 40)]

        rec = self.stream(sym_record_stream)
        n = len(rec)
        pos = 0
        find = rec.find
        while pos + 4 <= n:
            rec_len, kind = struct.unpack_from('<HH', rec, pos)
            end = pos + 2 + rec_len
            if rec_len < 2:
                break
            if kind in (S_PUB32, S_GDATA32, S_LDATA32, S_CONSTANT) and find(b'Feature_', pos + 4, end) != -1:
                body = pos + 4
                if kind == S_CONSTANT:
                    leaf = struct.unpack_from('<H', rec, body + 4)[0]
                    p = body + 6
                    if leaf < 0x8000:
                        value = leaf
                    elif leaf in NUMERIC_LEAF_FORMATS:
                        fmt = NUMERIC_LEAF_FORMATS[leaf]
                        value = struct.unpack_from(fmt, rec, p)[0]
                        p += struct.calcsize(fmt)
                    else:
                        pos = end
                        continue
                    name = rec[p:find(b'\0', p, end) if find(b'\0', p, end) != -1 else end].decode('utf-8', 'replace')
                    m = RE_TRAITS_ID.search(name)
                    if m and value:
                        yield ('const', m.group(1), value & 0xFFFFFFFF)
                else:
                    offset, segment = struct.unpack_from('<IH', rec, body + 4)
                    p = body + 10
                    z = find(b'\0', p, end)
                    name = rec[p:z if z != -1 else end].decode('utf-8', 'replace')
                    m = RE_CPP_DESCRIPTOR.match(name)
                    kind_name = 'cpp'
                    if not m:
                        m = RE_C_DESCRIPTOR.match(name)
                        kind_name = 'c'
                    if not m and kind == S_PUB32:
                        m = RE_CPP_STATE_FUNCTION.match(name)
                        kind_name = 'code'
                    if m and 1 <= segment <= len(section_vas):
                        yield (kind_name, m.group(1), section_vas[segment - 1] + offset)
            pos = end

def extract_features(pdb_path, info):
    """Returns a sorted list of [name, id, source] found for one image/PDB pair."""
    pdb = Pdb(pdb_path)
    try:
        symbols = list(pdb.feature_symbols())
    finally:
        pdb.close()

    found = set()
    descriptors = [(k, name, rva) for k, name, rva in symbols if k in ('cpp', 'c')]
    for k, name, value in symbols:
        if k == 'const':
            found.add((name, value, 'const'))
    if descriptors:
        data = read_image_u32s(info, [rva for _, _, rva in descriptors])
        ps = info.ptr_size
        ptr_fmt = '<Q' if ps == 8 else '<I'
        lo, hi = info.image_base, info.image_base + info.image_size
        for k, name, rva in descriptors:
            raw = data.get(rva)
            if raw is None:
                continue
            # Both descriptor layouts start with a pointer to the feature's state in this image; use it to reject anything that isn't a descriptor.
            first_ptr = struct.unpack_from(ptr_fmt, raw, 0)[0]
            if not lo <= first_ptr < hi:
                continue
            id_offset = ps if k == 'cpp' else ps * 3
            feature_id = struct.unpack_from('<I', raw, id_offset)[0]
            if feature_id:
                found.add((name, feature_id, k))
    # C++ features without a descriptor (binaries built with older WIL, such as some x64 builds): the ID is the first argument their
    # GetCurrentFeatureEnabledState passes to GetFeatureEnabledState, with the change time as the second
    named = {name for name, _, k in found if k != 'const'}
    code = [(name, rva) for k, name, rva in symbols if k == 'code' and name not in named]
    if code and info.ptr_size == 8:
        img = CodeImage(info.path)
        for name, rva in code:
            if name in named:
                continue  # One feature has several of these functions (ARM64 and ARM64EC copies, the variant state)
            if img.in_x64(rva):
                first, second = x64_first_call_args(img, rva)
            elif any(start <= rva < end for start, end in img.code_ranges):
                first, second = arm64_first_call_args(img, rva)
            else:
                continue
            if first and second is not None and not second & ~0x63:
                found.add((name, first, 'code'))
                named.add(name)
    return sorted([list(x) for x in found])

# ---------------------------------------------------------------------------
# Usage analysis: which functions check each feature, and what else the binary reveals about it
# ---------------------------------------------------------------------------
#
# Every feature a binary uses comes with WIL plumbing inside it: a descriptor, state variables and small per-feature functions
# (wil::details::FeatureImpl<T>::__private_IsEnabled, Feature_<Name>__private_IsEnabledDeviceUsageNoInline, ...). Code that checks the
# feature calls one of those functions or forms the address of one of those variables, so decoding the binary's code for calls and
# address computations that land on them finds the functions that check it: on ARM64, BL/B and ADRP + ADD/LDR/STR or ADR; on x64,
# CALL/JMP and RIP-relative operands. The PDB's public symbols name those functions. The same pass also gives:
#   - dependencies: one feature's plumbing checking another feature is how C++ features implement "requires"
#     (C-style descriptors list the features they require instead),
#   - lookup tables: a function referencing many different features (KernelBase's GetFeatureDescriptor) is a table, not a check,
#   - hints: the strings, source file paths, imported functions, named data and callees of the checking functions,
#   - the default state and when a change takes effect: C-style descriptors hold both; for C++ features they're read from the code of
#     GetCurrentFeatureEnabledState (tested against the feature store's ImageDefault entries: all 1,301 features that had one agreed). Features a binary uses
#     but another one defines ("external" features) get neither from it, since the defining binary decides.
# ARM64 and x64 code is decoded (ARM64X and ARM64EC binaries have both); binaries for other architectures (x86) get no usage data.

IMAGE_FILE_MACHINE_ARM64 = 0xAA64
IMAGE_FILE_MACHINE_AMD64 = 0x8664
IMAGE_SCN_MEM_EXECUTE = 0x20000000

RE_PLUMBING_CPP = re.compile(r'^\?(impl@\?1\?\?)?(\w+)@\?\$(?:Feature|FeatureImpl)@U__Wil(?:External)?FeatureTraits_Feature_(\w+?)@@@')  # Members of wil::Feature<T> and wil::details::FeatureImpl<T>, and GetImpl's static `impl` object
RE_PLUMBING_C = re.compile(r'^#?Feature_(\w+?)__(private_\w+|descriptor)$')  # '#' marks ARM64EC functions
RE_PLUMBING_TRAITS = re.compile(r'^Feature_(\w+)_logged_traits$')
RE_PLUMBING_KERNEL = re.compile(r'^#?Feature_(\w+?)_(IsEnabled\w*|ReportUsage\w*)$')  # Kernel-mode wrappers
DATA_ONLY_MEMBERS = {'logged_traits', 'private_requiresFeatures'}  # Referenced from descriptors, not code; identical ones are merged by the linker

TABLE_MIN_FEATURES = 20   # A function referencing more different features than this is a lookup table
CONTEXT_CALLERS = 3       # Hints are collected from this many of a feature's callers (the ones referencing it most)
LIMITS = {'callers': 10, 'strings': 10, 'sources': 3, 'imports': 8, 'symbols': 8, 'calls': 5}
STAGES = {0: 'alwaysDisabled', 1: 'disabled', 2: 'enabled', 3: 'alwaysEnabled'}
CHANGE_TIMES = {0: 'read', 1: 'moduleReload', 2: 'session', 3: 'reboot'}  # FEATURE_CHANGE_TIME in featurestagingapi.h

# Hints that every feature check or every function has, which say nothing about the feature
NOISE_IMPORTS = {'InitOnceExecuteOnce', 'InitOnceBeginInitialize', 'InitOnceComplete', 'AcquireSRWLockExclusive', 'AcquireSRWLockShared',
                 'ReleaseSRWLockExclusive', 'ReleaseSRWLockShared', 'TryAcquireSRWLockExclusive', 'GetLastError', 'SetLastError', 'GetProcessHeap',
                 'HeapAlloc', 'HeapFree', 'HeapReAlloc', 'LocalFree', 'CoTaskMemFree', 'CoTaskMemAlloc', 'abort', 'free', 'malloc', 'realloc', 'calloc',
                 'memset', 'memcpy', 'memmove', 'memcmp', 'wcslen', 'strlen', 'RaiseFailFastException', 'EventWriteTransfer', 'EventRegister',
                 'EventUnregister', 'EventSetInformation', 'EventActivityIdControl', 'OutputDebugStringW', 'IsDebuggerPresent', 'GetTickCount64',
                 'QueryPerformanceCounter', 'GetCurrentThreadId', 'GetCurrentProcessId', 'RtlNtStatusToDosErrorNoTeb', 'WindowsDeleteString',
                 'WindowsCreateStringReference', 'WindowsCreateString', 'WindowsGetStringRawBuffer', 'SysFreeString', 'SysAllocString'}
NOISE_NAME_PARTS = ('__guard_', '__security_', 'Wil_Staging', 'wil::details::', 'guid_v<', "vftable'", '_tlg', 'TraceLogging', 'RTL_RUN_ONCE',
                    'g_header_init_', 'g_pfn', 'wil::', 'Microsoft::WRL::', '__imp_', '_guard_', '$thunk', 'std::', 'winrt::impl::', 'winrt::param::')
NOISE_CALL_PREFIXES = ('wil::', 'Microsoft::WRL::', 'std::', 'winrt::impl::', 'winrt::param::', 'winrt::hstring', 'winrt::com_ptr', 'winrt::Windows::Foundation::IUnknown',
                       '__', '_guard', 'operator', '`', 'memset', 'memcpy', 'memmove', 'free', 'malloc', 'wistd::', 'ATL::')
RE_SOURCE_FILE = re.compile(r'\\[^\\]+\.(?:cpp|cxx|cc|c)$', re.I)
RE_WIL_PATH = re.compile(r'Wil\.Internal|(?:^|\\)wil\\', re.I)


def plumbing_of(name):
    """(feature name, member) when the symbol is part of a feature's own WIL plumbing, else None."""
    m = RE_PLUMBING_CPP.match(name)
    if m:
        return m.group(3), 'impl' if m.group(1) else m.group(2)
    m = RE_PLUMBING_C.match(name)
    if m:
        return m.group(1), m.group(2)
    m = RE_PLUMBING_TRAITS.match(name)
    if m:
        return m.group(1), 'logged_traits'
    m = RE_PLUMBING_KERNEL.match(name)
    if m:
        return m.group(1), m.group(2)
    return None


def read_public_symbols(pdb_path):
    """[(rva, name, is_function)] for every public, global data and local data symbol in the PDB."""
    pdb = Pdb(pdb_path)
    try:
        dbi = pdb.stream(3)
        if len(dbi) < 64:
            return []
        (sym_record_stream,) = struct.unpack_from('<H', dbi, 20)
        mod_size, sc_size, sm_size, src_size, tsm_size = struct.unpack_from('<5i', dbi, 24)
        dbg_size, ec_size = struct.unpack_from('<ii', dbi, 48)
        dbg_off = 64 + mod_size + sc_size + sm_size + src_size + tsm_size + ec_size
        dbg_streams = struct.unpack_from('<%dH' % (dbg_size // 2), dbi, dbg_off) if dbg_size >= 2 else ()
        if len(dbg_streams) <= 5 or dbg_streams[5] == 0xFFFF:
            return []
        sh = pdb.stream(dbg_streams[5])
        section_vas = [struct.unpack_from('<I', sh, i * 40 + 12)[0] for i in range(len(sh) // 40)]
        rec = pdb.stream(sym_record_stream)
    finally:
        pdb.close()
    out = []
    pos, n = 0, len(rec)
    find = rec.find
    while pos + 4 <= n:
        rec_len, kind = struct.unpack_from('<HH', rec, pos)
        end = pos + 2 + rec_len
        if rec_len < 2:
            break
        if kind in (S_PUB32, S_GDATA32, S_LDATA32) and end - pos >= 14:
            flags_or_type, offset, segment = struct.unpack_from('<IIH', rec, pos + 4)
            if 1 <= segment <= len(section_vas):
                z = find(b'\0', pos + 14, end)
                out.append((section_vas[segment - 1] + offset, rec[pos + 14:z if z != -1 else end].decode('utf-8', 'replace'),
                            kind == S_PUB32 and bool(flags_or_type & 2)))  # CVPSF_FUNCTION
        pos = end
    return out


class CodeImage:
    """A whole PE image, with the RVA ranges that hold ARM64 code and x64 code, and the function bounds from its exception table."""

    def __init__(self, path):
        with open(path, 'rb') as f:
            self.data = d = f.read()
        pe = struct.unpack_from('<I', d, 0x3C)[0]
        self.machine = struct.unpack_from('<H', d, pe + 4)[0]
        nsec, = struct.unpack_from('<H', d, pe + 6)
        opt_size, = struct.unpack_from('<H', d, pe + 20)
        opt = pe + 24
        if struct.unpack_from('<H', d, opt)[0] != 0x20B:
            raise ValueError('not a 64-bit image')
        self.image_base, = struct.unpack_from('<Q', d, opt + 24)
        self.image_size, = struct.unpack_from('<I', d, opt + 56)
        num_dirs, = struct.unpack_from('<I', d, opt + 108)
        dirs = opt + 112
        exc_rva, exc_size = struct.unpack_from('<II', d, dirs + 3 * 8) if num_dirs > 3 else (0, 0)
        lc_rva = struct.unpack_from('<I', d, dirs + 10 * 8)[0] if num_dirs > 10 else 0
        self.sections = []  # (va, vsize, raw_size, raw_ptr, characteristics)
        for i in range(nsec):
            o = opt + opt_size + i * 40
            vsize, va, raw_size, raw_ptr = struct.unpack_from('<IIII', d, o + 8)
            self.sections.append((va, vsize, raw_size, raw_ptr, struct.unpack_from('<I', d, o + 36)[0]))
        self.x64_ranges = []
        self.roots = {}  # x64: start of each later part of a function split into parts -> start of its first part
        self.code_ranges = self._code_ranges(lc_rva)
        if self.machine == IMAGE_FILE_MACHINE_ARM64:
            self.functions = self._functions(exc_rva, exc_size)
        elif self.machine == IMAGE_FILE_MACHINE_AMD64 and not self.code_ranges:
            self.x64_ranges = [(va, va + min(vsize, raw_size)) for va, vsize, raw_size, _, chars in self.sections if chars & IMAGE_SCN_MEM_EXECUTE]
            self.functions = self._functions_x64(exc_rva, exc_size)
        else:
            self.functions = []
        self.x64_ranges.sort()
        self._x64_starts = [s for s, _ in self.x64_ranges]

    def _section(self, rva):
        for s in self.sections:
            if s[0] <= rva < s[0] + max(s[1], s[2]):
                return s
        return None

    def read(self, rva, n):
        s = self._section(rva)
        if not s or rva - s[0] >= s[2]:
            return b''
        start = s[3] + rva - s[0]
        return self.data[start:min(start + n, s[3] + s[2])]

    def is_exec(self, rva):
        s = self._section(rva)
        return bool(s and s[4] & IMAGE_SCN_MEM_EXECUTE)

    def _code_ranges(self, lc_rva):
        # ARM64X and ARM64EC images carry a code map (CHPE metadata, from the load config) that says which ranges are ARM64, ARM64EC or x64
        lc = self.read(lc_rva, 208) if lc_rva else b''
        chpe = struct.unpack_from('<Q', lc, 200)[0] if len(lc) == 208 and struct.unpack_from('<I', lc, 0)[0] >= 208 else 0
        if chpe and self.image_base <= chpe < self.image_base + self.image_size:
            meta = self.read(chpe - self.image_base, 12)
            if len(meta) == 12:
                _version, code_map, count = struct.unpack('<III', meta)
                entries = self.read(code_map, count * 8)
                ranges = []
                for i in range(len(entries) // 8):
                    start, length = struct.unpack_from('<II', entries, i * 8)
                    if start & 3 in (0, 1):  # 0 = ARM64, 1 = ARM64EC, 2 = x64
                        ranges.append((start & ~3, (start & ~3) + length))
                    elif start & 3 == 2:
                        self.x64_ranges.append((start & ~3, (start & ~3) + length))
                return ranges
        if self.machine == IMAGE_FILE_MACHINE_ARM64:
            return [(va, va + min(vsize, raw_size)) for va, vsize, raw_size, _, chars in self.sections if chars & IMAGE_SCN_MEM_EXECUTE]
        return []

    def _functions(self, exc_rva, exc_size):
        """Sorted (begin, end) RVAs from the ARM64 .pdata table."""
        out = []
        raw = self.read(exc_rva, exc_size) if exc_size else b''
        for i in range(len(raw) // 8):
            begin, unwind = struct.unpack_from('<II', raw, i * 8)
            flag = unwind & 3
            if flag in (1, 2):  # Packed unwind data
                length = (unwind >> 2) & 0x7FF
            elif flag == 0:  # RVA of the .xdata record
                x = self.read(unwind, 4)
                if len(x) < 4:
                    continue
                length = struct.unpack('<I', x)[0] & 0x3FFFF
            else:
                continue
            if length:
                out.append((begin, begin + length * 4))
        out.sort()
        return out

    def _functions_x64(self, exc_rva, exc_size):
        """Sorted (begin, end) RVAs from the x64 .pdata table. The compiler can split a function into parts (cold code moved away, for
        example); a later part's unwind information chains to the part before it, which is how self.roots is filled in."""
        raw = self.read(exc_rva, exc_size) if exc_size else b''
        entries = [struct.unpack_from('<III', raw, i * 12) for i in range(len(raw) // 12)]
        parent = {}
        for begin, end, unwind in entries:
            if unwind & 1:  # The RVA of another function's entry, whose unwind information this part shares
                ref = self.read(unwind & ~1, 4)
                if len(ref) == 4:
                    parent[begin] = struct.unpack('<I', ref)[0]
                continue
            u = self.read(unwind, 4)
            if len(u) == 4 and (u[0] >> 3) & 4:  # UNW_FLAG_CHAININFO: the entry of the previous part follows the unwind codes
                chained = self.read(unwind + 4 + 2 * ((u[2] + 1) & ~1), 4)
                if len(chained) == 4:
                    parent[begin] = struct.unpack('<I', chained)[0]
        for begin in parent:
            root = begin
            for _ in range(16):
                if root not in parent or parent[root] == root:
                    break
                root = parent[root]
            self.roots[begin] = root
        return sorted((b, e) for b, e, _ in entries if e > b)

    def in_x64(self, rva):
        i = bisect.bisect_right(self._x64_starts, rva) - 1
        return i >= 0 and rva < self.x64_ranges[i][1]

    def read_string(self, rva):
        """A UTF-16 or ASCII string at the RVA, or None if what's there doesn't look like text."""
        raw = self.read(rva, 512)
        end = 0
        while end + 1 < len(raw) and (raw[end] or raw[end + 1]):
            end += 2
        if 6 <= end and end + 1 < len(raw):
            try:
                s = raw[:end].decode('utf-16-le')
                if s.isprintable() and sum(c.isascii() for c in s) >= len(s) * 0.9 and sum(c.isalpha() for c in s) >= 2:
                    return s
            except UnicodeDecodeError:
                pass
        z = raw.find(b'\0')
        if z >= 4 and all(0x20 <= c < 0x7F for c in raw[:z]) and sum(chr(c).isalpha() for c in raw[:z]) >= 2:
            return raw[:z].decode('ascii')
        return None


def sweep_arm64(img, start, end, on_ref):
    """Decodes the ARM64 code in [start, end) and calls on_ref(pc, target, kind) for every BL ('call') or B ('jump'), and for every
    address formed with ADRP + ADD/LDR/STR or with ADR ('addr')."""
    code = img.read(start, end - start)
    words = memoryview(code[:len(code) & ~3]).cast('I')
    pages = [None] * 32  # register -> (page address from an ADRP, pc of that ADRP)
    pc = start - 4
    for w in words:
        pc += 4
        top = w & 0xFC000000
        if top == 0x94000000 or top == 0x14000000:  # BL / B
            imm = w & 0x3FFFFFF
            on_ref(pc, pc + ((imm - 0x4000000 if imm & 0x2000000 else imm) << 2), 'call' if top == 0x94000000 else 'jump')
        elif (w & 0x9F000000) == 0x90000000:  # ADRP
            imm = ((w >> 3) & 0x1FFFFC) | ((w >> 29) & 3)
            pages[w & 31] = ((pc & ~0xFFF) + ((imm - 0x200000 if imm & 0x100000 else imm) << 12), pc)
        elif (w & 0x9F000000) == 0x10000000:  # ADR
            imm = ((w >> 3) & 0x1FFFFC) | ((w >> 29) & 3)
            on_ref(pc, pc + (imm - 0x200000 if imm & 0x100000 else imm), 'addr')
        elif (w & 0xFF800000) == 0x91000000:  # ADD Xd, Xn, #imm
            p = pages[(w >> 5) & 31]
            if p and pc - p[1] <= 256:
                on_ref(pc, p[0] + (((w >> 10) & 0xFFF) << (12 if w & 0x400000 else 0)), 'addr')
            pages[w & 31] = None
        elif (w & 0x3B000000) == 0x39000000:  # LDR/STR with an unsigned immediate offset
            p = pages[(w >> 5) & 31]
            if p and pc - p[1] <= 256:
                size = w >> 30
                scale = 4 if (w & 0x4000000 and size == 0 and w & 0x800000) else size  # 128-bit SIMD loads scale by 16
                on_ref(pc, p[0] + (((w >> 10) & 0xFFF) << scale), 'addr')
            if not w & 0x4000000 and w & 0xC00000:  # A load into a general register replaces what it held
                pages[w & 31] = None


def arm64_first_call_args(img, rva):
    """(w0, w1) at an ARM64 function's first call (BL), each None unless it was loaded with a constant."""
    code = img.read(rva, 96)
    w0 = w1 = None
    for i in range(len(code) // 4):
        w = struct.unpack_from('<I', code, i * 4)[0]
        if (w & 0xFC000000) == 0x94000000:  # BL
            break
        if (w & 0xFF00001F) == 0x18000000:  # LDR w0, literal
            imm = (w >> 5) & 0x7FFFF
            lit = img.read(rva + i * 4 + ((imm - 0x80000 if imm & 0x40000 else imm) << 2), 4)
            w0 = struct.unpack('<I', lit)[0] if len(lit) == 4 else None
        elif (w & 0xFF80001F) == 0x52800000:  # MOVZ w0, #imm
            w0 = ((w >> 5) & 0xFFFF) << (16 * ((w >> 21) & 3))
        elif (w & 0xFF80001F) == 0x72800000 and w0 is not None:  # MOVK w0, #imm, lsl #16
            shift = 16 * ((w >> 21) & 3)
            w0 = (w0 & ~(0xFFFF << shift)) | (((w >> 5) & 0xFFFF) << shift)
        elif (w & 0xFF80001F) == 0x52800001:  # MOVZ w1, #imm
            w1 = (w >> 5) & 0xFFFF
    return w0, w1


def cpp_change_time(img, rva, feature_id):
    """The change time a C++ feature's GetCurrentFeatureEnabledState passes to GetFeatureEnabledState(id, changeTime), or None.
    The function starts by loading the ID into the first argument (w0 on ARM64, ecx on x64) and the change time into the second (w1, edx)
    before its first call; the ID must match. Newer binaries add flags to the second argument: 0x40 for a feature defined in another
    binary (which has no change time of its own here) and 0x20 (meaning unknown). The low two bits are the change time either way."""
    first, second = (x64_first_call_args if img.in_x64(rva) else arm64_first_call_args)(img, rva)
    if first != feature_id or second is None or second & ~0x23:
        return None
    return second & 3


def cpp_default(img, rva):
    """The default stage of a C++ feature (1 = disabled, 2 = enabled) from its GetCurrentFeatureEnabledState, or None.
    After GetFeatureEnabledState returns, the function masks out the configured state (AND wS, w0, #0xffffff3f; 0 means not configured)
    and branches on it. An unconfigured feature counts as enabled if the 'enabled' bit (#0x40) is loaded before a CBZ on that state,
    or set right after a CBNZ on it; otherwise as disabled. (x64 code: see cpp_default_x64.)"""
    if img.in_x64(rva):
        return cpp_default_x64(img, rva)
    code = img.read(rva, 200)
    state_reg = None
    flag_loaded = False
    for i in range(len(code) // 4):
        w = struct.unpack_from('<I', code, i * 4)[0]
        if state_reg is None:
            if (w & 0xFFFFFFE0) == 0x12187400:  # AND wS, w0, #0xffffff3f
                state_reg = w & 31
            continue
        if (w & 0xFFFFFFE0) == 0x52800800:  # MOVZ wX, #0x40
            flag_loaded = True
        elif (w & 0xFF00001F) == 0x34000000 | state_reg:  # CBZ wS
            return 2 if flag_loaded else 1
        elif (w & 0xFF00001F) == 0x35000000 | state_reg:  # CBNZ wS
            nxt = struct.unpack_from('<I', code, (i + 1) * 4)[0] if (i + 2) * 4 <= len(code) else 0
            return 2 if (nxt & 0xFFFFFC00) == 0x321A0000 else 1  # ORR wD, wN, #0x40
        elif (w & 0x7C000000) == 0x14000000 or w == 0xD65F03C0:  # B, BL or RET before the decision: not the expected shape
            return None
    return None


# x64 instructions have variable lengths, so finding the references takes decoding every instruction's length: its prefixes, opcode,
# ModRM/SIB bytes, displacement and immediate. Each opcode table entry says whether a ModRM byte follows (X64_MODRM) and which immediate.
X64_MODRM = 0x80
(X64_NONE, X64_I8, X64_I16, X64_IZ, X64_IV, X64_MOFFS, X64_I24, X64_TEST8, X64_TESTZ, X64_REL8, X64_REL32,
 X64_PREFIX, X64_REX, X64_ESCAPE, X64_VEX, X64_EVEX) = range(16)


def _x64_opcode_maps():
    """The one-byte and 0F opcode maps (64-bit mode). IZ is 4 bytes (2 with a 66 prefix), IV is IZ or 8 with REX.W (MOV reg, imm),
    TEST8/TESTZ are the immediates of TEST in the F6/F7 groups, which the group's other instructions don't have."""
    m = X64_MODRM
    one = [X64_NONE] * 256
    for base in range(0, 0x40, 8):  # ADD, OR, ADC, SBB, AND, SUB, XOR, CMP: four ModRM forms, then AL and eAX with an immediate
        one[base:base + 4] = [m] * 4
        one[base + 4], one[base + 5] = X64_I8, X64_IZ
    for b in (0x26, 0x2E, 0x36, 0x3E, 0x64, 0x65, 0x66, 0x67, 0xF0, 0xF2, 0xF3):
        one[b] = X64_PREFIX
    one[0x40:0x50] = [X64_REX] * 16
    one[0x0F], one[0x62], one[0xC4], one[0xC5] = X64_ESCAPE, X64_EVEX, X64_VEX, X64_VEX
    one[0x63] = m
    one[0x68], one[0x69], one[0x6A], one[0x6B] = X64_IZ, m | X64_IZ, X64_I8, m | X64_I8
    one[0x70:0x80] = [X64_REL8] * 16
    one[0x80], one[0x81], one[0x83] = m | X64_I8, m | X64_IZ, m | X64_I8
    one[0x84:0x90] = [m] * 12
    one[0xA0:0xA4] = [X64_MOFFS] * 4
    one[0xA8], one[0xA9] = X64_I8, X64_IZ
    one[0xB0:0xB8] = [X64_I8] * 8
    one[0xB8:0xC0] = [X64_IV] * 8
    one[0xC0], one[0xC1], one[0xC2], one[0xC6], one[0xC7], one[0xC8] = m | X64_I8, m | X64_I8, X64_I16, m | X64_I8, m | X64_IZ, X64_I24
    one[0xCA], one[0xCD] = X64_I16, X64_I8
    one[0xD0:0xD4] = [m] * 4
    one[0xD8:0xE0] = [m] * 8
    one[0xE0:0xE4] = [X64_REL8] * 4
    one[0xE4:0xE8] = [X64_I8] * 4
    one[0xE8], one[0xE9], one[0xEB] = X64_REL32, X64_REL32, X64_REL8
    one[0xF6], one[0xF7], one[0xFE], one[0xFF] = m | X64_TEST8, m | X64_TESTZ, m, m
    two = [m] * 256
    for b in (0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0E, 0x77, 0xA0, 0xA1, 0xA2, 0xA8, 0xA9, 0xAA, *range(0x30, 0x38), *range(0xC8, 0xD0)):
        two[b] = X64_NONE
    for b in (0x0F, 0x70, 0x71, 0x72, 0x73, 0xA4, 0xAC, 0xBA, 0xC2, 0xC4, 0xC5, 0xC6):
        two[b] = m | X64_I8
    two[0x80:0x90] = [X64_REL32] * 16
    return bytes(one), bytes(two)


X64_ONE_BYTE, X64_TWO_BYTE = _x64_opcode_maps()
X64_VEX_IMM8 = frozenset((0x70, 0x71, 0x72, 0x73, 0xC2, 0xC4, 0xC5, 0xC6))  # VEX/EVEX opcodes of the 0F map with an imm8 (the 0F3A map always has one)
_unpack_i32 = struct.Struct('<i').unpack_from


def x64_decode(code, i):
    """Decodes the x64 instruction at code[i]: (length, opcode map, opcode, ModRM, REX, immediate offset, immediate size, RIP-relative
    displacement offset, opcode offset), or None if the code ends first. The map is 0 for one-byte opcodes, 1 for 0F, 2 for 0F38 and 3 for
    0F3A; ModRM is -1 when there's none; offsets are from i, and the displacement offset is -1 when there's no RIP-relative operand."""
    n = len(code)
    p = i
    opsize = addrsize = False
    rex = 0
    while True:
        if p >= n:
            return None
        b = code[p]
        kind = X64_ONE_BYTE[b]
        p += 1
        if kind == X64_PREFIX:
            if b == 0x66:
                opsize = True
            elif b == 0x67:
                addrsize = True
            rex = 0  # REX only counts right before the opcode
        elif kind == X64_REX:
            rex = b
        else:
            break
    mp = 0
    if X64_ESCAPE <= kind <= X64_EVEX:
        if kind == X64_ESCAPE:
            if p >= n:
                return None
            b = code[p]
            p += 1
            if b == 0x38 or b == 0x3A:
                mp = 2 if b == 0x38 else 3
                kind = X64_MODRM | (X64_I8 if mp == 3 else X64_NONE)
                if p >= n:
                    return None
                b = code[p]
                p += 1
            else:
                mp = 1
                kind = X64_TWO_BYTE[b]
        else:
            if p + 1 >= n:
                return None
            if kind == X64_EVEX:
                mp = code[p] & 7
                p += 3
            elif b == 0xC4:
                mp = code[p] & 0x1F
                p += 2
            else:
                mp = 1
                p += 1
            if p >= n:
                return None
            b = code[p]
            p += 1
            kind = X64_MODRM | (X64_I8 if mp == 3 or (mp == 1 and b in X64_VEX_IMM8) else X64_NONE)
            if mp == 1 and b == 0x77:  # VZEROUPPER, VZEROALL
                kind = X64_NONE
    op_at = p - 1 - i
    modrm = rip = -1
    if kind & X64_MODRM:
        if p >= n:
            return None
        modrm = code[p]
        p += 1
        mod = modrm >> 6
        if mod != 3:
            rm = modrm & 7
            if rm == 4:
                if p >= n:
                    return None
                if mod == 0 and code[p] & 7 == 5:  # SIB without a base register: disp32
                    p += 4
                p += 1
            elif mod == 0 and rm == 5:
                rip = p - i
                p += 4
            if mod == 1:
                p += 1
            elif mod == 2:
                p += 4
        kind &= 0x7F
    if kind == X64_NONE:
        size = 0
    elif kind == X64_I8 or kind == X64_REL8:
        size = 1
    elif kind == X64_IZ:
        size = 2 if opsize else 4
    elif kind == X64_REL32:
        size = 4
    elif kind == X64_TEST8:
        size = 1 if (modrm >> 3) & 7 < 2 else 0
    elif kind == X64_TESTZ:
        size = (2 if opsize else 4) if (modrm >> 3) & 7 < 2 else 0
    elif kind == X64_IV:
        size = 8 if rex & 8 else 2 if opsize else 4
    elif kind == X64_I16:
        size = 2
    elif kind == X64_MOFFS:
        size = 4 if addrsize else 8
    elif kind == X64_I24:
        size = 3
    else:
        size = 0
    if p + size > n:
        return None
    return (p + size - i, mp, b, modrm, rex, p - i, size, rip, op_at)


def sweep_x64(img, start, end, on_ref, starts=()):
    """Decodes the x64 code in [start, end) and calls on_ref(pc, target, kind) for every CALL ('call') and JMP/Jcc ('jump') with a 32-bit
    displacement, and for every RIP-relative memory operand ('addr'), which is how x64 code forms the addresses of data and imports.
    starts holds the sorted RVAs of known function starts: decoding restarts at each, so data between functions can't throw it off."""
    code = img.read(start, end - start)
    n = len(code)
    k = bisect.bisect_left(starts, start)
    nxt = starts[k] - start if k < len(starts) and starts[k] < end else n
    i = 0
    while i < n:
        if i >= nxt:
            while k < len(starts) and starts[k] - start <= i:
                k += 1
            nxt = starts[k] - start if k < len(starts) and starts[k] < end else n
        d = x64_decode(code, i)
        if d is None:
            break
        length = d[0]
        if i + length > nxt:  # Runs into a known function start, so this wasn't really an instruction
            i = nxt
            continue
        if d[7] >= 0:
            pc = start + i
            on_ref(pc, pc + length + _unpack_i32(code, i + d[7])[0], 'addr')
        elif d[6] == 4 and ((d[1] == 0 and (d[2] == 0xE8 or d[2] == 0xE9)) or (d[1] == 1 and 0x80 <= d[2] <= 0x8F)):
            pc = start + i
            on_ref(pc, pc + length + _unpack_i32(code, i + d[5])[0], 'call' if d[1] == 0 and d[2] == 0xE8 else 'jump')
        i += length


M32 = 0xFFFFFFFF
M64 = 0xFFFFFFFFFFFFFFFF
X64_VOLATILE = (0, 1, 2, 8, 9, 10, 11)                    # rax, rcx, rdx, r8-r11: a call doesn't preserve them
X64_ARGS = (('rcx', 1), ('rdx', 2), ('r8', 8), ('r9', 9))  # The first four arguments of a call
X64_GROUPS = frozenset((0x80, 0x81, 0x82, 0x83, 0x8F, 0xC0, 0xC1, 0xC6, 0xC7, 0xD0, 0xD1, 0xD2, 0xD3, 0xF6, 0xF7, 0xFE, 0xFF))
X64_GROUPS_0F = frozenset((0x00, 0x01, 0x0D, 0x18, 0x19, 0x1A, 0x1B, 0x1C, 0x1D, 0x1E, 0x1F, 0x71, 0x72, 0x73, 0xAE, 0xBA, 0xC7))
# One-byte opcodes whose operands are bytes (for most opcodes the low bit picks bytes or the full operand size)
X64_BYTE_OPS = frozenset([b + f for b in range(0, 0x40, 8) for f in (0, 2, 4)] + [0x80, 0x82, 0x84, 0x86, 0x88, 0x8A, 0xA8, 0xC0, 0xC6, 0xD0, 0xD2, 0xF6, 0xFE]
                         + list(range(0xB0, 0xB8)))
X64_FULL = {8: 0xFF, 16: 0xFFFF, 32: M32, 64: M64}


def _kb_and(a, b):
    m = (a[0] & b[0]) | (a[0] & ~a[1]) | (b[0] & ~b[1])
    return (m & M64, a[1] & b[1] & m)


def _kb_or(a, b):
    m = (a[0] & b[0]) | (a[0] & a[1]) | (b[0] & b[1])
    return (m & M64, (a[1] | b[1]) & m)


def _kb_zf(r, full):
    """The zero flag for a result: True or False when the known bits settle it, None otherwise."""
    if r[0] & r[1] & full:
        return False
    return True if (r[0] & full) == full else None


def _x64_condition(cc, zf, cf):
    """Whether condition code cc (the low nibble of Jcc/SETcc/CMOVcc) holds, or None if the flags it needs aren't known."""
    if cc in (2, 3):
        return None if cf is None else cf == (cc == 2)
    if cc in (4, 5):
        return None if zf is None else zf == (cc == 4)
    if cc in (6, 7):
        if cf is True or zf is True:
            return cc == 6
        return None if cf is None or zf is None else cc == 7
    return None


def x64_trace(img, rva, state=None, limit=200):
    """Follows the code of a small x64 function from its start, keeping track of which bits of each register are known, and returns the
    events on its path: (pc, slot, value) for the first four arguments of each call (slots 'rcx', 'rdx', 'r8', 'r9'), each store to memory
    ('store') and the return ('ret', rax). Values are (mask, bits): only the bits set in mask are known. A conditional jump is followed when
    its condition is known; the path ends at one that isn't, at a return, or after `limit` instructions. The first call returns `state`
    (for a feature's GetCurrentFeatureEnabledState: the state from GetFeatureEnabledState), or an unknown value if it's None.
    Only the instructions that compute such values are modeled; the registers any other instruction could write become unknown."""
    U = (0, 0)
    regs = [U] * 16
    mem = {}  # (base register, displacement) or ('rip', address) -> the 8 bytes there
    zf = cf = None
    events = []
    calls = 0
    pc = rva
    for _ in range(limit):
        code = img.read(pc, 16)
        d = x64_decode(code, 0)
        if d is None:
            return events
        length, mp, op, modrm, rex, imm_at, imm_size, rip, op_at = d
        nxt = pc + length
        imm = int.from_bytes(code[imm_at:imm_at + imm_size], 'little', signed=True) if imm_size else 0
        if (mp == 0 and op in X64_BYTE_OPS) or (mp == 1 and (0x90 <= op <= 0x9F or op == 0xB0)):
            w = 8
        else:
            w = 16 if 0x66 in code[:op_at] else 64 if rex & 8 else 32
        full = X64_FULL[w]
        sub = (modrm >> 3) & 7 if modrm >= 0 else 0
        reg = ((rex & 4) << 1) | sub
        direct = modrm >= 0 and modrm >> 6 == 3
        rm = ((rex & 1) << 3) | (modrm & 7) if direct else -1
        key = None
        if modrm >= 0 and not direct:
            if rip >= 0:
                key = ('rip', nxt + _unpack_i32(code, rip)[0])
            else:
                mod, low = modrm >> 6, modrm & 7
                at = op_at + 2
                base = ((rex & 1) << 3) | low
                if low == 4:
                    sib = code[at]
                    at += 1
                    base = ((rex & 1) << 3) | (sib & 7)
                    if (((rex & 2) << 2) | ((sib >> 3) & 7)) != 4 or (mod == 0 and sib & 7 == 5):
                        base = None  # Indexed, or no base register
                disp = (code[at] ^ 0x80) - 0x80 if mod == 1 else _unpack_i32(code, at)[0] if mod == 2 else 0
                if base is not None:
                    key = (base, disp)

        def high_byte(r):  # Without a REX prefix, byte registers 4-7 are AH, CH, DH and BH
            return w == 8 and not rex and 4 <= r < 8

        def value(r):
            if high_byte(r):
                return U
            return (regs[r][0] & full, regs[r][1] & full)

        def merged(old, v):  # A write of w bits: the bits above them stay as they were
            keep = M64 ^ full
            return ((old[0] & keep) | (v[0] & full), (old[1] & keep) | (v[1] & full))

        def put(r, v):
            if high_byte(r):
                regs[r - 4] = U
            elif w == 32:  # 32-bit results are zero-extended
                regs[r] = ((v[0] & M32) | (M64 ^ M32), v[1] & M32)
            else:
                regs[r] = merged(regs[r], v)
            for k in [k for k in mem if k[0] == r]:
                del mem[k]

        def rm_value():
            if direct:
                return value(rm)
            v = mem.get(key, U)
            return (v[0] & full, v[1] & full)

        def rm_put(v, store=True):
            if direct:
                put(rm, v)
                return
            if key is not None:
                v = mem[key] = merged(mem.get(key, U), v)
            if store:
                events.append((pc, 'store', v))

        def alu(n, a, b, same=False):
            """Applies ALU operation n (0 add, 1 or, 2 adc, 3 sbb, 4 and, 5 sub, 6 xor, 7 cmp) and sets the flags;
            returns the result, or None for CMP."""
            nonlocal zf, cf
            if n == 1:
                r, cf = _kb_or(a, b), False
            elif n == 4:
                r, cf = _kb_and(a, b), False
            elif n == 6 or (n == 5 and same):
                r, cf = ((full, 0) if same else (a[0] & b[0], (a[1] ^ b[1]) & a[0] & b[0])), False
            elif n == 3 and same:  # SBB reg, reg: 0 or all ones, from the carry flag
                r = (full, -cf & full) if cf is not None else U
            elif a[0] == full and b[0] == full and n in (0, 5, 7):
                r = (full, (a[1] + b[1] if n == 0 else a[1] - b[1]) & full)
                cf = a[1] + b[1] > full if n == 0 else a[1] < b[1]
            else:
                differs = n in (5, 7) and a[0] & b[0] & (a[1] ^ b[1])
                zf, cf = (False if differs else None), None
                return None if n == 7 else U
            zf = _kb_zf(r, full)
            return None if n == 7 else r

        if mp == 0 and op < 0x40 and op & 7 < 6:  # ADD, OR, ADC, SBB, AND, SUB, XOR, CMP
            n, form = op >> 3, op & 6
            if form == 4:
                r = alu(n, value(0), (full, imm & full))
                if r is not None:
                    put(0, r)
            elif form == 0:
                r = alu(n, rm_value(), value(reg), same=direct and rm == reg)
                if r is not None:
                    rm_put(r)
            else:
                r = alu(n, value(reg), rm_value(), same=direct and rm == reg)
                if r is not None:
                    put(reg, r)
        elif mp == 0 and op in (0x80, 0x81, 0x83):
            r = alu(sub, rm_value(), (full, imm & full))
            if r is not None:
                rm_put(r)
        elif mp == 0 and op in (0x84, 0x85):  # TEST
            zf, cf = _kb_zf(_kb_and(rm_value(), value(reg)), full), False
        elif mp == 0 and op in (0xA8, 0xA9):
            zf, cf = _kb_zf(_kb_and(value(0), (full, imm & full)), full), False
        elif mp == 0 and op in (0xF6, 0xF7) and sub < 2:
            zf, cf = _kb_zf(_kb_and(rm_value(), (full, imm & full)), full), False
        elif mp == 0 and op in (0xF6, 0xF7) and sub == 3:  # NEG
            a = rm_value()
            r = (full, -a[1] & full) if a[0] == full else U
            cf = (a[1] != 0) if a[0] == full else (True if a[0] & a[1] else None)
            zf = _kb_zf(r, full)
            rm_put(r)
        elif mp == 0 and op in (0xF6, 0xF7) and sub == 2:  # NOT
            a = rm_value()
            rm_put((a[0], ~a[1] & a[0] & full))
        elif mp == 0 and op in (0x88, 0x89):
            rm_put(value(reg))
        elif mp == 0 and op in (0x8A, 0x8B):
            put(reg, rm_value())
        elif mp == 0 and op in (0xC6, 0xC7) and sub == 0:
            rm_put((full, imm & full))
        elif mp == 0 and 0xB0 <= op <= 0xBF:
            put(((rex & 1) << 3) | (op & 7), (full, imm & full))
        elif mp == 0 and op == 0x8D:  # LEA reg, [base + disp]
            known = key and key[0] != 'rip' and regs[key[0]][0] == M64
            put(reg, (full, (regs[key[0]][1] + key[1]) & full) if known else U)
        elif mp == 0 and op in (0xC0, 0xC1, 0xD0, 0xD1) and sub in (4, 5):  # SHL, SHR by a constant
            a, count = rm_value(), (imm if op in (0xC0, 0xC1) else 1) & (63 if w == 64 else 31)
            if sub == 4:
                r = (((a[0] << count) | ((1 << count) - 1)) & full, (a[1] << count) & full)
            else:
                r = ((a[0] >> count) | (full ^ (full >> count)), a[1] >> count)
            if count:
                zf, cf = _kb_zf(r, full), None
            rm_put(r)
        elif mp == 1 and 0x40 <= op <= 0x4F:  # CMOVcc
            taken = _x64_condition(op & 0xF, zf, cf)
            put(reg, U if taken is None else rm_value() if taken else value(reg))  # A 32-bit CMOV zero-extends its destination either way
        elif mp == 1 and 0x90 <= op <= 0x9F:  # SETcc
            taken = _x64_condition(op & 0xF, zf, cf)
            rm_put(U if taken is None else (0xFF, int(taken)), store=False)
        elif mp == 1 and op in (0xB6, 0xB7):  # MOVZX
            w = 8 if op == 0xB6 else 16
            full = X64_FULL[w]
            v = rm_value()
            w, full = 64, M64
            put(reg, (v[0] | (M64 ^ (0xFF if op == 0xB6 else 0xFFFF)), v[1]))
        elif mp == 1 and op == 0xBA and sub >= 4:  # BT, BTS, BTR, BTC with a constant
            a, bit = rm_value(), 1 << (imm & (63 if w == 64 else 31))
            cf = bool(a[1] & bit) if a[0] & bit else None
            if sub == 5:
                rm_put((a[0] | bit, a[1] | bit))
            elif sub == 6:
                rm_put((a[0] | bit, a[1] & ~bit))
            elif sub == 7:
                rm_put(U)
        elif (mp == 0 and (0x70 <= op <= 0x7F or op in (0xE9, 0xEB))) or (mp == 1 and 0x80 <= op <= 0x8F):
            taken = True if mp == 0 and op in (0xE9, 0xEB) else _x64_condition(op & 0xF, zf, cf)
            if taken is None:
                return events
            pc = nxt + imm if taken else nxt
            continue
        elif mp == 0 and (op == 0xE8 or (op == 0xFF and sub == 2)):  # CALL
            for slot, r in X64_ARGS:
                events.append((pc, slot, regs[r]))
            for r in X64_VOLATILE:
                regs[r] = U
            calls += 1
            if calls == 1 and state is not None:
                regs[0] = (M64, state)
            mem.clear()
            zf = cf = None
        elif mp == 0 and op in (0xC2, 0xC3):  # RET
            events.append((pc, 'ret', regs[0]))
            return events
        elif mp == 0 and (op == 0xCC or (op == 0xFF and sub in (3, 4, 5))):  # INT3, an indirect jump
            return events
        elif (mp == 0 and (op == 0x90 or 0x50 <= op <= 0x57 or (op == 0xFF and sub == 6))) or (mp == 1 and op == 0x1F):  # NOP, PUSH
            pass
        elif mp == 1 and op == 0xB1:  # CMPXCHG: stores the register when the comparison succeeds, which isn't known here
            events.append((pc, 'store', value(reg)))
            if key is not None:
                mem.pop(key, None)
            regs[0] = U
            zf = cf = None
        else:
            # Anything else: the registers it could write become unknown, and so do the flags
            if mp == 0 and 0x58 <= op <= 0x5F:
                regs[((rex & 1) << 3) | (op & 7)] = U
            elif mp == 0 and op in (0x98, 0x99, 0x6C, 0x6D, 0xA4, 0xA5, 0xAA, 0xAB, 0xAC, 0xAD, 0xAE, 0xAF):
                regs[0] = regs[1] = regs[2] = regs[6] = regs[7] = U
            elif modrm >= 0:
                if not ((mp == 0 and op in X64_GROUPS) or (mp == 1 and op in X64_GROUPS_0F)):  # In these the reg field is part of the opcode
                    regs[reg] = U
                if direct:
                    regs[rm] = U
                elif key is not None:
                    mem.pop(key, None)
                if mp == 0 and op in (0xF6, 0xF7):
                    regs[0] = regs[2] = U
            else:
                regs[0] = regs[2] = U
            zf = cf = None
        pc = nxt
    return events


def x64_first_call_args(img, rva):
    """(ecx, edx) at a function's first call, each None unless fully known."""
    for pc, slot, (mask, bits) in x64_trace(img, rva, limit=40):
        if slot == 'rcx':
            ecx = bits & M32 if mask & M32 == M32 else None
        elif slot == 'rdx':
            return ecx, bits & M32 if mask & M32 == M32 else None
    return None, None


def cpp_default_x64(img, rva):
    """The default stage of a C++ feature (1 = disabled, 2 = enabled) from its x64 GetCurrentFeatureEnabledState, or None.
    The function puts 'enabled' (0x40) in the state it returns according to the configured state from GetFeatureEnabledState: set when
    the feature is configured enabled (2), clear when configured disabled (1), and the default when it isn't configured (0). Where the
    compiler put that decision varies, so the function is traced once with each of the three states: the first value (a store, a call
    argument or the return value) whose 0x40 bit follows the configured state is the result, and its bit in the unconfigured run is the default."""
    runs = {s: x64_trace(img, rva, state=s) for s in (0, 1, 2)}
    at = [{(pc, slot): v for pc, slot, v in reversed(runs[s])} for s in (0, 1, 2)]  # First occurrence of each
    for pc, slot, on in runs[2]:
        off = at[1].get((pc, slot))
        if off and on[0] & off[0] & 0x40 and on[1] & 0x40 and not off[1] & 0x40:
            unset = at[0].get((pc, slot))
            if unset and unset[0] & 0x40:
                return 2 if unset[1] & 0x40 else 1
            return None
    return None


class Demangler:
    """Short readable names for decorated C++ symbols: scopes and name only, with template arguments collapsed to <>.
    Uses dbghelp's UnDecorateSymbolName on Windows, llvm-undname elsewhere when it's installed, and a simple fallback otherwise."""

    def __init__(self):
        self._lock = threading.Lock()
        self._cache = {}
        self._undecorate = None
        if os.name == 'nt':
            try:
                import ctypes
                fn = ctypes.WinDLL('dbghelp.dll').UnDecorateSymbolName
                fn.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint32, ctypes.c_uint32]
                fn.restype = ctypes.c_uint32
                buf = ctypes.create_string_buffer(4096)

                def undecorate(names):
                    out = {}
                    for name in names:
                        n = fn(name.encode('utf-8', 'replace'), buf, len(buf), 0x1000)  # UNDNAME_NAME_ONLY
                        if n:
                            out[name] = buf.value[:n].decode('utf-8', 'replace')
                    return out
                self._undecorate = undecorate
            except (OSError, AttributeError):
                pass
        if self._undecorate is None and shutil.which('llvm-undname'):
            self._undecorate = self._llvm_undname

    @staticmethod
    def _llvm_undname(names):
        names = list(names)
        res = subprocess.run(['llvm-undname', '--no-calling-convention', '--no-return-type', '--no-access-specifier', '--no-member-type', '--no-variable-type'],
                             input='\n'.join(names) + '\n', capture_output=True, text=True)
        lines = res.stdout.split('\n')
        out, pos = {}, 0
        for name in names:  # Each name is echoed, then followed by its demangled form and a blank line, or by just a blank line if it failed
            if pos + 1 >= len(lines) or lines[pos] != name:
                break
            if lines[pos + 1]:
                out[name] = Demangler._strip_parameters(lines[pos + 1])
                pos += 3
            else:
                pos += 2
        return out

    def names(self, raw_names):
        """{raw name: short name} for the given names."""
        todo = {}
        with self._lock:
            for n in raw_names:
                if n not in self._cache:
                    todo.setdefault(n.lstrip('#').replace('$$h', ''), []).append(n)  # '#' and '$$h' mark ARM64EC symbols
            decorated = [k for k in todo if k.startswith('?')]
            undecorated = self._undecorate(decorated) if self._undecorate and decorated else {}
            for k, raws in todo.items():
                short = self._shorten(undecorated.get(k) or self._fallback(k))
                for r in raws:
                    self._cache[r] = short
            return {n: self._cache[n] for n in raw_names}

    @staticmethod
    def _strip_parameters(name):
        """Foo::Bar(int, char *) const -> Foo::Bar; operator()(int) -> operator()."""
        name = re.sub(r' const$', '', name)
        if not name.endswith(')'):
            return name
        depth = 0
        for i in range(len(name) - 1, -1, -1):
            depth += {')': 1, '(': -1}.get(name[i], 0)
            if depth == 0:
                return name[:i]
        return name

    @staticmethod
    def _fallback(name):
        m = re.match(r'^\?([^@?$]+)@((?:[^@?$]+@)*)@', name)
        return '::'.join(m.group(2).split('@')[:-1][::-1] + [m.group(1)]) if m else name

    @staticmethod
    def _shorten(name):
        name = re.sub(r'<lambda_\w+>', '\x01', name)
        while True:  # Innermost template arguments first; \x02 stands for an already collapsed <> so the enclosing one can match
            collapsed = re.sub(r'<[^<>]*>', '\x02', name)
            if collapsed == name:
                break
            name = collapsed
        return re.sub(r'\b(?:struct|class|enum|union) ', '', name).replace('\x02', '<>').replace('\x01', '<lambda>').strip()


def analyze_usage(pdb_path, info, found, demangler):
    """What one binary reveals about the features in it: {feature ID as a string: details}, or None if it holds no ARM64 or x64 code.
    found is extract_features' result for the binary; features it only declares (an ID constant in a full PDB) have no plumbing to analyze."""
    ids = {name: feature_id for name, feature_id, source in found if source != 'const'}
    if not ids:
        return {}
    img = CodeImage(info.path)
    if not img.code_ranges and not img.x64_ranges:
        return None
    publics = read_public_symbols(pdb_path)

    names_at = {}
    targets = {}   # RVA -> (feature ID, member) for plumbing that code references; None where two features' plumbing share an address
    members = {}   # feature ID -> {member: RVA}
    external = set()
    func_rvas = set()
    for rva, name, is_function in publics:
        names_at.setdefault(rva, []).append(name)
        p = plumbing_of(name)
        if p and p[0] in ids:
            fid = ids[p[0]]
            members.setdefault(fid, {})[p[1]] = rva
            if '__WilExternalFeatureTraits_' in name:
                external.add(fid)
            if p[1] not in DATA_ONLY_MEMBERS:
                prev = targets.get(rva, (fid, p[1]))
                targets[rva] = (fid, p[1]) if prev is not None and prev[0] == fid else None
        if (is_function or img.is_exec(rva)) and not name.startswith('??_C@'):
            func_rvas.add(rva)
    if not members:
        return {}
    sym_rvas = sorted(names_at)
    func_rvas = sorted(func_rvas)
    funcs = img.functions
    func_starts = [b for b, _ in funcs]
    func_end = dict(funcs)
    known_starts = sorted(set(func_starts) | set(func_rvas))  # Where x64 decoding restarts

    def sweep(start, end, fn):
        if img.in_x64(start):
            sweep_x64(img, start, end, fn, known_starts)
        else:
            sweep_arm64(img, start, end, fn)

    def enclosing(pc):
        i = bisect.bisect_right(func_starts, pc) - 1
        if i >= 0 and funcs[i][0] <= pc < funcs[i][1]:
            return img.roots.get(funcs[i][0], funcs[i][0])
        j = bisect.bisect_right(func_rvas, pc) - 1
        return func_rvas[j] if j >= 0 else None

    def name_at(rva):
        names = names_at.get(rva)
        if not names:
            return None
        plain = [n for n in names if not plumbing_of(n)]
        return (plain or names)[0]

    def plumbing_target(target):
        """The feature plumbing an address points at: exactly, or up to 64 bytes into a data member."""
        if target in targets:
            return targets[target]
        j = bisect.bisect_right(sym_rvas, target) - 1
        if j >= 0 and target - sym_rvas[j] < 64:
            t = targets.get(sym_rvas[j])
            if t and not img.is_exec(target):
                return t
        return None

    # Pass 1: every reference to plumbing, attributed to the function it's in
    func_refs = {}                          # function RVA -> {feature ID: references}
    requires_code = {}                      # feature ID -> feature IDs its plumbing checks
    plumbing_owner = {}                     # function RVA -> (whether it's feature plumbing, ID of the feature it belongs to if known)

    def owner_of(fstart):
        if fstart not in plumbing_owner:
            name = name_at(fstart)
            p = plumbing_of(name) if name else None
            plumbing_owner[fstart] = (True, ids.get(p[0])) if p else (False, None)
        return plumbing_owner[fstart]

    def on_ref(pc, target, kind):
        t = plumbing_target(target)
        if not t:
            return
        fstart = enclosing(pc)
        if fstart is None:
            return
        is_plumbing, owner = owner_of(fstart)
        if is_plumbing:
            if owner is not None and owner != t[0]:
                requires_code.setdefault(owner, set()).add(t[0])
            return
        refs = func_refs.setdefault(fstart, {})
        refs[t[0]] = refs.get(t[0], 0) + 1

    for start, end in img.code_ranges + img.x64_ranges:
        sweep(start, end, on_ref)

    tables = {f for f, refs in func_refs.items() if len(refs) > TABLE_MIN_FEATURES}
    callers = {}       # feature ID -> [(references, function RVA)]
    in_tables = {}     # feature ID -> [table function RVA]
    for f, refs in func_refs.items():
        for fid, count in refs.items():
            if f in tables:
                in_tables.setdefault(fid, []).append(f)
            else:
                callers.setdefault(fid, []).append((count, f))
    for fid in callers:
        callers[fid].sort(key=lambda c: (-c[0], c[1]))

    def context_callers(cs):
        """The first CONTEXT_CALLERS distinct functions; ARM64X binaries have most functions twice (ARM64 and ARM64EC)."""
        out, seen = [], set()
        for count, f in cs:
            key = (name_at(f) or '').lstrip('#').replace('$$h', '') or f
            if key not in seen:
                seen.add(key)
                out.append(f)
                if len(out) == CONTEXT_CALLERS:
                    break
        return out

    # Pass 2: hints from the functions that check each feature
    context = {}

    def function_context(fstart):
        if fstart in context:
            return context[fstart]
        fend = func_end.get(fstart)
        if not fend:
            j = bisect.bisect_right(func_rvas, fstart)
            fend = min(func_rvas[j] if j < len(func_rvas) else fstart + 0x400, fstart + 0x4000)
        found_ctx = {'strings': [], 'sources': [], 'imports': [], 'symbols': [], 'calls': []}

        def add(kind, value):
            if value not in found_ctx[kind]:
                found_ctx[kind].append(value)

        def collect(pc, target, kind):
            if kind != 'addr':
                n = name_at(target)
                if n and not plumbing_of(n):
                    add('calls', n)
                return
            if img.is_exec(target):
                return
            n = name_at(target)
            if n and not n.startswith('??_C@'):  # ??_C@ symbols are string literals; read those as strings
                if n.startswith('__imp_'):
                    add('imports', n[6:])
                elif not plumbing_of(n):
                    add('symbols', n)
                return
            s = img.read_string(target)
            if s and not RE_WIL_PATH.search(s):
                add('sources' if RE_SOURCE_FILE.search(s) else 'strings', s)
        sweep(fstart, fend, collect)
        context[fstart] = found_ctx
        return found_ctx

    # C-style descriptors: { featureState*, reporting*, logged_traits*, UINT32 id, change time, 0, 1 if always enabled, 1 if enabled by default,
    # requiresFeatures* (zero-terminated list of descriptor pointers) }. logged_traits is { UINT32, UINT32 stage, ... }.
    def ptr_rva(q):
        return q - img.image_base if img.image_base <= q < img.image_base + img.image_size else None
    descriptor_feature = {m['private_descriptor']: fid for fid, m in members.items() if 'private_descriptor' in m}
    decoded = {}
    for fid, m in members.items():
        raw = img.read(m['private_descriptor'], 40) if 'private_descriptor' in m else b''
        if len(raw) == 40:
            _state, _reporting, traits, id_and_flags, requires = struct.unpack('<5Q', raw)
            if id_and_flags & 0xFFFFFFFF != fid:
                continue
            d = {'changeTime': raw[28]}
            t = ptr_rva(traits)
            tr = img.read(t, 8) if t is not None else b''
            if len(tr) == 8 and struct.unpack('<2I', tr)[1] in STAGES:
                d['stage'] = struct.unpack('<2I', tr)[1]
            req = []
            r = ptr_rva(requires)
            arr = img.read(r, 8 * 64) if r is not None else b''
            for i in range(0, len(arr) - 7, 8):
                q = ptr_rva(struct.unpack_from('<Q', arr, i)[0])
                if q is None:
                    break  # The list ends with a null pointer
                if q in descriptor_feature:
                    req.append(descriptor_feature[q])
            d['requires'] = req
            decoded[fid] = d
        elif 'GetCurrentFeatureEnabledState' in m and fid not in external:
            d = {'changeTime': cpp_change_time(img, m['GetCurrentFeatureEnabledState'], fid), 'stage': cpp_default(img, m['GetCurrentFeatureEnabledState'])}
            decoded[fid] = {k: v for k, v in d.items() if v is not None}

    requires = {fid: set(requires_code.get(fid, ())) | set(decoded.get(fid, {}).get('requires', ())) for fid in members}
    required = {r for reqs in requires.values() for r in reqs}

    # Names, demangled in one batch
    wanted = set()
    for fid, cs in callers.items():
        for count, f in cs:
            wanted.add(name_at(f) or '')
        for f in context_callers(cs):
            ctx = function_context(f)
            wanted.update(ctx['calls'], ctx['symbols'], ctx['imports'])
    for f in tables:
        wanted.add(name_at(f) or '')
    unnamed_hint = {}
    for fid, cs in callers.items():
        for count, f in cs:
            if not name_at(f):
                j = bisect.bisect_right(func_rvas, f - 1) - 1
                unnamed_hint[f] = name_at(func_rvas[j]) if j >= 0 else None
                if unnamed_hint[f]:
                    wanted.add(unnamed_hint[f])
    wanted.discard('')
    short = demangler.names(wanted)

    def func_name(f):
        n = name_at(f)
        if n:
            return short[n]
        hint = unnamed_hint.get(f)
        return '(unnamed function after %s)' % short[hint] if hint else '(unnamed function)'

    result = {}
    for fid in members:
        entry = {}
        cs = callers.get(fid, [])
        if cs:
            entry['use'] = 'checked'
            ordered = []
            for count, f in cs:
                n = func_name(f)
                if n not in ordered:
                    ordered.append(n)  # ARM64X binaries have each function twice (ARM64 and ARM64EC), under the same name
            entry['callers'] = ordered[:LIMITS['callers']]
            entry['callerCount'] = len(ordered)
            hints = {k: [] for k in ('strings', 'sources', 'imports', 'symbols', 'calls')}
            for f in context_callers(cs):
                ctx = function_context(f)
                for k in ('strings', 'sources'):
                    hints[k].extend(s for s in ctx[k] if s not in hints[k])
                for n in ctx['imports']:
                    s = short[n]
                    if s not in NOISE_IMPORTS and s not in hints['imports']:
                        hints['imports'].append(s)
                for n in ctx['symbols']:
                    s = short[n]
                    if not any(p in n or p in s for p in NOISE_NAME_PARTS) and s not in hints['symbols']:
                        hints['symbols'].append(s)
                for n in ctx['calls']:
                    s = short[n]
                    if not s.startswith(NOISE_CALL_PREFIXES) and s not in hints['calls'] and s not in ordered:
                        hints['calls'].append(s)
            for k, v in hints.items():
                if v:
                    entry[k] = v[:LIMITS[k]]
        elif fid in in_tables:
            entry['use'] = 'table'
        elif fid in required:
            entry['use'] = 'required'
        else:
            entry['use'] = 'unreferenced'
        if fid in in_tables:
            entry['tables'] = sorted({func_name(f) for f in in_tables[fid]})
        if requires[fid]:
            entry['requires'] = sorted(requires[fid])
        d = decoded.get(fid, {})
        if 'stage' in d:
            entry['default'] = STAGES[d['stage']]
        if d.get('changeTime') in CHANGE_TIMES:
            entry['changeTime'] = CHANGE_TIMES[d['changeTime']]
        result[str(fid)] = entry
    return result

# ---------------------------------------------------------------------------
# Symbol download
# ---------------------------------------------------------------------------

class Downloader:
    """Downloads PDBs over persistent connections.

    msdl limits how fast new connections can be opened, not how many requests are made: opening a fresh TLS connection per request
    (msdl, then the blob storage host it redirects to) gets throttled after a few hundred requests, showing up as connection timeouts
    (WinError 10060) or resets. Each worker thread therefore keeps one connection per host and reuses it, following redirects itself.
    """

    def __init__(self, server, timeout=20, retries=3):
        self.server = server.rstrip('/')
        self.timeout = timeout
        self.retries = retries
        self.bytes = 0
        self._lock = threading.Lock()
        self._local = threading.local()
        self._proxy = urllib.request.getproxies().get('https')  # Honour HTTPS_PROXY when run locally behind a proxy

    def fetch(self, pdb_name, pdb_key, dest):
        """Downloads the PDB to dest. Returns 'ok', 'missing', or raises on repeated failure."""
        url = '%s/%s/%s/%s' % (self.server, pdb_name, pdb_key, pdb_name)
        result = self._get(url, dest)
        if result == 'missing' and os.name == 'nt':
            # Some symbols are only published CAB-compressed as name.pd_
            compressed = pdb_name[:-1] + '_'
            cab_url = '%s/%s/%s/%s' % (self.server, pdb_name, pdb_key, compressed)
            cab_dest = dest + '.cab'
            if self._get(cab_url, cab_dest) == 'ok':
                try:
                    subprocess.run(['expand.exe', '-R', cab_dest, dest], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                    result = 'ok' if os.path.exists(dest) else 'missing'
                finally:
                    remove_quietly(cab_dest)
        return result

    def _connection(self, scheme, host, port):
        conns = getattr(self._local, 'conns', None)
        if conns is None:
            conns = self._local.conns = {}
        key = (scheme, host, port)
        conn = conns.get(key)
        if conn is None:
            if self._proxy and scheme == 'https':
                proxy = urllib.parse.urlsplit(self._proxy)
                conn = http.client.HTTPSConnection(proxy.hostname, proxy.port or 8080, timeout=self.timeout)
                headers = {}
                if proxy.username:
                    creds = '%s:%s' % (urllib.parse.unquote(proxy.username), urllib.parse.unquote(proxy.password or ''))
                    headers['Proxy-Authorization'] = 'Basic ' + base64.b64encode(creds.encode()).decode()
                conn.set_tunnel(host, port, headers=headers)
            elif scheme == 'https':
                conn = http.client.HTTPSConnection(host, port, timeout=self.timeout)
            else:
                conn = http.client.HTTPConnection(host, port, timeout=self.timeout)
            conns[key] = conn
        return key, conn

    def _drop(self, key):
        conn = self._local.conns.pop(key, None)
        if conn is not None:
            conn.close()

    def _request_once(self, url, dest):
        for _hop in range(5):
            parts = urllib.parse.urlsplit(url)
            port = parts.port or (443 if parts.scheme == 'https' else 80)
            key, conn = self._connection(parts.scheme, parts.hostname, port)
            target = parts.path + ('?' + parts.query if parts.query else '')
            try:
                conn.request('GET', target, headers={'User-Agent': USER_AGENT})
                resp = conn.getresponse()
                if resp.status in (301, 302, 303, 307, 308):
                    location = resp.getheader('Location')
                    resp.read()
                    if not location:
                        raise RuntimeError('HTTP %d without Location' % resp.status)
                    url = urllib.parse.urljoin(url, location)
                    continue
                if resp.status == 404:
                    resp.read()
                    return 'missing'
                if resp.status != 200:
                    resp.read()
                    raise RuntimeError('HTTP %d' % resp.status)
                with open(dest, 'wb') as out:
                    shutil.copyfileobj(resp, out, 1 << 20)
                if resp.will_close:
                    self._drop(key)
                with self._lock:
                    self.bytes += os.path.getsize(dest)
                return 'ok'
            except Exception:
                self._drop(key)  # A broken or half-read connection can't be reused
                raise
        raise RuntimeError('too many redirects')

    def _get(self, url, dest):
        last_error = None
        for attempt in range(self.retries):
            try:
                return self._request_once(url, dest)
            except Exception as e:
                remove_quietly(dest)
                last_error = e
            # The first retry is immediate, since a reused connection the server had already closed fails right away.
            # Anything still failing goes to the retry rounds at the end of the scan rather than holding this worker.
            if attempt:
                time.sleep(1)
        raise RuntimeError('download failed: %s (%s)' % (url, last_error))

def remove_quietly(path):
    try:
        os.remove(path)
    except OSError:
        pass

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

NUMERIC_NAME = re.compile(r'^(?:ID|FI)?\d+$')
FEATURE_LEVEL_FIELDS = ('requires', 'default', 'changeTime')

def feature_level_usage(by_module):
    """requires (union), default and changeTime (the value most binaries agree on) from a feature's per-module usage details.
    C++ code can only say enabled or disabled, so where a descriptor says always enabled (or disabled), that wins over the plain value."""
    out = {}
    requires = sorted({r for d in by_module.values() for r in d.get('requires', ())})
    if requires:
        out['requires'] = requires
    defaults = [d['default'] for d in by_module.values() if 'default' in d]
    if defaults:
        plain = [{'alwaysEnabled': 'enabled', 'alwaysDisabled': 'disabled'}.get(v, v) for v in defaults]
        value = max(sorted(set(plain)), key=plain.count)
        always = 'always' + value[0].upper() + value[1:]
        out['default'] = always if always in defaults else value
    times = [d['changeTime'] for d in by_module.values() if 'changeTime' in d]
    if times:
        out['changeTime'] = max(sorted(set(times)), key=times.count)
    return out

def pick_name(names):
    """Chooses the display name for an ID: a descriptive name over a bare number, then the most widely used, then alphabetical."""
    return sorted(names.items(), key=lambda kv: (bool(NUMERIC_NAME.match(kv[0])), -len(kv[1]), kv[0].lower()))[0][0]

def log(msg):
    print(msg, flush=True)

def main():
    parser = argparse.ArgumentParser(description='Extract Windows feature names and IDs from public symbols.')
    parser.add_argument('--root', action='append', default=None, help='Directory to scan recursively (repeatable). Defaults to the Windows directories that ship features.')
    parser.add_argument('--symbol-server', default=DEFAULT_SYMBOL_SERVER)
    parser.add_argument('--symbol-cache', default=None, help='Local symbol store (name.pdb\\GUIDAGE\\name.pdb) to read from before downloading.')
    parser.add_argument('--keep-pdbs', action='store_true', help='Keep downloaded PDBs in --symbol-cache instead of deleting them after use.')
    parser.add_argument('--results-cache', default=None, help='JSON file remembering what each PDB contained, so unchanged binaries are not downloaded again.')
    parser.add_argument('--workers', type=int, default=12)
    parser.add_argument('--names-out', default='extracted-names.txt', help='"ID Name" lines, one per feature ID.')
    parser.add_argument('--json-out', default='symbol-features.json', help='Every feature found, with all names and the modules that contain it.')
    args = parser.parse_args()

    if args.keep_pdbs and not args.symbol_cache:
        parser.error('--keep-pdbs requires --symbol-cache')

    start = time.time()
    roots = [(r, True) for r in args.root] if args.root else default_roots()
    for root, recursive in roots:
        log('[scan] root: %s%s%s' % (root, '' if recursive else ' (top level only)', '' if os.path.isdir(root) else ' (not found, skipped)'))

    # 1. Enumerate images and group them by PDB identity
    by_pdb = {}
    image_count = 0
    for path in enumerate_images(roots):
        info = read_pe_info(path)
        if info is None:
            continue
        image_count += 1
        by_pdb.setdefault((info.pdb_name.lower(), info.pdb_key), []).append(info)
    log('[scan] %d images with a PDB reference, %d unique PDBs (%.0fs)' % (image_count, len(by_pdb), time.time() - start))

    # 2. Results cache
    cache = {}
    if args.results_cache and os.path.exists(args.results_cache):
        try:
            with open(args.results_cache, 'r', encoding='utf-8') as f:
                loaded = json.load(f)
            if loaded.get('version') == RESULTS_CACHE_VERSION:
                cache = loaded.get('pdbs', {})
            log('[scan] loaded results cache with %d entries' % len(cache))
        except (OSError, ValueError) as e:
            log('[scan] ignoring unreadable results cache: %s' % e)

    work_dir = tempfile.mkdtemp(prefix='featsym-')
    downloader = Downloader(args.symbol_server)
    results = {}
    stats = {'cached': 0, 'local': 0, 'downloaded': 0, 'missing': 0, 'error': 0, 'previousVersion': 0}
    today = time.strftime('%Y-%m-%d', time.gmtime())
    # PDBs that 404'd are remembered and only asked for again after this many days, in case Microsoft publishes them later
    missing_recheck_after = time.strftime('%Y-%m-%d', time.gmtime(time.time() - 14 * 86400))
    stats_lock = threading.Lock()
    demangler = Demangler()

    def process(key):
        pdb_name, pdb_key = key
        infos = by_pdb[key]
        cache_key = '%s/%s' % (pdb_name, pdb_key)
        cached = cache.get(cache_key)
        # Usage details are only kept for the PDBs of the latest scan, so an older version showing up again is analyzed again
        has_usage = cached is not None and ('usage' in cached or all(src == 'const' for _, _, src in cached.get('features', [])))
        if cached is not None and cached.get('status') == 'ok' and has_usage:
            with stats_lock:
                stats['cached'] += 1
            return cache_key, cached
        if cached is not None and cached.get('status') == 'missing' and cached.get('checked', '') >= missing_recheck_after:
            with stats_lock:
                stats['missing'] += 1
            return cache_key, cached
        real_name = infos[0].pdb_name
        local = os.path.join(args.symbol_cache, real_name, pdb_key, real_name) if args.symbol_cache else None
        temp_path = None
        try:
            if local and os.path.exists(local):
                pdb_path = local
                source = 'local'
            else:
                if args.keep_pdbs:
                    os.makedirs(os.path.dirname(local), exist_ok=True)
                    pdb_path = local
                else:
                    temp_path = pdb_path = os.path.join(work_dir, '%s.%s.pdb' % (pdb_key, threading.get_ident()))
                status = downloader.fetch(real_name, pdb_key, pdb_path)
                if status == 'missing':
                    with stats_lock:
                        stats['missing'] += 1
                    return cache_key, {'status': 'missing', 'checked': today}
                source = 'downloaded'
            features = extract_features(pdb_path, infos[0])
            entry = {'status': 'ok', 'scanned': today, 'modules': sorted({os.path.basename(i.path) for i in infos}), 'features': features}
            try:
                entry['usage'] = analyze_usage(pdb_path, infos[0], features, demangler)
            except Exception as e:  # A binary the analysis can't handle still keeps its features
                entry['usage'] = None
                entry['usageError'] = '%s: %s' % (type(e).__name__, e)
            with stats_lock:
                stats[source] += 1
            return cache_key, entry
        except Exception as e:
            with stats_lock:
                stats['error'] += 1
            return cache_key, {'status': 'error', 'error': str(e)}
        finally:
            if temp_path:
                remove_quietly(temp_path)

    cache_before = dict(cache)

    # 3. Download and parse
    done = 0
    last_report = time.time()
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.workers) as pool:
        futures = {pool.submit(process, key): key for key in by_pdb}
        for fut in concurrent.futures.as_completed(futures):
            cache_key, result = fut.result()
            results[futures[fut]] = result
            cache[cache_key] = result
            done += 1
            if result.get('status') == 'error':
                log('[scan] error: %s: %s' % (cache_key, result.get('error')))
            if result.get('usageError'):
                log('[scan] usage analysis failed for %s: %s' % (cache_key, result['usageError']))
            if time.time() - last_report > 15 or done == len(futures):
                last_report = time.time()
                log('[scan] %d/%d PDBs  cached=%d local=%d downloaded=%d missing=%d error=%d  %.1f MB  %.0fs' % (
                    done, len(futures), stats['cached'], stats['local'], stats['downloaded'], stats['missing'], stats['error'],
                    downloader.bytes / 1048576, time.time() - start))

    # 4. Retry anything that failed (usually connection timeouts) in rounds with low concurrency, after the main burst has finished
    for retry_round in range(1, 4):
        # The first round also re-checks 404s once, in case msdl answered 404 while overloaded; they're fast to re-check
        retry_statuses = ('error', 'missing') if retry_round == 1 else ('error',)
        failed = [key for key, result in results.items() if result.get('status') in retry_statuses
                  and not (result.get('status') == 'missing' and result is cache_before.get('%s/%s' % key))]
        if not failed:
            break
        log('[scan] retry round %d: re-checking %d PDBs (%s), 4 workers' % (retry_round, len(failed), ' + '.join(retry_statuses)))
        time.sleep(10 * retry_round)
        for key in failed:
            stats[results[key]['status']] -= 1
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            for key, (cache_key, result) in zip(failed, pool.map(process, failed)):
                results[key] = result
                cache[cache_key] = result
        log('[scan] after retry round %d: downloaded=%d missing=%d error=%d  %.0fs' % (retry_round, stats['downloaded'], stats['missing'], stats['error'], time.time() - start))
    shutil.rmtree(work_dir, ignore_errors=True)

    # 5. A binary whose PDB still couldn't be downloaded falls back to what the most recently scanned earlier version of it contained,
    #    so its features aren't dropped from this build. Those features are marked unverified. (A 404 is a definite answer, so no fallback.)
    previous_by_name = {}
    for cache_key, entry in cache.items():
        if entry.get('status') == 'ok':
            previous_by_name.setdefault(cache_key.split('/', 1)[0], []).append((cache_key, entry))
    for key, result in list(results.items()):
        if result.get('status') != 'error':
            continue
        # The PDB name alone isn't enough: different binaries can share one (smartscreen.exe and smartscreen.dll both use smartscreen.pdb)
        modules = {os.path.basename(i.path).lower() for i in by_pdb[key]}
        candidates = [c for c in previous_by_name.get(key[0], []) if modules & {m.lower() for m in c[1].get('modules', [])}]
        previous = max(candidates, key=lambda c: c[1].get('scanned', ''), default=None)
        if previous:
            log('[scan] gave up on %s/%s (%s); using features from earlier version %s' % (key[0], key[1], result.get('error'), previous[0]))
            results[key] = {'status': 'previousVersion', 'from': previous[0], 'features': previous[1]['features'], 'usage': previous[1].get('usage')}
            stats['error'] -= 1
            stats['previousVersion'] += 1
        else:
            log('[scan] gave up on %s/%s: %s' % (key[0], key[1], result.get('error')))

    if args.results_cache:
        cache_dir = os.path.dirname(os.path.abspath(args.results_cache))
        os.makedirs(cache_dir, exist_ok=True)
        # Successful results are kept for every PDB ever scanned (old builds included), one per line so git diffs stay small.
        # 404s are kept with the date they were checked; failures aren't kept. Usage details are only kept for the PDBs of this scan.
        current = {'%s/%s' % key for key in by_pdb}
        ok = {k: v if k in current else {x: y for x, y in v.items() if x not in ('usage', 'usageError')}
              for k, v in cache.items() if v.get('status') in ('ok', 'missing')}
        with open(args.results_cache, 'w', encoding='utf-8', newline='\n') as f:
            f.write('{"version": %d, "pdbs": {\n' % RESULTS_CACHE_VERSION)
            f.write(',\n'.join('%s: %s' % (json.dumps(k), json.dumps(ok[k], separators=(',', ':'))) for k in sorted(ok)))
            f.write('\n}}\n')

    # 6. Aggregate: id -> name -> set of modules. A feature is unverified if it only came from earlier-version fallbacks.
    #    A module only counts as using a feature if it has the feature's plumbing; full PDBs also declare the IDs of features the binary never uses.
    features = {}
    verified = set()
    used_in = {}
    usage = {}  # id -> module -> usage details
    for key, result in results.items():
        if result.get('status') not in ('ok', 'previousVersion'):
            continue
        modules = sorted({os.path.basename(i.path) for i in by_pdb[key]})
        for name, feature_id, source in result['features']:
            features.setdefault(feature_id, {}).setdefault(name, set()).update(modules)
            if source != 'const':
                used_in.setdefault(feature_id, set()).update(modules)
            if result['status'] == 'ok':
                verified.add(feature_id)
        for feature_id, details in (result.get('usage') or {}).items():
            by_module = usage.setdefault(int(feature_id), {})
            for m in modules:
                # Two versions of a binary under the same name: keep the details of the one with more callers
                if m not in by_module or details.get('callerCount', 0) > by_module[m].get('callerCount', 0):
                    by_module[m] = details

    with open(args.names_out, 'w', encoding='utf-8', newline='\n') as f:
        for feature_id in sorted(features):
            name = pick_name(features[feature_id])
            # Many features are named only by a number in the symbols (the ID itself, or an obfuscated hash); that's no name at all
            if not NUMERIC_NAME.match(name):
                f.write('%d %s\n' % (feature_id, name))

    json_features = []
    for feature_id in sorted(features):
        names = features[feature_id]
        entry = {
            'id': feature_id,
            'name': pick_name(names),
            'names': sorted(names),
            'modules': sorted(used_in.get(feature_id, ())),
        }
        declared = set().union(*names.values()) - used_in.get(feature_id, set())
        if declared:
            entry['declaredIn'] = sorted(declared)  # Binaries whose PDB has the ID constant but not the plumbing
        if feature_id not in verified:
            entry['unverified'] = True
        by_module = usage.get(feature_id)
        if by_module:
            entry.update(feature_level_usage(by_module))
            entry['usage'] = {m: {k: v for k, v in d.items() if k not in FEATURE_LEVEL_FIELDS} for m, d in sorted(by_module.items())}
        json_features.append(entry)
    # Binaries with feature plumbing: analyzed, another architecture (no usage data), or failed
    usage_stats = {'analyzed': 0, 'otherArchitecture': 0, 'failed': 0}
    for result in results.values():
        if result.get('status') in ('ok', 'previousVersion') and any(src != 'const' for _, _, src in result['features']):
            usage_stats['failed' if result.get('usageError') else 'otherArchitecture' if result.get('usage') is None else 'analyzed'] += 1
    with open(args.json_out, 'w', encoding='utf-8') as f:
        json.dump({'imagesScanned': image_count, 'pdbs': len(by_pdb), 'stats': stats, 'usageStats': usage_stats, 'features': json_features}, f, indent=1)

    log('[scan] found %d feature IDs (%d names) in %.0fs' % (len(features), sum(len(v) for v in features.values()), time.time() - start))
    log('[scan] usage analysis: %d binaries analyzed, %d of another architecture, %d failed' % (usage_stats['analyzed'], usage_stats['otherArchitecture'], usage_stats['failed']))
    log('[scan] wrote %s and %s' % (args.names_out, args.json_out))
    return 0

if __name__ == '__main__':
    sys.exit(main())
