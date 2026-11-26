'use strict';
// Narrow bridge between the sandboxed renderer and the main process.
const { contextBridge, ipcRenderer, webUtils } = require('electron');

let tokenCounter = 1;

function on(channel, fn) {
  const h = (_e, ...args) => fn(...args);
  ipcRenderer.on(channel, h);
  return () => ipcRenderer.removeListener(channel, h);
}

contextBridge.exposeInMainWorld('vibeview', {
  /** Engine request. Resolves with the envelope {ok, result} or {ok: false, error: {code, message}}.
   *  (An Error rejected across contextBridge loses its custom properties such as `code`, so the
   *  renderer's api.js turns the envelope into an Error itself.) */
  request(method, params, opts) {
    if (typeof method !== 'string') return Promise.resolve({ ok: false, error: { code: 'bad_request', message: 'method must be a string' } });
    const token = opts && opts.cancellable ? tokenCounter++ : null;
    const p = ipcRenderer.invoke('engine:request', method, params || {}, token);
    if (token != null && typeof opts.onToken === 'function') opts.onToken(token);
    return p;
  },
  cancel: (token) => ipcRenderer.invoke('engine:cancel', token),
  engineStatus: () => ipcRenderer.invoke('engine:status'),
  onEvent: (fn) => on('engine-event', fn),
  onEngineStatus: (fn) => on('engine-status', fn),
  onEngineRestarted: (fn) => on('engine-restarted', fn),
  onMenu: (fn) => on('menu', fn),
  onOpenFile: (fn) => on('open-file', fn),
  onSmokeTest: (fn) => on('smoke-test', fn),
  openFileDialog: (opts) => ipcRenderer.invoke('dialog:open', opts),
  saveFileDialog: (opts) => ipcRenderer.invoke('dialog:save', opts),
  messageBox: (opts) => ipcRenderer.invoke('dialog:message', opts),
  recentFiles: () => ipcRenderer.invoke('recent:list'),
  addRecentFile: (p) => ipcRenderer.invoke('recent:add', p),
  writeFileBase64: (p, b64) => ipcRenderer.invoke('file:writeBase64', p, b64),
  writeTextFile: (p, text) => ipcRenderer.invoke('file:writeText', p, text),
  revealInExplorer: (p) => ipcRenderer.invoke('shell:reveal', p),
  openPath: (p) => ipcRenderer.invoke('shell:openPath', p),
  openLogsFolder: () => ipcRenderer.invoke('shell:openLogs'),
  openTextFile: (p) => ipcRenderer.invoke('shell:openTextFile', p),
  xtbStatus: () => ipcRenderer.invoke('xtb:status'),
  installXtb: () => ipcRenderer.invoke('xtb:install'),
  uninstallXtb: () => ipcRenderer.invoke('xtb:uninstall'),
  onXtbInstallProgress: (fn) => on('xtb-install-progress', fn),
  loadSettings: () => ipcRenderer.invoke('settings:load'),
  saveSettings: (s) => ipcRenderer.invoke('settings:save', s),
  setTitle: (t) => ipcRenderer.invoke('window:setTitle', t),
  closeWindow: () => ipcRenderer.invoke('window:close'),
  appInfo: () => ipcRenderer.invoke('app:info'),
  pathForFile: (file) => { try { return webUtils.getPathForFile(file); } catch { return null; } },
  ready: () => ipcRenderer.send('renderer:ready'),
  smokeDone: (r) => ipcRenderer.invoke('smoke:done', r),
  smokeLog: (line) => ipcRenderer.send('smoke:log', String(line)),
  smokeWriteFile: (name, b64) => ipcRenderer.invoke('smoke:writeFile', name, b64),
});
