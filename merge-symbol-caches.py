#!/usr/bin/env python3
# merge-symbol-caches.py
# Merges the symbol caches of builds scanned in parallel (each on its own runner) into one cache file for data/.
#
# Every scan starts from the same cache and writes all of it back with what it found added (scan-symbols.py --results-cache), so
# the merge is the union of the scans' caches. A PDB that more than one scan has is the same file with the same result; the entry
# kept is the one that still has its usage details (scan-symbols.py keeps those only for the PDBs of its own scan), else the most
# recently scanned or checked. The cache already in data/ isn't read: every scan's copy contains all of it. Usage details are only
# kept for the PDBs of the newest build of each version among the scans, as for a single scan, so that scanning many builds at once
# doesn't make the file too big for GitHub (100 MB).
#
#   python merge-symbol-caches.py --out data/symbol-cache-AMD64.json caches/*/symbol-cache-AMD64.json

import argparse
import json
import os
import re
import sys


def load(path):
    with open(path, 'r', encoding='utf-8') as f:
        cache = json.load(f)
    return cache.get('version'), cache.get('pdbs', {})


def preference(entry):
    # A result over a 404, an entry with usage details over one without, then the latest
    return (entry.get('status') == 'ok', 'usage' in entry or 'usageError' in entry, entry.get('scanned') or entry.get('checked') or '')


def main():
    parser = argparse.ArgumentParser(description='Merge symbol caches written by scans run in parallel.')
    parser.add_argument('--out', required=True, help='The merged cache to write')
    parser.add_argument('caches', nargs='+', help="The scans' caches")
    args = parser.parse_args()

    version, merged = None, {}
    builds, usage_of = {}, {}
    for path in args.caches:
        v, pdbs = load(path)
        if version is None:
            version = v
        elif v != version:
            print('[cache] %s is version %s, not %s; leaving it out' % (path, v, version))
            continue
        # The scan's build, from the folder of its artifact (symbol-cache-<build>-<arch>), and the PDBs it kept usage details for
        m = re.search(r'symbol-cache-(\d+)\.(\d+)-', path)
        if m:
            builds[path] = (int(m.group(1)), int(m.group(2)))
        usage_of[path] = {k for k, e in pdbs.items() if 'usage' in e or 'usageError' in e}
        added = 0
        for key, entry in pdbs.items():
            if key not in merged:
                added += 1
                merged[key] = entry
            elif preference(entry) > preference(merged[key]):
                merged[key] = entry
        print('[cache] %s: %d PDBs, %d not in the caches before it' % (path, len(pdbs), added))

    # Usage details are kept for the PDBs of the newest scanned build of each version, which the next scan of the version most likely
    # shares, and dropped for the others' as a single scan drops them, so the cache doesn't grow with the number of builds scanned at once
    newest = {}
    for path, (base, ubr) in builds.items():
        if base not in newest or ubr > builds[newest[base]][1]:
            newest[base] = path
    keep = set().union(*(usage_of[p] for p in set(newest.values()) | (set(usage_of) - set(builds))))
    stripped = 0
    for key, entry in merged.items():
        if key not in keep and ('usage' in entry or 'usageError' in entry):
            merged[key] = {x: y for x, y in entry.items() if x not in ('usage', 'usageError')}
            stripped += 1
    if stripped:
        print('[cache] usage details kept for the PDBs of %s; dropped for %d others' % (', '.join(sorted(os.path.basename(os.path.dirname(p)) for p in newest.values())), stripped))

    # The same layout as scan-symbols.py writes: one PDB per line, so git diffs stay small
    with open(args.out, 'w', encoding='utf-8', newline='\n') as f:
        f.write('{"version": %d, "pdbs": {\n' % version)
        f.write(',\n'.join('%s: %s' % (json.dumps(k), json.dumps(merged[k], separators=(',', ':'))) for k in sorted(merged)))
        f.write('\n}}\n')
    print('[cache] wrote %s: %d PDBs' % (args.out, len(merged)))
    return 0


if __name__ == '__main__':
    sys.exit(main())
