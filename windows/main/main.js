'use strict';
const { app, BrowserWindow, ipcMain, dialog, Menu, shell, nativeTheme, session } = require('electron');
const path = require('path');
const fs = require('fs');
const { EngineClient, resolveEnginePath, mockEngine } = require('./engine');
const { buildMenu } = require('./menu');

const APP_ROOT = path.resolve(__dirname, '..');
const OPENABLE = ['xyz', 'pdb', 'mol', 'sdf', 'cml', 'gjf', 'com', 'log', 'out', 'fchk', 'fch', 'cube', 'cub', 'molden', 'input',
  'vibeview', 'inp', 'in', 'hess', 'mol2', 'zmat', 'gzmat', 'trj'];

// ---------- command line ----------
function parseArgs(argv) {
  const out = { files: [], smoke: null, screenshot: null, mock: false, dev: false, width: 1400, height: 900 };
  // In a packaged app argv[0] is the exe; in dev, argv[1] is the app dir ".".
  const args = argv.slice(app.isPackaged ? 1 : 2);
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a === '--smoke-test') {
      out.smoke = true;
      if (args[i + 1] && !args[i + 1].startsWith('--')) out.files.push(path.resolve(args[++i]));
    } else if (a === '--screenshot') out.screenshot = path.resolve(args[++i]);
    else if (a === '--size') { const [w, h] = String(args[++i]).split('x').map(Number); if (w && h) { out.width = w; out.height = h; } }
    else if (a === '--mock-engine') out.mock = true;
    else if (a === '--dev') out.dev = true;
    else if (a.startsWith('--')) { /* chromium / electron switches */ }
    else if (a !== '.' && fs.existsSync(a) && fs.statSync(a).isFile()) out.files.push(path.resolve(a));
  }
  return out;
}

const cli = parseArgs(process.argv);

// Scientific app: numbers always use a decimal point. Chromium formats <input type=number>, toLocaleString and
// Intl with the UI locale (e.g. "1,497" on an Italian system), so pin the renderer locale to en-US. Dialogs and
// menus are unaffected (they are ours or native). Typing ',' in number fields is mapped to '.' in the renderer.
app.commandLine.appendSwitch('lang', 'en-US');

// ---------- single instance ----------
if (!cli.smoke && !app.requestSingleInstanceLock()) {
  app.quit();
} else {
  main();
}

function main() {
  const userDir = path.join(app.getPath('appData'), 'VibeView');
  const logDir = path.join(userDir, 'logs');
  const recentPath = path.join(userDir, 'recent.json');
  const settingsPath = path.join(userDir, 'settings.json');
  let win = null;
  let rendererReady = false;
  const pendingOpen = [...cli.files];
  const tokens = new Map(); // renderer cancel token -> engine request id
  const userChosen = new Set(); // normalized paths returned by Save dialogs (write allowlist)
  const norm = (p) => path.resolve(p).toLowerCase();
  const isAbsPath = (p) => typeof p === 'string' && p.length < 32768 && path.isAbsolute(p) && !p.includes('\0');

  // ----- recent files -----
  function readRecent() {
    try { return JSON.parse(fs.readFileSync(recentPath, 'utf8')).filter((p) => typeof p === 'string'); } catch { return []; }
  }
  function writeRecent(list) {
    try { fs.mkdirSync(userDir, { recursive: true }); fs.writeFileSync(recentPath, JSON.stringify(list.slice(0, 15), null, 1)); } catch { /* ignore */ }
  }
  function addRecent(p) {
    if (cli.smoke) return;
    const list = [p, ...readRecent().filter((q) => q.toLowerCase() !== p.toLowerCase())];
    writeRecent(list);
    try { app.addRecentDocument(p); } catch { /* not supported */ }
    refreshMenu();
  }
  function refreshMenu() {
    Menu.setApplicationMenu(buildMenu({ send: sendMenu, recent: readRecent(), openPath, clearRecent: () => { writeRecent([]); try { app.clearRecentDocuments(); } catch { } refreshMenu(); }, logDir, dev: cli.dev }));
  }
  function sendMenu(cmd, arg) {
    if (win) win.webContents.send('menu', cmd, arg);
  }
  function openPath(p) {
    if (!win) { pendingOpen.push(p); return; }
    if (win.isMinimized()) win.restore();
    win.focus();
    if (rendererReady) win.webContents.send('open-file', p);
    else pendingOpen.push(p);
  }

  // ----- engine -----
  const engine = new EngineClient({
    logDir,
    resolve: () => {
      if (cli.mock || process.env.VIBEVIEW_MOCK_ENGINE === '1') return mockEngine(APP_ROOT);
      const real = resolveEnginePath({ isPackaged: app.isPackaged, resourcesPath: process.resourcesPath, appRoot: APP_ROOT });
      if (real) return real;
      // Development fallback so the UI is usable before the Swift engine builds.
      if (!app.isPackaged && fs.existsSync(path.join(APP_ROOT, 'dev', 'mock-engine.js'))) return mockEngine(APP_ROOT);
      return null;
    },
  });
  let engineStatus = { state: 'starting' };
  engine.on('status', (s) => { engineStatus = s; if (win) win.webContents.send('engine-status', s); });
  engine.on('event', (name, params) => { if (win) win.webContents.send('engine-event', name, params); });
  engine.on('restarted', () => { if (win) win.webContents.send('engine-restarted'); });

  // ----- IPC -----
  ipcMain.handle('engine:request', async (_e, method, params, token) => {
    if (typeof method !== 'string' || !/^[a-zA-Z]+(\.[a-zA-Z]+)*$/.test(method) || (params != null && typeof params !== 'object')) {
      return { ok: false, error: { code: 'bad_request', message: 'invalid engine request' } };
    }
    if (token != null) tokens.set(token, engine.peekNextId());
    try {
      return { ok: true, result: await engine.request(method, params || {}) };
    } catch (e) {
      return { ok: false, error: { code: e.code || 'internal', message: e.message } };
    } finally {
      if (token != null) tokens.delete(token);
    }
  });
  ipcMain.handle('engine:cancel', (_e, token) => { const id = tokens.get(token); if (id != null) engine.cancel(id); });
  ipcMain.handle('engine:status', () => ({ ...engineStatus, logPath: engine.logPath }));
  ipcMain.handle('dialog:open', async (_e, opts = {}) => {
    const r = await dialog.showOpenDialog(win, {
      title: opts.title || 'Open',
      properties: opts.directory ? ['openDirectory', 'createDirectory'] : ['openFile', 'multiSelections'],
      defaultPath: opts.defaultPath,
      filters: opts.directory ? undefined : (opts.filters || [
        { name: 'Molecular files', extensions: OPENABLE },
        { name: 'All files', extensions: ['*'] },
      ]),
    });
    return r.canceled ? null : r.filePaths;
  });
  ipcMain.handle('dialog:save', async (_e, opts = {}) => {
    const r = await dialog.showSaveDialog(win, {
      title: opts.title || 'Save As', defaultPath: opts.defaultPath, filters: opts.filters,
    });
    if (r.canceled || !r.filePath) return null;
    userChosen.add(norm(r.filePath));
    return r.filePath;
  });
  ipcMain.handle('dialog:message', async (_e, opts = {}) => {
    const r = await dialog.showMessageBox(win, {
      type: opts.type || 'info', title: opts.title || 'VibeView', message: opts.message || '', detail: opts.detail,
      buttons: opts.buttons || ['OK'], defaultId: opts.defaultId ?? 0, cancelId: opts.cancelId ?? (opts.buttons ? opts.buttons.length - 1 : 0),
    });
    return r.response;
  });
  ipcMain.handle('recent:list', () => readRecent());
  ipcMain.handle('recent:add', (_e, p) => { if (isAbsPath(p)) addRecent(p); });
  // Writes go only to paths the user picked in a Save dialog, or (console `export image …`) to a .png.
  ipcMain.handle('file:writeBase64', async (_e, p, b64) => {
    if (!isAbsPath(p) || typeof b64 !== 'string' || !(userChosen.has(norm(p)) || /\.png$/i.test(p))) throw new Error('write refused: path was not chosen in a Save dialog');
    fs.writeFileSync(p, Buffer.from(b64, 'base64')); return true;
  });
  ipcMain.handle('file:writeText', async (_e, p, text) => {
    if (!isAbsPath(p) || typeof text !== 'string' || !userChosen.has(norm(p))) throw new Error('write refused: path was not chosen in a Save dialog');
    fs.writeFileSync(p, text, 'utf8'); return true;
  });
  ipcMain.handle('shell:reveal', (_e, p) => { if (isAbsPath(p)) shell.showItemInFolder(p); });
  // Only folders (job directories): shell.openPath on a file would run it with its default handler.
  ipcMain.handle('shell:openPath', (_e, p) => {
    try { if (isAbsPath(p) && fs.statSync(p).isDirectory()) return shell.openPath(p); } catch { /* missing */ }
    return 'not a folder';
  });
  ipcMain.handle('shell:openLogs', () => shell.openPath(logDir));
  ipcMain.handle('settings:load', () => { try { return JSON.parse(fs.readFileSync(settingsPath, 'utf8')); } catch { return {}; } });
  ipcMain.handle('settings:save', (_e, s) => { if (!s || typeof s !== 'object') return; try { fs.mkdirSync(userDir, { recursive: true }); fs.writeFileSync(settingsPath, JSON.stringify(s, null, 1)); } catch { } });
  ipcMain.handle('window:setTitle', (_e, t) => { if (win && typeof t === 'string') win.setTitle(t.slice(0, 300)); });
  ipcMain.handle('app:info', () => ({ version: app.getVersion(), smoke: !!cli.smoke, dev: cli.dev, platform: process.platform, darkMode: nativeTheme.shouldUseDarkColors }));
  ipcMain.on('renderer:ready', () => {
    rendererReady = true;
    const files = pendingOpen.splice(0);
    if (cli.smoke) win.webContents.send('smoke-test', { files, screenshot: cli.screenshot, tab: process.env.VIBEVIEW_SMOKE_TAB || null, orbital: process.env.VIBEVIEW_SMOKE_ORBITAL || null, ui: process.env.VIBEVIEW_SMOKE_UI || null, view: process.env.VIBEVIEW_SMOKE_VIEW || null, console: process.env.VIBEVIEW_SMOKE_CONSOLE || null, exportSpec: process.env.VIBEVIEW_SMOKE_EXPORT || null, dialog: process.env.VIBEVIEW_SMOKE_DIALOG || null, zmatrix: process.env.VIBEVIEW_SMOKE_ZMATRIX || null, build: process.env.VIBEVIEW_SMOKE_BUILD || null });
    else for (const f of files) win.webContents.send('open-file', f);
  });
  ipcMain.handle('smoke:done', async (_e, { ok, message, viewportPngB64 }) => {
    const out = cli.screenshot || path.join(APP_ROOT, 'dist', 'smoke.png');
    try {
      fs.mkdirSync(path.dirname(out), { recursive: true });
      const img = await win.webContents.capturePage();
      const png = img.toPNG();
      if (png.length > 1000) fs.writeFileSync(out, png);
      if (viewportPngB64) fs.writeFileSync(out.replace(/\.png$/i, '') + '-viewport.png', Buffer.from(viewportPngB64, 'base64'));
      process.stdout.write(`smoke-test: ${ok ? 'ok' : 'FAILED'} ${message || ''}\nscreenshot: ${out} (${png.length} bytes)\n`);
    } catch (e) {
      process.stdout.write(`smoke-test: capture failed ${e.message}\n`);
      ok = false;
    }
    setTimeout(() => app.exit(ok ? 0 : 1), 100);
  });
  ipcMain.on('smoke:log', (_e, line) => process.stdout.write(`[renderer] ${line}\n`));
  // Smoke test only (VIBEVIEW_SMOKE_EXPORT): export.js writes its files next to the screenshot.
  ipcMain.handle('smoke:writeFile', (_e, name, b64) => {
    if (!cli.smoke || typeof name !== 'string' || typeof b64 !== 'string') throw new Error('smoke mode only');
    const dir = path.dirname(cli.screenshot || path.join(APP_ROOT, 'dist', 'smoke.png'));
    const p = path.join(dir, path.basename(name).replace(/[^\w.-]+/g, '_'));
    fs.mkdirSync(dir, { recursive: true }); fs.writeFileSync(p, Buffer.from(b64, 'base64')); return p;
  });

  app.on('second-instance', (_e, argv, workingDirectory) => {
    // Relative paths are relative to the second launch's directory, not to ours.
    const cwd = typeof workingDirectory === 'string' && workingDirectory ? workingDirectory : process.cwd();
    const files = argv.slice(1).filter((a) => typeof a === 'string' && !a.startsWith('-') && a !== '.')
      .map((a) => path.resolve(cwd, a))
      .filter((a) => { try { return fs.statSync(a).isFile(); } catch { return false; } });
    for (const f of files) openPath(f);
    if (win) { if (win.isMinimized()) win.restore(); win.focus(); }
  });

  function createWindow() {
    win = new BrowserWindow({
      width: cli.width, height: cli.height, minWidth: 900, minHeight: 600,
      show: !cli.smoke,
      skipTaskbar: !!cli.smoke,
      title: 'VibeView',
      backgroundColor: '#eef0f4',
      icon: path.join(APP_ROOT, 'build', 'icon.ico'),
      webPreferences: {
        preload: path.join(__dirname, 'preload.js'),
        contextIsolation: true,
        nodeIntegration: false,
        sandbox: true,
        spellcheck: false,
        backgroundThrottling: !cli.smoke,
      },
    });
    win.loadFile(path.join(APP_ROOT, 'renderer', 'index.html'));
    if (cli.smoke) {
      // A hidden window does not composite WebGL, so show it without focus, far off-screen.
      win.webContents.once('did-finish-load', () => { win.setPosition(-cli.width - 4000, 0); win.showInactive(); });
    }
    win.webContents.setWindowOpenHandler(({ url }) => { if (/^https?:/.test(url)) shell.openExternal(url); return { action: 'deny' }; });
    win.webContents.on('will-navigate', (e) => e.preventDefault());
    win.on('close', (e) => {
      if (win.__allowClose || cli.smoke) return;
      e.preventDefault();
      win.webContents.send('menu', 'app.quit-request');
    });
    ipcMain.removeHandler('window:close');
    ipcMain.handle('window:close', () => { win.__allowClose = true; win.close(); });
    win.on('closed', () => { win = null; });
    if (cli.smoke) {
      win.webContents.on('console-message', (_e, level, message) => process.stdout.write(`[console:${level}] ${message}\n`));
      setTimeout(() => { process.stdout.write('smoke-test: timed out\n'); app.exit(2); }, 90_000);
    }
  }

  app.whenReady().then(() => {
    app.setAppUserModelId('io.github.vibeview.windows');
    // The renderer needs no camera, microphone, notifications, geolocation, …
    session.defaultSession.setPermissionRequestHandler((_wc, _perm, cb) => cb(false));
    engine.start();
    refreshMenu();
    createWindow();
  });
  app.on('window-all-closed', () => { engine.stop(); app.quit(); });
  app.on('before-quit', () => engine.stop());
}
