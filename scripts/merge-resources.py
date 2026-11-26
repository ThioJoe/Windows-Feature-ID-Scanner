# merge-resources.py
# Adds the scans' resource data (scan-resources.py's output folders) to a work tree of the assets branch, and records in data/ which
# builds have it (data/builds/<build>/resources.json, which update-data.py lists in data/index.json for the site). Used by the VM
# scanner's commit job, which then commits the added paths to the assets branch and pushes it before data/.
#
#   python scripts/merge-resources.py --assets <work tree> --known known.txt --added added.txt --data-dir data <scan output>...
#     --known   the paths the assets branch has (git ls-tree -r --name-only), which aren't copied again
#     --added   where the list of paths copied goes (for git add --pathspec-from-file)
#
# Everything in the branch is named by its content's hash, except each build's own files (builds/<build>/), which a new scan of the
# build replaces.

import argparse
import datetime
import json
import os
import shutil
import sys


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--assets', required=True)
    parser.add_argument('--known', required=True)
    parser.add_argument('--added', required=True)
    parser.add_argument('--data-dir', default='data')
    parser.add_argument('outputs', nargs='+')
    args = parser.parse_args()

    with open(args.known, encoding='utf-8-sig') as f:
        known = {line.strip() for line in f if line.strip()}
    added, added_set = [], set()
    now = datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
    for out in args.outputs:
        summary_path = os.path.join(out, 'summary.json')
        if not os.path.exists(summary_path):
            print('[resources] %s has no summary.json; skipped' % out)
            continue
        with open(summary_path, encoding='utf-8-sig') as f:
            summary = json.load(f)
        key = summary['build']
        assets = os.path.join(out, 'assets')
        copied = 0
        for folder, _, names in os.walk(assets):
            for name in names:
                if name.endswith('.tmp'):
                    continue
                source = os.path.join(folder, name)
                rel = os.path.relpath(source, assets).replace(os.sep, '/')
                own = rel.startswith('builds/')
                if not own and (rel in known or rel in added_set):
                    continue
                target = os.path.join(args.assets, *rel.split('/'))
                os.makedirs(os.path.dirname(target), exist_ok=True)
                shutil.copyfile(source, target)
                if rel not in added_set:
                    added.append(rel)
                    added_set.add(rel)
                copied += 1
        build_dir = os.path.join(args.data_dir, 'builds', key)
        if not os.path.isdir(build_dir):
            print('[resources] %s isn\'t in data/; its resource data is in the branch but not listed' % key)
        else:
            record = {'scannedAt': now, 'files': summary['files'], 'fileVersions': summary['fileVersions'], 'listed': summary['listed'],
                      'errors': summary['errorCount'], 'new': summary['new']}
            with open(os.path.join(build_dir, 'resources.json'), 'w', encoding='utf-8', newline='\n') as f:
                json.dump(record, f, indent=1, sort_keys=True)
                f.write('\n')
        print('[resources] %s: %d files read (%d errors), %d paths added to the branch' % (key, summary['files'], summary['errorCount'], copied))
    with open(args.added, 'w', encoding='utf-8', newline='\n') as f:
        f.write(''.join(p + '\n' for p in sorted(added)))
    print('[resources] %d paths added in all' % len(added))
    return 0


if __name__ == '__main__':
    sys.exit(main())
