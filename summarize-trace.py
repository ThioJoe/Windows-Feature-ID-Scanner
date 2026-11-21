# summarize-trace.py
# Summarizes a feature trace (trace-features.ps1) into trace.json in the same folder:
#
#   python summarize-trace.py <folder>      # with events.xml (tracerpt's decoding), processes.csv, targets.csv and run.json
#
# For each feature checked: the stages its checks reported (the stage compiled into the binary that checked it), how they came out
# (on or off, and the variant for variant checks), the processes that checked it, the phases of the trace it was checked in, and the
# targets (pages, folders, apps, ...) it can be put down to. A target's checks are those made while it was open by processes in the
# signed-in user's session, other than trace-features.ps1's own and a GitHub runner's; checks that most targets of its kind make
# (such as File Explorer's for any folder), and those a program makes whenever it starts (such as Settings, which some Control Panel
# links open), are left out, so what's left is particular to it. The run's details (when, how long, events lost, the targets and
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
STARTUP_SECONDS = 10    # A process's checks this long after it started are its startup's
STARTUP_SHARE = 0.5     # A feature a program checks at startup in this share of its starts is the program's, not any one target's
STARTUP_MIN = 3         # Programs started fewer times than this have no startup baseline
SIGN_IN_MINUTES = 2     # Checks this long after Explorer started count as sign-in
KIND_NAMES = {'app': 'app', 'task': 'Control Panel'}
RUNNER = re.compile(r'^(hosted-compute-agent|provjobd|runner\.(listener|worker|provisioner))', re.I)  # A GitHub runner's own programs


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

    def instance(pid, t):
        """The process with this ID at this time (IDs are reused): its start time (None if it was running before the trace), image
        name, session and parent"""
        best = None
        for s in starts.get(pid, ()):
            if s[0] <= t + timedelta(seconds=1):
                best = s
        if best:
            return best
        return (None,) + snapshot.get(pid, ('pid %d' % pid, -1, 0))

    def process(pid, t):
        return instance(pid, t)[1:]

    # The GitHub runner's own processes and what they start, which run in the user's session there: its agent starts wsl.exe every
    # 30 seconds, and the workflow's steps run under Runner.Worker. What they check isn't what a target did.
    runner_cache = {}

    def from_runner(pid, t, depth=0):
        start, name, _, parent = instance(pid, t)
        key = (pid, start)
        if key not in runner_cache:
            runner_cache[key] = False  # (Reused process IDs could make a loop; it ends here)
            if RUNNER.match(name):
                runner_cache[key] = True
            elif parent and parent != pid and depth < 16:
                # The parent as it was when this process started, or for one running before the trace, as the snapshot has it
                runner_cache[key] = from_runner(parent, start, depth + 1) if start else from_snapshot(parent, depth + 1)
        return runner_cache[key]

    def from_snapshot(pid, depth):
        while pid and depth < 16:
            name, _, parent = snapshot.get(pid, ('', -1, 0))
            if RUNNER.match(name):
                return True
            if parent == pid:
                break
            pid, depth = parent, depth + 1
        return False

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

    # What programs check whenever they start (Settings, File Explorer's windows, Control Panel), whichever target started them: the
    # features a program checked in the first seconds after most of its starts
    started = defaultdict(set)   # (process ID, start time): what it checked at startup
    for t, pid, stage, fid, kind in checks:
        inst = instance(pid, t)
        if inst[0] is not None and (t - inst[0]).total_seconds() <= STARTUP_SECONDS:
            started[(pid, inst[0])].add(fid)
    runs = defaultdict(list)     # Image name: the startup checks of each of its starts in the trace
    for pid, start_list in starts.items():
        for st in start_list:
            runs[st[1].lower()].append(started.get((pid, st[0]), set()))
    startup = {}
    for name, sets in runs.items():
        if len(sets) >= STARTUP_MIN:
            counts = Counter(fid for x in sets for fid in x)
            startup[name] = {fid for fid, n in counts.items() if n >= STARTUP_SHARE * len(sets)}

    # What each target's window checked, in the user's session, not counting trace-features.ps1's own process and its console, the
    # runner's processes, or what a program checks whenever it starts
    times = [c[0] for c in checks]
    windows = []
    for r in targets:
        found = set()
        if r.get('opened'):
            a, b = when(r['opened']), when(r['closed'])
            for t, pid, stage, fid, kind in checks[bisect.bisect_left(times, a):bisect.bisect_right(times, b)]:
                name, sess, parent = process(pid, t)
                if (pid in ours or (parent in ours and name.lower() == 'conhost.exe') or fid in startup.get(name.lower(), ())
                        or from_runner(pid, t)):
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
        'startupBaselines': {k: len(v) for k, v in sorted(startup.items()) if v},
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
