'use strict';
const { Menu, shell } = require('electron');
const path = require('path');

/** Application menu. Items send command ids to the renderer, which owns all app state. */
function buildMenu({ send, recent, openPath, clearRecent, logDir, dev }) {
  const c = (label, cmd, accelerator, extra = {}) => ({ label, accelerator, click: () => send(cmd), ...extra });
  const recentItems = recent.length
    ? [...recent.map((p, i) => ({ label: `${i < 9 ? '&' + (i + 1) + ' ' : ''}${path.basename(p).replace(/&/g, '&&')}`, sublabel: p, toolTip: p, click: () => openPath(p) })),
      { type: 'separator' }, { label: 'Clear Recent', click: clearRecent }]
    : [{ label: 'No recent files', enabled: false }];

  const template = [
    {
      label: '&File',
      submenu: [
        c('&New', 'file.new', 'Ctrl+N'),
        c('&Open…', 'file.open', 'Ctrl+O'),
        { label: 'Open &Recent', submenu: recentItems },
        { type: 'separator' },
        c('&Save', 'file.save', 'Ctrl+S'),
        c('Save &As…', 'file.saveAs', 'Ctrl+Shift+S'),
        c('Save Session…', 'file.saveSession'),
        { type: 'separator' },
        c('&Export…', 'file.export', 'Ctrl+Shift+E'),
        c('Export &Image…', 'file.exportImage', 'Ctrl+E'),
        c('Export &Animation (GIF)…', 'file.exportAnimation'),
        { type: 'separator' },
        c('&Close Document', 'file.close', 'Ctrl+W'),
        c('E&xit', 'app.quit-request', 'Alt+F4'),
      ],
    },
    {
      label: '&Edit',
      submenu: [
        c('&Undo', 'edit.undo', 'Ctrl+Z'),
        c('&Redo', 'edit.redo', 'Ctrl+Y'),
        { type: 'separator' },
        { role: 'cut' }, { role: 'copy' }, { role: 'paste' },
        c('&Delete Selection', 'edit.delete'),
        { type: 'separator' },
        c('Select &All', 'edit.selectAll', 'Ctrl+A'),
        c('Select &None', 'edit.selectNone', 'Ctrl+Shift+A'),
        c('&Invert Selection', 'edit.selectInvert', 'Ctrl+I'),
        { type: 'separator' },
        c('Add &Hydrogens', 'build.addHydrogens', 'Ctrl+Shift+H'),
        c('&Clean Up Geometry', 'build.cleanUp', 'Ctrl+Shift+K'),
        c('S&ymmetrize', 'build.symmetrize'),
        c('Set Charge and &Multiplicity…', 'build.charge'),
      ],
    },
    {
      label: '&View',
      submenu: [
        c('&Ball and Stick', 'view.style.ballAndStick', 'Alt+1'),
        c('&Tube', 'view.style.tube', 'Alt+2'),
        c('&Wireframe', 'view.style.wireframe', 'Alt+3'),
        c('&Space Filling', 'view.style.spaceFilling', 'Alt+4'),
        { type: 'separator' },
        c('&Fit to Window', 'view.fit', 'Ctrl+0'),
        { label: 'Standard &Views', submenu: [
          c('Along +X', 'view.axis.x'), c('Along +Y', 'view.axis.y'), c('Along +Z', 'view.axis.z'),
          c('Along −X', 'view.axis.-x'), c('Along −Y', 'view.axis.-y'), c('Along −Z', 'view.axis.-z'),
        ] },
        c('&Orthographic Projection', 'view.ortho', 'Ctrl+Shift+O'),
        { type: 'separator' },
        c('&Library', 'panel.library', 'Ctrl+Alt+L'),
        c('&Inspector', 'panel.inspector', 'Ctrl+Alt+I'),
        c('&Results', 'panel.results', 'Ctrl+Alt+R'),
        c('&Console', 'panel.console', 'Ctrl+Shift+C'),
        c('Command &Palette…', 'panel.palette', 'Ctrl+K'),
        { type: 'separator' },
        { role: 'zoomIn', label: 'Larger Interface' }, { role: 'zoomOut', label: 'Smaller Interface' }, { role: 'resetZoom', label: 'Actual Size' },
        { role: 'togglefullscreen' },
        ...(dev ? [{ type: 'separator' }, { role: 'reload' }, { role: 'toggleDevTools' }] : [{ type: 'separator' }, { role: 'toggleDevTools', accelerator: 'Ctrl+Shift+I' }]),
      ],
    },
    {
      label: '&Build',
      submenu: [
        c('&Select', 'tool.select', 'Ctrl+1'),
        c('&Place', 'tool.place', 'Ctrl+2'),
        c('&Link', 'tool.link', 'Ctrl+3'),
        c('&Gauge', 'tool.gauge', 'Ctrl+4'),
        c('&Delete', 'tool.delete', 'Ctrl+5'),
        { type: 'separator' },
        c('Periodic &Table…', 'build.periodic', 'Ctrl+T'),
        c('Look Up &Name…', 'lookup.open', 'Ctrl+L'),
        c('From &Z-Matrix…', 'build.zmatrix'),
        c('Z-Matrix &Editor', 'results.zmatrix'),
      ],
    },
    {
      label: '&Calculate',
      submenu: [
        c('&Optimize with xtb', 'calc.xtbQuick', 'Ctrl+Shift+X'),
        c('&xtb Settings…', 'calc.xtb'),
        c('&Calculation Setup…', 'calc.setup', 'Ctrl+Alt+C'),
        { type: 'separator' },
        c('&Job Log', 'calc.jobs', 'Ctrl+Alt+J'),
        c('Program &Locations…', 'calc.programs'),
        c('&Install xtb…', 'calc.installXtb'),
        c('Point &Group', 'analysis.symmetry'),
      ],
    },
    {
      label: '&Help',
      submenu: [
        c('&Keyboard Shortcuts', 'help.shortcuts', 'F1'),
        { label: 'Open &Logs Folder', click: () => shell.openPath(logDir) },
        { type: 'separator' },
        c('&About VibeView', 'help.about'),
      ],
    },
  ];
  return Menu.buildFromTemplate(template);
}

module.exports = { buildMenu };
