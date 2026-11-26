// Command palette (Ctrl+K): fuzzy search over commands, elements, fragments and recent files.
import { h, clear } from './dom.js';
import { ELEMENTS } from './elements.js';
import { api } from './api.js';
import { escapeHTML } from './app.js';

/** Subsequence fuzzy match. Returns {score, marks} or null. */
export function fuzzy(query, text) {
  const q = query.toLowerCase(), t = text.toLowerCase();
  if (!q) return { score: 0, marks: [] };
  const direct = t.indexOf(q);
  if (direct >= 0) return { score: 100 - direct + (direct === 0 ? 50 : 0) - t.length * 0.1, marks: [...Array(q.length).keys()].map((k) => k + direct) };
  let ti = 0, score = 0, prev = -2; const marks = [];
  for (const c of q) {
    const j = t.indexOf(c, ti);
    if (j < 0) return null;
    marks.push(j);
    score += j === prev + 1 ? 6 : (j === 0 || /[\s\-_/(]/.test(t[j - 1]) ? 4 : 1);
    prev = j; ti = j + 1;
  }
  return { score: score - t.length * 0.05, marks };
}

function highlight(text, marks) {
  const set = new Set(marks); let out = '';
  [...text].forEach((c, i) => { out += set.has(i) ? `<mark>${escapeHTML(c)}</mark>` : escapeHTML(c); });
  return out;
}

export async function openPalette(app, catalog) {
  document.querySelector('.palette')?.remove();
  const recent = await api.recentFiles().catch(() => []);
  const items = [
    ...catalog.map((c) => ({ cat: c.category, label: c.title, kbd: c.key, run: () => app.command(c.id), keywords: c.keywords || '' })),
    ...ELEMENTS.slice(1).map((e) => ({ cat: 'Element', label: `${e.symbol} · ${e.name}`, run: () => app.setPayload({ kind: 'element', z: e.z }) })),
    ...app.fragments.map((f) => ({ cat: 'Fragment', label: f.name, run: () => app.setPayload({ kind: 'fragment', id: f.id, name: f.name }) })),
    ...recent.map((p) => ({ cat: 'Recent', label: p.split(/[\\/]/).pop(), keywords: p, run: () => app.openPath(p) })),
  ];
  const input = h('input', { type: 'text', placeholder: 'Search commands, elements, fragments, recent files…', spellcheck: false });
  const list = h('div.items');
  const root = h('div.palette', { role: 'dialog' }, input, list);
  const backdrop = h('div.modal-backdrop', { style: { background: 'rgba(10,12,16,0.12)' } });
  document.body.append(backdrop, root);
  let shown = []; let idx = 0;
  const close = () => { root.remove(); backdrop.remove(); };
  backdrop.addEventListener('mousedown', close);
  const render = () => {
    const q = input.value.trim();
    const scored = [];
    for (const it of items) {
      const m = fuzzy(q, it.label) || (it.keywords && fuzzy(q, it.keywords) ? { score: fuzzy(q, it.keywords).score - 20, marks: [] } : null);
      if (m) scored.push({ it, m });
    }
    if (q) scored.sort((a, b) => b.m.score - a.m.score);
    shown = (q ? scored : scored.filter((s) => s.it.cat !== 'Element')).slice(0, 60);
    idx = Math.min(idx, Math.max(0, shown.length - 1));
    clear(list);
    shown.forEach(({ it, m }, i) => list.append(h('div.item' + (i === idx ? '.on' : ''), { onmousemove: () => { if (idx !== i) { idx = i; render(); } }, onmousedown: (e) => { e.preventDefault(); idx = i; go(); } },
      h('span.cat', {}, it.cat), h('span.label', { innerHTML: highlight(it.label, m.marks) }), it.kbd ? h('span.kbd', {}, it.kbd) : null)));
    if (!shown.length) list.append(h('div.empty', {}, 'No matches'));
    list.children[idx]?.scrollIntoView({ block: 'nearest' });
  };
  const go = () => { const s = shown[idx]; close(); if (s) s.it.run(); };
  input.addEventListener('input', () => { idx = 0; render(); });
  input.addEventListener('keydown', (e) => {
    if (e.key === 'ArrowDown') { e.preventDefault(); idx = Math.min(shown.length - 1, idx + 1); render(); }
    else if (e.key === 'ArrowUp') { e.preventDefault(); idx = Math.max(0, idx - 1); render(); }
    else if (e.key === 'Enter') { e.preventDefault(); go(); }
    else if (e.key === 'Escape') { e.preventDefault(); close(); }
  });
  render();
  input.focus();
}
