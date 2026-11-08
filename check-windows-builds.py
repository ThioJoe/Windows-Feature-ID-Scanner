# check-windows-builds.py
# Finds the Windows 11 builds Microsoft has released, for every version and every Windows Insider channel, and which of them need a
# scan: the builds of the versions scanned in the VM (scan-in-vm.ps1) that data/ doesn't have yet.
#
# Sources, all Microsoft's. Each is read every time, so they can be checked against each other; a page's HTML is only read when
# the Microsoft Learn API (see microsoft_learn.py), which gives the same page as Markdown, fails:
#   Versions and their updates  support.microsoft.com's index of its Windows 11 update history (JSON), checked against the Windows 11
#                               release information page, which also stands in for the index if that can't be read or lacks a version
#   Insider builds              the index of the Windows Insider release notes (JSON), with each build's release date from Flight Hub,
#                               which also stands in for the index if that can't be read
# A source that fails, and sources that disagree about a version's or channel's newest build, are reported (as warnings in GitHub
# Actions). The check only fails when no source says what the builds of a version to scan are.
#
#   python check-windows-builds.py --arch AMD64                         # prints the builds to scan as JSON
#     --versions 26H2 25H2                 only these versions (default: every version the VM can be built for)
#     --github-output                      also writes `builds` (JSON) and `needed` to $GITHUB_OUTPUT
#     --releases data/releases.json        writes the newest builds of every version and Insider channel, which the site lists
#     --summary "$GITHUB_STEP_SUMMARY"     writes all of it as Markdown
#     --all                                scans each version's newest build even if data/ has it
#     --builds 26300.9725 26200.9711       scans these builds (even if data/ has them) instead
#
# A version's builds come with its monthly security update (B, the second week), the optional preview (D, the fourth week) and
# out-of-band releases (OOB); each is a different build, so each is scanned. Every build newer than the version's newest one in
# data/ counts, so none is missed when two come out between checks (only the newest few when many are missing; --builds takes the
# rest). A version with no build in data/ yet starts at its newest.

import argparse
import datetime
import gzip
import html
import json
import os
import re
import sys
import time
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import microsoft_learn  # noqa: E402

SERVICING_INDEX_URL = 'https://support.microsoft.com/en-us/servicing/os/windows-11/toc.json'
RELEASE_INFO_URL = 'https://learn.microsoft.com/en-us/windows/release-health/windows11-release-information'
INSIDER_INDEX_URL = 'https://learn.microsoft.com/en-us/windows-insider/toc.json'
INSIDER_ROOT = 'https://learn.microsoft.com/en-us/windows-insider/'
FLIGHT_HUB_URL = 'https://learn.microsoft.com/en-us/windows-insider/flight-hub/'
USER_AGENT = 'Windows-Feature-ID-Scanner'

# The versions scan-in-vm.ps1 can build a VM of: those that the Media Creation Tool's catalogs have an image for (26H2, and 24H2,
# which 25H2 starts from). 26H1 is a separate branch for new devices, with no image there.
VM_VERSIONS = ('26H2', '25H2', '24H2')
ACTIVE_DAYS = 183        # A version whose newest update is older than this isn't serviced any more, and isn't listed
LISTED = 6               # Newest builds listed per version and Insider channel in --releases
MAX_NEW = 3              # Most builds of one version scanned in one run

warnings = []


def log(msg):
    print('[check] ' + msg, file=sys.stderr)


def warn(msg):
    warnings.append(msg)
    print('[check] WARNING: ' + msg, file=sys.stderr)
    if os.environ.get('GITHUB_ACTIONS') == 'true':
        print('::warning::' + msg.replace('\n', ' '))


def fetch(url, retries=3):
    for attempt in range(retries):
        try:
            req = urllib.request.Request(url, headers={'User-Agent': USER_AGENT, 'Accept-Encoding': 'gzip', 'Accept-Language': 'en-US'})
            with urllib.request.urlopen(req, timeout=60) as r:
                data = r.read()
            if data[:2] == b'\x1f\x8b':
                data = gzip.decompress(data)
            return data.decode('utf-8-sig', 'replace')
        except Exception as e:
            if attempt == retries - 1 or getattr(e, 'code', None) == 404:
                raise RuntimeError(f'{url}: {e}')
            time.sleep(5 * (attempt + 1))


def read_page(learn, url, name, parse_markdown, parse_html):
    """A page parsed from the Markdown the Learn API gives for it, or from its HTML if that fails: (result, how it was read), or
    (None, None) if neither gives anything."""
    problems = []
    try:
        markdown = learn.fetch(url)
        result = parse_markdown(markdown) if markdown else None
        if result:
            return result, 'through the Learn API'
        problems.append('the Learn API returned ' + ('nothing usable' if markdown else 'nothing'))
    except Exception as e:
        problems.append(str(e))
    try:
        result = parse_html(fetch(url))
        if result:
            warn(f'{name}: {problems[0]}, so its HTML was read instead')
            return result, 'from its HTML'
        problems.append('its HTML had nothing usable either')
    except Exception as e:
        problems.append(f'its HTML: {e}')
    warn(f"{name} couldn't be read: {'; '.join(problems)}")
    return None, None


def version_tuple(build):
    return tuple(int(p) for p in build.split('.'))


def newest_first(rows):
    return sorted(rows, key=lambda r: version_tuple(r['build']), reverse=True)


def markdown_tables(text):
    """Every table in Markdown text, as (position, header cells, rows of cells)."""
    tables, header, rows, start = [], None, [], 0
    for m in re.finditer(r'^.*$', text, re.M):
        line = m.group(0).strip()
        if line.startswith('|'):
            cells = [c.strip() for c in line.strip('|').split('|')]
            if header is None:
                header, rows, start = cells, [], m.start()
            elif not all(re.match(r'^:?-{3,}:?$', c) for c in cells if c):
                rows.append(cells)
            continue
        if header is not None:
            tables.append((start, header, rows))
            header = None
    if header is not None:
        tables.append((start, header, rows))
    return tables


# ---------------------------------------------------------------------------
# Windows 11 versions and their updates
# ---------------------------------------------------------------------------

def parse_servicing_index(text):
    """{version: {'base': 26300, 'releases': [{'version', 'type', 'date', 'build', 'kb'}, ...] newest first}} from support.microsoft.com's
    index of its update history pages: a group per version, listing its updates with titles like "October 28, 2026—KB5127936 (OS
    Builds 26300.9818 and 26200.9818) Preview". An update shared by several versions names each one's build, and a version's group
    also has the updates of the version before it from before it came out, so which build is a version's own is decided across all
    versions: those with the longest histories (the older ones) take their base build first, and each base build goes to one version."""
    groups = {}
    for group in json.loads(text).get('items') or []:
        m = re.search(r'\bversion (\d\d[Hh][12])\b', group.get('toc_title') or '')
        if not m:
            continue
        entries = []
        for node in group.get('children') or []:
            title, href = node.get('toc_title') or '', node.get('href') or ''
            # The KB comes from the page's address first: titles have had typos (KB55134134 for KB5134134)
            kb = re.search(r'\bkb(\d{6,8})\b', href, re.I) or re.search(r'\bKB\s?(\d{6,8})\b', title)
            date = re.match(r'\s*([A-Z][a-z]+ \d{1,2}, \d{4})', title)
            builds = re.findall(r'\b\d{5}\.\d{1,6}\b', title)
            if not (kb and date and builds) or re.search(r'\bexpired\b', title, re.I):
                continue
            date = datetime.datetime.strptime(date.group(1), '%B %d, %Y').strftime('%Y-%m-%d')
            kind = 'OOB' if re.search(r'out-of-band', title, re.I) else 'D' if re.search(r'\bpreview\b', title, re.I) else 'B'
            entries.append({'kb': 'KB' + kb.group(1), 'date': date, 'builds': builds, 'type': f'{date[:7]} {kind}'})
        if entries:
            groups[m.group(1).upper()] = entries

    versions, taken = {}, set()
    for version, entries in sorted(groups.items(), key=lambda g: -len(g[1])):
        counts = {}
        for e in entries:
            for base in {b.split('.')[0] for b in e['builds']}:
                counts[base] = counts.get(base, 0) + 1
        newest = max(entries, key=lambda e: e['date'])
        candidates = [b for b in counts if b not in taken] or list(counts)
        # The one most of its updates name; on a tie, the one its newest update names, then the highest
        base = max(candidates, key=lambda b: (counts[b], any(x.split('.')[0] == b for x in newest['builds']), int(b)))
        taken.add(base)
        releases = {}
        for e in entries:
            build = next((b for b in e['builds'] if b.split('.')[0] == base), None)
            if build and build not in releases:
                releases[build] = {'version': version, 'type': e['type'], 'date': e['date'], 'build': build, 'kb': e['kb']}
        versions[version] = {'base': int(base), 'releases': newest_first(releases.values())}
    return versions


def parse_release_page_markdown(text):
    """The same from the release information page as Markdown: a heading "**Version 26H2 (OS build 26300)**" per version, followed by
    its release history table (Servicing option, Update type, Availability date, Build, KB article)."""
    versions = {}
    headings = list(re.finditer(r'^\s*\*\*Version (\d\d[Hh][12]) \(OS build (\d+)\)\*\*', text, re.M))
    tables = markdown_tables(text)
    for i, h in enumerate(headings):
        version = h.group(1).upper()
        if version in versions:
            continue  # A later section (the hotpatch calendar) repeats the headings
        end = headings[i + 1].start() if i + 1 < len(headings) else len(text)
        table = next((t for t in tables if h.end() <= t[0] < end and 'Build' in t[1]), None)
        if not table:
            continue
        col = {name: n for n, name in enumerate(table[1])}
        rows = []
        for cells in table[2]:
            get = lambda name: cells[col[name]] if name in col and col[name] < len(cells) else ''
            kb = re.search(r'KB\d+', get('KB article'))
            if re.match(r'^\d+\.\d+$', get('Build')) and kb:  # The version's first release has no KB
                rows.append({'version': version, 'type': get('Update type'), 'date': get('Availability date'), 'build': get('Build'), 'kb': kb.group(0)})
        versions[version] = {'base': int(h.group(2)), 'releases': newest_first(rows)}
    return versions


def parse_release_page_html(page):
    """The same from the page's HTML: the first table after each version's heading is its release history."""
    versions = {}
    for m in re.finditer(r'<strong>Version (\w+) \(OS build (\d+)\)</strong>.*?<table[^>]*>(.*?)</table>', page, re.S):
        version, base, table = m.groups()
        if version in versions:
            continue
        rows = []
        for row in re.findall(r'<tr>(.*?)</tr>', table, re.S):
            cells = [html.unescape(re.sub(r'<[^>]+>', '', c)).strip() for c in re.findall(r'<td[^>]*>(.*?)</td>', row, re.S)]
            if len(cells) >= 5 and re.match(r'^\d+\.\d+$', cells[3]) and re.match(r'^KB\d+$', cells[4]):
                rows.append({'version': version, 'type': cells[1], 'date': cells[2], 'build': cells[3], 'kb': cells[4]})
        versions[version] = {'base': int(base), 'releases': newest_first(rows)}
    return versions


def windows_versions(learn, page_file=None):
    """Every version's base build and updates, newest first, and a description of the sources read."""
    sources = []
    index = page = None
    try:
        index = parse_servicing_index(fetch(SERVICING_INDEX_URL))
        if not index:
            raise RuntimeError('no versions in it')
        sources.append(f"support.microsoft.com's update history index: {len(index)} versions")
    except Exception as e:
        warn(f"support.microsoft.com's update history index couldn't be read: {e}")

    if page_file:
        page, form = parse_release_page_html(open(page_file, encoding='utf-8').read()), 'from a file'
    else:
        page, form = read_page(learn, RELEASE_INFO_URL, 'The Windows 11 release information page', parse_release_page_markdown, parse_release_page_html)
    if page:
        sources.append(f'The Windows 11 release information page ({form}): {len(page)} versions')

    today = datetime.date.today()
    versions = {}
    for version in sorted(set(index or {}) | set(page or {}), reverse=True):
        a, b = (index or {}).get(version), (page or {}).get(version)
        chosen = a if a and a['releases'] else b
        if not chosen or not chosen['releases']:
            continue
        newest = chosen['releases'][0]
        try:
            active = (today - datetime.date.fromisoformat(newest['date'])).days <= ACTIVE_DAYS
        except ValueError:
            active = True
        if a and b and b['releases']:
            if a['base'] != b['base']:
                warn(f"{version}: the update history index gives base build {a['base']}, the release information page {b['base']}")
            if a['releases'][0]['build'] != b['releases'][0]['build'] and active:
                warn(f"{version}: the update history index's newest build is {a['releases'][0]['build']}, the release information page's is {b['releases'][0]['build']}")
        elif index and not a and active:
            warn(f"{version} isn't in the update history index; using the release information page for it")
        versions[version] = {'base': chosen['base'], 'releases': chosen['releases'], 'active': active,
                             'source': 'update history index' if chosen is a else 'release information page'}
    return versions, sources


# ---------------------------------------------------------------------------
# Windows Insider channels
# ---------------------------------------------------------------------------

def parse_insider_index(text):
    """[{'channel', 'folder', 'releases': [{'build', 'builds', 'notes'}, ...] newest first}] from the index of the Windows Insider
    release notes. Each channel's notes are under release-notes/<folder>/, a page per build; a Release Preview page can cover the
    builds of several versions ("Build 26200.9807/26300.9807")."""
    channels = []

    def walk(nodes):
        for node in nodes or []:
            kids = node.get('children') or []
            releases = []
            for kid in kids:
                href = (kid.get('href') or '').lstrip('/')
                m = re.match(r'release-notes/([^/]+)/((?:preview-)?build-[\d-]+)$', href)
                if not m:
                    continue
                builds = re.findall(r'\b\d{5}\.\d+\b', kid.get('toc_title') or '') or ['%s.%s' % p for p in re.findall(r'(\d{5})-(\d+)', m.group(2))]
                releases.append({'build': max(builds, key=version_tuple), 'builds': builds, 'folder': m.group(1), 'notes': INSIDER_ROOT + href})
            if releases:
                channels.append({'channel': re.sub(r'\s+', ' ', node.get('toc_title') or releases[0]['folder']).strip(),
                                 'folder': releases[0]['folder'], 'releases': newest_first(releases)})
            walk(kids)

    walk(json.loads(text).get('items'))
    return channels


def flight_hub_entry(entries, build, column, url, label):
    """Adds a Flight Hub cell (a link to the build's release notes, with its release date as the link's text) to entries."""
    link = re.search(r'release-notes/([^/]+)/([^/?#]+)', url)
    date = re.search(r'(\d{1,2})/(\d{1,2})/(\d{4})', label)
    if link and date:
        entries.setdefault((link.group(1), link.group(2)), []).append({
            'build': build, 'channel': column, 'date': '%s-%02d-%02d' % (date.group(3), int(date.group(1)), int(date.group(2))),
            'notes': INSIDER_ROOT + 'release-notes/%s/%s' % link.groups()})


def parse_flight_hub_markdown(text):
    """{(folder, page): [{'build', 'channel', 'date', 'notes'}]} from Flight Hub as Markdown: a table per version, a column per channel,
    a row per build, and in the channels that got it, a link to its release notes with the release date."""
    entries = {}
    for _, header, rows in markdown_tables(text):
        if not header or header[0].lower() != 'build':
            continue
        for cells in rows:
            build = re.match(r'(\d{5}\.\d+)', cells[0].replace('\\', ''))
            for i, cell in enumerate(cells[1:], 1):
                for label, url in microsoft_learn.links(cell):
                    if build:
                        flight_hub_entry(entries, build.group(1), header[i] if i < len(header) else '', url, label)
    return entries


def parse_flight_hub_html(page):
    """The same from Flight Hub's HTML."""
    entries = {}
    text = lambda s: html.unescape(re.sub(r'<[^>]+>', '', s)).strip()
    for table in re.findall(r'<table[^>]*>(.*?)</table>', page, re.S):
        header = [text(c) for c in re.findall(r'<th[^>]*>(.*?)</th>', table, re.S)]
        if not header or header[0].lower() != 'build':
            continue
        for row in re.findall(r'<tr[^>]*>(.*?)</tr>', table, re.S):
            cells = re.findall(r'<td[^>]*>(.*?)</td>', row, re.S)
            build = re.match(r'(\d{5}\.\d+)', text(cells[0])) if cells else None
            for i, cell in enumerate(cells[1:], 1):
                for url, label in re.findall(r'<a\s[^>]*?href="([^"]+)"[^>]*>(.*?)</a>', cell, re.S):
                    if build:
                        flight_hub_entry(entries, build.group(1), header[i] if i < len(header) else '', html.unescape(url), text(label))
    return entries


def insider_channels(learn):
    """Every Insider channel's builds, newest first, with their release dates where Flight Hub has them, and the sources read."""
    sources = []
    index = hub = None
    try:
        index = parse_insider_index(fetch(INSIDER_INDEX_URL))
        if not index:
            raise RuntimeError('no channels in it')
        sources.append(f'The Windows Insider release notes index: {len(index)} channels')
    except Exception as e:
        warn(f"The Windows Insider release notes index couldn't be read: {e}")
    hub, form = read_page(learn, FLIGHT_HUB_URL, 'Flight Hub', parse_flight_hub_markdown, parse_flight_hub_html)
    if hub:
        sources.append(f'Flight Hub ({form}): {len(hub)} builds')

    hub = hub or {}
    if index:
        channels = index
    else:
        # Without the index, Flight Hub's links say which channel (folder of release notes) each build is in
        by_folder = {}
        for (folder, page), cells in hub.items():
            by_folder.setdefault(folder, {})[page] = cells
        channels = []
        for folder, pages in by_folder.items():
            names = [c['channel'] for cells in pages.values() for c in cells]
            releases = [{'build': max((c['build'] for c in cells), key=version_tuple), 'builds': sorted({c['build'] for c in cells}, key=version_tuple),
                         'folder': folder, 'notes': cells[0]['notes']} for cells in pages.values()]
            channels.append({'channel': max(set(names), key=names.count), 'folder': folder, 'releases': newest_first(releases)})
        same = [c['channel'] for c in channels]
        for channel in channels:  # Flight Hub calls both Release Preview channels "RP"
            if same.count(channel['channel']) > 1:
                channel['channel'] += f" ({channel['folder']})"
    for channel in channels:
        for r in channel['releases']:
            cells = hub.get((channel['folder'], r['notes'].rstrip('/').rsplit('/', 1)[-1]))
            r['date'] = cells[0]['date'] if cells else None
        listed = [c['build'] for (folder, _), cells in hub.items() if folder == channel['folder'] for c in cells]
        if index and listed and max(listed, key=version_tuple) != channel['releases'][0]['build']:
            warn(f"Insider channel {channel['channel']}: the release notes index's newest build is {channel['releases'][0]['build']}, "
                 f"Flight Hub's is {max(listed, key=version_tuple)}")
    return channels, sources


# ---------------------------------------------------------------------------
# What to scan, and the reports
# ---------------------------------------------------------------------------

def scanned_keys(data_dir):
    builds_dir = os.path.join(data_dir, 'builds')
    return {fn[:-5] for fn in (os.listdir(builds_dir) if os.path.isdir(builds_dir) else []) if fn.endswith('.json')}


def builds_to_scan(versions, scan_versions, arch, have, rescan, wanted):
    """The builds to scan, each with its version, KB and so on, ordered by update so builds that share their binaries follow each other."""
    done = {k.rsplit('-', 1)[0] for k in have if k.endswith('-' + arch)}
    picks = []
    if wanted:
        for build in wanted:
            row = next((r for v in versions.values() for r in v['releases'] if r['build'] == build), None)
            if not row:
                raise RuntimeError(f"build {build} isn't in the update history of any Windows 11 version")
            picks.append(row)
    else:
        for version in scan_versions:
            info = versions.get(version)
            if not info:
                raise RuntimeError(f'no source lists the updates of Windows 11, version {version}')
            rows = info['releases']
            scanned = [b for b in done if b.split('.')[0] == str(info['base'])]
            if rescan or not scanned:
                new = [rows[0]]
            else:
                latest = max(scanned, key=version_tuple)
                new = [r for r in rows if version_tuple(r['build']) > version_tuple(latest)]
                if len(new) > MAX_NEW:
                    warn(f"{version}: {len(new)} builds since {latest}, the newest in data/; scanning the newest {MAX_NEW}, the others "
                         f"({', '.join(r['build'] for r in new[MAX_NEW:])}) can be scanned by starting the workflow with them")
                    new = new[:MAX_NEW]
            picks += new
    return [dict(r, key=f"{r['build']}-{arch}", scanned=r['build'] in done)
            for r in sorted(picks, key=lambda r: (version_tuple(r['build'])[1], version_tuple(r['build'])[0]))]


def releases_document(versions, channels, previous):
    """What data/releases.json holds: the newest builds of every serviced version and of every Insider channel. Nothing in it changes
    from one check to the next unless Microsoft releases something (whether data/ has a build is looked up from data/index.json)."""
    doc = {'windows11': [{'version': v, 'base': info['base'], 'scannedInVm': v in VM_VERSIONS,
                          'releases': [{k: r[k] for k in ('build', 'kb', 'date', 'type')} for r in info['releases'][:LISTED]]}
                         for v, info in sorted(versions.items(), reverse=True) if info['active'] or v in VM_VERSIONS]}
    if channels:
        doc['insider'] = [{'channel': c['channel'], 'releases': [{k: r[k] for k in ('build', 'builds', 'date', 'notes')} for r in c['releases'][:LISTED]]}
                          for c in channels]
    else:
        doc['insider'] = (previous or {}).get('insider', [])  # Keep the last list rather than lose it when the sources fail
    return doc


def summary_markdown(scan, versions, channels, have, scan_versions, sources):
    in_data = lambda build: ', '.join(a for a in ('AMD64', 'ARM64') if f'{build}-{a}' in have) or 'no'
    lines = ['## Windows builds', '']
    if scan:
        lines += ['Builds to scan:', '', '| Version | Build | KB | Released | Update |', '|---|---|---|---|---|']
        lines += [f"| {r['version']} | {r['build']} | {r['kb']} | {r['date']} | {r['type']} |" for r in scan]
    else:
        lines += ['Nothing to scan: data/ has the newest builds of ' + ', '.join(scan_versions) + '.']
    lines += ['', '### Windows 11', '', '| Version | Newest build | KB | Released | Update | In data/ |', '|---|---|---|---|---|---|']
    for v, info in sorted(versions.items(), reverse=True):
        if info['active'] or v in VM_VERSIONS:
            r = info['releases'][0]
            lines.append(f"| {v} | {r['build']} | {r['kb']} | {r['date']} | {r['type']} | {in_data(r['build'])} |")
    lines += ['', '### Windows Insider', '', '| Channel | Newest build | Released | In data/ |', '|---|---|---|---|']
    for c in channels:
        r = c['releases'][0]
        lines.append(f"| {c['channel']} | {' / '.join(r['builds'])} | {r['date'] or '?'} | {in_data(r['build'])} |")
    lines += ['', '### Sources', ''] + [f'- {s}' for s in sources]
    if warnings:
        lines += ['', '### Warnings', ''] + [f'- {w}' for w in warnings]
    return '\n'.join(lines) + '\n'


def main():
    parser = argparse.ArgumentParser(description="Find the Windows 11 builds Microsoft has released and which of them need a scan.")
    parser.add_argument('--versions', nargs='+', default=list(VM_VERSIONS), help='Windows 11 versions to scan (default: %(default)s)')
    parser.add_argument('--arch', required=True, help='Architecture the builds would be scanned for, as in data/builds file names (AMD64)')
    parser.add_argument('--data-dir', default='data')
    parser.add_argument('--builds', nargs='*', default=[], help='Scan these builds instead, even if data/ has them')
    parser.add_argument('--all', action='store_true', help="Scan each version's newest build even if data/ has it (to scan it again)")
    parser.add_argument('--releases', help='Write the newest builds of every version and Insider channel to this file')
    parser.add_argument('--summary', help='Add a Markdown summary to this file')
    parser.add_argument('--page-file', help='Read the release information page (HTML) from this file instead of downloading it')
    parser.add_argument('--github-output', action='store_true', help='Write `builds` and `needed` to the file named by $GITHUB_OUTPUT')
    args = parser.parse_args()

    learn = microsoft_learn.LearnApi(USER_AGENT)
    versions, sources = windows_versions(learn, args.page_file)
    if not versions:
        log('No source says what the Windows 11 versions and their builds are')
        return 1
    channels, insider_sources = insider_channels(learn)
    sources += insider_sources
    have = scanned_keys(args.data_dir)
    try:
        scan = builds_to_scan(versions, args.versions, args.arch, have, args.all, args.builds)
    except RuntimeError as e:
        log(str(e))
        return 1

    for v, info in sorted(versions.items(), reverse=True):
        if info['active'] or v in args.versions:
            r = info['releases'][0]
            log(f"{v}: newest build {r['build']} ({r['type']}, {r['date']}, {r['kb']}; from the {info['source']})")
    for c in channels:
        r = c['releases'][0]
        log(f"Insider {c['channel']}: newest build {' / '.join(r['builds'])} ({r['date'] or 'no date'})")
    for r in scan:
        log(f"To scan: {r['key']} ({r['version']}, {r['kb']}){' again' if r['scanned'] else ''}")
    if not scan:
        log('Nothing to scan')

    if args.releases:
        previous = None
        if os.path.exists(args.releases):
            with open(args.releases, encoding='utf-8') as f:
                previous = json.load(f)
        with open(args.releases, 'w', encoding='utf-8', newline='\n') as f:
            json.dump(releases_document(versions, channels, previous), f, indent=1)
            f.write('\n')
    if args.summary:
        with open(args.summary, 'a', encoding='utf-8') as f:
            f.write(summary_markdown(scan, versions, channels, have, args.versions, sources))
    print(json.dumps(scan, indent=1))
    if args.github_output:
        with open(os.environ['GITHUB_OUTPUT'], 'a', encoding='utf-8') as f:
            f.write('builds=%s\n' % json.dumps(scan, separators=(',', ':')))
            f.write('needed=%s\n' % ('true' if scan else 'false'))
    return 0


if __name__ == '__main__':
    sys.exit(main())
