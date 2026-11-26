// Right inspector: display style, labels, colours, theme, molecule info and measurements.
import { h, $, clear, segmented, select, fmt } from './dom.js';
import { STYLE_ICONS } from './icons.js';
import { request } from './api.js';
import { CARTOON_STYLE, CARTOON_COLORS } from './cartoon.js';

const STYLES = [
  { value: 'ballAndStick', label: 'Ball & stick' }, { value: 'tube', label: 'Tube' },
  { value: 'wireframe', label: 'Wireframe' }, { value: 'spaceFilling', label: 'Space filling' },
  CARTOON_STYLE,
];

export function buildInspector(app) {
  const root = $('#inspector');
  const vp = app.viewport;
  const o = () => vp.options;
  const set = (patch) => vp.setOptions(patch);

  const styleGrid = h('div.style-grid', {}, STYLES.map((s) => h('button.style-card', { dataset: { style: s.value }, title: s.label, onclick: () => set({ style: s.value }), innerHTML: STYLE_ICONS[s.value] + `<span>${s.label}</span>` })));
  const check = (label, key, title) => {
    const input = h('input', { type: 'checkbox', checked: !!o()[key], onchange: () => set({ [key]: input.checked }) });
    input.dataset.key = key;
    return h('label.check', { title }, input, label);
  };
  const slider = (label, key, min, max, step) => {
    const val = h('span', { style: { width: '42px', textAlign: 'right', fontVariantNumeric: 'tabular-nums' } });
    const input = h('input', { type: 'range', min, max, step, value: o()[key], oninput: () => { val.textContent = Number(input.value).toFixed(2); set({ [key]: Number(input.value) }); } });
    input.dataset.key = key;
    val.textContent = Number(o()[key]).toFixed(2);
    return h('div.row', {}, h('label', { style: { width: '74px' } }, label), h('div.grow', {}, input), val);
  };
  const labels = select([
    { value: 'none', label: 'None' }, { value: 'element', label: 'Element' }, { value: 'index', label: 'Index' },
    { value: 'elementIndex', label: 'Element + index' }, { value: 'charge', label: 'Partial charge' }, { value: 'custom', label: 'Atom label' },
  ], o().labelMode, (v) => set({ labelMode: v }));
  const colors = select([{ value: 'element', label: 'By element' }, { value: 'charge', label: 'By partial charge' }, { value: 'uniform', label: 'Single colour' }], o().colorScheme, (v) => { set({ colorScheme: v }); uniformRow.hidden = v !== 'uniform'; });
  const uniform = h('input', { type: 'color', value: o().uniformColor, oninput: () => set({ uniformColor: uniform.value }) });
  const uniformRow = h('div.row', {}, h('label', {}, 'Colour'), uniform);
  uniformRow.hidden = o().colorScheme !== 'uniform';
  const material = select([{ value: 'glossy', label: 'Glossy' }, { value: 'satin', label: 'Satin' }, { value: 'matte', label: 'Matte' }, { value: 'metallic', label: 'Metallic' }, { value: 'flat', label: 'Flat' }], o().material, (v) => set({ material: v }));
  const theme = segmented([{ value: 'auto', label: 'Auto', title: 'Follow the interface theme' }, { value: 'light', label: 'Light' }, { value: 'dark', label: 'Dark' }, { value: 'black', label: 'Black' }, { value: 'white', label: 'White' }], o().theme, (v) => set({ theme: v, background: null }));
  const bg = h('input', { type: 'color', value: '#eef0f4', title: 'Custom background', oninput: () => set({ background: bg.value }) });
  const uiTheme = segmented([{ value: 'system', label: 'System' }, { value: 'light', label: 'Light' }, { value: 'dark', label: 'Dark' }], app.settings.uiTheme, (v) => { app.settings.uiTheme = v; app.applyUITheme(); app.saveSettingsSoon(); });
  const proj = segmented([{ value: 'perspective', label: 'Perspective' }, { value: 'orthographic', label: 'Orthographic' }], o().projection, (v) => set({ projection: v }));

  const molInfo = h('div.kv');
  const chargeIn = h('input', { type: 'number', step: 1, style: { width: '64px' } });
  const multIn = h('input', { type: 'number', step: 1, min: 1, style: { width: '64px' } });
  const applyCharge = () => app.edit({ type: 'setCharge', charge: Number(chargeIn.value) || 0, multiplicity: Math.max(1, Number(multIn.value) || 1) }, { keepSelection: true });
  chargeIn.addEventListener('change', applyCharge); multIn.addEventListener('change', applyCharge);
  const pg = h('span', {}, '–');
  const aromatic = select([{ value: 'kekule', label: 'Kekulé' }, { value: 'dashed', label: 'Dashed' }], o().aromaticStyle || 'kekule', (v) => set({ aromaticStyle: v }));
  const aromaticRow = h('div.row', { title: 'Aromatic bonds: one alternating Kekulé structure, or a solid and a dashed line' }, h('label', { style: { width: '74px' } }, 'Aromatic'), h('div.grow', {}, aromatic));
  const cartoonColor = select(CARTOON_COLORS, o().cartoonColor || 'ss', (v) => set({ cartoonColor: v }));
  const cartoonRow = h('div.row', { style: { marginTop: '8px' }, title: 'Protein residues are drawn as a cartoon; ligands as ball and stick' }, h('label', { style: { width: '74px' } }, 'Cartoon'), h('div.grow', {}, cartoonColor));
  const selInfo = h('div', { style: { fontSize: '12px', color: 'var(--text-2)' } });
  const measures = h('div.measure-list');

  root.append(
    h('div.section', {}, h('h3', {}, 'Style'), styleGrid, cartoonRow,
      h('div', { style: { marginTop: '8px' } },
        check('Hydrogens', 'showHydrogens'), check('Bond orders', 'showBondOrders', 'Draw double, triple and aromatic bonds'),
        aromaticRow, check('Two-colour bonds', 'splitBondColors'),
        slider('Atom size', 'atomScale', 0.1, 0.6, 0.01), slider('Bond radius', 'bondRadius', 0.04, 0.3, 0.01))),
    h('div.section', {}, h('h3', {}, 'Labels and colours'),
      h('div.row', {}, h('label', { style: { width: '74px' } }, 'Labels'), h('div.grow', {}, labels)),
      h('div.row', {}, h('label', { style: { width: '74px' } }, 'Atoms'), h('div.grow', {}, colors)), uniformRow,
      h('div.row', {}, h('label', { style: { width: '74px' } }, 'Material'), h('div.grow', {}, material))),
    h('div.section', {}, h('h3', {}, 'Scene'), theme,
      h('div.row', { style: { marginTop: '6px' } }, h('label', {}, 'Custom background'), bg),
      proj,
      h('div', { style: { marginTop: '6px' } }, check('Ambient occlusion', 'ambientOcclusion', 'Darken crevices (screen-space)'), check('Axes', 'showAxes')),
      h('div.field', { style: { marginTop: '6px' } }, h('span.field-label', {}, 'Interface'), uiTheme)),
    h('div.section', {}, h('h3', {}, 'Molecule'), molInfo,
      h('div.row', { style: { marginTop: '6px' } }, h('label', {}, 'Charge'), chargeIn, h('label', {}, 'Mult.'), multIn),
      h('div.row', {}, h('label', {}, 'Point group'), pg, h('span.grow'), h('button.btn.small', { onclick: () => app.command('analysis.symmetry') }, 'Detect'), h('button.btn.small', { onclick: () => app.command('build.symmetrize'), title: 'Symmetrize to the detected point group' }, 'Symmetrize'))),
    h('div.section', {}, h('h3', {}, 'Selection'), selInfo),
    // Measurements live in a panel at the top right of the viewer (measurepanel.js).
  );

  const refreshOptions = () => {
    cartoonRow.hidden = o().style !== 'cartoon';
    for (const c of styleGrid.children) c.classList.toggle('on', c.dataset.style === o().style);
    for (const i of root.querySelectorAll('input[data-key]')) {
      if (i.type === 'checkbox') i.checked = !!o()[i.dataset.key];
      else if (document.activeElement !== i) i.value = o()[i.dataset.key];
    }
    aromatic.value = o().aromaticStyle || 'kekule'; aromaticRow.hidden = !o().showBondOrders;
    labels.value = o().labelMode; colors.value = o().colorScheme; material.value = o().material;
    theme.setValue(o().theme); proj.setValue(o().projection);
  };
  const refreshMol = () => {
    const d = app.active; clear(molInfo);
    if (!d) return;
    const m = d.molecule, s = d.summary;
    const rows = [['Name', d.name], ['Formula', s.formula || '–'], ['Atoms', m.atoms.length], ['Bonds', m.bonds.length], ['Mass', massOf(m).toFixed(3) + ' u']];
    if (s.program) rows.push(['Program', s.program]);
    if (s.frameCount > 1) rows.push(['Frames', s.frameCount]);
    for (const [k, v] of rows) molInfo.append(h('span.k', {}, k), h('span.v.selectable', { title: String(v) }, String(v)));
    if (document.activeElement !== chargeIn) chargeIn.value = m.charge;
    if (document.activeElement !== multIn) multIn.value = m.multiplicity;
    pg.textContent = d.cache.pointGroup || '–';
  };
  const refreshSel = () => {
    const d = app.active;
    if (!d || !d.selection.size) { selInfo.textContent = 'Nothing selected. Click atoms with the Select tool.'; return; }
    const idx = [...d.selection].sort((a, b) => a - b);
    const syms = idx.slice(0, 12).map((i) => `${d.molecule.atoms[i].symbol}${i + 1}`).join(', ');
    clear(selInfo).append(`${idx.length} atom${idx.length > 1 ? 's' : ''}: ${syms}${idx.length > 12 ? '…' : ''}`);
    if (idx.length >= 2 && idx.length <= 4) {
      const v = app.measureValue(d.molecule, idx);
      selInfo.append(h('div', {}, `${v.kind} ${v.value.toFixed(v.kind === 'distance' ? 4 : 2)}${v.kind === 'distance' ? ' Å' : '°'} `, h('button.link', { onclick: () => app.addMeasurement(idx) }, 'Keep')));
    }
  };
  const refreshMeasures = () => {
    const d = app.active; clear(measures);
    if (!d || !d.measurements.length) { measures.append(h('div', { style: { fontSize: '12px', color: 'var(--text-3)' } }, 'Use the Gauge tool to add distances, angles and dihedrals. Edit a value to move the smaller side of the structure.')); return; }
    d.measurements.forEach((m, k) => {
      const unit = m.kind === 'distance' ? 'Å' : '°';
      const input = h('input', { type: 'number', step: m.kind === 'distance' ? 0.01 : 1, value: m.value.toFixed(m.kind === 'distance' ? 3 : 1), title: 'Type a new value and press Enter' });
      input.addEventListener('change', () => { const v = Number(input.value); if (Number.isFinite(v)) app.setMeasurementValue(m, v); });
      measures.append(h('div.m', {}, h('span.atoms', {}, m.atoms.map((i) => `${d.molecule.atoms[i]?.symbol}${i + 1}`).join('–')), input, h('span', {}, unit),
        h('button.icon-btn', { title: 'Remove', innerHTML: '&#x2715;', onclick: () => app.removeMeasurement(k) })));
    });
  };
  app.on('options', refreshOptions);
  app.on('doc', () => { refreshMol(); refreshSel(); refreshMeasures(); });
  app.on('molecule', () => { refreshMol(); refreshMeasures(); });
  app.on('selection', refreshSel);
  app.on('measurements', refreshMeasures);
  app.on('pointgroup', refreshMol);
  refreshOptions();
}

const MASSES = {};
import { element } from './elements.js';
function massOf(m) { return m.atoms.reduce((s, a) => s + (MASSES[a.z] ??= element(a.z).mass), 0); }

export async function detectSymmetry(app) {
  const d = app.active; if (!d) return;
  try {
    const r = await request('analysis.symmetry', { docId: d.docId, tolerance: 0.1 });
    d.cache.pointGroup = r.pointGroup;
    app.emit('pointgroup', r);
    app.status(`Point group ${r.pointGroup}${r.elements?.length ? ' · ' + r.elements.join(' ') : ''}`);
  } catch (e) { app.error('Symmetry detection failed', e); }
}

export { fmt };
