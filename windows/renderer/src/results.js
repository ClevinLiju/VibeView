// Results panel: Summary, Orbitals, Vibrations (+ IR/Raman), UV-Vis and Trajectory tabs.
import { h, $, clear, segmented, select, decodeF32, fmt, toast } from './dom.js';
import { request, api } from './api.js';
import { XYChart, LevelDiagram } from './chart.js';
import { ICONS } from './icons.js';
import { hasResultData } from './shell.js';
import { buildZMatrixTab } from './zmatrix.js';
import { sendFormchkPath } from './dialogs.js';

const HARTREE_EV = 27.211386;

export function buildResults(app) {
  const root = $('#results');
  const tabsEl = h('div.tabs');
  const body = h('div.tab-body');
  root.append(tabsEl, body);
  const state = { tab: 'summary' };
  const tabs = [
    { id: 'summary', label: 'Summary', show: (d) => hasResultData(d), build: buildSummary },
    { id: 'orbitals', label: 'Orbitals', show: (d) => d.summary.orbitalCount > 0 || d.summary.hasWavefunction || (d.summary.volumeNames || []).length > 0, build: buildOrbitals },
    { id: 'vibrations', label: 'Vibrations', show: (d) => d.summary.modeCount > 0, build: buildVibrations },
    { id: 'uvvis', label: 'UV-Vis', show: (d) => d.summary.excitedStateCount > 0, build: buildUVVis },
    { id: 'trajectory', label: 'Trajectory', show: (d) => d.summary.frameCount > 1, build: buildTrajectory },
    { id: 'zmatrix', label: 'Z-Matrix', show: (d) => true, build: buildZMatrixTab }, // zmatrix.js
  ];
  let current = null; let builtFor = null;
  const render = () => {
    const d = app.active;
    clear(tabsEl);
    if (!d || !(hasResultData(d) || app.zmatrixOpen)) { clear(body); current?.dispose?.(); current = null; builtFor = null; return; }
    const visible = tabs.filter((t) => t.show(d));
    if (!visible.some((t) => t.id === state.tab)) state.tab = visible[0].id;
    for (const t of visible) tabsEl.append(h('button.tab' + (t.id === state.tab ? '.on' : ''), { onclick: () => { state.tab = t.id; render(); } }, t.label));
    tabsEl.append(h('span.grow'), h('button.icon-btn', { title: 'Hide results (Ctrl+Alt+R)', innerHTML: '&#x2715;', onclick: () => app.command('panel.results') }));
    const s = d.summary;
    const key = `${d.docId}:${state.tab}:${s.modeCount}:${s.orbitalCount}:${s.frameCount}:${s.excitedStateCount}:${s.atomCount}:${!!s.hasWavefunction}:${!!s.formchkPending}`;
    if (builtFor === key) return;
    current?.dispose?.();
    clear(body);
    builtFor = key;
    current = visible.find((t) => t.id === state.tab).build(app, d, body) || null;
  };
  app.on('doc', () => render());
  app.on('engine-restarted', () => { builtFor = null; render(); });
  app.on('results-tab', (id) => { if (id === 'zmatrix') app.zmatrixOpen = true; state.tab = id; builtFor = null; app.settings.panels.results = true; app.emit('panels'); render(); });
  app.on('molecule', () => current?.onMolecule?.());
  installFormchkStatus(app, () => { builtFor = null; render(); });
  render();
}

// ---------- Gaussian checkpoints: automatic formchk (engine Formchk.swift) ----------
const fileOf = (p) => String(p || '').split(/[\\/]/).pop();
/**
 * Shows the automatic .chk → .fchk conversion: `doc.wavefunction` (background formchk after opening a Gaussian log)
 * updates the document and the Results panel; `job.finished` of a Gaussian job reports `fchk` / `formchkError`.
 */
function installFormchkStatus(app, rerender) {
  // engine-info arrives at startup and after an engine restart (which forgets the path)
  app.on('engine-info', () => sendFormchkPath(app, { force: !!app.settings.programPaths?.formchk }));
  if (app.engineInfo) sendFormchkPath(app);
  api.onEvent((name, p) => {
    if (name === 'doc.wavefunction') {
      const d = app.docs.find((x) => x.docId === p.docId);
      if (!d) return;
      if (p.summary) d.summary = p.summary;
      else d.summary = { ...d.summary, formchkPending: false };
      delete d.cache.orbitals; delete d.cache.result;
      if (d === app.active) rerender();
      if (p.ok) {
        app.status(`Orbitals ready: ${fileOf(p.fchk)} (made by formchk)`);
        toast(`${d.name}: formchk made ${fileOf(p.fchk)}. Orbital surfaces are available.`, { kind: 'ok',
          action: { label: 'Show orbitals', run: () => { if (app.active !== d) app.activate(d); app.emit('results-tab', 'orbitals'); } } });
      } else if (p.errorCode !== 'cancelled') {
        toast(`${d.name}: automatic formchk failed: ${p.error || 'unknown error'}`, { kind: 'error', timeout: 0 });
      }
    } else if (name === 'job.finished' && ('fchk' in p || 'formchkError' in p) && (p.fchk || p.formchkError)) {
      const j = app.ensureJob(p.jobId);
      j.formchk = { fchk: p.fchk || null, error: p.formchkError || null };
      j.lines.push({ jobId: p.jobId, stream: p.formchkError ? 'stderr' : 'stdout', file: null,
        line: p.formchkError ? `formchk: ${p.formchkError}` : `formchk: wrote ${p.fchk}` });
      app.emit('job-log', j, j.lines[j.lines.length - 1]);
      if (p.formchkError && !p.cancelled) {
        toast(`formchk: ${p.formchkError}`, { kind: 'warn', timeout: 0, action: { label: 'Show log', run: () => app.command('calc.jobs', p.jobId) } });
      }
    }
  });
}

// ---------- Summary ----------
function buildSummary(app, d, body) {
  const left = h('div.pane');
  const right = h('div.pane');
  body.append(left, right);
  left.append(h('div.empty', {}, 'Loading…'));
  (async () => {
    let r;
    try { r = d.cache.result || (d.cache.result = await request('doc.result', { docId: d.docId })); } catch (e) { clear(left).append(h('div.empty', {}, e.message)); return; }
    clear(left);
    const kv = h('div.kv.selectable');
    const s = d.summary;
    const rows = [
      ['File', d.path || '–'], ['Program', s.program || '–'], ['Format', s.format || '–'],
      ['Level of theory', r.info?.levelOfTheory || '–'],
      ['Termination', r.normalTermination ? 'normal' : 'not normal'],
    ];
    if (s.formchkPending) rows.push(['Checkpoint', 'converting .chk to .fchk with formchk…']);
    else { const fc = (s.companions || []).find((c) => /\.fchk?$/i.test(c.fileName || '') && c.used); if (fc && /formchk/.test(fc.note || '')) rows.push(['Checkpoint', `${fc.fileName} (made by formchk)`]); }
    const e = r.energies || [];
    if (e.length) rows.push(['Final energy', `${e[e.length - 1].toFixed(8)} Eh  (${(e[e.length - 1] * HARTREE_EV).toFixed(4)} eV)`]);
    if (e.length > 1) rows.push(['Energy steps', String(e.length)]);
    if (r.dipole) rows.push(['Dipole', `${Math.hypot(...r.dipole).toFixed(4)} D  (${r.dipole.map((x) => x.toFixed(3)).join(', ')})`]);
    for (const row of r.info?.rows || []) rows.push([row.label, row.value]);
    for (const [k, v] of rows) kv.append(h('span.k', {}, k), h('span.v', { title: String(v) }, String(v)));
    left.append(h('h3', { class: 'sub' }, ''), kv);
    if (r.routeSection) left.append(h('pre.preview', {}, r.routeSection));
    const comp = s.companions || [];
    if (comp.length) {
      left.append(h('div', { style: { marginTop: '10px', fontWeight: 600, fontSize: '12px' } }, 'Companion files'));
      const t = h('table.list', {}, h('tr', {}, h('th', {}, 'File'), h('th', {}, 'Role'), h('th', {}, 'Used'), h('th', {}, 'Note')));
      for (const c of comp) t.append(h('tr', {}, h('td', {}, c.fileName), h('td', {}, c.role), h('td', {}, c.used ? 'yes' : 'no'), h('td', {}, c.note || '')));
      left.append(t);
    }
    // charges
    const schemes = Object.keys(r.charges || {});
    if (schemes.length) {
      const sel = select([{ value: '', label: 'File charges' }, ...schemes.map((x) => ({ value: x, label: x }))], '', (v) => {
        if (v) { const q = r.charges[v]; d.molecule.atoms.forEach((a, i) => { a.charge = q[i] ?? 0; }); }
        app.viewport.setOptions({ colorScheme: 'charge', labelMode: app.viewport.options.labelMode === 'none' ? 'charge' : app.viewport.options.labelMode });
      });
      right.append(h('div.row', {}, h('label', {}, 'Partial charges'), sel, h('button.btn.small', { onclick: () => app.viewport.setOptions({ colorScheme: 'charge' }) }, 'Colour by charge')));
    }
    // thermochemistry
    if (s.modeCount > 0) {
      const T = h('input', { type: 'number', value: 298.15, step: 1, style: { width: '80px' } });
      const P = h('input', { type: 'number', value: 1, step: 0.1, style: { width: '64px' } });
      const sc = h('input', { type: 'number', value: 1, step: 0.001, style: { width: '64px' } });
      const out = h('div');
      const run = async () => {
        try {
          const t = await request('analysis.thermo', { docId: d.docId, temperature: Number(T.value), pressure: Number(P.value), frequencyScale: Number(sc.value) });
          const tbl = h('table.list', {}, h('tr', {}, h('th', {}, 'Quantity'), h('th.num', {}, 'Hartree'), h('th.num', {}, 'kcal/mol')));
          for (const row of t.rows || []) tbl.append(h('tr', {}, h('td', {}, row.label), h('td.num', {}, row.hartree != null ? row.hartree.toFixed(6) : '–'), h('td.num', {}, row.kcal != null ? row.kcal.toFixed(2) : '–')));
          clear(out).append(tbl);
        } catch (e) { clear(out).append(h('div.errors', {}, e.message)); }
      };
      for (const i of [T, P, sc]) i.addEventListener('change', run);
      right.append(h('div', { style: { fontWeight: 600, fontSize: '12px', margin: '8px 0 4px' } }, 'Thermochemistry'),
        h('div.row', {}, h('label', {}, 'T (K)'), T, h('label', {}, 'p (atm)'), P, h('label', {}, 'Freq. scale'), sc), out);
      run();
    }
    if (!right.children.length) right.append(h('div.empty', {}, 'No further results in this file.'));
  })();
}

// ---------- Orbitals ----------
function buildOrbitals(app, d, body) {
  const left = h('div.pane.fixed', { style: { width: '230px', padding: '6px' } });
  const canvas = h('canvas.levels');
  left.append(canvas);
  const right = h('div.pane');
  body.append(left, right);
  const look = app.settings.orbitalLook;
  const info = h('div', { style: { fontSize: '12.5px', marginBottom: '8px' } }, 'Click a level to show its orbital.');
  let selected = d.cache.orbitalSel || null; // {orbital, spin, level}
  const diagram = new LevelDiagram(canvas, (level, column) => {
    selected = { orbital: level.orbitalIndices[0], spin: column.spin === 'beta' ? 'beta' : 'alpha', level };
    d.cache.orbitalSel = selected;
    diagram.selected = selected; diagram.draw();
    show();
  });
  diagram.selected = selected;
  const iso = h('input', { type: 'range', min: 0.002, max: 0.1, step: 0.001, value: look.isovalue });
  const isoVal = h('span', { style: { width: '48px', textAlign: 'right' } }, look.isovalue.toFixed(3));
  iso.addEventListener('input', () => { isoVal.textContent = Number(iso.value).toFixed(3); });
  iso.addEventListener('change', () => { look.isovalue = Number(iso.value); app.saveSettingsSoon(); show(); });
  const quality = segmented(['draft', 'normal', 'high', 'ultra'].map((q) => ({ value: q, label: q[0].toUpperCase() + q.slice(1) })), look.quality, (v) => { look.quality = v; app.saveSettingsSoon(); show(); });
  const mode = segmented([{ value: 'solid', label: 'Solid' }, { value: 'transparent', label: 'Transparent' }, { value: 'wireframe', label: 'Wireframe' }, { value: 'points', label: 'Points' }], look.mode, (v) => { look.mode = v; app.saveSettingsSoon(); restyle(true); });
  const opacity = h('input', { type: 'range', min: 0.1, max: 1, step: 0.02, value: look.opacity, oninput: () => { look.opacity = Number(opacity.value); restyle(false); app.saveSettingsSoon(); } });
  const colorIn = (scheme, key) => h('input', { type: 'color', value: look[scheme][key], oninput: (e) => { look[scheme][key] = e.target.value; restyle(false); app.saveSettingsSoon(); } });
  const gap = h('span');
  const vols = d.summary.volumeNames || [];
  const volSel = vols.length ? select(vols, vols[0], () => {}) : null;
  right.append(...[
    info,
    h('div.row', {}, h('label', { style: { width: '70px' } }, 'Isovalue'), h('div.grow', {}, iso), isoVal),
    h('div.row', {}, h('label', { style: { width: '70px' } }, 'Quality'), h('div.grow', {}, quality)),
    h('div.row', {}, h('label', { style: { width: '70px' } }, 'Display'), h('div.grow', {}, mode)),
    h('div.row', {}, h('label', { style: { width: '70px' } }, 'Opacity'), h('div.grow', {}, opacity)),
    h('div.row', {}, h('label', { style: { width: '70px' } }, 'Occupied'), colorIn('occupied', 'positive'), colorIn('occupied', 'negative'), h('label', { style: { marginLeft: '12px' } }, 'Virtual'), colorIn('virtual', 'positive'), colorIn('virtual', 'negative')),
    h('div.btn-row', { style: { marginTop: '6px' } },
      h('button.btn', { onclick: () => pickSpecial('HOMO') }, 'HOMO'), h('button.btn', { onclick: () => pickSpecial('LUMO') }, 'LUMO'),
      d.summary.hasWavefunction ? [
        h('button.btn', { onclick: () => density('total') }, 'Total density'), h('button.btn', { onclick: () => density('total', true) }, 'ESP-mapped density'),
        d.summary.multiplicity > 1 || d.summary.isUnrestricted ? h('button.btn', { onclick: () => density('spin') }, 'Spin density') : null] : null,
      h('button.btn', { onclick: () => { app.viewport.clearSurfaces(); d.surfaces = []; info.textContent = 'Surfaces cleared.'; } }, 'Clear surfaces')),
    volSel ? h('div.row', { style: { marginTop: '8px' } }, h('label', {}, 'Volume'), volSel, h('button.btn.small', { onclick: () => volume(volSel.value) }, 'Show')) : null,
    h('div', { style: { marginTop: '8px', fontSize: '12px', color: 'var(--text-2)' } }, gap),
  ].filter(Boolean)); // Element.append would print a literal "null"

  const lookFor = (occupied) => ({ ...look[occupied ? 'occupied' : 'virtual'], opacity: look.opacity, mode: look.mode });
  let lastOcc = true;
  function restyle(full) {
    if (full) { // rebuild with the new display mode
      const surf = d.surfaces; app.viewport.clearSurfaces();
      for (const s of surf) { s.look = { ...lookFor(s.occupied), }; app.viewport.addSurfaces(s.meshes, s.look, s.tag); }
    } else {
      for (const s of d.surfaces) s.look = lookFor(s.occupied);
      app.viewport.restyleSurfaces(lookFor(lastOcc));
    }
  }
  async function runSurface(method, params, label, occupied) {
    const res = await app.runCancellable(method, { docId: d.docId, ...params }, `Computing ${label}…`);
    if (!res) return;
    lastOcc = occupied;
    const lk = lookFor(occupied);
    app.viewport.clearSurfaces();
    d.surfaces = [{ meshes: res.meshes, look: lk, tag: label, occupied }];
    app.viewport.addSurfaces(res.meshes, lk, label);
    return res;
  }
  const noSurfaces = d.summary.formchkPending
    ? 'formchk is converting the checkpoint (.chk → .fchk). Orbital surfaces become available when it finishes.'
    : 'Energy levels only: this file has no wavefunction. Open the matching .fchk or Molden file (or an orbital cube) to draw orbital surfaces.';
  async function show() {
    if (!selected) return;
    if (d.cache.orbitals && d.cache.orbitals.canDrawSurfaces === false) { info.textContent = noSurfaces; return; }
    const occ = selected.level ? selected.level.occupation > 0.01 : true;
    const res = await runSurface('analysis.orbitalSurface', { orbital: selected.orbital, spin: selected.spin, isovalue: look.isovalue, quality: look.quality, smoothing: 0 }, `orbital ${selected.orbital + 1}`, res0(occ));
    if (res) {
      const tri = res.meshes.reduce((s, m) => s + (m.triangleCount || 0), 0);
      info.textContent = `Orbital ${selected.orbital + 1} (${selected.spin})${res.isHOMO ? ' · HOMO' : res.isLUMO ? ' · LUMO' : ''} · ${res.energy.toFixed(5)} Eh = ${(res.energy * HARTREE_EV).toFixed(3)} eV · ${res.isOccupied ? 'occupied' : 'virtual'} · ${tri} triangles`;
    }
  }
  function res0(occ) { return occ; }
  function pickSpecial(kind) {
    const cols = d.cache.orbitals?.columns || [];
    for (const col of cols) {
      const lv = col.levels.find((l) => (kind === 'HOMO' ? l.isHOMO : l.isLUMO));
      if (lv) { selected = { orbital: lv.orbitalIndices[0], spin: col.spin === 'beta' ? 'beta' : 'alpha', level: lv }; d.cache.orbitalSel = selected; diagram.selected = selected; diagram.draw(); show(); return; }
    }
    app.status(`No ${kind} found`);
  }
  async function density(kind, esp = false) {
    const r = await runSurface('analysis.densitySurface', { kind, isovalue: 0.002, quality: look.quality, esp }, `${kind} density`, true);
    if (r) info.textContent = `${kind === 'spin' ? 'Spin' : 'Total'} density${esp ? ' mapped with the electrostatic potential' : ''}.`;
  }
  async function volume(name) {
    const r = await runSurface('analysis.volumeSurface', { name, isovalue: look.isovalue }, name, true);
    if (r) info.textContent = `Volume ${name} at ±${look.isovalue}`;
  }
  (async () => {
    try {
      const r = d.cache.orbitals || (d.cache.orbitals = await request('analysis.orbitals', { docId: d.docId }));
      diagram.set(r.columns);
      gap.textContent = r.homoLumoGapEV != null ? `HOMO–LUMO gap ${r.homoLumoGapEV.toFixed(3)} eV. Scroll the diagram to zoom.` : 'Scroll the diagram to zoom.';
      if (r.canDrawSurfaces === false) info.textContent = noSurfaces;
      if (app.smokeOrbital && !d.surfaces.length) pickSpecial(app.smokeOrbital);
      if (app.pendingOrbital) { showIndex(app.pendingOrbital); app.pendingOrbital = null; }
    } catch (e) {
      diagram.set([]);
      // Cube-only documents have volumes but no orbital list: point at the Volume row instead of an error.
      if (e.code === 'not_found' && vols.length) { gap.textContent = ''; info.textContent = 'This file holds volume data only: pick a volume below and click Show.'; if (!d.surfaces.length) volume(vols[0]); } else gap.textContent = e.message;
    }
  })();
  function showIndex(o) {
    const cols = d.cache.orbitals?.columns || [];
    let level = null;
    for (const col of cols) {
      if ((o.spin === 'beta') !== (col.spin === 'beta')) continue;
      level = col.levels.find((l) => l.orbitalIndices.includes(o.index)) || null;
      if (level) break;
    }
    selected = { orbital: o.index, spin: o.spin === 'beta' ? 'beta' : 'alpha', level };
    d.cache.orbitalSel = selected; diagram.selected = selected; diagram.draw();
    show();
  }
  const off = app.on('show-orbital', (o) => { if (d.cache.orbitals) { app.pendingOrbital = null; showIndex(o); } });
  return { dispose() { diagram.ro.disconnect(); off(); } };
}

// ---------- Vibrations ----------
function buildVibrations(app, d, body) {
  const left = h('div.pane.fixed', { style: { width: '330px', padding: 0 } });
  const right = h('div.pane.chart');
  body.append(left, right);
  const table = h('table.list');
  left.append(table);
  const vp = app.viewport;
  const st = d.cache.vib || (d.cache.vib = { mode: null, amplitude: 0.5, speed: 1, arrows: false, kind: 'ir', fwhm: 20, scale: 1, playing: false });
  const amp = h('input', { type: 'range', min: 0.05, max: 1.5, step: 0.05, value: st.amplitude, oninput: () => { st.amplitude = Number(amp.value); vp.setVibrationParams({ amplitude: st.amplitude }); } });
  const speed = h('input', { type: 'range', min: 0.2, max: 3, step: 0.1, value: st.speed, oninput: () => { st.speed = Number(speed.value); vp.setVibrationParams({ speed: st.speed }); } });
  const arrows = h('input', { type: 'checkbox', checked: st.arrows, onchange: () => { st.arrows = arrows.checked; applyMode(); } });
  const playBtn = h('button.btn.small', { onclick: () => { st.playing = !st.playing; applyMode(); } });
  const kind = segmented([{ value: 'ir', label: 'IR' }, { value: 'raman', label: 'Raman' }], st.kind, (v) => { st.kind = v; loadSpectrum(); });
  const fwhm = h('input', { type: 'number', min: 1, max: 200, step: 1, value: st.fwhm, style: { width: '58px' }, onchange: () => { st.fwhm = Number(fwhm.value); loadSpectrum(); } });
  const scale = h('input', { type: 'number', min: 0.8, max: 1.1, step: 0.001, value: st.scale, style: { width: '66px' }, title: 'Frequency scale factor', onchange: () => { st.scale = Number(scale.value); loadSpectrum(); } });
  const canvas = h('canvas.chart-canvas');
  right.append(h('div.chart-tools', {}, playBtn, h('label', {}, 'Amplitude'), amp, h('label', {}, 'Speed'), speed, h('label.check', {}, arrows, 'Arrows'), h('span', { style: { flex: 1 } }), kind, h('label', {}, 'FWHM'), fwhm, h('label', {}, 'Scale'), scale,
    h('button.btn.small', { title: 'Export the spectrum as CSV', onclick: () => exportCSV() }, 'CSV'),
    h('button.btn.small', { title: 'Export this mode as an animated GIF or video', onclick: () => app.command('file.exportAnimation', { source: 'vibration', mode: st.mode }) }, 'GIF…')), canvas);
  const chart = new XYChart(canvas, { onPick: (s) => selectMode(s.sourceIndex) });
  let modes = [];
  let geometry = null;
  let spectrum = null;

  function selectMode(idx) {
    st.mode = idx; st.playing = true; applyMode();
    for (const tr of table.querySelectorAll('tr[data-i]')) tr.classList.toggle('on', Number(tr.dataset.i) === idx);
    table.querySelector(`tr[data-i="${idx}"]`)?.scrollIntoView({ block: 'nearest' });
  }
  function applyMode() {
    const m = modes.find((x) => x.index === st.mode);
    playBtn.innerHTML = st.playing ? 'Stop' : 'Animate';
    chart.select(st.mode);
    if (!m) { vp.stopVibration(); vp.showArrows(null); return; }
    const base = geometry && geometry.atoms.length === m.displacements.length ? geometry.atoms.map((a) => a.pos) : null;
    if (st.playing) vp.startVibration(m.displacements, { amplitude: st.amplitude, speed: st.speed, base }); else vp.stopVibration();
    vp.showArrows(st.arrows ? m.displacements : null, 1.6, base);
    app.status(`Mode ${m.index + 1}: ${m.frequency.toFixed(1)} cm⁻¹${m.symmetry ? ' (' + m.symmetry + ')' : ''}`);
  }
  async function loadSpectrum() {
    try {
      // The engine's default range is 0–4000 cm⁻¹; widen it so high modes (e.g. O–H/N–H stretches above
      // 4000 at low levels of theory) and their line shape tails stay on the plot.
      const top = modes.reduce((mx, m) => Math.max(mx, (m.frequency || 0) * (st.scale || 1)), 0);
      const xMax = Math.max(4000, Math.ceil((top + 4 * (st.fwhm || 10) + 100) / 500) * 500);
      spectrum = await request('analysis.spectrum', { docId: d.docId, kind: st.kind, fwhm: st.fwhm, scale: st.scale, xMin: 0, xMax, points: Math.round(xMax / 2) });
      chart.set({ x: decodeF32(spectrum.xB64), y: decodeF32(spectrum.yB64), sticks: spectrum.sticks, xLabel: spectrum.xLabel, yLabel: spectrum.yLabel, reversed: spectrum.xAxisReversed });
      chart.select(st.mode);
    } catch (e) { chart.set(null); app.status(`Spectrum: ${e.message}`); }
  }
  function exportCSV() {
    if (!spectrum) return;
    const x = decodeF32(spectrum.xB64), y = decodeF32(spectrum.yB64);
    let csv = `${spectrum.xLabel},${spectrum.yLabel}\n`;
    for (let i = 0; i < x.length; i++) csv += `${x[i]},${y[i]}\n`;
    csv += `\nstick x,height,label\n` + spectrum.sticks.map((s) => `${s.x},${s.height},${s.label || ''}`).join('\n');
    api.saveFileDialog({ title: 'Export spectrum', defaultPath: `${d.name.replace(/\.[^.]+$/, '')}-${st.kind}.csv`, filters: [{ name: 'CSV', extensions: ['csv'] }] }).then((p) => p && api.writeTextFile(p, csv));
  }
  (async () => {
    try {
      const r = d.cache.modesResult || (d.cache.modesResult = await request('analysis.modes', { docId: d.docId }));
      modes = r.modes || []; geometry = r.geometry || null;
    } catch (e) { left.append(h('div.empty', {}, e.message)); return; }
    const hasRaman = modes.some((m) => m.ramanActivity != null);
    const hasLabel = modes.some((m) => m.label && !/cm/.test(m.label));
    table.append(h('tr', {}, h('th', {}, '#'), h('th.num', {}, 'cm⁻¹'), h('th.num', {}, 'IR'), hasRaman ? h('th.num', {}, 'Raman') : null, h('th', {}, 'Sym'), hasLabel ? h('th', {}, 'Character') : null));
    for (const m of modes) {
      table.append(h('tr', { dataset: { i: m.index }, onclick: () => selectMode(m.index) },
        h('td', {}, m.index + 1), h('td.num' + (m.frequency < 0 ? '.imag' : ''), {}, m.frequency < 0 ? `${Math.abs(m.frequency).toFixed(1)}i` : m.frequency.toFixed(1)),
        h('td.num', {}, fmt(m.irIntensity, 1)), hasRaman ? h('td.num', {}, fmt(m.ramanActivity, 1)) : null, h('td', {}, m.symmetry || ''),
        hasLabel ? h('td', { title: m.label }, m.label) : null));
    }
    if (app.pendingMode !== undefined) { const pm = app.pendingMode; app.pendingMode = undefined; if (pm == null) { st.playing = false; applyMode(); } else selectMode(pm); }
    else applyMode();
    loadSpectrum();
  })();
  const off = app.on('show-mode', (idx) => {
    if (!modes.length) { app.pendingMode = idx; return; }
    if (idx == null) { st.playing = false; applyMode(); } else selectMode(idx);
  });
  return {
    dispose() { vp.stopVibration(); vp.showArrows(null); chart.ro.disconnect(); st.playing = false; off(); },
  };
}

// ---------- UV-Vis ----------
function buildUVVis(app, d, body) {
  const left = h('div.pane.fixed', { style: { width: '300px', padding: 0 } });
  const right = h('div.pane.chart');
  body.append(left, right);
  const st = d.cache.uv || (d.cache.uv = { fwhm: 0.3, unit: 'nm' });
  const fwhm = h('input', { type: 'number', min: 0.01, step: 0.05, value: st.fwhm, style: { width: '64px' }, title: 'Broadening (eV)', onchange: () => { st.fwhm = Number(fwhm.value); load(); } });
  const canvas = h('canvas.chart-canvas');
  const axis = segmented([{ value: 'wavelengthNM', label: 'nm' }, { value: 'energyEV', label: 'eV' }, { value: 'wavenumber', label: 'cm⁻¹' }], st.axis || 'wavelengthNM', (v) => { st.axis = v; load(); });
  right.append(h('div.chart-tools', {}, axis, h('label', {}, 'FWHM (eV)'), fwhm), canvas);
  const chart = new XYChart(canvas, { onPick: (s) => mark(s.sourceIndex) });
  const table = h('table.list'); left.append(table);
  function mark(i) { chart.select(i); for (const tr of table.querySelectorAll('tr[data-i]')) tr.classList.toggle('on', Number(tr.dataset.i) === i); }
  async function load() {
    try {
      const s = await request('analysis.spectrum', { docId: d.docId, kind: 'uvvis', fwhm: st.fwhm, scale: 1, axis: st.axis || 'wavelengthNM' });
      chart.set({ x: decodeF32(s.xB64), y: decodeF32(s.yB64), sticks: s.sticks, xLabel: s.xLabel, yLabel: s.yLabel, reversed: s.xAxisReversed, stickColor: 'rgba(140,90,200,0.9)' });
      // Stick heights are in the curve's units (ε); the oscillator strengths come from doc.result.
      let states = [];
      try { states = (d.cache.result || (d.cache.result = await request('doc.result', { docId: d.docId }))).excitedStates || []; } catch { /* table shows ε only */ }
      const unit = { wavelengthNM: 'nm', energyEV: 'eV', wavenumber: 'cm⁻¹' }[st.axis || 'wavelengthNM'];
      clear(table).append(h('tr', {}, h('th', {}, 'State'), h('th.num', {}, unit), h('th.num', {}, 'eV'), h('th.num', {}, 'f')));
      s.sticks.forEach((k) => {
        const es = states.find((x) => x.index === k.sourceIndex) || states[k.sourceIndex];
        table.append(h('tr', { dataset: { i: k.sourceIndex }, onclick: () => mark(k.sourceIndex) }, h('td', {}, k.label || k.sourceIndex + 1),
          h('td.num', {}, k.x.toFixed(unit === 'eV' ? 3 : 1)), h('td.num', {}, es ? fmt(es.energyEV, 3) : '–'), h('td.num', {}, es ? fmt(es.oscillatorStrength, 4) : '–')));
      });
    } catch (e) { chart.set(null); clear(table).append(h('tr', {}, h('td', {}, e.message))); }
  }
  load();
  return { dispose() { chart.ro.disconnect(); } };
}

// ---------- Trajectory ----------
function buildTrajectory(app, d, body) {
  const left = h('div.pane.fixed', { style: { width: '330px' } });
  const right = h('div.pane.chart');
  body.append(left, right);
  const n = d.summary.frameCount;
  // The document geometry is the last frame, except for PDB models (the document opens on model 1, like RCSB).
  const home = d.summary.format === 'pdb' ? 0 : n - 1;
  const st = d.cache.traj || (d.cache.traj = { frame: home, fps: 8, playing: false, loop: true });
  const frameCache = new Map();
  const slider = h('input', { type: 'range', min: 0, max: n - 1, step: 1, value: st.frame, oninput: () => go(Number(slider.value)) });
  const label = h('span', { style: { fontVariantNumeric: 'tabular-nums' } });
  const fps = h('input', { type: 'number', min: 1, max: 60, value: st.fps, style: { width: '54px' }, onchange: () => { st.fps = Number(fps.value) || 8; } });
  const play = h('button.btn.small', { onclick: () => toggle() });
  const loop = h('input', { type: 'checkbox', checked: st.loop, onchange: () => { st.loop = loop.checked; } });
  const energyInfo = h('div', { style: { fontSize: '12px', color: 'var(--text-2)', marginTop: '6px' } });
  left.append(
    h('div.row', {}, h('button.icon-btn', { title: 'First frame', innerHTML: ICONS.prev, onclick: () => go(0) }), play, h('button.icon-btn', { title: 'Last frame', innerHTML: ICONS.next, onclick: () => go(n - 1) }), label),
    h('div.row', {}, slider),
    h('div.row', {}, h('label', {}, 'Frames/s'), fps, h('label.check', {}, loop, 'Loop'), h('span.grow'),
      h('button.btn.small', { title: 'Make this frame the document geometry (undoable)', onclick: () => adopt() }, 'Use this geometry'),
      h('button.btn.small', { title: 'Export the trajectory as an animated GIF or video', onclick: () => app.command('file.exportAnimation', { source: 'trajectory' }) }, 'GIF…')),
    energyInfo);
  const canvas = h('canvas.chart-canvas');
  right.append(canvas);
  const chart = new XYChart(canvas, { onPick: () => {} });
  canvas.addEventListener('click', (e) => {
    if (!chart.data) return;
    const b = chart.bounds(), lay = chart.layout();
    const x = chart.pxToX(e.offsetX, b, lay);
    let best = 0; for (let i = 0; i < chart.data.x.length; i++) if (Math.abs(chart.data.x[i] - x) < Math.abs(chart.data.x[best] - x)) best = i;
    go(best);
  });
  let energies = [];
  let timer = null; let busy = false;
  async function go(i) {
    i = Math.max(0, Math.min(n - 1, i));
    st.frame = i; slider.value = i;
    label.textContent = `Frame ${i + 1} / ${n}`;
    chart.select(i);
    if (energies[i] != null) energyInfo.textContent = `E = ${energies[i].toFixed(8)} Eh · ΔE = ${((energies[i] - Math.min(...energies)) * 627.5095).toFixed(2)} kcal/mol`;
    if (busy) return; busy = true;
    try {
      let m = frameCache.get(i);
      if (!m) { m = await request('doc.molecule', { docId: d.docId, frame: i }); frameCache.set(i, m); }
      if (app.active !== d) return;
      if (!app.viewport.setDisplayedPositions(m.atoms.map((a) => a.pos))) app.viewport.setMolecule(m, { keepSelection: true });
      d.frame = i;
    } catch (e) { app.status(e.message); } finally { busy = false; }
  }
  function toggle() {
    st.playing = !st.playing;
    play.textContent = st.playing ? 'Pause' : 'Play';
    clearTimeout(timer);
    if (st.playing) tick();
  }
  function tick() {
    if (!st.playing) return;
    let next = st.frame + 1;
    if (next >= n) { if (!st.loop) { toggle(); return; } next = 0; }
    go(next).then(() => { timer = setTimeout(tick, 1000 / st.fps); });
  }
  async function adopt() {
    const m = frameCache.get(st.frame) || await request('doc.molecule', { docId: d.docId, frame: st.frame });
    await app.edit({ type: 'replaceMolecule', molecule: m }, { message: `Frame ${st.frame + 1} is now the document geometry` });
  }
  play.textContent = 'Play';
  (async () => {
    try {
      const f = await request('doc.frames', { docId: d.docId });
      energies = f.energies || [];
      if (f.profile && f.profile.coordinates?.length) {
        chart.set({ x: Float32Array.from(f.profile.coordinates), y: Float32Array.from(f.profile.relativeKcal), sticks: [], xLabel: f.profile.xLabel || 'Coordinate', yLabel: 'ΔE (kcal/mol)', line: true, markers: true });
      } else if (energies.length) {
        const e0 = Math.min(...energies);
        chart.set({ x: Float32Array.from(energies.map((_, i) => i + 1)), y: Float32Array.from(energies.map((e) => (e - e0) * 627.5095)), sticks: [], xLabel: 'Frame', yLabel: 'ΔE (kcal/mol)', line: true, markers: true });
        // chart x is 1-based; select() uses index into data arrays, which matches frame index.
      } else chart.set(null);
    } catch (e) { chart.set(null); }
    go(st.frame);
  })();
  return {
    dispose() { st.playing = false; clearTimeout(timer); chart.ro.disconnect(); if (app.active === d && d.frame != null && d.frame !== home) app.viewport.setMolecule(d.molecule, { keepSelection: true }); d.frame = null; },
  };
}
