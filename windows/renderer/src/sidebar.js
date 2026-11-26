// Left library sidebar: element tiles, element groups, fragment library and recent files; periodic-table popover.
import { h, $, clear } from './dom.js';
import { element, cssColor, textOn, tablePosition, category, ELEMENTS } from './elements.js';
import { api, request } from './api.js';

const COMMON = [1, 6, 7, 8, 9, 15, 16, 17, 35, 53, 5, 14, 3, 11, 12, 26];

export function buildSidebar(app) {
  const root = $('#library');
  const tiles = h('div.tiles');
  const recentTiles = h('div.tiles');
  const search = h('input.frag-search', { type: 'search', placeholder: 'Filter fragments', oninput: () => renderFragments() });
  const frags = h('div');
  const recent = h('div.recent-files');
  const groupTitle = h('span', {}, 'Groups');
  const groupChips = h('div.grp-chips');
  const groupSection = h('div.section', {}, h('h3', {}, groupTitle), groupChips);
  root.append(
    h('div.section', {}, h('h3', {}, 'Elements', h('span.grow'), h('button.link', { onclick: () => app.command('build.periodic'), title: 'Periodic table (Ctrl+T)' }, 'Periodic table…')), tiles),
    groupSection,
    h('div.section', {}, h('h3', {}, 'Recently used'), recentTiles),
    h('div.section', {}, h('h3', {}, 'Fragments'), search, frags),
    h('div.section', {}, h('h3', {}, 'Recent files'), recent),
  );
  const tile = (z) => h('button.tile', {
    title: `${element(z).name} (${z})`, dataset: { z },
    style: { background: cssColor(z), color: textOn(z) },
    onclick: () => app.setPayload({ kind: 'element', z }),
  }, h('small', {}, z), element(z).symbol);
  for (const z of COMMON) tiles.append(tile(z));
  const renderRecent = () => { clear(recentTiles); for (const z of app.settings.recentElements.slice(0, 8)) recentTiles.append(tile(z)); mark(); };
  const mark = () => {
    const p = app.payload;
    for (const t of root.querySelectorAll('.tile')) t.classList.toggle('on', (p.kind === 'element' || p.kind === 'group') && Number(t.dataset.z) === p.z);
    for (const t of root.querySelectorAll('.frag')) t.classList.toggle('on', p.kind === 'fragment' && t.dataset.id === p.id);
    for (const c of groupChips.children) c.classList.toggle('on', payloadKey(p) === c.dataset.key);
  };
  // Atom alone / hybridization / functional-group chips for the current element (GaussView-style).
  let groupZ = null;
  const renderGroups = async () => {
    const p = app.payload;
    const z = p.kind === 'element' || p.kind === 'group' ? p.z : null;
    groupSection.hidden = z == null;
    if (z == null || (z === groupZ && groupChips.children.length > 1)) { mark(); return; }
    groupZ = z;
    groupTitle.textContent = `${element(z).symbol}: atom or group`;
    const items = await groupItems(z);
    if (groupZ !== z) return;
    clear(groupChips);
    for (const it of items) {
      groupChips.append(h('button.grp-chip', { dataset: { key: payloadKey(it.payload) }, title: it.title, onclick: () => app.setPayload(it.payload) }, it.label));
    }
    mark();
  };
  const renderFragments = () => {
    clear(frags);
    const q = search.value.trim().toLowerCase();
    const list = app.fragments.filter((f) => !q || f.name.toLowerCase().includes(q) || f.category.toLowerCase().includes(q) || f.id.toLowerCase().includes(q));
    if (!list.length) { frags.append(h('div.empty', {}, app.fragments.length ? 'No matches' : 'No fragments (engine not ready)')); return; }
    const byCat = new Map();
    for (const f of list) { const c = f.categoryTitle || f.category; if (!byCat.has(c)) byCat.set(c, []); byCat.get(c).push(f); }
    for (const [cat, items] of byCat) {
      frags.append(h('div.frag-cat', {}, cat));
      const grid = h('div.frags');
      for (const f of items) {
        const c = h('canvas', { width: 144, height: 112 });
        drawThumbnail(c, f.molecule);
        grid.append(h('button.frag', { dataset: { id: f.id }, title: `${f.name}: click to pick, then click in the view (or on an atom to attach)`, onclick: () => app.setPayload({ kind: 'fragment', id: f.id, name: f.name }) }, c, h('span', {}, f.name)));
      }
      frags.append(grid);
    }
    mark();
  };
  const renderRecentFiles = async () => {
    const list = await api.recentFiles();
    clear(recent);
    if (!list.length) { recent.append(h('div.empty', {}, 'Nothing yet')); return; }
    for (const p of list.slice(0, 8)) recent.append(h('button', { title: p, onclick: () => app.openPath(p) }, p.split(/[\\/]/).pop()));
  };
  app.on('fragments', () => { renderFragments(); groupZ = null; renderGroups(); });
  app.on('payload', () => { renderRecent(); renderGroups(); mark(); });
  app.on('docs', renderRecentFiles);
  renderRecent(); renderFragments(); renderRecentFiles(); renderGroups();
}

// ---------- element groups (engine `build.groups`, MolBuild GroupLibrary) ----------

let groupCache = null;
async function loadGroups() {
  if (groupCache) return groupCache;
  try {
    const r = await request('build.groups', {});
    const map = new Map();
    for (const g of r.groups || []) { if (!map.has(g.element)) map.set(g.element, []); map.get(g.element).push(g); }
    groupCache = map;
  } catch { return new Map(); }   // engine not ready (or an old engine): try again next time
  return groupCache;
}

const payloadKey = (p) => (p.kind === 'group' ? 'g:' + p.id : p.kind === 'element' ? 'e:' + p.z : 'f:' + p.id);

/** Picker items for element z: the atom with automatic hydrogens first, then hybridized atoms and groups. */
async function groupItems(z) {
  const e = element(z);
  const groups = (await loadGroups()).get(z) || [];
  const items = [{ label: `${e.symbol} atom`, title: `${e.name}: hydrogens are added to suit its bonds`, payload: { kind: 'element', z }, molecule: null, kind: 'atom' }];
  for (const g of groups) {
    const bond = g.bondOrder === 2 ? ' (double bond to the clicked atom)' : g.bondOrder === 3 ? ' (triple bond to the clicked atom)' : '';
    items.push({ label: g.label, title: g.name + bond,
      payload: { kind: 'group', id: g.id, z, name: g.name, label: g.label }, molecule: g.molecule, kind: g.kind });
  }
  return items;
}

/** 2D thumbnail drawn from the fragment's own geometry (depth-sorted discs and bonds). */
export function drawThumbnail(canvas, mol, { bg = null } = {}) {
  const ctx = canvas.getContext('2d');
  const W = canvas.width, H = canvas.height;
  ctx.clearRect(0, 0, W, H);
  if (bg) { ctx.fillStyle = bg; ctx.fillRect(0, 0, W, H); }
  if (!mol || !mol.atoms?.length) return;
  // Principal-ish orientation: tilt slightly so planar rings read as 3D.
  const ax = -0.45, ay = 0.35;
  const rot = (p) => {
    let [x, y, z] = p;
    let y1 = y * Math.cos(ax) - z * Math.sin(ax), z1 = y * Math.sin(ax) + z * Math.cos(ax);
    let x2 = x * Math.cos(ay) + z1 * Math.sin(ay), z2 = -x * Math.sin(ay) + z1 * Math.cos(ay);
    return [x2, y1, z2];
  };
  const P = mol.atoms.map((a) => rot(a.pos));
  const cx = P.reduce((s, p) => s + p[0], 0) / P.length, cy = P.reduce((s, p) => s + p[1], 0) / P.length;
  let ext = 0.8;
  for (const p of P) ext = Math.max(ext, Math.abs(p[0] - cx) * (H / W), Math.abs(p[1] - cy));
  const k = (Math.min(W, H) * 0.42) / (ext + 0.5);
  const sx = (p) => W / 2 + (p[0] - cx) * k, sy = (p) => H / 2 - (p[1] - cy) * k;
  const items = [];
  for (const b of mol.bonds) items.push({ z: (P[b.a][2] + P[b.b][2]) / 2 - 0.01, bond: b });
  mol.atoms.forEach((a, i) => items.push({ z: P[i][2], atom: i }));
  items.sort((a, b) => a.z - b.z);
  for (const it of items) {
    if (it.bond) {
      const { a, b, order } = it.bond;
      ctx.strokeStyle = '#8a8f98'; ctx.lineWidth = Math.max(1.5, k * 0.11); ctx.lineCap = 'round';
      if (order >= 2) {
        const dx = sx(P[b]) - sx(P[a]), dy = sy(P[b]) - sy(P[a]); const l = Math.hypot(dx, dy) || 1;
        const ox = (-dy / l) * k * 0.09, oy = (dx / l) * k * 0.09;
        for (const s of order === 3 ? [-1.6, 0, 1.6] : [-1, 1]) {
          ctx.beginPath(); ctx.moveTo(sx(P[a]) + ox * s, sy(P[a]) + oy * s); ctx.lineTo(sx(P[b]) + ox * s, sy(P[b]) + oy * s); ctx.stroke();
        }
      } else {
        if (order === 1.5) ctx.setLineDash([]);
        ctx.beginPath(); ctx.moveTo(sx(P[a]), sy(P[a])); ctx.lineTo(sx(P[b]), sy(P[b])); ctx.stroke();
      }
    } else {
      const a = mol.atoms[it.atom]; const r = Math.max(2.5, k * (a.z === 1 ? 0.2 : 0.3));
      const x = sx(P[it.atom]), y = sy(P[it.atom]);
      const g = ctx.createRadialGradient(x - r * 0.35, y - r * 0.35, r * 0.1, x, y, r);
      g.addColorStop(0, '#ffffff'); g.addColorStop(0.35, cssColor(a.z)); g.addColorStop(1, shade(cssColor(a.z), 0.55));
      ctx.fillStyle = g; ctx.beginPath(); ctx.arc(x, y, r, 0, Math.PI * 2); ctx.fill();
      ctx.strokeStyle = 'rgba(0,0,0,0.25)'; ctx.lineWidth = 0.8; ctx.stroke();
    }
  }
}

function shade(hex, f) {
  const n = parseInt(hex.slice(1), 16);
  const r = Math.round(((n >> 16) & 255) * f), g = Math.round(((n >> 8) & 255) * f), b = Math.round((n & 255) * f);
  return `rgb(${r},${g},${b})`;
}

/** Thumbnail for "the atom alone": an element disc with its symbol. */
function drawAtomTile(canvas, z) {
  const ctx = canvas.getContext('2d');
  const W = canvas.width, H = canvas.height, r = Math.min(W, H) * 0.3;
  ctx.clearRect(0, 0, W, H);
  const g = ctx.createRadialGradient(W / 2 - r * 0.35, H / 2 - r * 0.35, r * 0.1, W / 2, H / 2, r);
  g.addColorStop(0, '#ffffff'); g.addColorStop(0.35, cssColor(z)); g.addColorStop(1, shade(cssColor(z), 0.55));
  ctx.fillStyle = g; ctx.beginPath(); ctx.arc(W / 2, H / 2, r, 0, Math.PI * 2); ctx.fill();
  ctx.fillStyle = textOn(z); ctx.font = `600 ${Math.round(r * 0.9)}px system-ui, sans-serif`;
  ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
  ctx.fillText(element(z).symbol, W / 2, H / 2 + 1);
}

/**
 * Periodic table popover: compact, anchored at the viewer's top-left corner, with a GaussView-style picker below
 * the table (the atom alone, hybridized atoms, functional groups). Clicking an element picks the plain atom and
 * keeps the popover open; picking a group (or double-clicking an element, Enter, Esc, clicking outside) closes it.
 */
let openPopover = null;
export function openPeriodicTable(app) {
  if (openPopover) { openPopover.close(); return; }
  const grid = h('div.ptp-grid');
  const info = h('div.ptp-info', {}, 'Pick an element, then the atom alone or a group.');
  const groupHead = h('div.ptp-ghead');
  const groupGrid = h('div.ptp-groups');
  const pop = h('div.ptp', { role: 'dialog', 'aria-label': 'Periodic table' },
    h('div.ptp-head', {}, h('span.ptp-title', {}, 'Periodic table'), h('span.grow'),
      h('button.icon-btn.close', { title: 'Close (Esc)', innerHTML: '&#x2715;', onclick: () => close() })),
    grid, info, groupHead, groupGrid);
  let selZ = app.payload.kind === 'element' || app.payload.kind === 'group' ? app.payload.z : 6;
  const tiles = new Map();
  for (let z = 1; z <= 118; z++) {
    const [row, col] = tablePosition(z);
    const e = element(z);
    const b = h('button.ptp-el.ptc-' + category(z), {
      style: { gridRow: String(row), gridColumn: String(col) },
      title: `${e.name} (${z})`,
      onmouseenter: () => { info.textContent = `${e.name} · Z ${z} · ${e.mass} u · covalent r ${e.covalent.toFixed(2)} Å · vdW r ${e.vdw.toFixed(2)} Å`; },
      onclick: () => { app.setPayload({ kind: 'element', z }); select(z); },
      ondblclick: () => close(),
    }, h('small', {}, z), e.symbol);
    tiles.set(z, b);
    grid.append(b);
  }
  grid.append(h('div.ptp-gap', { style: { gridRow: '8', gridColumn: '1 / -1' } }));
  const markGroups = () => { for (const c of groupGrid.children) c.classList.toggle('on', c.dataset.key === payloadKey(app.payload)); };
  async function select(z) {
    selZ = z;
    for (const [k, t] of tiles) t.classList.toggle('on', k === z);
    groupHead.textContent = `${element(z).name}: the atom alone or a group`;
    const items = await groupItems(z);
    if (selZ !== z || !openPopover) return;
    clear(groupGrid);
    for (const it of items) {
      const c = h('canvas', { width: 104, height: 72 });
      if (it.molecule) drawThumbnail(c, it.molecule); else drawAtomTile(c, z);
      groupGrid.append(h('button.ptp-grp' + (it.kind === 'atom' ? '.atom' : ''), {
        dataset: { key: payloadKey(it.payload) }, title: it.title,
        onclick: () => { app.setPayload(it.payload); close(); },
      }, c, h('span', {}, it.label)));
    }
    markGroups();
  }
  const place = () => {
    const host = document.querySelector('#viewport-wrap') || document.body;
    const r = host.getBoundingClientRect();
    const top = Math.max(8, r.top + 10);
    pop.style.left = Math.max(8, r.left + 10) + 'px';
    pop.style.top = top + 'px';
    pop.style.maxHeight = Math.max(240, window.innerHeight - top - 12) + 'px';
  };
  const onKey = (ev) => {
    if (ev.key === 'Escape' || ev.key === 'Enter') { ev.stopPropagation(); ev.preventDefault(); close(); }
  };
  // Clicks outside close it; the toolbar's element button toggles it itself.
  const onDown = (ev) => { if (!pop.contains(ev.target) && !ev.target.closest?.('.element-btn')) close(); };
  const unsubscribe = app.on('payload', markGroups);
  function close() {
    if (!openPopover) return;
    openPopover = null;
    pop.remove();
    document.removeEventListener('keydown', onKey, true);
    document.removeEventListener('mousedown', onDown, true);
    window.removeEventListener('resize', place);
    unsubscribe?.();
  }
  openPopover = { close };
  document.body.append(pop);
  place();
  document.addEventListener('keydown', onKey, true);
  document.addEventListener('mousedown', onDown, true);
  window.addEventListener('resize', place);
  select(selZ);
}

/**
 * Smoke test (VIBEVIEW_SMOKE_BUILD): steps separated by ';' go through the same Place-tool path as clicks.
 * `<groupId>` places it in empty space, `<groupId>@H` clicks the last hydrogen, `<groupId>@<n>` clicks atom n,
 * `periodic:<Symbol>` opens the periodic-table popover with that element picked (left open for the screenshot).
 */
export async function smokeBuild(app, spec, log) {
  let ok = true;
  for (const step of spec.split(';').map((s) => s.trim()).filter(Boolean)) {
    try {
      if (step.startsWith('periodic:')) {
        const sym = step.slice(9).toLowerCase();
        const e = ELEMENTS.find((x) => x.symbol.toLowerCase() === sym);
        if (!openPopover) openPeriodicTable(app);
        if (e) document.querySelectorAll('.ptp-el')[e.z - 1]?.click();
        await new Promise((r) => setTimeout(r, 500));
        log(`build: periodic ${sym}: ${document.querySelectorAll('.ptp-grp').length} picker items`);
        continue;
      }
      const [id, target] = step.split('@');
      const z = elementBySymbolPrefix(id);
      app.setPayload(/^[A-Z][a-z]?$/.test(id) ? { kind: 'element', z } : { kind: 'group', id, z, name: id, label: id });
      const m = app.active.molecule;
      let pick = null;
      if (target === 'H') { for (let i = m.atoms.length - 1; i >= 0; i--) if (m.atoms[i].z === 1 && m.bonds.some((b) => b.a === i || b.b === i)) { pick = { kind: 'atom', index: i }; break; } }
      else if (target != null) pick = { kind: 'atom', index: Number(target) };
      const rect = app.viewport.renderer?.domElement?.getBoundingClientRect?.() || { width: 800, height: 600 };
      await app.placeAt(rect.width / 2, rect.height / 2, pick);
      const mol = app.active.molecule;
      log(`build: ${step} -> ${mol.atoms.length} atoms, ${mol.bonds.length} bonds (${app.active.summary.formula})`);
    } catch (e) { ok = false; log(`build: ${step} failed: ${e.message || e}`); }
  }
  app.viewport.fit?.();
  return { ok };
}
function elementBySymbolPrefix(id) {
  const sym = id.split('.')[0].toLowerCase();
  return ELEMENTS.find((x) => x.symbol.toLowerCase() === sym)?.z ?? 6;
}

export { ELEMENTS };
