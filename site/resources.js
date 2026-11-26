// The compare view's resource data: what the files of two builds hold besides code (scan-resources.py), read from the repository's
// assets branch, where everything is stored once, named by its hash. For each build, builds/<build>/index.json.gz has every file the
// scan read, with its hash, and for each file version the hashes of the parts of what was found in it (an executable's icons,
// strings, exports, ...); builds/<build>/files.csv.gz lists every file of the build. The parts are in parts/, images in icons/,
// cursors/, bitmaps/ and images/, whole files in files/, registry keys in registry/.
'use strict';

// GitHub's raw file links, which other sites can read (the site's own repository's, when it's on GitHub Pages)
const ASSETS = (() => {
  const host = location.hostname.match(/^([^.]+)\.github\.io$/i);
  const repo = host && location.pathname.split('/')[1];
  return `https://raw.githubusercontent.com/${host && repo ? `${host[1]}/${repo}` : 'ThioJoe/Windows-Feature-ID-Scanner'}/assets/`;
})();

const resCaches = { index: new Map(), files: new Map(), parts: new Map(), registry: new Map() };

function resCached(map, key, load) {
  if (!map.has(key)) map.set(key, load().catch((e) => { map.delete(key); throw e; }));
  return map.get(key);
}

async function assetFetch(path) {
  // GitHub answers HTTP 429 when one address reads many raw files in a short time (a comparison reads about a thousand): wait and try
  // again, longer each time
  for (let attempt = 0; ; attempt++) {
    const res = await fetch(ASSETS + path);
    if (res.status === 429 && attempt < 5) {
      await new Promise((resolve) => setTimeout(resolve, 2 ** attempt * (1000 + Math.random() * 1000)));
      continue;
    }
    if (!res.ok) throw new Error(`${path}: HTTP ${res.status}`);
    return res;
  }
}

// A .gz file's text (decompressed here, unless the browser already did on the way)
async function assetGzText(path) {
  const bytes = new Uint8Array(await (await assetFetch(path)).arrayBuffer());
  if (bytes[0] !== 0x1f || bytes[1] !== 0x8b) return new TextDecoder().decode(bytes);
  return new Response(new Blob([bytes]).stream().pipeThrough(new DecompressionStream('gzip'))).text();
}

const loadResIndex = (key) => resCached(resCaches.index, key, async () => JSON.parse(await assetGzText(`builds/${encodeURIComponent(key)}/index.json.gz`)));
const loadPart = (hash) => resCached(resCaches.parts, hash, async () => (await assetFetch(`parts/${hash.slice(0, 2)}/${hash}.json`)).json());
const loadRegistry = (hash) => resCached(resCaches.registry, hash, async () => (await assetFetch(`registry/${hash.slice(0, 2)}/${hash}.json`)).json());
const loadFileList = (key) => resCached(resCaches.files, key, async () => parseFileList(await assetGzText(`builds/${encodeURIComponent(key)}/files.csv.gz`)));

// What a file is matched across builds by: its path in lower case (Windows doesn't tell paths apart by case), without what changes in
// folder names when what's in them is updated: the hash a driver package's folder in the driver store is named with
// (ntprint.inf_amd64_6fe9a2a3d1e1d2f8), and the version the Windows Security platform's and the servicing stack's folders are named with
const fileKey = (path) => path.toLowerCase()
  .replace(/^(windows\\system32\\driverstore\\filerepository\\[^\\]+?)_[0-9a-f]{16}(?=\\|\.ini$)/, '$1')
  .replace(/^(windows\\system32\\securityhealth|windows\\servicing\\version)\\\d+\.\d+\.\d+\.\d+[^\\]*(?=\\)/, '$1\\*');
// (The whole path where another path has the same key already: two versions of a driver package)
const setByFileKey = (map, path, value) => { const k = fileKey(path); map.set(map.has(k) ? path.toLowerCase() : k, value); };

// files.csv.gz: path, size, hash (a path with a comma or quote is quoted, as Python's csv module writes it). Keyed by fileKey().
function parseFileList(text) {
  const files = new Map();
  let i = 0, header = true;
  while (i < text.length) {
    const fields = [];
    for (;;) {
      let value = '';
      if (text[i] === '"') {
        i++;
        for (;;) {
          const j = text.indexOf('"', i);
          if (j < 0) { value += text.slice(i); i = text.length; break; }
          value += text.slice(i, j);
          i = j + 1;
          if (text[i] === '"') { value += '"'; i++; } else break;
        }
      } else {
        let j = i;
        while (j < text.length && text[j] !== ',' && text[j] !== '\n' && text[j] !== '\r') j++;
        value = text.slice(i, j);
        i = j;
      }
      fields.push(value);
      if (text[i] === ',') { i++; continue; }
      if (text[i] === '\r') i++;
      if (text[i] === '\n') i++;
      break;
    }
    if (header) { header = false; continue; }
    if (fields.length >= 3 && fields[0]) setByFileKey(files, fields[0], { path: fields[0], size: fields[1], hash: fields[2] });
  }
  return files;
}

const fileName = (path) => path.slice(path.lastIndexOf('\\') + 1);
const fileCell = (r) => `<span title="${esc(r.path)}">${esc(fileName(r.path))}</span>`;
const changeCell = (r) => `<span class="chg ${r.change}">${r.change}</span>`;
const CHANGE_ORDER = { added: 0, removed: 1, changed: 2 };
const changeColumn = { title: 'Change', value: (r) => r.change, sortKey: (r) => CHANGE_ORDER[r.change], html: changeCell };
const textCell = (s) => (s === null || s === undefined ? '<span class="muted">(none)</span>' : `<span class="res-text">${esc(s)}</span>`);

const imageUrl = (kind, w, h, hash, ext) => `${ASSETS}${kind}/${w}x${h}/${hash[0]}/${hash}.${ext || 'png'}`;
const imgHtml = (src, title, max) => `<img class="res-img" loading="lazy" src="${esc(src)}" title="${esc(title)}" alt="" style="max-width:${max}px;max-height:${max}px">`;
// An icon's or cursor's images: [width, height, bits, hash, (hotspot x, y)]; its preview is the largest
const largestImage = (images) => (images || []).reduce((m, x) => (!m || x[0] * x[1] > m[0] * m[1] || (x[0] * x[1] === m[0] * m[1] && x[2] > m[2]) ? x : m), null);
const imagePreview = (kind, images, max = 48) => {
  const x = largestImage(images);
  return x ? imgHtml(imageUrl(kind, x[0], x[1], x[3]), `${x[0]}×${x[1]}, ${x[2]}-bit`, max) : '<span class="muted">(none)</span>';
};
// The old and new images of an icon or cursor in two rows, a column for each size and bit depth, so that the same size lines up (a
// cell is empty where one of them doesn't have it)
const imageGrid = (kind, before, after, marked = () => false) => {
  const key = (x) => `${x[0]}x${x[1]}x${x[2]}`;
  const sizes = new Map();
  [before, after].forEach((list, side) => (list || []).forEach((x) => {
    if (!sizes.has(key(x))) sizes.set(key(x), { x, sides: [[], []] });
    sizes.get(key(x)).sides[side].push(x);
  }));
  const columns = [...sizes.values()].sort((p, q) => p.x[0] * p.x[1] - q.x[0] * q.x[1] || p.x[2] - q.x[2])
    .flatMap(({ sides }) => Array.from({ length: Math.max(sides[0].length, sides[1].length) }, (_, i) => [sides[0][i], sides[1][i]]));
  const cell = (x) => (x ? `<td><span class="res-size${marked(x) ? ' changed' : ''}">${imgHtml(imageUrl(kind, x[0], x[1], x[3]), `${x[0]}×${x[1]}, ${x[2]}-bit`, 96)}<br>${x[0]}×${x[1]}<span class="muted">, ${x[2]}-bit</span></span></td>` : '<td></td>');
  const row = (label, side, list) => `<tr><th>${label}</th>${list && list.length ? columns.map((c) => cell(c[side])).join('') : `<td colspan="${columns.length}" class="muted">(none)</td>`}</tr>`;
  return `<div class="res-grid-wrap"><table class="res-grid">${row('Old', 0, before)}${row('New', 1, after)}</table></div>`;
};

// Added, removed and changed keys of two objects (with equal() for what counts as the same)
function objectDiff(before, after, equal = (x, y) => JSON.stringify(x) === JSON.stringify(y)) {
  const rows = [];
  before = before || {};
  after = after || {};
  for (const [k, v] of Object.entries(after)) {
    if (!(k in before)) rows.push({ change: 'added', key: k, new: v, old: null });
    else if (!equal(before[k], v)) rows.push({ change: 'changed', key: k, new: v, old: before[k] });
  }
  for (const [k, v] of Object.entries(before)) if (!(k in after)) rows.push({ change: 'removed', key: k, old: v, new: null });
  return rows;
}

function listDiff(before, after) {
  const o = new Set(before || []), n = new Set(after || []);
  return [...[...n].filter((x) => !o.has(x)).map((x) => ({ change: 'added', key: x })), ...[...o].filter((x) => !n.has(x)).map((x) => ({ change: 'removed', key: x }))];
}

// The registry keys a build's scan recorded, under the names scan-resources.py gives them
const REGISTRY_TITLES = { policyManager: 'MDM/CSP policies', services: 'Services and drivers', etwProviders: 'ETW providers', activatableClasses: 'WinRT activatable classes' };

// Every key of a registry tree with its values, by its path below the tree's root
function flattenRegistry(tree, path = '', out = {}) {
  if (path) out[path] = tree.values || {};
  for (const [name, sub] of Object.entries(tree.keys || {})) flattenRegistry(sub, path ? `${path}\\${name}` : name, out);
  return out;
}

const registryText = (values) => Object.entries(values || {}).map(([k, v]) => `${k || '(default)'} = ${Array.isArray(v) ? v.join('; ') : v}`).join('\n');

// Values Windows writes as it runs, which differ between any two installations, so they're left out of the comparison (key path, then
// the value's name): in services, network bindings, times and counters, IDs made for the machine and performance counter numbers;
// whether an ETW provider was ever enabled; the WNF state names of MDM/CSP policies, and the processor and graphics power settings
// Windows registers as MDM/CSP knobs for the hardware it finds (which differ between the runners builds were scanned on). These are
// the ones seen to differ between builds.
const REGISTRY_STATE = {
  services: new RegExp([/^[^\\]+\\(Linkage|State|SQMState|SecureTimeLimits|Epoch2?)\\/,
    /^[^\\]+\\Performance\\(First Counter|Last Counter|First Help|Last Help|Object List)$/,
    /^(CLFS\\Authentication\\Key|W32Time\\Config\\LastKnownGoodTime|TPM\\OsBootCount|TPM\\(WMI|ProvisionInfo)\\.*|rdyboost\\(Diagnostics|AttachState)\\.*)$/,
    /^(rdyboost\\Parameters\\(ReadyBootVolumeUniqueId|LastBootPlanUserTime|BootPlan|EffectivePends)|spaceport\\Parameters\\(ControlId|PrimordialId))$/,
    /^(LanmanServer\\Parameters\\Guid|Tcpip6\\Parameters\\Dhcpv6DUID|HyperVideo\\Video\\VideoID|srvnet\\Parameters\\MajorSequence)$/].map((r) => r.source).join('|'), 'i'),
  etwProviders: /^[^\\]+\\Enabled$/i,
  policyManager: /^knobs\\Power\/Policy\/Settings\/|\\wnfStateName\d*$/i,
};
// A build's registry keys as compared: without those values, and without the keys that had only those (or have none, under a key
// whose values are all left out)
function registryForCompare(label, flat) {
  const state = REGISTRY_STATE[label];
  if (!state) return flat;
  const out = {};
  for (const [key, values] of Object.entries(flat)) {
    const kept = Object.fromEntries(Object.entries(values).filter(([name]) => !state.test(`${key}\\${name}`)));
    if (Object.keys(kept).length || (!Object.keys(values).length && !state.test(`${key}\\`))) out[key] = kept;
  }
  return out;
}
// Two keys' values are the same if they differ only in what changes with an update of a driver package, the Windows Security platform
// or Edge (the folder names in their paths, as fileKey()), in letter case, in how a path under the Windows folder is written, or in the
// order of a list
const registryPathForm = (s) => s.toLowerCase()
  .replace(/(\\driverstore\\filerepository\\[^\\]+?)_[0-9a-f]{16}(?=\\)/g, '$1')
  .replace(/(\\securityhealth)\\\d+\.\d+\.\d+\.\d+[^\\]*(?=\\)/g, '$1\\*')
  .replace(/(\\microsoft\\edge[a-z]*\\application)\\\d+\.\d+\.\d+\.\d+(?=\\)/g, '$1\\*')
  .replace(/^\\systemroot\\/, '');
const registryCompareForm = (values) => JSON.stringify(Object.entries(values || {}).map(([k, v]) =>
  [k.toLowerCase(), Array.isArray(v) ? v.map((x) => (typeof x === 'string' ? registryPathForm(x) : x)).sort() : typeof v === 'string' ? registryPathForm(v) : v]).sort());
const registryEqual = (x, y) => registryCompareForm(x) === registryCompareForm(y);

// What kind of whole file it is, from where it is: the groups the compare view lists them in
function fileGroup(path) {
  const p = path.toLowerCase();
  if (p.startsWith('windows\\policydefinitions\\')) return 'Group Policy templates';
  if (p.includes('cloudexperiencehost') || p.includes('microsoftwindows.client.oobe')) return 'Setup (OOBE)';
  if (p.startsWith('windows\\system32\\windowspowershell\\')) return 'PowerShell modules';
  if (p.startsWith('windows\\servicing\\packages\\')) return 'Servicing packages';
  if (p.startsWith('windows\\system32\\tasks\\')) return 'Scheduled tasks';
  if (p.startsWith('windows\\media\\')) return 'Sounds';
  if (p.startsWith('windows\\resources\\themes\\')) return 'Themes';
  if (p.startsWith('windows\\web\\')) return 'Wallpapers and lock screens';
  if (p.startsWith('windows\\cursors\\')) return 'Cursors';
  return 'Shell UI files';
}

// Folders of apps that update themselves (Edge, Copilot, the Store's apps): what they hold depends on when the build's VM ran, not on the build
const SELF_UPDATING = ['program files (x86)\\microsoft\\edge', 'program files (x86)\\microsoft\\copilot\\', 'program files (x86)\\microsoft\\temp\\', 'program files\\windowsapps\\'];
const selfUpdating = (key) => SELF_UPDATING.some((s) => key.startsWith(s));

// The compare view's resource sections. Adds nothing once isCurrent() says a newer render has started.
async function renderResourcesCompare(out, a, b, q, isCurrent) {
  const entryOf = (key) => (index.builds.find((x) => x.key === key) || {}).resources;
  const missing = [a, b].filter((x) => !entryOf(x.key));
  const box = section(out, 'compare:res', 'h2', '', 'Resource Data <span class="count">(icons, UI text, APIs, files and registry)</span>', true);
  const note = (html) => box.insertAdjacentHTML('beforeend', `<p class="muted">${html}</p>`);
  if (missing.length) {
    note(missing.map((x) => `${esc(buildLabel(x))} has no resource data yet.`).join(' ') +
      ' Resource data is what the files of a build hold besides code: icons, UI text, APIs, policies, files and registry keys.');
    return;
  }
  const status = document.createElement('p');
  status.className = 'muted';
  status.textContent = 'Loading the resource data…';
  box.appendChild(status);
  let ia, ib;
  try {
    [ia, ib] = await Promise.all([loadResIndex(a.key), loadResIndex(b.key)]);
  } catch (e) {
    if (isCurrent()) status.textContent = 'Could not load the resource data: ' + e.message;
    return;
  }
  if (!isCurrent()) return;
  status.remove();

  // The files read in either build, and the changed ones
  const files = (ix) => { const m = new Map(); for (const [p, h] of Object.entries(ix.files)) setByFileKey(m, p, { path: p, hash: h }); return m; };
  const fa = files(ia), fb = files(ib);
  const changes = [];
  for (const [k, n] of fb) {
    const o = fa.get(k);
    if (!o) changes.push({ path: n.path, change: 'added', old: null, new: ib.entries[n.hash] });
    else if (o.hash !== n.hash) changes.push({ path: n.path, change: 'changed', old: ia.entries[o.hash], new: ib.entries[n.hash] });
  }
  for (const [k, o] of fa) if (!fb.has(k)) changes.push({ path: o.path, change: 'removed', old: ia.entries[o.hash], new: null });
  const partOf = (entry, part) => (entry && entry.d && entry.d[part]) || null;
  const partChanged = (c, part) => partOf(c.old, part) !== partOf(c.new, part);
  const loadBoth = (c, part) => Promise.all([partOf(c.old, part), partOf(c.new, part)].map((h) => (h ? loadPart(h) : null)));
  const matchesQ = (...texts) => !q || texts.some((t) => t !== null && t !== undefined && String(t).toLowerCase().includes(q));
  note(`${fmt(fa.size)} files read in ${esc(buildLabel(a))}, ${fmt(fb.size)} in ${esc(buildLabel(b))}; ` +
    `${fmt(changes.filter((c) => c.change === 'changed').length)} changed, ${fmt(changes.filter((c) => c.change === 'added').length)} added, ` +
    `${fmt(changes.filter((c) => c.change === 'removed').length)} removed. Images and files load from the repository's assets branch.`);

  // One subsection: its rows (a promise) in a table with these columns. Its place is kept in order while all the subsections load
  // at the same time.
  const pending = [];
  const sub = (id, title, rowsPromise, columns, detail, noteHtml) => {
    const slot = document.createElement('div');
    box.appendChild(slot);
    pending.push((async () => {
      let rows;
      try {
        rows = await rowsPromise;
      } catch (e) {
        if (isCurrent()) slot.innerHTML = `<p class="muted">${esc(title)}: could not load (${esc(e.message)})</p>`;
        return;
      }
      if (!isCurrent()) return;
      rows.forEach((r, i) => { r.id = i; });
      const counts = Object.keys(CHANGE_ORDER).map((c) => [c, rows.filter((r) => r.change === c).length]).filter(([, n]) => n)
        .map(([c, n]) => `<span class="${c}">${fmt(n)} ${c}</span>`).join(', ');
      const sec = section(slot, 'compare:res:' + id, 'h3', '', `${esc(title)} <span class="count">${counts || '0'}</span>`, rows.length > 0);
      const extra = noteHtml && noteHtml();
      if (extra) (rows.length ? sec : slot).insertAdjacentHTML('beforeend', `<p class="muted">${extra}</p>`);
      if (rows.length) renderTable(sec, rows, columns, undefined, detail);
    })());
  };

  // Icons and cursors of executables, by their group's ID. One whose only image is 1×1 is a placeholder: programs built from Chromium's
  // code (copilotapp.exe, mscopilot.exe) keep the places of the icons they don't use, since Windows refers to an icon by its position in
  // the file, with a 1×1 image in each. Those are left out where neither build has more than a placeholder, so a real icon that
  // replaces one, or that one replaces, still shows.
  const placeholder = (images) => !images || (images.length > 0 && images.every((x) => x[0] <= 1 && x[1] <= 1));
  const leftOut = { icons: [], cursors: [] };
  const groupRows = (part, kind) => Promise.all(changes.filter((c) => partChanged(c, part)).map(async (c) => {
    const [o, n] = await loadBoth(c, part);
    return objectDiff(o, n).map((r) => ({ ...r, path: c.path, kind })).filter((r) => matchesQ(r.path, r.key));
  })).then((x) => x.flat().filter((r) => {
    if (!placeholder(r.old) || !placeholder(r.new)) return true;
    leftOut[kind].push(r);
    return false;
  }));
  const placeholderNote = (kind) => () => {
    const rows = leftOut[kind];
    if (!rows.length) return '';
    const files = [...new Set(rows.map((r) => fileName(r.path)))].sort();
    return `Not counted: ${fmt(rows.length)} ${kind === 'icons' ? 'icon' : 'cursor'}${rows.length === 1 ? '' : 's'} whose only image is a 1×1 placeholder ` +
      `(in ${esc(files.slice(0, 5).join(', '))}${files.length > 5 ? ` and ${fmt(files.length - 5)} more files` : ''}). Programs built from Chromium's code ` +
      "keep a 1×1 image in the places of the icons they don't use, since Windows refers to an icon by its position in the file.";
  };
  // A changed icon's images that differ (by size and bits), so its preview is one that changed rather than its largest
  const sizeKey = (x) => `${x[0]}x${x[1]}x${x[2]}`;
  const differing = (r) => {
    if (r.change !== 'changed') return [r.old, r.new];
    const o = new Map(r.old.map((x) => [sizeKey(x), x[3]])), n = new Map(r.new.map((x) => [sizeKey(x), x[3]]));
    const oc = r.old.filter((x) => n.get(sizeKey(x)) !== x[3]), nc = r.new.filter((x) => o.get(sizeKey(x)) !== x[3]);
    return [oc.length ? oc : r.old, nc.length ? nc : r.new];
  };
  // The variations (an image of one size and bit depth) the change is in: all of an added or removed icon's, those of a changed icon
  // that were added, removed or changed
  const changedVariations = (r) => {
    const pairs = (list) => new Set((list || []).map((x) => `${sizeKey(x)}:${x[3]}`));
    const o = pairs(r.old), n = pairs(r.new);
    return new Set([...(r.old || []).filter((x) => !n.has(`${sizeKey(x)}:${x[3]}`)), ...(r.new || []).filter((x) => !o.has(`${sizeKey(x)}:${x[3]}`))].map(sizeKey));
  };
  const variationsText = (r) => {
    const all = new Set([...(r.old || []), ...(r.new || [])].map(sizeKey)).size;
    return `${r.change === 'changed' ? `${fmt(changedVariations(r).size)} of ` : ''}${fmt(all)} variation${all === 1 ? '' : 's'}`;
  };
  const groupColumns = (kind) => [changeColumn,
    { title: 'File', value: (r) => fileName(r.path), html: fileCell, cls: 'name' },
    { title: 'ID', value: (r) => r.key, cls: 'id' },
    { title: 'Variations', value: variationsText, sortKey: (r) => changedVariations(r).size, cls: 'mods' },
    { title: 'Old', value: () => '', html: (r) => imagePreview(kind, differing(r)[0]), cls: 'res-cell' },
    { title: 'New', value: () => '', html: (r) => imagePreview(kind, differing(r)[1]), cls: 'res-cell' }];
  const groupDetail = (kind) => async (r) => {
    // (Outlined only where some of them changed, not all)
    const changed = r.change === 'changed' ? changedVariations(r) : new Set();
    const keys = changed.size < new Set([...(r.old || []), ...(r.new || [])].map(sizeKey)).size ? changed : new Set();
    const marked = (x) => keys.has(sizeKey(x));
    return `<div class="res-detail">${imageGrid(kind, r.old, r.new, marked)}` +
      `<p class="muted">${keys.size ? 'Outlined: the variations that changed. ' : ''}${esc(r.path)}</p></div>`;
  };
  await sub('icons', 'Icons', groupRows('icons', 'icons'), groupColumns('icons'), groupDetail('icons'), placeholderNote('icons'));
  await sub('cursors', 'Cursors in executables', groupRows('cursors', 'cursors'), groupColumns('cursors'), groupDetail('cursors'), placeholderNote('cursors'));

  // Bitmaps and other images in executables
  const imageRows = Promise.all(changes.filter((c) => partChanged(c, 'bitmaps') || partChanged(c, 'images')).map(async (c) => {
    const [ob, nb] = await loadBoth(c, 'bitmaps');
    const [oi, ni] = await loadBoth(c, 'images');
    const bitmaps = objectDiff(ob, nb).map((r) => ({ ...r, kind: 'bitmaps' }));
    const images = objectDiff(oi, ni).map((r) => ({ ...r, kind: 'images' }));
    return [...bitmaps, ...images].map((r) => ({ ...r, path: c.path })).filter((r) => matchesQ(r.path, r.key));
  })).then((x) => x.flat());
  const resourceImage = (r, x) => {
    if (!x) return '<span class="muted">(none)</span>';
    const [w, h, hash, ext] = x;
    return ext === 'svg' ? imgHtml(`${ASSETS}images/svg/${hash[0]}/${hash}.svg`, 'SVG', 96) : imgHtml(imageUrl(r.kind, w, h, hash, ext), `${w}×${h}`, 96);
  };
  await sub('bitmaps', 'Bitmaps and images in executables', imageRows, [changeColumn,
    { title: 'File', value: (r) => fileName(r.path), html: fileCell, cls: 'name' },
    { title: 'ID', value: (r) => r.key, cls: 'id' },
    { title: 'Old', value: () => '', html: (r) => resourceImage(r, r.old), cls: 'res-cell' },
    { title: 'New', value: () => '', html: (r) => resourceImage(r, r.new), cls: 'res-cell' }]);

  // UI text: string and message tables, dialogs and menus
  const dialogText = (d) => (d ? [d.title, ...(d.controls || []).map((x) => x[2]).filter((t) => t && !t.startsWith('#'))].filter(Boolean).join(' · ') : null);
  const textRows = Promise.all(changes.filter((c) => ['strings', 'messages', 'dialogs', 'menus'].some((p) => partChanged(c, p))).map(async (c) => {
    const rows = [];
    for (const [part, kind] of [['strings', 'String'], ['messages', 'Message']]) {
      if (!partChanged(c, part)) continue;
      const [o, n] = await loadBoth(c, part);
      rows.push(...objectDiff(o, n).map((r) => ({ ...r, kind, old: r.old, new: r.new })));
    }
    if (partChanged(c, 'dialogs')) {
      const [o, n] = await loadBoth(c, 'dialogs');
      rows.push(...objectDiff(o, n).map((r) => ({ ...r, kind: 'Dialog', old: dialogText(r.old), new: dialogText(r.new) })).filter((r) => r.old !== r.new));
    }
    if (partChanged(c, 'menus')) {
      const [o, n] = await loadBoth(c, 'menus');
      for (const id of new Set([...Object.keys(o || {}), ...Object.keys(n || {})])) {
        const items = (m) => (m && m[id] ? m[id].map((x) => x[0]).filter((t) => t && !t.endsWith('-')) : []);
        rows.push(...listDiff(items(o), items(n)).map((r) => ({ change: r.change, key: id, kind: 'Menu', old: r.change === 'removed' ? r.key : null, new: r.change === 'added' ? r.key : null })));
      }
    }
    return rows.map((r) => ({ ...r, path: c.path })).filter((r) => matchesQ(r.path, r.key, r.old, r.new));
  })).then((x) => x.flat());
  await sub('text', 'UI text', textRows, [changeColumn,
    { title: 'File', value: (r) => fileName(r.path), html: fileCell, cls: 'name' },
    { title: 'Kind', value: (r) => r.kind, cls: 'mods' },
    { title: 'ID', value: (r) => r.key, sortKey: (r) => Number(r.key) || r.key, cls: 'id' },
    { title: 'Old', value: (r) => r.old, html: (r) => textCell(r.old), cls: 'sgm' },
    { title: 'New', value: (r) => r.new, html: (r) => textCell(r.new), cls: 'sgm' }]);

  // APIs: exported functions, and WinRT types and their members
  const apiRows = Promise.all(changes.filter((c) => partChanged(c, 'exports') || partChanged(c, 'types')).map(async (c) => {
    const rows = [];
    if (partChanged(c, 'exports')) {
      const [o, n] = await loadBoth(c, 'exports');
      rows.push(...listDiff(o, n).map((r) => ({ ...r, kind: 'Export', name: r.key })));
    }
    if (partChanged(c, 'types')) {
      const [o, n] = await loadBoth(c, 'types');
      for (const r of objectDiff(o, n)) {
        if (r.change !== 'changed') { rows.push({ change: r.change, kind: `WinRT ${(r.new || r.old).kind}`, name: r.key }); continue; }
        for (const m of ['methods', 'properties', 'events', 'fields']) {
          rows.push(...listDiff(r.old[m], r.new[m]).map((x) => ({ change: x.change, kind: `WinRT ${m.replace(/s$/, '').replace(/ie$/, 'y')}`, name: `${r.key}.${x.key}` })));
        }
      }
    }
    return rows.map((r) => ({ ...r, path: c.path })).filter((r) => matchesQ(r.path, r.name));
  })).then((x) => x.flat());
  await sub('apis', 'APIs', apiRows, [changeColumn,
    { title: 'File', value: (r) => fileName(r.path), html: fileCell, cls: 'name' },
    { title: 'Kind', value: (r) => r.kind, cls: 'mods' },
    { title: 'Name', value: (r) => r.name, cls: 'name wide' }]);

  // Fonts: characters and emoji sequences whose glyph is new, gone or different, drawn with each build's own font file
  const fontFaces = new Map();
  const fontFamily = (entry) => {
    const hash = entry.meta.split('/').pop().replace('.json', '');
    if (!fontFaces.has(hash)) {
      const face = new FontFace('res-' + hash, `url(${ASSETS}${entry.file})`);
      document.fonts.add(face);
      face.load().catch(() => {});
      fontFaces.set(hash, 'res-' + hash);
    }
    return fontFaces.get(hash);
  };
  const glyphText = (key) => key.split(' ').map((cp) => String.fromCodePoint(parseInt(cp, 16))).join('');
  const glyph = (entry, key) => (entry ? `<span class="res-glyph" style="font-family:'${fontFamily(entry)}'">${esc(glyphText(key))}</span>` : '<span class="muted">(none)</span>');
  const fontRows = Promise.all(changes.filter((c) => (c.old || c.new || {}).kind === 'font' && ['codepoints', 'sequences'].some((p) => partChanged(c, p))).map(async (c) => {
    const rows = [];
    for (const part of ['codepoints', 'sequences']) {
      const [o, n] = await loadBoth(c, part);
      rows.push(...objectDiff(o, n).map((r) => ({ ...r, c })));
    }
    return rows.map((r) => ({ ...r, path: c.path })).filter((r) => matchesQ(r.path, r.key));
  })).then((x) => x.flat());
  await sub('fonts', 'Font glyphs', fontRows, [changeColumn,
    { title: 'Font', value: (r) => fileName(r.path), html: fileCell, cls: 'name' },
    { title: 'Character', value: (r) => r.key, html: (r) => `<span class="id">U+${esc(r.key.replace(/ /g, ' U+'))}</span>`, cls: 'mods' },
    { title: 'Old', value: () => '', html: (r) => glyph(r.change === 'added' ? null : r.c.old, r.key), cls: 'res-cell' },
    { title: 'New', value: () => '', html: (r) => glyph(r.change === 'removed' ? null : r.c.new, r.key), cls: 'res-cell' }]);

  // Whole files: shell UI files, wallpapers, Group Policy templates, setup, PowerShell modules, packages, tasks, sounds, themes, cursors
  const fileLink = (entry, label) => (entry && entry.file ? `<a href="${esc(ASSETS + entry.file)}" target="_blank" rel="noopener">${label}</a>` : '');
  const filePreview = (entry) => {
    if (!entry) return '<span class="muted">(none)</span>';
    if (entry.kind === 'image' && entry.file) return imgHtml(ASSETS + entry.file, entry.size ? `${entry.size[0]}×${entry.size[1]}` : '', 64);
    return fileLink(entry, entry.lottie ? 'animation (Lottie)' : 'file');
  };
  const wholeRows = changes.filter((c) => ['image', 'file', 'ico', 'cursor', 'ani'].includes((c.new || c.old || {}).kind))
    .map((c) => ({ ...c, group: fileGroup(c.path) })).filter((r) => matchesQ(r.path, r.group));
  await sub('files', 'Files', Promise.resolve(wholeRows), [changeColumn,
    { title: 'Kind', value: (r) => r.group, cls: 'mods' },
    { title: 'Path', value: (r) => r.path, html: (r) => `<span class="res-path">${esc(r.path)}</span>`, cls: 'sgm' },
    { title: 'Old', value: () => '', html: (r) => filePreview(r.old), cls: 'res-cell' },
    { title: 'New', value: () => '', html: (r) => filePreview(r.new), cls: 'res-cell' }]);

  // Registry keys
  for (const [label, title] of Object.entries(REGISTRY_TITLES)) {
    const ho = (ia.registry || {})[label], hn = (ib.registry || {})[label];
    if (!ho || !hn) continue;
    const rows = ho === hn ? Promise.resolve([]) : Promise.all([loadRegistry(ho), loadRegistry(hn)]).then(([o, n]) =>
      objectDiff(registryForCompare(label, flattenRegistry(o)), registryForCompare(label, flattenRegistry(n)), registryEqual).map((r) => ({ ...r, path: r.key, oldText: r.old && registryText(r.old), newText: r.new && registryText(r.new) }))
        .filter((r) => matchesQ(r.key, r.oldText, r.newText)));
    await sub('registry:' + label, title, rows, [changeColumn,
      { title: 'Key', value: (r) => r.key, html: (r) => `<span class="res-path">${esc(r.key)}</span>${label === 'etwProviders' && (r.new || r.old || {})[''] ? `<div class="muted">${esc((r.new || r.old)[''])}</div>` : ''}`, cls: 'sgm' },
      { title: 'Old values', value: (r) => r.oldText, html: (r) => textCell(r.oldText), cls: 'sgm' },
      { title: 'New values', value: (r) => r.newText, html: (r) => textCell(r.newText), cls: 'sgm' }]);
  }

  // Every file of the two builds (also those the scan doesn't read): which were added and removed
  if (!isCurrent()) return;
  const allSec = section(box, 'compare:res:all', 'h3', '', 'All files added and removed <span class="count">(loading)</span>', true);
  try {
    const [la, lb] = await Promise.all([loadFileList(a.key), loadFileList(b.key)]);
    if (!isCurrent()) return;
    const rows = [];
    for (const [k, f] of lb) if (!la.has(k) && !selfUpdating(k)) rows.push({ change: 'added', path: f.path, size: f.size });
    for (const [k, f] of la) if (!lb.has(k) && !selfUpdating(k)) rows.push({ change: 'removed', path: f.path, size: f.size });
    let changed = 0;
    for (const [k, f] of lb) if (la.has(k) && la.get(k).hash !== f.hash && !selfUpdating(k)) changed++;
    const shown = rows.filter((r) => matchesQ(r.path));
    shown.forEach((r, i) => { r.id = i; });
    allSec.querySelector('.count').innerHTML = `<span class="added">${fmt(shown.filter((r) => r.change === 'added').length)} added</span>, ` +
      `<span class="removed">${fmt(shown.filter((r) => r.change === 'removed').length)} removed</span> (and ${fmt(changed)} changed)`;
    allSec.insertAdjacentHTML('beforeend', '<p class="muted">Not counted: Edge, Copilot and the Store\'s apps (Program Files\\WindowsApps), which update themselves, so what they have depends on when the build was scanned.</p>');
    renderTable(allSec, shown, [changeColumn,
      { title: 'Path', value: (r) => r.path, html: (r) => `<span class="res-path">${esc(r.path)}</span>`, cls: 'sgm' },
      { title: 'Size', value: (r) => (r.size === '' ? null : Number(r.size)), html: (r) => (r.size === '' ? '' : fmt(r.size)), cls: 'mods' }]);
  } catch (e) {
    allSec.querySelector('.count').textContent = '(could not load: ' + e.message + ')';
  }
  await Promise.all(pending);
}
