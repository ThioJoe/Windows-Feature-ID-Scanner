// Windows Feature IDs browser. Loads data/index.json, then individual build files on demand.
'use strict';

const DATA = 'data/';
const PAGE = 500;
const NUMERIC = /^(?:ID|FI)?\d+$/;

const DETAIL_SHARDS = 64;
const DEFAULTS = { enabled: 'enabled', disabled: 'disabled', alwaysEnabled: 'always enabled', alwaysDisabled: 'always disabled' };
const CHANGE_TIMES = { read: 'the next time it is checked', moduleReload: 'when the binary is reloaded', session: 'at the next sign-in', reboot: 'after a reboot' };
const CHANGE_SHORT = { read: 'on read', moduleReload: 'on reload', session: 'on sign-in', reboot: 'on reboot' };

let index = null;
let firstSeen = null;
const buildCache = new Map();
const detailCache = new Map();
const detailTextCache = new Map();

const $ = (id) => document.getElementById(id);
const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));

async function getJson(path) {
  const res = await fetch(DATA + path, { cache: 'no-cache' });
  if (!res.ok) throw new Error(path + ': HTTP ' + res.status);
  return res.json();
}

function loadBuild(key) {
  if (!buildCache.has(key)) buildCache.set(key, getJson('builds/' + encodeURIComponent(key) + '.json'));
  return buildCache.get(key);
}

// Usage details (what each binary's code reveals about a feature) are split into shards by ID; a missing shard means no details
function loadShard(arch, n) {
  const path = `details/${encodeURIComponent(arch)}/${String(n).padStart(2, '0')}.json`;
  if (!detailCache.has(path)) detailCache.set(path, getJson(path).catch(() => ({})));
  return detailCache.get(path);
}

async function loadDetails(arch, id) {
  return (await loadShard(arch, id % DETAIL_SHARDS))[String(id)] || null;
}

// All details of an architecture as searchable text, for "Search code details"
function loadDetailText(arch) {
  if (!detailTextCache.has(arch)) {
    detailTextCache.set(arch, Promise.all([...Array(DETAIL_SHARDS).keys()].map((n) => loadShard(arch, n))).then((shards) => {
      const text = new Map();
      for (const shard of shards) {
        for (const [id, d] of Object.entries(shard)) {
          const parts = [];
          for (const u of Object.values(d.usage)) for (const k of ['callers', 'strings', 'sources', 'imports', 'symbols', 'calls', 'tables']) parts.push(...(u[k] || []));
          text.set(Number(id), parts.join('\n').toLowerCase());
        }
      }
      return text;
    }));
  }
  return detailTextCache.get(arch);
}

function compareVersions(a, b) {
  const pa = a.build.split('.').map(Number), pb = b.build.split('.').map(Number);
  for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
    const d = (pa[i] || 0) - (pb[i] || 0);
    if (d) return d;
  }
  return 0;
}

function buildLabel(b) {
  return `${b.build} ${b.architecture}${b.displayVersion ? ' (' + b.displayVersion + ')' : ''}`;
}

// Builds grouped by architecture and display version (e.g. 25H2), newest first
function fillBuildSelect(select, selectedKey) {
  const groups = new Map();
  [...index.builds].sort((a, b) => compareVersions(b, a)).forEach((b) => {
    const g = `${b.architecture} — ${b.displayVersion || 'unknown version'}`;
    if (!groups.has(g)) groups.set(g, []);
    groups.get(g).push(b);
  });
  select.innerHTML = '';
  for (const [g, builds] of groups) {
    const og = document.createElement('optgroup');
    og.label = g;
    for (const b of builds) {
      const o = document.createElement('option');
      o.value = b.key;
      o.textContent = `${buildLabel(b)} — ${b.features} IDs, ${b.named} named`;
      og.appendChild(o);
    }
    select.appendChild(og);
  }
  if (selectedKey) select.value = selectedKey;
}

function latestBuild(arch) {
  const list = index.builds.filter((b) => !arch || b.architecture === arch).sort(compareVersions);
  return list[list.length - 1];
}

function firstSeenText(arch, id) {
  const key = firstSeen.firstSeen[arch] && firstSeen.firstSeen[arch][String(id)];
  if (!key) return '';
  return key === firstSeen.firstTrackedBuild[arch] ? `≤ ${key}` : key;
}

function storeText(store) {
  if (!store) return '';
  return store.map((c) => [c.state, c.priority, c.type, c.variant ? 'variant ' + c.variant : ''].filter(Boolean).join(', ')).join('; ');
}

const stateText = (f) => [DEFAULTS[f.default], CHANGE_SHORT[f.changeTime]].filter(Boolean).join(', ');

function matches(f, q, namedOnly) {
  if (namedOnly && !f.name) return false;
  if (!q) return true;
  if (String(f.id).includes(q)) return true;
  if (f.name && f.name.toLowerCase().includes(q)) return true;
  if (f.oldName && f.oldName.toLowerCase().includes(q)) return true;
  if (f.newName && f.newName.toLowerCase().includes(q)) return true;
  return (f.modules || []).some((m) => m.toLowerCase().includes(q));
}

// Renders a sortable table with incremental "show more". With detail (an async function returning HTML), clicking a row shows it below the row.
function renderTable(container, rows, columns, defaultSort, detail) {
  let sort = defaultSort || { col: 0, dir: 1 };
  let shown = PAGE;
  const wrap = document.createElement('div');
  container.appendChild(wrap);
  const draw = () => {
    const col = columns[sort.col];
    const key = col.sortKey || col.value;
    const sorted = [...rows].sort((a, b) => {
      const x = key(a), y = key(b);
      if (x === y) return a.id - b.id;
      if (x === '' || x === null || x === undefined) return 1;
      if (y === '' || y === null || y === undefined) return -1;
      return (x < y ? -1 : 1) * sort.dir;
    });
    let html = '<div class="table-wrap"><table><thead><tr>';
    columns.forEach((c, i) => {
      html += `<th data-col="${i}">${esc(c.title)}${i === sort.col ? (sort.dir > 0 ? ' ▲' : ' ▼') : ''}</th>`;
    });
    html += '</tr></thead><tbody>';
    sorted.slice(0, shown).forEach((r, i) => {
      html += (detail ? `<tr class="clickable" data-i="${i}" title="Show details">` : '<tr>') +
        columns.map((c) => `<td class="${c.cls || ''}">${c.html ? c.html(r) : esc(c.value(r) ?? '')}</td>`).join('') + '</tr>';
    });
    html += '</tbody></table></div>';
    if (sorted.length > shown) html += `<button class="more" type="button">Show more (${sorted.length - shown} remaining)</button>`;
    wrap.innerHTML = html;
    wrap.querySelectorAll('th').forEach((th) => th.addEventListener('click', () => {
      const i = Number(th.dataset.col);
      sort = { col: i, dir: sort.col === i ? -sort.dir : 1 };
      draw();
    }));
    const more = wrap.querySelector('.more');
    if (more) more.addEventListener('click', () => { shown += PAGE * 4; draw(); });
    if (detail) wrap.querySelectorAll('tr.clickable').forEach((tr) => tr.addEventListener('click', () => {
      const next = tr.nextElementSibling;
      if (next && next.classList.contains('detail')) { next.remove(); return; }
      const d = document.createElement('tr');
      d.className = 'detail';
      d.innerHTML = `<td colspan="${columns.length}"><div class="detail-body">Loading…</div></td>`;
      tr.after(d);
      const body = d.querySelector('.detail-body');
      detail(sorted[Number(tr.dataset.i)]).then((h) => { body.innerHTML = h; }, (e) => { body.textContent = 'Error: ' + e.message; });
    }));
  };
  draw();
}

// ---------------------------------------------------------------------------
// Feature details
// ---------------------------------------------------------------------------

const USE_TEXT = {
  checked: (u) => `checked in ${u.callerCount} function${u.callerCount === 1 ? '' : 's'}`,
  required: () => 'only checked as a requirement of other features',
  table: (u) => `only listed in a lookup table (${(u.tables || []).join(', ')})`,
  unreferenced: () => 'has the feature\'s plumbing, but no code using it was found',
};

function moduleDetail(mod, u) {
  const list = (title, items, more) => (items && items.length
    ? `<div class="kv"><span>${title}</span><ul>${items.map((x) => `<li>${esc(x)}</li>`).join('')}${more ? `<li class="muted">and ${more} more</li>` : ''}</ul></div>` : '');
  return `<div class="mod"><h4>${esc(mod)} <span class="muted">${esc((USE_TEXT[u.use] || (() => u.use))(u))}</span></h4>` +
    list('Checked in', u.callers, (u.callerCount || 0) - (u.callers || []).length) +
    list('Strings', u.strings) + list('Source files', u.sources) + list('Imports used', u.imports) +
    list('Data referenced', u.symbols) + list('Also calls', u.calls) + '</div>';
}

// Returns the detail function for rows of one build: default state, dependencies, and per-binary usage details
function featureDetail(build) {
  const byId = new Map(build.features.map((f) => [f.id, f]));
  const requiredBy = new Map();
  for (const f of build.features) {
    for (const r of f.requires || []) {
      if (!requiredBy.has(r)) requiredBy.set(r, []);
      requiredBy.get(r).push(f.id);
    }
  }
  const link = (id) => {
    const f = byId.get(id);
    return `<a href="#" class="feat-link" data-id="${id}" data-build="${esc(build.key)}">${id}</a>${f && f.name ? ' ' + esc(f.name) : ''}`;
  };
  return async (row) => {
    const f = byId.get(row.id) || row;
    const parts = [];
    if (f.default || f.changeTime) {
      const def = f.default ? DEFAULTS[f.default] + (f.default.startsWith('always') ? '' : ' by default') : '';
      const when = f.changeTime ? 'changes take effect ' + CHANGE_TIMES[f.changeTime] : '';
      parts.push(`<p><b>Default:</b> ${esc([def, when].filter(Boolean).join('; '))}</p>`);
    }
    if ((f.requires || []).length) parts.push(`<p><b>Requires:</b> ${f.requires.map(link).join(', ')}</p>`);
    if (requiredBy.has(f.id)) parts.push(`<p><b>Required by:</b> ${requiredBy.get(f.id).map(link).join(', ')}</p>`);
    const det = await loadDetails(build.architecture, f.id);
    if (det) {
      parts.push(...Object.entries(det.usage).map(([mod, u]) => moduleDetail(mod, u)));
      if (det.build !== build.key) parts.push(`<p class="muted">Code details are from build ${esc(det.build)}.</p>`);
    }
    if ((f.declaredIn || []).length) {
      parts.push(`<p class="muted"><b>Declared only</b> (the ID is in the symbols, but the binary has no code for it) in: ${f.declaredIn.map(esc).join(', ')}</p>`);
    }
    return parts.join('') || '<p class="muted">Nothing more is known about this feature.</p>';
  };
}

const nameCell = (f) => (f.name ? esc(f.name) : '<span class="unnamed">unnamed</span>') +
  (f.unverified ? ' <span class="unverified" title="This build\'s symbols for its binary couldn\'t be downloaded; known from an earlier version of the binary">unverified</span>' : '');
const modsText = (f) => (f.modules || []).join(', ');

// ---------------------------------------------------------------------------
// Compare view
// ---------------------------------------------------------------------------

async function renderCompare() {
  const oldKey = $('cmp-old').value, newKey = $('cmp-new').value;
  const q = $('cmp-search').value.trim().toLowerCase();
  const namedOnly = $('cmp-named').checked;
  const out = $('cmp-results');
  setHash(`compare/${oldKey}/${newKey}`);
  if (!oldKey || !newKey) return;
  $('cmp-status').textContent = 'Loading…';
  out.innerHTML = '';
  const [a, b] = await Promise.all([loadBuild(oldKey), loadBuild(newKey)]);
  const of = new Map(a.features.map((f) => [f.id, f])), nf = new Map(b.features.map((f) => [f.id, f]));
  const added = [], removed = [], renamed = [], newlyNamed = [], nameLost = [], storeChanged = [], defaultChanged = [];
  for (const [id, f] of nf) {
    const o = of.get(id);
    if (!o) { added.push(f); continue; }
    if (o.name !== f.name) {
      if (!o.name) newlyNamed.push(f);
      else if (f.name) renamed.push({ id, oldName: o.name, newName: f.name, name: f.name, modules: f.modules });
      else nameLost.push({ id, oldName: o.name, name: o.name, modules: o.modules });
    }
    if (JSON.stringify(o.store || null) !== JSON.stringify(f.store || null)) {
      storeChanged.push({ id, name: f.name || o.name, modules: f.modules, oldStore: o.store, newStore: f.store });
    }
    // Only where both builds know the value; builds scanned before default states were read don't have them
    const known = ['default', 'changeTime'].filter((k) => o[k] && f[k]);
    if (known.some((k) => o[k] !== f[k])) {
      const pick = (x) => Object.fromEntries(known.map((k) => [k, x[k]]));
      defaultChanged.push({ id, name: f.name || o.name, modules: f.modules, oldState: pick(o), newState: pick(f) });
    }
  }
  for (const [id, f] of of) if (!nf.has(id)) removed.push(f);

  const arch = b.architecture;
  const sections = [
    ['Added', 'added', added, [
      { title: 'ID', value: (f) => f.id, cls: 'id' },
      { title: 'Name', value: (f) => f.name, html: nameCell, cls: 'name' },
      { title: 'Feature store', value: (f) => storeText(f.store), cls: 'store' },
      { title: 'Modules', value: modsText, cls: 'mods' },
    ]],
    ['Removed', 'removed', removed, [
      { title: 'ID', value: (f) => f.id, cls: 'id' },
      { title: 'Name', value: (f) => f.name, html: nameCell, cls: 'name' },
      { title: 'First seen', value: (f) => firstSeenText(a.architecture, f.id), cls: 'seen' },
      { title: 'Modules', value: modsText, cls: 'mods' },
    ]],
    ['Renamed', 'changed', renamed, [
      { title: 'ID', value: (f) => f.id, cls: 'id' },
      { title: 'Old name', value: (f) => f.oldName, cls: 'name' },
      { title: 'New name', value: (f) => f.newName, cls: 'name' },
    ]],
    ['Newly named', 'changed', newlyNamed, [
      { title: 'ID', value: (f) => f.id, cls: 'id' },
      { title: 'Name', value: (f) => f.name, cls: 'name' },
      { title: 'First seen', value: (f) => firstSeenText(arch, f.id), cls: 'seen' },
      { title: 'Modules', value: modsText, cls: 'mods' },
    ]],
    ...(nameLost.length ? [['Name lost', 'changed', nameLost, [
      { title: 'ID', value: (f) => f.id, cls: 'id' },
      { title: 'Old name', value: (f) => f.oldName, cls: 'name' },
      { title: 'Old modules', value: modsText, cls: 'mods' },
    ]]] : []),
    ['Feature store changes', 'changed', storeChanged, [
      { title: 'ID', value: (f) => f.id, cls: 'id' },
      { title: 'Name', value: (f) => f.name, html: nameCell, cls: 'name' },
      { title: 'Old', value: (f) => storeText(f.oldStore) || '(not configured)', cls: 'store' },
      { title: 'New', value: (f) => storeText(f.newStore) || '(not configured)', cls: 'store' },
    ]],
    ['Default changed', 'changed', defaultChanged, [
      { title: 'ID', value: (f) => f.id, cls: 'id' },
      { title: 'Name', value: (f) => f.name, html: nameCell, cls: 'name' },
      { title: 'Old', value: (f) => stateText(f.oldState), cls: 'store' },
      { title: 'New', value: (f) => stateText(f.newState), cls: 'store' },
    ]],
  ];
  const detailOld = featureDetail(a), detailNew = featureDetail(b);
  const direction = compareVersions(a, b) > 0 ? ' (the "old" build is newer than the "new" one)' : '';
  $('cmp-status').textContent = `${buildLabel(a)} → ${buildLabel(b)}${direction}`;
  for (const [title, cls, rows, cols] of sections) {
    const filtered = rows.filter((f) => matches(f, q, namedOnly));
    const h = document.createElement('h2');
    h.className = cls;
    h.innerHTML = `${esc(title)} <span class="count">${filtered.length}${filtered.length !== rows.length ? ' of ' + rows.length : ''}</span>`;
    out.appendChild(h);
    if (filtered.length) renderTable(out, filtered, cols, undefined, title === 'Removed' ? detailOld : detailNew);
  }
}

// ---------------------------------------------------------------------------
// Browse view
// ---------------------------------------------------------------------------

let buildRender = 0;

async function renderBuild() {
  const key = $('bld-select').value;
  const q = $('bld-search').value.trim().toLowerCase();
  const namedOnly = $('bld-named').checked, storeOnly = $('bld-store').checked, newOnly = $('bld-new').checked;
  const searchDetails = $('bld-details').checked;
  const out = $('bld-results');
  setHash(`build/${key}`);
  if (!key) return;
  const render = ++buildRender;  // A slower earlier render must not overwrite a newer one
  $('bld-status').textContent = searchDetails && q ? 'Loading code details…' : 'Loading…';
  out.innerHTML = '';
  const b = await loadBuild(key);
  const arch = b.architecture;
  const detailText = searchDetails && q ? await loadDetailText(arch) : null;
  if (render !== buildRender) return;
  const seen = firstSeen.firstSeen[arch] || {};
  const hit = (f) => matches(f, q, namedOnly) || (detailText !== null && (!namedOnly || f.name) && (detailText.get(f.id) || '').includes(q));
  const rows = b.features.filter((f) => hit(f) && (!storeOnly || f.store) && (!newOnly || seen[String(f.id)] === key));
  const firstTracked = firstSeen.firstTrackedBuild[arch] === key;
  $('bld-status').textContent = `${buildLabel(b)}: ${b.features.length} feature IDs, ${b.features.filter((f) => f.name).length} named, ` +
    `${b.features.filter((f) => f.store).length} in the feature store. Showing ${rows.length}.` +
    (newOnly && firstTracked ? ' This is the first tracked build, so every ID counts as new here.' : '');
  renderTable(out, rows, [
    { title: 'ID', value: (f) => f.id, cls: 'id' },
    { title: 'Name', value: (f) => f.name, html: nameCell, cls: 'name' },
    { title: 'Default', value: (f) => DEFAULTS[f.default] || '', cls: 'store' },
    { title: 'First seen', value: (f) => firstSeenText(arch, f.id), sortKey: (f) => seen[String(f.id)] || '', cls: 'seen' },
    { title: 'Feature store', value: (f) => storeText(f.store), cls: 'store' },
    { title: 'Modules', value: modsText, cls: 'mods' },
  ], undefined, featureDetail(b));
}

// ---------------------------------------------------------------------------
// Routing
// ---------------------------------------------------------------------------

// replaceState doesn't fire hashchange, so this only records state; back/forward and pasted links go through route()
function setHash(h) {
  if (location.hash.slice(1) !== h) history.replaceState(null, '', '#' + h);
}

function showView(view) {
  for (const v of ['compare', 'build']) $('view-' + v).hidden = v !== view;
  document.querySelectorAll('nav a').forEach((a) => a.classList.toggle('active', a.dataset.view === view));
}

function route() {
  const parts = location.hash.slice(1).split('/').map(decodeURIComponent);
  const view = parts[0] === 'build' ? 'build' : 'compare';
  showView(view);
  const known = (k) => index.builds.some((b) => b.key === k);
  if (view === 'build') {
    if (known(parts[1])) $('bld-select').value = parts[1];
    renderBuild().catch(showError('bld-status'));
  } else {
    if (known(parts[1])) $('cmp-old').value = parts[1];
    if (known(parts[2])) $('cmp-new').value = parts[2];
    renderCompare().catch(showError('cmp-status'));
  }
}

const showError = (id) => (e) => { $(id).textContent = 'Error: ' + e.message; };

function debounce(fn, ms) {
  let t;
  return () => { clearTimeout(t); t = setTimeout(fn, ms); };
}

async function init() {
  try {
    [index, firstSeen] = await Promise.all([getJson('index.json'), getJson('first-seen.json')]);
  } catch (e) {
    $('cmp-status').textContent = 'Could not load data: ' + e.message;
    showView('compare');
    return;
  }
  if (!index.builds.length) {
    $('cmp-status').textContent = 'No builds have been scanned yet.';
    showView('compare');
    return;
  }
  const latest = latestBuild();
  const prevKey = latest.previous || latest.key;
  fillBuildSelect($('cmp-old'), prevKey);
  fillBuildSelect($('cmp-new'), latest.key);
  fillBuildSelect($('bld-select'), latest.key);

  const cmp = () => renderCompare().catch(showError('cmp-status'));
  const bld = () => renderBuild().catch(showError('bld-status'));
  $('cmp-old').addEventListener('change', cmp);
  $('cmp-new').addEventListener('change', cmp);
  $('cmp-named').addEventListener('change', cmp);
  $('cmp-search').addEventListener('input', debounce(cmp, 250));
  $('cmp-swap').addEventListener('click', () => {
    const o = $('cmp-old').value;
    $('cmp-old').value = $('cmp-new').value;
    $('cmp-new').value = o;
    cmp();
  });
  for (const id of ['bld-select', 'bld-named', 'bld-store', 'bld-new', 'bld-details']) $(id).addEventListener('change', bld);
  $('bld-search').addEventListener('input', debounce(bld, 250));
  document.querySelectorAll('nav a').forEach((a) => a.addEventListener('click', (e) => {
    e.preventDefault();
    const v = a.dataset.view;
    setHash(v === 'build' ? `build/${$('bld-select').value}` : `compare/${$('cmp-old').value}/${$('cmp-new').value}`);
    route();
  }));
  // Links to other features in the details panels open that feature in its build
  document.addEventListener('click', (e) => {
    const a = e.target.closest('a.feat-link');
    if (!a) return;
    e.preventDefault();
    $('bld-search').value = a.dataset.id;
    setHash(`build/${a.dataset.build}`);
    route();
  });
  window.addEventListener('hashchange', route);
  route();
}

init();
