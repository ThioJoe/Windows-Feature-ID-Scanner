#!/usr/bin/env python3
# merge-symbol-caches.py
# Merges the symbol caches of builds scanned in parallel (each on its own runner) into one cache file for data/.
#
# Every scan starts from the same cache and writes all of it back with what it found added (scan-symbols.py --results-cache), so
# the merge is the union of the scans' caches. A PDB that more than one scan has is the same file with the same result; the entry
# kept is the one that still has its usage details (scan-symbols.py keeps those only for the PDBs of its own scan), else the most
# recently scanned or checked. The cache already in data/ isn't read: every scan's copy contains all of it.
#
#   python merge-symbol-caches.py --out data/symbol-cache-AMD64.json caches/*/symbol-cache-AMD64.json

import argparse
import json
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
    for path in args.caches:
        v, pdbs = load(path)
        if version is None:
            version = v
        elif v != version:
            print('[cache] %s is version %s, not %s; leaving it out' % (path, v, version))
            continue
        added = 0
        for key, entry in pdbs.items():
            if key not in merged:
                added += 1
                merged[key] = entry
            elif preference(entry) > preference(merged[key]):
                merged[key] = entry
        print('[cache] %s: %d PDBs, %d not in the caches before it' % (path, len(pdbs), added))

    # The same layout as scan-symbols.py writes: one PDB per line, so git diffs stay small
    with open(args.out, 'w', encoding='utf-8', newline='\n') as f:
        f.write('{"version": %d, "pdbs": {\n' % version)
        f.write(',\n'.join('%s: %s' % (json.dumps(k), json.dumps(merged[k], separators=(',', ':'))) for k in sorted(merged)))
        f.write('\n}}\n')
    print('[cache] wrote %s: %d PDBs' % (args.out, len(merged)))
    return 0


if __name__ == '__main__':
    sys.exit(main())
