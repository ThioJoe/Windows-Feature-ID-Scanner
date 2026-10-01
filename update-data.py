# update-data.py
# Maintains the feature database in data/:
#
#   data/builds/<build>-<arch>.json        One file per scanned build: every feature ID found (named or not), from symbols and/or the feature store
#   data/index.json                        List of tracked builds with summary counts (what the site loads first)
#   data/first-seen.json                   For each architecture, the first tracked build each feature ID appeared in
#   data/diffs/<old>_to_<new>.json / .md   Changes between consecutive builds of the same architecture
#
# Usage:
#   python update-data.py --summary summary.json --symbols symbol-features.json   # add/replace a build, then regenerate everything
#   python update-data.py                                                         # only regenerate index, first-seen and diffs
#
# Build files are written with one feature per line so git diffs between commits stay small and readable.

import argparse
import datetime
import json
import os
import re
import sys

NUMERIC_NAME = re.compile(r'^(?:ID|FI)?\d+$')
STORE_FIELDS = (('Priority', 'priority'), ('State', 'state'), ('Type', 'type'), ('Variant', 'variant'), ('PayloadKind', 'payloadKind'), ('Payload', 'payload'))


def load_json(path):
    with open(path, 'r', encoding='utf-8-sig') as f:
        return json.load(f)


def version_tuple(full_build):
    return tuple(int(p) for p in re.findall(r'\d+', full_build))


def build_key(full_build, arch):
    return '%s-%s' % (full_build, arch)


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


def add_build(data_dir, summary_path, symbols_path):
    summary = load_json(summary_path)
    symbols = load_json(symbols_path) if symbols_path and os.path.exists(symbols_path) else {'features': []}

    full_build = summary['fullBuild']
    arch = summary['architecture']
    key = build_key(full_build, arch)

    features = {}
    for f in symbols.get('features', []):
        real = [n for n in f.get('names', []) if not NUMERIC_NAME.match(n)]
        name = f.get('name') if f.get('name') and not NUMERIC_NAME.match(f['name']) else (real[0] if real else None)
        entry = {'id': f['id'], 'name': name}
        if len(f.get('names', [])) > 1 or (f.get('names') and name is None):
            entry['symbolNames'] = f['names']
        entry['modules'] = f.get('modules', [])
        if f.get('unverified'):
            entry['unverified'] = True  # Only known from an earlier version of its binary; this build's PDB couldn't be downloaded
        features[f['id']] = entry

    for s in summary.get('features', []):
        fid = int(s['id'])
        entry = features.setdefault(fid, {'id': fid, 'name': None, 'modules': []})
        if not entry['name'] and s.get('name') and not NUMERIC_NAME.match(s['name']):
            entry['name'] = s['name']  # Name from ViVeTool's dictionary, when symbols had none
            entry['nameSource'] = 'vivetool'
        configs = []
        for c in s.get('configurations', []):
            configs.append({out: c[src] for src, out in STORE_FIELDS if c.get(src) not in (None, '')})
        entry['store'] = configs

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
    ordered = [features[k] for k in sorted(features)]
    os.makedirs(os.path.join(data_dir, 'builds'), exist_ok=True)
    path = os.path.join(data_dir, 'builds', key + '.json')
    write_build_file(path, header, ordered)
    print('[data] wrote %s (%d features, %d named, %d in feature store)' % (
        path, len(ordered), sum(1 for f in ordered if f['name']), sum(1 for f in ordered if 'store' in f)))
    return key


def store_signature(feat):
    return json.dumps(feat.get('store'), sort_keys=True) if 'store' in feat else None


def diff_builds(old, new):
    of = {f['id']: f for f in old['features']}
    nf = {f['id']: f for f in new['features']}
    added = [nf[i] for i in sorted(set(nf) - set(of))]
    removed = [of[i] for i in sorted(set(of) - set(nf))]
    renamed, newly_named, store_changed = [], [], []
    for i in sorted(set(of) & set(nf)):
        a, b = of[i], nf[i]
        if a['name'] != b['name']:
            if a['name'] is None:
                newly_named.append({'id': i, 'name': b['name']})
            elif b['name'] is not None:
                renamed.append({'id': i, 'oldName': a['name'], 'newName': b['name']})
        if store_signature(a) != store_signature(b):
            store_changed.append({'id': i, 'name': b['name'] or a['name'], 'old': a.get('store'), 'new': b.get('store')})
    brief = lambda f: {'id': f['id'], 'name': f['name'], 'modules': f.get('modules', []), 'store': f.get('store')}
    return {
        'old': old['key'], 'new': new['key'],
        'added': [brief(f) for f in added],
        'removed': [brief(f) for f in removed],
        'renamed': renamed,
        'newlyNamed': newly_named,
        'storeChanged': store_changed,
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
             '| Feature store changes | %d | |' % len(d['storeChanged']), '']
    mods = lambda r: ', '.join(r.get('modules', [])[:4]) + (' …' if len(r.get('modules', [])) > 4 else '')
    for title, rows in (('Added', d['added']), ('Removed', d['removed'])):
        lines += ['## %s' % title, '']
        lines += table(rows, [('ID', lambda r: r['id']), ('Name', lambda r: r['name'] or ''), ('Modules', mods)]) if rows else ['None.']
        lines.append('')
    if d['renamed']:
        lines += ['## Renamed', ''] + table(d['renamed'], [('ID', lambda r: r['id']), ('Old name', lambda r: r['oldName']), ('New name', lambda r: r['newName'])]) + ['']
    if d['newlyNamed']:
        lines += ['## Newly named', ''] + table(d['newlyNamed'], [('ID', lambda r: r['id']), ('Name', lambda r: r['name'])]) + ['']
    return '\n'.join(lines) + '\n'


def regenerate(data_dir):
    builds_dir = os.path.join(data_dir, 'builds')
    builds = []
    for fn in sorted(os.listdir(builds_dir)) if os.path.isdir(builds_dir) else []:
        if fn.endswith('.json'):
            builds.append(load_json(os.path.join(builds_dir, fn)))
    builds.sort(key=lambda b: (b['architecture'], version_tuple(b['build'])))

    # Index
    index = {'generated': datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'), 'builds': []}
    for b in builds:
        feats = b['features']
        index['builds'].append({
            'key': b['key'], 'build': b['build'], 'architecture': b['architecture'],
            'productName': b.get('productName'), 'displayVersion': b.get('displayVersion'), 'scannedAt': b.get('scannedAt'),
            'features': len(feats), 'named': sum(1 for f in feats if f['name']), 'inStore': sum(1 for f in feats if 'store' in f),
        })

    # First seen, per architecture. The first tracked build of an architecture is where tracking began, not necessarily where a feature appeared.
    first_seen = {}
    first_tracked = {}
    for b in builds:
        arch = b['architecture']
        first_tracked.setdefault(arch, b['key'])
        seen = first_seen.setdefault(arch, {})
        for f in b['features']:
            seen.setdefault(str(f['id']), b['key'])
    with open(os.path.join(data_dir, 'first-seen.json'), 'w', encoding='utf-8', newline='\n') as f:
        json.dump({'firstTrackedBuild': first_tracked, 'firstSeen': first_seen}, f, separators=(',', ':'), sort_keys=True)

    # Consecutive diffs, per architecture
    diffs_dir = os.path.join(data_dir, 'diffs')
    os.makedirs(diffs_dir, exist_ok=True)
    wanted = set()
    for prev, cur in zip(builds, builds[1:]):
        if prev['architecture'] != cur['architecture']:
            continue
        d = diff_builds(prev, cur)
        name = '%s_to_%s' % (prev['key'], cur['key'])
        wanted.update({name + '.json', name + '.md'})
        with open(os.path.join(diffs_dir, name + '.json'), 'w', encoding='utf-8', newline='\n') as f:
            json.dump(d, f, indent=1)
        with open(os.path.join(diffs_dir, name + '.md'), 'w', encoding='utf-8', newline='\n') as f:
            f.write(diff_markdown(d))
        index_entry = next(x for x in index['builds'] if x['key'] == cur['key'])
        index_entry['previous'] = prev['key']
        index_entry['diff'] = {k: len(d[k]) for k in ('added', 'removed', 'renamed', 'newlyNamed', 'storeChanged')}
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
    args = parser.parse_args()
    if args.summary:
        add_build(args.data_dir, args.summary, args.symbols)
    regenerate(args.data_dir)
    return 0


if __name__ == '__main__':
    sys.exit(main())
