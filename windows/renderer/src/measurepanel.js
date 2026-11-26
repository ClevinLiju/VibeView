// Measurements panel: floats at the top right of the viewer while the document has measurements or the
// Gauge tool is active. Large values, editable (moves the smaller side of the structure), removable.
import { h, $, clear } from './dom.js';

export function buildMeasurePanel(app) {
  const wrap = $('#viewport-wrap');
  const list = h('div.mp-list');
  const head = h('div.mp-head', {}, h('span', {}, 'Measurements'), h('span.grow'),
    h('button.link', { title: 'Remove all measurements', onclick: () => clearAll() }, 'Clear'));
  const hint = h('div.mp-hint');
  const panel = h('div.measure-panel', { hidden: true }, head, list, hint);
  wrap.append(panel);

  const clearAll = () => {
    const d = app.active; if (!d) return;
    for (let k = d.measurements.length - 1; k >= 0; k--) app.removeMeasurement(k);
  };
  const label = (d, m) => m.atoms.map((i) => `${d.molecule.atoms[i]?.symbol ?? '?'}${i + 1}`).join('–');

  const render = () => {
    const d = app.active;
    const ms = d ? d.measurements : [];
    const gauge = app.tool === 'gauge';
    panel.hidden = !d || (!ms.length && !gauge);
    if (panel.hidden) return;
    clear(list);
    ms.forEach((m, k) => {
      const unit = m.kind === 'distance' ? 'Å' : '°';
      // Plain text (not type=number) so the value always shows a decimal point; ',' is accepted as '.'.
      const input = h('input.mp-value', {
        type: 'text', inputmode: 'decimal', spellcheck: false, dataset: { decimal: '1' },
        value: m.value.toFixed(m.kind === 'distance' ? 3 : 1), title: 'Type a new value and press Enter to move the smaller side',
      });
      const commit = () => {
        const v = Number(input.value.trim().replace(',', '.'));
        if (Number.isFinite(v) && input.value.trim() !== '') app.setMeasurementValue(m, v);
        else input.value = m.value.toFixed(m.kind === 'distance' ? 3 : 1);
      };
      input.addEventListener('change', commit);
      input.addEventListener('keydown', (e) => e.stopPropagation());
      list.append(h('div.mp-row', {},
        h('span.mp-kind', { title: m.kind }, m.kind === 'distance' ? 'd' : m.kind === 'angle' ? '∠' : 'φ'),
        h('span.mp-atoms', { title: label(d, m) }, label(d, m)),
        input, h('span.mp-unit', {}, unit),
        h('button.icon-btn', { title: 'Remove', innerHTML: '&#x2715;', onclick: () => app.removeMeasurement(k) })));
    });
    hint.textContent = gauge
      ? (ms.length ? 'Click 2, 3 or 4 atoms to add more. Esc leaves the Gauge tool.' : 'Click 2, 3 or 4 atoms for a distance, angle or dihedral.')
      : '';
    hint.hidden = !hint.textContent;
  };
  // Re-render on edits, but not while the user is typing in one of the value fields.
  const soon = () => { if (!panel.contains(document.activeElement)) render(); };
  app.on('doc', render);
  app.on('tool', render);
  app.on('measurements', render);
  app.on('molecule', soon);
  render();
}
