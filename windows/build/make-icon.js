// Draws the original VibeView app icon (a stylised three-atom molecule with a vibration arc on a
// rounded tile) and writes build/icon.ico (16–256 px PNG entries) and build/icon.png (512 px).
// No dependencies: a tiny software rasteriser plus zlib for PNG encoding.
const fs = require('fs');
const path = require('path');
const zlib = require('zlib');

function render(S) {
  const px = new Float32Array(S * S * 4); // premultiplied RGBA 0..1
  const over = (i, r, g, b, a) => {
    const k = 1 - a;
    px[i] = r * a + px[i] * k; px[i + 1] = g * a + px[i + 1] * k; px[i + 2] = b * a + px[i + 2] * k; px[i + 3] = a + px[i + 3] * k;
  };
  const ss = 4; // supersampling per axis
  const shapes = [];
  const u = S / 256;
  // background tile: rounded square with a vertical gradient (deep teal to blue)
  shapes.push({ kind: 'tile', r: 56 * u });
  // vibration arcs behind the molecule
  shapes.push({ kind: 'arc', cx: 128 * u, cy: 132 * u, rad: 92 * u, w: 7 * u, a0: -2.5, a1: -0.64, col: [1, 1, 1], alpha: 0.35 });
  shapes.push({ kind: 'arc', cx: 128 * u, cy: 132 * u, rad: 92 * u, w: 7 * u, a0: 0.64, a1: 2.5, col: [1, 1, 1], alpha: 0.35 });
  // bonds
  const O = [128 * u, 118 * u], H1 = [70 * u, 168 * u], H2 = [186 * u, 168 * u], C = [128 * u, 58 * u];
  shapes.push({ kind: 'seg', a: O, b: H1, w: 15 * u, col: [0.93, 0.95, 0.98] });
  shapes.push({ kind: 'seg', a: O, b: H2, w: 15 * u, col: [0.93, 0.95, 0.98] });
  shapes.push({ kind: 'seg', a: O, b: C, w: 15 * u, col: [0.93, 0.95, 0.98] });
  // atoms (shaded spheres)
  shapes.push({ kind: 'ball', c: C, r: 26 * u, col: [0.98, 0.76, 0.22] });
  shapes.push({ kind: 'ball', c: H1, r: 24 * u, col: [0.96, 0.97, 1.0] });
  shapes.push({ kind: 'ball', c: H2, r: 24 * u, col: [0.96, 0.97, 1.0] });
  shapes.push({ kind: 'ball', c: O, r: 38 * u, col: [0.95, 0.28, 0.3] });

  const sample = (x, y) => {
    // returns list of [r,g,b,a] layers for point (x,y)
    const out = [];
    for (const s of shapes) {
      if (s.kind === 'tile') {
        const m = 10 * u, r = s.r;
        const qx = Math.max(Math.abs(x - S / 2) - (S / 2 - m - r), 0), qy = Math.max(Math.abs(y - S / 2) - (S / 2 - m - r), 0);
        if (Math.hypot(qx, qy) <= r) {
          const t = y / S;
          out.push([0.06 + 0.06 * t, 0.36 - 0.1 * t, 0.55 + 0.25 * t, 1]);
        }
      } else if (s.kind === 'arc') {
        const d = Math.hypot(x - s.cx, y - s.cy); const ang = Math.atan2(y - s.cy, x - s.cx);
        if (Math.abs(d - s.rad) <= s.w / 2 && ang >= s.a0 && ang <= s.a1) out.push([...s.col, s.alpha]);
      } else if (s.kind === 'seg') {
        const [ax, ay] = s.a, [bx, by] = s.b; const dx = bx - ax, dy = by - ay;
        const t = Math.max(0, Math.min(1, ((x - ax) * dx + (y - ay) * dy) / (dx * dx + dy * dy)));
        if (Math.hypot(x - (ax + t * dx), y - (ay + t * dy)) <= s.w / 2) out.push([...s.col, 1]);
      } else if (s.kind === 'ball') {
        const dx = (x - s.c[0]) / s.r, dy = (y - s.c[1]) / s.r; const rr = dx * dx + dy * dy;
        if (rr <= 1) {
          const nz = Math.sqrt(1 - rr);
          const L = [-0.45, -0.55, 0.7]; const ln = Math.hypot(...L);
          const diff = Math.max(0, (dx * L[0] + dy * L[1] + nz * L[2]) / ln);
          const hx = L[0] / ln, hy = L[1] / ln, hz = L[2] / ln + 1; const hn = Math.hypot(hx, hy, hz);
          const spec = Math.pow(Math.max(0, (dx * hx + dy * hy + nz * hz) / hn), 40);
          const k = 0.35 + 0.7 * diff;
          out.push([Math.min(1, s.col[0] * k + spec * 0.8), Math.min(1, s.col[1] * k + spec * 0.8), Math.min(1, s.col[2] * k + spec * 0.8), 1]);
        }
      }
    }
    return out;
  };
  for (let y = 0; y < S; y++) for (let x = 0; x < S; x++) {
    const acc = [0, 0, 0, 0];
    for (let sy = 0; sy < ss; sy++) for (let sx = 0; sx < ss; sx++) {
      let c = [0, 0, 0, 0];
      for (const [r, g, b, a] of sample(x + (sx + 0.5) / ss, y + (sy + 0.5) / ss)) {
        const k = 1 - a; c = [r * a + c[0] * k, g * a + c[1] * k, b * a + c[2] * k, a + c[3] * k];
      }
      for (let i = 0; i < 4; i++) acc[i] += c[i] / (ss * ss);
    }
    over((y * S + x) * 4, acc[3] ? acc[0] / acc[3] : 0, acc[3] ? acc[1] / acc[3] : 0, acc[3] ? acc[2] / acc[3] : 0, acc[3]);
  }
  const bytes = Buffer.alloc(S * S * 4);
  for (let i = 0; i < S * S; i++) {
    const a = px[i * 4 + 3];
    for (let c = 0; c < 3; c++) bytes[i * 4 + c] = Math.round(Math.min(1, a ? px[i * 4 + c] / a : 0) * 255);
    bytes[i * 4 + 3] = Math.round(a * 255);
  }
  return bytes;
}

const CRC = (() => { const t = new Uint32Array(256); for (let n = 0; n < 256; n++) { let c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1; t[n] = c >>> 0; } return t; })();
function crc32(buf) { let c = 0xffffffff; for (const b of buf) c = CRC[(c ^ b) & 255] ^ (c >>> 8); return (c ^ 0xffffffff) >>> 0; }
function chunk(type, data) {
  const len = Buffer.alloc(4); len.writeUInt32BE(data.length);
  const td = Buffer.concat([Buffer.from(type), data]);
  const crc = Buffer.alloc(4); crc.writeUInt32BE(crc32(td));
  return Buffer.concat([len, td, crc]);
}
function png(S, rgba) {
  const raw = Buffer.alloc(S * (S * 4 + 1));
  for (let y = 0; y < S; y++) { raw[y * (S * 4 + 1)] = 0; rgba.copy(raw, y * (S * 4 + 1) + 1, y * S * 4, (y + 1) * S * 4); }
  const ihdr = Buffer.alloc(13); ihdr.writeUInt32BE(S, 0); ihdr.writeUInt32BE(S, 4); ihdr[8] = 8; ihdr[9] = 6; ihdr[10] = 0; ihdr[11] = 0; ihdr[12] = 0;
  return Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), chunk('IHDR', ihdr), chunk('IDAT', zlib.deflateSync(raw, { level: 9 })), chunk('IEND', Buffer.alloc(0))]);
}
function ico(images) {
  const head = Buffer.alloc(6); head.writeUInt16LE(0, 0); head.writeUInt16LE(1, 2); head.writeUInt16LE(images.length, 4);
  const dir = []; let offset = 6 + 16 * images.length;
  for (const { size, data } of images) {
    const e = Buffer.alloc(16);
    e[0] = size >= 256 ? 0 : size; e[1] = size >= 256 ? 0 : size; e[2] = 0; e[3] = 0;
    e.writeUInt16LE(1, 4); e.writeUInt16LE(32, 6); e.writeUInt32LE(data.length, 8); e.writeUInt32LE(offset, 12);
    offset += data.length; dir.push(e);
  }
  return Buffer.concat([head, ...dir, ...images.map((i) => i.data)]);
}

const outDir = __dirname;
const sizes = [16, 24, 32, 48, 64, 128, 256];
const images = sizes.map((s) => ({ size: s, data: png(s, render(s)) }));
fs.writeFileSync(path.join(outDir, 'icon.ico'), ico(images));
fs.writeFileSync(path.join(outDir, 'icon.png'), png(512, render(512)));
console.log('wrote build/icon.ico and build/icon.png');
