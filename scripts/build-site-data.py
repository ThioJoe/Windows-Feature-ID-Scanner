# build-site-data.py
# Derives the files the site loads from data/, when the site is published (pages.yml). They aren't kept in the repository: data/ holds
# each build's data in its own folder, and these only rearrange it so the site can load what it shows quickly.
#
#   <out>/details/<arch>/<nn>.json   For each feature ID, its code details (from the builds' details.json) from the newest build of the
#                                    architecture that has them, with that build's key. Split by feature ID (ID % 64), so that showing a
#                                    feature only downloads the file it's in rather than all of a build's details. Also what the newest
#                                    feature trace that saw it says of where it's used (the processes and the targets that checked it,
#                                    from a build's features.json), for builds whose own trace didn't see it.
#
#   <out>/super-god-mode.json        The builds that have Super God Mode statistics (their super-god-mode/ folder), with the version,
#                                    user and any error from its run.json.
#   <out>/super-god-mode/<build>.json The statistics of each of those builds: the columns and rows of each of its CSV files, so that
#                                    comparing two builds loads two files. Also the entries of the Settings app's search index
#                                    (Settings_XML_Resolved.xml) as a table, Settings_Index: what each entry says, where it leads,
#                                    and the feature that shows or hides it.
#
#   <out>/trace-targets/<build>.json What the build's feature trace's app and Control Panel targets opened in full, by their labels (from
#                                    its trace.json), for the site's tooltips: an app's program with its folder, and a Control Panel
#                                    link's command.
#
#   python scripts/build-site-data.py --data data --out _site/derived

import argparse
import csv
import json
import os
import sys
import xml.etree.ElementTree as ET

SHARDS = 64


def version_tuple(build):
    return tuple(int(p) for p in build.split('.'))


SETTINGS_COLUMNS = ['Entry', 'Description', 'Page', 'Group', 'Setting', 'Shown with feature', 'Hidden with feature', 'Condition',
                    'Deep link', 'Host', 'Policy IDs', 'High keywords', 'Keywords']


def settings_index(path):
    # One row per SearchableContent element. An entry can have several paths (pages, groups, settings); their values are joined.
    def joined(el, xpath):
        values = []
        for e in el.findall(xpath):
            for v in (e.text or '').split(';'):
                if v.strip() and v.strip() not in values:
                    values.append(v.strip())
        return '; '.join(values)
    rows = []
    for el in ET.parse(path).getroot().iter('SearchableContent'):
        rows.append([el.findtext('Filename') or '', el.findtext('SettingInformation/Description') or '',
                     joined(el, 'SettingIdentity//PageID'), joined(el, 'SettingIdentity//GroupID'), joined(el, 'SettingIdentity//SettingID'),
                     el.get('IncludeWithFeature', ''), el.get('ExcludeWithFeature', ''), joined(el, 'SettingIdentity/Condition'),
                     el.findtext('ApplicationInformation/DeepLink') or '', el.findtext('SettingIdentity/HostID') or '',
                     joined(el, 'SettingIdentity//PolicyIds'), el.findtext('SettingInformation/HighKeywords') or '',
                     el.findtext('SettingInformation/Keywords') or ''])
    return {'columns': SETTINGS_COLUMNS, 'rows': rows}


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
        if tables and os.path.exists(os.path.join(folder, 'Settings_XML_Resolved.xml')):
            tables['Settings_Index'] = settings_index(os.path.join(folder, 'Settings_XML_Resolved.xml'))
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


# The known folders an app ID can start with ({1AC14E77-...}\odbcad32.exe: the folder's ID and the path in it)
KNOWN_FOLDERS = {
    '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}': r'%windir%\System32',
    '{D65231B0-B2F1-4857-A4CE-A8E7C6EA7D27}': r'%windir%\SysWOW64',
    '{F38BF404-1D43-42F2-9305-67DE0B28FC23}': r'%windir%',
    '{905E63B6-C1BF-494E-B29C-65B732D3D21A}': r'%ProgramFiles%',
    '{6D809377-6AF0-444B-8957-A3773F02200E}': r'%ProgramFiles%',
    '{7C5A40EF-A0FB-4BFC-874A-C0F2E0B9FA8E}': r'%ProgramFiles(x86)%',
}


def trace_targets(builds_dir, out):
    # The labels show an app by its program alone and a Control Panel link by its name, and each names one thing in its build
    # (summarize-trace.py, target_labels)
    done = []
    for key in sorted(os.listdir(builds_dir)) if os.path.isdir(builds_dir) else []:
        path = os.path.join(builds_dir, key, 'trace.json')
        if not os.path.exists(path):
            continue
        full = {}
        with open(path, encoding='utf-8') as f:
            for t in json.load(f).get('targets', []):
                target = t['target']
                if t['kind'] == 'app' and '\\' in target:
                    folder, _, rest = target.partition('\\')
                    target = KNOWN_FOLDERS.get(folder.upper(), folder) + '\\' + rest
                elif t['kind'] != 'task':
                    continue
                if target not in full.setdefault(t['label'], []):
                    full[t['label']].append(target)
        os.makedirs(os.path.join(out, 'trace-targets'), exist_ok=True)
        with open(os.path.join(out, 'trace-targets', key + '.json'), 'w', encoding='utf-8', newline='\n') as f:
            json.dump({label: '\n'.join(targets) for label, targets in sorted(full.items())}, f, ensure_ascii=False, indent=0)
        done.append('%s (%d)' % (key, len(full)))
    print('[site] the full targets of the feature traces of %s' % (', '.join(done) or 'no build'))


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

    # Where the newest trace that saw a feature saw it used. Not its stages or results: those belong to that build.
    traced = {}  # arch -> feature ID -> {build, processes, targets}
    names = [name for name in os.listdir(builds_dir) if os.path.exists(os.path.join(builds_dir, name, 'features.json'))] if os.path.isdir(builds_dir) else []
    for key in sorted(names, key=lambda k: version_tuple(k.rsplit('-', 1)[0])):
        with open(os.path.join(builds_dir, key, 'features.json'), encoding='utf-8') as f:
            build = json.load(f)
        for feat in build.get('features', []) if build.get('trace') else []:
            if feat.get('trace'):
                t = feat['trace']
                traced.setdefault(build['architecture'], {})[feat['id']] = dict({'build': key, 'processes': t.get('processes', [])},
                                                                               **({'targets': t['targets']} if t.get('targets') else {}))

    for arch in sorted(set(newest) | set(traced)):
        features, seen = newest.get(arch, {}), traced.get(arch, {})
        entry = lambda fid: dict({'build': features[fid][0], 'usage': features[fid][1]} if fid in features else {},
                                 **({'trace': seen[fid]} if fid in seen else {}))
        out_dir = os.path.join(args.out, 'details', arch)
        os.makedirs(out_dir, exist_ok=True)
        for n in range(SHARDS):
            lines = ['%s: %s' % (json.dumps(str(fid)), json.dumps(entry(fid), separators=(',', ':')))
                     for fid in sorted(set(features) | set(seen)) if fid % SHARDS == n]
            with open(os.path.join(out_dir, '%02d.json' % n), 'w', encoding='utf-8', newline='\n') as f:
                f.write('{\n' + ',\n'.join(lines) + '\n}\n' if lines else '{}\n')
        builds = sorted({key for key, _ in features.values()})
        print('[site] %s: code details of %d features, from %s' % (arch, len(features), ', '.join(builds)))
        if seen:
            print('[site] %s: where %d features are used, from the feature traces of %s' % (arch, len(seen), ', '.join(sorted({t['build'] for t in seen.values()}))))
    os.makedirs(args.out, exist_ok=True)
    super_god_mode(builds_dir, args.out)
    trace_targets(builds_dir, args.out)
    return 0


if __name__ == '__main__':
    sys.exit(main())
