// Windows Feature IDs browser. Loads data/index.json, then individual build files on demand.
'use strict';

const DATA = 'data/';
const DERIVED = 'derived/';  // Files build-site-data.py derives from data/ when the site is published
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
const fmt = (n) => Number(n).toLocaleString('en-US');
// A feature's address: its build's view, searched for the feature's ID (so a link to it also works in a new tab)
const featureHref = (buildKey, id) => `#build/${encodeURIComponent(buildKey)}/${id}`;

// What the site calls the architectures of the data (PROCESSOR_ARCHITECTURE values)
const ARCH_NAMES = { AMD64: 'x64' };
const archName = (a) => ARCH_NAMES[a] || a;

// Sections the user collapsed, kept in the browser so they stay collapsed after a reload (where storage works)
const collapsed = new Set((() => {
  try { return JSON.parse(localStorage.getItem('collapsed') || '[]'); } catch (e) { return []; }
})());
function setCollapsed(id, value) {
  if (value) collapsed.add(id); else collapsed.delete(id);
  try { localStorage.setItem('collapsed', JSON.stringify([...collapsed])); } catch (e) { /* storage blocked */ }
}

// A heading whose content can be collapsed (a <details>); returns the element to put the content in. Without content, only the heading.
function section(container, id, level, cls, headingHtml, hasContent = true) {
  const heading = `<${level} class="${cls}">${headingHtml}</${level}>`;
  if (!hasContent) {
    const h = document.createElement('div');
    h.className = 'section-head';
    h.innerHTML = heading;
    container.appendChild(h);
    return h;
  }
  const d = document.createElement('details');
  d.className = 'section';
  d.open = !collapsed.has(id);
  d.innerHTML = `<summary class="section-head">${heading}</summary>`;
  d.addEventListener('toggle', () => setCollapsed(id, !d.open));
  container.appendChild(d);
  return d;
}

async function getJson(path, root = DATA) {
  const res = await fetch(root + path, { cache: 'no-cache' });
  if (!res.ok) throw new Error(path + ': HTTP ' + res.status);
  return res.json();
}

function loadBuild(key) {
  if (!buildCache.has(key)) buildCache.set(key, getJson('builds/' + encodeURIComponent(key) + '/features.json'));
  return buildCache.get(key);
}

// Usage details (what each binary's code reveals about a feature), from the newest build that has them, split into shards by ID
// when the site is published (data/ has a file per build); a missing shard means no details
function loadShard(arch, n) {
  const path = `details/${encodeURIComponent(arch)}/${String(n).padStart(2, '0')}.json`;
  if (!detailCache.has(path)) detailCache.set(path, getJson(path, DERIVED).catch(() => ({})));
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

// What a build is a build of: its display version (e.g. 25H2), or its Windows Insider channel
const versionText = (b) => (b.insiderChannel ? `Insider ${b.insiderChannel}` : b.displayVersion);

function buildLabel(b) {
  return `${b.build} ${archName(b.architecture)}${versionText(b) ? ' (' + versionText(b) + ')' : ''}`;
}

// ---------------------------------------------------------------------------
// Build picker
// ---------------------------------------------------------------------------

// Used like a <select> (a value, and a change event when the user picks something), but its list can have sections within sections,
// which a select can't: setSections([{ label, note, groups: [{ label, items: [{ value, text, tag, meta, label }] }] }]), where text is
// what typing jumps to and label the HTML the button shows. The sections are side by side, a column each (stacked on a narrow screen).
// The list works like a listbox: arrow keys (left and right to the next column), Home/End, Page Up/Down, Enter or Space to pick,
// Escape to close, and typing the start of a build number.
class BuildPicker extends HTMLElement {
  connectedCallback() {
    if (this.button) return;
    this.items = [];
    this.current = '';
    this.typed = '';
    this.innerHTML = `<button type="button" class="picker-button" aria-haspopup="listbox" aria-expanded="false" aria-controls="${this.id}-list">` +
      `<span class="picker-value" id="${this.id}-value"></span><span class="picker-chevron" aria-hidden="true"></span></button>` +
      `<div class="picker-list" id="${this.id}-list" role="listbox" tabindex="-1" hidden></div>`;
    this.button = this.firstElementChild;
    this.list = this.lastElementChild;
    if (this.dataset.label) {
      this.button.setAttribute('aria-labelledby', `${this.dataset.label} ${this.id}-value`);
      this.list.setAttribute('aria-labelledby', this.dataset.label);
    }
    this.button.addEventListener('click', () => (this.list.hidden ? this.open() : this.close(true)));
    this.button.addEventListener('keydown', (e) => {
      if (e.key === 'ArrowDown' || e.key === 'ArrowUp') { e.preventDefault(); this.open(); }
    });
    this.list.addEventListener('keydown', (e) => this.onKey(e));
    this.list.addEventListener('click', (e) => {
      const o = e.target.closest('[role=option]');
      if (o) this.pick(o.dataset.value);
    });
    this.list.addEventListener('mousemove', (e) => {
      const o = e.target.closest('[role=option]');
      if (o && o !== this.active) this.setActive(o, 'none');
    });
    // Closes when focus moves elsewhere (Tab, a click outside), or on a tap outside, which doesn't move focus on every phone
    this.addEventListener('focusout', (e) => { if (!this.contains(e.relatedTarget)) this.close(false); });
    document.addEventListener('pointerdown', (e) => { if (!this.contains(e.target)) this.close(false); });
  }

  get value() { return this.current; }

  set value(v) {
    const item = this.items.find((x) => x.value === v);
    this.current = item ? v : '';
    this.button.querySelector('.picker-value').innerHTML = item ? item.label : '';
    for (const o of this.list.querySelectorAll('[role=option]')) o.setAttribute('aria-selected', String(o.dataset.value === this.current));
  }

  setSections(sections, footer = '') {
    this.items = [];
    let html = '<div class="picker-columns">';
    for (const s of sections) {
      html += `<div class="picker-section"><div class="picker-section-label" aria-hidden="true">${esc(s.label)}${s.note ? ` <span>${esc(s.note)}</span>` : ''}</div>`;
      for (const g of s.groups) {
        html += `<div role="group" aria-label="${esc(s.label + ' ' + g.label)}"><div class="picker-group-label" aria-hidden="true">${esc(g.label)}</div>`;
        for (const it of g.items) {
          html += `<div class="picker-option" role="option" id="${this.id}-o${this.items.length}" data-value="${esc(it.value)}" ` +
            `data-text="${esc(it.text.toLowerCase())}" aria-selected="false"><span class="picker-main">${esc(it.text)}</span>` +
            `${it.tag ? `<span class="picker-tag"${it.tagTitle ? ` title="${esc(it.tagTitle)}"` : ''}>${esc(it.tag)}</span>` : ''}` +
            `${it.meta ? `<span class="picker-meta">${esc(it.meta)}</span>` : ''}</div>`;
          this.items.push(it);
        }
        html += '</div>';
      }
      html += '</div>';
    }
    html += '</div>';
    if (footer) html += `<div class="picker-footer" aria-hidden="true">${footer}</div>`;
    this.list.innerHTML = html;
    this.active = null;
    this.value = this.items.some((x) => x.value === this.current) ? this.current : (this.items.length ? this.items[0].value : '');
  }

  option(value) {
    return [...this.list.querySelectorAll('[role=option]')].find((o) => o.dataset.value === value);
  }

  open() {
    if (!this.list.hidden || !this.items.length) return;
    this.list.hidden = false;
    this.button.setAttribute('aria-expanded', 'true');
    // The list can be wider than the button: keep it inside the window
    this.list.style.left = '0px';
    const room = document.documentElement.clientWidth - 8, left = this.getBoundingClientRect().left, width = this.list.offsetWidth;
    if (left + width > room) this.list.style.left = Math.max(8 - left, room - width - left) + 'px';
    this.setActive(this.option(this.current) || this.list.querySelector('[role=option]'), 'center');
    this.list.focus({ preventScroll: true });
  }

  close(focusButton) {
    if (this.list.hidden) return;
    this.list.hidden = true;
    this.button.setAttribute('aria-expanded', 'false');
    if (focusButton) this.button.focus();
  }

  pick(value) {
    this.close(true);
    if (value === this.current) return;
    this.value = value;
    this.dispatchEvent(new Event('change', { bubbles: true }));
  }

  // scroll: 'center' (on opening), 'nearest' (keys) or 'none' (the mouse)
  setActive(o, scroll = 'nearest') {
    if (!o) return;
    if (this.active) this.active.classList.remove('active');
    this.active = o;
    o.classList.add('active');
    this.list.setAttribute('aria-activedescendant', o.id);
    if (scroll === 'center') this.list.scrollTop = o.offsetTop - (this.list.clientHeight - o.offsetHeight) / 2;
    else if (scroll === 'nearest') o.scrollIntoView({ block: 'nearest' });
  }

  onKey(e) {
    const opts = [...this.list.querySelectorAll('[role=option]')];
    const i = opts.indexOf(this.active);
    const go = (n) => { e.preventDefault(); this.setActive(opts[Math.max(0, Math.min(opts.length - 1, n))]); };
    switch (e.key) {
      case 'ArrowDown': return go(i + 1);
      case 'ArrowUp': return go(i - 1);
      case 'Home': return go(0);
      case 'End': return go(opts.length - 1);
      case 'PageDown': return go(i + 10);
      case 'PageUp': return go(i - 10);
      case 'ArrowLeft':
      case 'ArrowRight': {
        // The option nearest the same height in the column to the left or right
        if (!this.active) return;
        const columns = [...this.list.querySelectorAll('.picker-section')];
        const next = columns[columns.indexOf(this.active.closest('.picker-section')) + (e.key === 'ArrowRight' ? 1 : -1)];
        if (!next) return;
        e.preventDefault();
        const y = this.active.getBoundingClientRect().top, dy = (o) => Math.abs(o.getBoundingClientRect().top - y);
        this.setActive([...next.querySelectorAll('[role=option]')].reduce((a, b) => (dy(b) < dy(a) ? b : a)));
        return;
      }
      case 'Enter':
      case ' ':
        e.preventDefault();
        if (this.active) this.pick(this.active.dataset.value);
        return;
      case 'Escape':
        e.preventDefault();
        this.close(true);
        return;
    }
    // Typing jumps to the first build that starts with what was typed
    if (e.key.length === 1 && !e.ctrlKey && !e.metaKey && !e.altKey) {
      clearTimeout(this.typedTimer);
      this.typed += e.key.toLowerCase();
      this.typedTimer = setTimeout(() => { this.typed = ''; }, 800);
      const hit = opts.find((o) => o.dataset.text.startsWith(this.typed));
      if (hit) { e.preventDefault(); this.setActive(hit); }
    }
  }
}
customElements.define('build-picker', BuildPicker);

// Microsoft's labels for its updates: the year and month of the release, then which kind it is
// (https://learn.microsoft.com/windows/deployment/update/release-cycle)
const UPDATE_TYPES = {
  B: 'Monthly security update, released the second Tuesday of the month',
  D: 'Optional non-security preview, released the fourth week of the month',
  OOB: "Out-of-band update, released when a fix can't wait for the next monthly update",
};
const updateTypeTitle = (type) => UPDATE_TYPES[String(type || '').split(' ').pop()] || '';
const UPDATE_TYPES_LEGEND = '<b>B</b> monthly security update (second Tuesday) · <b>D</b> optional preview (fourth week) · <b>OOB</b> out-of-band';

// A build's update (e.g. 2026-10 B), shown in the build picker: stored with the build (data/index.json), else from the list of released
// builds, which has Insider builds' release dates instead
function releaseTag(b) {
  if (b.release && b.release.type) return b.release.type;
  if (!releases) return '';
  for (const v of releases.windows11) for (const r of v.releases) if (r.build === b.build) return r.type || '';
  for (const c of releases.insider) for (const r of c.releases) if ((r.builds || [r.build]).includes(b.build)) return r.date || '';
  return '';
}

// Builds by architecture (x64 first, a column each), then by Windows version, newest first (Insider channels after the released versions)
function fillBuildPicker(picker, selectedKey) {
  const archs = new Map();
  for (const b of [...index.builds].sort((x, y) => compareVersions(y, x))) {
    if (!archs.has(b.architecture)) archs.set(b.architecture, new Map());
    const groups = archs.get(b.architecture), g = versionText(b) || 'Other';
    if (!groups.has(g)) groups.set(g, []);
    groups.get(g).push(b);
  }
  const archOrder = (a) => (a === 'AMD64' ? 0 : 1);
  const insider = (builds) => (builds[0].insiderChannel ? 1 : 0);
  picker.setSections([...archs].sort(([x], [y]) => archOrder(x) - archOrder(y) || x.localeCompare(y)).map(([arch, groups]) => ({
    label: archName(arch),
    note: archName(arch) !== arch ? arch : '',
    groups: [...groups].sort(([, x], [, y]) => insider(x) - insider(y)).map(([label, builds]) => ({
      label,
      items: builds.map((b) => ({
        value: b.key,
        text: b.build,
        tag: releaseTag(b),
        tagTitle: [b.release && [b.release.date, b.release.kb].filter(Boolean).join(' · '), updateTypeTitle(releaseTag(b))].filter(Boolean).join('\n'),
        label: `<span class="picker-main">${esc(b.build)}</span>` +
          `<span class="picker-sub">${esc([archName(b.architecture), versionText(b)].filter(Boolean).join(' · '))}</span>`,
      })),
    })),
  })), index.builds.some((b) => updateTypeTitle(releaseTag(b))) ? UPDATE_TYPES_LEGEND : '');
  if (selectedKey) picker.value = selectedKey;
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
  return store.map((c) => [c.state, c.priority, c.type, c.variant ? 'variant ' + c.variant : '', c.payload ? payloadText(c) : ''].filter(Boolean).join(', ')).join('; ');
}

// The same as HTML, with each part that says enabled in green and each that says disabled in red
function storeHtml(store) {
  if (!store) return '';
  const part = (s) => (/disabled/i.test(s) ? `<span class="state disabled">${esc(s)}</span>` : /enabled/i.test(s) ? `<span class="state enabled">${esc(s)}</span>` : esc(s));
  return store.map((c) => [c.state, c.priority, c.type, c.variant ? 'variant ' + c.variant : '', c.payload ? payloadText(c) : ''].filter(Boolean).map(part).join(', ')).join('; ');
}

// A variant's payload (a value configured with it), also in decimal; its kind only when it isn't the usual Resident (stored in the
// configuration itself)
function payloadText(c) {
  const n = parseInt(c.payload, 16);
  return `payload ${c.payload}${n >= 10 ? ' (' + fmt(n) + ')' : ''}${c.payloadKind && !/^Resident\b/.test(c.payloadKind) ? ', ' + c.payloadKind : ''}`;
}

const stateText = (f) => [DEFAULTS[f.default], CHANGE_SHORT[f.changeTime]].filter(Boolean).join(', ');
// The same in green when it's enabled, red when it's disabled
const stateHtml = (f) => {
  const d = (f || {}).default || '', cls = /enabled/i.test(d) ? 'enabled' : /disabled/i.test(d) ? 'disabled' : '';
  return cls ? `<span class="state ${cls}">${esc(stateText(f))}</span>` : esc(stateText(f || {}));
};

function matches(f, q, namedOnly) {
  if (namedOnly && !f.name) return false;
  if (!q) return true;
  if (String(f.id).includes(q)) return true;
  if (f.name && f.name.toLowerCase().includes(q)) return true;
  if (f.viveToolName && f.viveToolName.toLowerCase().includes(q)) return true;
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
    if (detail) wrap.querySelectorAll('tr.clickable').forEach((tr) => tr.addEventListener('click', (e) => {
      if (e.target.closest('a')) return;  // A link in the row (a feature) goes where it leads instead
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
    return `<a href="${featureHref(build.key, id)}" class="feat-link">${id}</a>${f && f.name ? ' ' + esc(f.name) : ''}`;
  };
  // A feature only works when the features it requires are on too, so it's only on by default if they are as well: its effective
  // default. causes() finds the nearest required features that make it so (off, or with no known default), past those that are on.
  const own = (id) => {
    const d = (byId.get(id) || {}).default;
    return d === 'enabled' || d === 'alwaysEnabled' ? 'enabled' : d === 'disabled' || d === 'alwaysDisabled' ? 'disabled' : 'unknown';
  };
  const effective = new Map();
  const effectiveDefault = (id) => {
    if (effective.has(id)) return effective.get(id);
    effective.set(id, 'unknown');  // Until its requirements are worked out, in case they ever loop back to it
    const reqs = ((byId.get(id) || {}).requires || []).map(effectiveDefault);
    const e = own(id) === 'disabled' || reqs.includes('disabled') ? 'disabled'
      : own(id) === 'enabled' && reqs.every((s) => s === 'enabled') ? 'enabled' : 'unknown';
    effective.set(id, e);
    return e;
  };
  const causes = (ids, state, found = [], seen = new Set()) => {
    for (const id of ids) {
      if (seen.has(id)) continue;
      seen.add(id);
      if (own(id) === state) found.push(id);
      else if (effectiveDefault(id) === state) causes((byId.get(id) || {}).requires || [], state, found, seen);
    }
    return found;
  };
  const listOf = (ids) => {
    const items = ids.slice(0, 5).map(link).concat(ids.length > 5 ? [`${ids.length - 5} more`] : []);
    return items.length > 1 ? items.slice(0, -1).join(', ') + ' and ' + items[items.length - 1] : items[0];
  };
  // How many features long a feature's chain of requirements is at most (itself included)
  const lengths = new Map();
  const chainLength = (id) => {
    if (!lengths.has(id)) {
      lengths.set(id, 1);  // Until its requirements are worked out, in case they ever loop back to it
      lengths.set(id, 1 + Math.max(0, ...((byId.get(id) || {}).requires || []).map(chainLength)));
    }
    return lengths.get(id);
  };
  // The features a feature requires, on a grid: a column for each step along a chain and a row for each line. A feature's first
  // requirement is on its row and each next one in the highest row below that where it fits among what's placed already, so a short
  // branch can sit under a long one. place() returns the cells of a tree with its root at row 0, column 0, given its subtrees' cells,
  // and notes each subtree's row; the bar joining several subtrees keeps the cells it passes, so nothing else is placed next to it.
  const place = (kids) => {
    const cells = [[0, 0]], taken = new Set(['0,0']);
    let row = -1;
    for (const k of kids) {
      row++;
      while (k.cells.some(([r, c]) => taken.has(`${r + row},${c + 1}`))) row++;
      k.row = row;
      for (const [r, c] of k.cells) { cells.push([r + row, c + 1]); taken.add(`${r + row},${c + 1}`); }
    }
    for (let r = kids.length > 1 ? kids[0].row + 1 : 0; kids.length > 1 && r < kids[kids.length - 1].row; r++) {
      if (!taken.has(`${r},1`)) { cells.push([r, 1]); taken.add(`${r},1`); }
    }
    return cells;
  };
  // Where a feature requires several, they're in the order that takes the fewest rows; between orders that take as many, the one
  // closest to longest chain first. (Rows are counted with every path followed, before features shown earlier are left out.)
  const fullCells = new Map(), ordered = new Map();
  const fullTree = (id) => {
    if (!fullCells.has(id)) {
      fullCells.set(id, [[0, 0]]);  // Until its requirements are worked out, in case they ever loop back to it
      fullCells.set(id, place(requiresOf(id).map((k) => ({ cells: fullTree(k) }))));
    }
    return fullCells.get(id);
  };
  const rowsOf = (cells) => 1 + Math.max(...cells.map(([r]) => r));
  const permutations = (a) => (a.length < 2 ? [a] : a.flatMap((x, i) => permutations(a.filter((_, j) => j !== i)).map((p) => [x, ...p])));
  const requiresOf = (id) => {
    if (!ordered.has(id)) {
      const ids = [...((byId.get(id) || {}).requires || [])].sort((a, b) => chainLength(b) - chainLength(a));
      ordered.set(id, ids);  // Until the best order is worked out, in case requirements ever loop back to it
      if (ids.length > 1 && ids.length <= 6) {
        let best = ids, fewest = Infinity;
        for (const p of permutations(ids)) {
          const rows = rowsOf(place(p.map((k) => ({ cells: fullTree(k) }))));
          if (rows < fewest) { best = p; fewest = rows; }
        }
        ordered.set(id, best);
      }
    }
    return ordered.get(id);
  };
  // The tree as shown: a feature already in it isn't followed again (…)
  const grow = (ids, shown) => ids.map((id) => {
    const next = requiresOf(id);
    const again = shown.has(id);
    shown.add(id);
    return { id, kids: again ? (next.length ? [{ more: true, kids: [] }] : []) : grow(next, shown) };
  });
  const layout = (node) => { node.kids.forEach(layout); node.cells = place(node.kids); return node; };
  // Each feature in a box outlined by its default state, with its name under its ID; an arrow to the first feature it requires, and a
  // bar joining them when it requires several
  const STATE_MARKS = { enabled: '✓', disabled: '✕', unknown: '?' };
  const box = (id, style) => {
    const r = byId.get(id);
    const state = r && r.default ? DEFAULTS[r.default] + (r.default.startsWith('always') ? '' : ' by default') : 'default not known';
    return `<a href="${featureHref(build.key, id)}" class="feat-link req-box ${own(id)}" title="${esc(state[0].toUpperCase() + state.slice(1))}" style="${style}">` +
      `<span class="req-id"><span class="req-mark">${STATE_MARKS[own(id)]}</span>${id}</span>${r && r.name ? `<span class="req-name">${esc(r.name)}</span>` : ''}</a>`;
  };
  // Grid columns: the bar joining the top level's features, then a column for each step with a gutter after it for arrows and bars
  const tree = (ids, shown) => {
    const root = layout({ kids: grow(ids, shown) });
    const items = [];
    let columns = 1;
    const pos = (row, column, lastRow = row) => `grid-row: ${row + 1} / ${lastRow + 2}; grid-column: ${column}`;
    const bar = (kids, row, column) => {
      if (kids.length > 1) items.push(`<span class="req-bar" style="${pos(row + kids[0].row, column, row + kids[kids.length - 1].row)}"></span>`);
    };
    const draw = (node, row, col) => {
      columns = Math.max(columns, col + 1);
      items.push(node.more ? `<span class="muted" title="What it requires is shown earlier" style="${pos(row, 2 + 2 * col)}">…</span>`
        : box(node.id, pos(row, 2 + 2 * col)));
      if (!node.kids.length) return;
      items.push(`<span class="req-arrow" style="${pos(row, 3 + 2 * col)}">→</span>`);
      bar(node.kids, row, 3 + 2 * col);
      node.kids.forEach((k) => draw(k, row + k.row, col + 1));
    };
    root.kids.forEach((k) => draw(k, k.row, 0));
    bar(root.kids, 0, 1);
    const template = `${root.kids.length > 1 ? 10 : 0}px ` + Array(columns).fill('max-content').join(' 30px ');
    return `<span class="req-tree" style="grid-template-columns: ${template}">${items.join('')}</span>`;
  };
  return async (row) => {
    const f = byId.get(row.id) || row;
    const parts = [];
    if (NAME_SOURCES[f.nameSource]) parts.push(`<p class="muted">${esc(NAME_SOURCES[f.nameSource][1])}.</p>`);
    if (f.default || f.changeTime) {
      const def = f.default ? DEFAULTS[f.default] + (f.default.startsWith('always') ? '' : ' by default') : '';
      const when = f.changeTime ? 'changes take effect ' + CHANGE_TIMES[f.changeTime] : '';
      parts.push(`<p><b>Default:</b> ${esc([def, when].filter(Boolean).join('; '))}</p>`);
    }
    // Shown when the features it requires decide it: not for a feature that's off by default anyway, or one with no known default
    // that nothing it requires turns off
    const e = effectiveDefault(f.id);
    if ((f.requires || []).length && own(f.id) !== 'disabled' && (e !== 'unknown' || own(f.id) === 'enabled')) {
      const causedBy = e === 'enabled' ? [] : causes(f.requires, e);
      const why = e === 'enabled' ? ', as are all the features it requires'
        : causedBy.length ? `, since it requires ${listOf(causedBy)}, ` + (e === 'disabled'
          ? `which ${causedBy.length > 1 ? 'are' : 'is'} disabled by default` : `whose default${causedBy.length > 1 ? 's aren\'t' : ' isn\'t'} known`) : '';
      parts.push(`<p><b>Effective default:</b> <span class="eff ${e}">${e === 'unknown' ? 'not known' : e}</span>${why}</p>`);
    }
    if ((f.requires || []).length) parts.push(`<p class="req-line"><b>Requires:</b> ${tree(requiresOf(f.id), new Set([f.id]))}</p>`);
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

// Names that don't come from the build's own symbols: [label, explanation]
const NAME_SOURCES = {
  vivetool: ['name from ViVeTool', "This build's symbols don't name this feature; the name is from ViVeTool's dictionary"],
  earlierBuild: ['name from an earlier build', "This build's symbols don't name this feature; the name is from an earlier build's symbols"],
};

const nameCell = (f) => (f.name ? esc(f.name) : '<span class="unnamed">unnamed</span>') +
  (NAME_SOURCES[f.nameSource] ? ` <span class="src" title="${esc(NAME_SOURCES[f.nameSource][1])}">${esc(NAME_SOURCES[f.nameSource][0])}</span>` : '') +
  (f.viveToolName ? ` <span class="muted" title="ViVeTool's dictionary names this feature differently from the symbols">(ViVeTool: ${esc(f.viveToolName)})</span>` : '') +
  (f.unverified ? ' <span class="unverified" title="This build\'s symbols for its binary couldn\'t be downloaded; known from an earlier version of the binary">unverified</span>' : '');
const modsText = (f) => (f.modules || []).join(', ');

// ---------------------------------------------------------------------------
// Super God Mode
// ---------------------------------------------------------------------------

// The feature that shows or hides an entry of the Settings app's search index, linked to that feature when the build has one with its
// ID or name. A column computed from the columns in from.
const SETTINGS_GATE = {
  title: 'Feature',
  from: ['Shown with feature', 'Hidden with feature'],
  text: (e) => (e['Shown with feature'] ? 'shown with ' + e['Shown with feature'] : e['Hidden with feature'] ? 'hidden with ' + e['Hidden with feature'] : ''),
  html: (e, build) => {
    const name = e['Shown with feature'] || e['Hidden with feature'];
    if (!name) return '';
    const id = findFeature(build, name);
    return (e['Shown with feature'] ? 'shown with ' : 'hidden with ') + (id === undefined ? esc(name)
      : `<a href="${featureHref(build.key, id)}" class="feat-link" title="Feature ${id} in ${esc(build.key)}">${esc(name)}</a>`);
  },
};

// The statistics files of Super God Mode (https://github.com/ThioJoe/Windows-Super-God-Mode), with the columns that identify an entry
// (key) and the columns its table shows (show: column names, or computed columns). A difference in any column counts as a change.
// Settings_Index is the Settings app's search index (Settings_XML_Resolved.xml), which build-site-data.py turns into a table.
const SGM_TABLES = [
  { file: 'CLSID_Shell_Folders', title: 'Shell folders (CLSIDs)', key: ['CLSID'], show: ['CLSID', 'Name', 'NameSource'] },
  { file: 'Named_Shell_Folders', title: 'Named special folders', key: ['Name'], show: ['Name', 'RelativePath', 'ParentFolder'] },
  { file: 'Task_Links', title: 'Control Panel tasks', key: ['XMLTaskId'], show: ['Name', 'ApplicationName', 'Command'] },
  { file: 'MS_Settings', title: 'Settings pages', key: ['Full Setting Command'], show: ['Full Setting Command'] },
  { file: 'Settings_Index', title: 'Settings search entries', key: ['Entry'], show: ['Description', 'Page', SETTINGS_GATE] },
  { file: 'Deep_Links', title: 'Deep links', key: ['Description', 'Full Command'], show: ['Description', 'Full Command'] },
  { file: 'URL_Protocols', title: 'URL protocols', key: ['Protocol'], show: ['Protocol', 'Name', 'Package AppName'] },
  { file: 'Hidden_App_Links', title: 'Hidden app links', key: ['Full URL'], show: ['Full URL', 'Found in File'] },
];
const SGM_ORDER = { added: 0, removed: 1, changed: 2 };

// Paths into app packages and user profiles change with every app update and differ between PCs, so entries are compared without
// the package version and architecture, and the user name. A value can also list several things (the apps that handle a protocol)
// in whatever order they were registered in, so the order of its parts doesn't count either.
const comparable = (s) => s.replace(/_\d+(?:\.\d+)+_(?:x64|x86|arm64|arm|neutral)__/gi, '__').replace(/\\Users\\[^\\]+\\/gi, '\\Users\\*\\')
  .split(/[\s;]+/).filter(Boolean).sort().join(' ');

let sgmIndex = null;  // derived/super-god-mode.json: the builds that have statistics
const sgmCache = new Map();
const featureNames = new WeakMap();

// The ID of the feature of a build with this ID or name (or ViVeTool name), if it has one
function findFeature(build, name) {
  if (!featureNames.has(build)) {
    const m = new Map();
    for (const f of build.features) {
      m.set(String(f.id), f.id);
      for (const n of [f.name, f.viveToolName]) if (n && !m.has(n.toLowerCase())) m.set(n.toLowerCase(), f.id);
    }
    featureNames.set(build, m);
  }
  return featureNames.get(build).get(name.toLowerCase());
}

function loadSgm(key) {
  if (!sgmCache.has(key)) sgmCache.set(key, getJson('super-god-mode/' + encodeURIComponent(key) + '.json', DERIVED));
  return sgmCache.get(key);
}

// One statistics table of two builds: the entries added, removed and changed, sorted by key. Keys (URLs, GUIDs, names) are matched
// regardless of case, as Windows does: the same link can turn up with different capitals.
function sgmDiff(t, oldTable, newTable) {
  const entries = (tb) => {
    const m = new Map();
    for (const r of (tb ? tb.rows : [])) {
      const e = Object.fromEntries(tb.columns.map((c, i) => [c, r[i] || '']));
      m.set(t.key.map((k) => e[k]).join('\n').toLowerCase(), e);
    }
    return m;
  };
  const o = entries(oldTable), n = entries(newTable), rows = [];
  for (const [k, e] of n) {
    const before = o.get(k);
    if (!before) { rows.push({ k, change: 'added', row: e }); continue; }
    const cols = Object.keys(e).filter((c) => comparable(e[c]) !== comparable(before[c] || ''));
    if (cols.length) rows.push({ k, change: 'changed', row: e, old: before, cols });
  }
  for (const [k, e] of o) if (!n.has(k)) rows.push({ k, change: 'removed', row: e });
  rows.sort((x, y) => (x.k < y.k ? -1 : x.k > y.k ? 1 : 0)).forEach((r, i) => { r.id = i; });
  return { rows, count: n.size };
}

// A changed value: what it was, and what it is
const NONE = '<span class="muted">(none)</span>';
const changeHtml = (before, after) => `${before ? `<del>${before}</del>` : NONE} → ${after || NONE}`;

// A column's value in an entry; a changed value shows what it was
function sgmValue(r, c) {
  const v = r.row[c] || '';
  return r.change === 'changed' && r.cols.includes(c) ? changeHtml(esc(r.old[c] || ''), esc(v)) : esc(v);
}

const sgmDetail = async (r) => '<div class="sgm-entry">' + Object.keys(r.row).map((c) =>
  `<div class="kv"><span>${esc(c)}</span><div class="val">${sgmValue(r, c) || '<span class="muted">(empty)</span>'}</div></div>`).join('') + '</div>';

// What Super God Mode found in one of two builds and not the other, and what changed. Adds nothing once isCurrent() says a newer
// render has started.
async function renderSgmCompare(out, a, b, q, isCurrent) {
  if (!sgmIndex) sgmIndex = await getJson('super-god-mode.json', DERIVED).catch(() => ({}));
  const runs = [sgmIndex[a.key], sgmIndex[b.key]];
  let notes = [], data = null;
  const missing = [a, b].filter((x, i) => !runs[i] || runs[i].empty);
  if (missing.length) {
    notes = missing.map((x) => {
      const run = sgmIndex[x.key];
      return run && run.error ? `Super God Mode failed on ${esc(buildLabel(x))}: ${esc(run.error)}`
        : `${esc(buildLabel(x))} has no Super God Mode statistics: it was scanned before they were collected.`;
    });
  } else {
    try {
      data = await Promise.all([loadSgm(a.key), loadSgm(b.key)]);
    } catch (e) {
      notes = ['Could not load the Super God Mode statistics: ' + esc(e.message)];
    }
  }
  if (!isCurrent()) return;
  const box = section(out, 'compare:sgm', 'h2', '', 'Super God Mode Analysis');
  const note = (html) => box.insertAdjacentHTML('beforeend', `<p class="muted">${html}</p>`);
  if (!data) { notes.forEach(note); return; }
  const sameVersion = runs[0].version === runs[1].version;
  // Patch releases (1.2.x) don't change what Super God Mode finds; a new minor or major version (1.3) can
  const minor = (v) => String(v).split('.').slice(0, 2).join('.');
  note(`The shortcuts and links <a href="https://github.com/ThioJoe/Windows-Super-God-Mode">Super God Mode</a> ` +
    (sameVersion ? esc(runs[0].version) : `(${esc(runs[0].version)} on the old build, ${esc(runs[1].version)} on the new one)`) +
    ' found in each build, run as the PC\'s user. URL protocols and hidden app links come from the installed apps, so they also change with ' +
    'app updates.' + (runs[0].user !== runs[1].user ? ` These two runs were on different PCs (as ${esc(runs[0].user)} and ${esc(runs[1].user)}), ` +
    'which have different apps.' : '') + (minor(runs[0].version) !== minor(runs[1].version)
    ? ` ${esc(runs[0].version)} and ${esc(runs[1].version)} are different minor versions of Super God Mode, which can find different things.` : ''));
  const same = [], absent = [];
  // A column of a statistics file, or a computed one (SETTINGS_GATE), whose links lead into the build the entry is from
  const column = (c, i) => (typeof c === 'string'
    ? { title: c, value: (r) => r.row[c], html: (r) => sgmValue(r, c), cls: i ? 'sgm' : 'name' }
    : {
      title: c.title, value: (r) => c.text(r.row), cls: 'sgm',
      html: (r) => {
        const now = c.html(r.row, r.change === 'removed' ? a : b);
        return r.change === 'changed' && c.from.some((x) => r.cols.includes(x)) ? changeHtml(esc(c.text(r.old)), now) : now;
      },
    });
  for (const t of SGM_TABLES) {
    const tables = [data[0].tables[t.file], data[1].tables[t.file]];
    if (!tables[0] || !tables[1]) {
      if (tables[0] || tables[1]) absent.push(esc(t.title));
      continue;
    }
    const { rows, count } = sgmDiff(t, tables[0], tables[1]);
    if (!rows.length) { same.push(`${esc(t.title)} (${fmt(count)})`); continue; }
    const filtered = rows.filter((r) => !q || [r.row, r.old || {}].some((e) => Object.values(e).some((v) => v.toLowerCase().includes(q))));
    const counts = Object.keys(SGM_ORDER).map((c) => [c, filtered.filter((r) => r.change === c).length]).filter(([, n]) => n)
      .map(([c, n]) => `<span class="${c}">${n} ${c}</span>`).join(', ');
    // A changed entry names the columns that changed when the table doesn't show them
    const shown = new Set(t.show.flatMap((c) => (typeof c === 'string' ? [c] : c.from)));
    const changeCell = (r) => `<span class="chg ${r.change}">${r.change}</span>` +
      (r.change === 'changed' && r.cols.some((c) => !shown.has(c)) ? `<div class="chg-cols">${r.cols.filter((c) => !shown.has(c)).map(esc).join(', ')}</div>` : '');
    const sec = section(box, 'compare:sgm:' + t.file, 'h3', '',
      `${esc(t.title)} <span class="count">${counts || '0'}${filtered.length !== rows.length ? ` of ${rows.length} differences` : ''}</span>`,
      filtered.length > 0);
    if (filtered.length) {
      renderTable(sec, filtered, [
        { title: 'Change', value: (r) => r.change, sortKey: (r) => SGM_ORDER[r.change], html: changeCell },
        ...t.show.map(column),
      ], undefined, sgmDetail);
    }
  }
  if (same.length) note('No differences in ' + same.join(', ') + '.');
  if (absent.length) note(`Only one of the two builds' statistics has ${absent.join(', ')}.`);
}

// ---------------------------------------------------------------------------
// Compare view
// ---------------------------------------------------------------------------

let compareRender = 0;

async function renderCompare() {
  const oldKey = $('cmp-old').value, newKey = $('cmp-new').value;
  const q = $('cmp-search').value.trim().toLowerCase();
  const namedOnly = $('cmp-named').checked;
  const out = $('cmp-results');
  setHash(`compare/${oldKey}/${newKey}`);
  if (!oldKey || !newKey) return;
  const render = ++compareRender;  // A slower earlier render must not add to a newer one
  $('cmp-status').textContent = 'Loading…';
  out.innerHTML = '';
  const [a, b] = await Promise.all([loadBuild(oldKey), loadBuild(newKey)]);
  if (render !== compareRender) return;
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
      { title: 'New', value: (f) => storeText(f.newStore) || '(not configured)', html: (f) => storeHtml(f.newStore) || '(not configured)', cls: 'store' },
    ]],
    ['Default changed', 'changed', defaultChanged, [
      { title: 'ID', value: (f) => f.id, cls: 'id' },
      { title: 'Name', value: (f) => f.name, html: nameCell, cls: 'name' },
      { title: 'Old', value: (f) => stateText(f.oldState), cls: 'store' },
      { title: 'New', value: (f) => stateText(f.newState), html: (f) => stateHtml(f.newState), cls: 'store' },
    ]],
  ];
  const detailOld = featureDetail(a), detailNew = featureDetail(b);
  const direction = compareVersions(a, b) > 0 ? ' (the "old" build is newer than the "new" one)' : '';
  $('cmp-status').textContent = `${buildLabel(a)} → ${buildLabel(b)}${direction}`;
  for (const [title, cls, rows, cols] of sections) {
    const filtered = rows.filter((f) => matches(f, q, namedOnly));
    const sec = section(out, 'compare:' + title, 'h2', cls,
      `${esc(title)} <span class="count">${filtered.length}${filtered.length !== rows.length ? ' of ' + rows.length : ''}</span>`, filtered.length > 0);
    if (filtered.length) renderTable(sec, filtered, cols, undefined, title === 'Removed' ? detailOld : detailNew);
  }
  await renderSgmCompare(out, a, b, q, () => render === compareRender);
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
  setHash(buildHash());
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
// Released builds
// ---------------------------------------------------------------------------

let releases = null;
const RELEASES_SHOWN = 6;  // Newest builds shown per version (data/releases.json has every one, for the tags of older scanned builds)

async function renderReleases() {
  if (!releases) releases = await getJson('releases.json');
  const keys = new Set(index.builds.map((b) => b.key));
  const none = '<span class="muted">—</span>';
  const scanLink = (build, arch) => (keys.has(`${build}-${arch}`)
    ? `<a href="#build/${encodeURIComponent(`${build}-${arch}`)}">scanned</a>` : '');
  const vm = releases.windows11.filter((v) => v.scannedInVm).map((v) => v.version);
  let html = '<p class="muted">The newest builds of each Windows 11 version that is still serviced, and of each Windows Insider channel, ' +
    "from Microsoft's update history and Insider release notes, checked daily. " +
    `x64 builds of ${esc(vm.join(', '))} are scanned in a virtual machine built from Microsoft's servers as they come out; ` +
    "ARM64 builds are scanned when GitHub's ARM64 runner has them. " +
    (releases.insider.some((c) => c.scannedInVm)
      ? "Insider builds are scanned in a virtual machine enrolled in the Windows Insider Program, except Release Preview's, which are scanned as the updates they become.</p>"
      : 'Insider builds are not scanned yet: Microsoft only provides them to devices enrolled in the Windows Insider Program, and the scanner has no enrolled device yet.</p>');

  html += '<h2>Windows 11</h2><p class="muted legend">Update is Microsoft\'s label for the release: the year and month, then ' +
    '<b>B</b> for the monthly security update (the second Tuesday of the month), <b>D</b> for the optional non-security preview ' +
    '(the fourth week of the month) or <b>OOB</b> for an out-of-band update, released when a fix can\'t wait for the next monthly ' +
    'update. <a href="https://learn.microsoft.com/windows/deployment/update/release-cycle">Microsoft\'s description of each</a>.</p>';
  html += '<div class="table-wrap"><table><thead><tr><th>Version</th><th>Build</th><th>KB</th><th>Released</th>' +
    '<th>Update</th><th>x64</th><th>ARM64</th></tr></thead><tbody>';
  // The first cell of a group spans its rows, so the last group's has to drop the bottom border the table's last row doesn't have
  const groupCell = (text, rows, last) => `<td rowspan="${rows}"${last ? ' class="last"' : ''}>${esc(text)}</td>`;
  releases.windows11.forEach((v, n) => {
    // The VM scans every build newer than the newest one scanned, or a version's newest build when none is
    const scanned = index.builds.filter((b) => b.architecture === 'AMD64' && !b.insiderChannel && b.build.split('.')[0] === String(v.base))
      .sort(compareVersions).pop();
    const shown = v.releases.slice(0, RELEASES_SHOWN);
    shown.forEach((r, i) => {
      const due = v.scannedInVm && (scanned ? compareVersions(r, scanned) > 0 : i === 0);
      html += '<tr>' + (i === 0 ? groupCell(v.version, shown.length, n === releases.windows11.length - 1) : '') +
        `<td class="id">${esc(r.build)}</td>` +
        `<td><a href="https://support.microsoft.com/help/${esc(r.kb.replace(/^KB/, ''))}">${esc(r.kb)}</a></td>` +
        `<td>${esc(r.date)}</td><td${updateTypeTitle(r.type) ? ` title="${esc(updateTypeTitle(r.type))}"` : ''}>${esc(r.type)}</td>` +
        `<td>${scanLink(r.build, 'AMD64') || (due ? '<span class="muted">not yet</span>' : none)}</td>` +
        `<td>${scanLink(r.build, 'ARM64') || none}</td></tr>`;
    });
  });
  html += '</tbody></table></div>';

  html += '<h2>Windows Insider</h2><div class="table-wrap"><table><thead><tr><th>Channel</th><th>Build</th><th>Released</th>' +
    '<th>Release notes</th><th>x64</th><th>ARM64</th></tr></thead><tbody>';
  releases.insider.forEach((c, n) => {
    const listed = new Set(c.releases.map((r) => r.build));
    const scanned = index.builds.filter((b) => b.architecture === 'AMD64' && listed.has(b.build)).sort(compareVersions).pop();
    c.releases.forEach((r, i) => {
      const due = c.scannedInVm && (scanned ? compareVersions(r, scanned) > 0 : i === 0);
      html += '<tr>' + (i === 0 ? groupCell(c.channel, c.releases.length, n === releases.insider.length - 1) : '') +
        `<td class="id">${esc(r.builds.join(' / '))}</td><td>${esc(r.date || '')}</td>` +
        `<td><a href="${esc(r.notes)}">${esc(r.notes.split('/').pop())}</a></td>` +
        `<td>${scanLink(r.build, 'AMD64') || (due ? '<span class="muted">not yet</span>' : none)}</td>` +
        `<td>${scanLink(r.build, 'ARM64') || none}</td></tr>`;
    });
  });
  html += '</tbody></table></div>';
  $('rel-status').textContent = '';
  $('rel-results').innerHTML = html;
}

// ---------------------------------------------------------------------------
// Routing
// ---------------------------------------------------------------------------

// replaceState doesn't fire hashchange, so this only records state; back/forward and pasted links go through route()
function setHash(h) {
  if (location.hash.slice(1) !== h) history.replaceState(null, '', '#' + h);
}

// The build view's address: the build, and the search when there is one, so the back button and links to features bring it back
function buildHash() {
  const q = $('bld-search').value.trim();
  return `build/${$('bld-select').value}${q ? '/' + encodeURIComponent(q) : ''}`;
}

function showView(view) {
  for (const v of ['compare', 'build', 'releases']) $('view-' + v).hidden = v !== view;
  document.querySelectorAll('nav a').forEach((a) => a.classList.toggle('active', a.dataset.view === view));
}

function route() {
  const parts = location.hash.slice(1).split('/').map(decodeURIComponent);
  const view = ['build', 'releases'].includes(parts[0]) ? parts[0] : 'compare';
  showView(view);
  const known = (k) => index.builds.some((b) => b.key === k);
  if (view === 'releases') {
    renderReleases().catch(showError('rel-status'));
  } else if (view === 'build') {
    if (known(parts[1])) $('bld-select').value = parts[1];
    $('bld-search').value = parts[2] || '';
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
    [index, firstSeen, releases] = await Promise.all([getJson('index.json'), getJson('first-seen.json'), getJson('releases.json').catch(() => null)]);
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
  // Compare the newest build that has an earlier one to compare with (a first build of an architecture has none)
  const compared = [...index.builds].filter((b) => b.previous).sort(compareVersions).pop() || latest;
  fillBuildPicker($('cmp-old'), compared.previous || compared.key);
  fillBuildPicker($('cmp-new'), compared.key);
  fillBuildPicker($('bld-select'), latest.key);

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
    setHash(v === 'build' ? buildHash() : v === 'releases' ? 'releases' : `compare/${$('cmp-old').value}/${$('cmp-new').value}`);
    route();
  }));
  // Links to features (featureHref) are ordinary links: the browser adds them to the history, and route() opens them
  window.addEventListener('hashchange', route);
  route();
}

init();
