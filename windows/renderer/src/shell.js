// Toolbar, document tabs, status bar, splitters and drag-and-drop.
import { h, $, clear } from './dom.js';
import { ICONS } from './icons.js';
import { element, cssColor, textOn } from './elements.js';
import { api } from './api.js';

export const TOOLS = [
  { id: 'select', label: 'Select', key: 'Ctrl+1', tip: 'Select atoms: click, Shift-click to add, Ctrl-click to toggle, double-click for a fragment, Shift-drag for a box. Drag selected atoms to move them, Alt-drag to rotate them.' },
  { id: 'place', label: 'Place', key: 'Ctrl+2', tip: 'Place the current element or fragment: click empty space to add, click an atom to change or substitute it, Ctrl-click an atom to grow a bonded atom.' },
  { id: 'link', label: 'Link', key: 'Ctrl+3', tip: 'Bond two atoms: click one, then the other. Click a bond to cycle its order, Ctrl-click to delete it. Keys 1–3 set the order.' },
  { id: 'gauge', label: 'Gauge', key: 'Ctrl+4', tip: 'Measure: click 2, 3 or 4 atoms for a distance, angle or dihedral. Enter or a click on empty space keeps it.' },
  { id: 'delete', label: 'Delete', key: 'Ctrl+5', tip: 'Click an atom or bond to delete it.' },
];

export function buildToolbar(app) {
  const tb = $('#toolbar');
  const btn = (icon, label, title, cmd, opts = {}) => h('button.tb-btn', { title, onclick: () => app.command(cmd), dataset: { cmd } }, h('span', { innerHTML: ICONS[icon] }), opts.showLabel ? h('span.lbl', {}, label) : null);
  const tools = h('div.group', { role: 'toolbar', 'aria-label': 'Tools' },
    TOOLS.map((t) => h('button.tb-btn', { dataset: { tool: t.id }, title: `${t.label} (${t.key})\n${t.tip}`, onclick: () => app.setTool(t.id) }, h('span', { innerHTML: ICONS[t.id] }), h('span.lbl', {}, t.label))));
  const elementBtn = h('button.tb-btn.element-btn', { title: 'Element or fragment to place (Ctrl+T for the periodic table)', onclick: () => app.command('build.periodic') });
  const bondOrder = h('div.bond-order', { title: 'Bond order for the Link tool' },
    [1, 2, 3].map((o) => h('button', { dataset: { order: o }, onclick: () => { app.bondOrder = o; app.emit('tool', app.tool); } }, ['–', '=', '≡'][o - 1])));
  tb.append(
    h('div.group', {}, btn('open', 'Open', 'Open… (Ctrl+O)', 'file.open'), btn('save', 'Save', 'Save (Ctrl+S)', 'file.save'),
      btn('undo', 'Undo', 'Undo (Ctrl+Z)', 'edit.undo'), btn('redo', 'Redo', 'Redo (Ctrl+Y)', 'edit.redo')),
    h('div.sep'), tools, elementBtn, bondOrder, h('div.sep'),
    h('div.group', {},
      btn('hydrogens', 'Add H', 'Add hydrogens (Ctrl+Shift+H)', 'build.addHydrogens'),
      btn('clean', 'Clean up', 'Clean up geometry with the built-in force field (Ctrl+Shift+K)', 'build.cleanUp'),
      btn('bolt', 'Optimize', 'Optimize with xtb (Ctrl+Shift+X)', 'calc.xtbQuick', { showLabel: true }),
      btn('calc', 'Calculation', 'Set up a calculation for ORCA, Gaussian, Q-Chem or xtb (Ctrl+Alt+C)', 'calc.setup', { showLabel: true })),
    h('div.spacer'),
    h('div.group', {},
      btn('lookup', 'Look up', 'Look up a structure by name, CAS number, SMILES or CID (Ctrl+L)', 'lookup.open'),
      btn('fit', 'Fit', 'Fit to window (Ctrl+0)', 'view.fit'),
      btn('jobs', 'Jobs', 'Job log (Ctrl+Alt+J)', 'calc.jobs'),
      btn('console', 'Console', 'Console (Ctrl+Shift+C)', 'panel.console'),
      btn('palette', 'Commands', 'Command palette (Ctrl+K)', 'panel.palette'),
      btn('results', 'Results', 'Results panel (Ctrl+Alt+R)', 'panel.results'),
      btn('library', 'Library', 'Library (Ctrl+Alt+L)', 'panel.library'),
      btn('inspector', 'Inspector', 'Inspector (Ctrl+Alt+I)', 'panel.inspector')),
  );
  const refreshTool = () => {
    for (const b of tb.querySelectorAll('[data-tool]')) b.classList.toggle('on', b.dataset.tool === app.tool);
    bondOrder.hidden = app.tool !== 'link';
    for (const b of bondOrder.children) b.classList.toggle('on', Number(b.dataset.order) === app.bondOrder);
  };
  const refreshPayload = () => {
    const p = app.payload;
    if (p.kind === 'element') {
      elementBtn.textContent = element(p.z).symbol;
      elementBtn.style.background = cssColor(p.z); elementBtn.style.color = textOn(p.z);
    } else if (p.kind === 'group') {   // element group (sidebar.js picker)
      elementBtn.textContent = (p.label || p.name).slice(0, 12);
      elementBtn.style.background = cssColor(p.z); elementBtn.style.color = textOn(p.z);
    } else {
      elementBtn.textContent = (p.name || p.id).slice(0, 10);
      elementBtn.style.background = ''; elementBtn.style.color = '';
    }
  };
  const refreshPanels = () => {
    const pn = app.settings.panels;
    for (const [cmd, key] of [['panel.console', 'console'], ['panel.results', 'results'], ['panel.library', 'library'], ['panel.inspector', 'inspector']]) {
      tb.querySelector(`[data-cmd="${cmd}"]`)?.classList.toggle('on', !!pn[key]);
    }
  };
  const refreshDoc = () => {
    const d = app.active;
    tb.querySelector('[data-cmd="edit.undo"]').disabled = !d?.summary.canUndo;
    tb.querySelector('[data-cmd="edit.redo"]').disabled = !d?.summary.canRedo;
  };
  app.on('tool', refreshTool); app.on('payload', refreshPayload); app.on('panels', refreshPanels); app.on('doc', refreshDoc);
  refreshTool(); refreshPayload(); refreshPanels();
}

export function buildDocTabs(app) {
  const bar = $('#doc-tabs');
  const render = () => {
    clear(bar);
    for (const d of app.docs) {
      bar.append(h('div.doc-tab' + (d === app.active ? '.on' : ''), { title: d.path || d.name, onmousedown: (e) => { if (e.button === 1) { e.preventDefault(); app.closeDoc(d); } else if (e.button === 0) app.activate(d); } },
        d.dirty ? h('span.dot', { title: 'Unsaved changes' }) : null,
        h('span.name', {}, d.name),
        h('button.x', { title: 'Close (Ctrl+W)', innerHTML: '&#x2715;', onmousedown: (e) => e.stopPropagation(), onclick: (e) => { e.stopPropagation(); app.closeDoc(d); } })));
    }
    bar.append(h('button.doc-tab-add', { title: 'New document (Ctrl+N)', onclick: () => app.newDocument() }, '+'));
  };
  app.on('docs', render);
  app.on('doc', render);
  render();
}

export function buildStatusBar(app) {
  const bar = $('#statusbar');
  const engineEl = h('span', { title: '' });
  const msg = h('span.grow');
  const counts = h('span');
  const sel = h('span');
  const view = h('button', { title: 'Toggle orthographic projection (Ctrl+Shift+O)', onclick: () => app.command('view.ortho') });
  bar.append(engineEl, msg, sel, counts, view);
  let msgTimer;
  app.on('status', (t) => { msg.textContent = t || ''; clearTimeout(msgTimer); if (t) msgTimer = setTimeout(() => { msg.textContent = hintFor(app); }, 6000); });
  const renderEngine = () => {
    const s = app.engineStatus || {};
    const mock = s.mock;
    const cls = mock ? 'mock' : (s.state || 'starting');
    const label = s.state === 'running' ? (mock ? 'Mock engine' : `Engine ${app.engineInfo?.version || ''}`) : s.state === 'restarting' ? 'Engine restarting…' : s.state === 'missing' ? 'Engine not found' : s.state === 'failed' ? 'Engine stopped' : 'Engine starting…';
    clear(engineEl).append(h('span.engine-dot.' + cls), label);
    engineEl.title = `${s.path || s.message || ''}${s.logPath ? '\nLog: ' + s.logPath : ''}`;
  };
  const renderDoc = () => {
    const d = app.active;
    const m = d?.molecule;
    counts.textContent = m && m.atoms.length ? `${d.summary.formula} · ${m.atoms.length} atoms · ${m.bonds.length} bonds · charge ${m.charge}, mult ${m.multiplicity}` : '';
    if (!msg.textContent) msg.textContent = hintFor(app);
  };
  const renderSel = () => {
    const d = app.active;
    sel.textContent = d && d.selection.size ? `${d.selection.size} selected` : '';
  };
  const renderView = () => { view.textContent = app.viewport.options.projection === 'orthographic' ? 'Orthographic' : 'Perspective'; };
  app.on('engine-status', renderEngine); app.on('engine-info', renderEngine);
  app.on('doc', renderDoc); app.on('molecule', renderDoc); app.on('selection', renderSel); app.on('options', renderView);
  app.on('tool', () => { msg.textContent = hintFor(app); });
  renderEngine(); renderView();
}

function hintFor(app) {
  const t = TOOLS.find((x) => x.id === app.tool);
  return t ? t.tip : '';
}

/** Resizable side panels and bottom panel. */
export function installSplitters(app) {
  for (const sp of document.querySelectorAll('.splitter')) {
    sp.addEventListener('pointerdown', (e) => {
      const target = sp.dataset.target === 'bottom' ? document.querySelector('#bottom > .panel:not([hidden])') : $('#' + sp.dataset.target);
      if (!target) return;
      sp.setPointerCapture(e.pointerId); sp.classList.add('dragging');
      const start = { x: e.clientX, y: e.clientY, w: target.offsetWidth, h: target.offsetHeight };
      const move = (ev) => {
        if (sp.classList.contains('h')) target.style.height = Math.max(100, start.h - (ev.clientY - start.y)) + 'px';
        else if (sp.dataset.side === 'left') target.style.width = Math.max(170, Math.min(460, start.w + ev.clientX - start.x)) + 'px';
        else target.style.width = Math.max(200, Math.min(480, start.w - (ev.clientX - start.x))) + 'px';
      };
      const up = () => { sp.classList.remove('dragging'); sp.removeEventListener('pointermove', move); sp.removeEventListener('pointerup', up); };
      sp.addEventListener('pointermove', move); sp.addEventListener('pointerup', up);
    });
  }
  const apply = () => {
    const p = app.settings.panels;
    $('#library').hidden = !p.library; document.querySelector('[data-target="library"]').hidden = !p.library;
    $('#inspector').hidden = !p.inspector; document.querySelector('[data-target="inspector"]').hidden = !p.inspector;
    $('#console').hidden = !p.console;
    const hasResults = !!app.active && (hasResultData(app.active) || !!app.zmatrixOpen); // zmatrixOpen: Z-Matrix tab (zmatrix.js)
    $('#results').hidden = !(p.results && hasResults);
    document.querySelector('[data-target="bottom"]').hidden = $('#console').hidden && $('#results').hidden;
  };
  app.on('panels', apply); app.on('doc', apply);
  apply();
}

export function hasResultData(d) {
  const s = d.summary || {};
  return !!(s.program || s.modeCount || s.orbitalCount || s.frameCount > 1 || s.excitedStateCount || (s.volumeNames || []).length || s.hasWavefunction);
}

export function installDragDrop(app) {
  const hint = $('#drop-hint');
  let depth = 0;
  window.addEventListener('dragenter', (e) => { if ([...(e.dataTransfer?.types || [])].includes('Files')) { depth++; hint.hidden = false; } });
  window.addEventListener('dragleave', () => { depth = Math.max(0, depth - 1); if (!depth) hint.hidden = true; });
  window.addEventListener('dragover', (e) => { e.preventDefault(); e.dataTransfer.dropEffect = 'copy'; });
  window.addEventListener('drop', async (e) => {
    e.preventDefault(); depth = 0; hint.hidden = true;
    for (const f of [...(e.dataTransfer?.files || [])]) {
      const p = api.pathForFile(f);
      if (p) await app.openPath(p);
      else if (f.size < 20_000_000) {
        // No path (e.g. dragged from a browser): send the text.
        try { const text = await f.text(); await app.openTextDoc(text, f.name); } catch (err) { app.error('Could not read the dropped file', err); }
      }
    }
  });
}
