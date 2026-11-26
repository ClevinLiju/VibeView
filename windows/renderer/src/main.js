// Renderer entry point.
import { App } from './app.js';
import { api } from './api.js';
import { $ } from './dom.js';
import { buildToolbar, buildDocTabs, buildStatusBar, installSplitters, installDragDrop } from './shell.js';
import { buildSidebar, smokeBuild } from './sidebar.js';
import { buildInspector } from './inspector.js';
import { buildResults } from './results.js';
import { buildConsole } from './console.js';
import { installCommands } from './commands.js';
import { runSmokeExports } from './export.js';
import { installCartoon } from './cartoon.js';
import { smokeCalcDialog } from './calc-setup.js';
import { buildMeasurePanel } from './measurepanel.js';
import { smokeZMatrix } from './zmatrix.js';

// Numbers always use a decimal point: a ',' typed or pasted into a number field becomes '.'.
const isNumberInput = (t) => t instanceof HTMLInputElement && (t.type === 'number' || t.dataset.decimal === '1');
document.addEventListener('keydown', (e) => {
  if (e.key === ',' && !e.ctrlKey && !e.altKey && !e.metaKey && isNumberInput(e.target)) { e.preventDefault(); document.execCommand('insertText', false, '.'); }
}, true);
document.addEventListener('paste', (e) => {
  const text = e.clipboardData?.getData('text') || '';
  if (isNumberInput(e.target) && text.includes(',')) { e.preventDefault(); document.execCommand('insertText', false, text.trim().replace(/,/g, '.')); }
}, true);
async function start() {
  const app = new App();
  window.__vibeview = app; // for DevTools debugging
  await app.init();
  app.applyUITheme();
  window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => app.applyUITheme());
  buildToolbar(app);
  buildDocTabs(app);
  buildSidebar(app);
  buildInspector(app);
  buildResults(app);
  buildConsole(app);
  buildMeasurePanel(app);
  buildStatusBar(app);
  installSplitters(app);
  installDragDrop(app);
  installCommands(app);
  installCartoon(app);

  // empty-state hint + busy pill
  const hint = $('#empty-hint');
  const updHint = () => {
    const d = app.active;
    hint.hidden = !!(d && d.molecule.atoms.length);
    hint.innerHTML = '<b>Start building</b>Pick an element or fragment on the left and click here,<br>open a file (Ctrl+O), drop one onto the window,<br>or look a structure up by name (Ctrl+L).';
  };
  app.on('doc', updHint); app.on('molecule', updHint);
  app.on('busy', (msg, onCancel) => {
    $('#busy').hidden = !msg; $('#busy-text').textContent = msg || '';
    const c = $('#busy-cancel'); c.hidden = !onCancel; c.onclick = () => onCancel && onCancel();
  });
  app.setTool('select');
  app.emit('payload', app.payload);
  app.emit('panels');

  api.onOpenFile((p) => app.openPath(p));
  api.onSmokeTest((opts) => smokeTest(app, opts));
  const info = await api.appInfo();
  if (!info.smoke) await app.newDocument();
  api.ready();
}

async function smokeTest(app, { files, tab, orbital, ui, view, console: consoleLine, exportSpec, dialog, zmatrix, build }) {
  const log = (s) => api.smokeLog(s);
  const wait = (ms) => new Promise((r) => setTimeout(r, ms));
  let ok = true; let message = '';
  try {
    if (ui) { app.settings.uiTheme = ui; app.applyUITheme(); }
    log(`engine: ${JSON.stringify(app.engineStatus)} info: ${app.engineInfo ? app.engineInfo.version : 'none'}`);
    if (!files.length) await app.newDocument();
    for (const f of files) {
      const d = await app.openPath(f);
      if (!d) { ok = false; message += `could not open ${f}; `; continue; }
      log(`opened ${f}: ${d.summary.formula}, ${d.molecule.atoms.length} atoms, ${d.molecule.bonds.length} bonds, modes ${d.summary.modeCount}, orbitals ${d.summary.orbitalCount}, frames ${d.summary.frameCount}`);
      message += `${d.summary.formula} ${d.molecule.atoms.length} atoms; `;
    }
    if (orbital) app.smokeOrbital = orbital;
    if (tab) app.emit('results-tab', tab);
    if (view) app.viewport.setOptions(JSON.parse(view));
    if (consoleLine) {
      app.settings.panels.console = true; app.emit('panels');
      for (const line of consoleLine.split(';;')) await app.consoleRun(line);
    }
    await wait(orbital ? 4000 : 1500);
    if (dialog) { const r = await smokeCalcDialog(app, dialog, log); ok = ok && r.ok; message += `dialog ${dialog.split(':')[0]} ${r.ok ? 'ok' : 'FAILED'}; `; }
    if (zmatrix) { const r = await smokeZMatrix(app, zmatrix, log); ok = ok && r.ok; message += `zmatrix ${r.ok ? 'ok' : 'FAILED'}; `; await wait(400); }
    if (build) { const r = await smokeBuild(app, build, log); ok = ok && r.ok; message += `build ${r.ok ? 'ok' : 'FAILED'}; `; await wait(600); }
    if (exportSpec) { const r = await runSmokeExports(app, exportSpec, log); ok = ok && r.ok; message += `exports ${r.count} ${r.ok ? 'ok' : 'FAILED'}; `; }
    app.viewport.dirty = true;
    await wait(300);
    const url = app.viewport.exportPNG(1200, 900);
    await api.smokeDone({ ok, message, viewportPngB64: url.split(',')[1] });
  } catch (e) {
    log(`smoke failed: ${e.stack || e}`);
    await api.smokeDone({ ok: false, message: String(e.message || e) });
  }
}

window.addEventListener('error', (e) => { try { api.smokeLog(`error: ${e.message} at ${e.filename}:${e.lineno}`); } catch { /* not in smoke mode */ } });
window.addEventListener('unhandledrejection', (e) => { try { api.smokeLog(`unhandled: ${e.reason?.stack || e.reason}`); } catch { /* ignore */ } });
start().catch((e) => { console.error(e); try { api.smokeLog(`startup failed: ${e.stack || e}`); } catch { /* ignore */ } });
