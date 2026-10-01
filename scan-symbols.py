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
#   4. For descriptor symbols, reads the feature ID out of the image file at the symbol's RVA.
#
# Only the Python standard library is used, so it runs on any GitHub-hosted Windows runner (x64 or ARM64) without installing anything.
# mach2 (the tool this replaces) is retired and fails on current PDBs with "The operation completed successfully., system:0".

import argparse
import concurrent.futures
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
import urllib.error
import urllib.request

DEFAULT_SYMBOL_SERVER = 'https://msdl.microsoft.com/download/symbols'
USER_AGENT = 'Microsoft-Symbol-Server/10.0.0.0'
RESULTS_CACHE_VERSION = 1

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
        """Yields (kind, name, rva_or_value): kind is 'cpp', 'c' (descriptor RVAs) or 'const' (ID value)."""
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
    return sorted([list(x) for x in found])

# ---------------------------------------------------------------------------
# Symbol download
# ---------------------------------------------------------------------------

class Downloader:
    def __init__(self, server, timeout=20, retries=2):
        self.server = server.rstrip('/')
        self.timeout = timeout
        self.retries = retries
        self.bytes = 0
        self._lock = threading.Lock()

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

    def _get(self, url, dest):
        last_error = None
        for attempt in range(self.retries):
            try:
                req = urllib.request.Request(url, headers={'User-Agent': USER_AGENT})
                with urllib.request.urlopen(req, timeout=self.timeout) as resp, open(dest, 'wb') as out:
                    shutil.copyfileobj(resp, out, 1 << 20)
                with self._lock:
                    self.bytes += os.path.getsize(dest)
                return 'ok'
            except urllib.error.HTTPError as e:
                remove_quietly(dest)
                if e.code == 404:
                    return 'missing'
                last_error = e
            except Exception as e:
                remove_quietly(dest)
                last_error = e
            # msdl intermittently stops answering connections (WinError 10060). Don't hold the worker here with long waits;
            # anything still failing after a quick second try goes to the retry rounds at the end of the scan.
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

    def process(key):
        pdb_name, pdb_key = key
        infos = by_pdb[key]
        cache_key = '%s/%s' % (pdb_name, pdb_key)
        cached = cache.get(cache_key)
        if cached is not None and cached.get('status') == 'ok':
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
            with stats_lock:
                stats[source] += 1
            return cache_key, {'status': 'ok', 'scanned': today, 'modules': sorted({os.path.basename(i.path) for i in infos}), 'features': features}
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
            name = cache_key.split('/', 1)[0]
            best = previous_by_name.get(name)
            if best is None or entry.get('scanned', '') > best[1].get('scanned', ''):
                previous_by_name[name] = (cache_key, entry)
    for key, result in list(results.items()):
        if result.get('status') != 'error':
            continue
        previous = previous_by_name.get(key[0])
        if previous:
            log('[scan] gave up on %s/%s (%s); using features from earlier version %s' % (key[0], key[1], result.get('error'), previous[0]))
            results[key] = {'status': 'previousVersion', 'from': previous[0], 'features': previous[1]['features']}
            stats['error'] -= 1
            stats['previousVersion'] += 1
        else:
            log('[scan] gave up on %s/%s: %s' % (key[0], key[1], result.get('error')))

    if args.results_cache:
        cache_dir = os.path.dirname(os.path.abspath(args.results_cache))
        os.makedirs(cache_dir, exist_ok=True)
        # Successful results are kept for every PDB ever scanned (old builds included), one per line so git diffs stay small.
        # 404s are kept with the date they were checked; failures aren't kept.
        ok = {k: v for k, v in cache.items() if v.get('status') in ('ok', 'missing')}
        with open(args.results_cache, 'w', encoding='utf-8', newline='\n') as f:
            f.write('{"version": %d, "pdbs": {\n' % RESULTS_CACHE_VERSION)
            f.write(',\n'.join('%s: %s' % (json.dumps(k), json.dumps(ok[k], separators=(',', ':'))) for k in sorted(ok)))
            f.write('\n}}\n')

    # 6. Aggregate: id -> name -> set of modules. A feature is unverified if it only came from earlier-version fallbacks.
    features = {}
    verified = set()
    for key, result in results.items():
        if result.get('status') not in ('ok', 'previousVersion'):
            continue
        modules = sorted({os.path.basename(i.path) for i in by_pdb[key]})
        for name, feature_id, _source in result['features']:
            features.setdefault(feature_id, {}).setdefault(name, set()).update(modules)
            if result['status'] == 'ok':
                verified.add(feature_id)

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
            'modules': sorted(set().union(*names.values())),
        }
        if feature_id not in verified:
            entry['unverified'] = True
        json_features.append(entry)
    with open(args.json_out, 'w', encoding='utf-8') as f:
        json.dump({'imagesScanned': image_count, 'pdbs': len(by_pdb), 'stats': stats, 'features': json_features}, f, indent=1)

    log('[scan] found %d feature IDs (%d names) in %.0fs' % (len(features), sum(len(v) for v in features.values()), time.time() - start))
    log('[scan] wrote %s and %s' % (args.names_out, args.json_out))
    return 0

if __name__ == '__main__':
    sys.exit(main())
