# update-data.py
# Maintains the feature database in data/:
#
#   data/builds/<build>-<arch>/            A folder per scanned build:
#       features.json                      every feature ID found (named or not), from symbols, the feature store and/or a feature trace
#       details.json                       what each binary's code reveals about each feature (callers, strings, ...)
#       super-god-mode/                    Super God Mode's statistics for the build, its CSV and XML files as it writes them
#       trace.json                         the build's latest feature trace (trace-features.ps1): its run, and what each target checked
#   data/index.json                        List of tracked builds with summary counts (what the site loads first)
#   data/first-seen.json                   For each architecture, the first tracked build(s) each feature ID appeared in
#
# Usage:
#   python scripts/update-data.py --summary summary.json --symbols symbol-features.json [--super-god-mode <folder>] [--trace <folder>]
#                                          # add/replace a build, then regenerate everything
#   python scripts/update-data.py          # only regenerate index and first-seen (and fill in what builds already here lack)
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
TRACE_LIST_LIMIT = 8  # Processes and targets kept in a feature's trace entry (the build's trace.json has every target's features)
ALWAYS = {'enabled': 'alwaysEnabled', 'disabled': 'alwaysDisabled'}


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


def add_build(data_dir, summary_path, symbols_path, trace_dir=None):
    summary = load_json(summary_path)
    symbols = load_json(symbols_path) if symbols_path and os.path.exists(symbols_path) else {'features': []}
    trace_path = os.path.join(trace_dir, 'trace.json') if trace_dir else None
    trace = load_json(trace_path) if trace_path and os.path.exists(trace_path) else None
    if trace_dir and not trace:
        print('[data] no feature trace for this build (%s has no trace.json)' % trace_dir)

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
    if trace:
        add_trace(features, trace)
    trace_defaults(features)

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
    trace_run = trace_header(trace, features) if trace else earlier_build.get('trace')
    if trace_run:
        header['trace'] = trace_run  # The latest feature trace of the build (its features keep what earlier ones saw too)
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
    if trace:
        write_trace(data_dir, key, trace)
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
                for k in ('default', 'defaultSource', 'symbolDefault', 'changeTime', 'requires'):
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
                        if k == 'default':
                            for extra in ('defaultSource', 'symbolDefault'):
                                if old.get(extra):
                                    entry[extra] = old[extra]
                if old.get('requires'):
                    entry['requires'] = sorted(set(entry.get('requires', [])) | set(old['requires']))
            if entry.get('unverified') and not old.get('unverified') and (modules or old.get('declaredIn')):
                del entry['unverified']  # The earlier scan had this build's own symbols for it
            if 'store' not in entry and 'store' in old:
                entry['store'] = old['store']
            if not entry.get('viveToolName') and old.get('viveToolName') and old['viveToolName'] != entry['name']:
                entry['viveToolName'] = old['viveToolName']
            if 'trace' in old:
                entry['trace'] = old['trace']  # What earlier traces saw (add_trace adds this scan's trace to it)
        # Code details: this scan's for the binaries it has them for, the earlier ones for the others it still links the feature to
        kept = {m: u for m, u in earlier_details.get(str(fid), {}).items() if m in entry['modules'] and m not in stale and m not in details.get(fid, {})}
        if kept:
            details[fid] = dict(sorted(dict(details.get(fid, {}), **kept).items()))


def trace_only(f):
    """Whether only a feature trace knows the feature: no binary's symbols have it, nor the feature store. Its first trace isn't where
    it first appeared, so such a feature counts in neither first seen nor the diffs between builds."""
    return 'trace' in f and not f.get('modules') and not f.get('declaredIn') and 'store' not in f


def rollout_entry(config):
    """Whether a feature store entry is the rollout service's (priority Service): Windows writes those after it checks in with Microsoft,
    for features Microsoft is rolling out to a share of PCs or testing, so which ones a VM gets depends on the day and on chance, not on
    the build."""
    return str(config.get('priority', '')).startswith('Service')


def as_built(f):
    """The feature as the build itself has it, for comparing builds and first seen: without the rollout service's feature store entries,
    or None if nothing else knows it (no binary's symbols, no other feature store entry, no feature trace)."""
    store = [c for c in f.get('store', []) if not rollout_entry(c)]
    if len(store) == len(f.get('store', [])):
        return f
    out = {k: v for k, v in f.items() if k != 'store'}
    if store:
        out['store'] = store
    return out if out.get('modules') or out.get('declaredIn') or 'store' in out or 'trace' in out else None


def merge_trace(old, new):
    """A feature's trace entry with what another trace saw added: the newer's values first, then the older's that it doesn't have"""
    out = {}
    for k in ('stages', 'results', 'variants', 'processes', 'targets'):
        items = list(new.get(k, [])) + [x for x in old.get(k, []) if x not in new.get(k, [])]
        if k in ('results', 'variants'):
            items = sorted(items)
        elif k in ('processes', 'targets'):
            items = items[:TRACE_LIST_LIMIT]
        if items:
            out[k] = items
    return out


def add_trace(features, trace):
    """Adds a feature trace (trace.json from summarize-trace.py) to the build's features. Each feature it saw checked gets a trace
    entry: the stages its checks reported (the stage compiled into the binary that checked it, the one most checks reported first),
    how they came out (on, off), the variants of variant checks, and the processes that checked it (the most checks first) and the
    targets (those with the fewest features first, the most particular to it), up to TRACE_LIST_LIMIT of each. A feature no symbols or feature store had gets an entry of its own. A scan of the build again adds to them."""
    added = 0
    for fid, t in trace.get('features', {}).items():
        fid = int(fid)
        if fid not in features:
            features[fid] = {'id': fid, 'name': None, 'modules': []}
            added += 1
        new = {'stages': [t['stage']] + [s for s in t['stages'] if s != t['stage']], 'results': t['results']}
        for k in ('variants', 'processes', 'targets'):
            if t.get(k):
                new[k] = t[k]
        features[fid]['trace'] = merge_trace(features[fid].get('trace', {}), new)
    print('[data] feature trace: %d features checked, %d of them found by nothing else' % (len(trace.get('features', {})), added))


def add_trace_only(data_dir, summary_path, trace_dir):
    """Adds a feature trace to a build data/ has, without scanning it again (scan-in-vm.ps1 -TraceOnly, whose summary.json only says
    which build it is): its features get what the trace saw (add_trace) and the defaults it gives (trace_defaults), the build's header the
    run (trace_header) and trace.json the targets. Nothing else of the build changes. Returns the build's key."""
    summary = load_json(summary_path)
    key = build_key(summary['fullBuild'], summary['architecture'])
    path = os.path.join(build_dir(data_dir, key), 'features.json')
    if not os.path.exists(path):
        sys.exit('[data] %s is not in data/: a trace alone can only be added to a build that was scanned' % key)
    trace_path = os.path.join(trace_dir or '', 'trace.json')
    if not trace_dir or not os.path.exists(trace_path):
        sys.exit('[data] no feature trace of %s to add (%s has no trace.json)' % (key, trace_dir))
    trace = load_json(trace_path)
    build = load_json(path)
    features = {f['id']: f for f in build['features']}
    before = len(features)
    add_trace(features, trace)
    trace_defaults(features)
    # The run goes where add_build puts it: after the notes, or after the symbols' statistics
    header, run, after = {}, trace_header(trace, features), 'notes' if 'notes' in build else 'symbolStats'
    for k, v in build.items():
        if k != 'features':
            header[k] = run if k == 'trace' else v
        if k == after and 'trace' not in build:
            header['trace'] = run
    header.setdefault('trace', run)
    write_build_file(path, header, [features[k] for k in sorted(features)])
    write_trace(data_dir, key, trace)
    print('[data] added the feature trace of %s: %d features checked, %d of them new to the build' % (
        key, len(trace.get('features', {})), len(features) - before))
    return key


def trace_defaults(features):
    """Defaults from the feature trace (defaultSource 'trace'): the stage most checks reported, for a feature the symbols give no
    default for; and always enabled (or always disabled) where the symbols say enabled (disabled) but every check reported always,
    since C++ code only shows whether a feature is enabled or disabled. Where the trace and the symbols disagree otherwise, the symbols'
    default stays (the site shows what the trace saw with it): the binaries that checked it may not be the ones the default is from.
    The symbols' own default of a refined feature stays in symbolDefault, which is what comparisons between builds use."""
    for entry in features.values():
        t = entry.get('trace')
        if not t:
            continue
        symbols = symbol_default(entry)
        if not symbols:
            entry['default'] = t['stages'][0]
            entry['defaultSource'] = 'trace'
            entry.pop('symbolDefault', None)
        elif symbols in ALWAYS and set(t['stages']) == {ALWAYS[symbols]}:
            entry['default'] = ALWAYS[symbols]
            entry['defaultSource'] = 'trace'
            entry['symbolDefault'] = symbols
        elif entry.get('defaultSource') == 'trace':
            entry['default'] = symbols  # (Refined by an earlier trace that this one doesn't bear out)
            entry.pop('defaultSource', None)
            entry.pop('symbolDefault', None)


def symbol_default(f):
    """The default the symbols give a feature (None for one only a feature trace gives)"""
    return f.get('symbolDefault') or (f.get('default') if f.get('defaultSource') != 'trace' else None)


def trace_header(trace, features):
    """The build header's summary of its latest feature trace"""
    run = trace.get('run', {})
    out = {k: run[k] for k in ('tracedAt', 'minutes', 'boot', 'checks', 'eventsLost') if k in run}
    out['features'] = len(trace.get('features', {}))
    out['traceOnly'] = sum(1 for f in features.values() if trace_only(f))
    out['targets'] = sum(v.get('opened', 0) for v in run.get('targets', {}).values())
    if run.get('error'):
        out['error'] = run['error']
    return out


def write_trace(data_dir, key, trace):
    """Stores the run of a build's latest feature trace and its targets (with the features each one checked) in
    data/builds/<build>-<arch>/trace.json, one target per line. What it saw of each feature is in features.json."""
    path = os.path.join(build_dir(data_dir, key), 'trace.json')
    with open(path, 'w', encoding='utf-8', newline='\n') as f:
        f.write('{"run": %s,\n"targets": [\n%s\n]}\n' % (json.dumps(trace.get('run', {})),
                                                        ',\n'.join(json.dumps(t, separators=(',', ':')) for t in trace.get('targets', []))))
    print('[data] wrote the feature trace run (%d targets) to %s' % (len(trace.get('targets', [])), path))


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
    of = {f['id']: f for f in map(as_built, old['features']) if f}
    nf = {f['id']: f for f in map(as_built, new['features']) if f}
    added = [nf[i] for i in sorted(set(nf) - set(of)) if not trace_only(nf[i])]  # (A trace sees what's checked while it runs, not what's new)
    removed = [of[i] for i in sorted(set(of) - set(nf)) if not trace_only(of[i])]
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
        # Only where both builds know the value; builds scanned before default states were read don't have them. The symbols' defaults,
        # not feature traces': a trace only has the binaries that checked the feature while it ran, which needn't be the same ones each time.
        va = {'default': symbol_default(a), 'changeTime': a.get('changeTime')}
        vb = {'default': symbol_default(b), 'changeTime': b.get('changeTime')}
        old_default = {k: va[k] for k in ('default', 'changeTime') if va[k] and vb[k]}
        new_default = {k: vb[k] for k in old_default}
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
        # Its resource data (scan-resources.py), which the site loads from the assets branch
        resources = os.path.join(build_dir(data_dir, b['key']), 'resources.json')
        if os.path.exists(resources):
            r = load_json(resources)
            index['builds'][-1]['resources'] = {'files': r.get('files'), 'scannedAt': r.get('scannedAt')}

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
            f = as_built(f)
            if not f or trace_only(f):
                continue
            first = seen.setdefault(str(f['id']), (day, []))
            if first[0] == day:
                first[1].append(b['key'])
    first_seen = {arch: {i: keys[0] if len(keys) == 1 else keys for i, (_, keys) in seen.items()} for arch, seen in first_seen.items()}
    with open(os.path.join(data_dir, 'first-seen.json'), 'w', encoding='utf-8', newline='\n') as f:
        json.dump({'firstTrackedBuild': first_tracked, 'firstSeen': first_seen}, f, separators=(',', ':'), sort_keys=True)

    # Each build's previous build (the index's previous, which the site's compare view starts from, with the counts of what changed
    # since it): the previous build of the same architecture and version (base build number), since builds of 25H2 and 26H2 come out
    # side by side. A version's first build is compared with the other version's build at the same update instead (the same binaries,
    # so what differs is the enablement package), or the newest one before it. Only versions whose base build numbers are less than
    # 1,000 apart count: 24H2, 25H2 and 26H2 (26100, 26200, 26300) share their updates' numbers, but 26H1 (28000) and the Future
    # Platforms builds (29000s) number their own. (The site compares any two builds from their features.json files.)
    for i, cur in enumerate(builds):
        earlier = [b for b in builds[:i] if b['architecture'] == cur['architecture']]
        same_version = [b for b in earlier if b['build'].split('.')[0] == cur['build'].split('.')[0]]
        if same_version:
            prev = same_version[-1]
        else:
            ubr = version_tuple(cur['build'])[1]
            base = version_tuple(cur['build'])[0]
            others = [b for b in earlier if version_tuple(b['build'])[1] <= ubr and abs(version_tuple(b['build'])[0] - base) < 1000]
            if not others:
                continue
            prev = max(others, key=lambda b: (version_tuple(b['build'])[1], version_tuple(b['build'])))
        d = diff_builds(prev, cur)
        index_entry = next(x for x in index['builds'] if x['key'] == cur['key'])
        index_entry['previous'] = prev['key']
        index_entry['diff'] = {k: len(d[k]) for k in ('added', 'removed', 'renamed', 'newlyNamed', 'nameLost', 'storeChanged', 'defaultChanged')}

    with open(os.path.join(data_dir, 'index.json'), 'w', encoding='utf-8', newline='\n') as f:
        json.dump(index, f, indent=1)
    print('[data] %d builds indexed' % len(builds))


def main():
    parser = argparse.ArgumentParser(description='Add a scanned build to the feature database and regenerate derived files.')
    parser.add_argument('--data-dir', default='data')
    parser.add_argument('--summary', help='summary.json from scan-features.ps1')
    parser.add_argument('--symbols', help='symbol-features.json from scan-symbols.py')
    parser.add_argument('--super-god-mode', help="Folder with Super God Mode's statistics for the build (from run-super-god-mode.ps1)")
    parser.add_argument('--trace', help='Folder with the feature trace of the build (trace.json, from trace-features.ps1)')
    args = parser.parse_args()
    if args.summary and load_json(args.summary).get('traceOnly'):
        add_trace_only(args.data_dir, args.summary, args.trace)  # (Its --symbols and --super-god-mode aren't used)
    elif args.summary:
        key = add_build(args.data_dir, args.summary, args.symbols, args.trace)
        if args.super_god_mode:
            store_super_god_mode(args.data_dir, key, args.super_god_mode)
    regenerate(args.data_dir)
    return 0


if __name__ == '__main__':
    sys.exit(main())
