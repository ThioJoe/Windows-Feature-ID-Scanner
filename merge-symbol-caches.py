#!/usr/bin/env python3
# merge-symbol-caches.py
# Merges the symbol caches of builds scanned in parallel (each on its own runner) into one cache file for data/.
#
# Every scan starts from the same cache and writes all of it back with what it found added (scan-symbols.py --results-cache), so
# the merge is the union of the scans' caches. A PDB that more than one scan has is the same file with the same result; the entry
# kept is the one that still has its usage details (scan-symbols.py keeps those only for the PDBs of its own scan), else the most
# recently scanned or checked. The cache already in data/ isn't read: every scan's copy contains all of it. Usage details are only
# kept for the PDBs of the newest build of each version among the scans, as for a single scan, so that scanning many builds at once
# doesn't make the file too big for GitHub (100 MB), and only as far as the file stays under LIMIT: an Insider build's PDBs are
# its own, so the details of several Insider builds can be too much together. The builds with the lowest base build numbers (the
# released versions, then the Insider channels' cores) keep theirs first.
#
#   python merge-symbol-caches.py --out data/symbol-cache-AMD64.json caches/*/symbol-cache-AMD64.json

import argparse
import json
import os
import re
import sys

LIMIT = 90 * 1000 * 1000  # Bytes: GitHub refuses a file over 100 MB


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
    # Each PDB's line in the file without and with its usage details: the details are added build by build while the file stays under
    # LIMIT (those of a cache that doesn't name its build first)
    line = lambda key, entry: len(json.dumps(key)) + len(json.dumps(entry, separators=(',', ':'))) + 4
    plain = {k: {x: y for x, y in e.items() if x not in ('usage', 'usageError')} for k, e in merged.items()}
    total = sum(line(k, e) for k, e in plain.items())
    keep, kept, left_out = set(), [], []
    for path in [p for p in usage_of if p not in builds] + [newest[b] for b in sorted(newest)]:
        more = usage_of[path] - keep
        add = sum(line(k, merged[k]) - line(k, plain[k]) for k in more)
        if total + add > LIMIT:
            left_out.append(path)
            continue
        keep |= more
        total += add
        kept.append(path)
    stripped = 0
    for key, entry in merged.items():
        if key not in keep and ('usage' in entry or 'usageError' in entry):
            merged[key] = plain[key]
            stripped += 1
    name = lambda p: os.path.basename(os.path.dirname(p)) or p
    if stripped:
        print('[cache] usage details kept for the PDBs of %s; dropped for %d others' % (', '.join(sorted(name(p) for p in kept if p in builds)) or 'none', stripped))
    for path in left_out:
        print('[cache] usage details of %s left out: the file would be over %d MB with them' % (name(path), LIMIT // 1000000))

    # The same layout as scan-symbols.py writes: one PDB per line, so git diffs stay small
    with open(args.out, 'w', encoding='utf-8', newline='\n') as f:
        f.write('{"version": %d, "pdbs": {\n' % version)
        f.write(',\n'.join('%s: %s' % (json.dumps(k), json.dumps(merged[k], separators=(',', ':'))) for k in sorted(merged)))
        f.write('\n}}\n')
    print('[cache] wrote %s: %d PDBs' % (args.out, len(merged)))
    return 0


if __name__ == '__main__':
    sys.exit(main())
