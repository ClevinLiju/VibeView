// Access to the preload bridge (window.vibeview).
const bridge = window.vibeview;
if (!bridge) throw new Error('VibeView must run inside its Electron shell (window.vibeview is missing).');

export const api = bridge;

/** Engine request; `opts.cancellable` gives a token through `opts.onToken` for api.cancel(token). */
export function request(method, params = {}, opts) {
  return bridge.request(method, params, opts).then((r) => {
    if (r && r.ok) return r.result;
    const e = (r && r.error) || {};
    const err = new Error(e.message || e.code || 'engine request failed');
    err.code = e.code || 'internal';
    throw err;
  });
}

/** Small typed helpers for frequent calls. */
export const engine = {
  info: () => request('engine.info'),
  newDoc: () => request('doc.new', {}),
  open: (path) => request('doc.open', { path, companions: true }),
  openText: (text, format, fileName) => request('doc.openText', { text, format, fileName }),
  close: (docId) => request('doc.close', { docId }),
  save: (docId, path, format = null) => request('doc.save', { docId, path, format }),
  molecule: (docId, frame = null) => request('doc.molecule', { docId, frame }),
  summary: (docId) => request('doc.summary', { docId }),
  undo: (docId) => request('doc.undo', { docId }),
  redo: (docId) => request('doc.redo', { docId }),
  result: (docId) => request('doc.result', { docId }),
  frames: (docId) => request('doc.frames', { docId }),
  edit: (docId, op) => request('edit.apply', { docId, op }),
  fragments: () => request('build.fragments', {}),
  measure: (docId, atoms) => request('analysis.measure', { docId, atoms }),
};
