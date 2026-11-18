#!/usr/bin/env python3
# catch-up-symbols.py
# Completes builds whose scan didn't get every binary's symbols. Microsoft can publish an update's symbols days after the update (those of
# KB5132061 came three days after its release), so a scan that runs early gets 404s for the PDBs of the binaries the update changed. The
# scan then keeps what earlier versions of those binaries contained (marked unverified), and data/builds/<build>/symbols.json lists the
# PDBs it didn't get, with what's needed to download their binaries from the symbol server (see scan-symbols.py and update-data.py).
#
#   python catch-up-symbols.py check [--github-output] [--summary FILE]
#       Asks the symbol server for each build's pending PDBs and their binaries, until the build's checkUntil (CHECK_DAYS after its
#       release, see update-data.py), and lists the builds it has some of now. Only needs Python, so it runs on any runner.
#
#   python catch-up-symbols.py run --builds KEY [KEY ...] [--github-output] [--summary FILE]
#       Scans those builds' PDBs again with scan-symbols.py --manifest, which takes what the results cache has for the PDBs the scan
#       got and downloads the others with their binaries (checked against the SHA-256 the scan recorded), so no VM is needed. The result
#       goes into data/ with update-data.py, which keeps the build's feature store data and Super God Mode statistics, and the code
#       details of binaries it has no new ones for. Runs on Windows, where scan-symbols.py demangles names and expands compressed
#       files the same way as in the scans.

import argparse
import concurrent.futures
import datetime
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
SERVER = 'https://msdl.microsoft.com/download/symbols'
USER_AGENT = 'Microsoft-Symbol-Server/10.0.0.0'

spec = importlib.util.spec_from_file_location('update_data', os.path.join(HERE, 'update-data.py'))
update_data = importlib.util.module_from_spec(spec)
spec.loader.exec_module(update_data)


def load_json(path):
    with open(path, 'r', encoding='utf-8-sig') as f:
        return json.load(f)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None  # The redirect itself is the answer: the symbol server sends one to the file's storage when it has the file


OPENER = urllib.request.build_opener(NoRedirect)


def on_server(name, key):
    """Whether the symbol server has name/key/name, also in the CAB-compressed form (name ending in _) scan-symbols.py falls back to."""
    for file in (name, name[:-1] + '_'):
        request = urllib.request.Request('%s/%s/%s/%s' % (SERVER, file, key, file), method='HEAD', headers={'User-Agent': USER_AGENT})
        for attempt in range(3):
            try:
                with OPENER.open(request, timeout=30) as response:
                    if response.status == 200:
                        return True
                break
            except urllib.error.HTTPError as e:
                if e.code in (301, 302, 303, 307, 308):
                    return True
                if e.code == 404:
                    break
                if attempt == 2:
                    raise
            except OSError:
                if attempt == 2:
                    raise
    return False


def binary_key(file):
    return '%08X%x' % (file['timestamp'], file['imageSize'])


def pending_builds(data_dir, today):
    """(key, symbols.json, its pending PDBs) for each build that has some and is still checked, and the keys of those that aren't."""
    checked, stopped = [], []
    builds_dir = os.path.join(data_dir, 'builds')
    for key in sorted(os.listdir(builds_dir)):
        path = os.path.join(builds_dir, key, 'symbols.json')
        if not os.path.exists(path):
            continue
        doc = load_json(path)
        pending = {k: v for k, v in doc['pdbs'].items() if v.get('pending')}
        if not pending:
            continue
        if doc.get('checkUntil') and today > doc['checkUntil']:
            stopped.append(key)
        else:
            checked.append((key, doc, pending))
    return checked, stopped


def check(args):
    today = datetime.date.today().isoformat()
    builds, stopped = pending_builds(args.data_dir, today)
    # One question per PDB and binary, though builds that share binaries list the same ones
    questions = {}
    for _, _, pending in builds:
        for cache_key, entry in pending.items():
            questions[('pdb', cache_key)] = (entry.get('pdbName') or cache_key.split('/')[0], cache_key.split('/', 1)[1])
            for file in entry.get('files', []):
                questions[('binary', file['name'], binary_key(file))] = (file['name'], binary_key(file))
    answers, failed = {}, 0
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        futures = {pool.submit(on_server, *q): k for k, q in questions.items()}
        for future in concurrent.futures.as_completed(futures):
            try:
                answers[futures[future]] = future.result()
            except Exception as e:
                answers[futures[future]] = False
                failed += 1
                print('[check] %s: %s' % ('/'.join(futures[future][1:]), e))

    ready, rows = [], []
    for key, doc, pending in builds:
        there = [k for k, e in pending.items() if answers.get(('pdb', k))
                 and any(answers.get(('binary', f['name'], binary_key(f))) for f in e.get('files', []))]
        likely = sum(1 for e in pending.values() if e.get('fallbackFeatures'))
        rows.append((key, len(pending), likely, len(there), doc.get('checkUntil')))
        print('[check] %s: %d PDBs pending (%d of binaries that had features), %d on the symbol server now with their binaries, checked until %s' % rows[-1])
        if there:
            ready.append(key)
    for key in stopped:
        print('[check] %s: past its checkUntil, no longer checked' % key)
    if failed:
        print('[check] %d questions to the symbol server failed; those PDBs are asked for again next time' % failed)

    if args.summary:
        with open(args.summary, 'a', encoding='utf-8') as f:
            f.write('## Symbols the scans didn\'t get\n\n')
            if rows:
                f.write('| Build | Pending PDBs | Of binaries that had features | On the symbol server now | Checked until |\n|---|---|---|---|---|\n')
                f.write(''.join('| %s | %d | %d | %d | %s |\n' % r for r in rows))
            else:
                f.write('No build has PDBs pending.\n')
            f.write('\n')
    if args.github_output:
        with open(os.environ['GITHUB_OUTPUT'], 'a', encoding='utf-8') as f:
            f.write('builds=%s\nneeded=%s\n' % (' '.join(ready), 'true' if ready else 'false'))
    return 0


def summary_from_build(build):
    """The scan summary (scan-features.ps1's summary.json) a build in data/ was added from, as far as update-data.py uses it: the build,
    and the feature store's configurations with ViVeTool's names."""
    summary = {'fullBuild': build['build'], 'architecture': build['architecture'], 'productName': build.get('productName'),
               'displayVersion': build.get('displayVersion'), 'timestamp': build.get('scannedAt')}
    for k in ('notes', 'insiderChannel'):
        if build.get(k):
            summary[k] = build[k]
    summary['features'] = [{'id': f['id'], 'name': f.get('viveToolName') or (f['name'] if f.get('nameSource') == 'vivetool' else None),
                            'configurations': [{src: c[out] for src, out in update_data.STORE_FIELDS if out in c} for c in f['store']]}
                           for f in build['features'] if 'store' in f]
    return summary


def run(args):
    today = datetime.date.today().isoformat()
    completed, rows = [], []
    for key in args.builds:
        folder = os.path.join(args.data_dir, 'builds', key)
        before = load_json(os.path.join(folder, 'features.json'))
        doc = load_json(os.path.join(folder, 'symbols.json'))
        cache = os.path.join(args.data_dir, 'symbol-cache-AMD64.json' if before['architecture'] == 'AMD64' else 'symbol-cache.json')
        with tempfile.TemporaryDirectory(prefix='catch-up-') as tmp:
            out = os.path.join(tmp, 'symbol-features.json')
            print('[run] %s: scanning its PDBs again' % key, flush=True)
            subprocess.run([sys.executable, os.path.join(HERE, 'scan-symbols.py'), '--manifest', os.path.join(folder, 'symbols.json'),
                            '--results-cache', cache, '--names-out', os.path.join(tmp, 'names.txt'), '--json-out', out], check=True)
            symbols = load_json(out)
            now = symbols['manifest']['pdbs']  # (Leaves out PDBs without features, so one that isn't listed now was read)
            resolved = [k for k, e in doc['pdbs'].items() if e.get('pending') and not now.get(k, {}).get('pending')]
            if not resolved:
                print('[run] %s: none of its pending PDBs could be scanned' % key)
                continue
            # The scan's statistics, with the PDBs it got now counted as downloaded
            stats = dict(before.get('symbolStats') or {})
            for k in resolved:
                e = doc['pdbs'][k]
                if e['pending'] != 'details':  # (Those were counted as cached)
                    bucket = 'previousVersion' if e.get('fallback') else e['pending']
                    stats[bucket] = max(0, stats.get(bucket, 0) - 1)
                    stats['downloaded'] = stats.get('downloaded', 0) + 1
            symbols['stats'] = stats
            symbols['symbolsUpdated'] = today
            symbols['componentStore'] = before.get('componentStore')  # (Only a scan on the machine finds those)
            with open(out, 'w', encoding='utf-8') as f:
                json.dump(symbols, f)
            summary = os.path.join(tmp, 'summary.json')
            with open(summary, 'w', encoding='utf-8') as f:
                json.dump(summary_from_build(before), f)
            subprocess.run([sys.executable, os.path.join(HERE, 'update-data.py'), '--data-dir', args.data_dir, '--summary', summary, '--symbols', out], check=True)
        after = load_json(os.path.join(folder, 'features.json'))
        count = lambda b, test: sum(1 for f in b['features'] if test(f))
        row = (key, len(resolved), len(before['features']), len(after['features']), count(before, lambda f: f['name']), count(after, lambda f: f['name']),
               count(before, lambda f: f.get('unverified')), count(after, lambda f: f.get('unverified')),
               count(before, lambda f: f['modules']), count(after, lambda f: f['modules']))
        rows.append(row)
        completed.append(key)
        print('[run] %s: %d PDBs added; features %d -> %d, named %d -> %d, unverified %d -> %d, with modules %d -> %d' % row)

    if args.summary:
        with open(args.summary, 'a', encoding='utf-8') as f:
            f.write('## Builds completed\n\n')
            if rows:
                f.write('| Build | PDBs added | Features | Named | Unverified | With modules |\n|---|---|---|---|---|---|\n')
                f.write(''.join('| %s | %d | %d → %d | %d → %d | %d → %d | %d → %d |\n' % r for r in rows))
            else:
                f.write('None: the PDBs the check found couldn\'t be scanned.\n')
            f.write('\n')
    if args.github_output:
        message = 'Complete the symbol data of build%s %s' % ('s' if len(completed) > 1 else '', ', '.join(completed))
        with open(os.environ['GITHUB_OUTPUT'], 'a', encoding='utf-8') as f:
            f.write('completed=%s\nmessage=%s\n' % (' '.join(completed), message))
    return 0


def main():
    parser = argparse.ArgumentParser(description="Complete builds whose scan didn't get every binary's symbols.")
    parser.add_argument('--data-dir', default=os.path.join(HERE, 'data'))
    sub = parser.add_subparsers(dest='command', required=True)
    p = sub.add_parser('check', help='List the builds the symbol server has some of the missing PDBs of now')
    p.add_argument('--github-output', action='store_true', help='Write builds (space-separated) and needed to $GITHUB_OUTPUT')
    p.add_argument('--summary', help='Markdown file to append a summary to (the run summary)')
    p = sub.add_parser('run', help="Scan those builds' PDBs again and add the result to data/")
    p.add_argument('--builds', nargs='+', required=True)
    p.add_argument('--github-output', action='store_true', help='Write completed and a commit message to $GITHUB_OUTPUT')
    p.add_argument('--summary', help='Markdown file to append a summary to (the run summary)')
    args = parser.parse_args()
    return check(args) if args.command == 'check' else run(args)


if __name__ == '__main__':
    sys.exit(main())
