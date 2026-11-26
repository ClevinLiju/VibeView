// Command catalog (menu, palette, toolbar) and the dispatcher.
import { api, request } from './api.js';
import { openPalette } from './palette.js';
import { openPeriodicTable } from './sidebar.js';
import { detectSymmetry } from './inspector.js';
import { openLookup, openCalcSetup, openXTBSettings, runXTB, defaultXTBSettings, openExportImage, openJobLog, openChargeDialog, openAbout, openShortcuts, openProgramPaths } from './dialogs.js';
import { toast } from './dom.js';
import { openZMatrixDialog, showZMatrixTab } from './zmatrix.js';
import { openExport } from './export.js';

export const CATALOG = [
  { id: 'file.new', title: 'New document', category: 'File', key: 'Ctrl+N' },
  { id: 'file.open', title: 'Open…', category: 'File', key: 'Ctrl+O' },
  { id: 'file.save', title: 'Save', category: 'File', key: 'Ctrl+S' },
  { id: 'file.saveAs', title: 'Save as…', category: 'File', key: 'Ctrl+Shift+S' },
  { id: 'file.saveSession', title: 'Save session…', category: 'File' },
  { id: 'file.exportImage', title: 'Export image…', category: 'File', key: 'Ctrl+E', keywords: 'png screenshot picture' },
  { id: 'file.export', title: 'Export… (structure formats, image, animation, data)', category: 'File', key: 'Ctrl+Shift+E', keywords: 'xyz sdf pdb mol cml molden cube gjf inp csv jpeg' },
  { id: 'file.exportAnimation', title: 'Export animation (GIF / video)…', category: 'File', keywords: 'gif webm mp4 movie trajectory vibration spin' },
  { id: 'file.close', title: 'Close document', category: 'File', key: 'Ctrl+W' },
  { id: 'edit.undo', title: 'Undo', category: 'Edit', key: 'Ctrl+Z' },
  { id: 'edit.redo', title: 'Redo', category: 'Edit', key: 'Ctrl+Y' },
  { id: 'edit.delete', title: 'Delete selected atoms', category: 'Edit', key: 'Del' },
  { id: 'edit.selectAll', title: 'Select all', category: 'Edit', key: 'Ctrl+A' },
  { id: 'edit.selectNone', title: 'Select none', category: 'Edit', key: 'Ctrl+Shift+A' },
  { id: 'edit.selectInvert', title: 'Invert selection', category: 'Edit', key: 'Ctrl+I' },
  { id: 'build.addHydrogens', title: 'Add hydrogens', category: 'Build', key: 'Ctrl+Shift+H' },
  { id: 'build.cleanUp', title: 'Clean up geometry (force field)', category: 'Build', key: 'Ctrl+Shift+K', keywords: 'uff relax' },
  { id: 'build.symmetrize', title: 'Symmetrize', category: 'Build' },
  { id: 'build.charge', title: 'Set charge and multiplicity…', category: 'Build' },
  { id: 'build.periodic', title: 'Periodic table…', category: 'Build', key: 'Ctrl+T' },
  { id: 'build.zmatrix', title: 'Build from Z-matrix…', category: 'Build', keywords: 'zmatrix internal coordinates gaussian orca paste molden' },
  { id: 'results.zmatrix', title: 'Z-matrix editor', category: 'Results', keywords: 'zmatrix internal coordinates table molden' },
  { id: 'tool.select', title: 'Select tool', category: 'Tool', key: 'Ctrl+1' },
  { id: 'tool.place', title: 'Place tool', category: 'Tool', key: 'Ctrl+2', keywords: 'sketch draw' },
  { id: 'tool.link', title: 'Link tool (bonds)', category: 'Tool', key: 'Ctrl+3' },
  { id: 'tool.gauge', title: 'Gauge tool (measure)', category: 'Tool', key: 'Ctrl+4' },
  { id: 'tool.delete', title: 'Delete tool', category: 'Tool', key: 'Ctrl+5' },
  { id: 'lookup.open', title: 'Look up structure by name…', category: 'Build', key: 'Ctrl+L', keywords: 'pubchem cas smiles cid' },
  { id: 'view.style.ballAndStick', title: 'Ball and stick', category: 'View', key: 'Alt+1' },
  { id: 'view.style.tube', title: 'Tube', category: 'View', key: 'Alt+2', keywords: 'licorice stick' },
  { id: 'view.style.wireframe', title: 'Wireframe', category: 'View', key: 'Alt+3' },
  { id: 'view.style.spaceFilling', title: 'Space filling', category: 'View', key: 'Alt+4', keywords: 'cpk vdw' },
  { id: 'view.fit', title: 'Fit to window', category: 'View', key: 'Ctrl+0' },
  { id: 'view.axis.x', title: 'View along X', category: 'View' },
  { id: 'view.axis.y', title: 'View along Y', category: 'View' },
  { id: 'view.axis.z', title: 'View along Z', category: 'View' },
  { id: 'view.ortho', title: 'Toggle orthographic projection', category: 'View', key: 'Ctrl+Shift+O' },
  { id: 'view.labels.none', title: 'Labels: none', category: 'View' },
  { id: 'view.labels.element', title: 'Labels: element', category: 'View' },
  { id: 'view.labels.elementIndex', title: 'Labels: element + index', category: 'View' },
  { id: 'view.labels.charge', title: 'Labels: partial charge', category: 'View' },
  { id: 'view.hydrogens', title: 'Show or hide hydrogens', category: 'View' },
  { id: 'view.dihedralPlanes', title: 'Show or hide dihedral planes', category: 'View', keywords: 'gauge measure torsion monitor plane' },
  { id: 'view.theme.light', title: 'Background: light', category: 'View' },
  { id: 'view.theme.dark', title: 'Background: dark', category: 'View' },
  { id: 'view.theme.white', title: 'Background: white', category: 'View' },
  { id: 'view.theme.black', title: 'Background: black', category: 'View' },
  { id: 'panel.library', title: 'Show or hide the library', category: 'Window', key: 'Ctrl+Alt+L' },
  { id: 'panel.inspector', title: 'Show or hide the inspector', category: 'Window', key: 'Ctrl+Alt+I' },
  { id: 'panel.results', title: 'Show or hide results', category: 'Window', key: 'Ctrl+Alt+R' },
  { id: 'panel.console', title: 'Show or hide the console', category: 'Window', key: 'Ctrl+Shift+C' },
  { id: 'results.orbitals', title: 'Orbitals', category: 'Results' },
  { id: 'results.vibrations', title: 'Vibrations and IR/Raman', category: 'Results' },
  { id: 'results.uvvis', title: 'UV-Vis spectrum', category: 'Results' },
  { id: 'results.trajectory', title: 'Trajectory / energy profile', category: 'Results' },
  { id: 'calc.xtbQuick', title: 'Optimize with xtb', category: 'Calculate', key: 'Ctrl+Shift+X' },
  { id: 'calc.xtb', title: 'xtb settings…', category: 'Calculate' },
  { id: 'calc.setup', title: 'Calculation setup…', category: 'Calculate', key: 'Ctrl+Alt+C', keywords: 'orca gaussian qchem input' },
  { id: 'calc.jobs', title: 'Job log', category: 'Calculate', key: 'Ctrl+Alt+J' },
  { id: 'calc.programs', title: 'Program locations…', category: 'Calculate', keywords: 'xtb orca gaussian qchem path exe settings' },
  { id: 'analysis.symmetry', title: 'Detect point group', category: 'Analysis', keywords: 'symmetry' },
  { id: 'help.shortcuts', title: 'Keyboard shortcuts', category: 'Help', key: 'F1' },
  { id: 'help.logs', title: 'Open logs folder', category: 'Help' },
  { id: 'help.about', title: 'About VibeView', category: 'Help' },
];

function isEditable(el) {
  return el && (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA' || el.tagName === 'SELECT' || el.isContentEditable);
}

export function installCommands(app) {
  const vp = () => app.viewport;
  const togglePanel = (k) => { app.settings.panels[k] = !app.settings.panels[k]; app.saveSettingsSoon(); app.emit('panels'); if (k === 'console' && app.settings.panels.console) app.consoleFocus?.(); };
  const handlers = {
    'file.new': () => app.newDocument(),
    'file.open': () => app.openDialog(),
    'file.save': () => app.save(),
    'file.saveAs': () => app.save(undefined, { as: true }),
    'file.saveSession': () => app.saveSession(),
    'file.exportImage': () => openExportImage(app),
    'file.export': (arg) => openExport(app, arg?.tab || 'structure', arg || {}),
    'file.exportAnimation': (arg) => openExport(app, 'animation', arg || {}),
    'file.close': () => app.closeDoc(),
    'app.quit-request': () => app.quitRequest(),
    'edit.undo': () => (isEditable(document.activeElement) ? document.execCommand('undo') : app.undo()),
    'edit.redo': () => (isEditable(document.activeElement) ? document.execCommand('redo') : app.redo()),
    'edit.delete': () => (isEditable(document.activeElement) ? document.execCommand('delete') : app.deleteSelection()),
    'edit.selectAll': () => (isEditable(document.activeElement) ? document.activeElement.select?.() : app.selectAll()),
    'edit.selectNone': () => app.selectNone(),
    'edit.selectInvert': () => app.selectInvert(),
    'build.addHydrogens': () => app.edit({ type: 'addHydrogens' }, { message: 'Hydrogens added' }),
    'build.cleanUp': async () => { app.setBusy('Cleaning up the geometry…'); try { await app.edit({ type: 'cleanUp', steps: 200 }, { keepSelection: true, message: 'Geometry cleaned up' }); } finally { app.setBusy(null); } },
    'build.symmetrize': () => app.edit({ type: 'symmetrize', tolerance: 0.1 }, { keepSelection: true, message: 'Symmetrized' }).then(() => detectSymmetry(app)),
    'build.charge': () => openChargeDialog(app),
    'build.periodic': () => openPeriodicTable(app),
    'build.zmatrix': () => openZMatrixDialog(app),
    'results.zmatrix': () => showZMatrixTab(app),
    'lookup.open': () => openLookup(app),
    'view.fit': () => vp().fit(),
    'view.ortho': () => vp().setOptions({ projection: vp().options.projection === 'orthographic' ? 'perspective' : 'orthographic' }),
    'view.hydrogens': () => vp().setOptions({ showHydrogens: !vp().options.showHydrogens }),
    'view.dihedralPlanes': () => { for (const m of app.active?.measurements || []) delete m.planes; vp().setOptions({ dihedralPlanes: !vp().options.dihedralPlanes }); },
    'panel.library': () => togglePanel('library'),
    'panel.inspector': () => togglePanel('inspector'),
    'panel.results': () => togglePanel('results'),
    'panel.console': () => togglePanel('console'),
    'panel.palette': () => openPalette(app, CATALOG),
    'calc.xtbQuick': () => runXTB(app, defaultXTBSettings(app)),
    'calc.xtb': () => openXTBSettings(app),
    'calc.setup': () => openCalcSetup(app),
    'calc.jobs': (arg) => openJobLog(app, arg),
    'calc.programs': () => openProgramPaths(app),
    'analysis.symmetry': () => detectSymmetry(app),
    'help.shortcuts': () => openShortcuts(),
    'help.logs': () => api.openLogsFolder(),
    'help.about': () => openAbout(app),
  };
  app.on('command', (id, arg) => {
    if (handlers[id]) return handlers[id](arg);
    let m;
    if ((m = id.match(/^tool\.(\w+)$/))) return app.setTool(m[1]);
    if ((m = id.match(/^view\.style\.(\w+)$/))) return vp().setOptions({ style: m[1] });
    if ((m = id.match(/^view\.axis\.(-?\w)$/))) return vp().viewAlong(m[1]);
    if ((m = id.match(/^view\.labels\.(\w+)$/))) return vp().setOptions({ labelMode: m[1] });
    if ((m = id.match(/^view\.theme\.(\w+)$/))) return vp().setOptions({ theme: m[1], background: null });
    if ((m = id.match(/^results\.(\w+)$/))) return app.emit('results-tab', m[1]);
    console.warn('unknown command', id);
    toast(`Not available: ${id}`, { kind: 'warn' });
  });
  api.onMenu((cmd, arg) => app.command(cmd, arg));
  // Keys that are not menu accelerators.
  window.addEventListener('keydown', (e) => {
    if (isEditable(e.target)) return;
    if (e.key === 'Delete' && !e.ctrlKey && document.activeElement === document.body) { app.deleteSelection(); }
    if (e.key === 'Escape' && document.activeElement === document.body) { app.viewportKey(e); }
  });
}

export { request };
