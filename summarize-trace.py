# summarize-trace.py
# Summarizes a feature trace (trace-features.ps1) into trace.json in the same folder:
#
#   python summarize-trace.py <folder>      # with events.xml (tracerpt's decoding), processes.csv, targets.csv and run.json
#
# For each feature checked: the stages its checks reported (the stage compiled into the binary that checked it), how they came out
# (on or off, and the variant for variant checks), the processes that checked it, the phases of the trace it was checked in, and the
# targets (pages, folders, apps, ...) it can be put down to. A target's checks are those made while it was open by processes in the
# signed-in user's session, other than trace-features.ps1's own; checks that most targets of its kind make (such as File Explorer's
# for any folder) are left out, so what's left is particular to it. The run's details (when, how long, events lost, the targets and
# what each opened) go with them. update-data.py adds the summary to the build's data.

import bisect
import csv
import json
import os
import re
import sys
import xml.etree.ElementTree as ET
from collections import Counter, defaultdict
from datetime import datetime, timedelta

NS = '{http://schemas.microsoft.com/win/2004/08/events/event}'
PROVIDER = 'c2f36562-a1e4-4bc3-a6f6-01a7adb643e8'  # Microsoft-Windows-FeatureConfiguration
KERNEL_PROCESS = '22fb2cd6-0e7b-422b-a0c7-2fad1fd0e716'
STAGES = {1007: 'alwaysDisabled', 1008: 'disabled', 1009: 'enabled', 1010: 'alwaysEnabled'}  # Event ID: the stage, as scan-symbols.py names them
BASELINE_SHARE = 0.4    # A feature checked while this share of a kind's targets were open is the kind's, not any one target's
BASELINE_MIN = 5        # Kinds with fewer targets than this have no baseline
SIGN_IN_MINUTES = 2     # Checks this long after Explorer started count as sign-in
KIND_NAMES = {'app': 'app', 'task': 'Control Panel'}


def when(s):
    return datetime.fromisoformat(re.sub(r'(\.\d{6})\d+', r'\1', s.strip()).replace('Z', '+00:00'))


def number(s):
    return int(s.strip(), 0)


def outcome(kind):
    """How a check came out, from its Kind (as Microsoft's StagingTool decodes it): 'on' or 'off', and the variant for variant checks."""
    if 0x100 <= kind <= 0x1FF:
        return ('on' if kind & 0x40 else 'off'), kind & 0x3F
    return ('on' if kind in (0, 1, 2, 3, 8, 9) or 100 <= kind <= 149 else 'off'), None


def read_csv(path):
    if not os.path.exists(path):
        return []
    with open(path, encoding='utf-8-sig', newline='') as f:
        return list(csv.DictReader(f))


def main():
    folder = sys.argv[1]
    run = json.load(open(os.path.join(folder, 'run.json'), encoding='utf-8-sig'))
    snapshot = {int(r['ProcessId']): (r['Name'], int(r['SessionId'] or -1), int(r['ParentProcessId'] or 0))
                for r in read_csv(os.path.join(folder, 'processes.csv'))}
    starts = defaultdict(list)   # Process ID: [(start time, image name, session, parent)], from the trace's process start events
    checks = []                  # (time, process ID, stage, feature ID, kind)
    other = 0
    for _, el in ET.iterparse(os.path.join(folder, 'events.xml')):
        if el.tag != NS + 'Event':
            continue
        system = el.find(NS + 'System')
        guid = (system.find(NS + 'Provider').get('Guid') or '').strip('{}').lower()
        eid = int(system.findtext(NS + 'EventID') or 0)
        data = {d.get('Name'): (d.text or '') for d in el.iter(NS + 'Data')}
        t = when(system.find(NS + 'TimeCreated').get('SystemTime'))
        if guid == PROVIDER and eid in STAGES and 'FeatureId' in data:
            checks.append((t, int(system.find(NS + 'Execution').get('ProcessID')), STAGES[eid], number(data['FeatureId']), number(data['Kind'])))
        elif guid == KERNEL_PROCESS and eid == 1 and 'ProcessID' in data:
            starts[number(data['ProcessID'])].append((t, (data.get('ImageName') or '').split('\\')[-1], number(data.get('SessionID') or '-1'),
                                                       number(data.get('ParentProcessID') or '0')))
        else:
            other += 1
        el.clear()
    checks.sort()

    def process(pid, t):
        """The image name, session and parent of the process with this ID at this time (IDs are reused)"""
        best = None
        for s in starts.get(pid, ()):
            if s[0] <= t + timedelta(seconds=1):
                best = s
        if best:
            return best[1:]
        return snapshot.get(pid, ('pid %d' % pid, -1, 0))

    targets = [r for r in read_csv(os.path.join(folder, 'targets.csv')) if r.get('kind') not in ('start', 'end')]
    ours = {int(r['target']) for r in read_csv(os.path.join(folder, 'targets.csv')) if r.get('kind') == 'start' and r['target'].isdigit()}
    session = run.get('session')
    signed_in = when(run['signedIn']) if run.get('signedIn') else None
    targets_started = when(run['targetsStarted']) if run.get('targetsStarted') else None

    def phase(t):
        if signed_in and t < signed_in:
            return 'boot'
        if signed_in and run.get('boot') and t < signed_in + timedelta(minutes=SIGN_IN_MINUTES):
            return 'signIn'
        if targets_started is None or t < targets_started:
            return 'idle'
        return 'targets'

    features = defaultdict(lambda: {'stages': Counter(), 'results': set(), 'variants': set(), 'processes': Counter(), 'phases': set()})
    for t, pid, stage, fid, kind in checks:
        name, _, _ = process(pid, t)
        f = features[fid]
        f['stages'][stage] += 1
        result, variant = outcome(kind)
        f['results'].add(result)
        if variant is not None:
            f['variants'].add(variant)
        f['processes'][name] += 1
        f['phases'].add(phase(t))

    # What each target's window checked, in the user's session, not counting trace-features.ps1's own process and its console
    times = [c[0] for c in checks]
    windows = []
    for r in targets:
        found = set()
        if r.get('opened'):
            a, b = when(r['opened']), when(r['closed'])
            for t, pid, stage, fid, kind in checks[bisect.bisect_left(times, a):bisect.bisect_right(times, b)]:
                name, sess, parent = process(pid, t)
                if pid in ours or (parent in ours and name.lower() == 'conhost.exe'):
                    continue
                if session is None or sess == session:
                    found.add(fid)
        windows.append(found)
    baseline = {}
    by_kind = defaultdict(list)
    for r, found in zip(targets, windows):
        if r.get('opened'):
            by_kind[r['kind']].append(found)
    for kind, sets in by_kind.items():
        if len(sets) >= BASELINE_MIN:
            counts = Counter(fid for s in sets for fid in s)
            baseline[kind] = {fid for fid, n in counts.items() if n >= BASELINE_SHARE * len(sets)}
    target_list = []
    for r, found in zip(targets, windows):
        own = sorted(found - baseline.get(r['kind'], set()))
        # How the site names the target: a page by its address, a folder by its name and address, others by name and kind
        label = r['label'] or r['target']
        if r['kind'] in ('settings', 'security'):
            label = r['target']
        elif r['kind'] == 'folder' and r['label'] and r['label'] not in r['target']:
            label = '%s (%s)' % (r['label'], r['target'])
        elif r['kind'] in KIND_NAMES:
            label = '%s (%s)' % (label, KIND_NAMES[r['kind']])
        entry = {'kind': r['kind'], 'label': label, 'target': r['target']}
        if r.get('opened'):
            entry['opened'] = r['opened']
        if r.get('error'):
            entry['error'] = r['error']
        entry['features'] = own
        target_list.append(entry)
        for fid in own:
            features[fid].setdefault('targets', []).append(label)

    summary_path = os.path.join(folder, 'tracerpt-summary.txt')
    lost = None
    if os.path.exists(summary_path):
        m = re.search(r'Total Events\s+Lost\s+(\d+)', open(summary_path, encoding='utf-8-sig', errors='replace').read())
        lost = int(m.group(1)) if m else None
    kinds = Counter(r['kind'] for r in targets)
    header = {
        'tracedAt': run.get('started'),
        'boot': bool(run.get('boot')),
        'minutes': round((checks[-1][0] - checks[0][0]).total_seconds() / 60) if checks else 0,
        'checks': len(checks),
        'eventsLost': lost,
        'buffersLost': run.get('buffersLost'),
        'features': len(features),
        'targets': {k: {'opened': sum(1 for r in targets if r['kind'] == k and r.get('opened') and not r.get('error')),
                        'failed': sum(1 for r in targets if r['kind'] == k and r.get('opened') and r.get('error')),
                        'notOpened': sum(1 for r in targets if r['kind'] == k and not r.get('opened'))} for k in kinds},
        'baselines': {k: len(v) for k, v in baseline.items()},
    }
    for k in ('user', 'error'):
        if run.get(k):
            header[k] = run[k]
    out = {}
    for fid in sorted(features):
        f = features[fid]
        entry = {'stage': f['stages'].most_common(1)[0][0], 'stages': sorted(f['stages']), 'results': sorted(f['results'])}
        if f['variants']:
            entry['variants'] = sorted(f['variants'])
        entry['processes'] = [p for p, _ in f['processes'].most_common() if not p.startswith('pid ')]  # (Not a process the trace didn't name)
        entry['phases'] = [p for p in ('boot', 'signIn', 'idle', 'targets') if p in f['phases']]
        if f.get('targets'):
            entry['targets'] = f['targets']
        out[str(fid)] = entry
    path = os.path.join(folder, 'trace.json')
    with open(path, 'w', encoding='utf-8', newline='\n') as fh:
        fh.write('{"run": %s,\n"features": {\n' % json.dumps(header))
        fh.write(',\n'.join('%s: %s' % (json.dumps(k), json.dumps(v, separators=(',', ':'))) for k, v in out.items()))
        fh.write('\n},\n"targets": [\n')
        fh.write(',\n'.join(json.dumps(t, separators=(',', ':')) for t in target_list))
        fh.write('\n]}\n')
    print('[trace] %d checks of %d features over %d min, %s events lost; %d targets (%s); wrote %s' % (
        len(checks), len(features), header['minutes'], lost, len(targets), ', '.join('%s %d' % kv for kv in sorted(kinds.items())), path))


if __name__ == '__main__':
    main()
