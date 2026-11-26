// Measurements panel: floats at the top right of the viewer while the document has measurements or the
// Gauge tool is active. Large values, editable (moves the smaller side of the structure), removable.
import * as THREE from 'three';
import { h, $, clear } from './dom.js';
import { monitorColor, planesShown, PLANE_COLORS } from './measure-overlay.js';

export function buildMeasurePanel(app) {
  const wrap = $('#viewport-wrap');
  const list = h('div.mp-list');
  // Global "show dihedral planes" setting (a viewport option, saved with the view settings). Changing it
  // resets the per-monitor overrides so it applies to every dihedral.
  const planesBox = h('input', { type: 'checkbox', onchange: () => {
    const d = app.active; if (d) for (const m of d.measurements) delete m.planes;
    app.viewport.setOptions({ dihedralPlanes: planesBox.checked });
    render();
  } });
  const planesAll = h('label.mp-planes-all', { title: 'Show the planes of atoms 1-2-3 and 2-3-4 for every dihedral' }, planesBox, 'Planes');
  const head = h('div.mp-head', {}, h('span', {}, 'Measurements'), h('span.grow'), planesAll,
    h('button.link', { title: 'Remove all measurements', onclick: () => clearAll() }, 'Clear'));
  const hint = h('div.mp-hint');
  const panel = h('div.measure-panel', { hidden: true }, head, list, hint);
  wrap.append(panel);

  const clearAll = () => {
    const d = app.active; if (!d) return;
    for (let k = d.measurements.length - 1; k >= 0; k--) app.removeMeasurement(k);
  };
  const label = (d, m) => m.atoms.map((i) => `${d.molecule.atoms[i]?.symbol ?? '?'}${i + 1}`).join('–');

  const render = () => {
    const d = app.active;
    const ms = d ? d.measurements : [];
    const gauge = app.tool === 'gauge';
    panel.hidden = !d || (!ms.length && !gauge);
    if (panel.hidden) return;
    clear(list);
    planesBox.checked = !!app.viewport.options.dihedralPlanes;
    planesAll.hidden = !ms.some((m) => m.kind === 'dihedral');
    ms.forEach((m, k) => {
      const color = monitorColor(m, ms);
      const unit = m.kind === 'distance' ? 'Å' : '°';
      // Plain text (not type=number) so the value always shows a decimal point; ',' is accepted as '.'.
      const input = h('input.mp-value', {
        type: 'text', inputmode: 'decimal', spellcheck: false, dataset: { decimal: '1' },
        value: m.value.toFixed(m.kind === 'distance' ? 3 : 1), title: 'Type a new value and press Enter to move the smaller side',
      });
      const commit = () => {
        const v = Number(input.value.trim().replace(',', '.'));
        if (Number.isFinite(v) && input.value.trim() !== '') app.setMeasurementValue(m, v);
        else input.value = m.value.toFixed(m.kind === 'distance' ? 3 : 1);
      };
      input.addEventListener('change', commit);
      input.addEventListener('keydown', (e) => e.stopPropagation());
      // Dihedral rows: toggle the two planes of this monitor (overrides the global setting).
      const shown = planesShown(m, app.viewport.options);
      const planesBtn = m.kind !== 'dihedral' ? null : h('button.icon-btn.mp-planes' + (shown ? '.on' : ''), {
        title: shown ? 'Hide the planes 1-2-3 and 2-3-4' : 'Show the planes 1-2-3 and 2-3-4',
        style: `--pa:${PLANE_COLORS[0]};--pb:${PLANE_COLORS[1]}`,
        innerHTML: '<svg viewBox="0 0 16 16" width="14" height="14"><path d="M8 2v12L2 11V5z" fill="var(--pa)" fill-opacity=".55" stroke="var(--pa)"/><path d="M8 2v12l6-3V5z" fill="var(--pb)" fill-opacity=".55" stroke="var(--pb)"/></svg>',
        onclick: () => { m.planes = !shown; app.viewport.updateHighlights(); render(); },
      });
      list.append(h('div.mp-row', { style: `--mc:${color}` },
        h('span.mp-kind', { title: m.kind }, m.kind === 'distance' ? 'd' : m.kind === 'angle' ? '∠' : 'φ'),
        h('span.mp-atoms', { title: label(d, m) }, label(d, m)),
        input, h('span.mp-unit', {}, unit), planesBtn,
        h('button.icon-btn', { title: 'Remove', innerHTML: '&#x2715;', onclick: () => app.removeMeasurement(k) })));
    });
    hint.textContent = gauge
      ? (ms.length ? 'Click 2, 3 or 4 atoms to add more. Esc leaves the Gauge tool.' : 'Click 2, 3 or 4 atoms for a distance, angle or dihedral.')
      : '';
    hint.hidden = !hint.textContent;
  };
  // Re-render on edits, but not while the user is typing in one of the value fields.
  const soon = () => { if (!panel.contains(document.activeElement)) render(); };
  app.on('doc', render);
  app.on('tool', render);
  app.on('measurements', render);
  app.on('options', soon);
  app.on('molecule', soon);
  render();
}

/**
 * Smoke-test hook (VIBEVIEW_SMOKE_MEASURE): "auto" adds a distance, an angle and a dihedral along the first
 * bonded heavy-atom chain of the active document (plus a non-bonded distance); JSON
 * {"monitors": [[i,j], [i,j,k], [i,j,k,l]], "planes": true} adds those (0-based atoms) and sets the global
 * plane option. "auto,planes" = auto with planes on.
 */
export function smokeMeasure(app, spec, log) {
  const d = app.active;
  if (!d) return { ok: false };
  let cfg = { monitors: null, planes: false, rotate: null };
  if (spec.startsWith('{')) cfg = { ...cfg, ...JSON.parse(spec) };
  else cfg.planes = spec.split(',').includes('planes');
  const mol = d.molecule;
  if (!cfg.monitors) {
    const nb = mol.atoms.map(() => []);
    for (const b of mol.bonds) { nb[b.a].push(b.b); nb[b.b].push(b.a); }
    const heavy = (i) => mol.atoms[i].z !== 1;
    let chain = null;
    // Prefer a chain whose central bond joins two heavy atoms; outer atoms may be hydrogens.
    for (const b of mol.bonds) {
      if (chain) break;
      for (const [x, y] of [[b.a, b.b], [b.b, b.a]]) {
        if (!heavy(x) || !heavy(y)) continue;
        const a = nb[x].filter((i) => i !== y).sort((p, q) => heavy(q) - heavy(p))[0];
        const e = nb[y].filter((i) => i !== x && i !== a).sort((p, q) => heavy(q) - heavy(p))[0];
        if (a != null && e != null) { chain = [a, x, y, e]; break; }
      }
    }
    if (!chain) return { ok: false };
    cfg.monitors = [chain.slice(0, 2), chain.slice(0, 3), chain, [chain[0], chain[3]]];
  }
  for (const atoms of cfg.monitors) app.addMeasurement(atoms);
  if (cfg.planes) app.viewport.setOptions({ dihedralPlanes: true });
  // "rotate": [[axis, degrees], ...] turns the camera (as the console's view rotate does) for a better view.
  const v = app.viewport;
  // "lookAlong": [i, j] views down the i→j axis (a Newman projection for a dihedral's central bond).
  if (Array.isArray(cfg.lookAlong)) {
    const [a, b] = cfg.lookAlong.map((i) => new THREE.Vector3(...mol.atoms[i].pos));
    const dir = a.clone().sub(b).normalize(); // camera sits on the i side
    const up = Math.abs(dir.y) > 0.9 ? new THREE.Vector3(1, 0, 0) : new THREE.Vector3(0, 1, 0);
    v.orientation.setFromRotationMatrix(new THREE.Matrix4().lookAt(dir, new THREE.Vector3(), up));
    v.updateCamera(); v.dirty = true;
  }
  for (const [axis, deg] of cfg.rotate || []) {
    const ax = { x: [1, 0, 0], y: [0, 1, 0], z: [0, 0, 1] }[axis] || [0, 1, 0];
    v.orientation.premultiply(new THREE.Quaternion().setFromAxisAngle(new THREE.Vector3(...ax), -deg * Math.PI / 180)).normalize();
    v.updateCamera(); v.dirty = true;
  }
  // "vibrate": true animates a synthetic displacement so the monitors are exercised while atoms move.
  if (cfg.vibrate) v.startVibration(mol.atoms.map((a, i) => [Math.sin(i * 1.7), Math.cos(i * 2.3), Math.sin(i * 0.9 + 1)]), { amplitude: 0.35 });
  // "removeCheck": true removes every monitor, checks the 3D plane objects were disposed, then re-adds them.
  if (cfg.removeCheck) {
    const saved = d.measurements.map((m) => m.atoms);
    for (let k = d.measurements.length - 1; k >= 0; k--) app.removeMeasurement(k);
    const left = v.measureOverlay.planes.size + v.measureOverlay.group.children.length;
    log(`measure: after removing all, ${left} plane objects left`);
    if (left) return { ok: false };
    for (const atoms of saved) app.addMeasurement(atoms);
  }
  log(`measure: ${d.measurements.map((m) => `${m.kind} ${m.atoms.map((i) => i + 1).join('-')} = ${m.value.toFixed(2)} ${m.color}`).join('; ')}`);
  return { ok: d.measurements.length >= cfg.monitors.length };
}
