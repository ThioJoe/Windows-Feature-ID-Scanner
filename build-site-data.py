# build-site-data.py
# Derives the files the site loads from data/, when the site is published (pages.yml). They aren't kept in the repository: data/ holds
# each build's data in its own folder, and these only rearrange it so the site can load what it shows quickly.
#
#   <out>/details/<arch>/<nn>.json   For each feature ID, its code details (from the builds' details.json) from the newest build of the
#                                    architecture that has them, with that build's key. Split by feature ID (ID % 64), so that showing a
#                                    feature only downloads the file it's in rather than all of a build's details.
#
#   <out>/super-god-mode.json        The builds that have Super God Mode statistics (their super-god-mode/ folder), with the version,
#                                    user and any error from its run.json.
#   <out>/super-god-mode/<build>.json The statistics of each of those builds: the columns and rows of each of its CSV files, so that
#                                    comparing two builds loads two files.
#
#   python build-site-data.py --data data --out _site/derived

import argparse
import csv
import json
import os
import sys

SHARDS = 64


def version_tuple(build):
    return tuple(int(p) for p in build.split('.'))


def super_god_mode(builds_dir, out):
    found = {}
    for key in sorted(os.listdir(builds_dir)) if os.path.isdir(builds_dir) else []:
        folder = os.path.join(builds_dir, key, 'super-god-mode')
        if not os.path.exists(os.path.join(folder, 'run.json')):
            continue
        with open(os.path.join(folder, 'run.json'), encoding='utf-8-sig') as f:
            run = json.load(f)
        tables = {}
        for name in sorted(os.listdir(folder)):
            if name.lower().endswith('.csv'):
                with open(os.path.join(folder, name), encoding='utf-8-sig', newline='') as f:
                    rows = [r for r in csv.reader(f) if any(r)]
                if rows:
                    tables[name[:-4]] = {'columns': [c.strip() for c in rows[0]], 'rows': rows[1:]}
        found[key] = {k: run[k] for k in ('version', 'user', 'error') if run.get(k)}
        if tables:
            os.makedirs(os.path.join(out, 'super-god-mode'), exist_ok=True)
            with open(os.path.join(out, 'super-god-mode', key + '.json'), 'w', encoding='utf-8', newline='\n') as f:
                json.dump({'build': key, 'tables': tables}, f, ensure_ascii=False, separators=(',', ':'))
        else:
            found[key]['empty'] = True
    with open(os.path.join(out, 'super-god-mode.json'), 'w', encoding='utf-8', newline='\n') as f:
        json.dump(found, f, indent=1)
    print('[site] Super God Mode statistics of %d builds: %s' % (len(found), ', '.join(found) or 'none'))


def main():
    parser = argparse.ArgumentParser(description='Derive the files the site loads from data/.')
    parser.add_argument('--data', default='data')
    parser.add_argument('--out', required=True, help='Folder for the derived files, which the site loads from derived/')
    args = parser.parse_args()

    builds_dir = os.path.join(args.data, 'builds')
    keys = [name for name in os.listdir(builds_dir) if os.path.exists(os.path.join(builds_dir, name, 'details.json'))] if os.path.isdir(builds_dir) else []
    newest = {}  # arch -> feature ID -> (build key, details)
    for key in sorted(keys, key=lambda k: version_tuple(k.rsplit('-', 1)[0])):  # Newer builds replace older ones
        arch = key.rsplit('-', 1)[1]
        with open(os.path.join(builds_dir, key, 'details.json'), encoding='utf-8') as f:
            for fid, usage in json.load(f).items():
                newest.setdefault(arch, {})[int(fid)] = (key, usage)

    for arch, features in sorted(newest.items()):
        out_dir = os.path.join(args.out, 'details', arch)
        os.makedirs(out_dir, exist_ok=True)
        for n in range(SHARDS):
            lines = ['%s: %s' % (json.dumps(str(fid)), json.dumps({'build': features[fid][0], 'usage': features[fid][1]}, separators=(',', ':')))
                     for fid in sorted(features) if fid % SHARDS == n]
            with open(os.path.join(out_dir, '%02d.json' % n), 'w', encoding='utf-8', newline='\n') as f:
                f.write('{\n' + ',\n'.join(lines) + '\n}\n' if lines else '{}\n')
        builds = sorted({key for key, _ in features.values()})
        print('[site] %s: code details of %d features, from %s' % (arch, len(features), ', '.join(builds)))
    os.makedirs(args.out, exist_ok=True)
    super_god_mode(builds_dir, args.out)
    return 0


if __name__ == '__main__':
    sys.exit(main())
