// Builds the VibeView app icon to match the macOS app: two water molecules side by side, each bent like a "V",
// together reading as a "W", on a rounded blue tile. Every size is downscaled from build/icon-master.png, the
// 512 px icon the macOS app renders with its own molecule renderer (IconRenderer.swift on main, docs/icon.png).
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

// Area-average downscale to any smaller size (each output pixel averages the source area it covers, weighted by
// partial coverage), in premultiplied alpha.
function downscale({ W, rgba }, S) {
  const k = W / S, out = Buffer.alloc(S * S * 4);
  const spans = (i) => { // source pixels and weights covered by output pixel i
    const a = i * k, b = a + k, list = [];
    for (let j = Math.floor(a); j < Math.min(W, Math.ceil(b)); j++) list.push([j, Math.min(b, j + 1) - Math.max(a, j)]);
    return list;
  };
  const cover = Array.from({ length: S }, (_, i) => spans(i));
  for (let y = 0; y < S; y++) for (let x = 0; x < S; x++) {
    let r = 0, g = 0, b = 0, a = 0, wsum = 0;
    for (const [sy, wy] of cover[y]) for (const [sx, wx] of cover[x]) {
      const o = (sy * W + sx) * 4, w = wx * wy, al = (rgba[o + 3] / 255) * w;
      r += rgba[o] * al; g += rgba[o + 1] * al; b += rgba[o + 2] * al; a += al; wsum += w;
    }
    const o = (y * S + x) * 4;
    out[o] = a ? Math.round(r / a) : 0; out[o + 1] = a ? Math.round(g / a) : 0; out[o + 2] = a ? Math.round(b / a) : 0;
    out[o + 3] = Math.round((a / wsum) * 255);
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
const rgbaFor = (s) => (s === master.W ? master.rgba : downscale(master, s));
const sizes = [16, 24, 32, 48, 64, 128, 256];
const images = sizes.map((s) => ({ size: s, data: png(s, rgbaFor(s)) }));
fs.writeFileSync(path.join(outDir, 'icon.ico'), ico(images));
fs.writeFileSync(path.join(outDir, 'icon.png'), png(512, rgbaFor(512)));
if (process.argv.includes('--preview')) for (const s of sizes) fs.writeFileSync(path.join(process.argv[process.argv.indexOf('--preview') + 1], `icon-${s}.png`), png(s, rgbaFor(s)));
console.log('wrote build/icon.ico and build/icon.png');
