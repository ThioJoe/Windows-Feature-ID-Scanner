# update-data.py
# Maintains the feature database in data/:
#
#   data/builds/<build>-<arch>/            A folder per scanned build:
#       features.json                      every feature ID found (named or not), from symbols and/or the feature store
#       details.json                       what each binary's code reveals about each feature (callers, strings, ...)
#       super-god-mode/                    Super God Mode's statistics for the build, its CSV and XML files as it writes them
#   data/index.json                        List of tracked builds with summary counts (what the site loads first)
#   data/first-seen.json                   For each architecture, the first tracked build(s) each feature ID appeared in
#   data/diffs/<old>_to_<new>.json / .md   Changes between consecutive builds of the same architecture and version
#
# Usage:
#   python update-data.py --summary summary.json --symbols symbol-features.json [--super-god-mode <folder>]
#                                          # add/replace a build, then regenerate everything
#   python update-data.py                  # only regenerate index, first-seen and diffs (and fill in what builds already here lack)
#
# features.json and details.json are written with one feature per line so git diffs between commits stay small and readable. The site
# doesn't load details.json itself: build-site-data.py derives the files it loads when the site is published.

import argparse
import datetime
import json
import os
import re
import shutil
import sys

NUMERIC_NAME = re.compile(r'^(?:ID|FI)?\d+$')
STORE_FIELDS = (('Priority', 'priority'), ('State', 'state'), ('Type', 'type'), ('Variant', 'variant'), ('PayloadKind', 'payloadKind'), ('Payload', 'payload'))
SYMBOL_FIELDS = ('declaredIn', 'default', 'changeTime', 'requires')  # Copied from scan-symbols.py's output when present
CHECK_DAYS = 60     # How long after a build's release catch-up-symbols.py keeps asking the symbol server for the PDBs its scan didn't get
INSIDER_CHECK_DAYS = 14  # The same for an Insider build, which the channel's next build replaces in a week or two (the symbol cache keeps
                         # the PDBs of the builds still checked, and an Insider build has thousands of its own)
WARN_PENDING = 25   # Binaries with features whose symbols a scan didn't get, above which the run gets a warning. A scan normally has a few;
                    # one that runs before Microsoft has published an update's symbols has hundreds.


def load_json(path):
    with open(path, 'r', encoding='utf-8-sig') as f:
        return json.load(f)


def version_tuple(full_build):
    return tuple(int(p) for p in re.findall(r'\d+', full_build))


def build_key(full_build, arch):
    return '%s-%s' % (full_build, arch)


def build_dir(data_dir, key):
    """The build's folder, data/builds/<build>-<arch>/."""
    return os.path.join(data_dir, 'builds', key)


def load_builds(data_dir):
    builds_dir = os.path.join(data_dir, 'builds')
    builds = []
    for name in sorted(os.listdir(builds_dir)) if os.path.isdir(builds_dir) else []:
        path = os.path.join(builds_dir, name, 'features.json')
        if os.path.exists(path):
            builds.append(load_json(path))
    return builds


def release_lookup(data_dir):
    """{build: {'type', 'date', 'kb'}} for every Windows 11 build in data/releases.json (from check-windows-builds.py): the update a
    build came in (e.g. 2026-08 B), its release date and KB article. A build stores its own, so they stay known after the list moves on.
    An Insider build has its release date only (its channel is stored with it); a build that's in both lists is a released build."""
    path = os.path.join(data_dir, 'releases.json')
    if not os.path.exists(path):
        return {}
    doc = load_json(path)
    found = {build: {'date': r['date']} for c in doc.get('insider', []) for r in c.get('releases', []) if r.get('date')
             for build in r.get('builds') or [r['build']]}
    found.update({r['build']: {k: r[k] for k in ('type', 'date', 'kb') if r.get(k)}
                  for v in doc.get('windows11', []) for r in v.get('releases', [])})
    return found


def release_order(b):
    """Where a build is in the order builds came out: its release date, then its build number (a security update's builds of 24H2, 25H2
    and 26H2 come out the same day). A build with no known release date counts from the day it was scanned."""
    return ((b.get('release') or {}).get('date') or (b.get('scannedAt') or '')[:10] or '9999-12-31', version_tuple(b['build']))


def write_build_file(path, header, features):
    """Writes the build JSON with one feature per line."""
    lines = ['{']
    for k, v in header.items():
        lines.append('  %s: %s,' % (json.dumps(k), json.dumps(v)))
    lines.append('  "features": [')
    for i, feat in enumerate(features):
        lines.append('    ' + json.dumps(feat, separators=(',', ':')) + (',' if i < len(features) - 1 else ''))
    lines.append('  ]')
    lines.append('}')
    with open(path, 'w', encoding='utf-8', newline='\n') as f:
        f.write('\n'.join(lines) + '\n')


def warn_renamed(data_dir, key, features):
    """Warns about each feature ID whose name in this build's symbols differs from its name in another build's symbols. Feature IDs
    aren't known to be reused (no ID had two names in the builds scanned up to November 2026), and the names filled in from earlier
    builds (nameSource earlierBuild) depend on that, so a change is worth a look: a feature renamed, or an ID given to another one."""
    names = {e['id']: e['name'] for e in features.values() if e.get('name') and not e.get('nameSource')}
    changed = {}
    for b in load_builds(data_dir):
        if b.get('key') == key:
            continue
        for f in b.get('features', []):
            if f.get('name') and not f.get('nameSource') and f['id'] in names and f['name'] != names[f['id']]:
                changed.setdefault(f['id'], {}).setdefault(f['name'], []).append(b.get('key'))
    lines = ['Feature %s is %s in %s, but %s' % (fid, names[fid], key, '; '.join(
        '%s in %s' % (name, ', '.join(keys)) for name, keys in sorted(changed[fid].items()))) for fid in sorted(changed)]
    # The run's page shows 10 warnings per step; past that, the 10th says how many there are. The log and the run's summary list them all.
    shown = 10 if len(lines) <= 10 else 9
    for n, line in enumerate(lines):
        print(('::warning title=Feature name changed::' if n < shown else '[data] WARNING: ') + line)
    if len(lines) > 10:
        print('::warning title=Feature names changed::%d feature IDs of %s have another name in other builds; the run summary lists them all' % (len(lines), key))
    summary = os.environ.get('GITHUB_STEP_SUMMARY')
    if lines and summary:
        with open(summary, 'a', encoding='utf-8') as f:
            f.write('### Feature names that differ from other builds (%s)\n\n%s\n' % (key, ''.join('- %s\n' % line for line in lines)))
    return len(changed)


def add_build(data_dir, summary_path, symbols_path):
    summary = load_json(summary_path)
    symbols = load_json(symbols_path) if symbols_path and os.path.exists(symbols_path) else {'features': []}

    full_build = summary['fullBuild']
    arch = summary['architecture']
    key = build_key(full_build, arch)

    # The build's data from its earlier scans, which scanning it again adds to (merge_earlier_scan)
    details_path = os.path.join(build_dir(data_dir, key), 'details.json')
    earlier_details = load_json(details_path) if os.path.exists(details_path) else {}
    features_path = os.path.join(build_dir(data_dir, key), 'features.json')
    earlier_build = load_json(features_path) if os.path.exists(features_path) else {}
    earlier_features = {f['id']: f for f in earlier_build.get('features', [])}

    features = {}
    for f in symbols.get('features', []):
        real = [n for n in f.get('names', []) if not NUMERIC_NAME.match(n)]
        name = f.get('name') if f.get('name') and not NUMERIC_NAME.match(f['name']) else (real[0] if real else None)
        entry = {'id': f['id'], 'name': name}
        if len(f.get('names', [])) > 1 or (f.get('names') and name is None):
            entry['symbolNames'] = f['names']
        entry['modules'] = f.get('modules', [])
        for k in SYMBOL_FIELDS:
            if f.get(k):
                entry[k] = f[k]
        if f.get('unverified'):
            entry['unverified'] = True  # Only known from an earlier version of its binary; this build's PDB couldn't be downloaded
        features[f['id']] = entry

    for s in summary.get('features', []):
        fid = int(s['id'])
        entry = features.setdefault(fid, {'id': fid, 'name': None, 'modules': []})
        if not entry['name'] and s.get('name') and not NUMERIC_NAME.match(s['name']):
            entry['name'] = s['name']  # Name from ViVeTool's dictionary, when symbols had none
            entry['nameSource'] = 'vivetool'
        elif s.get('name') and not NUMERIC_NAME.match(s['name']) and s['name'] != entry['name'] and s['name'] not in entry.get('symbolNames', []):
            entry['viveToolName'] = s['name']  # ViVeTool's dictionary names it differently from the symbols
        configs = []
        for c in s.get('configurations', []):
            configs.append({out: c[src] for src, out in STORE_FIELDS if c.get(src) not in (None, '')})
        entry['store'] = configs

    details = {f['id']: dict(f['usage']) for f in symbols.get('features', []) if f.get('usage')}
    merge_earlier_scan(features, details, earlier_features, earlier_details, symbols.get('manifest'))

    # A feature whose code was removed from every binary can stay in the feature store. Its name is still known from earlier builds.
    known = {}
    for b in sorted(load_builds(data_dir), key=lambda b: version_tuple(b['build'])):
        if b['architecture'] == arch and version_tuple(b['build']) < version_tuple(full_build):
            known.update((f['id'], f['name']) for f in b['features'] if f['name'])
    for entry in features.values():
        if not entry['name'] and entry['id'] in known:
            entry['name'] = known[entry['id']]
            entry['nameSource'] = 'earlierBuild'
    warn_renamed(data_dir, key, features)

    product = summary.get('productName') or ''
    if product.startswith('Windows 10') and version_tuple(full_build)[0] >= 22000:
        product = 'Windows 11' + product[len('Windows 10'):]  # The registry still says "Windows 10" on Windows 11

    header = {
        'key': key,
        'build': full_build,
        'architecture': arch,
        'productName': product,
        'displayVersion': summary.get('displayVersion'),
        'scannedAt': summary.get('timestamp'),
        'symbolStats': symbols.get('stats'),
    }
    if summary.get('notes'):
        header['notes'] = summary['notes']  # Anything about the scan worth knowing, such as Store apps the VM couldn't update
    if summary.get('insiderChannel'):
        header['insiderChannel'] = summary['insiderChannel']  # A Windows Insider build, from this channel
    release = release_lookup(data_dir).get(full_build)
    if release:
        header['release'] = release  # Its update, release date and KB article
    ordered = [features[k] for k in sorted(features)]
    # PDBs the scan got no verified data for, which catch-up-symbols.py asks the symbol server for every day until CHECK_DAYS after the
    # release. Those of binaries that had features in earlier versions mean features are only known from those versions (unverified).
    manifest = symbols.get('manifest')
    start = (release or {}).get('date') or (summary.get('timestamp') or '')[:10]
    days = INSIDER_CHECK_DAYS if summary.get('insiderChannel') else CHECK_DAYS
    until = (datetime.date.fromisoformat(start) + datetime.timedelta(days=days)).isoformat() if start else None
    pending = [p for p in (manifest or {}).get('pdbs', {}).values() if p.get('fallbackFeatures')]
    if len(pending) >= WARN_PENDING:  # (The few of a normal scan, such as Store apps updated past their published symbols, only get their features marked)
        header['symbolsPending'] = {'binaries': len(pending), 'unverified': sum(1 for f in ordered if f.get('unverified')), 'until': until}
    if symbols.get('symbolsUpdated'):
        header['symbolsUpdated'] = symbols['symbolsUpdated']  # When catch-up-symbols.py last added PDBs the scan didn't get
    # Modules only the component store has (not installed in the folders the scan covers), and their component
    seen = {m for e in (symbols.get('manifest') or {}).get('pdbs', {}).values() for m in e['modules']}
    component_store = dict({m: c for m, c in (earlier_build.get('componentStore') or {}).items() if m not in seen}, **(symbols.get('componentStore') or {}))
    if component_store:
        header['componentStore'] = dict(sorted(component_store.items(), key=lambda kv: kv[0].lower()))
    os.makedirs(build_dir(data_dir, key), exist_ok=True)
    path = os.path.join(build_dir(data_dir, key), 'features.json')
    write_build_file(path, header, ordered)
    print('[data] wrote %s (%d features, %d named, %d in feature store)' % (
        path, len(ordered), sum(1 for f in ordered if f['name']), sum(1 for f in ordered if 'store' in f)))
    write_details(data_dir, key, details)
    write_symbol_list(data_dir, key, manifest, until)
    if len(pending) >= WARN_PENDING:
        message = ("%s: the symbol server didn't have the symbols of %d binaries whose earlier versions had features, so %d of the build's "
                   'features are only known from those earlier versions (marked unverified). The daily symbol catch-up completes the build '
                   'when Microsoft publishes them.' % (key, len(pending), header['symbolsPending']['unverified']))
        print('::warning title=Symbols not published yet::' + message)
        if os.environ.get('GITHUB_STEP_SUMMARY'):
            with open(os.environ['GITHUB_STEP_SUMMARY'], 'a', encoding='utf-8') as f:
                f.write('> [!WARNING]\n> **Symbols not published yet.** %s\n\n' % message)
    return key


def merge_earlier_scan(features, details, earlier, earlier_details, manifest):
    """Scanning a build again adds to what its earlier scans found and never removes any of it: symbols that can't be downloaded any
    more, a binary the new VM doesn't have (such as an older version of a Store app) or a feature store entry that isn't there today
    take nothing away. A feature, its names, module links, code details, default state, change time, requirements and feature store
    configurations that only the earlier data has are kept; where both have one, this scan's wins. Placeholders are what's replaced:
    a feature marked unverified was only known from an earlier version of a binary, and its links to binaries whose own symbols this
    scan read are dropped (with what they said about the feature)."""
    read = {m for e in (manifest or {}).get('pdbs', {}).values() if e.get('pending') in (None, 'details') for m in e['modules']}
    for fid, old in earlier.items():
        stale = set(old.get('modules', [])) & read if old.get('unverified') else set()
        modules = [m for m in old.get('modules', []) if m not in stale]
        entry = features.get(fid)
        if entry is None:
            if stale and not modules and not old.get('declaredIn') and 'store' not in old:
                continue  # Only a placeholder for binaries this scan read, which don't have it
            entry = features[fid] = dict(old, modules=modules)
            if stale:
                for k in ('default', 'changeTime', 'requires'):
                    entry.pop(k, None)
        else:
            # A name from the symbols over one from ViVeTool's dictionary or an earlier build
            if old.get('name') and (entry['name'] is None or (entry.get('nameSource') and not old.get('nameSource'))):
                if entry.get('nameSource') == 'vivetool' and entry['name'] != old['name']:
                    entry['viveToolName'] = entry['name']
                entry['name'] = old['name']
                entry.pop('nameSource', None)
                if old.get('nameSource'):
                    entry['nameSource'] = old['nameSource']
            if old.get('symbolNames'):
                entry['symbolNames'] = sorted(set(entry.get('symbolNames', [])) | set(old['symbolNames']))
            entry['modules'] = sorted(set(entry['modules']) | set(modules))
            declared = (set(entry.get('declaredIn', [])) | set(old.get('declaredIn', []))) - set(entry['modules'])
            if declared:
                entry['declaredIn'] = sorted(declared)
            else:
                entry.pop('declaredIn', None)
            if not stale:
                for k in ('default', 'changeTime'):
                    if not entry.get(k) and old.get(k):
                        entry[k] = old[k]
                if old.get('requires'):
                    entry['requires'] = sorted(set(entry.get('requires', [])) | set(old['requires']))
            if entry.get('unverified') and not old.get('unverified') and (modules or old.get('declaredIn')):
                del entry['unverified']  # The earlier scan had this build's own symbols for it
            if 'store' not in entry and 'store' in old:
                entry['store'] = old['store']
            if not entry.get('viveToolName') and old.get('viveToolName') and old['viveToolName'] != entry['name']:
                entry['viveToolName'] = old['viveToolName']
        # Code details: this scan's for the binaries it has them for, the earlier ones for the others it still links the feature to
        kept = {m: u for m, u in earlier_details.get(str(fid), {}).items() if m in entry['modules'] and m not in stale and m not in details.get(fid, {})}
        if kept:
            details[fid] = dict(sorted(dict(details.get(fid, {}), **kept).items()))


def write_symbol_list(data_dir, key, manifest, until):
    """Stores the build's PDBs in data/builds/<build>-<arch>/symbols.json, one per line, for catch-up-symbols.py: each with its binaries
    and what's needed to download them, and whether the scan got no verified data for it. It describes the latest scan of the build."""
    path = os.path.join(build_dir(data_dir, key), 'symbols.json')
    if not manifest:
        if os.path.exists(path):
            os.remove(path)  # From an earlier scan of the build; this one didn't list its PDBs
        return
    lines = ['%s: %s' % (json.dumps(k), json.dumps(v, separators=(',', ':'))) for k, v in sorted(manifest['pdbs'].items())]
    with open(path, 'w', encoding='utf-8', newline='\n') as f:
        f.write('{"cacheVersion": %d, "checkUntil": %s, "pdbs": {\n' % (manifest['cacheVersion'], json.dumps(until)) + ',\n'.join(lines) + '\n}}\n')


def write_details(data_dir, key, usage):
    """Stores a build's usage details in data/builds/<build>-<arch>/details.json: for each feature ID, what each binary's code reveals
    about it (how it's used, callers, strings, ...). Scanning a build again adds to it (merge_earlier_scan)."""
    if not usage:
        return  # A scan without code analysis
    path = os.path.join(build_dir(data_dir, key), 'details.json')
    lines = ['%s: %s' % (json.dumps(str(fid)), json.dumps(usage[fid], separators=(',', ':'))) for fid in sorted(usage, key=int)]
    with open(path, 'w', encoding='utf-8', newline='\n') as f:
        f.write('{\n' + ',\n'.join(lines) + '\n}\n')  # One feature per line, like features.json
    print('[data] wrote usage details for %d features to %s' % (len(usage), path))


def store_super_god_mode(data_dir, key, folder):
    """Copies Super God Mode's statistics for a build (the CSV and XML files run-super-god-mode.ps1 keeps, as they are, and its
    run.json) to data/builds/<build>-<arch>/super-god-mode/, replacing what an earlier scan of the build stored there unless this run
    produced none."""
    if not folder or not os.path.isdir(folder) or not os.listdir(folder):
        print('[data] no Super God Mode statistics for %s' % key)
        return
    dest = os.path.join(build_dir(data_dir, key), 'super-god-mode')
    tables = lambda d: any(n.lower().endswith('.csv') for n in os.listdir(d))
    if not tables(folder) and os.path.isdir(dest) and tables(dest):
        print('[data] Super God Mode produced no statistics for %s this time; keeping those of the earlier scan' % key)
        return
    if os.path.isdir(dest):
        shutil.rmtree(dest)
    shutil.copytree(folder, dest)
    print('[data] stored Super God Mode statistics in %s: %s' % (dest, ', '.join(sorted(os.listdir(dest)))))


def store_signature(feat):
    return json.dumps(feat.get('store'), sort_keys=True) if 'store' in feat else None


def diff_builds(old, new):
    of = {f['id']: f for f in old['features']}
    nf = {f['id']: f for f in new['features']}
    added = [nf[i] for i in sorted(set(nf) - set(of))]
    removed = [of[i] for i in sorted(set(of) - set(nf))]
    renamed, newly_named, name_lost, store_changed, default_changed = [], [], [], [], []
    for i in sorted(set(of) & set(nf)):
        a, b = of[i], nf[i]
        if a['name'] != b['name']:
            if a['name'] is None:
                newly_named.append({'id': i, 'name': b['name']})
            elif b['name'] is not None:
                renamed.append({'id': i, 'oldName': a['name'], 'newName': b['name']})
            else:
                name_lost.append({'id': i, 'oldName': a['name']})
        if store_signature(a) != store_signature(b):
            store_changed.append({'id': i, 'name': b['name'] or a['name'], 'old': a.get('store'), 'new': b.get('store')})
        # Only where both builds know the value; builds scanned before default states were read don't have them
        old_default = {k: a[k] for k in ('default', 'changeTime') if a.get(k) and b.get(k)}
        new_default = {k: b[k] for k in old_default}
        if old_default != new_default:
            default_changed.append({'id': i, 'name': b['name'] or a['name'], 'old': old_default, 'new': new_default})

    def brief(f):
        out = {'id': f['id'], 'name': f['name'], 'modules': f.get('modules', []), 'store': f.get('store')}
        if f.get('unverified'):
            out['unverified'] = True
        return out
    return {
        'old': old['key'], 'new': new['key'],
        'added': [brief(f) for f in added],
        'removed': [brief(f) for f in removed],
        'renamed': renamed,
        'newlyNamed': newly_named,
        'nameLost': name_lost,
        'storeChanged': store_changed,
        'defaultChanged': default_changed,
    }


def diff_markdown(d):
    def table(rows, cols):
        out = ['| ' + ' | '.join(c for c, _ in cols) + ' |', '|' + '---|' * len(cols)]
        for r in rows:
            out.append('| ' + ' | '.join(str(fn(r)).replace('|', '\\|') for _, fn in cols) + ' |')
        return out
    named = lambda rows: [r for r in rows if r.get('name')]
    lines = ['# Feature changes: %s → %s' % (d['old'], d['new']), '',
             '| | Count | Named |', '|---|---|---|',
             '| Added | %d | %d |' % (len(d['added']), len(named(d['added']))),
             '| Removed | %d | %d |' % (len(d['removed']), len(named(d['removed']))),
             '| Renamed | %d | |' % len(d['renamed']),
             '| Newly named | %d | |' % len(d['newlyNamed']),
             '| Name lost | %d | |' % len(d['nameLost']),
             '| Feature store changes | %d | |' % len(d['storeChanged']),
             '| Default changed | %d | |' % len(d['defaultChanged']), '']
    mods = lambda r: ', '.join(r.get('modules', [])[:4]) + (' …' if len(r.get('modules', [])) > 4 else '')
    for title, rows in (('Added', d['added']), ('Removed', d['removed'])):
        lines += ['## %s' % title, '']
        lines += table(rows, [('ID', lambda r: r['id']), ('Name', lambda r: r['name'] or ''), ('Modules', mods)]) if rows else ['None.']
        lines.append('')
    if d['renamed']:
        lines += ['## Renamed', ''] + table(d['renamed'], [('ID', lambda r: r['id']), ('Old name', lambda r: r['oldName']), ('New name', lambda r: r['newName'])]) + ['']
    if d['newlyNamed']:
        lines += ['## Newly named', ''] + table(d['newlyNamed'], [('ID', lambda r: r['id']), ('Name', lambda r: r['name'])]) + ['']
    if d['nameLost']:
        lines += ['## Name lost', ''] + table(d['nameLost'], [('ID', lambda r: r['id']), ('Old name', lambda r: r['oldName'])]) + ['']
    if d['defaultChanged']:
        state = lambda x: ', '.join(x[k] for k in ('default', 'changeTime') if k in x)
        lines += ['## Default changed', ''] + table(d['defaultChanged'], [('ID', lambda r: r['id']), ('Name', lambda r: r['name'] or ''),
                                                                          ('Old', lambda r: state(r['old'])), ('New', lambda r: state(r['new']))]) + ['']
    return '\n'.join(lines) + '\n'


def regenerate(data_dir):
    builds = load_builds(data_dir)
    builds.sort(key=lambda b: (b['architecture'], version_tuple(b['build'])))

    # A build without its update, release date and KB (scanned before they were stored, or before data/releases.json had it) gets them
    releases = release_lookup(data_dir)
    for b in builds:
        if not b.get('release') and b['build'] in releases:
            b['release'] = releases[b['build']]
            write_build_file(os.path.join(build_dir(data_dir, b['key']), 'features.json'), {k: v for k, v in b.items() if k != 'features'}, b['features'])
            print('[data] stored the release of %s: %s, %s, %s' % (b['key'], b['release'].get('type'), b['release'].get('date'), b['release'].get('kb')))

    # A feature the symbols don't name gets its name from the earlier builds of the architecture when a build is added (add_build). Builds
    # aren't always added in order (older ones scanned later), so a build already here gets the names an earlier one added since has.
    known, arch = {}, None
    for b in builds:  # By architecture, then version
        if b['architecture'] != arch:
            known, arch = {}, b['architecture']
        filled = 0
        for f in b['features']:
            if not f['name'] and f['id'] in known:
                f['name'] = known[f['id']]
                f['nameSource'] = 'earlierBuild'
                filled += 1
        known.update((f['id'], f['name']) for f in b['features'] if f['name'])
        if filled:
            write_build_file(os.path.join(build_dir(data_dir, b['key']), 'features.json'), {k: v for k, v in b.items() if k != 'features'}, b['features'])
            print('[data] filled in %d names of %s from earlier builds' % (filled, b['key']))

    # Index
    index = {'generated': datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'), 'builds': []}
    for b in builds:
        feats = b['features']
        index['builds'].append({
            'key': b['key'], 'build': b['build'], 'architecture': b['architecture'],
            'productName': b.get('productName'), 'displayVersion': b.get('displayVersion'), 'scannedAt': b.get('scannedAt'),
            'features': len(feats), 'named': sum(1 for f in feats if f['name']), 'inStore': sum(1 for f in feats if 'store' in f),
        })
        if b.get('notes'):
            index['builds'][-1]['notes'] = b['notes']
        if b.get('insiderChannel'):
            index['builds'][-1]['insiderChannel'] = b['insiderChannel']
        if b.get('release'):
            index['builds'][-1]['release'] = b['release']

    # First seen, per architecture. The first tracked build of an architecture is where tracking began, not necessarily where a feature appeared.
    # Builds count in the order they came out, so a feature an Insider build had before a released build with a lower number counts in the
    # Insider build, and one a 25H2 build had in July doesn't count in a 24H2 build scanned from October. Builds that came out the same day
    # count together: a feature that several of them were the first to have, such as a security update's builds of 24H2, 25H2 and 26H2, or
    # Insider builds of several channels, has a list of them instead of one build.
    first_seen = {}
    first_tracked = {}
    for b in sorted(builds, key=release_order):
        arch = b['architecture']
        first_tracked.setdefault(arch, b['key'])
        seen = first_seen.setdefault(arch, {})
        day = release_order(b)[0]
        for f in b['features']:
            first = seen.setdefault(str(f['id']), (day, []))
            if first[0] == day:
                first[1].append(b['key'])
    first_seen = {arch: {i: keys[0] if len(keys) == 1 else keys for i, (_, keys) in seen.items()} for arch, seen in first_seen.items()}
    with open(os.path.join(data_dir, 'first-seen.json'), 'w', encoding='utf-8', newline='\n') as f:
        json.dump({'firstTrackedBuild': first_tracked, 'firstSeen': first_seen}, f, separators=(',', ':'), sort_keys=True)

    # Diffs with the previous build of the same architecture and version (base build number), since builds of 25H2 and 26H2 come
    # out side by side. A version's first build is compared with the other version's build at the same update instead (the same
    # binaries, so what differs is the enablement package), or the newest one before it.
    diffs_dir = os.path.join(data_dir, 'diffs')
    os.makedirs(diffs_dir, exist_ok=True)
    wanted = set()
    for i, cur in enumerate(builds):
        earlier = [b for b in builds[:i] if b['architecture'] == cur['architecture']]
        same_version = [b for b in earlier if b['build'].split('.')[0] == cur['build'].split('.')[0]]
        if same_version:
            prev = same_version[-1]
        else:
            ubr = version_tuple(cur['build'])[1]
            others = [b for b in earlier if version_tuple(b['build'])[1] <= ubr]
            if not others:
                continue
            prev = max(others, key=lambda b: (version_tuple(b['build'])[1], version_tuple(b['build'])))
        d = diff_builds(prev, cur)
        name = '%s_to_%s' % (prev['key'], cur['key'])
        wanted.update({name + '.json', name + '.md'})
        with open(os.path.join(diffs_dir, name + '.json'), 'w', encoding='utf-8', newline='\n') as f:
            json.dump(d, f, indent=1)
        with open(os.path.join(diffs_dir, name + '.md'), 'w', encoding='utf-8', newline='\n') as f:
            f.write(diff_markdown(d))
        index_entry = next(x for x in index['builds'] if x['key'] == cur['key'])
        index_entry['previous'] = prev['key']
        index_entry['diff'] = {k: len(d[k]) for k in ('added', 'removed', 'renamed', 'newlyNamed', 'nameLost', 'storeChanged', 'defaultChanged')}
    for fn in os.listdir(diffs_dir):
        if fn not in wanted:
            os.remove(os.path.join(diffs_dir, fn))  # Stale diff (e.g. a build was inserted between two others)

    with open(os.path.join(data_dir, 'index.json'), 'w', encoding='utf-8', newline='\n') as f:
        json.dump(index, f, indent=1)
    print('[data] %d builds indexed, %d diffs' % (len(builds), len(wanted) // 2))


def main():
    parser = argparse.ArgumentParser(description='Add a scanned build to the feature database and regenerate derived files.')
    parser.add_argument('--data-dir', default='data')
    parser.add_argument('--summary', help='summary.json from scan-features.ps1')
    parser.add_argument('--symbols', help='symbol-features.json from scan-symbols.py')
    parser.add_argument('--super-god-mode', help="Folder with Super God Mode's statistics for the build (from run-super-god-mode.ps1)")
    args = parser.parse_args()
    if args.summary:
        key = add_build(args.data_dir, args.summary, args.symbols)
        if args.super_god_mode:
            store_super_god_mode(args.data_dir, key, args.super_god_mode)
    regenerate(args.data_dir)
    return 0


if __name__ == '__main__':
    sys.exit(main())
