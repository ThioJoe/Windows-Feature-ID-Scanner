// Windows Feature IDs browser. Loads data/index.json, then individual build files on demand.
'use strict';

const DATA = 'data/';
const PAGE = 500;
const NUMERIC = /^(?:ID|FI)?\d+$/;

let index = null;
let firstSeen = null;
const buildCache = new Map();

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

function matches(f, q, namedOnly) {
  if (namedOnly && !f.name) return false;
  if (!q) return true;
  if (String(f.id).includes(q)) return true;
  if (f.name && f.name.toLowerCase().includes(q)) return true;
  if (f.oldName && f.oldName.toLowerCase().includes(q)) return true;
  if (f.newName && f.newName.toLowerCase().includes(q)) return true;
  return (f.modules || []).some((m) => m.toLowerCase().includes(q));
}

// Renders a sortable table with incremental "show more"
function renderTable(container, rows, columns, defaultSort) {
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
    for (const r of sorted.slice(0, shown)) {
      html += '<tr>' + columns.map((c) => `<td class="${c.cls || ''}">${c.html ? c.html(r) : esc(c.value(r) ?? '')}</td>`).join('') + '</tr>';
    }
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
  };
  draw();
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
  const added = [], removed = [], renamed = [], newlyNamed = [], storeChanged = [];
  for (const [id, f] of nf) {
    const o = of.get(id);
    if (!o) { added.push(f); continue; }
    if (o.name !== f.name) {
      if (!o.name) newlyNamed.push(f);
      else if (f.name) renamed.push({ id, oldName: o.name, newName: f.name, name: f.name, modules: f.modules });
    }
    if (JSON.stringify(o.store || null) !== JSON.stringify(f.store || null)) {
      storeChanged.push({ id, name: f.name || o.name, modules: f.modules, oldStore: o.store, newStore: f.store });
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
    ['Feature store changes', 'changed', storeChanged, [
      { title: 'ID', value: (f) => f.id, cls: 'id' },
      { title: 'Name', value: (f) => f.name, html: nameCell, cls: 'name' },
      { title: 'Old', value: (f) => storeText(f.oldStore) || '(not configured)', cls: 'store' },
      { title: 'New', value: (f) => storeText(f.newStore) || '(not configured)', cls: 'store' },
    ]],
  ];
  const direction = compareVersions(a, b) > 0 ? ' (the "old" build is newer than the "new" one)' : '';
  $('cmp-status').textContent = `${buildLabel(a)} → ${buildLabel(b)}${direction}`;
  for (const [title, cls, rows, cols] of sections) {
    const filtered = rows.filter((f) => matches(f, q, namedOnly));
    const h = document.createElement('h2');
    h.className = cls;
    h.innerHTML = `${esc(title)} <span class="count">${filtered.length}${filtered.length !== rows.length ? ' of ' + rows.length : ''}</span>`;
    out.appendChild(h);
    if (filtered.length) renderTable(out, filtered, cols);
  }
}

// ---------------------------------------------------------------------------
// Browse view
// ---------------------------------------------------------------------------

async function renderBuild() {
  const key = $('bld-select').value;
  const q = $('bld-search').value.trim().toLowerCase();
  const namedOnly = $('bld-named').checked, storeOnly = $('bld-store').checked, newOnly = $('bld-new').checked;
  const out = $('bld-results');
  setHash(`build/${key}`);
  if (!key) return;
  $('bld-status').textContent = 'Loading…';
  out.innerHTML = '';
  const b = await loadBuild(key);
  const arch = b.architecture;
  const seen = firstSeen.firstSeen[arch] || {};
  const rows = b.features.filter((f) => matches(f, q, namedOnly) && (!storeOnly || f.store) && (!newOnly || seen[String(f.id)] === key));
  const firstTracked = firstSeen.firstTrackedBuild[arch] === key;
  $('bld-status').textContent = `${buildLabel(b)}: ${b.features.length} feature IDs, ${b.features.filter((f) => f.name).length} named, ` +
    `${b.features.filter((f) => f.store).length} in the feature store. Showing ${rows.length}.` +
    (newOnly && firstTracked ? ' This is the first tracked build, so every ID counts as new here.' : '');
  renderTable(out, rows, [
    { title: 'ID', value: (f) => f.id, cls: 'id' },
    { title: 'Name', value: (f) => f.name, html: nameCell, cls: 'name' },
    { title: 'First seen', value: (f) => firstSeenText(arch, f.id), sortKey: (f) => seen[String(f.id)] || '', cls: 'seen' },
    { title: 'Feature store', value: (f) => storeText(f.store), cls: 'store' },
    { title: 'Modules', value: modsText, cls: 'mods' },
  ]);
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
  for (const id of ['bld-select', 'bld-named', 'bld-store', 'bld-new']) $(id).addEventListener('change', bld);
  $('bld-search').addEventListener('input', debounce(bld, 250));
  document.querySelectorAll('nav a').forEach((a) => a.addEventListener('click', (e) => {
    e.preventDefault();
    const v = a.dataset.view;
    setHash(v === 'build' ? `build/${$('bld-select').value}` : `compare/${$('cmp-old').value}/${$('cmp-new').value}`);
    route();
  }));
  window.addEventListener('hashchange', route);
  route();
}

init();
