// Tiny DOM helpers (no framework).
export function h(tag, attrs = {}, ...children) {
  const [name, ...classes] = tag.split('.');
  const el = document.createElement(name || 'div');
  if (classes.length) el.className = classes.join(' ');
  for (const [k, v] of Object.entries(attrs || {})) {
    if (v == null || v === false) continue;
    if (k === 'class') el.className += (el.className ? ' ' : '') + v;
    else if (k === 'style' && typeof v === 'object') Object.assign(el.style, v);
    else if (k.startsWith('on') && typeof v === 'function') el.addEventListener(k.slice(2).toLowerCase(), v);
    else if (k === 'dataset') Object.assign(el.dataset, v);
    else if (k === 'innerHTML' || k === 'textContent') el[k] = v;
    else if (k in el && typeof v !== 'string') el[k] = v;
    else if (k === 'value') el.value = v;
    else el.setAttribute(k, v === true ? '' : v);
  }
  for (const c of children.flat(Infinity)) {
    if (c == null || c === false) continue;
    el.append(c instanceof Node ? c : document.createTextNode(String(c)));
  }
  return el;
}
export const $ = (sel, root = document) => root.querySelector(sel);
export const $$ = (sel, root = document) => [...root.querySelectorAll(sel)];
export function clear(el) { while (el.firstChild) el.removeChild(el.firstChild); return el; }

export function fmt(x, digits = 4) {
  if (x == null || !Number.isFinite(x)) return '–';
  return Number(x).toFixed(digits);
}

export function decodeF32(b64) {
  if (!b64) return new Float32Array(0);
  const bin = atob(b64); const buf = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) buf[i] = bin.charCodeAt(i);
  return new Float32Array(buf.buffer);
}

/** Segmented control. options: [{value, label, title}] */
export function segmented(options, value, onChange, cls = '') {
  const root = h('div.segmented' + (cls ? '.' + cls : ''), { role: 'radiogroup' });
  const render = (v) => {
    for (const b of root.children) b.classList.toggle('on', b.dataset.value === String(v));
  };
  for (const o of options) {
    root.append(h('button', { type: 'button', dataset: { value: String(o.value) }, title: o.title || o.label, onclick: () => { render(o.value); onChange(o.value); } }, o.icon ? h('span.ico', { innerHTML: o.icon }) : null, o.label != null && !o.iconOnly ? o.label : null));
  }
  render(value);
  root.setValue = render;
  return root;
}

export function field(label, control, hint) {
  return h('div.field', {}, h('span.field-label', {}, label), control, hint ? h('span.hint', { style: { fontSize: '11px', color: 'var(--text-3)' } }, hint) : null);
}

export function select(options, value, onChange) {
  const s = h('select', { onchange: () => onChange(s.value) }, options.map((o) => h('option', { value: String(o.value ?? o), selected: String(o.value ?? o) === String(value) }, o.label ?? o)));
  return s;
}

/** Modal dialog. Returns {root, close}. */
export function modal(title, body, { width = 560, onClose, footer, cls = '' } = {}) {
  const backdrop = h('div.modal-backdrop');
  const close = () => { backdrop.remove(); document.removeEventListener('keydown', onKey, true); onClose && onClose(); };
  const onKey = (e) => { if (e.key === 'Escape') { e.stopPropagation(); close(); } };
  const dialog = h('div.modal' + (cls ? '.' + cls : ''), { role: 'dialog', 'aria-label': title, style: { width: width + 'px' } },
    h('div.modal-head', {}, h('h2', {}, title), h('button.icon-btn.close', { title: 'Close (Esc)', onclick: close, innerHTML: '&#x2715;' })),
    h('div.modal-body', {}, body),
    footer ? h('div.modal-foot', {}, footer) : null);
  backdrop.append(dialog);
  backdrop.addEventListener('mousedown', (e) => { if (e.target === backdrop) close(); });
  document.addEventListener('keydown', onKey, true);
  document.body.append(backdrop);
  setTimeout(() => { const f = dialog.querySelector('[autofocus], input, select, textarea, button.primary'); f && f.focus(); }, 0);
  return { root: dialog, close };
}

let toastHost = null;
export function toast(message, { kind = 'info', timeout = 4500, action } = {}) {
  if (!toastHost) { toastHost = h('div.toasts'); document.body.append(toastHost); }
  const t = h('div.toast.' + kind, {}, h('span', {}, message), action ? h('button.link', { onclick: () => { action.run(); t.remove(); } }, action.label) : null,
    h('button.icon-btn', { onclick: () => t.remove(), innerHTML: '&#x2715;', title: 'Dismiss' }));
  toastHost.append(t);
  if (timeout) setTimeout(() => t.remove(), timeout);
  return t;
}
