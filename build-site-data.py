# build-site-data.py
# Derives the files the site loads from data/, when the site is published (pages.yml). They aren't kept in the repository: data/ holds
# each build's data in its own files, and these only rearrange it so the site can load what it shows quickly.
#
#   <out>/details/<arch>/<nn>.json   For each feature ID, its code details (from data/details/) from the newest build of the architecture
#                                    that has them, with that build's key. Split by feature ID (ID % 64), so that showing a feature only
#                                    downloads the file it's in rather than all of a build's details.
#
#   python build-site-data.py --data data --out _site/derived

import argparse
import json
import os
import sys

SHARDS = 64


def version_tuple(build):
    return tuple(int(p) for p in build.split('.'))


def main():
    parser = argparse.ArgumentParser(description='Derive the files the site loads from data/.')
    parser.add_argument('--data', default='data')
    parser.add_argument('--out', required=True, help='Folder for the derived files, which the site loads from derived/')
    args = parser.parse_args()

    details_dir = os.path.join(args.data, 'details')
    keys = [fn[:-5] for fn in os.listdir(details_dir) if fn.endswith('.json')] if os.path.isdir(details_dir) else []
    newest = {}  # arch -> feature ID -> (build key, details)
    for key in sorted(keys, key=lambda k: version_tuple(k.rsplit('-', 1)[0])):  # Newer builds replace older ones
        arch = key.rsplit('-', 1)[1]
        with open(os.path.join(details_dir, key + '.json'), encoding='utf-8') as f:
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
    return 0


if __name__ == '__main__':
    sys.exit(main())
