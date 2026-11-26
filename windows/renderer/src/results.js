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
  const seen = new Set(); // documents the panel has shown (the first showing may pick the Trajectory tab)
  const render = () => {
    const d = app.active;
    clear(tabsEl);
    if (!d || !(hasResultData(d) || app.zmatrixOpen)) { clear(body); current?.dispose?.(); current = null; builtFor = null; return; }
    const visible = tabs.filter((t) => t.show(d));
    const frames = d.summary.frameCount || 1;
    const isCalcOutput = !!d.summary.program && d.summary.format !== 'pdb';
    // A geometry optimization (or scan / IRC) opens on its Trajectory tab, unless the file also has vibrations or
    // excited states to look at first; the "Play" button next to the tabs reaches it from anywhere.
    if (!seen.has(d.docId)) {
      seen.add(d.docId);
      if (frames > 1 && isCalcOutput && !d.summary.modeCount && !d.summary.excitedStateCount) state.tab = 'trajectory';
    }
    if (!visible.some((t) => t.id === state.tab)) state.tab = visible[0].id;
    for (const t of visible) tabsEl.append(h('button.tab' + (t.id === state.tab ? '.on' : ''), { onclick: () => { state.tab = t.id; render(); } }, t.label));
    tabsEl.append(h('span.grow'));
    if (frames > 1) {
      const what = isCalcOutput ? 'optimization' : d.summary.format === 'pdb' ? 'models' : 'frames';
      tabsEl.append(h('button.btn.small' + (state.tab === 'trajectory' ? '' : '.primary'), {
        style: { marginRight: '6px', display: 'inline-flex', alignItems: 'center', gap: '4px' },
        title: `Animate the ${frames} ${isCalcOutput ? 'optimization steps' : what} in the 3D view (Trajectory tab)`,
        onclick: () => {
          const st = d.cache.traj || (d.cache.traj = {});
          st.autoplay = true;
          if (state.tab === 'trajectory') { builtFor = null; } else state.tab = 'trajectory';
          render();
        },
      }, h('span', { innerHTML: ICONS.play.replace('<svg ', '<svg width="12" height="12" '), style: { display: 'inline-flex' } }), `Play ${what} (${frames})`));
    }
    tabsEl.append(h('button.icon-btn', { title: 'Hide results (Ctrl+Alt+R)', innerHTML: '&#x2715;', onclick: () => app.command('panel.results') }));
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
  app.on('results-tab', (req) => {
    // "trajectory:play" (Play button, smoke tests via VIBEVIEW_SMOKE_TAB) opens the Trajectory tab and starts playback.
    const [id, arg] = String(req).split(':');
    if (id === 'zmatrix') app.zmatrixOpen = true;
    if (id === 'trajectory' && arg === 'play' && app.active) (app.active.cache.traj || (app.active.cache.traj = {})).autoplay = true;
    state.tab = id; builtFor = null; app.settings.panels.results = true; app.emit('panels'); render();
  });
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
const KCAL = 627.5095;

/** The energy chart with a fractional playhead and the converged final step marked. */
class TrajectoryChart extends XYChart {
  draw() {
    super.draw();
    const d = this.data;
    if (!d || !d.x || !d.x.length || !this.canvas.clientWidth) return;
    const ctx = this.canvas.getContext('2d'); // super.draw left the DPR transform in place
    const b = this.bounds(), lay = this.layout();
    const css = (n, f) => getComputedStyle(document.documentElement).getPropertyValue(n).trim() || f;
    const top = b.ymax * 1.08, y0 = Math.min(0, b.ymin);
    const yPx = (y) => lay.T + lay.ph - ((y - y0) / (top - y0)) * lay.ph;
    ctx.save();
    ctx.beginPath(); ctx.rect(lay.L, lay.T, lay.pw, lay.ph); ctx.clip();
    if (this.playhead != null) {
      const px = this.xToPx(this.playhead + 1, b, lay);
      ctx.strokeStyle = css('--accent', '#3478f6'); ctx.globalAlpha = 0.55; ctx.lineWidth = 1.5;
      ctx.beginPath(); ctx.moveTo(px, lay.T); ctx.lineTo(px, lay.T + lay.ph); ctx.stroke(); ctx.globalAlpha = 1;
    }
    ctx.restore(); // the final-step ring may overlap the plot border
    // Final step: a ring (green when the optimizer reported convergence) and a label.
    const m = this.finalMark;
    if (m && m.dataIndex != null && m.dataIndex < d.x.length) {
      const px = this.xToPx(d.x[m.dataIndex], b, lay), py = yPx(d.y[m.dataIndex]);
      const col = m.converged === true ? css('--ok', '#1f8a4c') : m.converged === false ? css('--warn', '#b26a00') : css('--text-2', '#888');
      ctx.strokeStyle = col; ctx.lineWidth = 2;
      ctx.beginPath(); ctx.arc(px, py, 8, 0, Math.PI * 2); ctx.stroke();
      if (m.label) {
        ctx.font = '11px "Segoe UI", sans-serif'; ctx.fillStyle = col; ctx.textBaseline = 'bottom';
        const tw = ctx.measureText(m.label).width;
        ctx.textAlign = px + 10 + tw > lay.L + lay.pw ? 'right' : 'left';
        ctx.fillText(m.label, ctx.textAlign === 'right' ? px - 10 : px + 10, Math.max(lay.T + 14, py - 11));
      }
    }
  }
}

/**
 * Frame coordinates for the player: one `doc.frameCoordinates` call (all frames as one Float32 array), or, from an
 * engine without it, every frame through `doc.molecule`. Cached on the document.
 */
async function loadFrameData(d, n, onProgress) {
  if (d.cache.trajData && d.cache.trajData.count === n) return d.cache.trajData;
  let out = null;
  try {
    const r = await request('doc.frameCoordinates', { docId: d.docId });
    const xyz = decodeF32(r.positionsB64);
    out = { count: r.count, atomCounts: r.atomCounts, xyz, sameTopology: r.sameTopology, mols: new Map() };
  } catch (e) {
    if (e.code && e.code !== 'bad_request') throw e; // older engine: "unknown method" is a bad_request
    const mols = new Map(), counts = [], same = [], parts = [];
    const key = (m) => m.atoms.map((a) => a.z).join(',') + '|' + m.bonds.map((b) => Math.min(b.a, b.b) + '-' + Math.max(b.a, b.b)).sort().join(',');
    let prev = null;
    for (let k = 0; k < n; k++) {
      const m = await request('doc.molecule', { docId: d.docId, frame: k });
      mols.set(k, m);
      counts.push(m.atoms.length);
      const kk = key(m); same.push(k > 0 && kk === prev); prev = kk;
      const f = new Float32Array(m.atoms.length * 3);
      m.atoms.forEach((a, i) => { f[3 * i] = a.pos[0]; f[3 * i + 1] = a.pos[1]; f[3 * i + 2] = a.pos[2]; });
      parts.push(f);
      onProgress?.(k + 1);
    }
    const xyz = new Float32Array(parts.reduce((s, f) => s + f.length, 0));
    let o = 0; for (const f of parts) { xyz.set(f, o); o += f.length; }
    out = { count: n, atomCounts: counts, xyz, sameTopology: same, mols };
  }
  // Byte offsets per frame and topology groups (frames between rebonds share the drawn bonds).
  out.offsets = new Int32Array(out.count + 1);
  out.group = new Int32Array(out.count);
  for (let k = 0; k < out.count; k++) {
    out.offsets[k + 1] = out.offsets[k] + out.atomCounts[k] * 3;
    out.group[k] = k === 0 ? 0 : out.sameTopology[k] ? out.group[k - 1] : out.group[k - 1] + 1;
  }
  d.cache.trajData = out;
  return out;
}

function buildTrajectory(app, d, body) {
  const left = h('div.pane.fixed', { style: { width: '340px' } });
  const right = h('div.pane.chart');
  body.append(left, right);
  const n = d.summary.frameCount;
  // The document geometry is the last frame, except for PDB models (the document opens on model 1, like RCSB).
  let home = d.summary.format === 'pdb' ? 0 : n - 1;
  const st = d.cache.traj || (d.cache.traj = {});
  if (st.frame == null) st.frame = home;
  if (st.fps == null) st.fps = 4;
  if (st.mode == null) st.mode = st.loop === false ? 'once' : 'loop';
  if (st.smooth == null) st.smooth = true;
  st.playing = false; // export.js clears this to stop the player; a rebuilt tab starts paused
  const vp = app.viewport;

  // ----- controls -----
  const slider = h('input', { type: 'range', min: 0, max: Math.max(1, n - 1), step: 'any', value: st.frame, style: { flex: '1' },
    oninput: () => { pause(); seek(Number(slider.value)); }, onchange: () => go(Math.round(Number(slider.value))) });
  const label = h('span', { style: { fontVariantNumeric: 'tabular-nums', minWidth: '78px', textAlign: 'right', fontSize: '12px' } });
  const fps = h('input', { type: 'number', min: 0.25, max: 60, step: 0.25, value: st.fps, style: { width: '58px' },
    title: 'Playback speed in optimization steps (frames) per second',
    onchange: () => { st.fps = Math.min(60, Math.max(0.25, Number(fps.value) || 4)); fps.value = st.fps; } });
  const iconBtn = (title, icon, onclick) => h('button.icon-btn', { title, innerHTML: icon, onclick });
  const play = h('button.btn.small.primary', { style: { minWidth: '64px' }, onclick: () => toggle() });
  const smooth = h('input', { type: 'checkbox', checked: st.smooth, onchange: () => { st.smooth = smooth.checked; render(true); } });
  const smoothLabel = h('label.check', { title: 'Interpolate atom positions between steps at the display rate (off: jump from step to step)' }, smooth, 'Smooth');
  const mode = segmented([
    { value: 'once', label: 'Once', title: 'Play to the last step and stop' },
    { value: 'loop', label: 'Loop', title: 'Start again from the first step' },
    { value: 'bounce', label: 'Bounce', title: 'Play forwards and backwards (ping-pong)' },
  ], st.mode, (v) => { st.mode = v; });
  const energyInfo = h('div.selectable', { style: { fontSize: '12px', color: 'var(--text-2)', marginTop: '6px', lineHeight: '1.5', fontVariantNumeric: 'tabular-nums' } });
  const status = h('div', { style: { fontSize: '11.5px', color: 'var(--text-3)', marginTop: '4px' } });
  left.append(
    h('div.row', { style: { gap: '2px' } },
      iconBtn('First step (Home)', ICONS.prev, () => { pause(); go(0); }),
      iconBtn('Previous step', '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><path d="M15 5l-8 7 8 7z"/></svg>', () => { pause(); go(Math.ceil(st.frame - 1e-6) - 1); }),
      play,
      iconBtn('Next step', '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><path d="M9 5l8 7-8 7z"/></svg>', () => { pause(); go(Math.floor(st.frame + 1e-6) + 1); }),
      iconBtn('Last step (End)', ICONS.next, () => { pause(); go(n - 1); }),
      h('span.grow'), label),
    h('div.row', {}, slider),
    h('div.row', {}, h('label', { title: fps.title }, 'Steps/s'), fps, smoothLabel, h('div.grow', {}, mode)),
    h('div.row', {}, h('span.grow'),
      h('button.btn.small', { title: 'Make this step the document geometry (undoable)', onclick: () => adopt() }, 'Use this geometry'),
      h('button.btn.small', { title: 'Export the trajectory as an animated GIF or video', onclick: () => { pause(); app.command('file.exportAnimation', { source: 'trajectory' }); } }, 'GIF…')),
    energyInfo, status);
  const canvas = h('canvas.chart-canvas');
  right.append(canvas);
  const chart = new TrajectoryChart(canvas, { onPick: () => {} });
  canvas.addEventListener('click', (e) => {
    if (!chart.data) return;
    const b = chart.bounds(), lay = chart.layout();
    const x = chart.pxToX(e.offsetX, b, lay);
    let best = 0; for (let i = 0; i < chart.data.x.length; i++) if (Math.abs(chart.data.x[i] - x) < Math.abs(chart.data.x[best] - x)) best = i;
    pause(); go(chart.data.x[best] - 1);
  });

  // ----- data -----
  let info = null;      // doc.frames: frameEnergies, steps (optimizer data), converged, kind, home
  let data = null;      // loadFrameData
  let energies = [];    // per frame (null where unknown)
  let eMin = 0;
  let dataIndexOf = []; // frame -> index into the chart arrays (frames without an energy are not plotted)
  let disposed = false;

  // ----- display -----
  // Positions go to the viewport through reused buffers: a flat Float32Array (setDisplayedPositionsFast, when the
  // viewport has it) or an array of [x, y, z] arrays (setDisplayedPositions).
  let flat = null, nested = null;
  let shownGroup = null;   // topology group whose molecule the viewport draws (null: the document molecule)
  let viewChanged = false; // the viewport shows something other than the document geometry
  let swapping = false;    // a frame molecule is being fetched for a topology change
  let lastShown = NaN;
  // Playback statistics (devtools: __vibeviewTrajectory; logged by the trajectory:play smoke test).
  const stats = { frames: n, shown: 0, interpolated: 0, swaps: 0, pushMs: 0, frame: 0, fast: !!vp.setDisplayedPositionsFast };
  window.__vibeviewTrajectory = stats;
  function ensureBuffers(atoms) {
    if (!flat || flat.length !== atoms * 3) {
      flat = new Float32Array(atoms * 3);
      nested = Array.from({ length: atoms }, () => [0, 0, 0]);
    }
  }
  function push(atoms) {
    if (vp.setDisplayedPositionsFast) {
      const ok = vp.setDisplayedPositionsFast(flat, atoms);
      if (ok !== false) return true;
    }
    for (let i = 0; i < atoms; i++) { const p = nested[i]; p[0] = flat[3 * i]; p[1] = flat[3 * i + 1]; p[2] = flat[3 * i + 2]; }
    return vp.setDisplayedPositions(nested);
  }
  async function frameMolecule(k) {
    let m = data.mols.get(k);
    if (!m) { m = await request('doc.molecule', { docId: d.docId, frame: k }); data.mols.set(k, m); }
    return m;
  }
  /** Shows playhead `t` (fractional frame index). */
  function render(force = false) {
    if (!data || disposed || app.active !== d) return;
    const t = Math.max(0, Math.min(n - 1, st.frame));
    let i = Math.floor(t + 1e-9); const f = t - i;
    if (i >= n - 1) i = n - 1;
    const lerp = st.smooth && f > 1e-4 && i + 1 < n && data.sameTopology[i + 1] && data.atomCounts[i] === data.atomCounts[i + 1];
    const k = lerp ? i : Math.min(n - 1, st.playing || !st.smooth ? i : Math.round(t));
    const key = lerp ? t : k;
    if (!force && key === lastShown) return;
    const g = data.group[k];
    const docAtoms = d.molecule?.atoms?.length;
    const docCompatible = shownGroup == null && docAtoms === data.atomCounts[k] && data.group[home] === g;
    if (shownGroup !== g && !docCompatible) {
      // Rebond / different atoms: draw that frame's own molecule (stepping, no interpolation across the change).
      if (swapping) return;
      swapping = true;
      frameMolecule(k).then((m) => {
        swapping = false;
        if (disposed || app.active !== d) return;
        vp.setMolecule(m, { keepSelection: true }); stats.swaps++;
        shownGroup = g; viewChanged = true; lastShown = NaN;
        render(true);
      }, (e) => { swapping = false; app.status(e.message); pause(); });
      return;
    }
    const atoms = data.atomCounts[k];
    ensureBuffers(atoms);
    const a = data.offsets[k], xyz = data.xyz;
    if (lerp) {
      const b = data.offsets[k + 1], u = 1 - f;
      for (let j = 0; j < atoms * 3; j++) flat[j] = xyz[a + j] * u + xyz[b + j] * f;
    } else flat.set(xyz.subarray(a, a + atoms * 3));
    const t0 = performance.now();
    const pushed = push(atoms);
    stats.pushMs = Math.max(stats.pushMs, performance.now() - t0);
    if (!pushed) {
      // The viewport holds a different molecule (atom count changed): load the frame itself.
      shownGroup = -1; lastShown = NaN;
      return render(true);
    }
    lastShown = key;
    stats.shown++; if (lerp) stats.interpolated++; stats.frame = t;
    viewChanged = viewChanged || k !== home || lerp;
    d.frame = k;
  }

  // ----- readout -----
  let lastReadout = -1;
  function readout(force = false) {
    const t = Math.max(0, Math.min(n - 1, st.frame));
    const k = Math.min(n - 1, Math.round(t));
    slider.value = t;
    chart.playhead = t;
    if (dataIndexOf[k] != null) chart.selected = dataIndexOf[k];
    chart.draw();
    if (k === lastReadout && !force) return;
    lastReadout = k;
    const kindWord = info?.kind === 'optimization' ? 'Step' : info?.kind === 'models' ? 'Model' : 'Frame';
    label.textContent = `${kindWord} ${k + 1} / ${n}`;
    const lines = [];
    const e = energies[k];
    if (e != null) {
      let s = `E = ${e.toFixed(8)} Eh · ΔE = ${((e - eMin) * KCAL).toFixed(2)} kcal/mol`;
      const prev = k > 0 ? energies[k - 1] : null;
      if (prev != null) s += ` · step ΔE = ${((e - prev) * KCAL).toFixed(3)} kcal/mol`;
      lines.push(s);
    }
    const si = info?.steps?.[k];
    if (si) {
      const parts = [];
      const g = (x) => (Math.abs(x) >= 1e-3 ? x.toFixed(6) : x.toExponential(2));
      if (si.maxForce != null) parts.push(`max force ${g(si.maxForce)}`);
      if (si.rmsForce != null) parts.push(`RMS force ${g(si.rmsForce)}`);
      if (si.gradientNorm != null) parts.push(`|grad| ${g(si.gradientNorm)}`);
      if (si.maxStep != null) parts.push(`max step ${g(si.maxStep)}`);
      if (si.converged === true) parts.push('criteria met');
      if (parts.length) lines.push(parts.join(' · '));
    }
    if (k === n - 1 && info?.kind === 'optimization' && info.converged != null) {
      lines.push(info.converged ? 'Final step: optimization converged' : 'Final step: the optimization did not converge');
    }
    clear(energyInfo);
    for (const l of lines) energyInfo.append(h('div', {}, l));
  }

  // ----- transport -----
  let raf = 0, lastT = 0, dir = 1, holdUntil = 0;
  function setPlayLabel() { play.textContent = st.playing ? 'Pause' : 'Play'; }
  function pause() { if (st.playing) { st.playing = false; setPlayLabel(); } }
  function toggle() {
    if (!data) return;
    st.playing = !st.playing;
    if (st.playing) {
      if (st.mode !== 'bounce' && st.frame >= n - 1 - 1e-6) st.frame = 0; // replay from the start
      dir = st.mode === 'bounce' && st.frame >= n - 1 - 1e-6 ? -1 : 1;
      holdUntil = 0; lastT = performance.now();
      if (!raf) raf = requestAnimationFrame(tick);
    }
    setPlayLabel();
  }
  let wrapPending = false; // loop mode: holding on the last step before starting over
  function tick(now) {
    raf = 0;
    if (disposed) return;
    if (!st.playing) { setPlayLabel(); readout(true); return; } // paused, or stopped by the animation exporter
    const dt = Math.min(0.1, Math.max(0, (now - lastT) / 1000)); lastT = now;
    if (now >= holdUntil) {
      if (wrapPending) { wrapPending = false; st.frame = 0; }
      else {
        st.frame += dir * dt * st.fps;
        if (dir > 0 && st.frame >= n - 1) {
          st.frame = n - 1;
          // a short hold on the final (converged) step makes the end of the optimization readable
          if (st.mode === 'once') st.playing = false;
          else if (st.mode === 'loop') { holdUntil = now + 700; wrapPending = true; }
          else { dir = -1; holdUntil = now + 400; }
        } else if (dir < 0 && st.frame <= 0) { st.frame = 0; dir = 1; holdUntil = now + 250; }
      }
    }
    render(); readout();
    if (st.playing) raf = requestAnimationFrame(tick); else { setPlayLabel(); readout(true); }
  }
  /** Fractional seek (slider scrubbing): interpolates when Smooth is on. */
  function seek(t) { st.frame = Math.max(0, Math.min(n - 1, t)); render(); readout(); }
  function go(i) { st.frame = Math.max(0, Math.min(n - 1, Math.round(i))); render(true); readout(); }
  async function adopt() {
    pause();
    const k = Math.min(n - 1, Math.round(st.frame));
    go(k);
    try {
      const m = data?.mols.get(k) || await request('doc.molecule', { docId: d.docId, frame: k });
      await app.edit({ type: 'replaceMolecule', molecule: m }, { message: `Step ${k + 1} is now the document geometry` });
    } catch (e) { app.status(e.message); }
  }
  const onKey = (e) => {
    if (app.active !== d || e.target.closest?.('input, textarea, select, [contenteditable]')) return;
    if (!body.isConnected) return;
    if (e.key === ' ' && e.target === document.body) { e.preventDefault(); toggle(); }
  };
  window.addEventListener('keydown', onKey);
  setPlayLabel();

  // ----- load -----
  status.textContent = 'Loading frames…';
  (async () => {
    try {
      info = await request('doc.frames', { docId: d.docId });
      if (info.home != null) home = info.home;
      energies = info.frameEnergies || (info.energies || []).slice(-n);
      while (energies.length < n) energies.unshift(null);
      const known = energies.filter((e) => e != null);
      eMin = known.length ? Math.min(...known) : 0;
      const xs = [], ys = [];
      dataIndexOf = new Array(n);
      energies.forEach((e, k) => { if (e != null) { dataIndexOf[k] = xs.length; xs.push(k + 1); ys.push((e - eMin) * KCAL); } });
      if (xs.length > 1) {
        chart.finalMark = info.kind === 'optimization' && dataIndexOf[n - 1] != null
          ? { dataIndex: dataIndexOf[n - 1], converged: info.converged, label: info.converged === true ? 'converged' : info.converged === false ? 'not converged' : '' }
          : null;
        chart.set({ x: Float32Array.from(xs), y: Float32Array.from(ys), sticks: [], xLabel: info.kind === 'optimization' ? 'Optimization step' : info.kind === 'models' ? 'Model' : 'Frame',
          yLabel: 'ΔE (kcal/mol)', line: true, markers: true, xRange: [1, Math.max(2, n)] });
      } else chart.set(null);
    } catch { chart.set(null); }
    if (disposed) return;
    try {
      data = await loadFrameData(d, n, (k) => { status.textContent = `Loading frames… ${k}/${n}`; });
    } catch (e) { status.textContent = `Could not load the frames: ${e.message}`; return; }
    if (disposed) return;
    status.textContent = data.sameTopology.slice(1).every(Boolean) ? '' : 'Bonds change between some steps: those steps are shown one by one.';
    // Viewport currently draws the document molecule (or a frame we showed before the tab was rebuilt).
    shownGroup = d.frame != null && d.frame !== home ? -1 : null;
    go(st.frame);
    if (st.autoplay) {
      st.autoplay = false; st.frame = 0; go(0); toggle();
      // Smoke tests (VIBEVIEW_SMOKE_TAB=trajectory:play) report how playback went.
      setTimeout(() => { try { api.smokeLog?.(`trajectory: ${JSON.stringify(stats)}`); } catch { /* not in smoke mode */ } }, 1200);
    }
  })();

  return {
    onMolecule() {
      // The document changed (Use this geometry, undo, an edit): the viewport now draws the document molecule.
      shownGroup = null; viewChanged = false; lastShown = NaN; d.frame = null;
    },
    dispose() {
      disposed = true; st.playing = false;
      if (raf) cancelAnimationFrame(raf);
      window.removeEventListener('keydown', onKey);
      chart.ro.disconnect();
      if (app.active === d && (viewChanged || (d.frame != null && d.frame !== home))) vp.setMolecule(d.molecule, { keepSelection: true });
      d.frame = null;
    },
  };
}
