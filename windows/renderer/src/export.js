// File > Export: structure formats (engine doc.exportAs), images (PNG/JPEG), animations (GIF, WebM/MP4) of
// trajectories, vibrational modes and turntable spins, and result tables as CSV.
// Files are written only to paths picked in a Save dialog (main.js keeps that allowlist).
import { h, clear, modal, select, segmented, toast, decodeF32 } from './dom.js';
import { api, request } from './api.js';
import { GifEncoder, buildPalette, frameDelays } from './gif.js';

const KCAL = 627.509474;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const baseName = (d) => (d?.name || 'molecule').replace(/\.[^.]+$/, '');
const shortPath = (p) => p.split(/[\\/]/).pop();

function bytesToB64(bytes) {
  let s = '';
  for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
  return btoa(s);
}
function savedToast(p, extra = '') {
  toast(`Saved ${shortPath(p)}${extra}`, { kind: 'ok', action: { label: 'Show in Explorer', run: () => api.revealInExplorer(p) } });
}

// ---------------------------------------------------------------------------------------------------------
// Structure export
// ---------------------------------------------------------------------------------------------------------

/** Formats for the active document (engine list, or engine.info's write list on an older engine). */
async function structureFormats(app, d) {
  try { return (await request('doc.exportFormats', { docId: d.docId })).formats; } catch {
    const w = app.engineInfo?.formats?.write || [{ id: 'xyz', name: 'XYZ', extensions: ['xyz'] }];
    return w.map((f) => ({ ...f, multiFrame: false, available: true, legacy: true }));
  }
}

/** Text of a structure export. opts: {format, frames: 'current'|'all'|[k], atoms: [i]|null, energies, volume}. */
export async function exportStructureText(d, opts, legacy = false) {
  if (legacy) return request('doc.export', { docId: d.docId, format: opts.format });
  return request('doc.exportAs', { docId: d.docId, ...opts });
}

function buildStructurePane(app, d, ctx) {
  const pane = h('div.export-pane');
  const sel = [...(d.selection || [])].sort((a, b) => a - b);
  const nFrames = d.summary.frameCount || 1;
  const st = app.settings.exportStructure || (app.settings.exportStructure = { format: 'xyz', frames: 'current', energies: true });
  let formats = [];
  const fmtSel = h('select', { style: { minWidth: '260px' } });
  const framesSeg = segmented([{ value: 'current', label: 'Current structure' }, { value: 'all', label: `All ${nFrames} frames` }], st.frames, (v) => { st.frames = v; refresh(); });
  const selOnly = h('input', { type: 'checkbox', checked: false, onchange: () => refresh() });
  const energies = h('input', { type: 'checkbox', checked: st.energies !== false, onchange: () => { st.energies = energies.checked; refresh(); } });
  const volSel = h('select');
  const note = h('div.hint', { style: { fontSize: '12px', color: 'var(--text-2)', minHeight: '16px' } });
  const preview = h('textarea', { readOnly: true, spellcheck: false, style: { width: '100%', height: '210px', fontFamily: 'Consolas, "Cascadia Mono", monospace', fontSize: '11.5px', whiteSpace: 'pre', resize: 'vertical' } });
  const rowFrames = h('div.row', {}, h('label', { style: { width: '90px' } }, 'Frames'), framesSeg);
  const rowEnergies = h('label.check', {}, energies, 'Write frame energies (title line / SD data)');
  const rowSel = h('label.check', {}, selOnly, `Selected atoms only (${sel.length})`);
  const rowVol = h('div.row', {}, h('label', { style: { width: '90px' } }, 'Volume'), volSel);
  pane.append(
    h('div.row', {}, h('label', { style: { width: '90px' } }, 'Format'), fmtSel),
    rowFrames, rowSel, rowEnergies, rowVol, note,
    h('div', { style: { fontSize: '12px', color: 'var(--text-2)', margin: '6px 0 2px' } }, 'Preview'), preview);
  let timer = null;
  const current = () => formats.find((f) => f.id === fmtSel.value) || formats[0];
  const params = () => {
    const f = current();
    const p = { format: f.id, energies: energies.checked };
    p.frames = f.multiFrame && nFrames > 1 ? st.frames : 'current';
    if (selOnly.checked && sel.length) p.atoms = sel;
    if (f.id === 'cube' && volSel.value) p.volume = volSel.value;
    return p;
  };
  function refresh() {
    const f = current(); if (!f) return;
    st.format = f.id; app.saveSettingsSoon();
    rowFrames.hidden = !(f.multiFrame && nFrames > 1);
    rowSel.hidden = !sel.length || f.legacy;
    rowEnergies.hidden = !(['xyz', 'sdf'].includes(f.id) && (nFrames > 1 || d.summary.hasResult));
    rowVol.hidden = f.id !== 'cube' || !(f.volumes?.length > 1);
    const notes = [];
    if (f.note) notes.push(f.note);
    if (/Input$/.test(f.id)) notes.push('Default job (B3LYP single point). For a real job use Calculate > Calculation Setup.');
    if (!f.multiFrame && nFrames > 1) notes.push('This format holds one structure: the current one is written.');
    note.textContent = notes.join(' · ');
    clearTimeout(timer);
    timer = setTimeout(async () => {
      if (f.available === false) { preview.value = f.note || 'Not available for this document'; return; }
      try {
        const r = await exportStructureText(d, params(), f.legacy);
        const lines = r.text.split('\n');
        preview.value = lines.slice(0, 80).join('\n') + (lines.length > 80 ? `\n… (${lines.length} lines)` : '');
      } catch (e) { preview.value = e.message; }
    }, 120);
  }
  fmtSel.addEventListener('change', refresh);
  (async () => {
    formats = await structureFormats(app, d);
    clear(fmtSel).append(...formats.map((f) => h('option', { value: f.id, disabled: f.available === false, selected: f.id === st.format }, `${f.name} (*.${f.extensions[0]})${f.available === false ? ' – n/a' : ''}`)));
    if (!current() || current().available === false) fmtSel.value = 'xyz';
    const cube = formats.find((f) => f.id === 'cube');
    clear(volSel).append(...(cube?.volumes || []).map((v) => h('option', { value: v }, v)));
    refresh();
  })();
  ctx.run = async () => {
    const f = current(); if (!f || f.available === false) return;
    const exts = f.extensions || ['txt'];
    const p = await api.saveFileDialog({ title: `Export ${f.name}`, defaultPath: `${baseName(d)}.${exts[0]}`, filters: [{ name: f.name, extensions: exts }, { name: 'All files', extensions: ['*'] }] });
    if (!p) return;
    try {
      const r = await exportStructureText(d, params(), f.legacy);
      await api.writeTextFile(p, r.text);
      savedToast(p, r.frameCount > 1 ? ` (${r.frameCount} frames)` : '');
      ctx.close();
    } catch (e) { app.error('Export failed', e); }
  };
  ctx.runLabel = 'Export…';
  return pane;
}

// ---------------------------------------------------------------------------------------------------------
// Image export (PNG / JPEG)
// ---------------------------------------------------------------------------------------------------------

async function dataURLToCanvas(url, W, H, canvas) {
  const img = new Image();
  img.src = url;
  await img.decode();
  const c = canvas || document.createElement('canvas');
  if (c.width !== W || c.height !== H) { c.width = W; c.height = H; }
  const g = c.getContext('2d', { willReadFrequently: true });
  g.clearRect(0, 0, W, H);
  g.drawImage(img, 0, 0, W, H);
  return c;
}

/** Renders the viewport as PNG or JPEG; returns base64 (no data: prefix). */
export async function renderImage(vp, { width, height, format = 'png', transparent = false, quality = 0.92 }) {
  const url = vp.exportPNG(width, height, { transparent: transparent && format === 'png' });
  if (format === 'png') return url.split(',')[1];
  const c = await dataURLToCanvas(url, width, height);
  // JPEG has no alpha: compose over the viewport background (exportPNG already painted it).
  return c.toDataURL('image/jpeg', quality).split(',')[1];
}

function buildImagePane(app, d, ctx) {
  const vp = app.viewport;
  const s = app.settings.exportImage2 || { width: Math.round(vp.width * 2), height: Math.round(vp.height * 2), format: 'png', transparent: false, quality: 92 };
  const w = h('input', { type: 'number', min: 64, max: 8192, value: s.width, style: { width: '86px' } });
  const hh = h('input', { type: 'number', min: 64, max: 8192, value: s.height, style: { width: '86px' } });
  const keep = h('input', { type: 'checkbox', checked: true });
  const transparent = h('input', { type: 'checkbox', checked: !!s.transparent });
  const quality = h('input', { type: 'number', min: 40, max: 100, value: s.quality || 92, style: { width: '60px' } });
  const aspect = vp.width / vp.height;
  w.addEventListener('input', () => { if (keep.checked) hh.value = Math.round(Number(w.value) / aspect); });
  hh.addEventListener('input', () => { if (keep.checked) w.value = Math.round(Number(hh.value) * aspect); });
  let format = s.format || 'png';
  const rowT = h('label.check', {}, transparent, 'Transparent background');
  const rowQ = h('div.row', {}, h('label', {}, 'JPEG quality'), quality, h('span', {}, '%'));
  const upd = () => { rowT.hidden = format !== 'png'; rowQ.hidden = format !== 'jpeg'; };
  const fmt = segmented([{ value: 'png', label: 'PNG' }, { value: 'jpeg', label: 'JPEG' }], format, (v) => { format = v; upd(); });
  const presets = h('div.btn-row', {}, [1, 2, 3, 4].map((k) => h('button.btn.small', { onclick: () => { w.value = Math.round(vp.width * k); hh.value = Math.round(vp.height * k); } }, `${k}×`)),
    h('button.btn.small', { onclick: () => { w.value = 1920; hh.value = keep.checked ? Math.round(1920 / aspect) : 1080; } }, '1920 wide'),
    h('button.btn.small', { onclick: () => { w.value = 3000; hh.value = keep.checked ? Math.round(3000 / aspect) : 2000; } }, '3000 wide (print)'));
  upd();
  ctx.run = async () => {
    const W = Math.max(64, Math.min(8192, Number(w.value) || 1600)), H = Math.max(64, Math.min(8192, Number(hh.value) || 1200));
    app.settings.exportImage2 = { width: W, height: H, format, transparent: transparent.checked, quality: Number(quality.value) || 92 }; app.saveSettingsSoon();
    const ext = format === 'png' ? 'png' : 'jpg';
    const p = await api.saveFileDialog({ title: 'Export Image', defaultPath: `${baseName(d)}.${ext}`, filters: [format === 'png' ? { name: 'PNG image', extensions: ['png'] } : { name: 'JPEG image', extensions: ['jpg', 'jpeg'] }] });
    if (!p) return;
    try {
      const b64 = await renderImage(vp, { width: W, height: H, format, transparent: transparent.checked, quality: (Number(quality.value) || 92) / 100 });
      await api.writeFileBase64(p, b64);
      savedToast(p, ` (${W}×${H})`);
      ctx.close();
    } catch (e) { app.error('Image export failed', e); }
  };
  ctx.runLabel = 'Export…';
  return h('div.export-pane', {},
    h('div.row', {}, h('label', { style: { width: '90px' } }, 'Format'), fmt),
    h('div.row', {}, h('label', { style: { width: '90px' } }, 'Size'), w, h('span', {}, '×'), hh, h('span', {}, 'px')),
    h('label.check', {}, keep, 'Keep the window\'s aspect ratio'), rowT, rowQ,
    h('div', { style: { margin: '8px 0 4px', fontSize: '12px', color: 'var(--text-2)' } }, 'Presets'), presets);
}

// ---------------------------------------------------------------------------------------------------------
// Animation: frame sources, offscreen rendering, GIF / video encoding
// ---------------------------------------------------------------------------------------------------------

function measure(P, m) {
  const a = m.atoms.map((i) => P[i]);
  if (a.some((p) => !p)) return null;
  const sub = (p, q) => [p.x - q.x, p.y - q.y, p.z - q.z];
  const dot = (u, v) => u[0] * v[0] + u[1] * v[1] + u[2] * v[2];
  const cross = (u, v) => [u[1] * v[2] - u[2] * v[1], u[2] * v[0] - u[0] * v[2], u[0] * v[1] - u[1] * v[0]];
  const len = (u) => Math.sqrt(dot(u, u));
  if (a.length === 2) return len(sub(a[0], a[1]));
  if (a.length === 3) { const u = sub(a[0], a[1]), v = sub(a[2], a[1]); return (Math.acos(Math.max(-1, Math.min(1, dot(u, v) / (len(u) * len(v) || 1)))) * 180) / Math.PI; }
  const b1 = sub(a[1], a[0]), b2 = sub(a[2], a[1]), b3 = sub(a[3], a[2]);
  const n1 = cross(b1, b2), n2 = cross(b2, b3);
  const m1 = cross(n1, b2.map((x) => x / (len(b2) || 1)));
  return (Math.atan2(dot(m1, n2), dot(n1, n2)) * 180) / Math.PI;
}

/** What can be animated for this document. */
export async function animationSources(app, d) {
  const out = [];
  if ((d.summary.frameCount || 1) > 1) out.push({ id: 'trajectory', label: `Trajectory (${d.summary.frameCount} frames)` });
  if ((d.summary.modeCount || 0) > 0) out.push({ id: 'vibration', label: 'Vibrational mode' });
  if (d.molecule?.atoms?.length) out.push({ id: 'spin', label: 'Turntable (360° rotation)' });
  return out;
}

async function loadModes(d) {
  return d.cache.modesResult || (d.cache.modesResult = await request('analysis.modes', { docId: d.docId }));
}

/**
 * Builds the frame list: [{positions: [[x,y,z]] | null, molecule: Molecule | null, rotate: radians, caption, index}].
 * opts: {source, mode, cycleFrames, cycles, amplitude, step, pingpong, spinFrames, spinAxis, bonds}
 */
async function buildFrames(app, d, opts, onProgress) {
  const frames = [];
  const info = { captionLines: [], energies: null };
  if (opts.source === 'trajectory') {
    const n = d.summary.frameCount;
    const f = await request('doc.frames', { docId: d.docId }).catch(() => ({ energies: [] }));
    let e = f.energies || [];
    if (e.length > n) e = e.slice(e.length - n);
    const off = n - e.length; // energies cover the last frames
    const step = Math.max(1, opts.step | 0);
    const ks = []; for (let k = 0; k < n; k += step) ks.push(k);
    if (ks[ks.length - 1] !== n - 1) ks.push(n - 1);
    const mols = new Map();
    for (let j = 0; j < ks.length; j++) {
      if (opts.cancelled?.()) throw new Error('cancelled');
      mols.set(ks[j], await request('doc.molecule', { docId: d.docId, frame: ks[j] }));
      onProgress?.(`Reading frames ${j + 1}/${ks.length}`, (j + 1) / ks.length * 0.1);
    }
    const energyOf = (k) => (k - off >= 0 && k - off < e.length ? e[k - off] : null);
    const valid = e.filter((x) => x != null);
    info.energies = valid.length > 1 ? ks.map((k) => energyOf(k)) : null;
    const e0 = energyOf(0) ?? valid[0];
    let order = ks.map((k, j) => ({ k, j }));
    if (opts.pingpong && order.length > 2) order = order.concat(order.slice(1, -1).reverse());
    for (const { k, j } of order) {
      const m = mols.get(k);
      const E = energyOf(k);
      const cap = [`Frame ${k + 1} / ${n}`];
      if (E != null) cap.push(`E = ${E.toFixed(6)} Eh   ΔE = ${((E - e0) * KCAL).toFixed(2)} kcal/mol`);
      frames.push({ molecule: m, positions: m.atoms.map((a) => a.pos), caption: cap, plotIndex: j });
    }
  } else if (opts.source === 'vibration') {
    const r = await loadModes(d);
    const mode = r.modes.find((m) => m.index === opts.mode) || r.modes[0];
    if (!mode) throw new Error('No vibrational modes');
    const geo = r.geometry && r.geometry.atoms.length === mode.displacements.length ? r.geometry : d.molecule;
    if (geo.atoms.length !== mode.displacements.length) {
      throw new Error(`The vibrational modes have ${mode.displacements.length} atoms but the structure now has ${geo.atoms.length}: undo the edits (or reopen the file) to animate them.`);
    }
    let maxLen = 0; for (const v of mode.displacements) maxLen = Math.max(maxLen, Math.hypot(...v));
    const k = maxLen > 1e-9 ? (opts.amplitude ?? 0.5) / maxLen : 0;
    const N = Math.max(4, opts.cycleFrames | 0 || 24);
    const freq = mode.frequency < 0 ? `${Math.abs(mode.frequency).toFixed(1)}i` : mode.frequency.toFixed(1);
    const cap = [`Mode ${mode.index + 1}: ${freq} cm⁻¹${mode.symmetry ? ` (${mode.symmetry})` : ''}`];
    if (mode.label && !/cm/.test(mode.label)) cap.push(mode.label);
    for (let c = 0; c < Math.max(1, opts.cycles | 0 || 1); c++) {
      for (let i = 0; i < N; i++) {
        const s = Math.sin((2 * Math.PI * i) / N) * k;
        frames.push({ molecule: geo, positions: geo.atoms.map((a, j) => [a.pos[0] + mode.displacements[j][0] * s, a.pos[1] + mode.displacements[j][1] * s, a.pos[2] + mode.displacements[j][2] * s]), caption: cap });
      }
    }
    info.mode = mode; info.geometry = geo;
  } else {
    const N = Math.max(8, opts.spinFrames | 0 || 36);
    for (let i = 0; i < N; i++) frames.push({ molecule: null, positions: null, rotate: (2 * Math.PI) / N, caption: [] });
  }
  return { frames, info };
}

/** Draws caption lines and an optional energy-profile inset onto a 2D context. */
function drawCaption(g, W, H, frame, info, opts, fg) {
  const fs = Math.max(11, Math.round(Math.min(W, H) / 30));
  g.save();
  g.font = `600 ${fs}px "Segoe UI", system-ui, sans-serif`;
  g.textBaseline = 'bottom'; g.textAlign = 'left';
  g.lineJoin = 'round'; g.lineWidth = Math.max(2, fs / 5);
  const halo = fg === '#f2f2f2' || fg === '#ffffff' ? 'rgba(0,0,0,0.65)' : 'rgba(255,255,255,0.8)';
  const lines = [...(opts.title ? [opts.title] : []), ...(opts.caption ? frame.caption : [])];
  let y = H - Math.round(fs * 0.6);
  for (const t of [...lines].reverse()) {
    g.strokeStyle = halo; g.strokeText(t, Math.round(fs * 0.7), y);
    g.fillStyle = fg; g.fillText(t, Math.round(fs * 0.7), y);
    y -= Math.round(fs * 1.3);
  }
  // Energy profile inset (trajectories with energies).
  const E = info.energies;
  if (opts.profile && E && frame.plotIndex != null) {
    const vals = E.filter((x) => x != null);
    const lo = Math.min(...vals), hi = Math.max(...vals);
    const pw = Math.round(W * 0.28), ph = Math.round(H * 0.18), px = W - pw - Math.round(fs * 0.7), py = H - ph - Math.round(fs * 0.7);
    g.fillStyle = halo.replace(/[\d.]+\)$/, '0.35)'); g.fillRect(px, py, pw, ph);
    g.strokeStyle = fg; g.globalAlpha = 0.5; g.lineWidth = 1; g.strokeRect(px + 0.5, py + 0.5, pw - 1, ph - 1); g.globalAlpha = 1;
    const X = (i) => px + 6 + ((pw - 12) * i) / Math.max(1, E.length - 1);
    const Y = (e) => py + ph - 6 - ((ph - 12) * (e - lo)) / (hi - lo || 1);
    g.beginPath(); let first = true;
    E.forEach((e, i) => { if (e == null) return; if (first) { g.moveTo(X(i), Y(e)); first = false; } else g.lineTo(X(i), Y(e)); });
    g.strokeStyle = '#2f7cf6'; g.lineWidth = Math.max(1.5, fs / 8); g.stroke();
    const e = E[frame.plotIndex];
    if (e != null) { g.beginPath(); g.arc(X(frame.plotIndex), Y(e), Math.max(3, fs / 4), 0, 2 * Math.PI); g.fillStyle = '#e5484d'; g.fill(); }
  }
  g.restore();
}

/**
 * Renders the animation offscreen and encodes it.
 * opts: {source, width, height, fps, loop, format: 'gif'|'webm'|'mp4', dither, caption, profile, title, holdLast(s), …buildFrames opts}
 * hooks: {onProgress(text, fraction), cancelled()} → {bytes: Uint8Array, frames, width, height, mime}
 */
export async function renderAnimation(app, d, opts, hooks = {}) {
  const vp = app.viewport;
  const W = Math.max(32, Math.min(2048, opts.width | 0)), H = Math.max(32, Math.min(2048, opts.height | 0));
  const fps = Math.max(1, Math.min(50, Number(opts.fps) || 12));
  const cancelled = hooks.cancelled || (() => false);
  const progress = hooks.onProgress || (() => {});
  const { frames, info } = await buildFrames(app, d, { ...opts, cancelled }, progress);
  if (!frames.length) throw new Error('Nothing to animate');

  // Save the view state that frame rendering changes.
  const saved = {
    molecule: vp.molecule, positions: vp.positions.map((p) => [p.x, p.y, p.z]), vibration: vp.vibration, camera: vp.getCameraState(),
    selection: vp.selection, arrows: vp.arrows, hover: vp.hover, values: vp.measurements.map((m) => m.value),
  };
  const fg = vp.foreground();
  if (d.cache.traj?.playing) d.cache.traj.playing = false; // the Trajectory tab's player would move atoms meanwhile
  vp.vibration = null;
  vp.hover = null;
  vp.selection = new Set();
  if (vp.arrows) vp.arrows = null;
  let changedMolecule = false;
  if (opts.source === 'vibration' && opts.arrows && info.mode) {
    vp.showArrows(info.mode.displacements, 1.6, info.geometry.atoms.map((a) => a.pos));
  }
  vp.updateHighlights();

  const work = document.createElement('canvas');
  const showFrame = (fr) => {
    if (fr.molecule && opts.bonds && opts.source === 'trajectory' && fr.molecule !== vp.molecule) {
      vp.setMolecule(fr.molecule, { keepSelection: true }); changedMolecule = true;
      vp.selection = new Set();
    }
    if (fr.positions && !vp.setDisplayedPositions(fr.positions)) { vp.setMolecule(fr.molecule, { keepSelection: true }); vp.selection = new Set(); changedMolecule = true; }
    if (fr.rotate) {
      const ax = opts.spinAxis === 'x' ? [1, 0, 0] : [0, 1, 0];
      // Rotate about the screen axis: right-multiplying turns the camera around the molecule.
      const q = new vp.orientation.constructor().setFromAxisAngle({ x: ax[0], y: ax[1], z: ax[2] }, -fr.rotate);
      vp.orientation.multiply(q).normalize();
      vp.updateCamera();
    }
    if (vp.measurements.length) { const P = vp.positions; for (const m of vp.measurements) { const v = measure(P, m); if (v != null) m.value = v; } vp.updateHighlights(); }
  };
  const capture = async (fr) => {
    showFrame(fr);
    const url = vp.exportPNG(W, H, { transparent: false });
    await dataURLToCanvas(url, W, H, work);
    const g = work.getContext('2d', { willReadFrequently: true });
    drawCaption(g, W, H, fr, info, opts, fg);
    return g;
  };

  try {
    const fmt = opts.format || 'gif';
    let bytes, mime;
    const cam0 = vp.getCameraState();
    if (fmt === 'gif') {
      // Pass 1: palette from evenly spaced sample frames (rotation frames are rendered relative to the start view).
      const nS = Math.min(frames.length, 6);
      const samples = [];
      for (let s = 0; s < nS; s++) {
        if (cancelled()) throw new Error('cancelled');
        const k = Math.round((s * (frames.length - 1)) / Math.max(1, nS - 1));
        vp.setCameraState(cam0);
        const fr = frames[k];
        const g = await capture(fr.rotate ? { ...fr, rotate: fr.rotate * k } : fr);
        samples.push(g.getImageData(0, 0, W, H).data);
        progress(`Building palette ${s + 1}/${nS}`, 0.1 + (0.1 * (s + 1)) / nS);
      }
      vp.setCameraState(cam0);
      const palette = buildPalette(samples, 255);
      const enc = new GifEncoder(W, H, { palette, loop: opts.loop !== false });
      const delays = frameDelays(frames.length, fps);
      if (opts.holdLast > 0 && opts.source === 'trajectory' && !opts.pingpong) delays[delays.length - 1] += Math.round(opts.holdLast * 100);
      for (let i = 0; i < frames.length; i++) {
        if (cancelled()) throw new Error('cancelled');
        const g = await capture(frames[i]);
        enc.addFrame(g.getImageData(0, 0, W, H).data, delays[i], { dither: !!opts.dither });
        progress(`Encoding frame ${i + 1}/${frames.length}`, 0.2 + (0.8 * (i + 1)) / frames.length);
        if (i % 4 === 3) await sleep(0); // keep the UI responsive
      }
      bytes = enc.finish(); mime = 'image/gif';
    } else {
      mime = videoMime(fmt);
      if (!mime) throw new Error(`${fmt.toUpperCase()} recording is not supported here`);
      const out = document.createElement('canvas'); out.width = W; out.height = H;
      const og = out.getContext('2d');
      const stream = out.captureStream(0);
      const track = stream.getVideoTracks()[0];
      const rec = new MediaRecorder(stream, { mimeType: mime, videoBitsPerSecond: Math.round(W * H * fps * 0.25) });
      const chunks = [];
      rec.ondataavailable = (e) => { if (e.data.size) chunks.push(e.data); };
      const stopped = new Promise((r) => { rec.onstop = r; });
      const repeats = opts.source === 'trajectory' ? 1 : Math.max(1, opts.videoRepeats | 0 || 3);
      // The recorder starts once the stream delivers a frame: prime it with the first frame.
      og.drawImage((await capture(frames[0])).canvas, 0, 0);
      const started = new Promise((r) => { rec.onstart = r; });
      rec.start(250);
      track.requestFrame();
      await Promise.race([started, sleep(2000)]);
      vp.setCameraState(cam0);
      let n = 0; const total = frames.length * repeats;
      for (let rep = 0; rep < repeats; rep++) {
        if (rep) vp.setCameraState(cam0);
        for (let i = 0; i < frames.length; i++) {
          if (cancelled()) { rec.stop(); await stopped; throw new Error('cancelled'); }
          rec.pause();
          const g = await capture(frames[i]);
          og.drawImage(g.canvas, 0, 0);
          rec.resume();
          track.requestFrame();
          const hold = i === frames.length - 1 && opts.source === 'trajectory' ? (opts.holdLast || 0) * 1000 : 0;
          await sleep(1000 / fps + hold);
          progress(`Recording frame ${++n}/${total}`, 0.1 + (0.9 * n) / total);
        }
      }
      await sleep(200);
      rec.stop(); await stopped;
      bytes = new Uint8Array(await new Blob(chunks, { type: mime }).arrayBuffer());
      if (!bytes.length) throw new Error('the video recorder produced no data');
    }
    return { bytes, frames: frames.length, width: W, height: H, mime };
  } finally {
    // Restore the interactive view.
    if (changedMolecule) vp.setMolecule(saved.molecule, { keepSelection: true });
    vp.setDisplayedPositions(saved.positions);
    vp.setCameraState(saved.camera);
    vp.measurements.forEach((m, i) => { if (i < saved.values.length) m.value = saved.values[i]; });
    vp.selection = saved.selection;
    vp.hover = saved.hover;
    if (vp.arrows && vp.arrows !== saved.arrows) vp.showArrows(null);
    vp.arrows = saved.arrows;
    if (saved.vibration) { saved.vibration.t0 = performance.now(); vp.vibration = saved.vibration; }
    vp.updateHighlights();
    vp.dirty = true;
  }
}

export function videoMime(fmt) {
  if (typeof MediaRecorder === 'undefined') return null;
  const c = fmt === 'mp4' ? ['video/mp4;codecs=avc1', 'video/mp4'] : ['video/webm;codecs=vp9', 'video/webm;codecs=vp8', 'video/webm'];
  return c.find((m) => MediaRecorder.isTypeSupported(m)) || null;
}

function buildAnimationPane(app, d, ctx, initial = {}) {
  const vp = app.viewport;
  const st = app.settings.exportAnim || (app.settings.exportAnim = { width: 800, height: 600, fps: 12, loop: true, caption: true, profile: true, dither: false, cycleFrames: 24, cycles: 1, amplitude: 0.5, spinFrames: 48, spinAxis: 'y', step: 1, pingpong: false, holdLast: 1, format: 'gif', bonds: false, arrows: false });
  const pane = h('div.export-pane');
  const srcSel = h('select', { style: { minWidth: '240px' } });
  const modeSel = h('select', { style: { minWidth: '240px' } });
  const num = (key, attrs) => h('input', { type: 'number', value: st[key], style: { width: '70px' }, ...attrs, onchange: (e) => { st[key] = Number(e.target.value); } });
  const chk = (key, label, title) => { const c = h('input', { type: 'checkbox', checked: !!st[key], onchange: () => { st[key] = c.checked; } }); return h('label.check', { title }, c, label); };
  const wIn = num('width', { min: 64, max: 2048 }), hIn = num('height', { min: 64, max: 2048 });
  const sizePresets = h('span.btn-row', { style: { display: 'inline-flex', gap: '4px' } },
    [[480, 360], [640, 480], [800, 600], [1280, 720]].map(([a, b]) => h('button.btn.small', { onclick: () => { wIn.value = st.width = a; hIn.value = st.height = b; } }, `${a}×${b}`)),
    h('button.btn.small', { title: 'Same aspect ratio as the viewport', onclick: () => { st.height = Math.round(st.width * vp.height / vp.width); hIn.value = st.height; } }, 'Viewport aspect'));
  const supported = ['gif', ...(videoMime('webm') ? ['webm'] : []), ...(videoMime('mp4') ? ['mp4'] : [])];
  if (!supported.includes(st.format)) st.format = 'gif';
  const fmtSeg = segmented(supported.map((f) => ({ value: f, label: f.toUpperCase() })), st.format, (v) => { st.format = v; upd(); });
  const traj = h('div', {},
    h('div.row', {}, h('label', { style: { width: '110px' } }, 'Every Nth frame'), num('step', { min: 1, max: 100 }), chk('pingpong', 'Play forward and back'), chk('bonds', 'Re-detect bonds per frame', 'Bonds follow each frame (bond breaking/forming in scans and IRCs)')),
    h('div.row', {}, h('label', { style: { width: '110px' } }, 'Hold last frame'), num('holdLast', { min: 0, max: 10, step: 0.5 }), h('span', {}, 's'), chk('profile', 'Energy profile inset')));
  const vib = h('div', {},
    h('div.row', {}, h('label', { style: { width: '110px' } }, 'Mode'), modeSel),
    h('div.row', {}, h('label', { style: { width: '110px' } }, 'Frames per cycle'), num('cycleFrames', { min: 8, max: 120 }), h('label', {}, 'Amplitude (Å)'), num('amplitude', { min: 0.05, max: 2, step: 0.05 }), chk('arrows', 'Arrows')));
  const spin = h('div', {},
    h('div.row', {}, h('label', { style: { width: '110px' } }, 'Frames per turn'), num('spinFrames', { min: 8, max: 360 }),
      h('label', {}, 'Axis'), select([{ value: 'y', label: 'Vertical (screen Y)' }, { value: 'x', label: 'Horizontal (screen X)' }], st.spinAxis, (v) => { st.spinAxis = v; })));
  const ditherRow = chk('dither', 'Dither (smoother shading, larger file)');
  const progress = h('progress', { max: 1, value: 0, style: { width: '100%' } });
  const progText = h('div', { style: { fontSize: '12px', color: 'var(--text-2)', minHeight: '16px' } });
  const progRow = h('div', { hidden: true }, progress, progText);
  pane.append(
    h('div.row', {}, h('label', { style: { width: '110px' } }, 'Animate'), srcSel),
    traj, vib, spin,
    h('div.row', {}, h('label', { style: { width: '110px' } }, 'Size'), wIn, h('span', {}, '×'), hIn, h('span', {}, 'px')),
    h('div.row', {}, h('span', { style: { width: '110px' } }), sizePresets),
    h('div.row', {}, h('label', { style: { width: '110px' } }, 'Format'), fmtSeg, h('label', {}, 'Frames/s'), num('fps', { min: 1, max: 50 }), chk('loop', 'Loop forever')),
    h('div.row', {}, h('span', { style: { width: '110px' } }), chk('caption', 'Energy / frequency caption'), ditherRow),
    progRow);
  let sources = [];
  function upd() {
    const s = srcSel.value;
    traj.hidden = s !== 'trajectory'; vib.hidden = s !== 'vibration'; spin.hidden = s !== 'spin';
    ditherRow.hidden = st.format !== 'gif';
  }
  srcSel.addEventListener('change', upd);
  (async () => {
    sources = await animationSources(app, d);
    clear(srcSel).append(...sources.map((s) => h('option', { value: s.id }, s.label)));
    const want = initial.source || (sources.find((s) => s.id === 'trajectory') ? 'trajectory' : sources.find((s) => s.id === 'vibration') ? 'vibration' : 'spin');
    if (sources.some((s) => s.id === want)) srcSel.value = want;
    upd();
    if (sources.some((s) => s.id === 'vibration')) {
      try {
        const r = await loadModes(d);
        const cur = initial.mode ?? d.cache.vib?.mode ?? r.modes.find((m) => m.frequency < 0)?.index ?? r.modes[r.modes.length - 1]?.index;
        clear(modeSel).append(...r.modes.map((m) => h('option', { value: m.index, selected: m.index === cur },
          `${m.index + 1}: ${m.frequency < 0 ? Math.abs(m.frequency).toFixed(1) + 'i' : m.frequency.toFixed(1)} cm⁻¹${m.symmetry ? ' ' + m.symmetry : ''}${m.label && !/cm/.test(m.label) ? ' – ' + m.label : ''}`)));
      } catch (e) { clear(modeSel).append(h('option', {}, e.message)); }
    }
  })();
  let running = null;
  ctx.onClose = () => { if (running) running.cancel = true; };
  ctx.run = async () => {
    if (running) { running.cancel = true; return; }
    st.width = Number(wIn.value) || 800; st.height = Number(hIn.value) || 600; app.saveSettingsSoon();
    const ext = st.format === 'gif' ? 'gif' : st.format;
    const src = srcSel.value;
    const suffix = src === 'vibration' ? `-mode${Number(modeSel.value) + 1}` : src === 'spin' ? '-spin' : '-trajectory';
    const p = await api.saveFileDialog({ title: 'Export Animation', defaultPath: `${baseName(d)}${suffix}.${ext}`, filters: [{ name: `${ext.toUpperCase()} animation`, extensions: [ext] }] });
    if (!p) return;
    running = { cancel: false };
    progRow.hidden = false; ctx.setRunLabel('Cancel');
    for (const el of pane.querySelectorAll('input, select, button')) el.disabled = true;
    const t0 = performance.now();
    try {
      const r = await renderAnimation(app, d, { ...st, source: src, mode: Number(modeSel.value) }, {
        onProgress: (t, f) => { progText.textContent = t; progress.value = f; },
        cancelled: () => running.cancel,
      });
      await api.writeFileBase64(p, bytesToB64(r.bytes));
      savedToast(p, ` (${r.frames} frames, ${r.width}×${r.height}, ${(r.bytes.length / 1024).toFixed(0)} KB, ${((performance.now() - t0) / 1000).toFixed(1)} s)`);
      ctx.close();
    } catch (e) {
      if (e.message === 'cancelled') { progText.textContent = 'Cancelled'; } else { progText.textContent = e.message; app.error('Animation export failed', e); }
    } finally {
      running = null; ctx.setRunLabel('Export…');
      for (const el of pane.querySelectorAll('input, select, button')) el.disabled = false;
    }
  };
  ctx.runLabel = 'Export…';
  return pane;
}

// ---------------------------------------------------------------------------------------------------------
// Data (CSV)
// ---------------------------------------------------------------------------------------------------------

const csvCell = (v) => { if (v == null) return ''; const s = String(v); return /[",\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s; };
const csvRows = (rows) => rows.map((r) => r.map(csvCell).join(',')).join('\n') + '\n';

function spectrumCSV(s) {
  const x = decodeF32(s.xB64), y = decodeF32(s.yB64);
  const occ = s.occupiedYB64 ? decodeF32(s.occupiedYB64) : null;
  const rows = [[s.xLabel, s.yLabel, ...(occ ? ['occupied'] : [])]];
  for (let i = 0; i < x.length; i++) rows.push([x[i], y[i], ...(occ ? [occ[i]] : [])]);
  let out = csvRows(rows);
  if (s.sticks?.length) out += '\n' + csvRows([['stick x', 'height', 'label', 'source index'], ...s.sticks.map((k) => [k.x, k.height, k.label || '', k.sourceIndex])]);
  return out;
}

/** CSV tables available for a document: [{id, label, make: async () => csv}]. */
export function dataTables(app, d) {
  const s = d.summary; const out = [];
  const result = async () => d.cache.result || (d.cache.result = await request('doc.result', { docId: d.docId }));
  if ((s.frameCount || 1) > 1 || s.hasResult) {
    out.push({ id: 'energies', label: 'Energies per frame / step', make: async () => {
      const f = await request('doc.frames', { docId: d.docId });
      const e = f.energies || []; if (!e.length) throw new Error('No energies in this document');
      return csvRows([['step', 'energy (Eh)', 'relative (kcal/mol)'], ...e.map((x, i) => [i + 1, x.toFixed(10), ((x - e[0]) * KCAL).toFixed(4)])]);
    } });
  }
  if (s.modeCount > 0) {
    out.push({ id: 'modes', label: 'Vibrational modes', make: async () => {
      const r = await loadModes(d);
      return csvRows([['mode', 'frequency (cm-1)', 'IR intensity (km/mol)', 'Raman activity', 'symmetry', 'reduced mass', 'force constant', 'description'],
        ...r.modes.map((m) => [m.index + 1, m.frequency, m.irIntensity, m.ramanActivity, m.symmetry, m.reducedMass, m.forceConstant, m.label])]);
    } });
    out.push({ id: 'ir', label: 'IR spectrum (broadened, 10 cm⁻¹ FWHM)', make: async () => spectrumCSV(await request('analysis.spectrum', { docId: d.docId, kind: 'ir', fwhm: 10 })) });
    out.push({ id: 'raman', label: 'Raman spectrum', make: async () => spectrumCSV(await request('analysis.spectrum', { docId: d.docId, kind: 'raman', fwhm: 10 })) });
    out.push({ id: 'thermo', label: 'Thermochemistry (298.15 K, 1 atm)', make: async () => {
      const t = await request('analysis.thermo', { docId: d.docId });
      return csvRows([['quantity', 'Hartree', 'kcal/mol'], ...t.rows.map((r) => [r.label, r.hartree, r.kcal])]);
    } });
  }
  if (s.excitedStateCount > 0) {
    out.push({ id: 'uvvis', label: 'UV-Vis spectrum', make: async () => spectrumCSV(await request('analysis.spectrum', { docId: d.docId, kind: 'uvvis' })) });
    out.push({ id: 'states', label: 'Excited states', make: async () => {
      const r = await result();
      return csvRows([['state', 'energy (eV)', 'wavelength (nm)', 'oscillator strength', 'multiplicity', 'symmetry'], ...(r.excitedStates || []).map((x) => [x.index, x.energyEV, x.wavelengthNM, x.oscillatorStrength, x.multiplicity, x.symmetry])]);
    } });
  }
  if (s.orbitalCount > 0) {
    out.push({ id: 'orbitals', label: 'Orbital energies', make: async () => {
      const r = await request('analysis.orbitals', { docId: d.docId });
      const rows = [['spin', 'orbital', 'energy (Eh)', 'energy (eV)', 'occupation', 'label']];
      for (const c of r.columns) for (const l of c.levels) for (const i of l.orbitalIndices) rows.push([c.spin, i + 1, l.energy, l.energyEV, l.occupation, l.label || (l.isHOMO ? 'HOMO' : l.isLUMO ? 'LUMO' : '')]);
      return csvRows(rows);
    } });
    if (s.hasWavefunction || s.orbitalCount > 0) out.push({ id: 'dos', label: 'Density of states', make: async () => spectrumCSV(await request('analysis.spectrum', { docId: d.docId, kind: 'dos' })) });
  }
  if (s.hasResult) {
    out.push({ id: 'charges', label: 'Atomic charges', make: async () => {
      const r = await result();
      const schemes = Object.keys(r.charges || {}); if (!schemes.length) throw new Error('No atomic charges in this document');
      const spins = Object.keys(r.spinDensities || {});
      return csvRows([['atom', 'element', ...schemes, ...spins.map((k) => `${k} spin`)],
        ...d.molecule.atoms.map((a, i) => [i + 1, a.symbol, ...schemes.map((k) => r.charges[k][i]), ...spins.map((k) => r.spinDensities[k][i])])]);
    } });
    out.push({ id: 'summary', label: 'Result summary', make: async () => {
      const r = await result();
      return csvRows([['property', 'value'], ...(r.info?.rows || []).map((x) => [x.label, x.value])]);
    } });
  }
  out.push({ id: 'coordinates', label: 'Cartesian coordinates', make: async () =>
    csvRows([['atom', 'element', 'x (Å)', 'y (Å)', 'z (Å)'], ...d.molecule.atoms.map((a, i) => [i + 1, a.symbol, ...a.pos.map((v) => v.toFixed(6))])]) });
  return out;
}

function buildDataPane(app, d, ctx) {
  const tables = dataTables(app, d);
  let chosen = tables[0]?.id;
  const preview = h('textarea', { readOnly: true, spellcheck: false, style: { width: '100%', height: '210px', fontFamily: 'Consolas, monospace', fontSize: '11.5px', whiteSpace: 'pre' } });
  const list = h('div', { style: { display: 'flex', flexDirection: 'column', gap: '4px' } }, tables.map((t) => {
    const r = h('input', { type: 'radio', name: 'export-data', checked: t.id === chosen, onchange: () => { chosen = t.id; show(); } });
    return h('label.check', {}, r, t.label);
  }));
  async function show() {
    const t = tables.find((x) => x.id === chosen); if (!t) return;
    try { const csv = await t.make(); const l = csv.split('\n'); preview.value = l.slice(0, 40).join('\n') + (l.length > 40 ? `\n… (${l.length} lines)` : ''); } catch (e) { preview.value = e.message; }
  }
  show();
  ctx.run = async () => {
    const t = tables.find((x) => x.id === chosen); if (!t) return;
    try {
      const csv = await t.make();
      const p = await api.saveFileDialog({ title: `Export ${t.label}`, defaultPath: `${baseName(d)}-${t.id}.csv`, filters: [{ name: 'CSV', extensions: ['csv'] }] });
      if (!p) return;
      await api.writeTextFile(p, csv);
      savedToast(p); ctx.close();
    } catch (e) { app.error('Export failed', e); }
  };
  ctx.runLabel = 'Export…';
  return h('div.export-pane', {}, list, h('div', { style: { fontSize: '12px', color: 'var(--text-2)', margin: '8px 0 2px' } }, 'Preview'), preview);
}

// ---------------------------------------------------------------------------------------------------------
// Dialog
// ---------------------------------------------------------------------------------------------------------

/** File > Export…  tab: 'structure' | 'image' | 'animation' | 'data'; arg: {source, mode} for animations. */
export function openExport(app, tab = 'structure', arg = {}) {
  const d = app.active;
  if (!d || !d.molecule?.atoms?.length) { toast('Nothing to export: the document is empty', { kind: 'warn' }); return; }
  const body = h('div', { style: { minHeight: '330px' } });
  const runBtn = h('button.btn.primary', { onclick: () => ctx.run && ctx.run() }, 'Export…');
  const ctx = {
    run: null, runLabel: 'Export…', onClose: null,
    close: () => dlg.close(),
    setRunLabel: (t) => { runBtn.textContent = t; },
  };
  const panes = { structure: buildStructurePane, image: buildImagePane, animation: buildAnimationPane, data: buildDataPane };
  const show = (t) => {
    if (ctx.onClose) ctx.onClose();
    ctx.run = null; ctx.onClose = null;
    clear(body).append(panes[t](app, d, ctx, arg));
    runBtn.textContent = ctx.runLabel;
  };
  const tabs = segmented([{ value: 'structure', label: 'Structure file' }, { value: 'image', label: 'Image' }, { value: 'animation', label: 'Animation (GIF)' }, { value: 'data', label: 'Data (CSV)' }], tab, show);
  const dlg = modal(`Export – ${d.name}`, h('div', {}, h('div', { style: { marginBottom: '10px' } }, tabs), body), {
    width: 640,
    onClose: () => ctx.onClose && ctx.onClose(),
    footer: [h('button.btn', { onclick: () => dlg.close() }, 'Close'), runBtn],
  });
  show(tab);
  return dlg;
}

// ---------------------------------------------------------------------------------------------------------
// Headless check (npm run smoke with VIBEVIEW_SMOKE_EXPORT=1): exports every applicable format of every open
// document into the screenshot folder, re-opens the structure files in the engine and logs the results.
// ---------------------------------------------------------------------------------------------------------
export async function runSmokeExports(app, spec, log) {
  const want = new Set(String(spec || 'all').split(/[,; ]+/).filter(Boolean));
  const all = want.has('all') || want.has('1');
  const write = (name, b64) => api.smokeWriteFile(name, b64);
  const enc = (t) => btoa(unescape(encodeURIComponent(t)));
  const results = [];
  for (const d of [...app.docs]) {
    if (!d.molecule?.atoms?.length) continue;
    app.activate(d, { fit: true });
    await sleep(400);
    const base = baseName(d).replace(/[^\w.-]+/g, '_');
    if (all || want.has('struct')) {
      const formats = await structureFormats(app, d);
      for (const f of formats.filter((x) => x.available !== false)) {
        const frames = f.multiFrame && d.summary.frameCount > 1 ? 'all' : 'current';
        try {
          const r = await exportStructureText(d, { format: f.id, frames, energies: true });
          const p = await write(`export-${base}-${f.id}.${f.extensions[0]}`, enc(r.text));
          let back = '';
          try {
            const s = await request('doc.open', { path: p, companions: false });
            back = `re-opened ${s.format}: ${s.atomCount} atoms, ${s.frameCount} frames`;
            await request('doc.close', { docId: s.docId });
          } catch (e) { back = `re-open failed: ${e.message}`; }
          log(`export ${f.id}: ${r.frameCount} frames, ${r.text.length} chars -> ${shortPath(p)}; ${back}`);
          results.push(!/failed/.test(back) && (frames === 'current' || /, (\d+) frames/.exec(back)?.[1] == r.frameCount));
        } catch (e) { log(`export ${f.id}: FAILED ${e.message}`); results.push(false); }
      }
    }
    if (all || want.has('image')) {
      for (const format of ['png', 'jpeg']) {
        const b64 = await renderImage(app.viewport, { width: 640, height: 480, format, transparent: format === 'png' });
        const p = await write(`export-${base}.${format === 'png' ? 'png' : 'jpg'}`, b64);
        log(`image ${format}: ${Math.round(b64.length * 0.75 / 1024)} KB -> ${shortPath(p)}`);
      }
    }
    if (all || want.has('csv')) {
      for (const t of dataTables(app, d)) {
        try { const csv = await t.make(); const p = await write(`export-${base}-${t.id}.csv`, enc(csv)); log(`csv ${t.id}: ${csv.split('\n').length} lines -> ${shortPath(p)}`); } catch (e) { log(`csv ${t.id}: ${e.message}`); }
      }
    }
    const anims = [];
    if (all || want.has('gif')) {
      for (const s of await animationSources(app, d)) {
        if (s.id === 'spin' && (d.summary.frameCount > 1 || d.summary.modeCount > 0)) continue;
        anims.push({ source: s.id, format: 'gif' });
      }
    }
    if (want.has('webm') && videoMime('webm')) anims.push({ source: d.summary.frameCount > 1 ? 'trajectory' : 'spin', format: 'webm' });
    for (const a of anims) {
      const t0 = performance.now();
      try {
        const opts = { width: 800, height: 600, fps: 12, loop: true, caption: true, profile: true, dither: false, cycleFrames: 20, cycles: 1, amplitude: 0.5, spinFrames: 36, spinAxis: 'y', step: 1, holdLast: 1, ...a };
        if (a.source === 'vibration') { const r = await loadModes(d); opts.mode = r.modes[r.modes.length - 1].index; opts.arrows = true; }
        const r = await renderAnimation(app, d, opts, {});
        const p = await write(`export-${base}-${a.source}.${a.format}`, bytesToB64(r.bytes));
        log(`${a.format} ${a.source}: ${r.frames} frames ${r.width}x${r.height}, ${(r.bytes.length / 1024).toFixed(0)} KB in ${((performance.now() - t0) / 1000).toFixed(1)} s -> ${p}`);
        results.push(true);
      } catch (e) { log(`${a.format} ${a.source}: FAILED ${e.stack || e.message}`); results.push(false); }
    }
  }
  // "dialog=<tab>" leaves File > Export open on that tab for the window screenshot.
  const dlgTab = [...want].find((w) => w.startsWith('dialog='))?.slice(7);
  if (dlgTab) { openExport(app, dlgTab); await sleep(1200); }
  return { ok: results.every(Boolean), count: results.length };
}
