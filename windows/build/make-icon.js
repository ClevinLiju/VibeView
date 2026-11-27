// Builds the VibeView app icon to match the macOS app: two water molecules side by side, each bent like a "V",
// together reading as a "W", on a rounded blue tile.
// - 128 px and up: downscaled from build/icon-master.png, the 512 px icon the macOS app renders with its own
//   molecule renderer (Sources/VibeViewApp/Shell/IconRenderer.swift on main, exported as docs/icon.png).
// - 64 px and down: the same W drawn as flat shapes, as IconRenderer.drawVectorW does on macOS, because shaded
//   spheres turn into blobs at small sizes.
// Writes build/icon.ico (16–256 px PNG entries) and build/icon.png (512 px). No dependencies beyond zlib.
const fs = require('fs');
const path = require('path');
const zlib = require('zlib');

// ---- PNG decode (8-bit RGBA, non-interlaced: the format of icon-master.png) ----
function decodePNG(buf) {
  let p = 8, W = 0, H = 0; const idat = [];
  while (p < buf.length) {
    const len = buf.readUInt32BE(p), type = buf.toString('latin1', p + 4, p + 8), data = buf.subarray(p + 8, p + 8 + len);
    if (type === 'IHDR') {
      W = data.readUInt32BE(0); H = data.readUInt32BE(4);
      if (data[8] !== 8 || data[9] !== 6 || data[12] !== 0) throw new Error('icon-master.png must be 8-bit RGBA, non-interlaced');
    } else if (type === 'IDAT') idat.push(data);
    else if (type === 'IEND') break;
    p += 12 + len;
  }
  const raw = zlib.inflateSync(Buffer.concat(idat)), stride = W * 4, out = Buffer.alloc(H * stride);
  for (let y = 0; y < H; y++) {
    const f = raw[y * (stride + 1)], src = y * (stride + 1) + 1, row = y * stride, prev = row - stride;
    for (let x = 0; x < stride; x++) {
      const a = x >= 4 ? out[row + x - 4] : 0, b = y ? out[prev + x] : 0, c = y && x >= 4 ? out[prev + x - 4] : 0;
      let v = raw[src + x];
      if (f === 1) v += a;
      else if (f === 2) v += b;
      else if (f === 3) v += (a + b) >> 1;
      else if (f === 4) { const pp = a + b - c, pa = Math.abs(pp - a), pb = Math.abs(pp - b), pc = Math.abs(pp - c); v += pa <= pb && pa <= pc ? a : pb <= pc ? b : c; }
      out[row + x] = v & 255;
    }
  }
  return { W, H, rgba: out };
}

// Area-average downscale by an integer factor, in premultiplied alpha.
function downscale({ W, rgba }, S) {
  const k = W / S; if (!Number.isInteger(k)) throw new Error(`cannot scale ${W} to ${S}`);
  const out = Buffer.alloc(S * S * 4);
  for (let y = 0; y < S; y++) for (let x = 0; x < S; x++) {
    let r = 0, g = 0, b = 0, a = 0;
    for (let j = 0; j < k; j++) for (let i = 0; i < k; i++) {
      const o = ((y * k + j) * W + x * k + i) * 4, al = rgba[o + 3] / 255;
      r += rgba[o] * al; g += rgba[o + 1] * al; b += rgba[o + 2] * al; a += al;
    }
    const o = (y * S + x) * 4;
    out[o] = a ? Math.round(r / a) : 0; out[o + 1] = a ? Math.round(g / a) : 0; out[o + 2] = a ? Math.round(b / a) : 0;
    out[o + 3] = Math.round((a / (k * k)) * 255);
  }
  return out;
}

// ---- Small sizes: vector W (port of IconRenderer.tile(small: true) + drawVectorW) ----
// Two waters with real geometry (0.96 Å, 104.5°), each turned 58° about its vertical axis; projected x, y (y up).
function waterW() {
  const turn = 58 * Math.PI / 180, half = 104.5 / 2 * Math.PI / 180, r = 0.96, gap = 0.06;
  const dx = r * Math.sin(half), dy = r * Math.cos(half), px = dx * Math.cos(turn);
  const pts = [];
  for (const side of [-1, 1]) {
    const cx = side * (px + gap);
    pts.push([cx, 0], [cx + side * px, dy], [cx - side * px, dy]); // O, outer H, inner H
  }
  return pts;
}

function renderSmall(S) {
  const inset = S * 0.04, Wd = S - 2 * inset, x0 = inset, y0 = inset, rad = Wd * 0.225;
  const midX = S / 2, midY = S / 2;
  const pts = waterW();
  const xs = pts.map((q) => q[0]), ys = pts.map((q) => q[1]);
  const minX = Math.min(...xs), maxX = Math.max(...xs), minY = Math.min(...ys), maxY = Math.max(...ys);
  const scale = Wd * 0.62 / (maxX - minX);
  // macOS draws y-up with the centre 2% below the middle; here y grows downward.
  const P = ([x, y]) => [midX + (x - (minX + maxX) / 2) * scale, midY + Wd * 0.02 - (y - (minY + maxY) / 2) * scale * 1.35];
  const order = [1, 0, 2, 5, 3, 4].map((i) => P(pts[i])); // outer H, O, inner H | inner H, O, outer H
  const lw = Wd * 0.11;
  const oxy = [P(pts[0]), P(pts[3])], oR = lw * 1.05;
  const rimW = Math.max(1, S * 0.004);
  const glowC = [midX, midY - Wd * 0.04], glowR = Wd * 0.55;
  // NSGradient at 90°: navy at the bottom, mid blue, cyan at the top.
  const stops = [[0.07, 0.12, 0.30], [0.10, 0.33, 0.62], [0.18, 0.62, 0.78]];
  const grad = (t) => { // t = 0 bottom .. 1 top
    const u = Math.max(0, Math.min(1, t)) * 2, i = Math.min(1, Math.floor(u)), f = u - i;
    return [0, 1, 2].map((c) => stops[i][c] + (stops[i + 1][c] - stops[i][c]) * f);
  };
  const tileDist = (x, y) => { // signed distance to the rounded tile (negative inside)
    const qx = Math.abs(x - midX) - (Wd / 2 - rad), qy = Math.abs(y - midY) - (Wd / 2 - rad);
    return Math.hypot(Math.max(qx, 0), Math.max(qy, 0)) + Math.min(Math.max(qx, qy), 0) - rad;
  };
  const segDist = (x, y, [ax, ay], [bx, by]) => {
    const dx = bx - ax, dy = by - ay, t = Math.max(0, Math.min(1, ((x - ax) * dx + (y - ay) * dy) / (dx * dx + dy * dy)));
    return Math.hypot(x - ax - t * dx, y - ay - t * dy);
  };
  const shade = (x, y) => {
    const d = tileDist(x, y);
    if (d > 0) return null;
    let c = grad((y0 + Wd - y) / Wd), a;
    // soft radial glow behind the molecules
    const g = Math.hypot(x - glowC[0], y - glowC[1]) / glowR;
    if (g < 1) { a = 0.22 * (1 - g); c = c.map((v) => v * (1 - a) + a); }
    // H–O–H–O–H outline
    let inW = false;
    for (let i = 0; i + 1 < order.length; i++) if (segDist(x, y, order[i], order[i + 1]) <= lw / 2) { inW = true; break; }
    if (inW) c = [0.96, 0.96, 0.96];
    for (const o of oxy) if (Math.hypot(x - o[0], y - o[1]) <= oR) c = [0.93, 0.16, 0.16];
    // thin highlight rim (stroke centred on the tile edge; only the inner half lands inside)
    if (d > -rimW / 2) c = c.map((v) => v * 0.82 + 0.18);
    return c;
  };
  const ss = 8, out = Buffer.alloc(S * S * 4);
  for (let y = 0; y < S; y++) for (let x = 0; x < S; x++) {
    let r = 0, g = 0, b = 0, n = 0;
    for (let sy = 0; sy < ss; sy++) for (let sx = 0; sx < ss; sx++) {
      const c = shade(x + (sx + 0.5) / ss, y + (sy + 0.5) / ss);
      if (c) { r += c[0]; g += c[1]; b += c[2]; n++; }
    }
    const o = (y * S + x) * 4;
    if (n) { out[o] = Math.round(r / n * 255); out[o + 1] = Math.round(g / n * 255); out[o + 2] = Math.round(b / n * 255); }
    out[o + 3] = Math.round(n / (ss * ss) * 255);
  }
  return out;
}

// ---- PNG / ICO encode ----
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
const master = decodePNG(fs.readFileSync(path.join(outDir, 'icon-master.png')));
const rgbaFor = (s) => (s <= 64 ? renderSmall(s) : s === master.W ? master.rgba : downscale(master, s));
const sizes = [16, 24, 32, 48, 64, 128, 256];
const images = sizes.map((s) => ({ size: s, data: png(s, rgbaFor(s)) }));
fs.writeFileSync(path.join(outDir, 'icon.ico'), ico(images));
fs.writeFileSync(path.join(outDir, 'icon.png'), png(512, rgbaFor(512)));
if (process.argv.includes('--preview')) for (const s of sizes) fs.writeFileSync(path.join(process.argv[process.argv.indexOf('--preview') + 1], `icon-${s}.png`), png(s, rgbaFor(s)));
console.log('wrote build/icon.ico and build/icon.png');
