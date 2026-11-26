// Compact animated GIF (GIF89a) encoder: median-cut palette, optional Floyd–Steinberg dithering,
// LZW compression, and inter-frame optimisation (only the changed rectangle is stored; unchanged pixels
// inside it are transparent). No dependencies; works in the renderer and in Node.
//
//   const pal = buildPalette([rgba0, rgba5, …], 255);      // samples: Uint8ClampedArray RGBA, any sizes
//   const enc = new GifEncoder(w, h, { palette: pal, loop: true });
//   enc.addFrame(rgba, delayCentiseconds, { dither: false });
//   const bytes = enc.finish();                              // Uint8Array

const HBITS = 6; // histogram / lookup resolution per channel (6 bits → 262 144 cells)
const HSHIFT = 8 - HBITS;
const HSIZE = 1 << (3 * HBITS);
const cell = (r, g, b) => ((r >> HSHIFT) << (2 * HBITS)) | ((g >> HSHIFT) << HBITS) | (b >> HSHIFT);

/** Median-cut palette from RGBA samples. Returns {colors: Uint8Array(n*3), count}. Fully transparent pixels are ignored. */
export function buildPalette(samples, maxColors = 255) {
  const count = new Uint32Array(HSIZE);
  const sr = new Float64Array(HSIZE), sg = new Float64Array(HSIZE), sb = new Float64Array(HSIZE);
  for (const px of samples) {
    // Large frames: sample every k-th pixel (keeps palette building fast).
    const n = px.length >> 2;
    const step = Math.max(1, Math.floor(n / 400000));
    for (let i = 0; i < n; i += step) {
      const o = i << 2;
      if (px[o + 3] < 128) continue;
      const r = px[o], g = px[o + 1], b = px[o + 2];
      const c = cell(r, g, b);
      count[c]++; sr[c] += r; sg[c] += g; sb[c] += b;
    }
  }
  const cells = [];
  for (let c = 0; c < HSIZE; c++) if (count[c]) cells.push(c);
  const comp = (c, ch) => (c >> ((2 - ch) * HBITS)) & ((1 << HBITS) - 1);
  const makeBox = (list) => {
    let w = 0; const lo = [99, 99, 99], hi = [-1, -1, -1];
    for (const c of list) {
      w += count[c];
      for (let ch = 0; ch < 3; ch++) { const v = comp(c, ch); if (v < lo[ch]) lo[ch] = v; if (v > hi[ch]) hi[ch] = v; }
    }
    return { list, w, lo, hi };
  };
  let boxes = cells.length ? [makeBox(cells)] : [];
  while (boxes.length < maxColors) {
    // Split the box with the largest (range × sqrt(pixel weight)): favours both wide and populous boxes.
    let best = -1, score = 0;
    boxes.forEach((b, i) => {
      if (b.list.length < 2) return;
      const range = Math.max(b.hi[0] - b.lo[0], (b.hi[1] - b.lo[1]) * 1.2, b.hi[2] - b.lo[2]);
      const s = range * Math.sqrt(b.w);
      if (s > score) { score = s; best = i; }
    });
    if (best < 0) break;
    const b = boxes[best];
    const ranges = [b.hi[0] - b.lo[0], (b.hi[1] - b.lo[1]) * 1.2, b.hi[2] - b.lo[2]];
    const ch = ranges.indexOf(Math.max(...ranges));
    b.list.sort((x, y) => comp(x, ch) - comp(y, ch));
    let acc = 0, cut = 1;
    for (let i = 0; i < b.list.length - 1; i++) { acc += count[b.list[i]]; if (acc >= b.w / 2) { cut = i + 1; break; } cut = i + 1; }
    boxes.splice(best, 1, makeBox(b.list.slice(0, cut)), makeBox(b.list.slice(cut)));
  }
  const colors = new Uint8Array(Math.max(1, boxes.length) * 3);
  boxes.forEach((b, i) => {
    let r = 0, g = 0, bl = 0;
    for (const c of b.list) { r += sr[c]; g += sg[c]; bl += sb[c]; }
    colors[i * 3] = Math.round(r / b.w); colors[i * 3 + 1] = Math.round(g / b.w); colors[i * 3 + 2] = Math.round(bl / b.w);
  });
  return { colors, count: Math.max(1, boxes.length) };
}

class Bytes {
  constructor() { this.buf = new Uint8Array(1 << 16); this.n = 0; }
  ensure(k) { if (this.n + k > this.buf.length) { const b = new Uint8Array(Math.max(this.buf.length * 2, this.n + k)); b.set(this.buf.subarray(0, this.n)); this.buf = b; } }
  byte(v) { this.ensure(1); this.buf[this.n++] = v & 255; }
  word(v) { this.ensure(2); this.buf[this.n++] = v & 255; this.buf[this.n++] = (v >> 8) & 255; }
  bytes(a) { this.ensure(a.length); this.buf.set(a, this.n); this.n += a.length; }
  str(s) { for (let i = 0; i < s.length; i++) this.byte(s.charCodeAt(i)); }
  result() { return this.buf.slice(0, this.n); }
}

// LZW dictionary: key = prefix code (< 4096) << 8 | next index (< 256) → code (0 = absent). 1 M entries.
const DICT = new Int16Array(1 << 20);
const USED = new Int32Array(4096);

/** Writes the LZW-compressed image data (min code size byte + sub-blocks + terminator). */
function lzw(out, indices, minCodeSize) {
  out.byte(minCodeSize);
  const clearCode = 1 << minCodeSize, eoi = clearCode + 1;
  let codeSize = minCodeSize + 1, next = eoi + 1, used = 0;
  let acc = 0, bits = 0;
  const block = new Uint8Array(255); let bn = 0;
  const flushBlock = () => { if (bn) { out.byte(bn); out.bytes(block.subarray(0, bn)); bn = 0; } };
  const emit = (code) => {
    acc |= code << bits; bits += codeSize;
    while (bits >= 8) { block[bn++] = acc & 255; acc >>>= 8; bits -= 8; if (bn === 255) flushBlock(); }
  };
  const reset = () => { for (let i = 0; i < used; i++) DICT[USED[i]] = 0; used = 0; };
  emit(clearCode);
  let cur = indices[0];
  for (let i = 1; i < indices.length; i++) {
    const k = indices[i];
    const key = (cur << 8) | k;
    const code = DICT[key];
    if (code) { cur = code; continue; }
    emit(cur);
    if (next === 4096) {
      emit(clearCode);
      reset();
      next = eoi + 1; codeSize = minCodeSize + 1;
    } else {
      if (next >= (1 << codeSize)) codeSize++;
      DICT[key] = next++; USED[used++] = key;
    }
    cur = k;
  }
  emit(cur);
  emit(eoi);
  if (bits > 0) { block[bn++] = acc & 255; if (bn === 255) flushBlock(); }
  flushBlock();
  reset();
  out.byte(0);
}

export class GifEncoder {
  /** palette: result of buildPalette (≤ 255 colours; index 255 is reserved for "unchanged" transparency). */
  constructor(width, height, { palette, loop = true, loopCount = 0 } = {}) {
    this.w = width; this.h = height;
    this.pal = palette;
    this.out = new Bytes();
    this.prev = null;
    this.frames = 0;
    this.lut = new Int16Array(HSIZE).fill(-1);
    const o = this.out;
    o.str('GIF89a'); o.word(width); o.word(height);
    o.byte(0xF7); // global colour table, 8 bits colour resolution, 256 entries
    o.byte(0); o.byte(0);
    const gct = new Uint8Array(768);
    gct.set(palette.colors.subarray(0, Math.min(255, palette.count) * 3));
    o.bytes(gct);
    if (loop) { o.byte(0x21); o.byte(0xFF); o.byte(11); o.str('NETSCAPE2.0'); o.byte(3); o.byte(1); o.word(loopCount); o.byte(0); }
  }

  nearest(r, g, b) {
    const c = this.pal.colors, n = Math.min(255, this.pal.count);
    let best = 0, bd = Infinity;
    for (let i = 0; i < n; i++) {
      const dr = c[i * 3] - r, dg = c[i * 3 + 1] - g, db = c[i * 3 + 2] - b;
      const d = dr * dr * 3 + dg * dg * 4 + db * db * 2;
      if (d < bd) { bd = d; best = i; }
    }
    return best;
  }
  index(r, g, b) {
    const k = cell(r, g, b);
    let v = this.lut[k];
    if (v < 0) { v = this.nearest(r, g, b); this.lut[k] = v; }
    return v;
  }

  /** rgba: Uint8ClampedArray/Uint8Array of w*h*4 (alpha ignored). delay in 1/100 s. */
  addFrame(rgba, delay = 10, { dither = false } = {}) {
    const { w, h } = this;
    const idx = new Uint8Array(w * h);
    if (dither) this.ditherInto(rgba, idx);
    else for (let i = 0, o = 0; i < idx.length; i++, o += 4) idx[i] = this.index(rgba[o], rgba[o + 1], rgba[o + 2]);
    // Changed rectangle relative to the previous frame.
    let x0 = 0, y0 = 0, x1 = w - 1, y1 = h - 1, transparent = false;
    if (this.prev) {
      const p = this.prev;
      x0 = w; y0 = h; x1 = -1; y1 = -1;
      for (let y = 0; y < h; y++) {
        const row = y * w;
        for (let x = 0; x < w; x++) {
          if (idx[row + x] !== p[row + x]) { if (x < x0) x0 = x; if (x > x1) x1 = x; if (y < y0) y0 = y; y1 = y; }
        }
      }
      if (x1 < 0) { x0 = 0; y0 = 0; x1 = 0; y1 = 0; } // identical frame: a 1-pixel transparent patch
      transparent = true;
    }
    const rw = x1 - x0 + 1, rh = y1 - y0 + 1;
    const sub = new Uint8Array(rw * rh);
    for (let y = 0; y < rh; y++) {
      const src = (y + y0) * w + x0;
      for (let x = 0; x < rw; x++) {
        const v = idx[src + x];
        sub[y * rw + x] = transparent && this.prev[src + x] === v ? 255 : v;
      }
    }
    const o = this.out;
    // Graphic control extension: disposal 1 (leave in place), optional transparency index 255.
    o.byte(0x21); o.byte(0xF9); o.byte(4);
    o.byte((1 << 2) | (transparent ? 1 : 0));
    o.word(Math.max(2, Math.round(delay))); o.byte(transparent ? 255 : 0); o.byte(0);
    // Image descriptor (no local colour table).
    o.byte(0x2C); o.word(x0); o.word(y0); o.word(rw); o.word(rh); o.byte(0);
    lzw(o, sub, 8);
    this.prev = idx;
    this.frames++;
  }

  ditherInto(rgba, idx) {
    const { w, h } = this;
    const c = this.pal.colors;
    // Error buffers for the current and next row (serpentine Floyd–Steinberg, 3 channels).
    let cur = new Float32Array((w + 2) * 3), nxt = new Float32Array((w + 2) * 3);
    for (let y = 0; y < h; y++) {
      const ltr = (y & 1) === 0;
      for (let k = 0; k < w; k++) {
        const x = ltr ? k : w - 1 - k;
        const o = (y * w + x) * 4, e = (x + 1) * 3;
        const r = clamp(rgba[o] + cur[e]), g = clamp(rgba[o + 1] + cur[e + 1]), b = clamp(rgba[o + 2] + cur[e + 2]);
        const i = this.index(r, g, b);
        idx[y * w + x] = i;
        const er = r - c[i * 3], eg = g - c[i * 3 + 1], eb = b - c[i * 3 + 2];
        const f = ltr ? 3 : -3; // next pixel in scan direction
        for (let ch = 0; ch < 3; ch++) {
          const err = ch === 0 ? er : ch === 1 ? eg : eb;
          cur[e + f + ch] += err * 7 / 16;
          nxt[e - f + ch] += err * 3 / 16;
          nxt[e + ch] += err * 5 / 16;
          nxt[e + f + ch] += err * 1 / 16;
        }
      }
      [cur, nxt] = [nxt, cur]; nxt.fill(0);
    }
  }

  finish() {
    this.out.byte(0x3B);
    return this.out.result();
  }
}

function clamp(v) { return v < 0 ? 0 : v > 255 ? 255 : Math.round(v); }

/** Delays (1/100 s) for n frames at fps, with rounding spread so the average rate is exact. */
export function frameDelays(n, fps) {
  const out = [];
  for (let i = 0; i < n; i++) out.push(Math.round(((i + 1) * 100) / fps) - Math.round((i * 100) / fps));
  return out;
}
