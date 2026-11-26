'use strict';
// Calculate > Install xtb…: downloads the official Windows build of xtb (github.com/grimme-lab/xtb, LGPL-3.0),
// verifies its SHA-256, unpacks it to %APPDATA%\VibeView\xtb\{bin,share} and test-runs it. The engine searches that
// folder (MolCompute ProgramLocator.managedDirectory) and sets XTBPATH to its share\xtb, so nothing else is configured.
// Windows port of the macOS installer step (scripts/install.sh install_xtb).
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { execFile } = require('child_process');

const REPO_API = 'https://api.github.com/repos/grimme-lab/xtb/releases/latest';
const ASSET_RE = /^xtb-[\w.]+-windows-x86_64(?:-[\w]+)?\.zip$/i;
// Used when the GitHub API can't be reached or the latest release has no Windows build (checked 2026-11-26).
const PINNED = {
  version: '6.8.0',
  name: 'xtb-6.8.0-windows-x86_64-openblas.zip',
  url: 'https://github.com/grimme-lab/xtb/releases/download/v6.8.0/xtb-6.8.0-windows-x86_64-openblas.zip',
  sha256: 'abd7f74d60908925a7e88a030f83d448253ff4e087451f9b13aeda755eb7b98d',
  size: 37581809,
};
const UA = 'VibeView-Windows';

function managedRoot(appDataDir) { return path.join(appDataDir, 'VibeView', 'xtb'); }
function managedExe(appDataDir) { return path.join(managedRoot(appDataDir), 'bin', 'xtb.exe'); }

/** Version line of an installed xtb (`xtb --version`), or null when it doesn't run. */
function xtbVersion(exe, timeoutMs = 20000) {
  return new Promise((resolve) => {
    const share = path.join(path.dirname(path.dirname(exe)), 'share', 'xtb');
    const env = { ...process.env };
    if (fs.existsSync(path.join(share, 'param_gfn2-xtb.txt'))) env.XTBPATH = share;
    execFile(exe, ['--version'], { env, timeout: timeoutMs, windowsHide: true, cwd: path.dirname(exe) }, (err, stdout, stderr) => {
      const m = /xtb version\s+([\w.\-]+)/i.exec(`${stdout}\n${stderr}`);
      resolve(m ? m[1] : null);
    });
  });
}

/** {installed, path, version} for the copy VibeView manages. */
async function status(appDataDir) {
  const exe = managedExe(appDataDir);
  if (!fs.existsSync(exe)) return { installed: false, path: null, version: null, folder: managedRoot(appDataDir) };
  return { installed: true, path: exe, version: await xtbVersion(exe), folder: managedRoot(appDataDir) };
}

async function fetchJSON(net, url) {
  const r = await net.fetch(url, { headers: { 'User-Agent': UA, Accept: 'application/vnd.github+json' } });
  if (!r.ok) throw new Error(`GitHub answered ${r.status}`);
  return r.json();
}

/** The asset to download: the latest release's Windows zip with its SHA-256 (API digest or .sha256 asset), else PINNED. */
async function pickRelease(net, log) {
  try {
    const rel = await fetchJSON(net, REPO_API);
    const asset = (rel.assets || []).find((a) => ASSET_RE.test(a.name));
    if (!asset) { log(`the latest xtb release (${rel.tag_name}) has no Windows build; using ${PINNED.version}`); return PINNED; }
    let sha = typeof asset.digest === 'string' && /^sha256:[0-9a-f]{64}$/i.test(asset.digest) ? asset.digest.slice(7).toLowerCase() : null;
    if (!sha) {
      const sumAsset = (rel.assets || []).find((a) => a.name === asset.name + '.sha256');
      if (sumAsset) {
        const r = await net.fetch(sumAsset.browser_download_url, { headers: { 'User-Agent': UA } });
        if (r.ok) sha = (/[0-9a-f]{64}/i.exec(await r.text()) || [])[0]?.toLowerCase() || null;
      }
    }
    if (!sha) {
      if (asset.name === PINNED.name) return PINNED;
      log(`no checksum published for ${asset.name}; using ${PINNED.version}`);
      return PINNED;
    }
    return { version: String(rel.tag_name || '').replace(/^v/, ''), name: asset.name, url: asset.browser_download_url, sha256: sha, size: asset.size };
  } catch (e) {
    log(`could not query GitHub (${e.message}); using xtb ${PINNED.version}`);
    return PINNED;
  }
}

async function download(net, rel, file, onProgress, signal) {
  const r = await net.fetch(rel.url, { headers: { 'User-Agent': UA }, signal });
  if (!r.ok || !r.body) throw new Error(`download failed (HTTP ${r.status})`);
  const total = Number(r.headers.get('content-length')) || rel.size || 0;
  const hash = crypto.createHash('sha256');
  const out = fs.createWriteStream(file);
  let received = 0;
  const reader = r.body.getReader();
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      hash.update(value);
      received += value.length;
      if (!out.write(Buffer.from(value))) await new Promise((res) => out.once('drain', res));
      onProgress({ phase: 'download', received, total });
    }
  } finally {
    await new Promise((res) => out.end(res));
  }
  return hash.digest('hex');
}

function run(exe, args, opts = {}) {
  return new Promise((resolve, reject) => {
    execFile(exe, args, { windowsHide: true, timeout: 180000, ...opts }, (err, stdout, stderr) => {
      if (err) reject(new Error(`${path.basename(exe)} failed: ${(stderr || err.message).toString().trim().slice(0, 400)}`)); else resolve(stdout);
    });
  });
}

/** Unpacks a .zip with Windows' own tar.exe (bsdtar, Windows 10 1803+), else PowerShell Expand-Archive. */
async function unzip(zip, dest) {
  const sys = process.env.SystemRoot || 'C:\\Windows';
  const tar = path.join(sys, 'System32', 'tar.exe');
  if (fs.existsSync(tar)) {
    try { await run(tar, ['-xf', zip, '-C', dest]); return; } catch { /* fall through */ }
  }
  const ps = path.join(sys, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe');
  const q = (s) => `'${s.replace(/'/g, "''")}'`;
  await run(ps, ['-NoProfile', '-NonInteractive', '-Command', `Expand-Archive -LiteralPath ${q(zip)} -DestinationPath ${q(dest)} -Force`]);
}

/** The folder holding bin\xtb.exe inside the unpacked archive (stage\ in current releases). */
function findStage(root, depth = 0) {
  if (fs.existsSync(path.join(root, 'bin', 'xtb.exe'))) return root;
  if (depth >= 3) return null;
  for (const e of fs.readdirSync(root, { withFileTypes: true })) {
    if (!e.isDirectory()) continue;
    const s = findStage(path.join(root, e.name), depth + 1);
    if (s) return s;
  }
  return null;
}

/**
 * Downloads, verifies and installs xtb. `onProgress({phase, received?, total?, message?})`. Resolves to {path, version, folder}.
 * Throws with a readable message; a failed install leaves any previous copy in place.
 */
async function install({ net, appDataDir, onProgress = () => {}, signal } = {}) {
  const log = (message) => onProgress({ phase: 'note', message });
  const base = path.join(appDataDir, 'VibeView');
  fs.mkdirSync(base, { recursive: true });
  const work = fs.mkdtempSync(path.join(base, 'xtb-download-'));
  try {
    onProgress({ phase: 'resolve', message: 'Finding the latest xtb release…' });
    const rel = await pickRelease(net, log);
    onProgress({ phase: 'download', received: 0, total: rel.size || 0, message: `Downloading ${rel.name}…` });
    const zip = path.join(work, 'xtb.zip');
    const got = await download(net, rel, zip, onProgress, signal);
    if (got !== rel.sha256) throw new Error(`checksum mismatch for ${rel.name} (expected ${rel.sha256}, got ${got}); not installed`);
    onProgress({ phase: 'unpack', message: 'Checksum verified. Unpacking…' });
    const x = path.join(work, 'x');
    fs.mkdirSync(x);
    await unzip(zip, x);
    const stage = findStage(x);
    if (!stage) throw new Error('unexpected archive layout (no bin\\xtb.exe); not installed');
    // Assemble the new copy next to the old one, test it, then swap.
    const next = path.join(work, 'xtb');
    fs.mkdirSync(next);
    for (const sub of ['bin', 'share']) if (fs.existsSync(path.join(stage, sub))) fs.cpSync(path.join(stage, sub), path.join(next, sub), { recursive: true });
    onProgress({ phase: 'test', message: 'Testing xtb…' });
    const version = await xtbVersion(path.join(next, 'bin', 'xtb.exe'));
    if (!version) throw new Error('the downloaded xtb does not run on this computer; not installed');
    const dest = managedRoot(appDataDir);
    const old = dest + '.old';
    fs.rmSync(old, { recursive: true, force: true });
    if (fs.existsSync(dest)) fs.renameSync(dest, old);
    try { fs.renameSync(next, dest); } catch (e) { if (fs.existsSync(old)) fs.renameSync(old, dest); throw e; }
    fs.rmSync(old, { recursive: true, force: true });
    onProgress({ phase: 'done', message: `Installed xtb ${version}` });
    return { path: managedExe(appDataDir), version, folder: dest, release: rel.version };
  } finally {
    fs.rmSync(work, { recursive: true, force: true });
  }
}

function uninstall(appDataDir) {
  fs.rmSync(managedRoot(appDataDir), { recursive: true, force: true });
  return { installed: false };
}

module.exports = { install, uninstall, status, managedExe, managedRoot, PINNED, ASSET_RE, _test: { findStage, pickRelease, unzip } };
