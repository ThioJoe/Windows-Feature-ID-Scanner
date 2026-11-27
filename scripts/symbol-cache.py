#!/usr/bin/env python3
# symbol-cache.py
# Keeps the symbol caches (data/symbol-cache-AMD64.json for the x64 scans, data/symbol-cache.json for the ARM64 ones: what each PDB
# contained, see scan-symbols.py) on the repository's cache branch instead of in data/, so that they don't add to main's history with
# every scan. The branch has a folder for each branch the scans run on (main/, and others' for test runs, so that a test can't change
# the cache main's scans use), with each cache split into SHARDS files by a hash of each PDB's key, so that no file comes near GitHub's
# limits (a warning over 50 MiB, refused over 100 MiB). The files are the caches' own format, one PDB per line, sorted, which git stores
# as small changes from one version to the next. The branch keeps its newest KEEP commits: each change replaces the branch with them,
# the oldest left out, so that what's there before a change can't be lost to one change that goes wrong.
#
#   python scripts/symbol-cache.py get --branch BRANCH [--data-dir data]
#       Puts the branch's caches in data/: from its folder on the cache branch, else from main's (a test run's first), else it leaves
#       those in data/ (the files main had before the cache branch).
#   python scripts/symbol-cache.py put --branch BRANCH --message MESSAGE [--forget] [--data-dir data]
#       Stores the caches in data/ in the branch's folder on the cache branch (those data/ doesn't have stay as they are there). With
#       --forget, then removes them from git's index, for the branches that still have them in data/ from before the cache branch.
#   python scripts/symbol-cache.py fold --from BRANCH [--data-dir data]
#       When BRANCH is merged into main: main's caches with what BRANCH's have added (merge-symbol-caches.py, which leaves out the PDBs
#       the builds in data/ don't need), in main's folder, and BRANCH's folder removed.

import argparse
import json
import os
import subprocess
import sys
import tempfile
import zlib

REF = 'refs/heads/cache'
REMOTE_REF = 'refs/remotes/origin/cache'
CACHES = ('symbol-cache-AMD64', 'symbol-cache')
SHARDS = 8
KEEP = 3
HERE = os.path.dirname(os.path.abspath(__file__))
BOT = {'GIT_AUTHOR_NAME': 'github-actions[bot]', 'GIT_AUTHOR_EMAIL': '41898282+github-actions[bot]@users.noreply.github.com',
       'GIT_COMMITTER_NAME': 'github-actions[bot]', 'GIT_COMMITTER_EMAIL': '41898282+github-actions[bot]@users.noreply.github.com'}


def git(*args, input=None, env=None, check=True):
    r = subprocess.run(['git'] + list(args), input=input, capture_output=True, env=dict(os.environ, **(env or {})))
    if check and r.returncode:
        raise SystemExit('git %s failed: %s' % (' '.join(args), r.stderr.decode('utf-8', 'replace').strip()))
    return r


def fetch():
    """The cache branch's newest commit (its newest KEEP, fetched), or None if there's no branch yet"""
    r = git('fetch', '-q', '--depth=%d' % KEEP, 'origin', '+%s:%s' % (REF, REMOTE_REF), check=False)
    if r.returncode:
        if git('ls-remote', '--exit-code', '--heads', 'origin', 'cache', check=False).returncode == 2:
            return None  # (No branch yet)
        raise SystemExit('Fetching the cache branch failed: %s' % r.stderr.decode('utf-8', 'replace').strip())
    return git('rev-parse', REMOTE_REF).stdout.decode().strip()


def folder(branch, name):
    return '%s/%s' % (branch, name)


def read_cache(tip, branch, name):
    """{key: entry line} and the cache's version from the branch's folder, or None if it has none"""
    listing = git('ls-tree', '--name-only', '%s:%s' % (tip, folder(branch, name)), check=False)
    if listing.returncode:
        return None
    version, lines = None, {}
    for shard in listing.stdout.decode().split():
        text = git('cat-file', 'blob', '%s:%s/%s' % (tip, folder(branch, name), shard)).stdout.decode('utf-8')
        v, part = parse(text)
        if version is not None and v != version:
            raise SystemExit('%s/%s is version %s, the rest %s' % (folder(branch, name), shard, v, version))
        version = v
        lines.update(part)
    return version, lines


def parse(text, check=False):
    """The version and {key: entry line} of a cache file (one PDB per line, as scan-symbols.py and merge-symbol-caches.py write it);
    with check, after reading it all as JSON, so that a damaged file isn't stored"""
    version = (json.loads(text) if check else json.loads(text.split('\n', 1)[0] + '}}'))['version']
    lines = {}
    for line in text.split('\n')[1:]:
        if line.startswith('"'):
            line = line[:-1] if line.endswith(',') else line
            key = json.loads(line[:line.index('": ') + 1])
            lines[key] = line
    return version, lines


def write(version, lines):
    """A cache file's text, as scan-symbols.py and merge-symbol-caches.py write it"""
    return '{"version": %d, "pdbs": {\n' % version + ',\n'.join(lines[k] for k in sorted(lines)) + '\n}}\n'


def shard_of(key):
    return zlib.crc32(key.encode('utf-8')) % SHARDS


def get(args):
    tip = fetch()
    for name in CACHES:
        path = os.path.join(args.data_dir, name + '.json')
        found = None
        for source in [args.branch] + (['main'] if args.branch != 'main' else []):
            found = read_cache(tip, source, name) if tip else None
            if found:
                break
        if found:
            with open(path, 'w', encoding='utf-8', newline='\n') as f:
                f.write(write(*found))
            print('[cache] %s: %d PDBs, from %s on the cache branch' % (path, len(found[1]), folder(source, name)))
        elif os.path.exists(path):
            print("[cache] %s: none on the cache branch for %s; the one in data/ is used" % (path, ' or '.join(dict.fromkeys([args.branch, 'main']))))
        else:
            print('[cache] %s: none on the cache branch for %s, and none in data/: the scan starts without one' % (path, ' or '.join(dict.fromkeys([args.branch, 'main']))))
    return 0


def commit_object(commit):
    """The parents, author, committer and message of a commit, from its object"""
    raw = git('cat-file', 'commit', commit).stdout.decode('utf-8')
    head, message = raw.split('\n\n', 1)
    fields = {'parents': []}
    for line in head.split('\n'):
        kind, _, rest = line.partition(' ')
        if kind == 'parent':
            fields['parents'].append(rest)
        elif kind in ('author', 'committer'):
            name, _, rest = rest.rpartition(' <')
            email, _, date = rest.partition('> ')
            fields[kind] = (name, email, date)
    fields['message'] = message
    return fields


def commit_like(commit, parent):
    """A copy of commit (its tree, message, author and dates) with another parent, or none"""
    c = commit_object(commit)
    env = {}
    for kind in ('author', 'committer'):
        env.update(zip(('GIT_%s_NAME' % kind.upper(), 'GIT_%s_EMAIL' % kind.upper(), 'GIT_%s_DATE' % kind.upper()), c[kind]))
    return git('commit-tree', commit + '^{tree}', *(['-p', parent] if parent else []), input=c['message'].encode('utf-8'), env=env).stdout.decode().strip()


def store(tip, changes, message):
    """Commits changes ({path: text, or None to remove a folder}) on top of the cache branch, keeping its newest KEEP commits, and
    pushes it unless it changed meanwhile"""
    index = os.path.join(tempfile.mkdtemp(prefix='cache-index-'), 'index')
    env = {'GIT_INDEX_FILE': index}
    if tip:
        git('read-tree', tip, env=env)
    for path, text in sorted(changes.items()):
        if text is None:
            git('rm', '-r', '-q', '--cached', '--ignore-unmatch', '--', path, env=env)
            continue
        blob = git('hash-object', '-w', '--stdin', input=text.encode('utf-8')).stdout.decode().strip()
        git('update-index', '--add', '--cacheinfo', '100644,%s,%s' % (blob, path), env=env)
    tree = git('write-tree', env=env).stdout.decode().strip()
    if tip and tree == git('rev-parse', tip + '^{tree}').stdout.decode().strip():
        print('[cache] no change')
        return
    # The newest KEEP - 1 commits there (the fetch has KEEP), and the new one on top; the oldest one kept loses its parent
    history = git('rev-list', '--max-count=%d' % (KEEP - 1), tip).stdout.decode().split() if tip else []
    parent = None
    for i, commit in enumerate(reversed(history)):
        parent = commit if i == 0 and not commit_object(commit)['parents'] else commit_like(commit, parent)
    new = git('commit-tree', tree, *(['-p', parent] if parent else []), input=message.encode('utf-8'), env=BOT).stdout.decode().strip()
    kept = git('rev-list', new).stdout.decode().split()
    # (The same trees as before, each with the next older as its parent, and at most KEEP of them)
    trees = lambda commits: [git('rev-parse', c + '^{tree}').stdout.decode().strip() for c in commits]
    if len(kept) > KEEP or trees(kept[1:]) != trees(history):
        raise SystemExit('[cache] the new history of the cache branch is wrong; nothing was pushed')
    lease = '--force-with-lease=%s:%s' % (REF, tip or '')
    r = git('push', '-q', lease, 'origin', '%s:%s' % (new, REF), check=False)
    if r.returncode:
        raise SystemExit('[cache] pushing the cache branch failed (has it changed since it was fetched?): %s' % r.stderr.decode('utf-8', 'replace').strip())
    print('[cache] pushed %s to the cache branch (%d commits kept)' % (new[:12], len(kept)))


def shards(version, lines):
    split = [{} for _ in range(SHARDS)]
    for key, line in lines.items():
        split[shard_of(key)][key] = line
    return {'%d.json' % i: write(version, part) for i, part in enumerate(split)}


def put(args):
    tip = fetch()
    changes = {}
    for name in CACHES:
        path = os.path.join(args.data_dir, name + '.json')
        if not os.path.exists(path):
            continue
        with open(path, 'r', encoding='utf-8') as f:
            version, lines = parse(f.read(), check=True)
        for shard, text in shards(version, lines).items():
            changes['%s/%s' % (folder(args.branch, name), shard)] = text
        print('[cache] %s: %d PDBs, for %s' % (path, len(lines), folder(args.branch, name)))
    if not changes:
        print('[cache] no cache in %s' % args.data_dir)
        return 0
    store(tip, changes, args.message)
    if args.forget:
        # Now that the cache branch has them: out of the branch the scan runs on, where they were until the cache branch (they're in
        # .gitignore, so they aren't added again)
        for name in CACHES:
            git('rm', '-q', '--cached', '--ignore-unmatch', '--', os.path.join(args.data_dir, name + '.json'))
    return 0


def fold(args):
    tip = fetch()
    if not tip:
        raise SystemExit('[cache] there is no cache branch')
    work = tempfile.mkdtemp(prefix='cache-fold-')
    changes = {args.source: None}
    for name in CACHES:
        caches = []
        for source in ('main', args.source):
            found = read_cache(tip, source, name)
            if found:
                path = os.path.join(work, source.replace('/', '_'), name + '.json')
                os.makedirs(os.path.dirname(path), exist_ok=True)
                with open(path, 'w', encoding='utf-8', newline='\n') as f:
                    f.write(write(*found))
                caches.append(path)
        if not caches:
            continue
        out = os.path.join(work, name + '.json')
        subprocess.run([sys.executable, os.path.join(HERE, 'merge-symbol-caches.py'), '--data-dir', args.data_dir, '--out', out] + caches, check=True)
        with open(out, 'r', encoding='utf-8') as f:
            version, lines = parse(f.read(), check=True)
        for shard, text in shards(version, lines).items():
            changes['%s/%s' % (folder('main', name), shard)] = text
    store(tip, changes, 'Symbol caches: what %s added, into main' % args.source)
    return 0


def main():
    parser = argparse.ArgumentParser(description='Keep the symbol caches on the cache branch.')
    sub = parser.add_subparsers(dest='command', required=True)
    for command in ('get', 'put'):
        p = sub.add_parser(command)
        p.add_argument('--branch', required=True, help='The branch the scan runs on')
        p.add_argument('--data-dir', default='data')
        if command == 'put':
            p.add_argument('--message', required=True)
            p.add_argument('--forget', action='store_true', help='Then remove the caches from git\'s index (their files stay)')
    p = sub.add_parser('fold')
    p.add_argument('--from', dest='source', required=True)
    p.add_argument('--data-dir', default='data')
    args = parser.parse_args()
    return {'get': get, 'put': put, 'fold': fold}[args.command](args)


if __name__ == '__main__':
    sys.exit(main())
