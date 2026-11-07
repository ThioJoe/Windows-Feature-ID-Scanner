# check-windows-builds.py
# Finds the newest build of each Windows 11 version that Microsoft has released, from its official release information page,
# and whether data/ has it yet. A scan only needs to run when it doesn't.
#
#   python check-windows-builds.py --versions 26H2 --arch AMD64                     # prints the result as JSON
#   python check-windows-builds.py --versions 26H2 --arch AMD64 --github-output     # also writes `builds` (JSON) and `needed` to $GITHUB_OUTPUT
#   python check-windows-builds.py --versions 26H2 --arch AMD64 --all               # counts builds that are already in data/ as needed too
#
# A version's newest build counts whatever kind of update it came with: the monthly security update (B, the second week),
# the optional preview (D, the fourth week) or an out-of-band release (OOB). The preview is a different build from the next
# security update, so it gets scanned too.

import argparse
import html
import json
import os
import re
import sys
import urllib.request

RELEASE_INFO_URL = 'https://learn.microsoft.com/en-us/windows/release-health/windows11-release-information'


def version_tuple(build):
    return tuple(int(p) for p in build.split('.'))


def parse_release_history(page):
    """{version: [{'version', 'type', 'date', 'build', 'kb'}, ...] newest first} from the page's release history tables."""
    history = {}
    for m in re.finditer(r'<strong>Version (\w+) \(OS build (\d+)\)</strong>.*?<table[^>]*>(.*?)</table>', page, re.S):
        version, _base, table = m.groups()
        if version in history:
            continue  # The first table after a version's heading is its release history
        rows = []
        for row in re.findall(r'<tr>(.*?)</tr>', table, re.S):
            cells = [html.unescape(re.sub(r'<[^>]+>', '', c)).strip() for c in re.findall(r'<td[^>]*>(.*?)</td>', row, re.S)]
            if len(cells) >= 5 and re.match(r'^\d+\.\d+$', cells[3]):
                # The version's first release has no update type or KB
                rows.append({'version': version, 'type': cells[1] or 'release', 'date': cells[2], 'build': cells[3],
                             'kb': cells[4] if re.match(r'^KB\d+$', cells[4]) else None})
        rows.sort(key=lambda r: version_tuple(r['build']), reverse=True)
        history[version] = rows
    return history


def main():
    parser = argparse.ArgumentParser(description="Find Windows 11's newest released builds and whether data/ has them yet.")
    parser.add_argument('--versions', nargs='+', required=True, help='Windows 11 versions to check, such as 26H2 25H2')
    parser.add_argument('--arch', required=True, help='Architecture the builds would be scanned for, as in data/builds file names (AMD64, ARM64)')
    parser.add_argument('--data-dir', default='data')
    parser.add_argument('--page-file', help='Read the release information page from this file instead of downloading it')
    parser.add_argument('--github-output', action='store_true', help='Write `builds` and `needed` to the file named by $GITHUB_OUTPUT')
    parser.add_argument('--all', action='store_true', help='Count every build as needed, even if data/ has it (to scan it again)')
    args = parser.parse_args()

    if args.page_file:
        with open(args.page_file, 'r', encoding='utf-8') as f:
            page = f.read()
    else:
        req = urllib.request.Request(RELEASE_INFO_URL, headers={'User-Agent': 'Windows-Feature-ID-Scanner'})
        with urllib.request.urlopen(req, timeout=60) as resp:
            page = resp.read().decode('utf-8', 'replace')
    history = parse_release_history(page)

    builds = []
    for version in args.versions:
        rows = history.get(version)
        if not rows:
            print('[check] %s is not on the release information page' % version, file=sys.stderr)
            return 1
        newest = dict(rows[0])
        newest['key'] = '%s-%s' % (newest['build'], args.arch)
        newest['scanned'] = os.path.exists(os.path.join(args.data_dir, 'builds', newest['key'] + '.json'))
        builds.append(newest)
        print('[check] %s: newest build %s (%s, %s, %s) %s' % (
            version, newest['build'], newest['type'], newest['date'], newest['kb'] or 'no KB', 'already in data/' if newest['scanned'] else 'NOT in data/ yet'), file=sys.stderr)

    needed = [b for b in builds if args.all or not b['scanned']]
    print(json.dumps(builds, indent=1))
    if args.github_output:
        with open(os.environ['GITHUB_OUTPUT'], 'a', encoding='utf-8') as f:
            f.write('builds=%s\n' % json.dumps(needed, separators=(',', ':')))
            f.write('needed=%s\n' % ('true' if needed else 'false'))
    return 0


if __name__ == '__main__':
    sys.exit(main())
