# Temporary: compares scan-resources.py's reading of the .pri files the assets branch has stored whole with Microsoft's own reading
# of them (makepri.exe dump /dt Detailed, from the Windows SDK), before the whole files are removed from the branch:
#  1. every resource and candidate (name, qualifiers, type, value) pri_resources reads, against the dump's
#  2. what read_pri keeps (the English and neutral strings, images, icons, compiled XAML pages and other files), against what the dump
#     says should be kept by the same rules (not another language, not a path, not ContentChecksumValue)
#   python compare.py <makepri.exe> <folder of .pri files> <list of their paths> <report.json> <folder for sample dumps>
import base64, collections, hashlib, importlib.util, io, json, os, re, subprocess, sys, tempfile, xml.etree.ElementTree as ET

spec = importlib.util.spec_from_file_location('scan_resources', os.path.join('scripts', 'scan-resources.py'))
sr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sr)
STRING_TYPES = {'string': 'utf-16-le', 'asciiString': 'latin-1', 'utf8String': 'utf-8'}
PATH_TYPES = {'path': 'utf-16-le', 'asciiPath': 'latin-1', 'utf8Path': 'utf-8'}
BAD_REFERENCE = re.compile(rb'&#(x0*[0-8bBcCeEfF]|x0*1[0-9a-fA-F]|0*[0-8]|0*1[1-24-9]|0*2[0-9]|0*3[01]);')


def kind_of(value_type):
    t = value_type.lower()
    return 'string' if 'string' in t else 'path' if 'path' in t else 'data'


def norm_quals(quals):
    return tuple(sorted((n.lower(), v.lower()) for n, v in quals))


def canonical(key):
    """A kept resource's key ('name (qualifier=value, ...)'), in lower case with its qualifiers sorted"""
    key = key.lower()
    if key.endswith(')') and ' (' in key:
        name, _, quals = key[:-1].rpartition(' (')
        return '%s (%s)' % (name, ', '.join(sorted(quals.split(', '))))
    return key


def nl(s):
    return s.replace('\r\n', '\n').replace('\r', '\n')


def read_dump(path):
    """{name: [(qualifiers, kind, value)]} from a makepri Detailed dump, the resource maps' attributes, and the candidate types seen"""
    try:
        return read_events(ET.iterparse(path, events=('start', 'end')))
    except ET.ParseError:
        with open(path, 'rb') as f:  # (A string with a character XML 1.0 can't have, written as a character reference)
            text = BAD_REFERENCE.sub(b'\xef\xbf\xbd', f.read())
        resources, maps, types = read_events(ET.iterparse(io.BytesIO(text), events=('start', 'end')))
        types['dump with characters XML cannot have'] += 1
        return resources, maps, types


def read_events(events):
    resources, maps, types, stack = collections.defaultdict(list), [], collections.Counter(), []
    for event, el in events:
        if event == 'start':
            if el.tag == 'ResourceMap':
                maps.append(dict(el.attrib))
                stack = []
            elif el.tag == 'ResourceMapSubtree':
                stack.append(el.get('name'))
            continue
        if el.tag == 'ResourceMapSubtree':
            stack.pop()
            el.clear()
        elif el.tag == 'NamedResource':
            name = '/'.join(stack + [el.get('name')])
            for cand in el.findall('Candidate'):
                quals = norm_quals((q.get('name'), q.get('value')) for q in cand.iter('Qualifier'))
                ctype = cand.get('type') or '?'
                types[ctype] += 1
                kind = kind_of(ctype)
                value, tags = None, []
                for child in cand:
                    if child.tag == 'QualifierSet':
                        continue
                    tags.append(child.tag)
                    text = child.text or ''
                    value = base64.b64decode(text) if (kind == 'data' or 'base64' in child.tag.lower()) else text
                if value is None:
                    types['(no value) ' + ctype] += 1
                resources[name].append((quals, kind, value))
                types['element ' + '+'.join(tags)] += 1
            el.clear()
    return resources, maps, types


def read_ours(data):
    maps, res = sr.pri_resources(data)
    resources = collections.defaultdict(list)
    for name, values in res:
        for quals, value_type, value in values:
            value = bytes(value)
            if value_type in STRING_TYPES or value_type in PATH_TYPES:
                value = value.decode(STRING_TYPES.get(value_type) or PATH_TYPES[value_type], 'replace').rstrip('\0')
            resources[name].append((norm_quals(quals), kind_of(value_type), value))
    return resources, maps


def same(a, b):
    if a == b:
        return 'same'
    if isinstance(a, str) and isinstance(b, str):
        if nl(a) == nl(b):
            return 'same but for line ends'
        if '�' in b and len(a) == len(b) and all(x == y or y == '�' for x, y in zip(a, b)):
            return 'same but for characters XML cannot have'
    return None


def compare_candidates(ours, theirs, problems, stats):
    names_ours, names_theirs = set(ours), set(theirs)
    for name in sorted(names_theirs - names_ours):
        problems.append(('resource only in the dump', name))
    for name in sorted(names_ours - names_theirs):
        problems.append(('resource only in ours', name))
    for name in names_ours & names_theirs:
        a, b = collections.defaultdict(list), collections.defaultdict(list)
        for q, k, v in ours[name]:
            a[(q, k)].append(v)
        for q, k, v in theirs[name]:
            b[(q, k)].append(v)
        if set(a) != set(b):
            problems.append(('different candidates', name, sorted(map(str, set(a) - set(b)))[:5], sorted(map(str, set(b) - set(a)))[:5]))
            continue
        for key in a:
            va, vb = a[key], b[key]
            if len(va) != len(vb):
                problems.append(('different number of candidates', name, str(key), len(va), len(vb)))
                continue
            # (Several candidates with the same qualifiers are compared in the order of their values)
            pairs = [(va[0], vb[0])] if len(va) == 1 else list(zip(sorted(va, key=repr), sorted(vb, key=repr)))
            for x, y in pairs:
                result = same(x, y)
                stats['candidates ' + (result or 'different')] += 1
                if not result:
                    problems.append(('different value', name, str(key), repr(x)[:200], repr(y)[:200]))


def expected_kept(theirs):
    """What read_pri should keep by its rules, from the dump: {key: (kind, value)}, counts of what's left out and why, and the
    resources with English candidates but none for en-US"""
    chosen, left_out, english_only = {}, collections.Counter(), []
    for name, cands in theirs.items():
        if name in sr.PRI_LEFT_OUT:
            left_out['ContentChecksumValue'] += len(cands)
            continue
        languages = {dict(q).get('language') for q, k, v in cands}
        if 'en-us' not in languages and any(l and l.startswith('en') for l in languages):
            english_only.append(name)
        for q, kind, value in cands:
            language = dict(q).get('language')
            if language and language != 'en-us':
                left_out['other languages'] += 1
                continue
            if kind == 'path':
                left_out['paths'] += 1
                continue
            other = ', '.join('%s=%s' % qv for qv in q if qv[0] != 'language')
            key = canonical('%s (%s)' % (name, other) if other else name)
            rank = 0 if language else 1
            if key in chosen:
                kept_rank = min(rank, chosen[key][0])
                left_out['same key, %s kept' % ('the en-US one' if kept_rank == 0 and rank != chosen[key][0] else 'the first')] += 1
                if same(chosen[key][2], value) is None:
                    left_out['same key, with another value'] += 1
                if rank >= chosen[key][0]:
                    continue
            chosen[key] = (rank, kind, value)
    return {k: (kind, value) for k, (_, kind, value) in chosen.items()}, left_out, english_only


def compare_kept(info, expected, problems, stats):
    sha = lambda b: hashlib.sha256(b).hexdigest()
    got = {}
    for part in ('strings', 'images', 'icons', 'xaml', 'files'):
        for key, value in (info.get(part) or {}).items():
            got[canonical(key)] = (part, value)
    for key in sorted(set(expected) - set(got)):
        problems.append(('should be kept, is not', key, expected[key][0]))
    for key in sorted(set(got) - set(expected)):
        problems.append(('kept, should not be', key, got[key][0]))
    for key in set(expected) & set(got):
        kind, value = expected[key]
        part, kept = got[key]
        stats['kept ' + part] += 1
        if part == 'strings':
            ok = kind == 'string' and same(kept, value) is not None
        elif part == 'images':
            ok = kind == 'data' and sha(value).startswith(kept[2])
        elif part == 'xaml':
            ok = kind == 'data' and kept[0] == sha(value)[:16]
        elif part == 'files':
            ok = kind == 'data' and sha(value).startswith(kept[0]) and kept[1] == len(value)
        else:  # (icons: the images of the .ico)
            ok = kind == 'data' and bool(kept)
        if not ok:
            problems.append(('kept with other content', key, part, repr(kept)[:200]))



def main(makepri, root, listing, report_path, samples):
    with open(listing, encoding='utf-8') as f:
        paths = [line.strip() for line in f if line.strip()]
    report = {'files': len(paths), 'checked': 0, 'problems': 0, 'stats': collections.Counter(), 'leftOut': collections.Counter(),
              'types': collections.Counter(), 'englishWithoutEnUS': {}, 'byFile': {}, 'failed': {}}
    os.makedirs(samples, exist_ok=True)
    smallest = sorted(paths, key=lambda p: os.path.getsize(os.path.join(root, p)))
    keep_samples = set(smallest[:2] + smallest[len(smallest) // 2:len(smallest) // 2 + 1])
    work = tempfile.mkdtemp(prefix='pri-check-')
    try:
        for n, path in enumerate(paths, 1):
            pri = os.path.join(root, path)
            xml = os.path.join(work, 'dump.xml')
            if os.path.exists(xml):
                os.remove(xml)
            r = subprocess.run([makepri, 'dump', '/if', pri, '/of', xml, '/dt', 'Detailed', '/o'], capture_output=True, text=True, errors='replace')
            if r.returncode or not os.path.exists(xml):
                report['failed'][path] = 'makepri %d: %s' % (r.returncode, (r.stdout + r.stderr)[-2000:])
                report['problems'] += 1
                print('[%d/%d] %s: makepri failed (%d)' % (n, len(paths), path, r.returncode), flush=True)
                continue
            with open(pri, 'rb') as f:
                data = f.read()
            problems, stats = [], collections.Counter()
            try:
                theirs, their_maps, types = read_dump(xml)
                ours, our_maps = read_ours(data)
                compare_candidates(ours, theirs, problems, stats)
                expected, left_out, english_only = expected_kept(theirs)
                info = sr.read_pri(sr.Store(os.path.join(work, 'store'), set()), data, os.path.basename(path))
                compare_kept(info, expected, problems, stats)
            except Exception as e:
                report['failed'][path] = '%s: %s' % (type(e).__name__, e)
                report['problems'] += 1
                print('[%d/%d] %s: %s: %s' % (n, len(paths), path, type(e).__name__, e), flush=True)
                continue
            languages = sorted({dict(q).get('language') for c in theirs.values() for q, k, v in c} - {None})
            if languages != info.get('languages', []):
                problems.append(('languages', info.get('languages'), languages))
            report['checked'] += 1
            report['problems'] += len(problems)
            report['stats'].update(stats)
            report['leftOut'].update(left_out)
            report['types'].update(types)
            if english_only:
                report['englishWithoutEnUS'][path] = english_only[:20]
            report['byFile'][path] = {'size': len(data), 'resources': len(theirs), 'maps': [m.get('name') for m in their_maps],
                                      'ourMaps': our_maps, 'problems': problems[:40], 'problemCount': len(problems)}
            if path in keep_samples:
                os.replace(xml, os.path.join(samples, path.replace('/', '_') + '.xml'))
            print('[%d/%d] %s: %d resources, %d problems' % (n, len(paths), path, len(theirs), len(problems)), flush=True)
    finally:
        with open(report_path, 'w', encoding='utf-8') as f:
            json.dump(report, f, indent=1, ensure_ascii=False, default=str)
    print(json.dumps({k: report[k] for k in ('files', 'checked', 'problems', 'stats', 'leftOut', 'types', 'failed')}, indent=1, default=str))
    print('English candidates without en-US in %d files' % len(report['englishWithoutEnUS']))
    sys.exit(1 if report['problems'] or report['checked'] != len(paths) else 0)


if __name__ == '__main__':
    main(*sys.argv[1:6])
