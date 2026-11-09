# verify-windows-files.py
# Checks the files of the running Windows installation against what Microsoft publishes, so a scan only runs on a system whose
# files are the ones its build is supposed to have. Used by scan-in-vm.ps1: `image` lists the files of the image it starts from,
# right after applying it; `check` runs inside the VM before the scan.
#
# Every Windows update's KB article on support.microsoft.com links a file list (CSV) with the name, version and size of every file
# the update carries; since 2025 the lists also give each file's SHA-256 (.NET Framework's lists still don't, so for those a file
# has to match a listed name and size). A file the update doesn't carry is one that hasn't changed: a component's version can go
# up while some of its files stay exactly as they were, and those aren't in the list. The articles are read through the Microsoft
# Learn API (microsoft_learn.py), which gives them as Markdown; an article's HTML is only read when that fails.
#
# Windows keeps every component's files in its component store (C:\Windows\WinSxS), and the files in System32 and elsewhere are
# hard links to the installed versions' copies there. For every file installed from the component store, `check` requires that it
# either is a file one of the updates lists (the target update, its checkpoint update, or another update installed in the VM,
# such as .NET Framework's), or is the same file as in Microsoft's image the VM started from (whose own hash the Media Creation
# Tool's catalog gives). Anything else is a problem. Other files (apps, logs, files Windows generates, .NET's precompiled native
# images) are only counted.
#
# Whether an update installed every component that applies to the system is up to Windows' servicing, which scan-in-vm.ps1 checks
# separately. As a cross-check, the report lists file names the target update carries in the same version family whose installed
# copies all stayed as they were in the image. Names repeat across components, so these aren't necessarily problems.
#
#   python verify-windows-files.py image --root F:\ --out image-files.csv.gz
#   python verify-windows-files.py check --kb KB5127936 --kb KB5043080 --image image-files.csv.gz --out verification-files.json --inventory files.csv.gz

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

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import microsoft_learn  # noqa: E402

USER_AGENT = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'
LEARN = microsoft_learn.LearnApi(USER_AGENT)

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
            # A page that doesn't exist won't appear by trying again (servicing stack updates have no KB articles of their own)
            if attempt == retries - 1 or getattr(e, 'code', None) == 404:
                raise RuntimeError(f'{url}: {e}')
            time.sleep(5 * (attempt + 1))


# ---------------------------------------------------------------------------
# Microsoft's file lists
# ---------------------------------------------------------------------------

def file_list_links(kb):
    """The KB article's title, the links of its file lists, and how the article was read. The article is at
    support.microsoft.com/help/<number>, read through the Learn API as Markdown; the lists are the links to go.microsoft.com (which
    redirects to the list) or download.microsoft.com in its "File information" section, or in a line that mentions the file
    information ("For a list of the files provided in this update, download the file information for cumulative update KB...").
    The article's HTML is only read when the API fails or finds no such links (file_list_links_html)."""
    number = kb[2:] if kb.upper().startswith('KB') else kb
    try:
        markdown = LEARN.fetch(f'https://support.microsoft.com/help/{number}')
        if markdown and number in markdown:
            allowed = lambda url: re.match(r'https://(go\.microsoft\.com/fwlink/|download\.microsoft\.com/)', url, re.I)
            mentions = '\n'.join(line for line in markdown.splitlines() if re.search(r'file information|list of the files', line, re.I))
            for text in (microsoft_learn.section(markdown, 'File information'), mentions):
                links = [(url, label or url.rsplit('/', 1)[-1]) for label, url in microsoft_learn.links(text or '') if allowed(url)]
                if links:
                    return microsoft_learn.title(markdown) or f'KB{number}', list(dict.fromkeys(links)), 'Learn API'
            problem = 'the Learn API gave the article but no file lists in it'
        else:
            problem = 'the Learn API has no such article'
    except Exception as e:
        problem = str(e)
    title, links = file_list_links_html(number, problem)
    if links:
        log(f'KB{number}: {problem}; took the links from the article page instead')
    return title, links, 'article page'


def file_list_links_html(number, problem):
    """The same from the article's HTML, at support.microsoft.com/help/<number> (or /kb/<number>, an older address that also leads to
    it): links to go.microsoft.com or download.microsoft.com in its "File information" section, or whose text, or the text just
    before them, says "file information". Should the article change so that none are found, these count instead, in this order:
    links to a .csv file on download.microsoft.com, and go.microsoft.com links whose text names the KB."""
    page, errors = None, [problem]
    for url in (f'https://support.microsoft.com/help/{number}', f'https://support.microsoft.com/kb/{number}'):
        try:
            page = fetch(url).decode('utf-8', 'replace')
            break
        except Exception as e:
            errors.append(str(e))
    if page is None or number not in page:
        raise RuntimeError(f'KB{number}: no KB article ({"; ".join(errors) if page is None else "the page found is not about it"})')
    title = re.search(r'<title>([^<]*)', page)
    title = html.unescape(title.group(1)).strip() if title else f'KB{number}'
    anchors = [(m, html.unescape(m.group(1)), re.sub(r'<[^>]+>|\s+', ' ', m.group(2)).strip())
               for m in re.finditer(r'<a\s[^>]*?href="([^"]+)"[^>]*>(.*?)</a>', page, re.S)]
    allowed = lambda url: re.match(r'https://(go\.microsoft\.com/fwlink/|download\.microsoft\.com/)', url)
    heading = re.search(r'<(h\d|strong)[^>]*>\s*File information\s*</\1>', page, re.I)
    if heading:  # The section runs to the next heading
        following = re.compile(r'<h\d[\s>]', re.I).search(page, heading.end())
        section = (heading.end(), min(following.start() if following else len(page), heading.end() + 4000))
    for keep in (lambda m, url, text: allowed(url) and (re.search(r'file information', text + page[max(0, m.start() - 200):m.start()], re.I)
                                                        or (heading and section[0] < m.start() < section[1])),
                 lambda m, url, text: re.match(r'https://download\.microsoft\.com/\S+\.csv$', url, re.I),
                 lambda m, url, text: allowed(url) and re.search(rf'\b(KB)?{number}\b', text)):
        links = [(url, text or url.rsplit('/', 1)[-1]) for m, url, text in anchors if keep(m, url, text)]
        if links:
            return title, list(dict.fromkeys(links))
    return title, []


def read_file_list(data):
    """The x64 rows of a file list: (name, version, size, sha256 or None). Windows' lists have sections such as "Windows 10 LCU
    x64-based" and SHA-256 hashes; .NET's have sections such as "x64 Windows11" and only sizes."""
    rows, section, header = [], None, None
    for line in io.StringIO(data.decode('utf-8-sig', 'replace')):
        line = line.strip()
        if not line:
            continue
        cells = next(csv.reader([line]))
        while cells and not cells[-1]:
            cells.pop()  # Trailing commas
        if len(cells) <= 2:  # A section's name, which can have a comma in it ("Windows 11, version 24H2 LCU x64-based")
            if line.startswith('Additional file information'):
                break  # Details per component manifest follow
            section, header = line.strip('"'), None
            continue
        if cells[0] == 'File name':
            header = cells
            continue
        if not section or 'x64' not in section or not header:
            continue
        r = dict(zip(header, cells))
        rows.append((r['File name'], r.get('File version', ''), int(r.get('File size', '0').replace(',', '') or 0), (r.get('SHA256') or '').upper() or None))
    return rows


def load_updates(kbs, cache_dir, required=True):
    updates = []
    for kb in kbs:
        try:
            title, links, source = file_list_links(kb)
        except Exception as e:
            if required:
                raise
            log(f'{kb}: no KB article ({e})')
            continue
        if not links:
            if required:
                raise RuntimeError(f'{kb}: no file lists linked from its KB article ({title})')
            log(f'{kb}: its KB article links no file lists ({title})')
            continue
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
        if not rows and required:
            raise RuntimeError(f'{kb}: its file lists ({", ".join(u for u, _ in links)}) have no x64 files; is the layout new?')
        updates.append({'kb': kb, 'title': title, 'rows': rows, 'source': source})
    return updates


# ---------------------------------------------------------------------------
# Files
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


def relative(path):
    """The path without its drive, such as Windows\\System32\\kernel32.dll, lowercased, to compare an image with the installed system."""
    return re.sub(r'^[A-Za-z]:[\\/]', '', path).lower()


def list_files(roots, winsxs=None):
    """Every file under the roots (outside the component store) with its size, SHA-256 and, for one installed from the component
    store (a hard link to a file in it), the component's folder name."""
    by_id = {}
    if winsxs:
        for e in os.scandir(winsxs):
            if e.is_dir(follow_symlinks=False) and COMPONENT_FOLDER.match(e.name):
                for path in walk(e.path, set()):
                    try:
                        by_id[os.stat(path).st_ino] = e.name
                    except OSError:
                        pass
        log(f'Component store: {len(by_id):,} files')
    files, errors = [], 0
    for root in roots:
        for path in walk(root, SKIP_DIRS | {'winsxs'}):
            try:
                st = os.stat(path)
                digest = sha256(path)
            except OSError:
                errors += 1
                continue
            files.append({'path': path, 'size': st.st_size, 'sha256': digest, 'component': by_id.get(st.st_ino) if st.st_nlink > 1 else None})
    log(f'Files: {len(files):,} ({errors:,} unreadable)')
    return files, errors


def write_files(path, files):
    with gzip.open(path, 'wt', encoding='utf-8', newline='') as f:
        w = csv.writer(f)
        w.writerow(['path', 'size', 'sha256', 'component'])
        for x in files:
            w.writerow([x['path'], x['size'], x['sha256'], x['component'] or ''])


def read_files(path):
    with gzip.open(path, 'rt', encoding='utf-8', newline='') as f:
        return {relative(r['path']): r['sha256'] for r in csv.DictReader(f)}


# ---------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------

def base_name(name):
    # A few names in the lists include a folder, such as Amd64\UNIDRV.DLL
    return re.split(r'[\\/]', name)[-1].lower()


def version_family(version):
    parts = version.split('.')
    return '.'.join(parts[:3]) if len(parts) == 4 and all(p.isdigit() for p in parts) else None


SCAN_IMAGE = re.compile(r'\.(dll|exe|sys|cpl|ocx|scr|ax|drv|tsp|ime|efi|acm)$', re.I)


def check(files, updates, image, windir):
    target, others = updates[0], updates[1:]
    target_hashes = {r[3] for r in target['rows'] if r[3]}
    other_hashes = {r[3] for u in others for r in u['rows'] if r[3]}
    other_sizes = {(base_name(r[0]), r[2]) for u in others for r in u['rows'] if not r[3]}  # Older lists have no hashes
    target_by_name = {}
    for name, version, size, digest in target['rows']:
        if digest:
            entry = target_by_name.setdefault(base_name(name), {'hashes': set(), 'families': set()})
            entry['hashes'].add(digest)
            entry['families'].add(version_family(version))
    # The folders scan-symbols.py reads by default
    scan_roots = [os.path.join(windir, d).lower() + os.sep for d in ('System32', 'SystemApps', 'ImmersiveControlPanel', 'ShellComponents', 'ShellExperiences', 'PrintDialog', 'UUS')]
    scan_roots.append(os.path.join(os.environ.get('ProgramFiles', r'C:\Program Files'), 'WindowsApps').lower() + os.sep)

    problems = []
    counts = {'installed': {}, 'other': {}}
    scan_counts = {}
    installed_by_name = {}
    for f in files:
        name = os.path.basename(f['path']).lower()
        if '\\assembly\\nativeimages_' in f['path'].lower():
            category = 'dotnetNativeImage'  # .NET's precompiled code, which each PC regenerates; no list covers it
        elif f['sha256'] in target_hashes:
            category = 'listedByTargetUpdate'
        elif f['sha256'] in other_hashes or (name, f['size']) in other_sizes:
            category = 'listedByOtherUpdate'
        elif image is None:
            category = 'unverified'
        elif image.get(relative(f['path'])) == f['sha256']:
            category = 'unchangedFromImage'
        else:
            category = 'changed' if relative(f['path']) in image else 'new'
        kind = 'installed' if f['component'] else 'other'
        counts[kind][category] = counts[kind].get(category, 0) + 1
        if f['component'] and category != 'dotnetNativeImage':
            installed_by_name.setdefault(name, []).append((f, category))
            if category in ('changed', 'new'):
                problems.append({'path': f['path'], 'component': f['component'], 'sha256': f['sha256'], 'issue': f'{category}, and no update lists it'})
        lower = f['path'].lower()
        if SCAN_IMAGE.search(lower) and (os.path.dirname(lower) == windir.lower() or any(lower.startswith(r) for r in scan_roots)):
            key = f'{kind}: {category}'
            scan_counts[key] = scan_counts.get(key, 0) + 1

    unchanged_names = []
    for name, entry in target_by_name.items():
        copies = installed_by_name.get(name)
        if not copies or any(f['sha256'] in entry['hashes'] for f, _ in copies):
            continue
        families = {version_family(COMPONENT_FOLDER.match(f['component']).group(4)) for f, _ in copies}
        if families & entry['families'] and all(c in ('unchangedFromImage', 'unverified') for _, c in copies):
            unchanged_names.append({'name': name, 'installed': [{'path': f['path'], 'component': f['component']} for f, _ in copies]})
    return counts, scan_counts, problems, unchanged_names


def main():
    parser = argparse.ArgumentParser(description="Check this Windows installation's files against Microsoft's published file lists.")
    sub = parser.add_subparsers(dest='command', required=True)
    p = sub.add_parser('image', help='List the files of an applied image, before it first starts')
    p.add_argument('--root', required=True, help='The drive the image was applied to, such as F:\\')
    p.add_argument('--out', required=True)
    p = sub.add_parser('check', help='Check the running installation')
    p.add_argument('--kb', action='append', required=True, help='The target update first (such as KB5127936), then its checkpoint updates')
    p.add_argument('--other-kb', action='append', default=[], help='Another update installed in the VM (its files are allowed too)')
    p.add_argument('--image', help="The image's file list (from the image command)")
    p.add_argument('--windir', default=os.environ.get('SystemRoot', r'C:\Windows'))
    p.add_argument('--cache-dir', help='Keep the downloaded file lists here')
    p.add_argument('--out', required=True, help='JSON report')
    p.add_argument('--inventory', help='Also write every file found (path, size, SHA-256, component) as a gzipped CSV')
    args = parser.parse_args()

    program_files = lambda drive: [os.path.join(drive, d) for d in ('Program Files', 'Program Files (x86)')]
    if args.command == 'image':
        files, errors = list_files([os.path.join(args.root, 'Windows')] + program_files(args.root))
        write_files(args.out, files)
        return

    updates = load_updates(args.kb, args.cache_dir) + load_updates(args.other_kb, args.cache_dir, required=False)
    image = read_files(args.image) if args.image else None
    drive = os.path.splitdrive(args.windir)[0] + os.sep
    files, errors = list_files([args.windir] + program_files(drive), os.path.join(args.windir, 'WinSxS'))
    counts, scan_counts, problems, unchanged_names = check(files, updates, image, args.windir)
    report = {'updates': [{'kb': u['kb'], 'title': u['title'], 'x64Files': len(u['rows']), 'articleReadFrom': u['source']} for u in updates],
              'imageFiles': len(image) if image is not None else None, 'unreadable': errors,
              'files': counts, 'scannedBinaries': scan_counts, 'problems': problems, 'unchangedNamesTheUpdateCarries': unchanged_names}
    with open(args.out, 'w', encoding='utf-8') as f:
        json.dump(report, f, indent=1)
    if args.inventory:
        write_files(args.inventory, files)
    for kind, c in counts.items():
        log(f'Files {kind}: ' + ', '.join(f'{k} {v:,}' for k, v in c.items()))
    log('Binaries the scan reads: ' + ', '.join(f'{k} {v:,}' for k, v in scan_counts.items()))
    log(f'Names the target update carries that stayed as in the image: {len(unchanged_names)}')
    log(f'Problems: {len(problems)}')
    for p in problems[:20]:
        log(f'  {json.dumps(p)[:400]}')
    sys.exit(1 if problems else 0)


if __name__ == '__main__':
    main()
