// Command console (Ctrl+Shift+C): history, Tab completion via command.complete, coloured output.
import { h, $, clear } from './dom.js';
import { request, api } from './api.js';

export function buildConsole(app) {
  const root = $('#console');
  const out = h('div.console-out');
  const input = h('input', { type: 'text', spellcheck: false, placeholder: 'Type a command (help lists them). Tab completes, ↑/↓ browse history.', 'aria-label': 'Command' });
  const pop = h('div.completions', { hidden: true });
  const head = h('div.tabs', {}, h('span', { style: { fontWeight: 600, padding: '0 4px' } }, 'Console'), h('span.grow'),
    h('button.btn.small', { onclick: () => clear(out) }, 'Clear'),
    h('button.icon-btn', { title: 'Hide console (Ctrl+Shift+C)', innerHTML: '&#x2715;', onclick: () => app.command('panel.console') }));
  root.style.position = 'relative';
  root.append(head, out, pop, h('div.console-in', {}, h('span.prompt', {}, '›'), input));
  let history = [];
  try { history = JSON.parse(localStorage.getItem('vibeview.console.history') || '[]'); } catch { history = []; }
  let hIdx = history.length;
  let comps = []; let compIdx = 0; let compFrom = 0;

  const print = (text, cls = '') => { out.append(h('div' + (cls ? '.' + cls : ''), {}, text)); out.scrollTop = out.scrollHeight; };
  print('VibeView console. Commands act on the active document; try "help".', 'dim');

  async function run(line) {
    if (!line.trim()) return;
    history = [...history.filter((x) => x !== line), line].slice(-200);
    try { localStorage.setItem('vibeview.console.history', JSON.stringify(history)); } catch { /* storage off */ }
    hIdx = history.length;
    print(`› ${line}`, 'cmd');
    const d = app.active;
    if (!d) { print('No document.', 'error'); return; }
    try {
      const r = await request('command.execute', { docId: d.docId, line });
      for (const res of r.results || []) {
        for (const m of res.messages || []) print(m.text, m.level === 'error' ? 'error' : m.level === 'warning' ? 'warning' : m.level === 'success' ? 'success' : '');
        if (!res.success && !(res.messages || []).length) print(`${res.command}: failed`, 'error');
      }
      if (r.molecule) {
        const s = r.summary || await request('doc.summary', { docId: d.docId });
        app.applyMolecule(d, r.molecule, s, { keepSelection: true });
        d.dirty = true; app.updateTitle();
      } else if (r.summary) { d.summary = r.summary; app.emit('doc', d); }
      if (r.view) app.applyViewChange(r.view);
      // Files opened by `open` are new engine documents.
      for (const s of r.opened || []) {
        const m = await request('doc.molecule', { docId: s.docId });
        const nd = app.makeDoc(s, m, s.path);
        app.activate(nd, { fit: true });
        if (s.path) api.addRecentFile(s.path);
      }
      // jobStarted skips the busy pill when job.finished already arrived (very fast or failed jobs).
      for (const jid of r.jobs || []) app.jobStarted(jid, { title: `xtb (console) · ${d.name}`, docId: d.docId }, 'xtb running…');
    } catch (e) { print(e.message, 'error'); }
  }

  function hideComps() { pop.hidden = true; comps = []; }
  function showComps() {
    clear(pop);
    comps.forEach((c, i) => pop.append(h('div' + (i === compIdx ? '.on' : ''), { onmousedown: (e) => { e.preventDefault(); compIdx = i; accept(); } }, c)));
    pop.hidden = comps.length < 2;
  }
  function accept() {
    const c = comps[compIdx]; if (c == null) return;
    const v = input.value; const cur = input.selectionStart;
    input.value = v.slice(0, compFrom) + c + v.slice(cur);
    const pos = compFrom + c.length; input.setSelectionRange(pos, pos);
    hideComps();
  }
  async function complete() {
    const d = app.active; if (!d) return;
    try {
      const r = await request('command.complete', { docId: d.docId, line: input.value, cursor: input.selectionStart });
      comps = r.completions || []; compFrom = r.replaceFrom ?? input.selectionStart; compIdx = 0;
      if (comps.length === 1) accept();
      else if (comps.length > 1) {
        // extend to the common prefix first
        const pre = comps.reduce((p, c) => { let i = 0; while (i < p.length && i < c.length && p[i].toLowerCase() === c[i].toLowerCase()) i++; return p.slice(0, i); });
        const typed = input.value.slice(compFrom, input.selectionStart);
        if (pre.length > typed.length) { const v = input.value; input.value = v.slice(0, compFrom) + pre + v.slice(input.selectionStart); const p = compFrom + pre.length; input.setSelectionRange(p, p); }
        showComps();
      }
    } catch (e) { print(e.message, 'error'); }
  }

  input.addEventListener('keydown', (e) => {
    if (e.key === 'Tab') { e.preventDefault(); if (!pop.hidden) { compIdx = (compIdx + (e.shiftKey ? comps.length - 1 : 1)) % comps.length; showComps(); } else complete(); return; }
    if (!pop.hidden) {
      if (e.key === 'ArrowDown') { e.preventDefault(); compIdx = (compIdx + 1) % comps.length; showComps(); return; }
      if (e.key === 'ArrowUp') { e.preventDefault(); compIdx = (compIdx + comps.length - 1) % comps.length; showComps(); return; }
      if (e.key === 'Enter') { e.preventDefault(); accept(); return; }
      if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); hideComps(); return; }
    }
    if (e.key === 'Enter') { const line = input.value; input.value = ''; run(line); return; }
    if (e.key === 'ArrowUp') { e.preventDefault(); if (hIdx > 0) { hIdx--; input.value = history[hIdx]; } return; }
    if (e.key === 'ArrowDown') { e.preventDefault(); if (hIdx < history.length - 1) { hIdx++; input.value = history[hIdx]; } else { hIdx = history.length; input.value = ''; } return; }
    if (e.key === 'Escape') { app.viewport.renderer.domElement.focus(); }
  });
  input.addEventListener('blur', () => setTimeout(hideComps, 100));
  app.consoleFocus = () => setTimeout(() => input.focus(), 0);
  app.consoleRun = run;
}
