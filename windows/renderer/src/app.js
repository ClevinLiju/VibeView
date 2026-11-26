// Application state, documents, tools and viewport interaction.
import * as THREE from 'three';
import { api, engine, request } from './api.js';
import { Viewport, DEFAULT_OPTIONS } from './viewport.js';
import { element, elementBySymbol } from './elements.js';
import { h, $, toast } from './dom.js';

const BOND_NAMES = { 1: 'single', 1.5: 'aromatic', 2: 'double', 3: 'triple' };

export class App {
  constructor() {
    this.docs = [];
    this.active = null;
    this.tool = 'select';
    this.payload = { kind: 'element', z: 6 };
    this.bondOrder = 1;
    this.fragments = [];
    this.engineInfo = null;
    this.listeners = {};
    this.settings = {
      view: { ...DEFAULT_OPTIONS },
      orbitalLook: { occupied: { positive: '#d8343a', negative: '#2f66d6' }, virtual: { positive: '#3aa860', negative: '#e3b52a' }, mode: 'transparent', opacity: 0.62, quality: 'normal', isovalue: 0.02 },
      panels: { library: true, inspector: true, results: true, console: false },
      uiTheme: 'system',
      recentElements: [6, 1, 7, 8],
    };
    this.jobs = new Map(); // jobId -> {jobId, title, lines[], done, ok, directory}
  }

  on(name, fn) { (this.listeners[name] ||= []).push(fn); return () => { this.listeners[name] = this.listeners[name].filter((f) => f !== fn); }; }
  emit(name, ...a) { for (const f of this.listeners[name] || []) { try { f(...a); } catch (e) { console.error(e); } } }

  async init() {
    const appInfo = await api.appInfo();
    this.noPersist = appInfo.smoke; // smoke tests use defaults and leave the user's settings alone
    const saved = this.noPersist ? {} : await api.loadSettings().catch(() => ({}));
    if (saved && typeof saved === 'object') {
      if (saved.view) Object.assign(this.settings.view, saved.view);
      if (saved.orbitalLook) this.settings.orbitalLook = { ...this.settings.orbitalLook, ...saved.orbitalLook };
      if (saved.panels) Object.assign(this.settings.panels, saved.panels);
      if (saved.uiTheme) this.settings.uiTheme = saved.uiTheme;
      if (Array.isArray(saved.recentElements)) this.settings.recentElements = saved.recentElements;
      if (saved.programPaths && typeof saved.programPaths === 'object') this.settings.programPaths = { ...saved.programPaths };
    }
    this.viewport = new Viewport($('#viewport'), $('#overlay'));
    this.viewport.setOptions(this.settings.view);
    this.viewport.on('options', (o) => { this.settings.view = { ...o }; this.saveSettingsSoon(); this.emit('options', o); });
    this.installInteraction();
    this.on('selection', () => this.syncSelectionSoon());
    api.onEvent((name, params) => this.onEngineEvent(name, params));
    api.onEngineStatus((s) => this.onEngineStatus(s));
    api.onEngineRestarted(() => this.onEngineRestarted());
    const st = await api.engineStatus();
    this.onEngineStatus(st);
    await this.loadEngineInfo();
  }

  /** Program locations from Settings → engine (kept in memory there, so re-sent after every (re)start). */
  async sendProgramPaths() {
    const saved = this.settings.programPaths || {};
    let programs = null;
    for (const program of ['xtb', 'orca', 'gaussian', 'qchem']) {
      const p = typeof saved[program] === 'string' && saved[program].trim() ? saved[program].trim() : null;
      try { programs = await request('calc.setProgramPath', { program, path: p }); } catch (e) { if (p) toast(`${program} path not used: ${e.message}`, { kind: 'warn' }); }
    }
    if (programs && this.engineInfo) { this.engineInfo.programs = programs; this.emit('engine-info', this.engineInfo); }
    return programs;
  }

  /** Mirrors the viewport selection into the engine (the console's `sel`), debounced. */
  syncSelectionSoon() {
    clearTimeout(this._selT);
    this._selT = setTimeout(() => {
      const d = this.active; if (!d) return;
      const atoms = [...d.selection].filter((i) => i < d.molecule.atoms.length).sort((a, b) => a - b);
      const key = `${d.docId}:${atoms.join(',')}`;
      if (key === this._selKey) return;
      this._selKey = key;
      request('doc.setSelection', { docId: d.docId, atoms }).catch(() => { this._selKey = null; });
    }, 150);
  }

  async loadEngineInfo() {
    this._selKey = null; // a restarted engine has no selection
    if (this.settings.programPaths && Object.keys(this.settings.programPaths).length) await this.sendProgramPaths();
    try { this.engineInfo = await engine.info(); } catch (e) { this.engineInfo = null; }
    try { this.fragments = (await engine.fragments()).fragments || []; } catch { this.fragments = []; }
    this.emit('engine-info', this.engineInfo);
    this.emit('fragments', this.fragments);
  }

  onEngineStatus(s) {
    this.engineStatus = s;
    this.emit('engine-status', s);
    if (s.state === 'restarting' || s.state === 'failed' || s.state === 'missing') toast(s.message, { kind: s.state === 'restarting' ? 'warn' : 'error', timeout: s.state === 'restarting' ? 9000 : 0 });
  }

  async onEngineRestarted() {
    // The engine lost its documents: reopen files from disk, recreate unsaved ones from the last molecule we have.
    await this.loadEngineInfo();
    for (const d of this.docs) {
      try {
        let s;
        if (d.path && !d.dirty) s = await engine.open(d.path);
        else { s = await engine.newDoc(); if (d.molecule?.atoms.length) s = (await engine.edit(s.docId, { type: 'replaceMolecule', molecule: d.molecule })).summary; }
        d.docId = s.docId; d.summary = s; d.cache = {};
      } catch (e) { toast(`Could not restore ${d.name}: ${e.message}`, { kind: 'error' }); }
    }
    if (this.active) this.activate(this.active, { fit: false });
  }

  saveSettingsSoon() {
    if (this.noPersist) return;
    clearTimeout(this._saveT);
    this._saveT = setTimeout(() => api.saveSettings(this.settings), 400);
  }

  // ---------- documents ----------
  makeDoc(summary, molecule, path = null) {
    const d = {
      docId: summary.docId, summary, molecule, path: path || summary.path || null,
      name: path ? path.split(/[\\/]/).pop() : (summary.title || 'Untitled'),
      selection: new Set(), measurements: [], dirty: false, cache: {}, frame: null, surfaces: [],
    };
    this.docs.push(d);
    return d;
  }

  async newDocument() {
    try {
      const s = await engine.newDoc();
      const m = await engine.molecule(s.docId);
      const d = this.makeDoc(s, m);
      d.name = `Untitled ${this.docs.filter((x) => !x.path).length}`;
      this.activate(d, { fit: true });
    } catch (e) { this.error('Could not create a document', e); }
  }

  async openPath(path) {
    const existing = this.docs.find((d) => d.path && d.path.toLowerCase() === path.toLowerCase());
    if (existing) { this.activate(existing); return existing; }
    if (/\.vibeview$/i.test(path)) return this.loadSession(path);
    this.setBusy(`Opening ${path.split(/[\\/]/).pop()}…`);
    try {
      const s = await engine.open(path);
      const m = await engine.molecule(s.docId);
      // Replace an empty untitled document instead of piling up tabs.
      const blank = this.active && !this.active.path && !this.active.dirty && !this.active.molecule.atoms.length ? this.active : null;
      const d = this.makeDoc(s, m, path);
      if (blank) this.closeDoc(blank, { force: true, silent: true });
      this.activate(d, { fit: true, orient: true });
      api.addRecentFile(path);
      const unused = (s.companions || []).filter((c) => c.used);
      if (unused.length) this.status(`Loaded with ${unused.map((c) => c.fileName).join(', ')}`);
      return d;
    } catch (e) {
      this.error(`Could not open ${path.split(/[\\/]/).pop()}`, e);
      return null;
    } finally { this.setBusy(null); }
  }

  async openDialog() {
    const paths = await api.openFileDialog({ title: 'Open', defaultPath: this.active?.path || undefined });
    if (paths) for (const p of paths) await this.openPath(p);
  }

  activate(d, { fit = false, orient = false } = {}) {
    const vp = this.viewport;
    // Per-document camera: remember the outgoing document's view and restore the incoming one's.
    if (this.active && this.docs.includes(this.active) && this.active.molecule?.atoms.length) this.active.camera = vp.getCameraState();
    const restoreCamera = !fit && !orient && d.camera ? d.camera : null;
    this.active = d;
    vp.stopVibration();
    vp.showArrows(null);
    vp.clearSurfaces();
    vp.setMolecule(d.molecule, { fit: (fit && !orient) || (!orient && !restoreCamera && !d.camera) });
    if (orient) vp.orientToPrincipalAxes();
    else if (restoreCamera) vp.setCameraState(restoreCamera);
    vp.setSelection(d.selection);
    vp.setMeasurements(d.measurements);
    for (const s of d.surfaces) vp.addSurfaces(s.meshes, s.look, s.tag);
    this.pending = [];
    vp.setPendingPicks([]);
    this.updateTitle();
    this.emit('docs', this.docs, d);
    this.emit('doc', d);
    this.emit('molecule', d.molecule);
    this.emit('selection', d.selection);
  }

  async closeDoc(d = this.active, { force = false, silent = false } = {}) {
    if (!d) return true;
    if (d.dirty && !force) {
      const r = await api.messageBox({ type: 'question', message: `Save changes to ${d.name}?`, detail: 'Your changes will be lost if you don\'t save them.', buttons: ['Save', 'Don\'t Save', 'Cancel'], defaultId: 0, cancelId: 2 });
      if (r === 2) return false;
      if (r === 0 && !(await this.save(d))) return false;
    }
    this.docs = this.docs.filter((x) => x !== d);
    engine.close(d.docId).catch(() => {});
    if (this.active === d) {
      this.active = null;
      if (this.docs.length) this.activate(this.docs[this.docs.length - 1]);
      else if (!silent) await this.newDocument();
    }
    this.emit('docs', this.docs, this.active);
    return true;
  }

  async quitRequest() {
    for (const d of [...this.docs]) {
      if (d.dirty) { this.activate(d); if (!(await this.closeDoc(d))) return; }
    }
    api.closeWindow();
  }

  updateTitle() {
    const d = this.active;
    const name = d ? d.name : 'VibeView';
    const sub = d && d.molecule.atoms.length ? ` — ${d.summary.formula}, ${d.molecule.atoms.length} atoms` : '';
    api.setTitle(`${d?.dirty ? '• ' : ''}${name}${sub} — VibeView`);
  }

  async save(d = this.active, { as = false } = {}) {
    if (!d) return false;
    let path = d.path;
    const writable = !path || /\.(log|out|fchk|fch|cube|cub|molden|hess)$/i.test(path);
    if (as || writable) {
      const base = (d.path ? d.path.replace(/\.[^.\\/]+$/, '') : (d.summary.title || 'molecule')) + '.xyz';
      path = await api.saveFileDialog({
        title: 'Save As', defaultPath: base,
        filters: [
          { name: 'XYZ', extensions: ['xyz'] }, { name: 'MDL Molfile', extensions: ['mol'] }, { name: 'SDF', extensions: ['sdf'] },
          { name: 'PDB', extensions: ['pdb'] }, { name: 'CML', extensions: ['cml'] }, { name: 'Gaussian input', extensions: ['gjf', 'com'] },
          { name: 'VibeView session', extensions: ['vibeview'] },
        ],
      });
      if (!path) return false;
    }
    try {
      if (/\.vibeview$/i.test(path)) return this.saveSession(path);
      const r = await engine.save(d.docId, path, null);
      d.path = r.path || path; d.name = d.path.split(/[\\/]/).pop(); d.dirty = false;
      api.addRecentFile(d.path);
      this.updateTitle(); this.emit('docs', this.docs, this.active);
      this.status(`Saved ${d.name}`);
      return true;
    } catch (e) { this.error('Could not save', e); return false; }
  }

  async saveSession(path) {
    if (!path) path = await api.saveFileDialog({ title: 'Save Session', defaultPath: 'session.vibeview', filters: [{ name: 'VibeView session', extensions: ['vibeview'] }] });
    if (!path) return false;
    try {
      const views = {};
      const { colorScheme, uniformColor, background, ...renderOptions } = this.settings.view;
      for (const d of this.docs) {
        views[d.docId] = { renderOptions, monitors: d.measurements.map((m) => ({ atoms: m.atoms, kind: m.kind })), frameIndex: d.frame };
      }
      await request('session.save', { path, docs: this.docs.map((d) => d.docId), views });
      api.addRecentFile(path);
      this.status('Session saved');
      return true;
    } catch (e) { this.error('Could not save the session', e); return false; }
  }

  async loadSession(path) {
    try {
      const r = await request('session.load', { path });
      const list = r.docs || [];
      let last = null; let ro = null;
      for (const e of list) {
        const sum = e.summary || e;
        if (!sum?.docId) continue;
        const m = await engine.molecule(sum.docId);
        last = this.makeDoc(sum, m, sum.path);
        const mons = Array.isArray(e.view?.monitors) ? e.view.monitors : [];
        for (const mon of mons) {
          const atoms = Array.isArray(mon) ? mon : mon?.atoms;
          if (Array.isArray(atoms) && atoms.length >= 2 && atoms.length <= 4 && atoms.every((i) => Number.isInteger(i) && i >= 0 && i < m.atoms.length)) {
            last.measurements.push({ atoms, ...this.measureValue(m, atoms) });
          }
        }
        if (!ro && e.view?.renderOptions && typeof e.view.renderOptions === 'object') ro = e.view.renderOptions;
      }
      if (ro) {
        // Only take known, primitive options (also accepts the macOS RenderOptions keys that match).
        const patch = {};
        for (const [k, v] of Object.entries(ro)) if (k in DEFAULT_OPTIONS && k !== 'colorScheme' && typeof v === typeof DEFAULT_OPTIONS[k]) patch[k] = v;
        this.viewport.setOptions(patch);
      }
      if (last) this.activate(last, { fit: true });
      api.addRecentFile(path);
      return last;
    } catch (e) { this.error('Could not open the session', e); return null; }
  }

  // ---------- editing ----------
  async edit(op, { keepSelection = false, message } = {}) {
    const d = this.active; if (!d) return null;
    try {
      const r = await engine.edit(d.docId, op);
      this.applyMolecule(d, r.molecule, r.summary, { keepSelection });
      d.dirty = true; this.updateTitle();
      if (message) this.status(message);
      return r;
    } catch (e) {
      if (d === this.active) this.viewport.setMolecule(d.molecule, { keepSelection: true });
      this.error('Edit failed', e); return null;
    }
  }

  applyMolecule(d, molecule, summary, { keepSelection = false, fit = false } = {}) {
    d.molecule = molecule;
    if (summary) d.summary = summary;
    d.cache = {};
    d.frame = null;
    if (!keepSelection) d.selection = new Set();
    else d.selection = new Set([...d.selection].filter((i) => i < molecule.atoms.length));
    d.measurements = d.measurements.filter((m) => m.atoms.every((i) => i < molecule.atoms.length));
    this.recomputeMeasurements(d);
    if (d === this.active) {
      const hadAtoms = this.viewport.positions.length > 0;
      this.viewport.setMolecule(molecule, { fit: fit || (!hadAtoms && molecule.atoms.length > 0), keepSelection: true });
      this.viewport.setSelection(d.selection);
      this.viewport.setMeasurements(d.measurements);
      this.emit('molecule', molecule);
      this.emit('doc', d);
      this.emit('selection', d.selection);
    }
  }

  async undo() {
    const d = this.active; if (!d || !d.summary.canUndo) return;
    try { const r = await engine.undo(d.docId); this.applyMolecule(d, r.molecule, r.summary, { keepSelection: true }); d.dirty = true; this.updateTitle(); } catch (e) { this.error('Undo failed', e); }
  }
  async redo() {
    const d = this.active; if (!d || !d.summary.canRedo) return;
    try { const r = await engine.redo(d.docId); this.applyMolecule(d, r.molecule, r.summary, { keepSelection: true }); d.dirty = true; this.updateTitle(); } catch (e) { this.error('Redo failed', e); }
  }

  deleteSelection() {
    const d = this.active; if (!d || !d.selection.size) return;
    const atoms = [...d.selection].sort((a, b) => a - b);
    this.edit({ type: 'deleteAtoms', atoms }, { message: `Deleted ${atoms.length} atom${atoms.length > 1 ? 's' : ''}` });
  }

  setSelection(set) {
    const d = this.active; if (!d) return;
    d.selection = new Set(set);
    this.viewport.setSelection(d.selection);
    this.emit('selection', d.selection);
  }
  selectAll() { if (this.active) this.setSelection(this.active.molecule.atoms.map((_, i) => i)); }
  selectNone() { this.setSelection([]); }
  selectInvert() { const d = this.active; if (d) this.setSelection(d.molecule.atoms.map((_, i) => i).filter((i) => !d.selection.has(i))); }
  fragmentOf(i) {
    const m = this.active.molecule; const adj = m.atoms.map(() => []);
    for (const b of m.bonds) { adj[b.a].push(b.b); adj[b.b].push(b.a); }
    const seen = new Set([i]); const stack = [i];
    while (stack.length) { const x = stack.pop(); for (const y of adj[x]) if (!seen.has(y)) { seen.add(y); stack.push(y); } }
    return seen;
  }

  // ---------- measurements ----------
  measureValue(mol, atoms) {
    const P = atoms.map((i) => mol.atoms[i].pos);
    const sub = (a, b) => [a[0] - b[0], a[1] - b[1], a[2] - b[2]];
    const dot = (a, b) => a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
    const cross = (a, b) => [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]];
    const len = (a) => Math.hypot(a[0], a[1], a[2]);
    if (P.length === 2) return { kind: 'distance', value: len(sub(P[1], P[0])) };
    if (P.length === 3) { const u = sub(P[0], P[1]), v = sub(P[2], P[1]); return { kind: 'angle', value: Math.acos(Math.max(-1, Math.min(1, dot(u, v) / (len(u) * len(v) || 1)))) * 180 / Math.PI }; }
    const b1 = sub(P[1], P[0]), b2 = sub(P[2], P[1]), b3 = sub(P[3], P[2]);
    const n1 = cross(b1, b2), n2 = cross(b2, b3); const l2 = len(b2) || 1;
    const m1 = cross(n1, [b2[0] / l2, b2[1] / l2, b2[2] / l2]);
    return { kind: 'dihedral', value: Math.atan2(dot(m1, n2), dot(n1, n2)) * 180 / Math.PI };
  }
  recomputeMeasurements(d) {
    for (const m of d.measurements) Object.assign(m, this.measureValue(d.molecule, m.atoms));
  }
  addMeasurement(atoms) {
    const d = this.active; if (!d) return;
    const key = atoms.join('-'), rkey = [...atoms].reverse().join('-');
    if (d.measurements.some((m) => m.atoms.join('-') === key || m.atoms.join('-') === rkey)) return;
    d.measurements.push({ atoms: [...atoms], ...this.measureValue(d.molecule, atoms) });
    this.viewport.setMeasurements(d.measurements);
    this.emit('measurements', d.measurements);
  }
  removeMeasurement(idx) {
    const d = this.active; if (!d) return;
    d.measurements.splice(idx, 1);
    this.viewport.setMeasurements(d.measurements);
    this.emit('measurements', d.measurements);
  }
  async setMeasurementValue(m, value) {
    const type = { distance: 'setDistance', angle: 'setAngle', dihedral: 'setDihedral' }[m.kind];
    await this.edit({ type, atoms: m.atoms, value }, { keepSelection: true });
    this.emit('measurements', this.active?.measurements || []);
  }

  // ---------- tools ----------
  setTool(t) {
    this.tool = t;
    this.pending = []; this.viewport.setPendingPicks([]);
    $('#viewport').dataset.tool = t;
    this.emit('tool', t);
  }
  setPayload(p) {
    this.payload = p;
    if (p.kind === 'element') {
      this.settings.recentElements = [p.z, ...this.settings.recentElements.filter((z) => z !== p.z)].slice(0, 8);
      this.saveSettingsSoon();
    }
    if (this.tool !== 'place') this.setTool('place');
    this.emit('payload', p);
  }

  async placeAt(x, y, pick, { grow = false } = {}) {
    const vp = this.viewport; const d = this.active; if (!d) return;
    const p = this.payload;
    if (p.kind === 'fragment') {
      const at = pick?.kind === 'atom' ? pick.index : null;
      const pos = at == null ? vp.unprojectOnTargetPlane(x, y).toArray() : null;
      await this.edit({ type: 'placeFragment', fragmentId: p.id, at, pos }, { message: `Placed ${p.name || p.id}` });
      return;
    }
    if (p.kind === 'group' && pick?.kind !== 'bond' && !(grow && pick?.kind === 'atom')) {
      // Element group from the periodic-table picker (engine MolBuild GroupLibrary): replace an H / attach / place.
      const at = pick?.kind === 'atom' ? pick.index : null;
      const pos = at == null ? vp.unprojectOnTargetPlane(x, y).toArray() : null;
      await this.edit({ type: 'placeGroup', groupId: p.id, at, pos }, { message: `Placed ${p.name || p.id}` });
      return;
    }
    if (pick?.kind === 'atom') {
      // MolBuild rules: an H is substituted, a heavy atom is replaced in place; Ctrl/Alt grows a bonded atom.
      if (grow) await this.edit({ type: 'growAtom', from: pick.index, z: p.z });
      else await this.edit({ type: 'placeElement', z: p.z, at: pick.index, pos: null });
      return;
    }
    if (pick?.kind === 'bond') { await this.cycleBond(pick.index); return; }
    const pos = vp.unprojectOnTargetPlane(x, y).toArray();
    await this.edit({ type: 'placeElement', z: p.z, at: null, pos });
  }

  async cycleBond(bi) {
    const b = this.active.molecule.bonds[bi]; if (!b) return;
    const next = b.order === 1 ? 2 : b.order === 2 ? 3 : 1;
    await this.edit({ type: 'setBondOrder', a: b.a, b: b.b, order: next }, { keepSelection: true, message: `Bond order ${BOND_NAMES[next]}` });
  }

  async onClick(x, y, e, pick) {
    const d = this.active; if (!d) return;
    switch (this.tool) {
      case 'select': {
        if (pick?.kind === 'atom') {
          const s = new Set(d.selection);
          if (e.ctrlKey) { s.has(pick.index) ? s.delete(pick.index) : s.add(pick.index); }
          else if (e.shiftKey) s.add(pick.index);
          else { s.clear(); s.add(pick.index); }
          this.setSelection(s);
        } else if (pick?.kind === 'bond') {
          const b = d.molecule.bonds[pick.index];
          const s = e.shiftKey || e.ctrlKey ? new Set(d.selection) : new Set();
          s.add(b.a); s.add(b.b); this.setSelection(s);
        } else if (!e.shiftKey && !e.ctrlKey) this.selectNone();
        break;
      }
      case 'place': await this.placeAt(x, y, pick, { grow: e.ctrlKey || e.altKey }); break;
      case 'link': {
        if (pick?.kind === 'bond') {
          const b = d.molecule.bonds[pick.index];
          if (e.ctrlKey || e.altKey) await this.edit({ type: 'deleteBond', a: b.a, b: b.b }, { message: 'Bond deleted' });
          else await this.cycleBond(pick.index);
          return;
        }
        if (pick?.kind !== 'atom') { this.pending = []; this.viewport.setPendingPicks([]); return; }
        if (!this.pending.length || this.pending[0] === pick.index) { this.pending = [pick.index]; this.viewport.setPendingPicks(this.pending); this.status('Now click the second atom'); return; }
        const [a] = this.pending; this.pending = []; this.viewport.setPendingPicks([]);
        await this.edit({ type: 'addBond', a, b: pick.index, order: this.bondOrder }, { message: `${BOND_NAMES[this.bondOrder]} bond added` });
        break;
      }
      case 'gauge': {
        if (pick?.kind === 'bond') { const b = d.molecule.bonds[pick.index]; this.addMeasurement([b.a, b.b]); return; }
        if (pick?.kind !== 'atom') { this.finishGauge(); return; }
        if (this.pending.includes(pick.index)) return;
        this.pending.push(pick.index);
        this.viewport.setPendingPicks(this.pending);
        if (this.pending.length >= 2) {
          const v = this.measureValue(d.molecule, this.pending);
          this.status(`${v.kind}: ${v.value.toFixed(v.kind === 'distance' ? 4 : 2)}${v.kind === 'distance' ? ' Å' : '°'} — click another atom to extend, empty space or Enter to keep`);
        } else this.status('Click more atoms: 2 for a distance, 3 for an angle, 4 for a dihedral');
        if (this.pending.length === 4) this.finishGauge();
        break;
      }
      case 'delete':
        if (pick?.kind === 'atom') await this.edit({ type: 'deleteAtoms', atoms: d.selection.has(pick.index) ? [...d.selection] : [pick.index] });
        else if (pick?.kind === 'bond') { const b = d.molecule.bonds[pick.index]; await this.edit({ type: 'deleteBond', a: b.a, b: b.b }); }
        break;
      default: break;
    }
  }

  finishGauge() {
    if (this.pending.length >= 2) this.addMeasurement(this.pending);
    this.pending = []; this.viewport.setPendingPicks([]);
  }

  // ---------- viewport interaction ----------
  installInteraction() {
    const vp = this.viewport;
    const el = vp.renderer.domElement;
    const tip = $('#tooltip');
    let drag = null;
    const pos = (e) => { const r = el.getBoundingClientRect(); return { x: e.clientX - r.left, y: e.clientY - r.top }; };
    el.addEventListener('contextmenu', (e) => e.preventDefault());
    el.addEventListener('pointerdown', (e) => {
      el.focus();
      const p = pos(e);
      const pick = vp.pick(p.x, p.y);
      drag = { x0: p.x, y0: p.y, x: p.x, y: p.y, button: e.button, pick, moved: false, mode: null, e };
      el.setPointerCapture(e.pointerId);
      tip.hidden = true;
    });
    el.addEventListener('pointermove', (e) => {
      const p = pos(e);
      if (!drag) { this.updateHover(p.x, p.y, e); return; }
      const dx = p.x - drag.x, dy = p.y - drag.y;
      if (!drag.moved && Math.hypot(p.x - drag.x0, p.y - drag.y0) > 4) {
        drag.moved = true;
        const d = this.active;
        if (drag.button === 2 || drag.button === 1) drag.mode = e.ctrlKey ? 'zoom' : 'pan';
        else if (this.tool === 'select' && drag.pick?.kind === 'atom' && d?.selection.has(drag.pick.index) && !e.shiftKey && !e.ctrlKey) {
          drag.mode = e.altKey ? 'rotateSel' : 'moveSel';
          drag.base = d.molecule.atoms.map((a) => a.pos.slice());
          drag.anchor = vp.unprojectOnTargetPlane(drag.x0, drag.y0, vp.positions[drag.pick.index]);
        } else if (this.tool === 'select' && (e.shiftKey || e.ctrlKey) && !drag.pick) drag.mode = 'box';
        else drag.mode = e.altKey ? 'roll' : 'rotate';
      }
      if (!drag.moved) return;
      if (drag.mode === 'rotate') vp.rotate(dx, dy);
      else if (drag.mode === 'roll') vp.roll(dx * 0.01);
      else if (drag.mode === 'pan') vp.pan(dx, dy);
      else if (drag.mode === 'zoom') vp.zoom(Math.exp(dy * 0.01));
      else if (drag.mode === 'box') { vp.boxRect = { x: Math.min(drag.x0, p.x), y: Math.min(drag.y0, p.y), w: Math.abs(p.x - drag.x0), h: Math.abs(p.y - drag.y0) }; vp.dirty = true; }
      else if (drag.mode === 'moveSel') {
        const now = vp.unprojectOnTargetPlane(p.x, p.y, vp.positions[drag.pick.index]);
        const delta = now.clone().sub(drag.anchor);
        drag.delta = delta.toArray();
        const sel = this.active.selection;
        vp.setDisplayedPositions(drag.base.map((q, i) => (sel.has(i) ? [q[0] + delta.x, q[1] + delta.y, q[2] + delta.z] : q)));
      } else if (drag.mode === 'rotateSel') {
        drag.angle = (drag.angle || 0) + dx * 0.01;
        const sel = [...this.active.selection];
        const c = sel.reduce((s, i) => s.map((v, k) => v + drag.base[i][k] / sel.length), [0, 0, 0]);
        const axis = vp.camera.getWorldDirection(new THREE.Vector3()).negate();
        drag.center = c; drag.axis = axis.toArray();
        const q = new THREE.Quaternion().setFromAxisAngle(axis, drag.angle);
        const selSet = this.active.selection;
        vp.setDisplayedPositions(drag.base.map((b, i) => {
          if (!selSet.has(i)) return b;
          const v = new THREE.Vector3(b[0] - c[0], b[1] - c[1], b[2] - c[2]).applyQuaternion(q);
          return [v.x + c[0], v.y + c[1], v.z + c[2]];
        }));
      }
      drag.x = p.x; drag.y = p.y;
    });
    const end = async (e) => {
      if (!drag) return;
      const dr = drag; drag = null;
      try { el.releasePointerCapture(e.pointerId); } catch { /* released */ }
      const p = pos(e);
      if (!dr.moved) {
        if (dr.button === 0) await this.onClick(p.x, p.y, e, dr.pick);
        else if (dr.button === 2) this.contextMenu(e, dr.pick);
        return;
      }
      if (dr.mode === 'box') {
        const ids = vp.atomsInRect(dr.x0, dr.y0, p.x, p.y);
        const s = new Set(e.ctrlKey && !e.shiftKey ? [] : this.active.selection);
        for (const i of ids) { if (e.ctrlKey && !e.shiftKey && this.active.selection.has(i)) continue; s.add(i); }
        if (e.ctrlKey && !e.shiftKey) for (const i of this.active.selection) if (!ids.includes(i)) s.add(i);
        vp.boxRect = null; vp.dirty = true;
        this.setSelection(s);
      } else if (dr.mode === 'moveSel' && dr.delta) {
        await this.edit({ type: 'moveAtoms', atoms: [...this.active.selection], delta: dr.delta }, { keepSelection: true });
      } else if (dr.mode === 'rotateSel' && dr.angle) {
        await this.edit({ type: 'rotateAtoms', atoms: [...this.active.selection], axisPoint: dr.center, axis: dr.axis, degrees: dr.angle * 180 / Math.PI }, { keepSelection: true });
      }
    };
    el.addEventListener('pointerup', end);
    el.addEventListener('pointercancel', end);
    el.addEventListener('pointerleave', () => { if (!drag) { vp.setHover(null); tip.hidden = true; } });
    el.addEventListener('wheel', (e) => { e.preventDefault(); vp.zoom(Math.exp(e.deltaY * 0.0012)); }, { passive: false });
    el.addEventListener('dblclick', (e) => {
      const p = pos(e); const pick = vp.pick(p.x, p.y);
      if (this.tool === 'select' && pick?.kind === 'atom') {
        const frag = this.fragmentOf(pick.index);
        const s = e.shiftKey || e.ctrlKey ? new Set([...this.active.selection, ...frag]) : frag;
        this.setSelection(s);
      } else if (!pick) vp.fit();
    });
    el.addEventListener('keydown', (e) => this.viewportKey(e));
  }

  updateHover(x, y) {
    const vp = this.viewport; const tip = $('#tooltip'); const d = this.active;
    const pick = vp.pick(x, y);
    vp.setHover(pick);
    if (!pick || !d) { tip.hidden = true; return; }
    const m = d.molecule;
    let html;
    if (pick.kind === 'atom') {
      const a = m.atoms[pick.index]; const el = element(a.z);
      const q = a.charge ? ` · q ${a.charge >= 0 ? '+' : ''}${Number(a.charge).toFixed(3)}` : '';
      const pos = vp.positions[pick.index];
      html = `<b>${a.symbol}${pick.index + 1}</b> ${el.name}${q}${a.label ? ` · ${escapeHTML(a.label)}` : ''}<br><span class="dim">${pos.x.toFixed(3)}, ${pos.y.toFixed(3)}, ${pos.z.toFixed(3)} Å</span>`;
    } else {
      const b = m.bonds[pick.index]; const A = m.atoms[b.a], B = m.atoms[b.b];
      const len = vp.positions[b.a].distanceTo(vp.positions[b.b]);
      html = `<b>${A.symbol}${b.a + 1}–${B.symbol}${b.b + 1}</b> ${len.toFixed(4)} Å<br><span class="dim">${BOND_NAMES[b.order] || 'order ' + b.order} bond</span>`;
    }
    tip.innerHTML = html;
    tip.hidden = false;
    const W = vp.width;
    tip.style.left = Math.min(x + 16, W - tip.offsetWidth - 8) + 'px';
    tip.style.top = Math.max(8, y - tip.offsetHeight - 10) + 'px';
  }

  viewportKey(e) {
    if (e.ctrlKey || e.metaKey) return;
    const vp = this.viewport;
    if (e.key === 'Delete' || e.key === 'Backspace') { e.preventDefault(); this.deleteSelection(); return; }
    if (e.key === 'Escape') { this.pending = []; vp.setPendingPicks([]); if (this.tool !== 'select') this.setTool('select'); else this.selectNone(); return; }
    if (e.key === 'Enter' && this.tool === 'gauge') { this.finishGauge(); return; }
    if (e.key === 'f' || e.key === 'F') { vp.fit(); return; }
    const step = e.shiftKey ? 0.4 : 0.1;
    const arrows = { ArrowLeft: [-20, 0], ArrowRight: [20, 0], ArrowUp: [0, -20], ArrowDown: [0, 20] };
    if (arrows[e.key]) { e.preventDefault(); vp.rotate(arrows[e.key][0] * step * 5, arrows[e.key][1] * step * 5); return; }
    if (e.key === '+' || e.key === '=') { vp.zoom(0.9); return; }
    if (e.key === '-') { vp.zoom(1.1); return; }
    if (['1', '2', '3'].includes(e.key) && this.tool === 'link') { this.bondOrder = Number(e.key); this.emit('tool', this.tool); return; }
    // Type an element symbol to pick it for the Place tool (e.g. C, N, O, Cl).
    if (/^[a-zA-Z]$/.test(e.key) && !e.altKey) {
      const now = performance.now();
      const buf = (this._symBuf && now - this._symT < 700) ? this._symBuf + e.key.toLowerCase() : e.key.toLowerCase();
      this._symBuf = buf; this._symT = now;
      const el = elementBySymbol(buf) || elementBySymbol(buf.slice(-1));
      if (el && el.z > 0 && this.tool === 'place') this.setPayload({ kind: 'element', z: el.z });
    }
  }

  contextMenu(e, pick) {
    const d = this.active; if (!d) return;
    const items = [];
    if (pick?.kind === 'atom') {
      const i = pick.index; const a = d.molecule.atoms[i];
      if (!d.selection.has(i)) this.setSelection([i]);
      items.push({ label: `${a.symbol}${i + 1}`, header: true });
      items.push({ label: 'Delete atom', run: () => this.edit({ type: 'deleteAtoms', atoms: d.selection.size ? [...d.selection] : [i] }) });
      if (this.payload.kind === 'element' && this.payload.z !== a.z) items.push({ label: `Change to ${element(this.payload.z).symbol}`, run: () => this.edit({ type: 'setElement', atom: i, z: this.payload.z }) });
      items.push({ label: `Grow ${element(this.payload.kind === 'element' ? this.payload.z : 6).symbol}`, run: () => this.edit({ type: 'growAtom', from: i, z: this.payload.kind === 'element' ? this.payload.z : 6 }) });
      items.push({ label: 'Select fragment', run: () => this.setSelection(this.fragmentOf(i)) });
      items.push({ label: 'Center view here', run: () => { this.viewport.target.copy(this.viewport.positions[i]); this.viewport.updateCamera(); } });
    } else if (pick?.kind === 'bond') {
      const b = d.molecule.bonds[pick.index];
      items.push({ label: `Bond ${b.a + 1}–${b.b + 1}`, header: true });
      for (const [o, n] of [[1, 'Single'], [2, 'Double'], [3, 'Triple'], [1.5, 'Aromatic']]) items.push({ label: n, checked: b.order === o, run: () => this.edit({ type: 'setBondOrder', a: b.a, b: b.b, order: o }) });
      items.push({ sep: true });
      items.push({ label: 'Measure length', run: () => this.addMeasurement([b.a, b.b]) });
      items.push({ label: 'Delete bond', run: () => this.edit({ type: 'deleteBond', a: b.a, b: b.b }) });
    } else {
      items.push({ label: 'Fit to window', run: () => this.viewport.fit() });
      items.push({ label: 'Select all', run: () => this.selectAll() });
      items.push({ label: 'Add hydrogens', run: () => this.command('build.addHydrogens') });
      items.push({ label: 'Clean up geometry', run: () => this.command('build.cleanUp') });
      items.push({ label: 'Export image…', run: () => this.command('file.exportImage') });
    }
    if (d.selection.size > 1 && pick?.kind === 'atom') {
      items.push({ sep: true });
      items.push({ label: `Delete ${d.selection.size} selected atoms`, run: () => this.deleteSelection() });
      if (d.selection.size >= 2 && d.selection.size <= 4) items.push({ label: 'Measure selected atoms', run: () => this.addMeasurement([...d.selection]) });
    }
    showContextMenu(e.clientX, e.clientY, items);
  }

  // ---------- engine events / jobs ----------
  onEngineEvent(name, params) {
    if (name === 'job.log') {
      const j = this.ensureJob(params.jobId);
      j.lines.push(params);
      if (j.lines.length > 20000) j.lines.splice(0, j.lines.length - 20000);
      this.emit('job-log', j, params);
    } else if (name === 'job.finished') {
      const j = this.ensureJob(params.jobId);
      j.done = true; j.ok = params.ok; j.exitCode = params.exitCode; j.error = params.error;
      this.emit('job', j);
      this.onJobFinished(j, params);
    } else if (name === 'engine.log') {
      if (params.level === 'error') console.warn('engine:', params.text);
    }
  }
  ensureJob(jobId, extra = {}) {
    if (!this.jobs.has(jobId)) this.jobs.set(jobId, { jobId, title: jobId, lines: [], done: false, ok: null, started: Date.now(), ...extra });
    const j = this.jobs.get(jobId); Object.assign(j, extra);
    return j;
  }
  /** Registers a job returned by xtb.run/calc.run/console and shows the busy pill, unless the job
   *  already finished (job.finished can arrive before the response that started it). */
  jobStarted(jobId, extra, label) {
    const j = this.ensureJob(jobId, extra);
    this.emit('jobs');
    if (j.done) { if (this.busyJob === jobId || !this.busyJob) this.setBusy(null); return j; }
    this.busyJob = jobId;
    this.setBusy(label);
    return j;
  }
  async onJobFinished(j, p) {
    if (!this.busyJob || this.busyJob === j.jobId || ![...this.jobs.values()].some((x) => !x.done)) { this.busyJob = null; this.setBusy(null); }
    if (!p.ok) { toast(`${j.title} failed${p.error ? ': ' + p.error : ''}`, { kind: 'error', timeout: 0, action: { label: 'Show log', run: () => this.command('calc.jobs', j.jobId) } }); return; }
    if (p.docId) {
      let d = this.docs.find((x) => x.docId === p.docId);
      const m = await engine.molecule(p.docId).catch(() => null);
      if (!m) return;
      if (d) { this.applyMolecule(d, m, p.summary || (await engine.summary(p.docId)), { keepSelection: true }); d.dirty = true; }
      else {
        const s = p.summary || (await engine.summary(p.docId));
        d = this.makeDoc(s, m, s.path); d.name = s.path ? s.path.split(/[\\/]/).pop() : `${j.title} result`;
        this.activate(d, { fit: true });
      }
      toast(`${j.title} finished`, { kind: 'ok' });
    } else toast(`${j.title} finished`, { kind: 'ok' });
  }

  // ---------- misc ----------
  /** Long engine request with a busy pill and a Cancel button. Returns null when cancelled or failed. */
  async runCancellable(method, params, label) {
    let token = null;
    this.setBusy(label, () => { if (token != null) api.cancel(token); });
    try {
      return await request(method, params, { cancellable: true, onToken: (t) => { token = t; } });
    } catch (e) {
      if (e.code !== 'cancelled') this.error(label.replace(/…$/, '') + ' failed', e);
      else this.status('Cancelled');
      return null;
    } finally { this.setBusy(null); }
  }

  async openTextDoc(text, fileName) {
    try {
      const s = await engine.openText(text, null, fileName);
      const m = await engine.molecule(s.docId);
      const d = this.makeDoc(s, m); d.name = fileName || 'Dropped text';
      this.activate(d, { fit: true });
    } catch (e) { this.error(`Could not read ${fileName || 'the text'}`, e); }
  }

  /** ViewChange from console commands. */
  applyViewChange(v) {
    const vp = this.viewport; const d = this.active;
    const styleMap = { ball: 'ballAndStick', stick: 'tube', spacefill: 'spaceFilling', wire: 'wireframe', ballAndStick: 'ballAndStick', tube: 'tube', spaceFilling: 'spaceFilling', wireframe: 'wireframe' };
    const hex = (c) => '#' + c.slice(0, 3).map((x) => Math.round(Math.max(0, Math.min(1, x)) * 255).toString(16).padStart(2, '0')).join('');
    const patch = {};
    if (v.style && styleMap[v.style]) patch.style = styleMap[v.style];
    if (v.labels) patch.labelMode = { none: 'none', atoms: 'elementIndex', charges: 'charge', element: 'element', index: 'index', elementIndex: 'elementIndex', charge: 'charge', custom: 'custom' }[v.labels] || 'element';
    if (Array.isArray(v.background) && v.background.length >= 3) patch.background = hex(v.background);
    if (typeof v.hydrogens === 'boolean') patch.showHydrogens = v.hydrogens;
    if (Array.isArray(v.colors) && v.colors.length) {
      for (const c of v.colors) for (const i of c.atoms || []) vp.colorOverrides.set(i, hex(c.rgba || [0.5, 0.5, 0.5]));
      vp.rebuild();
    }
    if (Array.isArray(v.hidden) && v.hidden.length) {
      for (const hd of v.hidden) for (const i of hd.atoms || []) (hd.hidden ? vp.hidden.add(i) : vp.hidden.delete(i));
      vp.rebuild();
    }
    if (Object.keys(patch).length) vp.setOptions(patch);
    if (Array.isArray(v.selection) && d) this.setSelection(v.selection);
    if (Array.isArray(v.measurements)) for (const atoms of v.measurements) if (atoms.length >= 2 && atoms.length <= 4) this.addMeasurement(atoms);
    for (const r of v.rotate || []) {
      const axis = new THREE.Vector3(r.axis === 'x' ? 1 : 0, r.axis === 'y' ? 1 : 0, r.axis === 'z' ? 1 : 0);
      vp.orientation.premultiply(new THREE.Quaternion().setFromAxisAngle(axis, -THREE.MathUtils.degToRad(r.degrees || 0))).normalize();
      vp.updateCamera();
    }
    if (v.view) vp.viewAlong(v.view);
    else if (v.fit) vp.fit();
    if (v.orbital && v.orbital.index != null) { this.pendingOrbital = v.orbital; this.emit('results-tab', 'orbitals'); this.emit('show-orbital', v.orbital); }
    if (v.vibration) { this.emit('results-tab', 'vibrations'); this.emit('show-mode', v.vibration.mode); }
    if (v.exportImage?.path) {
      const w = v.exportImage.width || Math.round(vp.width * 2), h2 = v.exportImage.height || Math.round((w * vp.height) / vp.width);
      const url = vp.exportPNG(w, h2);
      api.writeFileBase64(v.exportImage.path, url.split(',')[1]).then(() => this.status(`Saved ${v.exportImage.path}`));
    }
    if (v.close && d) this.closeDoc(d);
  }

  applyUITheme() {
    const t = this.settings.uiTheme;
    const dark = t === 'dark' || (t === 'system' && window.matchMedia('(prefers-color-scheme: dark)').matches);
    document.documentElement.dataset.uiTheme = dark ? 'dark' : 'light';
    this.viewport.setSystemDark(dark);
    this.emit('ui-theme', dark);
  }

  setBusy(msg, onCancel) { this.busy = msg; this.emit('busy', msg, onCancel); }
  status(msg) { this.emit('status', msg); }
  error(title, e) {
    console.error(title, e);
    const msg = e?.message || String(e);
    const hint = e?.code === 'not_installed' ? ' (program not installed)' : e?.code === 'offline' ? ' (offline)' : '';
    toast(`${title}: ${msg}${hint}`, { kind: 'error', timeout: 8000 });
  }

  /** Commands from the menu, palette, toolbar and keyboard are dispatched here (see commands.js). */
  command(id, arg) { this.emit('command', id, arg); }
}

export function escapeHTML(s) { return String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c])); }

export function showContextMenu(x, y, items) {
  document.querySelector('.ctxmenu')?.remove();
  const menu = h('div.ctxmenu', { role: 'menu' });
  for (const it of items) {
    if (it.sep) menu.append(h('div.sep'));
    else if (it.header) menu.append(h('div.ctx-header', {}, it.label));
    else menu.append(h('button', { role: 'menuitem', onclick: () => { menu.remove(); it.run(); } }, h('span.check', {}, it.checked ? '✓' : ''), it.label));
  }
  document.body.append(menu);
  const r = menu.getBoundingClientRect();
  menu.style.left = Math.min(x, window.innerWidth - r.width - 4) + 'px';
  menu.style.top = Math.min(y, window.innerHeight - r.height - 4) + 'px';
  const close = (e) => { if (!menu.contains(e.target)) { menu.remove(); document.removeEventListener('mousedown', close, true); } };
  setTimeout(() => document.addEventListener('mousedown', close, true), 0);
  const onKey = (e) => { if (e.key === 'Escape') { menu.remove(); document.removeEventListener('keydown', onKey, true); } };
  document.addEventListener('keydown', onKey, true);
}
