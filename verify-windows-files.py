# verify-windows-files.py
# Checks the files of the running Windows installation against what Microsoft publishes about its updates, so a scan only runs
# on a system whose files are what its build is supposed to have. Used inside the VM by scan-in-vm.ps1.
#
# Every Windows update's KB article on support.microsoft.com links a file list (CSV) with the name, version and size of every file
# in the update; since 2025 the lists also give each file's SHA-256. Since 24H2, a cumulative update contains every file that changed
# since its checkpoint update (KB5043080, 26100.1742), so the target update's list covers almost everything serviced since then.
#
# Windows keeps every component's files in its component store (C:\Windows\WinSxS\<component>_<version>_...), and the files in
# System32 and elsewhere are hard links to the installed version's copies there. That gives each installed file its component and
# version, and the checks are:
#   1. Every installed file of a component newer than the checkpoint has a SHA-256 the target update lists.
#   2. Every file name the target update lists that is installed has at least one installed copy with a SHA-256 the update lists.
#      (Names repeat across components and languages, so this asks for one match, not all.) This catches a component left at an
#      older version, including one older than the checkpoint, which the first check can't see.
#   3. Where the component store has several versions of a component, the installed files are from the newest one.
# Files that aren't installed from the component store (apps, logs, generated files) are only counted.
#
#   python verify-windows-files.py --kb KB5127936 --kb KB5043080 --out verification-files.json --inventory files.csv.gz

import argparse
import csv
import gzip
import hashlib
import html
import io
import json
import os
import re
import sys
import time
import urllib.request

USER_AGENT = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'

# Folders with machine-specific or generated content, not installed files
SKIP_DIRS = {'softwaredistribution', 'logs', 'temp', 'prefetch', 'installer', 'serviceprofiles', 'panther', 'livekernelreports',
             'minidump', 'cbstemp', 'config', 'winevt', 'logfiles', 'sru', 'catroot2', 'tasks', 'printers', 'wer'}

COMPONENT_FOLDER = re.compile(r'^([a-z0-9]+)_(.+)_([0-9a-f]{16})_(\d+(?:\.\d+){3})_([a-z0-9-]+)_([0-9a-f]{16})$', re.I)


def log(msg):
    print(msg, flush=True)


def fetch(url, retries=4):
    for attempt in range(retries):
        try:
            req = urllib.request.Request(url, headers={'User-Agent': USER_AGENT, 'Accept-Language': 'en-US'})
            with urllib.request.urlopen(req, timeout=120) as r:
                return r.read()
        except Exception as e:
            if attempt == retries - 1:
                raise RuntimeError(f'{url}: {e}')
            time.sleep(5 * (attempt + 1))


# ---------------------------------------------------------------------------
# Microsoft's file lists
# ---------------------------------------------------------------------------

def file_list_links(kb):
    """The KB article's title and the links of its file lists ('file information for cumulative update ...', '... the SSU ...')."""
    page = fetch(f'https://support.microsoft.com/help/{kb[2:] if kb.upper().startswith("KB") else kb}').decode('utf-8', 'replace')
    title = html.unescape(re.search(r'<title>([^<]*)', page).group(1)).strip()
    links = []
    for m in re.finditer(r'<a\s+href="([^"]+)"[^>]*>(.*?)</a>', page, re.S):
        url, text = html.unescape(m.group(1)), re.sub(r'<[^>]+>|\s+', ' ', m.group(2))
        before = page[max(0, m.start() - 200):m.start()]
        if re.search(r'file information', text + before, re.I) and re.match(r'https://(go\.microsoft\.com/fwlink/|download\.microsoft\.com/)', url):
            links.append((url, text.strip()))
    return title, links


def read_file_list(data):
    """The x64 rows of a file list: (name, version, size, sha256 or None)."""
    rows, section, header = [], None, None
    for line in io.StringIO(data.decode('utf-8-sig', 'replace')):
        line = line.strip()
        if not line:
            continue
        if not line.startswith('"'):
            section = line  # Such as "Windows 10 LCU x64-based"
            continue
        cells = next(csv.reader([line]))
        if cells[0] == 'File name':
            header = cells
            continue
        if not section or 'x64' not in section or not header:
            continue
        r = dict(zip(header, cells))
        rows.append((r['File name'], r.get('File version', ''), int(r.get('File size', '0').replace(',', '') or 0), (r.get('SHA256') or '').upper() or None))
    return rows


def load_updates(kbs, cache_dir):
    updates = []
    for kb in kbs:
        title, links = file_list_links(kb)
        builds = re.findall(r'\b(\d{5})\.(\d+)\b', title)
        if not links:
            raise RuntimeError(f'{kb}: no file lists linked from its KB article ({title})')
        rows = []
        for url, text in links:
            path = os.path.join(cache_dir, re.sub(r'[^A-Za-z0-9]+', '_', f'{kb}_{text}')[:80] + '.csv') if cache_dir else None
            if path and os.path.exists(path):
                data = open(path, 'rb').read()
            else:
                data = fetch(url)
                if path:
                    os.makedirs(cache_dir, exist_ok=True)
                    open(path, 'wb').write(data)
            part = read_file_list(data)
            log(f'{kb}: {text}: {len(part):,} x64 files')
            rows += part
        updates.append({'kb': kb, 'title': title, 'builds': ['.'.join(b) for b in builds], 'rows': rows})
    return updates


# ---------------------------------------------------------------------------
# Installed files
# ---------------------------------------------------------------------------

def walk(root, skip_dirs=SKIP_DIRS):
    stack = [root]
    while stack:
        d = stack.pop()
        try:
            entries = list(os.scandir(d))
        except OSError:
            continue
        for e in entries:
            try:
                if e.is_symlink() or getattr(e, 'is_junction', lambda: False)():
                    continue
                if e.is_dir(follow_symlinks=False):
                    if e.name.lower() not in skip_dirs:
                        stack.append(e.path)
                elif e.is_file(follow_symlinks=False):
                    yield e.path
            except OSError:
                continue


def sha256(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest().upper()


def parse_version(v):
    try:
        return tuple(int(p) for p in v.split('.'))
    except ValueError:
        return None


def inventory(windir, extra_roots):
    """Component store folders by file ID, and every other file with its size, SHA-256 and, for an installed file, its component."""
    winsxs = os.path.join(windir, 'WinSxS')
    by_id, components = {}, {}
    for e in os.scandir(winsxs):
        m = COMPONENT_FOLDER.match(e.name)
        if not m or not e.is_dir(follow_symlinks=False):
            continue
        arch, name, token, version, culture, _ = m.groups()
        has_files = False
        for path in walk(e.path, set()):
            has_files = True
            try:
                by_id[os.stat(path).st_ino] = e.name
            except OSError:
                pass
        if has_files:
            components.setdefault((arch.lower(), name.lower(), token.lower(), culture.lower()), []).append((parse_version(version), e.name))
    log(f'Component store: {len(components):,} components, {len(by_id):,} files')
    files, errors = [], 0
    roots = [windir] + extra_roots
    for root in roots:
        for path in walk(root):
            if path.lower().startswith(winsxs.lower() + os.sep):
                continue
            try:
                st = os.stat(path)
                digest = sha256(path)
            except OSError:
                errors += 1
                continue
            files.append({'path': path, 'size': st.st_size, 'sha256': digest, 'component': by_id.get(st.st_ino) if st.st_nlink > 1 else None})
    log(f'Files outside the component store: {len(files):,} ({errors:,} unreadable)')
    return files, components, errors


# ---------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------

def component_parts(folder):
    m = COMPONENT_FOLDER.match(folder)
    arch, name, token, version, culture, _ = m.groups()
    return (arch.lower(), name.lower(), token.lower(), culture.lower()), parse_version(version)


def base_name(name):
    # A few names in the lists include a folder, such as Amd64\UNIDRV.DLL
    return re.split(r'[\\/]', name)[-1].lower()


SCAN_IMAGE = re.compile(r'\.(dll|exe|sys|cpl|ocx|scr|ax|drv|tsp|ime|efi|acm)$', re.I)


def check(files, components, updates, windir):
    target, older = updates[0], updates[1:]
    target_hashes = {r[3] for r in target['rows'] if r[3]}
    by_name = {}
    for name, version, size, digest in target['rows']:
        if digest:
            by_name.setdefault(base_name(name), set()).add(digest)
    older_rows = {(base_name(r[0]), r[2]) for u in older for r in u['rows']}
    # Components newer than the newest checkpoint must be in the target update; its builds share the checkpoint's base build (26100)
    cutoff = max((parse_version(b) for u in older for b in u['builds']), default=None)
    # The folders scan-symbols.py reads by default
    scan_roots = [os.path.join(windir, d).lower() + os.sep for d in ('System32', 'SystemApps', 'ImmersiveControlPanel', 'ShellComponents', 'ShellExperiences', 'PrintDialog', 'UUS')]
    scan_roots.append(os.path.join(os.environ.get('ProgramFiles', r'C:\Program Files'), 'WindowsApps').lower() + os.sep)

    problems = {'notListed': [], 'notUpdated': [], 'olderVersionInstalled': []}
    counts, scan_counts = {}, {}
    installed_by_name = {}
    for f in files:
        name = os.path.basename(f['path']).lower()
        if not f['component']:
            category = 'notFromComponentStore'
        else:
            key, version = component_parts(f['component'])
            installed_by_name.setdefault(name, []).append(f)
            if f['sha256'] in target_hashes:
                category = 'listedByTargetUpdate'
            elif cutoff and len(version) == 4 and version[2] == cutoff[0] and version[3] > cutoff[1]:
                category = 'notListed'
                problems['notListed'].append({'path': f['path'], 'component': f['component'], 'sha256': f['sha256']})
            elif (name, f['size']) in older_rows:
                category = 'listedByCheckpointUpdate'
            elif cutoff and len(version) == 4 and version[2] == cutoff[0]:
                category = 'unchangedSinceCheckpoint'
            else:
                category = 'otherVersioning'
            newest = max(components.get(key, [(version, f['component'])]))
            if newest[0] > version:
                problems['olderVersionInstalled'].append({'path': f['path'], 'component': f['component'], 'newestInStore': newest[1]})
        counts[category] = counts.get(category, 0) + 1
        lower = f['path'].lower()
        if SCAN_IMAGE.search(lower) and (os.path.dirname(lower) == windir.lower() or any(lower.startswith(r) for r in scan_roots)):
            scan_counts[category] = scan_counts.get(category, 0) + 1
    for name, hashes in by_name.items():
        copies = installed_by_name.get(name)
        if copies and not any(c['sha256'] in hashes for c in copies):
            problems['notUpdated'].append({'name': name, 'installed': [{'path': c['path'], 'component': c['component']} for c in copies]})
    return counts, scan_counts, problems


def main():
    parser = argparse.ArgumentParser(description="Check this Windows installation's files against Microsoft's published file lists.")
    parser.add_argument('--kb', action='append', required=True, help='The target update first (such as KB5127936), then its checkpoint updates')
    parser.add_argument('--windir', default=os.environ.get('SystemRoot', r'C:\Windows'))
    parser.add_argument('--root', action='append', default=None, help='More folders to list (default: Program Files and Program Files (x86))')
    parser.add_argument('--cache-dir', help='Keep the downloaded file lists here')
    parser.add_argument('--out', required=True, help='JSON report')
    parser.add_argument('--inventory', help='Also write every file found (path, size, SHA-256, component) as a gzipped CSV')
    args = parser.parse_args()

    updates = load_updates(args.kb, args.cache_dir)
    extra = args.root if args.root is not None else [p for p in (os.environ.get('ProgramFiles'), os.environ.get('ProgramFiles(x86)')) if p]
    files, components, errors = inventory(args.windir, extra)
    counts, scan_counts, problems = check(files, components, updates, args.windir)
    counts['unreadable'] = errors

    report = {'updates': [{'kb': u['kb'], 'title': u['title'], 'x64Files': len(u['rows'])} for u in updates],
              'files': counts, 'scannedBinaries': scan_counts, 'problems': problems}
    with open(args.out, 'w', encoding='utf-8') as f:
        json.dump(report, f, indent=1)
    if args.inventory:
        with gzip.open(args.inventory, 'wt', encoding='utf-8', newline='') as f:
            w = csv.writer(f)
            w.writerow(['path', 'size', 'sha256', 'component'])
            for x in files:
                w.writerow([x['path'], x['size'], x['sha256'], x['component'] or ''])
    log('Files: ' + ', '.join(f'{k} {v:,}' for k, v in counts.items()))
    log('Binaries the scan reads: ' + ', '.join(f'{k} {v:,}' for k, v in scan_counts.items()))
    for k, v in problems.items():
        log(f'{k}: {len(v)}')
        for p in v[:10]:
            log(f'  {json.dumps(p)[:400]}')
    sys.exit(1 if any(problems.values()) else 0)


if __name__ == '__main__':
    main()
