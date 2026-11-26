// Z-Matrix tab (results panel) and the Build > From Z-Matrix… dialog.
//
// - Table of the current molecule as a Z-matrix (connectivity-following or input order). Hovering a row highlights the
//   atom and its reference atoms in the viewport, clicking selects the atom. Editing a distance/angle/dihedral moves the
//   structure (engine `zmatrix.edit`, one undo step), like Molden's Z-matrix editor. Reference cells take atom numbers.
// - Text view (Gaussian, with or without variables, or ORCA `* int`), editable: Apply keeps atom indices when the atoms
//   match, otherwise it replaces the structure; "New document" opens it as a new document.
// - Incremental builder: element + reference atoms (default: selection / last atom and its neighbours) + distance,
//   angle and dihedral (defaults from covalent radii and hybridisation via `zmatrix.addAtom {dryRun}`).
import { h, clear, segmented, modal, toast } from './dom.js';
import { request } from './api.js';
import { elementBySymbol } from './elements.js';

let activeTab = null;

/** Per-document view state (survives tab rebuilds). */
const STATE = new WeakMap();
function stateOf(d) {
  let s = STATE.get(d);
  if (!s) { s = { ordering: 'connectivity', view: 'table', variables: false, order: null, refs: null, builder: { symbol: 'C', bondOrder: 1, addH: false } }; STATE.set(d, s); }
  return s;
}

const SAMPLE = `0 1
C
C  1  1.53
H  1  1.09  2  110.0
H  1  1.09  2  110.0  3  120.0
H  1  1.09  2  110.0  3  -120.0
H  2  1.09  1  110.0  3  180.0
H  2  1.09  1  110.0  6  120.0
H  2  1.09  1  110.0  6  -120.0
`;

/** Opens a document from an engine `zmatrix.apply` result (mode "new"). */
function openCreated(app, r) {
  const blank = app.active && !app.active.path && !app.active.dirty && !app.active.molecule.atoms.length ? app.active : null;
  const d = app.makeDoc(r.summary, r.molecule);
  d.name = r.summary.title || 'Z-Matrix';
  d.dirty = true;
  if (blank) app.closeDoc(blank, { force: true, silent: true });
  app.activate(d, { fit: true });
  return d;
}

/** Applies a molecule returned by a zmatrix.* edit to the document. */
function applyResult(app, d, r, { fit = false } = {}) {
  app.applyMolecule(d, r.molecule, r.summary, { keepSelection: true, fit });
  d.dirty = true; app.updateTitle();
}

// ---------------------------------------------------------------- tab
export function buildZMatrixTab(app, d, body) {
  const st = stateOf(d);
  const vp = app.viewport;
  const left = h('div.pane.zm-main');
  const right = h('div.pane.fixed.zm-builder');
  body.append(left, right);
  const tools = h('div.zm-tools');
  const content = h('div.zm-content');
  const status = h('div.zm-status');
  left.append(tools, content, status);
  let data = null; let disposed = false; let seq = 0; let skipRefresh = false; let rowEls = []; let hoverRow = -1;

  const orderingSeg = segmented([{ value: 'connectivity', label: 'Connectivity', title: 'Order atoms along bonds (references are bonded neighbours)' }, { value: 'input', label: 'Input order', title: 'Keep the document atom order' }],
    st.ordering, (v) => { st.ordering = v; st.order = null; st.refs = null; refresh(); });
  const viewSeg = segmented([{ value: 'table', label: 'Table' }, { value: 'gaussian', label: 'Gaussian' }, { value: 'orca', label: 'ORCA' }], st.view, (v) => { st.view = v; render(); });
  const varsBox = h('input', { type: 'checkbox', checked: st.variables, onchange: () => { st.variables = varsBox.checked; render(); } });
  const varsLabel = h('label.zm-check', { title: 'Gaussian text with a variables section (R2, A3, D4…)' }, varsBox, 'Variables');
  tools.append(orderingSeg, viewSeg, varsLabel, h('span.grow'),
    h('button.btn.small', { title: 'Copy the Z-matrix text', onclick: () => copyText() }, 'Copy'),
    h('button.btn.small', { title: 'Type or paste a Z-matrix (Build > From Z-Matrix…)', onclick: () => openZMatrixDialog(app) }, 'Paste…'));

  const label = (atom) => {
    const a = d.molecule.atoms[atom];
    return a ? `${a.symbol}${atom + 1}` : `#${atom + 1}`;
  };

  async function refresh() {
    const my = ++seq;
    const n = d.molecule.atoms.length;
    if (!n) { data = null; render(); return; }
    const params = { docId: d.docId, ordering: st.ordering, variables: false };
    if (st.order && st.order.length === n) { params.order = st.order; if (st.refs && st.refs.length === n) params.refs = st.refs; }
    try {
      const r = await request('zmatrix.get', params);
      if (disposed || my !== seq) return;
      take(r);
    } catch (e) {
      if (disposed || my !== seq) return;
      if (params.refs) { st.refs = null; st.order = null; refresh(); return; }
      data = null; clear(content).append(h('div.empty', {}, e.message)); status.textContent = '';
    }
  }
  function take(r) {
    data = r; st.order = r.order; st.refs = r.refs;
    render();
  }

  function render() {
    viewSeg.setValue(st.view);
    varsLabel.hidden = st.view !== 'gaussian';
    clear(content); rowEls = [];
    if (!data) { content.append(h('div.empty', {}, d.molecule.atoms.length ? 'Loading…' : 'No atoms yet: add one with the builder on the right, or paste a Z-matrix.')); status.textContent = ''; return; }
    if (st.view === 'table') renderTable(); else renderText();
    const bondedRefs = data.rows.filter((r) => r.row > 0 && !r.bonded).length;
    status.textContent = `${data.rows.length} rows · ${st.ordering === 'connectivity' ? 'connectivity order' : 'input order'}${bondedRefs ? ` · ${bondedRefs} distance reference${bondedRefs > 1 ? 's are' : ' is'} not a bond` : ''} · edit a value and press Enter (Ctrl+Z undoes)`;
    syncSelection();
  }

  function numInput(row, field, value, digits) {
    const inp = h('input.zm-num', { type: 'text', value: value.toFixed(digits), spellcheck: false, title: `${field === 'bond' ? 'Distance (Å)' : field === 'angle' ? 'Angle (°)' : 'Dihedral (°)'}: Enter applies, Esc reverts, ↑/↓ step` });
    const orig = inp.value;
    const commit = async () => {
      const v = Number(inp.value.replace(',', '.'));
      if (inp.value === orig) return;
      if (!Number.isFinite(v)) { inp.value = orig; toast('Not a number', { kind: 'warn' }); return; }
      await editValue(row.row, field, v);
    };
    inp.addEventListener('keydown', (e) => {
      if (e.key === 'Enter') { e.preventDefault(); commit(); }
      else if (e.key === 'Escape') { e.stopPropagation(); inp.value = orig; inp.blur(); }
      else if (e.key === 'ArrowUp' || e.key === 'ArrowDown') {
        e.preventDefault();
        const step = (field === 'bond' ? 0.01 : 1) * (e.shiftKey ? 10 : 1) * (e.key === 'ArrowUp' ? 1 : -1);
        const v = Number(inp.value) + step; inp.value = v.toFixed(digits); commit();
      }
    });
    inp.addEventListener('change', commit);
    return inp;
  }

  function refInput(row, k) {
    const rowIdx = [row.bondRow, row.angleRow, row.dihedralRow][k];
    const atom = [row.bondAtom, row.angleAtom, row.dihedralAtom][k];
    const inp = h('input.zm-ref', { type: 'text', value: String(atom + 1), spellcheck: false, title: `${label(atom)} (row ${rowIdx + 1}). Type another atom number to change the reference; it must come earlier in the Z-matrix.` });
    const orig = inp.value;
    const commit = () => {
      if (inp.value === orig) return;
      const target = Number(inp.value) - 1;
      const targetRow = data.order.indexOf(target);
      if (!Number.isInteger(target) || targetRow < 0) { inp.value = orig; toast('No such atom', { kind: 'warn' }); return; }
      if (targetRow >= row.row) { inp.value = orig; toast(`${label(target)} comes after ${label(row.atom)} in the Z-matrix; references must be earlier rows`, { kind: 'warn' }); return; }
      const refs = data.refs.map((x) => [...x]);
      refs[row.row][k] = targetRow;
      st.refs = refs; refresh();
    };
    inp.addEventListener('keydown', (e) => { if (e.key === 'Enter') { e.preventDefault(); commit(); } else if (e.key === 'Escape') { e.stopPropagation(); inp.value = orig; inp.blur(); } });
    inp.addEventListener('change', commit);
    return inp;
  }

  function renderTable() {
    const tbl = h('table.list.zm-table', {}, h('tr', {},
      h('th.num', {}, '#'), h('th', {}, 'Atom'),
      h('th', {}, 'Bond to'), h('th.num', {}, 'Distance (Å)'),
      h('th', {}, 'Angle to'), h('th.num', {}, 'Angle (°)'),
      h('th', {}, 'Dihedral to'), h('th.num', {}, 'Dihedral (°)')));
    for (const row of data.rows) {
      const cells = [h('td.num.dim', {}, String(row.row + 1)), h('td.zm-atom', {}, label(row.atom))];
      const pair = (k, field, value, digits) => {
        if (value == null) { cells.push(h('td'), h('td')); return; }
        cells.push(h('td', {}, refInput(row, k)), h('td.num', {}, numInput(row, field, value, digits)));
      };
      pair(0, 'bond', row.bond, 4); pair(1, 'angle', row.angle, 2); pair(2, 'dihedral', row.dihedral, 2);
      const tr = h('tr', {
        class: row.row > 0 && !row.bonded ? 'zm-nobond' : null,
        onmouseenter: () => highlight(row.row), onmouseleave: () => highlight(-1),
        onclick: (e) => { if (e.target.tagName === 'INPUT') return; app.setSelection(e.shiftKey ? [...d.selection, row.atom] : [row.atom]); },
      }, cells);
      rowEls.push(tr);
      tbl.append(tr);
    }
    content.append(tbl);
  }

  function currentText() {
    if (!data) return '';
    if (st.view === 'orca') return data.orca;
    return st.variables ? data.gaussianVariables : data.gaussian;
  }
  function renderText() {
    const ta = h('textarea.zm-text', { spellcheck: false, value: currentText() });
    const err = h('div.errors');
    const apply = async (newDocument) => {
      try {
        const r = await request('zmatrix.apply', newDocument ? { text: ta.value, newDocument: true, title: `${d.name.replace(/\.[^.]+$/, '')} (Z-matrix)` } : { docId: d.docId, text: ta.value, order: data.order });
        if (newDocument) { openCreated(app, r); return; }
        applyResult(app, d, r, { fit: r.mode === 'replace' });
        app.status(r.mode === 'positions' ? 'Z-matrix applied' : 'Structure replaced from the Z-matrix');
      } catch (e) { err.textContent = e.message; }
    };
    content.append(ta, err, h('div.btn-row', {},
      h('button.btn.small.primary', { onclick: () => apply(false), title: 'Same atoms in the same order: move them (bonds and atom numbers kept). Otherwise: replace the structure. One undo step.' }, 'Apply to structure'),
      h('button.btn.small', { onclick: () => apply(true) }, 'Open as new document'),
      h('button.btn.small', { onclick: () => { ta.value = currentText(); err.textContent = ''; } }, 'Revert')));
  }

  async function copyText() {
    const t = st.view === 'orca' ? data?.orca : (st.variables ? data?.gaussianVariables : data?.gaussian);
    if (!t) return;
    try { await navigator.clipboard.writeText(t); app.status('Z-matrix copied'); } catch (e) { toast(`Copy failed: ${e.message}`, { kind: 'error' }); }
  }

  async function editValue(row, field, value) {
    try {
      const r = await request('zmatrix.edit', { docId: d.docId, ordering: st.ordering, order: data.order, refs: data.refs, row, field, value });
      skipRefresh = true; // the molecule event below would rebuild the table and drop the focus
      const keepFocus = document.activeElement?.classList.contains('zm-num') ? [row, field] : null;
      applyResult(app, d, r);
      skipRefresh = false;
      seq++;
      take(r.zmatrix);
      if (keepFocus) focusCell(...keepFocus);
    } catch (e) { toast(e.message, { kind: 'error' }); render(); }
  }
  function focusCell(row, field) {
    const tr = rowEls[row]; if (!tr) return;
    const inputs = tr.querySelectorAll('input.zm-num');
    const k = { bond: 0, angle: 1, dihedral: 2 }[field];
    const el = inputs[Math.min(k, inputs.length - 1)];
    if (el) { el.focus(); el.select(); }
  }

  function highlight(r) {
    hoverRow = r;
    if (r < 0 || !data?.rows[r]) { vp.setHover(null); vp.setPendingPicks(app.pending || []); return; }
    const row = data.rows[r];
    vp.setHover({ kind: 'atom', index: row.atom });
    vp.setPendingPicks([row.bondAtom, row.angleAtom, row.dihedralAtom].filter((x) => x != null));
  }
  function syncSelection() {
    if (!data) return;
    data.rows.forEach((row, k) => rowEls[k]?.classList.toggle('on', d.selection.has(row.atom)));
  }

  // ---------- builder ----------
  const b = st.builder;
  const elIn = h('input.zm-el', { type: 'text', value: b.symbol, spellcheck: false, title: 'Element symbol' });
  const refIns = [0, 1, 2].map(() => h('input.zm-ref', { type: 'text', placeholder: '–', spellcheck: false, title: 'Atom number (empty: automatic)' }));
  const valIns = ['bond', 'angle', 'dihedral'].map((f) => h('input.zm-val', { type: 'text', placeholder: '', spellcheck: false, title: f === 'bond' ? 'Distance in Å (empty: from covalent radii)' : f === 'angle' ? 'Angle in degrees (empty: from the hybridisation)' : 'Dihedral in degrees (empty: the most open staggered position)' }));
  const orderSel = segmented([{ value: 1, label: '1' }, { value: 2, label: '2' }, { value: 3, label: '3' }], b.bondOrder, (v) => { b.bondOrder = Number(v); suggest(); }, 'small');
  const addH = h('input', { type: 'checkbox', checked: b.addH, onchange: () => { b.addH = addH.checked; } });
  const hint = h('div.zm-hint');
  const addBtn = h('button.btn.primary', { onclick: () => addAtom() }, 'Add atom');
  const grid = h('div.zm-grid', {},
    h('span'), h('span.zm-gh', {}, 'Atom'), h('span.zm-gh', {}, 'Value'), h('span'),
    h('label', {}, 'Bond to'), refIns[0], valIns[0], h('span.zm-unit', {}, 'Å'),
    h('label', {}, 'Angle with'), refIns[1], valIns[1], h('span.zm-unit', {}, '°'),
    h('label', {}, 'Dihedral with'), refIns[2], valIns[2], h('span.zm-unit', {}, '°'));
  right.append(h('div.zm-btitle', {}, 'Add atom'),
    h('div.row', {}, h('label', {}, 'Element'), elIn, h('label', {}, 'Bond'), orderSel),
    grid,
    h('div.row', {}, h('label.zm-check', {}, addH, 'Fill valence with H'), h('span.grow'), addBtn),
    hint);

  const zOf = () => { const e = elementBySymbol(elIn.value.trim()); return e ? e.z : null; };
  const refVal = (i) => { const t = refIns[i].value.trim(); if (!t) return undefined; const n = Number(t) - 1; return Number.isInteger(n) ? n : NaN; };
  const numVal = (i) => { const t = valIns[i].value.trim().replace(',', '.'); if (!t) return undefined; return Number(t); };
  function builderParams() {
    const z = zOf();
    if (!z) throw new Error(`Unknown element "${elIn.value}"`);
    const p = { docId: d.docId, z, bondOrder: b.bondOrder };
    ['bondAtom', 'angleAtom', 'dihedralAtom'].forEach((k, i) => { const v = refVal(i); if (v !== undefined) { if (!Number.isInteger(v) || v < 0 || v >= d.molecule.atoms.length) throw new Error(`No atom ${refIns[i].value}`); p[k] = v; } });
    ['bond', 'angle', 'dihedral'].forEach((k, i) => { const v = numVal(i); if (v !== undefined) { if (!Number.isFinite(v)) throw new Error(`${k} is not a number`); p[k] = v; } });
    return p;
  }
  let sugSeq = 0;
  async function suggest() {
    const my = ++sugSeq;
    let p;
    try { p = builderParams(); } catch (e) { hint.textContent = e.message; hint.classList.add('err'); addBtn.disabled = true; return; }
    addBtn.disabled = false;
    try {
      const r = await request('zmatrix.addAtom', { ...p, dryRun: true });
      if (disposed || my !== sugSeq) return;
      const df = r.defaults;
      [df.bondAtom, df.angleAtom, df.dihedralAtom].forEach((a, i) => { refIns[i].placeholder = a != null ? String(a + 1) : '–'; });
      [[df.bond, 4], [df.angle, 2], [df.dihedral, 2]].forEach(([v, dg], i) => { valIns[i].placeholder = v != null ? v.toFixed(dg) : ''; });
      const names = [df.bondAtom, df.angleAtom, df.dihedralAtom].filter((x) => x != null).map(label);
      hint.classList.remove('err');
      hint.textContent = d.molecule.atoms.length
        ? `New ${elIn.value.trim()}${d.molecule.atoms.length + 1} bonded to ${names[0] || '–'}${names.length > 1 ? `, references ${names.slice(1).join(', ')}` : ''}${df.hybridization && df.hybridization !== 'none' ? ` (${df.hybridization} centre)` : ''}. Empty fields use the grey defaults.`
        : 'The first atom goes to the origin.';
    } catch (e) { if (!disposed && my === sugSeq) { hint.textContent = e.message; hint.classList.add('err'); } }
  }
  async function addAtom() {
    let p;
    try { p = builderParams(); } catch (e) { toast(e.message, { kind: 'warn' }); return; }
    if (b.addH) p.addHydrogens = true;
    try {
      const r = await request('zmatrix.addAtom', p);
      // keep the table order: append the new atom (and any hydrogens) at the end
      const n0 = d.molecule.atoms.length;
      if (data && st.order?.length === n0) {
        const rowOf = (a) => st.order.indexOf(a);
        const df = r.defaults;
        const refs = [df.bondAtom, df.angleAtom, df.dihedralAtom].map((a) => (a == null ? null : rowOf(a)));
        st.order = [...st.order, r.atom]; st.refs = [...st.refs, refs.slice(0, Math.min(3, n0))];
        if (r.molecule.atoms.length !== n0 + 1) { st.order = null; st.refs = null; }
      }
      applyResult(app, d, r, { fit: n0 < 3 });
      app.setSelection([r.atom]);
      for (const i of refIns) i.value = '';
      for (const i of valIns) i.value = '';
      app.status(`Added ${r.molecule.atoms[r.atom].symbol}${r.atom + 1}`);
    } catch (e) { toast(e.message, { kind: 'error' }); }
  }
  elIn.addEventListener('input', () => { b.symbol = elIn.value.trim(); suggest(); });
  for (const i of [...refIns, ...valIns]) { i.addEventListener('change', suggest); i.addEventListener('keydown', (e) => { if (e.key === 'Enter') { e.preventDefault(); suggest().then(() => addAtom()); } }); }
  elIn.addEventListener('keydown', (e) => { if (e.key === 'Enter') { e.preventDefault(); addAtom(); } });

  const offSel = app.on('selection', () => { syncSelection(); suggest(); });
  let molT = null;
  const onMolecule = () => { if (skipRefresh) return; clearTimeout(molT); molT = setTimeout(() => { if (!disposed) { refresh(); suggest(); } }, 60); };
  refresh(); suggest();
  const tab = {
    onMolecule,
    dispose() { disposed = true; offSel(); clearTimeout(molT); if (hoverRow >= 0) highlight(-1); if (activeTab === tab) activeTab = null; },
    // smoke-test hooks
    get data() { return data; }, highlight, editValue, refresh,
    setView(v) { st.view = v; render(); },
    setBuilder({ symbol, refs = [], values = [] }) { if (symbol) { elIn.value = symbol; b.symbol = symbol; } refs.forEach((x, i) => { refIns[i].value = x ?? ''; }); values.forEach((x, i) => { valIns[i].value = x ?? ''; }); return suggest(); },
    addAtom,
  };
  activeTab = tab;
  return tab;
}

// ---------------------------------------------------------------- dialog
/** Build > From Z-Matrix…: type or paste a Z-matrix (Gaussian with/without variables, ORCA `* int`, a Gaussian input). */
export function openZMatrixDialog(app, { text = '' } = {}) {
  const ta = h('textarea.zm-text.zm-dialog-text', { spellcheck: false, placeholder: SAMPLE, value: text });
  const info = h('div.zm-hint');
  const d = app.active;
  const canReplace = () => !!(d && app.docs.includes(d));
  let t = null; let seq = 0;
  const check = async () => {
    const my = ++seq;
    if (!ta.value.trim()) { info.textContent = 'Gaussian style: element, then bond atom + distance, angle atom + angle, dihedral atom + dihedral; references are row numbers or labels. A variables section after a blank line, a "charge multiplicity" line, a whole Gaussian input or an ORCA "* int" block also work.'; info.classList.remove('err'); return null; }
    try {
      const r = await request('zmatrix.parse', { text: ta.value });
      if (my !== seq) return r;
      const m = r.molecule;
      const counts = {};
      for (const a of m.atoms) counts[a.symbol] = (counts[a.symbol] || 0) + 1;
      const formula = Object.keys(counts).sort((a, b) => (a === 'C' ? -1 : b === 'C' ? 1 : a === 'H' ? -1 : b === 'H' ? 1 : a.localeCompare(b))).map((s) => s + (counts[s] > 1 ? counts[s] : '')).join('');
      info.classList.remove('err');
      info.textContent = `${formula}: ${m.atoms.length} atoms, ${m.bonds.length} bonds${r.dummyCount ? `, ${r.dummyCount} dummy atom${r.dummyCount > 1 ? 's' : ''} dropped` : ''}${Object.keys(r.variables || {}).length ? `, ${Object.keys(r.variables).length} variables` : ''} · charge ${m.charge}, multiplicity ${m.multiplicity}`;
      return r;
    } catch (e) { if (my === seq) { info.textContent = e.message; info.classList.add('err'); } return null; }
  };
  ta.addEventListener('input', () => { clearTimeout(t); t = setTimeout(check, 250); });
  const run = async (newDocument) => {
    try {
      const params = newDocument || !canReplace() ? { text: ta.value, newDocument: true, title: 'Z-Matrix' } : { docId: d.docId, text: ta.value };
      const r = await request('zmatrix.apply', params);
      dlg.close();
      if (r.mode === 'new') openCreated(app, r);
      else { applyResult(app, d, r, { fit: true }); app.status('Structure replaced from the Z-matrix'); }
    } catch (e) { info.textContent = e.message; info.classList.add('err'); }
  };
  const footer = h('div.btn-row', {},
    h('button.btn', { onclick: () => { ta.value = SAMPLE; check(); } }, 'Example'),
    h('span.grow'),
    h('button.btn', { onclick: () => dlg.close() }, 'Cancel'),
    canReplace() && d.molecule.atoms.length ? h('button.btn', { onclick: () => run(false), title: 'Replace the current structure (one undo step)' }, 'Replace current') : null,
    h('button.btn.primary', { onclick: () => run(!(canReplace() && !d.molecule.atoms.length)) }, canReplace() && !d.molecule.atoms.length ? 'Build' : 'New document'));
  const dlg = modal('Build from Z-Matrix', h('div', {}, ta, info), { width: 640, footer });
  ta.addEventListener('keydown', (e) => { if (e.key === 'Enter' && e.ctrlKey) { e.preventDefault(); footer.querySelector('.btn.primary').click(); } });
  check();
  return dlg;
}

/** Opens the Z-Matrix results tab. */
export function showZMatrixTab(app) {
  app.zmatrixOpen = true;
  app.emit('results-tab', 'zmatrix');
}

/** Smoke test (VIBEVIEW_SMOKE_ZMATRIX): steps separated by ';' —
 *  `tab`, `view:table|gaussian|orca`, `vars`, `edit:<row>:<bond|angle|dihedral>:<value>`, `hover:<row>`,
 *  `add:<symbol>[:<bondAtom>:<angleAtom>:<dihedralAtom>]` (1-based atom numbers), `undo`, `dialog[:<text>]`. */
export async function smokeZMatrix(app, spec, log) {
  const wait = (ms) => new Promise((r) => setTimeout(r, ms));
  const until = async (f, ms = 5000) => { const t0 = Date.now(); while (!f() && Date.now() - t0 < ms) await wait(50); return f(); };
  let ok = true;
  for (const step of spec.split(';').map((x) => x.trim()).filter(Boolean)) {
    const [cmd, ...a] = step.split(':');
    try {
      if (cmd === 'tab') { showZMatrixTab(app); await until(() => activeTab?.data); }
      else if (cmd === 'view') activeTab.setView(a[0]);
      else if (cmd === 'vars') { stateOf(app.active).variables = true; activeTab.setView('gaussian'); }
      else if (cmd === 'edit') { await activeTab.editValue(Number(a[0]), a[1], Number(a[2])); }
      else if (cmd === 'hover') activeTab.highlight(Number(a[0]));
      else if (cmd === 'add') { await activeTab.setBuilder({ symbol: a[0], refs: a.slice(1, 4) }); await activeTab.addAtom(); await wait(300); await until(() => activeTab?.data?.rows.length === app.active.molecule.atoms.length); }
      else if (cmd === 'undo') { await app.undo(); await wait(300); }
      else if (cmd === 'dialog') { openZMatrixDialog(app, { text: a.length ? a.join(':').replace(/\\n/g, '\n') : SAMPLE }); await wait(600); }
      else { log(`zmatrix smoke: unknown step ${step}`); ok = false; continue; }
      await wait(150);
      const t = activeTab?.data;
      log(`zmatrix smoke ${step}: ${t ? `${t.rows.length} rows, last ${JSON.stringify(t.rows[t.rows.length - 1])}` : 'no table'}; atoms ${app.active?.molecule.atoms.length}, undo "${app.active?.summary.undoName || ''}"`);
    } catch (e) { ok = false; log(`zmatrix smoke ${step} failed: ${e.stack || e}`); }
  }
  return { ok };
}
