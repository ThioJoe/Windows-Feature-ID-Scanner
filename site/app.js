// Windows Feature IDs browser. Loads data/index.json, then individual build files on demand.
'use strict';

const DATA = 'data/';
const DERIVED = 'derived/';  // Files build-site-data.py derives from data/ when the site is published
const PAGE = 500;
const NUMERIC = /^(?:ID|FI)?\d+$/;

const DETAIL_SHARDS = 64;
const DEFAULTS = { enabled: 'enabled', disabled: 'disabled', alwaysEnabled: 'always enabled', alwaysDisabled: 'always disabled' };
// The order the tables sort default states in, instead of alphabetical (which put always enabled below disabled)
const DEFAULT_ORDER = { alwaysDisabled: 1, disabled: 2, enabled: 3, alwaysEnabled: 4 };
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
          for (const u of Object.values(d.usage || {})) for (const k of ['callers', 'strings', 'sources', 'imports', 'symbols', 'calls', 'tables']) parts.push(...(u[k] || []));
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

// A build whose scan didn't get the symbols of binaries that had features in earlier versions, because Microsoft hadn't published them
// yet: until the daily symbol catch-up completes it, those features are only known from the earlier versions
function pendingNote(b) {
  const p = b.symbolsPending;
  if (!p) return '';
  const n = (count, one, many) => `${count} ${count === 1 ? one : many}`;
  const checking = !p.until || new Date().toISOString().slice(0, 10) <= p.until;
  const known = `${n(p.unverified, 'feature is', 'features are')} known only from earlier versions of their binaries (marked unverified)`;
  return `<p class="notice"><b>${esc(buildLabel(b))}:</b> ` + (checking
    ? `Microsoft's symbol server didn't have the symbols of ${n(p.binaries, 'binary', 'binaries')} with features yet when this build was scanned, ` +
      `so ${known}, and features new in them aren't listed. The symbol server is checked daily${p.until ? ` until <time>${esc(p.until)}</time>` : ''}, ` +
      'and the build is completed when the symbols are published.'
    : `Microsoft hasn't published the symbols of ${n(p.binaries, 'binary', 'binaries')} with features in this build, so ${known}.`) + '</p>';
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
      const o = e.target.closest('[role=option]:not([aria-disabled=true])');
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
        // A group's notes: a bulleted line each on its info icon, and plain sentences for screen readers
        const notes = g.notes || [];
        html += `<div role="group"${g.divider ? ' class="picker-divided"' : ''} aria-label="${esc(s.label + ' ' + g.label)}"` +
          `${notes.length ? ` aria-description="${esc(notes.join(' '))}"` : ''}><div class="picker-group-label" aria-hidden="true">${esc(g.label)}` +
          `${notes.length ? `<span class="picker-note" data-tip="${esc(notes.map((n) => `• ${n}`).join('\n'))}">${INFO_ICON}</span>` : ''}</div>`;
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
    this.markTaken();
  }

  // A value the list shows greyed out and doesn't let be picked, with a note saying why when it's hovered or clicked (the build the other
  // compare picker has)
  setTaken(value, note) {
    this.taken = value;
    this.takenNote = note;
    this.markTaken();
  }

  markTaken() {
    for (const o of this.list.querySelectorAll('[role=option]')) {
      if (o.dataset.value === this.taken) {
        o.setAttribute('aria-disabled', 'true');
        o.dataset.tip = this.takenNote;
      } else {
        o.removeAttribute('aria-disabled');
        delete o.dataset.tip;
      }
    }
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
    if (value === this.taken) return;
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
  if (b.insiderChannel && b.release && b.release.date) return b.release.date;
  if (!releases) return '';
  for (const v of releases.windows11) for (const r of v.releases) if (r.build === b.build) return r.type || '';
  for (const c of releases.insider) for (const r of c.releases) if ((r.builds || [r.build]).includes(b.build)) return r.date || '';
  return '';
}

// What each Insider channel is, from Microsoft's descriptions (https://learn.microsoft.com/windows-insider/flighting): its Windows core
// version, then what the features in its builds are. Each point is a bulleted line on the channel's info icon.
const CHANNEL_NOTES = {
  'Experimental (Future Platforms)': [
    'Previously known as "Canary".',
    'Builds are not aligned to any retail release of Windows, and their features may or may not appear in future updates.',
  ],
  'Experimental (26H1)': [
    'Based on a newer core than 24H2, 25H2 and 26H2, despite the name. The released 26H1 only comes preinstalled on select new devices and ' +
      'isn\'t offered through Windows Update, but Insiders can choose these builds on other PCs.',
    'Experimental: Contains features that may or may not ship in a future monthly update.',
  ],
  'Beta (26H1)': [
    'Based on a newer core than 24H2, 25H2 and 26H2, despite the name. The released 26H1 only comes preinstalled on select new devices and ' +
      'isn\'t offered through Windows Update, but Insiders can choose these builds on other PCs.',
    'Beta: Typically contains features planned to ship in an upcoming monthly update.',
  ],
  Experimental: [
    'The "normal" Insider channels, on the same core as 24H2, 25H2 and 26H2.',
    'Experimental: Contains features that may or may not ship in a future monthly update.',
  ],
  Beta: [
    'The "normal" Insider channels, on the same core as 24H2, 25H2 and 26H2.',
    'Beta: Typically contains features planned to ship in an upcoming monthly update.',
  ],
};
// A channel's Windows core version: the end of its name in parentheses, none for the main channels
const coreVersion = (channel) => (channel.match(/\(([^()]*)\)$/) || [])[1] || '';

// Released builds by architecture (x64 first, a column each), then by Windows version, newest first; Insider builds in a column of their
// own, by channel, with a line between channels of different Windows core versions as Flight Hub groups them (those named for one, such as
// Experimental (Future Platforms) or Beta (26H1), and the main ones), and an info icon on each channel with what it is
function fillBuildPicker(picker, selectedKey) {
  const columns = new Map();
  for (const b of [...index.builds].sort((x, y) => compareVersions(y, x))) {
    const column = b.insiderChannel ? 'Insider' : b.architecture;
    if (!columns.has(column)) columns.set(column, new Map());
    const groups = columns.get(column), g = b.insiderChannel || versionText(b) || 'Other';
    if (!groups.has(g)) groups.set(g, []);
    groups.get(g).push(b);
  }
  const columnOrder = (c) => (c === 'AMD64' ? 0 : c === 'Insider' ? 2 : 1);
  const insiderArchs = [...new Set(index.builds.filter((b) => b.insiderChannel).map((b) => archName(b.architecture)))].join(', ');
  picker.setSections([...columns].sort(([x], [y]) => columnOrder(x) - columnOrder(y) || x.localeCompare(y)).map(([column, groups]) => ({
    label: column === 'Insider' ? 'Insider' : archName(column),
    note: column === 'Insider' ? insiderArchs : archName(column) !== column ? column : '',
    groups: [...groups].map(([label, builds], i, all) => ({
      label,
      divider: column === 'Insider' && i > 0 && coreVersion(label) !== coreVersion(all[i - 1][0]),
      notes: column === 'Insider' ? CHANNEL_NOTES[label] || [] : [],
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

// The newest build (of an architecture): a released one when there is one, since the site opens on it
function latestBuild(arch) {
  const list = index.builds.filter((b) => !arch || b.architecture === arch).sort(compareVersions);
  return list.filter((b) => !b.insiderChannel).pop() || list[list.length - 1];
}

// The builds by key, each build's place in the order builds came out (its release date, then its build number), which is the order
// first-seen.json counts them in (update-data.py), the first build of each Insider channel (of an architecture) in that order, and the
// builds that came out on each architecture's first tracked day
let buildsByKey = null, releaseRank = null, channelFirst = null, earliestBuilds = null;
function buildOrder() {
  if (!buildsByKey) {
    buildsByKey = new Map(index.builds.map((b) => [b.key, b]));
    const date = (b) => (b.release && b.release.date) || String(b.scannedAt || '').slice(0, 10) || '9999-12-31';
    const ordered = [...index.builds].sort((x, y) => (date(x) < date(y) ? -1 : date(x) > date(y) ? 1 : compareVersions(x, y)));
    releaseRank = new Map(ordered.map((b, i) => [b.key, i]));
    const firsts = new Map();
    for (const b of ordered) {
      const channel = `${b.architecture} ${b.insiderChannel}`;
      if (b.insiderChannel && !firsts.has(channel)) firsts.set(channel, b.key);
    }
    channelFirst = new Set(firsts.values());
    earliestBuilds = new Map();
    for (const b of ordered) {
      const earliest = earliestBuilds.get(b.architecture);
      if (!earliest) earliestBuilds.set(b.architecture, [b.key]);
      else if (date(buildsByKey.get(earliest[0])) === date(b)) earliest.push(b.key);
    }
  }
}

// Whether a build came out on its architecture's first tracked day, so that every feature it has counts as first seen in it by default
function isEarliestBuild(b) {
  buildOrder();
  return (earliestBuilds.get(b.architecture) || []).includes(b.key);
}

// The builds a feature was first seen in: the ones that had it of the builds that came out on the first day any build had it. In
// first-seen.json that's one build's key, or a list of them when several builds that came out that day had it.
function firstSeenKeys(arch, id) {
  const v = firstSeen.firstSeen[arch] && firstSeen.firstSeen[arch][String(id)];
  return !v ? [] : Array.isArray(v) ? v : [v];
}

// The builds a feature was first seen in, as the First seen column lists them. names gives the build of the view a name in its place,
// such as "This build"; other builds are listed by key, with the Insider channel of an Insider build (Future Platforms shortened to FP).
// Each has why the feature may be older if the build came out on the first tracked day, or was the first scanned of its Insider channel:
// every feature such a build had that no earlier scan had counts as first seen there by default, however old.
function firstSeenEntries(arch, id, names) {
  buildOrder();
  return firstSeenKeys(arch, id).map((key) => {
    const b = buildsByKey.get(key), earliest = earliestBuilds.get(arch) || [];
    const text = (names && names[key]) || (b && b.insiderChannel ? `${key} (${versionText(b).replace('Future Platforms', 'FP')})` : key);
    const why = earliest.includes(key)
      ? `This was ${earliest.length > 1 ? 'one of the earliest builds' : 'the earliest build'} scanned, so the feature counts as first seen here by default. It may be older.`
      : channelFirst.has(key) ? `This was the first ${versionText(b)} build scanned, so a feature no earlier scan had counts as first seen here by default. It may be older.`
      : '';
    return { text, why };
  });
}

function firstSeenText(arch, id, names) {
  return firstSeenEntries(arch, id, names).map((e) => e.text).join('\n');
}

// An info icon, in the color of the text around it
const INFO_ICON = '<svg viewBox="0 0 16 16" aria-hidden="true"><circle cx="8" cy="8" r="6.75" fill="none" stroke="currentColor" stroke-width="1.5"/>' +
  '<path d="M8 7.25v4" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/><circle cx="8" cy="4.75" r="1" fill="currentColor"/></svg>';

// The same as HTML: a line per build, with an info icon where the feature may be older
function firstSeenHtml(arch, id, names) {
  return firstSeenEntries(arch, id, names).map((e) => `<span class="seen-build">${esc(e.text)}` +
    // (Its empty title keeps the row's "Show details" tooltip from showing as well)
    (e.why ? `<span class="seen-default" data-tip="${esc(e.why)}" title="" aria-label="${esc(e.why)}" role="img">${INFO_ICON}</span>` : '') + '</span>').join('<br>');
}

// For sorting by first seen: the order the builds came out
function firstSeenRank(arch, id) {
  const key = firstSeenKeys(arch, id)[0];
  if (!key) return '';
  buildOrder();
  return releaseRank.has(key) ? releaseRank.get(key) : '';
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
// Sorts by the default (DEFAULT_ORDER), then by the text; a state without a known default goes last, as a blank does
const stateSortKey = (f) => (DEFAULT_ORDER[f.default] ? `${DEFAULT_ORDER[f.default]} ${stateText(f)}` : '');
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
  // What a feature trace opened when it was checked, such as ms-settings:display; and for a feature only a trace has, what checked it
  if (f.trace && (f.trace.targets || []).some((t) => t.replace(/`/g, '').toLowerCase().includes(q))) return true;
  if (traceOnly(f) && (f.trace.processes || []).some((p) => p.toLowerCase().includes(q))) return true;
  return (f.modules || []).some((m) => m.toLowerCase().includes(q));
}

// Lays out each list of .cells in columns (--cell wide, --cell-gap apart, from the CSS): every item is made as wide as a whole number of
// columns, so they all start on one, and a long item takes as many as it needs, the next one starting after it. The items go in order of
// how many columns they take, then alphabetically by data-name (then data-id). Measured once shown, all of them before any is changed.
function fitCells(root) {
  for (const cells of root.querySelectorAll('.cells')) {
    const style = getComputedStyle(cells), width = parseFloat(style.getPropertyValue('--cell')), gap = parseFloat(style.getPropertyValue('--cell-gap'));
    // (The exact width, with half a pixel to spare: a whole-pixel one can be a fraction short, and the text then wraps)
    const items = [...cells.children].map((cell) => ({ cell, n: Math.max(1, Math.ceil((cell.getBoundingClientRect().width + 0.5 + gap) / (width + gap))) }));
    items.sort((a, b) => a.n - b.n || (a.cell.dataset.name || '').localeCompare(b.cell.dataset.name || '', 'en', { sensitivity: 'base' }) ||
      Number(a.cell.dataset.id) - Number(b.cell.dataset.id));
    for (const { cell, n } of items) {
      cell.style.width = `${n * (width + gap) - gap}px`;
      cells.appendChild(cell);
    }
    cells.classList.add('fitted');
  }
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
      detail(sorted[Number(tr.dataset.i)]).then((h) => { body.innerHTML = h; fitCells(body); }, (e) => { body.textContent = 'Error: ' + e.message; });
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
    return `<a href="${featureHref(build.key, id)}" class="feat-link fid">${id}</a>${f && f.name ? ' ' + esc(f.name) : ''}`;
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
  // How many boxes a feature's tree has with every path followed, or Infinity if its requirements loop back. Orders are only compared
  // for requirements whose trees take up to ORDER_BOXES together: every x64 feature's take fewer than 130, but some ARM64 builds'
  // requirements branch and loop back so much that laying out every order would take minutes. The others keep longest chain first.
  const ORDER_BOXES = 500;
  const boxes = new Map();
  const boxCount = (id) => {
    if (!boxes.has(id)) {
      boxes.set(id, Infinity);  // Until its requirements are counted: reaching it again on the way means they loop back
      boxes.set(id, 1 + ((byId.get(id) || {}).requires || []).reduce((n, k) => n + boxCount(k), 0));
    }
    return boxes.get(id);
  };
  const requiresOf = (id) => {
    if (!ordered.has(id)) {
      const ids = [...((byId.get(id) || {}).requires || [])].sort((a, b) => chainLength(b) - chainLength(a));
      ordered.set(id, ids);  // Until the best order is worked out, in case requirements ever loop back to it
      if (ids.length > 1 && ids.length <= 6 && ids.reduce((n, k) => n + boxCount(k), 0) <= ORDER_BOXES) {
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
  // A feature's ID and those of every feature it requires, in the order the tree shows them
  const withRequired = (id, ids = new Set()) => {
    if (!ids.has(id)) {
      ids.add(id);
      for (const k of requiresOf(id)) withRequired(k, ids);
    }
    return ids;
  };
  return async (row) => {
    const f = byId.get(row.id) || row;
    const det = await loadDetails(build.architecture, f.id);
    const parts = [];
    if (NAME_SOURCES[f.nameSource]) parts.push(`<p class="muted">${esc(NAME_SOURCES[f.nameSource][1])}.</p>`);
    if (f.default || f.changeTime) {
      const def = f.default ? DEFAULTS[f.default] + (f.default.startsWith('always') ? '' : ' by default') : '';
      const when = f.changeTime ? 'changes take effect ' + CHANGE_TIMES[f.changeTime] : '';
      const source = f.defaultSource === 'trace' ? ` <span class="src" title="${esc(TRACE_DEFAULT)}">from a feature trace</span>` : '';
      parts.push(`<p><b>Default:</b> ${esc(def)}${def ? source : ''}${def && when ? '; ' : ''}${esc(when)}</p>`);
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
    if (f.trace) parts.push(traceHtml(f, build, await loadTraceTargets(build.key)));
    else if (det && det.trace && det.trace.build !== build.key) parts.push(otherTraceHtml(det.trace, f.id, await loadTraceTargets(det.trace.build)));
    if ((f.requires || []).length) {
      // The IDs as ViVeTool's /id: takes them. Disabling what a feature requires would also turn off the other features that require it.
      const ids = [...withRequired(f.id)];
      parts.push(`<p class="req-line"><b>Requires:</b> ${tree(requiresOf(f.id), new Set([f.id]))}</p>`,
        `<p class="req-copy"><button type="button" class="copy-ids" data-ids="${ids.join(',')}">Copy ${ids.length} IDs</button>` +
        '<span class="muted">Copies this feature ID and its dependencies as a comma-separated list. Use with ViVeTool /enable or /reset. ' +
        'To disable it, use only its own ID.</span></p>');
    }
    if (requiredBy.has(f.id)) {
      // Grouped by how many columns each takes, then alphabetical (fitCells puts them in that order once it has measured them)
      const cell = (id) => `<span class="cell" data-name="${esc((byId.get(id) || {}).name || '')}" data-id="${id}">${link(id)}</span>`;
      parts.push(`<div class="req-by"><b>Required by:</b><div class="cells">${requiredBy.get(f.id).map(cell).join('')}</div></div>`);
    }
    if (det && det.usage) {
      parts.push(...Object.entries(det.usage).map(([mod, u]) => moduleDetail(mod, u)));
      if (det.build !== build.key) parts.push(`<p class="muted">Code details are from build ${esc(det.build)}.</p>`);
    }
    if ((f.declaredIn || []).length) {
      parts.push(`<p class="muted"><b>Declared only</b> (the ID is in the symbols, but the binary has no code for it) in: ${f.declaredIn.map(esc).join(', ')}</p>`);
    }
    const stored = (f.modules || []).filter((m) => (build.componentStore || {})[m]);
    if (stored.length) {
      parts.push(`<p class="muted"><b>Only in the component store</b> (WinSxS, not in the Windows folders: for example part of an optional feature that isn't turned on): ` +
        `${stored.map((m) => `<span title="${esc(build.componentStore[m])}">${esc(m)}</span>`).join(', ')}</p>`);
    }
    return parts.join('') || '<p class="muted">Nothing more is known about this feature.</p>';
  };
}

// Copies the IDs of a feature panel's copy button (its data-ids), and says so on the button for a moment
async function copyIds(button) {
  const label = button.dataset.label || (button.dataset.label = button.textContent);
  let copied = false;
  try {
    await navigator.clipboard.writeText(button.dataset.ids);
    copied = true;
  } catch (e) {
    // Where the Clipboard API isn't available or allowed: the older way, from a selected text box
    const area = document.createElement('textarea');
    area.value = button.dataset.ids;
    area.style.position = 'fixed';
    area.style.opacity = '0';
    document.body.appendChild(area);
    area.select();
    try { copied = document.execCommand('copy'); } catch (e2) { copied = false; }
    area.remove();
  }
  button.textContent = copied ? 'Copied' : 'Couldn\'t copy';
  clearTimeout(button.copyTimer);
  button.copyTimer = setTimeout(() => { button.textContent = label; }, 1500);
}

// An info icon's note (its data-tip): shown while the pointer is over the icon or the note, and from a click or tap on the icon until the
// next one elsewhere. (A title attribute's tooltip only shows on hover, hides when the pointer moves or clicks, and never shows on a touch
// screen.) A line that starts with "• " is a bullet point. A hover shows it after a moment, so moving across a column of icons doesn't
// flash each one's note.
const tip = { el: null, target: null, pinned: false, timer: 0, pending: null, showTimer: 0 };

function showTip(target, pinned) {
  clearTimeout(tip.showTimer);
  tip.pending = null;
  if (!tip.el) {
    tip.el = document.createElement('div');
    tip.el.className = 'tip';
    tip.el.setAttribute('role', 'tooltip');
    tip.el.addEventListener('pointerenter', () => clearTimeout(tip.timer));
    tip.el.addEventListener('pointerleave', () => { if (!tip.pinned) hideTipSoon(); });
    document.body.appendChild(tip.el);
  }
  clearTimeout(tip.timer);
  tip.target = target;
  tip.pinned = pinned;
  tip.el.classList.toggle('tip-path', 'tipPath' in target.dataset);
  tip.el.innerHTML = target.dataset.tip.split('\n').map((line) => `<div${line.startsWith('• ') ? ' class="tip-bullet"' : ''}>${esc(line)}</div>`).join('');
  // Below the icon, or above it where there's no room below, and within the window (measured from the corner, at its full width)
  tip.el.style.left = tip.el.style.top = '0px';
  tip.el.hidden = false;
  const r = target.getBoundingClientRect(), w = tip.el.offsetWidth, h = tip.el.offsetHeight;
  tip.el.style.left = `${Math.max(8, Math.min(r.left - 10, window.innerWidth - w - 8))}px`;
  tip.el.style.top = `${r.bottom + 4 + h <= window.innerHeight - 8 ? r.bottom + 4 : Math.max(8, r.top - 4 - h)}px`;
}

function hideTip() {
  clearTimeout(tip.timer);
  clearTimeout(tip.showTimer);
  tip.pending = null;
  if (tip.el) tip.el.hidden = true;
  tip.target = null;
  tip.pinned = false;
}

// After a moment, so the pointer can slip off the icon, or move onto the note, without the note going away
function hideTipSoon() {
  clearTimeout(tip.timer);
  tip.timer = setTimeout(hideTip, 300);
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
// Whether only a feature trace knows the feature (no binary's symbols have it, nor the feature store). A trace sees what's checked while
// it runs, so such a feature counts in neither first seen nor the builds' added and removed features.
const traceOnly = (f) => Boolean(f.trace) && !(f.modules || []).length && !(f.declaredIn || []).length && !f.store;
// Whether a feature store entry is the rollout service's (priority Service): Windows writes those after it checks in with Microsoft, for
// features Microsoft is rolling out to a share of PCs or testing, so which ones a VM gets depends on the day and on chance, not on the build
const rolloutEntry = (c) => String(c.priority || '').startsWith('Service');
// The feature as the build itself has it, for comparing builds: without the rollout service's entries, or null if nothing else knows it
function asBuilt(f) {
  if (!(f.store || []).some(rolloutEntry)) return f;
  const store = f.store.filter((c) => !rolloutEntry(c));
  const out = { ...f, store: store.length ? store : undefined };
  return (out.modules || []).length || (out.declaredIn || []).length || out.store || out.trace ? out : null;
}
// The default the symbols give a feature (none for one only a feature trace gives)
const symbolDefault = (f) => f.symbolDefault || (f.defaultSource !== 'trace' ? f.default : undefined);
const checkedBy = (f) => ((f.trace.processes || []).length ? `checked by ${f.trace.processes.join(', ')}` : 'in the runtime trace');
// The modules, or for a feature only a trace has, the processes that checked it
const modsCell = {
  title: 'Modules', cls: 'mods',
  value: (f) => modsText(f) || (traceOnly(f) ? checkedBy(f) : ''),
  html: (f) => (traceOnly(f) ? `<span class="muted">${esc(checkedBy(f))}</span>` : esc(modsText(f))),
};
const TRACE_DEFAULT = 'From a feature trace: the stage compiled into the binaries that checked the feature while Windows ran';
const defaultCell = (f) => (f.defaultSource === 'trace' ? `<span class="trace-default" title="${esc(TRACE_DEFAULT)}">${esc(DEFAULTS[f.default])}</span>` : esc(DEFAULTS[f.default] || ''));

const TRACE_LIST_LIMIT = 8;  // The processes and targets a feature's trace entry keeps (update-data.py)
const onOff = (s) => (s === 'enabled' || s === 'alwaysEnabled' ? 'on' : s ? 'off' : '');

// derived/trace-targets/<build>.json: what a build's trace's app and Control Panel targets opened in full (a program with its folder, a
// link's command), by their labels
const traceTargets = new Map();
const loadTraceTargets = (key) => {
  if (!traceTargets.has(key)) traceTargets.set(key, getJson(`trace-targets/${key}.json`, DERIVED).catch(() => ({})));
  return traceTargets.get(key);
};

// A trace target's label: what was opened as code (between backticks in the data), and the name after it a little apart. Where it was
// opened from more than the label shows (an app's program's folder, a Control Panel link's command), hovering the program or the
// link's name shows that at once.
const targetHtml = (label, full) => {
  const tipped = full ? ` data-tip="${esc(full.includes('\n') ? full.split('\n').map((x) => '• ' + x).join('\n') : full)}" data-tip-path` : '';
  const quoted = !label.includes('`') && label.match(/^([^"]*)(".*")$/);
  if (quoted) return `${esc(quoted[1])}<span class="target-full"${tipped}>${esc(quoted[2])}</span>`;
  return label.split('`').map((part, i) => (i % 2 ? `<code${i === 1 ? tipped : ''}>${esc(part)}</code>`
    : i && part.startsWith(' ') ? `<span class="target-name">${esc(part.slice(1))}</span>` : esc(part))).join('');
};

// A trace entry's processes that checked the feature (the most checks first) and the targets it was checked on (the most particular to
// it first), as the rows of a panel's block
function traceLists(t, full) {
  const list = (title, items, html, cls = '') => (items.length
    ? `<div class="kv"><span>${title}</span><ul${cls}>${items.map((x) => `<li>${html(x)}</li>`).join('')}` +
      (items.length >= TRACE_LIST_LIMIT ? `<li class="muted" title="The data keeps up to ${TRACE_LIST_LIMIT}">…</li>` : '') + '</ul></div>' : '');
  return list('Found usage by', t.processes || [], esc) + list('Found triggers', t.targets || [], (x) => targetHtml(x, full[x]), ' class="targets"');
}

// What a build's feature trace saw of a feature, for its panel: who checked it, on what, and how the checks came out against the default
// they reported (the stage compiled into the binaries that made them). Where the symbols give the feature another default (the one the
// panel shows), that's noted too: the binaries that checked it may not be the ones that default is from.
function traceHtml(f, build, full) {
  const t = f.trace;
  const mixed = t.results.length > 1;
  const state = mixed ? 'Enabled and disabled' : t.results[0] === 'on' ? 'Enabled' : 'Disabled';
  const reported = [...new Set(t.stages.map(onOff))];
  const notes = [reported.length > 1 ? `defaults: ${reported.join(', ')}` : !mixed && t.results[0] === reported[0] ? 'matches default' : `default: ${reported[0]}`];
  const symbols = onOff(symbolDefault(f));
  if (symbols && reported.length === 1 && symbols !== reported[0]) notes.push(`symbols' default: ${symbols}`);
  return `<div class="mod"><h4>Runtime trace data</h4>${traceLists(t, full)}<p><b>Feature runtime state:</b> ` +
    `<span class="state ${mixed ? '' : t.results[0] === 'on' ? 'enabled' : 'disabled'}">${state}</span>` +
    ((t.variants || []).length ? `, variant ${esc(t.variants.join(', '))}` : '') +
    (notes.length ? ` <span class="muted">(${esc(notes.join('; '))})</span>` : '') + '</p></div>';
}

// Where another build's feature trace saw a feature used, for a build whose own trace didn't see it (or that has none). Only the
// processes and targets: the stages and results were that build's, whose panel the link leads to.
function otherTraceHtml(t, id, full) {
  return '<div class="mod"><h4>Runtime trace data</h4><h5>From other builds</h5>' +
    `<div class="kv"><span>Build</span><div class="val"><a href="${featureHref(t.build, id)}" title="Feature ${id} in ${esc(t.build)}">${esc(t.build)}</a></div></div>` +
    `${traceLists(t, full)}</div>`;
}

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
  // Each picker greys out the build the other one has, which it doesn't let be picked too
  $('cmp-old').setTaken(newKey, "Already selected as the new build; a build can't be compared with itself");
  $('cmp-new').setTaken(oldKey, "Already selected as the old build; a build can't be compared with itself");
  if (!oldKey || !newKey) return;
  const render = ++compareRender;  // A slower earlier render must not add to a newer one
  $('cmp-status').textContent = 'Loading…';
  out.innerHTML = '';
  const [a, b] = await Promise.all([loadBuild(oldKey), loadBuild(newKey)]);
  if (render !== compareRender) return;
  const built = (x) => new Map(x.features.map(asBuilt).filter(Boolean).map((f) => [f.id, f]));
  const of = built(a), nf = built(b);
  const added = [], removed = [], renamed = [], newlyNamed = [], nameLost = [], storeChanged = [], defaultChanged = [];
  for (const [id, f] of nf) {
    const o = of.get(id);
    if (!o) { if (!traceOnly(f)) added.push(f); continue; }
    if (o.name !== f.name) {
      if (!o.name) newlyNamed.push(f);
      else if (f.name) renamed.push({ id, oldName: o.name, newName: f.name, name: f.name, modules: f.modules });
      else nameLost.push({ id, oldName: o.name, name: o.name, modules: o.modules });
    }
    if (JSON.stringify(o.store || null) !== JSON.stringify(f.store || null)) {
      storeChanged.push({ id, name: f.name || o.name, modules: f.modules, oldStore: o.store, newStore: f.store });
    }
    // Only where both builds know the value; builds scanned before default states were read don't have them. The symbols' defaults, not
    // feature traces': a trace only has the binaries that checked the feature while it ran, which needn't be the same ones each time.
    const value = (x, k) => (k === 'default' ? symbolDefault(x) : x[k]);
    const known = ['default', 'changeTime'].filter((k) => value(o, k) && value(f, k));
    if (known.some((k) => value(o, k) !== value(f, k))) {
      const pick = (x) => Object.fromEntries(known.map((k) => [k, value(x, k)]));
      defaultChanged.push({ id, name: f.name || o.name, modules: f.modules, oldState: pick(o), newState: pick(f) });
    }
  }
  for (const [id, f] of of) if (!nf.has(id) && !traceOnly(f)) removed.push(f);

  const arch = b.architecture;
  const seenNames = { [a.key]: 'Old build', [b.key]: 'New build' };  // How the First seen column names the two builds
  const sections = [
    ['Added', 'added', added, [
      { title: 'ID', value: (f) => f.id, cls: 'id' },
      { title: 'Name', value: (f) => f.name, html: nameCell, cls: 'name wide' },
      { title: 'Feature store', value: (f) => storeText(f.store), cls: 'store' },
      { title: 'Modules', value: modsText, cls: 'mods' },
    ]],
    ['Removed', 'removed', removed, [
      { title: 'ID', value: (f) => f.id, cls: 'id' },
      { title: 'Name', value: (f) => f.name, html: nameCell, cls: 'name wide' },
      { title: 'First seen', value: (f) => firstSeenText(a.architecture, f.id, seenNames), html: (f) => firstSeenHtml(a.architecture, f.id, seenNames), sortKey: (f) => firstSeenRank(a.architecture, f.id), cls: 'seen' },
      { title: 'Modules', value: modsText, cls: 'mods' },
    ]],
    ['Renamed', 'changed', renamed, [
      { title: 'ID', value: (f) => f.id, cls: 'id' },
      { title: 'Old name', value: (f) => f.oldName, cls: 'name' },
      { title: 'New name', value: (f) => f.newName, cls: 'name' },
    ]],
    ['Newly named', 'changed', newlyNamed, [
      { title: 'ID', value: (f) => f.id, cls: 'id' },
      { title: 'Name', value: (f) => f.name, cls: 'name wide' },
      { title: 'First seen', value: (f) => firstSeenText(arch, f.id, seenNames), html: (f) => firstSeenHtml(arch, f.id, seenNames), sortKey: (f) => firstSeenRank(arch, f.id), cls: 'seen' },
      { title: 'Modules', value: modsText, cls: 'mods' },
    ]],
    ...(nameLost.length ? [['Name lost', 'changed', nameLost, [
      { title: 'ID', value: (f) => f.id, cls: 'id' },
      { title: 'Old name', value: (f) => f.oldName, cls: 'name wide' },
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
      { title: 'Old', value: (f) => stateText(f.oldState), sortKey: (f) => stateSortKey(f.oldState), cls: 'store' },
      { title: 'New', value: (f) => stateText(f.newState), sortKey: (f) => stateSortKey(f.newState), html: (f) => stateHtml(f.newState), cls: 'store' },
    ]],
  ];
  const detailOld = featureDetail(a), detailNew = featureDetail(b);
  const direction = compareVersions(a, b) > 0 ? ' (the "old" build is newer than the "new" one)' : '';
  $('cmp-status').textContent = `${buildLabel(a)} → ${buildLabel(b)}${direction}`;
  out.insertAdjacentHTML('beforeend', pendingNote(a) + pendingNote(b));
  for (const [title, cls, rows, cols] of sections) {
    const filtered = rows.filter((f) => matches(f, q, namedOnly));
    const sec = section(out, 'compare:' + title, 'h2', cls,
      `${esc(title)} <span class="count">${filtered.length}${filtered.length !== rows.length ? ' of ' + rows.length : ''}</span>`, filtered.length > 0);
    if (filtered.length) renderTable(sec, filtered, cols, undefined, title === 'Removed' ? detailOld : detailNew);
  }
  await renderSgmCompare(out, a, b, q, () => render === compareRender);
  await renderResourcesCompare(out, a, b, q, () => render === compareRender);
}

// ---------------------------------------------------------------------------
// Browse view
// ---------------------------------------------------------------------------

let buildRender = 0;

async function renderBuild() {
  const key = $('bld-select').value;
  const q = $('bld-search').value.trim().toLowerCase();
  const namedOnly = $('bld-named').checked, storeOnly = $('bld-store').checked, newOnly = $('bld-new').checked, tracedOnly = $('bld-traced').checked;
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
  const hit = (f) => matches(f, q, namedOnly) || (detailText !== null && (!namedOnly || f.name) && (detailText.get(f.id) || '').includes(q));
  const rows = b.features.filter((f) => hit(f) && (!storeOnly || f.store) && (!newOnly || firstSeenKeys(arch, f.id).includes(key)) && (!tracedOnly || f.trace));
  const firstTracked = isEarliestBuild(b);
  const thisBuild = { [key]: 'This build' };  // How the First seen column names this build
  const traced = b.features.filter((f) => f.trace).length;
  $('bld-status').textContent = `${buildLabel(b)}: ${b.features.length} feature IDs, ${b.features.filter((f) => f.name).length} named, ` +
    `${b.features.filter((f) => f.store).length} in the feature store${traced ? `, ${traced} with runtime details` : ''}. Showing ${rows.length}.` +
    (newOnly && firstTracked ? ' This is the first tracked build, so every ID counts as new here.' : '') +
    (tracedOnly && !traced ? ' This build has no feature trace.' : '');
  out.insertAdjacentHTML('beforeend', pendingNote(b));
  if (b.trace && tracedOnly) {
    const t = b.trace, only = b.features.filter(traceOnly).length;
    out.insertAdjacentHTML('beforeend', `<p class="notice"><b>Feature trace:</b> Windows wrote an event each time its code checked a feature, ` +
      `for ${t.minutes} minutes on <time>${esc((t.tracedAt || '').slice(0, 10))}</time>${t.boot ? ' from boot' : ''}, while the trace opened ` +
      `${fmt(t.targets || 0)} settings pages, folders, apps and parts of the shell one at a time. It saw ${fmt(traced)} features checked` +
      (only ? `, ${fmt(only)} of them in no binary's symbols or the feature store` : '') + '. A feature only shows up if code that checks it ran, ' +
      'so this is a sample of what Windows uses, not everything it has.</p>');
  }
  if (firstTracked) {
    const several = earliestBuilds.get(arch).length > 1;
    out.insertAdjacentHTML('beforeend', `<p class="notice"><b>${esc(buildLabel(b))}:</b> This is ${several ? 'one of the earliest' : 'the earliest'} ` +
      `${esc(archName(arch))} build${several ? 's' : ''} scanned. ` +
      'With no earlier scan to compare it with, every feature in it counts as first seen here by default, so the First seen column shows N/A.</p>');
  }
  renderTable(out, rows, [
    { title: 'ID', value: (f) => f.id, cls: 'id' },
    { title: 'Name', value: (f) => f.name, html: nameCell, cls: 'name' },
    { title: 'Default', value: (f) => DEFAULTS[f.default] || '', html: defaultCell, sortKey: (f) => DEFAULT_ORDER[f.default] || '', cls: 'store' },
    firstTracked ? { title: 'First seen', value: () => 'N/A', cls: 'seen' }
      : { title: 'First seen', value: (f) => firstSeenText(arch, f.id, thisBuild), html: (f) => firstSeenHtml(arch, f.id, thisBuild), sortKey: (f) => firstSeenRank(arch, f.id), cls: 'seen' },
    { title: 'Feature store', value: (f) => storeText(f.store), cls: 'store' },
    modsCell,
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
    "from Microsoft's update history, Insider release notes and Windows Update, checked daily. " +
    `x64 builds of ${esc(vm.join(', '))} are scanned in a virtual machine built from Microsoft's servers as they come out; ` +
    "ARM64 builds are scanned when GitHub's ARM64 runner has them. " +
    (releases.insider.some((c) => c.scannedInVm)
      ? "Each Insider channel's newest build is scanned in a virtual machine made from the build's own files from Windows Update, which only has a channel's newest build; Release Preview's builds are scanned as the updates they become.</p>"
      : 'Insider builds are not scanned yet.</p>');

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
      // Only a channel's newest build can be scanned (Windows Update has no other)
      const due = c.scannedInVm && i === 0 && (!scanned || compareVersions(r, scanned) > 0);
      html += '<tr>' + (i === 0 ? groupCell(c.channel, c.releases.length, n === releases.insider.length - 1) : '') +
        `<td class="id">${esc(r.builds.join(' / '))}</td><td>${esc(r.date || '')}</td>` +
        // (A build the release notes don't list has the date Windows Update gives with it)
        `<td>${r.notes ? `<a href="${esc(r.notes)}">${esc(r.notes.split('/').pop())}</a>`
          : `<span class="muted" title="Not in the release notes: the build ${esc(r.source || '')} gives the channel">${esc(r.source || '')}</span>`}</td>` +
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
  // Compare the newest released build that has an earlier one to compare with (a first build of an architecture has none)
  const compared = [...index.builds].filter((b) => b.previous && !b.insiderChannel).sort(compareVersions).pop() || latest;
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
  for (const id of ['bld-select', 'bld-named', 'bld-store', 'bld-new', 'bld-traced', 'bld-details']) $(id).addEventListener('change', bld);
  $('bld-search').addEventListener('input', debounce(bld, 250));
  // The copy buttons of feature panels, which are added and removed with the panels
  document.addEventListener('click', (e) => {
    const button = e.target.closest('button.copy-ids');
    if (button) copyIds(button);
  });
  // Info icons' notes (showTip): on hover with a mouse or pen
  document.addEventListener('pointerover', (e) => {
    const t = e.target.closest('[data-tip]');
    if (!t || e.pointerType === 'touch') return;
    if (t === tip.target) {
      clearTimeout(tip.timer);
    } else if (t !== tip.pending) {
      clearTimeout(tip.showTimer);
      tip.pending = t;
      tip.showTimer = setTimeout(() => showTip(t, false), 'tipPath' in t.dataset ? 0 : 200);
    }
  });
  document.addEventListener('pointerout', (e) => {
    const t = e.target.closest('[data-tip]');
    if (!t || t.contains(e.relatedTarget)) return;
    if (t === tip.pending) {
      clearTimeout(tip.showTimer);
      tip.pending = null;
    }
    if (t === tip.target && !tip.pinned) hideTipSoon();
  });
  // A click or tap on an icon shows its note until the next one elsewhere (or hides it, when it's already shown that way), and does
  // nothing else, such as opening a table row's details
  document.addEventListener('click', (e) => {
    const t = e.target.closest('[data-tip]');
    if (!t) return;
    e.stopPropagation();
    if (t === tip.target && tip.pinned) hideTip();
    else showTip(t, true);
  }, true);
  document.addEventListener('pointerdown', (e) => {
    if (tip.target && !e.target.closest('[data-tip]') && !tip.el.contains(e.target)) hideTip();
  }, true);
  document.addEventListener('keydown', (e) => { if (e.key === 'Escape' && tip.target) hideTip(); });
  // (A note stays where it was put, so it goes when what's under it moves)
  document.addEventListener('scroll', () => { if (tip.target) hideTip(); }, true);
  window.addEventListener('resize', () => { if (tip.target) hideTip(); });
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
