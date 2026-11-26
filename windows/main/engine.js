'use strict';
// Spawns vibeview-engine.exe and speaks newline-delimited JSON over stdio (docs/WINDOWS_PROTOCOL.md).
const { spawn } = require('child_process');
const { EventEmitter } = require('events');
const fs = require('fs');
const path = require('path');

const DEFAULT_TIMEOUT_MS = 60_000;
// Methods that can legitimately run long. They are cancellable instead of timing out quickly.
const LONG_METHODS = new Set([
  'analysis.orbitalSurface', 'analysis.densitySurface', 'analysis.volumeSurface',
  'doc.open', 'lookup.suggest', 'lookup.structure', 'lookup.download', 'edit.apply', 'session.load', 'command.execute',
]);
const LONG_TIMEOUT_MS = 10 * 60_000;

function newestExe(root) {
  // ..\.build-*\{debug,release}\vibeview-engine.exe (also x86_64-unknown-windows-msvc subfolders).
  let best = null;
  let dirs = [];
  try { dirs = fs.readdirSync(root).filter((d) => d.startsWith('.build')); } catch { return null; }
  for (const d of dirs) {
    const candidates = [];
    for (const cfg of ['debug', 'release']) {
      candidates.push(path.join(root, d, cfg, 'vibeview-engine.exe'));
      candidates.push(path.join(root, d, 'x86_64-unknown-windows-msvc', cfg, 'vibeview-engine.exe'));
      candidates.push(path.join(root, d, 'aarch64-unknown-windows-msvc', cfg, 'vibeview-engine.exe'));
    }
    // SwiftPM 6.x with the swift-build backend: <scratch>\out\Products\<Debug|Release>-windows-<arch>\.
    const products = path.join(root, d, 'out', 'Products');
    let pdirs = [];
    try { pdirs = fs.readdirSync(products).filter((p) => /^(debug|release)-windows/i.test(p)); } catch { /* other layout */ }
    for (const p of pdirs) candidates.push(path.join(products, p, 'vibeview-engine.exe'));
    for (const c of candidates) {
      try {
        const st = fs.statSync(c);
        if (!best || st.mtimeMs > best.mtime) best = { path: c, mtime: st.mtimeMs };
      } catch { /* missing */ }
    }
  }
  return best ? best.path : null;
}

/** Engine path resolution order: env, packaged resources, windows/engine, newest repo build. */
function resolveEnginePath({ isPackaged, resourcesPath, appRoot }) {
  const env = process.env.VIBEVIEW_ENGINE;
  if (env && fs.existsSync(env)) return { command: env, args: [] };
  if (isPackaged && resourcesPath) {
    const p = path.join(resourcesPath, 'engine', 'vibeview-engine.exe');
    if (fs.existsSync(p)) return { command: p, args: [] };
  }
  const local = path.join(appRoot, 'engine', 'vibeview-engine.exe');
  if (fs.existsSync(local)) return { command: local, args: [] };
  const built = newestExe(path.resolve(appRoot, '..'));
  if (built) return { command: built, args: [] };
  return null;
}

function mockEngine(appRoot) {
  return { command: process.execPath, args: [path.join(appRoot, 'dev', 'mock-engine.js')], env: { ELECTRON_RUN_AS_NODE: '1' }, mock: true };
}

class EngineClient extends EventEmitter {
  /**
   * @param {{resolve: () => ({command, args, env?, mock?}|null), logDir: string}} opts
   */
  constructor(opts) {
    super();
    this.opts = opts;
    this.proc = null;
    this.nextId = 1;
    this.pending = new Map();
    this.buffer = '';
    this.restarts = 0;
    this.stopping = false;
    this.info = null;
    this.target = null;
    this.logStream = null;
    this.openLog();
  }

  openLog() {
    try {
      fs.mkdirSync(this.opts.logDir, { recursive: true });
      const stamp = new Date().toISOString().replace(/[:.]/g, '-');
      this.logPath = path.join(this.opts.logDir, `engine-${stamp}.log`);
      this.logStream = fs.createWriteStream(this.logPath, { flags: 'a' });
      // Keep the 10 newest logs.
      const old = fs.readdirSync(this.opts.logDir).filter((f) => f.startsWith('engine-')).sort();
      for (const f of old.slice(0, Math.max(0, old.length - 10))) {
        try { fs.unlinkSync(path.join(this.opts.logDir, f)); } catch { /* in use */ }
      }
    } catch { this.logStream = null; }
  }

  log(line) {
    if (this.logStream) this.logStream.write(`[${new Date().toISOString()}] ${line}\n`);
  }

  start() {
    this.target = this.opts.resolve();
    if (!this.target) {
      this.emit('status', { state: 'missing', message: 'vibeview-engine.exe was not found. Set VIBEVIEW_ENGINE or build the engine.' });
      return false;
    }
    this.log(`starting ${this.target.command} ${this.target.args.join(' ')}`);
    const env = { ...process.env, ...(this.target.env || {}) };
    let proc;
    try {
      proc = spawn(this.target.command, [...this.target.args, '--stdio'], {
        stdio: ['pipe', 'pipe', 'pipe'], windowsHide: true, env,
      });
    } catch (e) {
      this.emit('status', { state: 'failed', message: String(e.message || e) });
      return false;
    }
    this.proc = proc;
    this.buffer = '';
    proc.stdout.setEncoding('utf8');
    proc.stdout.on('data', (chunk) => this.onData(chunk));
    proc.stderr.setEncoding('utf8');
    proc.stderr.on('data', (chunk) => { for (const l of chunk.split(/\r?\n/)) if (l) this.log(`stderr: ${l}`); });
    proc.on('error', (e) => { this.log(`spawn error: ${e.message}`); });
    proc.on('exit', (code, signal) => this.onExit(proc, code, signal));
    proc.stdin.on('error', (e) => this.log(`stdin error: ${e.message}`));
    this.emit('status', { state: 'running', mock: !!this.target.mock, path: this.target.command });
    return true;
  }

  onData(chunk) {
    this.buffer += chunk;
    let nl;
    while ((nl = this.buffer.indexOf('\n')) >= 0) {
      const line = this.buffer.slice(0, nl).trim();
      this.buffer = this.buffer.slice(nl + 1);
      if (!line) continue;
      let msg;
      try { msg = JSON.parse(line); } catch {
        this.log(`unparseable stdout: ${line.slice(0, 500)}`);
        continue;
      }
      if (msg.event) {
        if (msg.event === 'engine.log') this.log(`engine.log ${msg.params?.level}: ${msg.params?.text}`);
        this.emit('event', msg.event, msg.params || {});
      } else if (msg.id != null && this.pending.has(msg.id)) {
        const p = this.pending.get(msg.id);
        this.pending.delete(msg.id);
        clearTimeout(p.timer);
        if (msg.error) p.reject(Object.assign(new Error(msg.error.message || msg.error.code), { code: msg.error.code || 'internal' }));
        else p.resolve(msg.result ?? {});
      }
    }
  }

  onExit(proc, code, signal) {
    if (proc !== this.proc) return;
    this.log(`engine exited code=${code} signal=${signal}`);
    this.proc = null;
    for (const [, p] of this.pending) {
      clearTimeout(p.timer);
      p.reject(Object.assign(new Error('The engine stopped while handling this request.'), { code: 'internal' }));
    }
    this.pending.clear();
    if (this.stopping) return;
    this.restarts += 1;
    if (this.restarts > 5) {
      this.emit('status', { state: 'failed', message: `The engine keeps crashing (exit code ${code}). See the log: ${this.logPath}` });
      return;
    }
    this.emit('status', { state: 'restarting', message: `The engine stopped unexpectedly (exit code ${code}) and was restarted. Open documents must be reopened.` });
    setTimeout(() => { if (!this.stopping) { this.start(); this.emit('restarted'); } }, 500 * this.restarts);
  }

  request(method, params = {}, { timeoutMs } = {}) {
    return new Promise((resolve, reject) => {
      if (!this.proc) {
        reject(Object.assign(new Error('The engine is not running.'), { code: 'not_installed' }));
        return;
      }
      const id = this.nextId++;
      const ms = timeoutMs ?? (LONG_METHODS.has(method) ? LONG_TIMEOUT_MS : DEFAULT_TIMEOUT_MS);
      const timer = setTimeout(() => {
        if (!this.pending.has(id)) return;
        this.pending.delete(id);
        this.write({ id: this.nextId++, method: 'cancel', params: { id } });
        reject(Object.assign(new Error(`${method} timed out after ${Math.round(ms / 1000)} s`), { code: 'timeout' }));
      }, ms);
      this.pending.set(id, { resolve, reject, timer, method });
      this.emit('request-id', id, method);
      this.write({ id, method, params });
    });
  }

  /** Returns the id that the next request will use (so the renderer can cancel it). */
  peekNextId() { return this.nextId; }

  cancel(id) {
    if (this.pending.has(id)) this.write({ id: this.nextId++, method: 'cancel', params: { id } });
  }

  write(obj) {
    if (!this.proc) return;
    try { this.proc.stdin.write(JSON.stringify(obj) + '\n'); } catch (e) { this.log(`write failed: ${e.message}`); }
  }

  stop() {
    this.stopping = true;
    if (this.proc) {
      try { this.proc.stdin.end(); } catch { /* closed */ }
      const p = this.proc;
      setTimeout(() => { try { p.kill(); } catch { /* gone */ } }, 1500);
    }
    if (this.logStream) this.logStream.end();
  }
}

module.exports = { EngineClient, resolveEnginePath, mockEngine };
