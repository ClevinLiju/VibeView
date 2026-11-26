// Canvas charts drawn by hand: spectra (sticks + broadened curve), line profiles, orbital level diagrams.

function css(name) { return getComputedStyle(document.documentElement).getPropertyValue(name).trim() || '#888'; }

function niceStep(range, target = 6) {
  const raw = range / target; const p = Math.pow(10, Math.floor(Math.log10(raw))); const f = raw / p;
  return (f < 1.5 ? 1 : f < 3 ? 2 : f < 7 ? 5 : 10) * p;
}

/** Sets the canvas backing store to its CSS size × DPR and returns a 2D context in CSS pixels. */
function prepare(canvas) {
  const dpr = window.devicePixelRatio || 1;
  const w = Math.max(10, canvas.clientWidth), hgt = Math.max(10, canvas.clientHeight);
  if (canvas.width !== Math.round(w * dpr) || canvas.height !== Math.round(hgt * dpr)) { canvas.width = Math.round(w * dpr); canvas.height = Math.round(hgt * dpr); }
  const ctx = canvas.getContext('2d');
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  ctx.clearRect(0, 0, w, hgt);
  return { ctx, w, h: hgt };
}

export class XYChart {
  /** opts: {onPick(stick), xLabel, yLabel} */
  constructor(canvas, opts = {}) {
    this.canvas = canvas; this.opts = opts;
    this.data = null; this.selected = null; this.hoverX = null;
    canvas.addEventListener('mousemove', (e) => { this.hoverX = e.offsetX; this.hoverY = e.offsetY; this.draw(); });
    canvas.addEventListener('mouseleave', () => { this.hoverX = null; this.draw(); });
    canvas.addEventListener('click', (e) => { const s = this.stickAt(e.offsetX); if (s && this.opts.onPick) this.opts.onPick(s); });
    this.ro = new ResizeObserver(() => this.draw());
    this.ro.observe(canvas);
  }
  /**
   * data: {x: Float32Array, y: Float32Array, sticks: [{x, height, label, sourceIndex}], xLabel, yLabel, reversed, line: bool, markers: bool,
   *   yRange: [lo, hi] (fixed y axis, e.g. [0, 105] for %T), baseline: y the sticks and the fill start from (default 0; 100 for %T),
   *   sticksAbsolute: bool (draw stick heights as given instead of scaling them to the curve maximum)}
   */
  set(data) { this.data = data; this.draw(); }
  select(sourceIndex) { this.selected = sourceIndex; this.draw(); }

  bounds() {
    const d = this.data;
    let xmin = Infinity, xmax = -Infinity, ymax = 0, ymin = 0;
    const xs = d.x || [], ys = d.y || [];
    for (let i = 0; i < xs.length; i++) { xmin = Math.min(xmin, xs[i]); xmax = Math.max(xmax, xs[i]); ymax = Math.max(ymax, ys[i]); ymin = Math.min(ymin, ys[i]); }
    for (const s of d.sticks || []) { xmin = Math.min(xmin, s.x); xmax = Math.max(xmax, s.x); }
    if (d.xRange) [xmin, xmax] = d.xRange;
    if (!Number.isFinite(xmin)) { xmin = 0; xmax = 1; }
    if (xmax - xmin < 1e-9) { xmin -= 1; xmax += 1; }
    const stickMax = Math.max(0, ...(d.sticks || []).map((s) => s.height));
    return { xmin, xmax, ymin, ymax: ymax || 1, stickMax: stickMax || 1 };
  }

  layout() {
    const { w, h } = { w: this.canvas.clientWidth, h: this.canvas.clientHeight };
    const L = 58, R = 14, T = 12, B = 36;
    return { L, R, T, B, pw: Math.max(10, w - L - R), ph: Math.max(10, h - T - B) };
  }

  xToPx(x, b, lay) {
    const t = (x - b.xmin) / (b.xmax - b.xmin);
    return lay.L + (this.data.reversed ? 1 - t : t) * lay.pw;
  }
  pxToX(px, b, lay) {
    let t = (px - lay.L) / lay.pw; if (this.data.reversed) t = 1 - t;
    return b.xmin + t * (b.xmax - b.xmin);
  }

  stickAt(px) {
    if (!this.data?.sticks?.length) return null;
    const b = this.bounds(), lay = this.layout();
    let best = null, bd = 8;
    for (const s of this.data.sticks) { const d = Math.abs(this.xToPx(s.x, b, lay) - px); if (d < bd) { bd = d; best = s; } }
    return best;
  }

  draw() {
    const { ctx, w, h } = prepare(this.canvas);
    const d = this.data;
    const text = css('--text-2'), grid = css('--border'), accent = css('--accent');
    if (!d) { ctx.fillStyle = text; ctx.font = '12px "Segoe UI"'; ctx.textAlign = 'center'; ctx.fillText('No data', w / 2, h / 2); return; }
    const b = this.bounds(), lay = this.layout();
    const hasCurve = !!(d.x && d.x.length);
    const y0 = d.yRange ? d.yRange[0] : Math.min(0, b.ymin);
    const base = d.baseline ?? 0;
    const yScale = (y, max) => lay.T + lay.ph - ((y - y0) / (max - y0)) * lay.ph;
    // grid + axes
    ctx.font = '11px "Segoe UI", sans-serif'; ctx.fillStyle = text; ctx.strokeStyle = grid; ctx.lineWidth = 1;
    const step = niceStep(b.xmax - b.xmin, Math.max(3, Math.floor(lay.pw / 80)));
    ctx.textAlign = 'center'; ctx.textBaseline = 'top';
    for (let x = Math.ceil(b.xmin / step) * step; x <= b.xmax + 1e-9; x += step) {
      const px = this.xToPx(x, b, lay);
      ctx.beginPath(); ctx.moveTo(px + 0.5, lay.T); ctx.lineTo(px + 0.5, lay.T + lay.ph); ctx.stroke();
      ctx.fillText(Math.abs(step) >= 1 ? x.toFixed(0) : x.toFixed(Math.max(0, -Math.floor(Math.log10(step)))), px, lay.T + lay.ph + 4);
    }
    const ymaxCurve = d.yRange ? d.yRange[1] : hasCurve ? b.ymax * 1.08 : b.stickMax * 1.08;
    const ystep = niceStep(ymaxCurve - y0, 4);
    ctx.textAlign = 'right'; ctx.textBaseline = 'middle';
    for (let y = Math.ceil(y0 / ystep) * ystep; y <= ymaxCurve + 1e-9; y += ystep) {
      const py = yScale(y, ymaxCurve);
      ctx.globalAlpha = 0.5; ctx.beginPath(); ctx.moveTo(lay.L, py + 0.5); ctx.lineTo(lay.L + lay.pw, py + 0.5); ctx.stroke(); ctx.globalAlpha = 1;
      ctx.fillText(Math.abs(ystep) >= 1 ? y.toFixed(0) : y.toPrecision(2), lay.L - 6, py);
    }
    ctx.strokeStyle = css('--border-strong'); ctx.strokeRect(lay.L + 0.5, lay.T + 0.5, lay.pw, lay.ph);
    ctx.textAlign = 'center'; ctx.textBaseline = 'bottom'; ctx.fillText(d.xLabel || '', lay.L + lay.pw / 2, h - 2);
    ctx.save(); ctx.translate(12, lay.T + lay.ph / 2); ctx.rotate(-Math.PI / 2); ctx.textBaseline = 'middle'; ctx.fillText(d.yLabel || '', 0, 0); ctx.restore();
    ctx.save(); ctx.beginPath(); ctx.rect(lay.L, lay.T, lay.pw, lay.ph); ctx.clip();
    // sticks (scaled to the curve height so both read together)
    const sticks = d.sticks || [];
    const stickScale = hasCurve && !d.sticksAbsolute ? (b.ymax / b.stickMax) : 1;
    for (const s of sticks) {
      const px = this.xToPx(s.x, b, lay);
      const on = this.selected != null && s.sourceIndex === this.selected;
      ctx.strokeStyle = on ? css('--err') : (d.stickColor || 'rgba(120,126,138,0.85)'); ctx.lineWidth = on ? 2.5 : 1.3;
      ctx.beginPath(); ctx.moveTo(px, yScale(base, ymaxCurve)); ctx.lineTo(px, yScale(s.height * stickScale, ymaxCurve)); ctx.stroke();
    }
    // curve
    if (hasCurve) {
      ctx.strokeStyle = accent; ctx.lineWidth = 1.8; ctx.beginPath();
      for (let i = 0; i < d.x.length; i++) { const px = this.xToPx(d.x[i], b, lay), py = yScale(d.y[i], ymaxCurve); i ? ctx.lineTo(px, py) : ctx.moveTo(px, py); }
      ctx.stroke();
      if (d.markers) {
        ctx.fillStyle = accent;
        for (let i = 0; i < d.x.length; i++) {
          const px = this.xToPx(d.x[i], b, lay), py = yScale(d.y[i], ymaxCurve);
          const on = this.selected === i;
          ctx.beginPath(); ctx.arc(px, py, on ? 5 : 3, 0, Math.PI * 2); ctx.fillStyle = on ? css('--err') : accent; ctx.fill();
        }
      }
      if (!d.line) {
        ctx.globalAlpha = 0.12; ctx.fillStyle = accent; ctx.lineTo(this.xToPx(d.x[d.x.length - 1], b, lay), yScale(base, ymaxCurve)); ctx.lineTo(this.xToPx(d.x[0], b, lay), yScale(base, ymaxCurve)); ctx.closePath(); ctx.fill(); ctx.globalAlpha = 1;
      }
    }
    ctx.restore();
    // hover readout
    if (this.hoverX != null && this.hoverX > lay.L && this.hoverX < lay.L + lay.pw) {
      ctx.strokeStyle = css('--text-3'); ctx.setLineDash([3, 3]); ctx.beginPath(); ctx.moveTo(this.hoverX + 0.5, lay.T); ctx.lineTo(this.hoverX + 0.5, lay.T + lay.ph); ctx.stroke(); ctx.setLineDash([]);
      const x = this.pxToX(this.hoverX, b, lay);
      const s = this.stickAt(this.hoverX);
      const label = s ? `${s.label || s.x.toFixed(1)} · ${s.height.toPrecision(4)}` : x.toFixed(1);
      ctx.font = '11px "Segoe UI"'; const tw = ctx.measureText(label).width + 10;
      const bx = Math.min(this.hoverX + 6, lay.L + lay.pw - tw);
      ctx.fillStyle = css('--raised'); ctx.strokeStyle = css('--border'); ctx.fillRect(bx, lay.T + 4, tw, 18); ctx.strokeRect(bx + 0.5, lay.T + 4.5, tw, 18);
      ctx.fillStyle = css('--text'); ctx.textAlign = 'left'; ctx.textBaseline = 'middle'; ctx.fillText(label, bx + 5, lay.T + 13);
    }
  }
}

/** Orbital energy-level diagram. columns: analysis.orbitals columns. onPick(level, column). */
export class LevelDiagram {
  constructor(canvas, onPick) {
    this.canvas = canvas; this.onPick = onPick; this.columns = []; this.selected = null; this.hits = [];
    this.window = null; // [eMin, eMax] in eV
    canvas.addEventListener('click', (e) => { const hit = this.hitAt(e.offsetX, e.offsetY); if (hit) this.onPick(hit.level, hit.column); });
    canvas.addEventListener('mousemove', (e) => { const hit = this.hitAt(e.offsetX, e.offsetY); canvas.title = hit ? `${hit.label}: ${hit.level.energyEV.toFixed(3)} eV (${hit.level.energy.toFixed(5)} Eh), occ ${hit.level.occupation}` : ''; this.hover = hit; this.draw(); });
    canvas.addEventListener('wheel', (e) => { e.preventDefault(); this.zoom(Math.exp(e.deltaY * 0.001)); }, { passive: false });
    this.ro = new ResizeObserver(() => this.draw()); this.ro.observe(canvas);
  }
  set(columns) {
    this.columns = columns || [];
    // Default window: HOMO-6 … LUMO+6 levels
    const all = this.columns.flatMap((c) => c.levels);
    const homo = all.find((l) => l.isHOMO), lumo = all.find((l) => l.isLUMO);
    if (homo && lumo) { const gap = Math.max(1, lumo.energyEV - homo.energyEV); this.window = [homo.energyEV - gap * 2.2, lumo.energyEV + gap * 2.2]; }
    else if (all.length) this.window = [Math.min(...all.map((l) => l.energyEV)), Math.max(...all.map((l) => l.energyEV))];
    this.draw();
  }
  zoom(f) { if (!this.window) return; const c = (this.window[0] + this.window[1]) / 2, r = (this.window[1] - this.window[0]) / 2 * f; this.window = [c - r, c + r]; this.draw(); }
  hitAt(x, y) { return this.hits.find((h) => x >= h.x0 && x <= h.x1 && Math.abs(y - h.y) <= 5) || null; }
  draw() {
    const { ctx, w, h } = prepare(this.canvas);
    this.hits = [];
    if (!this.columns.length || !this.window) { ctx.fillStyle = css('--text-3'); ctx.font = '12px "Segoe UI"'; ctx.textAlign = 'center'; ctx.fillText('No orbitals', w / 2, h / 2); return; }
    const [e0, e1] = this.window; const T = 10, B = 10, L = 44;
    const y = (e) => T + (1 - (e - e0) / (e1 - e0)) * (h - T - B);
    ctx.font = '10px "Segoe UI"'; ctx.fillStyle = css('--text-3'); ctx.strokeStyle = css('--border'); ctx.textAlign = 'right'; ctx.textBaseline = 'middle';
    const step = niceStep(e1 - e0, 6);
    for (let e = Math.ceil(e0 / step) * step; e <= e1; e += step) { ctx.fillText(e.toFixed(step < 1 ? 1 : 0), L - 6, y(e)); ctx.beginPath(); ctx.moveTo(L, y(e) + 0.5); ctx.lineTo(w, y(e) + 0.5); ctx.globalAlpha = 0.4; ctx.stroke(); ctx.globalAlpha = 1; }
    ctx.save(); ctx.translate(9, h / 2); ctx.rotate(-Math.PI / 2); ctx.textAlign = 'center'; ctx.fillText('eV', 0, 0); ctx.restore();
    const colW = (w - L - 6) / this.columns.length;
    this.columns.forEach((col, ci) => {
      const x0 = L + ci * colW + 8, x1 = x0 + colW - 16;
      if (this.columns.length > 1) { ctx.fillStyle = css('--text-2'); ctx.textAlign = 'center'; ctx.fillText(col.spin, (x0 + x1) / 2, h - 4); }
      let homoIdx = 0;
      for (const lv of col.levels) {
        if (lv.energyEV < e0 || lv.energyEV > e1) continue;
        const py = Math.round(y(lv.energyEV)) + 0.5;
        const n = lv.orbitalIndices.length;
        const segW = (x1 - x0 - (n - 1) * 4) / n;
        const occ = lv.occupation > 0.01;
        const isSel = this.selected && this.selected.spin === col.spin && lv.orbitalIndices.includes(this.selected.orbital);
        const isHover = this.hover && this.hover.level === lv;
        ctx.strokeStyle = isSel ? css('--accent') : occ ? css('--text') : css('--text-3'); ctx.lineWidth = isSel ? 3 : isHover ? 2.5 : 1.6;
        for (let k = 0; k < n; k++) {
          const a = x0 + k * (segW + 4);
          ctx.beginPath(); ctx.moveTo(a, py); ctx.lineTo(a + segW, py); ctx.stroke();
          if (occ) { // electrons
            ctx.fillStyle = css('--accent');
            const mid = a + segW / 2;
            const spins = col.spin === 'restricted' ? Math.round(lv.occupation / Math.max(1, n)) : 1;
            for (let s = 0; s < Math.min(2, Math.max(1, spins)); s++) { ctx.beginPath(); ctx.arc(mid + (spins > 1 ? (s ? 4 : -4) : 0), py - 4, 2, 0, Math.PI * 2); ctx.fill(); }
          }
        }
        const label = lv.isHOMO ? 'HOMO' : lv.isLUMO ? 'LUMO' : null;
        if (label) { ctx.fillStyle = css('--text-2'); ctx.textAlign = 'left'; ctx.fillText(label, x1 + 2 > w - 30 ? x0 : x1 - 30, py - 8); }
        this.hits.push({ x0, x1, y: py, level: lv, column: col, label: label || `orbital ${lv.orbitalIndices[0] + 1}` });
        homoIdx++;
      }
    });
  }
}
