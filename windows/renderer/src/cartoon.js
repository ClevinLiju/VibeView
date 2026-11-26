// Protein cartoon: helices as ribbons, strands as arrows, loops as tubes (style "cartoon").
//
// Data comes from the engine's analysis.secondaryStructure (per-residue N/CA/C/O atom indices, secondary structure
// letters, continuous backbone segments, the chain of every atom and the file's biological assembly 1). The trace is a
// Catmull-Rom spline through the CA atoms (strand CAs are smoothed to take out the pleat); the ribbon's width direction
// follows the carbonyl C=O vectors, flipped to stay consistent. All profiles share one vertex count, so a segment is a
// single continuous tube whose cross-section morphs between round (loops), flat ellipse (helices) and rounded box
// (strands). Everything is merged into one BufferGeometry, rebuilt from scratch on every build (never added twice);
// new displayed positions (trajectory frames, vibrations) only refill its vertex buffers (CartoonGeometry.update).
//
// RCSB/Mol*-like defaults: colour "auto" (one chain: rainbow N→C; several chains: one colour per chain), waters hidden,
// ligands as ball and stick with their carbons tinted by chain, only the chains of biological assembly 1 shown (its
// symmetry copies are drawn as transformed copies of the same meshes), chain gaps (missing residues, i.e. a jump in
// the residue numbering) as dashes; a C-terminus (OXT) ends a segment, and real breaks are left open.
import * as THREE from 'three';
import { STYLE_ICONS } from './icons.js';
import { request } from './api.js';

STYLE_ICONS.cartoon = '<svg viewBox="0 0 54 34"><path d="M4 24c6-14 10-14 14 0s8 14 12 0" fill="none" stroke="#e0457b" stroke-width="5" stroke-linecap="round"/><path d="M32 12h12v-4l8 8-8 8v-4H32z" fill="#f2c230"/></svg>';

export const CARTOON_STYLE = { value: 'cartoon', label: 'Cartoon' };
export const CARTOON_COLORS = [
  { value: 'auto', label: 'Auto (like RCSB)' }, { value: 'chain', label: 'Chain' },
  { value: 'ss', label: 'Secondary structure' }, { value: 'rainbow', label: 'Rainbow (N→C)' }, { value: 'uniform', label: 'Single colour' },
];
export const CARTOON_ASSEMBLY = [
  { value: 'assembly', label: 'Biological assembly' }, { value: 'asymmetric', label: 'All chains in the file' },
];

const SS_COLORS = { helix: 0xe0457b, strand: 0xf2c230, loop: 0xc8ccd2 };
// Mol* "chain-id" look (ColorBrewer Dark2, then Paired-like extras).
const CHAIN_COLORS = [0x7570b3, 0x1b9e77, 0xd95f02, 0xe7298a, 0x66a61e, 0xe6ab02, 0xa6761d, 0x1f78b4, 0xb2df8a, 0xfb9a99, 0x6a3d9a, 0x33a02c];
// Rainbow stops (blue → cyan → green → yellow → orange → red), as in the RCSB sequence-id previews.
const RAINBOW = [0x3a4cc0, 0x3b8bd0, 0x35b6b0, 0x5cc35a, 0xb7cf3a, 0xf2c230, 0xf28a2a, 0xd7301f].map((c) => new THREE.Color(c));

function rainbowAt(t) {
  const x = Math.max(0, Math.min(1, t)) * (RAINBOW.length - 1);
  const i = Math.min(RAINBOW.length - 2, Math.floor(x));
  return RAINBOW[i].clone().lerp(RAINBOW[i + 1], x - i);
}

function kind(ch) {
  if (ch === 'H' || ch === 'G' || ch === 'I') return 'helix';
  if (ch === 'E') return 'strand';
  return 'loop';
}

// Cross-section shapes: half width (along the C=O guide), half thickness, superellipse exponent.
const LOOP = { w: 0.26, h: 0.26, n: 2 };
const HELIX = { w: 1.2, h: 0.24, n: 2.6 };
const STRAND = { w: 1.05, h: 0.26, n: 5 };
const ARROW = 1.7; // arrow base half width
const smooth = (f) => f * f * (3 - 2 * f);

/** Row-major 3x4 operator → Matrix4. */
function opMatrix(op) {
  return new THREE.Matrix4().set(op[0], op[1], op[2], op[3], op[4], op[5], op[6], op[7], op[8], op[9], op[10], op[11], 0, 0, 0, 1);
}
const isIdentity = (op) => [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0].every((v, k) => Math.abs(op[k] - v) < 1e-4);

export class CartoonLayer {
  constructor(vp) {
    this.vp = vp;
    this.data = null;
    this.mesh = null;
    this.copies = []; // assembly symmetry copies (Object3Ds in the molecule group)
    this.covered = null; // Uint8Array per atom: 1 polymer (cartoon), 2 water, 3 chain outside the shown assembly
    this.drawn = null; // Uint8Array per residue: drawn as cartoon
    this.caIndex = null; // Set of CA atoms (pickable stand-ins for hidden residues)
    this.coverKey = null;
    this.geom = null; // CartoonGeometry of the current mesh
    this.builtFrom = -1; // viewport.positionsVersion the vertices were computed for
    this.lastBuildMs = 0;
    this.lastSyncMs = 0;
  }

  /** Engine result (or null). Must match the viewport's current molecule. */
  setData(data) {
    this.data = data && data.residueCount > 0 ? data : null;
    this.covered = null; this.caIndex = null; this.drawn = null; this.coverKey = null;
    this.vp.rebuild();
  }

  /** Chain names shown under the current options (null = all). */
  shownChains() {
    const a = this.data?.assembly;
    if (!a || this.vp.options.cartoonAssembly === 'asymmetric' || !Array.isArray(a.chains) || !a.chains.length) return null;
    return new Set(a.chains);
  }

  /** Symmetry operators drawn as copies: the non-identity operators of assembly 1, when one operator set applies to
   *  every chain of the assembly and includes the identity (the file's own coordinates). */
  operators() {
    const a = this.data?.assembly;
    if (!a || this.vp.options.cartoonAssembly === 'asymmetric' || !a.parts?.length) return [];
    const sig = (p) => JSON.stringify(p.operators);
    if (!a.parts.every((p) => sig(p) === sig(a.parts[0]))) return [];
    const all = a.parts[0].operators.filter((op) => Array.isArray(op) && op.length === 12);
    if (!all.some(isIdentity)) return [];
    const ops = all.filter((op) => !isIdentity(op));
    return ops.length && this.data.atomCount * (ops.length + 1) <= 3_000_000 ? ops.slice(0, 120) : [];
  }

  /** (Re)computes which atoms the cartoon covers, for the current data and options. */
  coverage() {
    const key = this.vp.options.cartoonAssembly || 'assembly';
    if (this.covered && this.coverKey === key) return;
    this.coverKey = key;
    const d = this.data;
    const n = d.atomCount;
    const cov = new Uint8Array(n);
    const chains = this.shownChains();
    const drawn = new Uint8Array(d.residueCount);
    for (let r = 0; r < d.residueCount; r++) if (!chains || chains.has(d.chain[r])) drawn[r] = 1;
    for (const i of d.polymerAtoms) if (i < n) cov[i] = 1;
    for (const i of d.waterAtoms) if (i < n) cov[i] = 2;
    if (chains && d.atomChain && d.chains) {
      for (let i = 0; i < n; i++) { const c = d.atomChain[i]; if (c >= 0 && !chains.has(d.chains[c])) cov[i] = 3; }
    }
    this.covered = cov;
    this.drawn = drawn;
    this.caIndex = new Set(d.ca.filter((i, r) => drawn[r] && i >= 0));
  }

  /** Cartoon applies to the molecule now shown. */
  active() {
    const vp = this.vp;
    return vp.options.style === 'cartoon' && !!this.data && !!vp.molecule && vp.molecule.atoms.length === this.data.atomCount;
  }

  ready() {
    if (!this.active()) return false;
    this.coverage();
    return true;
  }

  /** Atom drawn by the cartoon (or a water / an atom of a chain outside the assembly, hidden in cartoon mode). */
  hides(i) { return this.ready() && !!this.covered[i]; }

  /** Waters and chains outside the assembly don't count for zoom-to-fit. */
  excludesFromFit(i) { return this.ready() && this.covered[i] >= 2; }

  /** CA atom standing in for a cartoon residue (picking, selection highlight). */
  isPickable(i) { return this.ready() && this.caIndex.has(i); }

  /** Cartoon-mode colour of a ligand carbon: its element colour tinted with its chain colour (null = unchanged). */
  ligandCarbonColor(i, base) {
    const d = this.data;
    if (!d || !d.atomChain || !this.active() || (this.vp.options.colorScheme || 'element') !== 'element') return null;
    const c = d.atomChain[i];
    if (c == null || c < 0) return null;
    return base.clone().lerp(new THREE.Color(CHAIN_COLORS[c % CHAIN_COLORS.length]), 0.45);
  }

  /** Pick the CA of a cartoon residue near the ray (atoms under the cartoon stay pickable through their CA). */
  pick(ray, best) {
    if (!this.ready()) return best;
    const P = this.vp.positions;
    const v = new THREE.Vector3();
    for (const i of this.caIndex) {
      const p = P[i]; if (!p) continue;
      v.subVectors(p, ray.origin);
      const t = v.dot(ray.direction);
      if (t < 0) continue;
      const d2 = v.lengthSq() - t * t;
      if (d2 < 1.1 * 1.1 && (!best || t < best.t)) best = { kind: 'atom', index: i, t };
    }
    return best;
  }

  /** Called at the end of Viewport.rebuild(): (re)creates the cartoon mesh and the assembly copies in `group`. */
  build(group) {
    this.disposeMesh();
    if (!this.ready()) return;
    const t0 = performance.now();
    const vp = this.vp;
    this.geom = new CartoonGeometry(this.data, vp.positions, vp.options, this.drawn, vp.molecule);
    const geo = this.geom.geometry;
    if (geo) {
      let mat;
      if (vp.options.material === 'flat') mat = new THREE.MeshBasicMaterial({ vertexColors: true });
      else {
        mat = vp.material.clone(); // same look (PBR parameters) as the atoms
        mat.vertexColors = true;
        mat.color?.set(0xffffff);
      }
      this.mesh = new THREE.Mesh(geo, mat);
      this.mesh.userData.cartoon = true;
      this.mesh.frustumCulled = false; // vertices move with trajectory frames; bounds are recomputed lazily
      group.add(this.mesh);
    }
    // Biological assembly copies: the cartoon, atoms and bonds again under each symmetry operator (display only,
    // sharing geometry and instance buffers with the originals).
    for (const op of this.operators()) {
      const M = opMatrix(op);
      const add = (src, make) => {
        if (!src) return;
        const o = make(src);
        o.matrixAutoUpdate = false; o.matrix.copy(M); o.frustumCulled = false;
        o.userData.assemblyCopy = true;
        group.add(o); this.copies.push(o);
      };
      add(this.mesh, (m) => new THREE.Mesh(m.geometry, m.material));
      for (const src of [vp.atomMesh, vp.bondMesh]) {
        add(src, (m) => {
          const c = new THREE.InstancedMesh(m.geometry, m.material, m.count);
          c.instanceMatrix = m.instanceMatrix; // shared: follows updateMatrices()
          if (m.instanceColor) c.instanceColor = m.instanceColor;
          return c;
        });
      }
    }
    this.builtFrom = vp.positionsVersion;
    this.lastBuildMs = performance.now() - t0;
  }

  /** Called from updateMatrices(): follow the displayed positions (trajectory frames, vibrations) by refilling
   *  the vertex buffers in place (same topology, a few ms for a 500-residue protein). */
  sync() {
    if (!this.mesh || !this.geom || this.builtFrom === this.vp.positionsVersion) return;
    const t0 = performance.now();
    this.geom.update(this.vp.positions);
    this.builtFrom = this.vp.positionsVersion;
    this.lastSyncMs = performance.now() - t0;
  }

  disposeMesh() {
    for (const c of this.copies) c.parent?.remove(c); // geometry and buffers are shared: nothing of their own to free
    this.copies = [];
    if (!this.mesh) return;
    this.mesh.parent?.remove(this.mesh);
    this.mesh.geometry.dispose();
    this.mesh.material.dispose();
    this.mesh = null;
    this.geom = null;
  }
}

// ---------- geometry ----------

/** Index of a chain in the engine's chain list (the same colour as the chain's ligand carbons). */
function chainColorIndex(data, name) {
  const k = data.chains ? data.chains.indexOf(name) : -1;
  return k >= 0 ? k : [...new Set(data.chain)].indexOf(name);
}

function residueColors(data, options, drawn) {
  const R = data.residueCount;
  const out = new Array(R);
  let mode = options.cartoonColoring || 'auto';
  if (mode === 'auto') {
    const shown = new Set();
    for (let r = 0; r < R; r++) if (!drawn || drawn[r]) shown.add(data.chain[r]);
    mode = shown.size > 1 ? 'chain' : 'rainbow';
  }
  for (let r = 0; r < R; r++) {
    let c;
    if (mode === 'chain') c = new THREE.Color(CHAIN_COLORS[chainColorIndex(data, data.chain[r]) % CHAIN_COLORS.length]);
    else if (mode === 'uniform') c = new THREE.Color(options.uniformColor || '#9aa0a8');
    else if (mode !== 'rainbow') c = new THREE.Color(SS_COLORS[kind(data.ss[r])]);
    out[r] = c;
  }
  if (mode === 'rainbow') {
    // N→C per chain, blue → red.
    let s = 0;
    for (let r = 1; r <= R; r++) {
      if (r === R || data.chain[r] !== data.chain[s]) {
        const len = Math.max(1, r - s - 1);
        for (let k = s; k < r; k++) out[k] = rainbowAt((k - s) / len);
        s = r;
      }
    }
  }
  return { colors: out, smoothColors: mode === 'rainbow' };
}

/** C-terminal residues: an OXT (or CHARMM OT2) oxygen in the residue. A chain that continues after one (two
 *  proteins concatenated in one chain without TER) starts a new, unconnected segment. The OXT belongs to the residue
 *  whose carbonyl C precedes it in file order (PDB atom order); bonds are not used, since a distorted frame can
 *  bond it to a neighbouring residue's C too. */
function terminalResidues(data, atoms) {
  const R = data.residueCount, term = new Uint8Array(R);
  if (!atoms) return term;
  const cs = [];
  for (let r = 0; r < R; r++) if (data.c[r] >= 0) cs.push([data.c[r], r]);
  cs.sort((x, y) => x[0] - y[0]);
  for (let i = 0; i < atoms.length; i++) {
    const l = atoms[i].label;
    if (l !== 'OXT' && l !== 'OT2') continue;
    let lo = 0, hi = cs.length - 1, best = -1; // last C index below i
    while (lo <= hi) { const m = (lo + hi) >> 1; if (cs[m][0] < i) { best = m; lo = m + 1; } else hi = m - 1; }
    if (best >= 0) term[cs[best][1]] = 1;
  }
  return term;
}

/** The engine's continuous backbone segments, also split after every C-terminal residue. */
function cartoonSegments(data, term) {
  const out = [];
  for (const [s, e] of data.segments) {
    let a = s;
    for (let r = s; r < e - 1; r++) if (term[r]) { out.push([a, r + 1]); a = r + 1; }
    out.push([a, e]);
  }
  return out;
}

const CA_STEP = 3.8; // Å between consecutive CA atoms (trans peptide)

/**
 * Cartoon mesh with a fixed topology: the plan (segments, samples, cross-section profiles, colours, triangles)
 * is made once in the constructor; update(positions) recomputes the spline, the frames and every vertex position
 * and normal into the same buffers, allocation-free, so trajectory frames and vibrations only cost that refill.
 */
class CartoonGeometry {
  constructor(data, positions, options, drawn, mol) {
    this.geometry = null;
    const term = terminalResidues(data, mol?.atoms);
    const segments = cartoonSegments(data, term).filter(([s]) => !drawn || drawn[s]);
    const total = segments.reduce((a, [s, e]) => a + (e - s), 0);
    if (!total) return;
    const S = total > 6000 ? 4 : total > 2000 ? 6 : 10; // samples per residue
    const M = this.M = total > 6000 ? 10 : 16; // vertices per ring
    const { colors, smoothColors } = residueColors(data, options, drawn);
    this.cosA = new Float64Array(M); this.sinA = new Float64Array(M);
    for (let k = 0; k < M; k++) { const a = (k / M) * Math.PI * 2; this.cosA[k] = Math.cos(a); this.sinA[k] = Math.sin(a); }
    const items = this.items = [];
    const col = [], idx = [];
    let nv = 0;
    const pushColor = (c, count) => { for (let k = 0; k < count; k++) col.push(c.r, c.g, c.b); };
    const ringBand = (a, b) => {
      for (let m = 0; m < M; m++) { const m2 = (m + 1) % M; idx.push(a + m, a + m2, b + m, a + m2, b + m2, b + m); }
    };
    const capFan = (center, sign) => {
      const ring = center + 1;
      for (let m = 0; m < M; m++) { const m2 = (m + 1) % M; if (sign > 0) idx.push(center, ring + m, ring + m2); else idx.push(center, ring + m2, ring + m); }
    };
    /** Round tube through `count` points (lone residues, gap dashes): rings, then two flat end caps. */
    const addTube = (item, count, radius, color) => {
      item.count = count; item.radius = radius; item.v0 = nv; item.pts = new Float64Array(count * 3);
      for (let k = 0; k + 1 < count; k++) ringBand(nv + k * M, nv + (k + 1) * M);
      pushColor(color, count * M);
      const c0 = nv + count * M, c1 = c0 + M + 1;
      capFan(c0, -1); capFan(c1, 1);
      pushColor(color, 2 * (M + 1));
      nv += count * M + 2 * (M + 1);
      items.push(item);
    };
    const P = (i) => (i >= 0 ? positions[i] : null);

    // Missing residues inside a chain (a numbering gap between consecutive segments of the same chain): a dashed
    // line between the two CA atoms, like Mol*. Nothing is drawn across a real break: after a C-terminus (OXT),
    // between consecutively numbered residues (two molecules in one chain), or when the CA atoms are farther
    // apart than the missing residues could span (CA_STEP per residue).
    const dashColor = new THREE.Color(0xa0a4aa);
    for (let k = 0; k + 1 < segments.length; k++) {
      const e = segments[k][1] - 1, s2 = segments[k + 1][0];
      if (data.chain[e] !== data.chain[s2] || s2 !== e + 1 || term[e]) continue;
      const gap = Array.isArray(data.seq) ? data.seq[s2] - data.seq[e] - 1 : null;
      if (gap != null && !(gap >= 1)) continue;
      const a = P(data.ca[e]), b = P(data.ca[s2]);
      if (!a || !b) continue;
      const len = a.distanceTo(b);
      const maxLen = gap != null ? Math.min(60, CA_STEP * (gap + 1) + 1) : 20;
      if (len < 4.2 || len > maxLen) continue;
      const dash = 0.5, period = 1.0, nd = Math.floor(len / period);
      for (let j = 0; j < nd; j++) {
        const t0 = (j * period + (len - nd * period + period - dash) / 2) / len, t1 = t0 + dash / len;
        if (t1 > 1) break;
        addTube({ kind: 'dash', a: data.ca[e], b: data.ca[s2], j, nd, dash, period }, 2, 0.12, dashColor);
      }
    }

    for (const [s, e] of segments) {
      const n = e - s;
      if (n < 2) {
        // Lone residue (neighbours missing): a short loop tube N–CA–C.
        const atoms = [data.n[s], data.ca[s], data.c[s]].filter((i) => P(i));
        if (atoms.length >= 2) addTube({ kind: 'lone', atoms }, atoms.length, LOOP.w, colors[s]);
        continue;
      }
      const ss = []; for (let r = s; r < e; r++) ss.push(kind(data.ss[r]));
      const it = { kind: 'seg', n, v0: nv };
      it.ca = Int32Array.from({ length: n }, (_, i) => data.ca[s + i]);
      it.o = Int32Array.from({ length: n }, (_, i) => data.o[s + i]);
      it.c = Int32Array.from({ length: n }, (_, i) => data.c[s + i]);
      // Strand CAs are smoothed (pleat removed); strand guides are averaged with their neighbours.
      it.smooth = Uint8Array.from({ length: n }, (_, i) => (ss[i] === 'strand' && i > 0 && i < n - 1 && ss[i - 1] === 'strand' && ss[i + 1] === 'strand' ? 1 : 0));
      it.strand = Uint8Array.from(ss, (k) => (k === 'strand' ? 1 : 0));
      it.ctrl = new Float64Array(n * 3); it.guide = new Float64Array(n * 3); it.sg = new Float64Array(n * 3);

      // Shape at parameter t (residue units, 0..n-1).
      const shapeAt = (t) => {
        const i = Math.min(n - 1, Math.max(0, Math.round(t)));
        const lo = Math.floor(t), hi = Math.min(n - 1, lo + 1), f = t - lo;
        const prof = (k) => (k === 'helix' ? HELIX : k === 'strand' ? STRAND : LOOP);
        // Arrow: last strand residue (next is not strand). Base at t=i-0.5, tip at t=i+0.6.
        for (let j = Math.max(0, Math.floor(t - 0.6)); j <= Math.min(n - 1, Math.ceil(t + 0.5)); j++) {
          if (ss[j] === 'strand' && (j === n - 1 || ss[j + 1] !== 'strand') && j > 0 && ss[j - 1] === 'strand') {
            if (t >= j - 0.5 && t <= j + 0.6) {
              const u = (t - (j - 0.5)) / 1.1;
              return { w: ARROW * (1 - u) + LOOP.w * u, h: STRAND.h * (1 - u) + LOOP.h * u, n: STRAND.n * (1 - u) + 2 * u, res: j };
            }
            if (t > j + 0.6 && t < j + 1) return { ...LOOP, res: Math.min(n - 1, j + 1) };
          }
        }
        const A = prof(ss[lo]), B = prof(ss[hi]);
        // A strand that just ended in an arrow must not blend back up into the next residue.
        if (ss[lo] === 'strand' && ss[hi] !== 'strand') return { ...B, res: i };
        const m = ss[lo] === ss[hi] ? 0 : smooth(f);
        return { w: A.w + (B.w - A.w) * m, h: A.h + (B.h - A.h) * m, n: A.n + (B.n - A.n) * m, res: i };
      };

      // Samples along the spline: t, plus three extra samples at each arrow base (narrow end, wide start).
      const samples = [];
      const steps = (n - 1) * S;
      for (let k = 0; k <= steps; k++) samples.push({ t: k / S, at: k / S });
      for (let j = 1; j < n; j++) {
        if (!(ss[j] === 'strand' && ss[j - 1] === 'strand' && (j === n - 1 || ss[j + 1] !== 'strand'))) continue;
        const tb = j - 0.5;
        const k = samples.findIndex((q) => q.t > tb);
        if (k <= 0) continue;
        samples.splice(k, 0, { t: tb - 1e-4, at: tb, forceBody: true }, { t: tb, at: tb, cap: true }, { t: tb, at: tb });
      }
      const ns = it.ns = samples.length;
      it.sI = new Int32Array(ns); it.sF = new Float64Array(ns); it.capN = new Uint8Array(ns);
      it.prof = new Float32Array(ns * M * 4); // per ring vertex: x, y offsets and unit normal (nx, ny) in the frame
      it.sp = new Float64Array(ns * 3); it.sgS = new Float64Array(ns * 3);
      for (let k = 0; k < ns; k++) {
        const q = samples[k];
        const i = Math.min(n - 2, Math.floor(q.at));
        it.sI[k] = i; it.sF[k] = q.at - i;
        it.capN[k] = q.cap || (k > 0 && samples[k - 1].cap) ? 1 : 0;
        let sh = shapeAt(q.t);
        if (q.forceBody) sh = { ...STRAND, res: Math.round(q.t + 0.5) };
        if (q.cap) sh = { ...STRAND, w: ARROW, res: Math.round(q.t + 0.5) };
        // Rainbow interpolates smoothly; the others switch at residue boundaries.
        let cr = colors[s + Math.min(n - 1, Math.max(0, sh.res))];
        if (smoothColors) {
          const lo = Math.min(n - 2, Math.floor(q.t)), f = q.t - lo;
          cr = colors[s + lo].clone().lerp(colors[s + lo + 1], Math.max(0, Math.min(1, f)));
        }
        pushColor(cr, M);
        const e2 = 2 / sh.n;
        for (let m = 0; m < M; m++) {
          const cx = this.cosA[m], sy = this.sinA[m];
          // Superellipse point and normal ∝ (sign(c)|c|^(2-2/n)/w, sign(s)|s|^(2-2/n)/h).
          const x = Math.sign(cx) * Math.pow(Math.abs(cx), e2) * sh.w;
          const y = Math.sign(sy) * Math.pow(Math.abs(sy), e2) * sh.h;
          let nx = Math.sign(cx) * Math.pow(Math.abs(cx), 2 - e2) / sh.w;
          let ny = Math.sign(sy) * Math.pow(Math.abs(sy), 2 - e2) / sh.h;
          const l = Math.hypot(nx, ny) || 1; nx /= l; ny /= l;
          const o = (k * M + m) * 4;
          it.prof[o] = x; it.prof[o + 1] = y; it.prof[o + 2] = nx; it.prof[o + 3] = ny;
        }
      }
      for (let k = 0; k + 1 < ns; k++) ringBand(nv + k * M, nv + (k + 1) * M);
      // End caps, coloured like their ring.
      const c0 = nv + ns * M, c1 = c0 + M + 1;
      capFan(c0, -1); capFan(c1, 1);
      const lastRing = (ns - 1) * M * 3, colAt = (v) => new THREE.Color(col[v], col[v + 1], col[v + 2]);
      const first = colAt(nv * 3), last = colAt(nv * 3 + lastRing);
      pushColor(first, M + 1); pushColor(last, M + 1);
      nv += ns * M + 2 * (M + 1);
      items.push(it);
    }
    if (!nv) return;
    this.pos = new Float32Array(nv * 3);
    this.nor = new Float32Array(nv * 3);
    const g = this.geometry = new THREE.BufferGeometry();
    this.posAttr = new THREE.BufferAttribute(this.pos, 3).setUsage(THREE.DynamicDrawUsage);
    this.norAttr = new THREE.BufferAttribute(this.nor, 3).setUsage(THREE.DynamicDrawUsage);
    g.setAttribute('position', this.posAttr);
    g.setAttribute('normal', this.norAttr);
    g.setAttribute('color', new THREE.Float32BufferAttribute(col, 3));
    g.setIndex(nv > 65535 ? new THREE.Uint32BufferAttribute(idx, 1) : new THREE.Uint16BufferAttribute(idx, 1));
    this.update(positions);
  }

  /** Recomputes every vertex position and normal for `positions` (Vector3 per atom) into the existing buffers. */
  update(positions) {
    if (!this.geometry) return;
    for (const it of this.items) {
      if (it.kind === 'seg') this.updateSegment(it, positions);
      else this.updateTube(it, positions);
    }
    this.posAttr.needsUpdate = true;
    this.norAttr.needsUpdate = true;
    const g = this.geometry;
    g.boundingBox = null; // recomputed lazily (zoom-to-fit); the mesh is not frustum culled
    g.boundingSphere = null;
  }

  updateTube(it, P) {
    const M = this.M, pts = it.pts, cnt = it.count, pos = this.pos, nor = this.nor, r = it.radius;
    if (it.kind === 'dash') {
      const a = P[it.a], b = P[it.b];
      const dx = b.x - a.x, dy = b.y - a.y, dz = b.z - a.z, len = Math.hypot(dx, dy, dz) || 1;
      const t0 = Math.max(0, (it.j * it.period + (len - it.nd * it.period + it.period - it.dash) / 2) / len);
      const t1 = Math.min(1, t0 + it.dash / len);
      pts[0] = a.x + dx * t0; pts[1] = a.y + dy * t0; pts[2] = a.z + dz * t0;
      pts[3] = a.x + dx * t1; pts[4] = a.y + dy * t1; pts[5] = a.z + dz * t1;
    } else {
      for (let k = 0; k < cnt; k++) { const p = P[it.atoms[k]]; pts[3 * k] = p.x; pts[3 * k + 1] = p.y; pts[3 * k + 2] = p.z; }
    }
    const tangent = (k, out) => {
      const i1 = Math.min(k + 1, cnt - 1) * 3, i0 = Math.max(k - 1, 0) * 3;
      let x = pts[i1] - pts[i0], y = pts[i1 + 1] - pts[i0 + 1], z = pts[i1 + 2] - pts[i0 + 2];
      const l = Math.hypot(x, y, z) || 1; out[0] = x / l; out[1] = y / l; out[2] = z / l;
    };
    const T = TT, N = TN;
    let hasPrev = false;
    for (let k = 0; k < cnt; k++) {
      tangent(k, T);
      let nx, ny, nz;
      if (hasPrev) { const d = N[0] * T[0] + N[1] * T[1] + N[2] * T[2]; nx = N[0] - T[0] * d; ny = N[1] - T[1] * d; nz = N[2] - T[2] * d; }
      else { nx = -T[1]; ny = T[0]; nz = 0; } // (0,0,1) × T
      if (nx * nx + ny * ny + nz * nz < 1e-6) { nx = 0; ny = -T[2]; nz = T[1]; } // (1,0,0) × T
      const l = Math.hypot(nx, ny, nz) || 1; N[0] = nx / l; N[1] = ny / l; N[2] = nz / l; hasPrev = true;
      const bx = T[1] * N[2] - T[2] * N[1], by = T[2] * N[0] - T[0] * N[2], bz = T[0] * N[1] - T[1] * N[0];
      const px = pts[3 * k], py = pts[3 * k + 1], pz = pts[3 * k + 2];
      for (let m = 0; m < M; m++) {
        const c = this.cosA[m], s = this.sinA[m];
        const dx = N[0] * c + bx * s, dy = N[1] * c + by * s, dz = N[2] * c + bz * s;
        const o = (it.v0 + k * M + m) * 3;
        pos[o] = px + dx * r; pos[o + 1] = py + dy * r; pos[o + 2] = pz + dz * r;
        nor[o] = dx; nor[o + 1] = dy; nor[o + 2] = dz;
      }
    }
    this.writeCaps(it.v0, cnt, (k, out) => { out[0] = pts[3 * k]; out[1] = pts[3 * k + 1]; out[2] = pts[3 * k + 2]; },
      (k, sign, out) => { tangent(k, out); out[0] *= sign; out[1] *= sign; out[2] *= sign; });
  }

  /** The two flat end caps after `rings` rings starting at v0: centre vertex + a copy of the end ring. */
  writeCaps(v0, rings, center, normal) {
    const M = this.M, pos = this.pos, nor = this.nor, C = TC, Nn = TB;
    let v = v0 + rings * M;
    for (const [k, sign] of [[0, -1], [rings - 1, 1]]) {
      center(k, C); normal(k, sign, Nn);
      let o = v * 3;
      pos[o] = C[0]; pos[o + 1] = C[1]; pos[o + 2] = C[2]; nor[o] = Nn[0]; nor[o + 1] = Nn[1]; nor[o + 2] = Nn[2];
      for (let m = 0; m < M; m++) {
        o = (v + 1 + m) * 3; const src = (v0 + k * M + m) * 3;
        pos[o] = pos[src]; pos[o + 1] = pos[src + 1]; pos[o + 2] = pos[src + 2];
        nor[o] = Nn[0]; nor[o + 1] = Nn[1]; nor[o + 2] = Nn[2];
      }
      v += M + 1;
    }
  }

  updateSegment(it, P) {
    const M = this.M, n = it.n, pos = this.pos, nor = this.nor;
    const ctrl = it.ctrl, G = it.guide, SG = it.sg, ca = it.ca;
    // Control points (CA), strands smoothed.
    for (let i = 0; i < n; i++) {
      const p = P[ca[i]], j = 3 * i;
      if (it.smooth[i]) {
        const a = P[ca[i - 1]], b = P[ca[i + 1]];
        ctrl[j] = 0.5 * p.x + 0.25 * (a.x + b.x); ctrl[j + 1] = 0.5 * p.y + 0.25 * (a.y + b.y); ctrl[j + 2] = 0.5 * p.z + 0.25 * (a.z + b.z);
      } else { ctrl[j] = p.x; ctrl[j + 1] = p.y; ctrl[j + 2] = p.z; }
    }
    // Guides: C=O direction, made consistent and orthogonal to the local trace.
    for (let i = 0; i < n; i++) {
      const i1 = Math.min(i + 1, n - 1) * 3, i0 = Math.max(i - 1, 0) * 3;
      let tx = ctrl[i1] - ctrl[i0], ty = ctrl[i1 + 1] - ctrl[i0 + 1], tz = ctrl[i1 + 2] - ctrl[i0 + 2];
      const tl = Math.hypot(tx, ty, tz); if (tl > 0) { tx /= tl; ty /= tl; tz /= tl; }
      let gx, gy, gz;
      const o = it.o[i], c = it.c[i];
      if (o >= 0 && c >= 0 && P[o] && P[c]) { gx = P[o].x - P[c].x; gy = P[o].y - P[c].y; gz = P[o].z - P[c].z; }
      else if (i > 0 && i < n - 1) {
        const q = P[ca[i]], a = P[ca[i - 1]], b = P[ca[i + 1]];
        const ux = a.x - q.x, uy = a.y - q.y, uz = a.z - q.z, wx = b.x - q.x, wy = b.y - q.y, wz = b.z - q.z;
        gx = uy * wz - uz * wy; gy = uz * wx - ux * wz; gz = ux * wy - uy * wx;
      } else { gx = 0; gy = 1; gz = 0; }
      const d = gx * tx + gy * ty + gz * tz;
      gx -= tx * d; gy -= ty * d; gz -= tz * d;
      if (gx * gx + gy * gy + gz * gz < 1e-8) { gx = 0; gy = -tz; gz = ty; } // (1,0,0) × tan
      const gl = Math.hypot(gx, gy, gz) || 1; gx /= gl; gy /= gl; gz /= gl;
      const j = 3 * i;
      if (i > 0 && gx * G[j - 3] + gy * G[j - 2] + gz * G[j - 1] < 0) { gx = -gx; gy = -gy; gz = -gz; }
      G[j] = gx; G[j + 1] = gy; G[j + 2] = gz;
    }
    // Smooth strand guides (remove the alternation left after flipping).
    for (let i = 0; i < n; i++) {
      const j = 3 * i;
      if (!it.strand[i]) { SG[j] = G[j]; SG[j + 1] = G[j + 1]; SG[j + 2] = G[j + 2]; continue; }
      const a = Math.max(i - 1, 0) * 3, b = Math.min(i + 1, n - 1) * 3;
      const x = 2 * G[j] + G[a] + G[b], y = 2 * G[j + 1] + G[a + 1] + G[b + 1], z = 2 * G[j + 2] + G[a + 2] + G[b + 2];
      const l = Math.hypot(x, y, z) || 1; SG[j] = x / l; SG[j + 1] = y / l; SG[j + 2] = z / l;
    }
    // Sample the Catmull-Rom spline and the guides.
    const ns = it.ns, sp = it.sp, sgS = it.sgS;
    for (let k = 0; k < ns; k++) {
      const i = it.sI[k], t = it.sF[k], t2 = t * t, t3 = t2 * t;
      const a = Math.max(i - 1, 0) * 3, b = i * 3, c = (i + 1) * 3, d = Math.min(i + 2, n - 1) * 3, o = 3 * k;
      for (let x = 0; x < 3; x++) {
        const p0 = ctrl[a + x], p1 = ctrl[b + x], p2 = ctrl[c + x], p3 = ctrl[d + x];
        sp[o + x] = 0.5 * ((2 * p1) + (-p0 + p2) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2 + (-p0 + 3 * p1 - 3 * p2 + p3) * t3);
        sgS[o + x] = SG[b + x] + (SG[c + x] - SG[b + x]) * t;
      }
    }
    // Frames and rings.
    let Tx = 1, Ty = 0, Tz = 0, Wx = 0, Wy = 1, Wz = 0;
    let T0x = 1, T0y = 0, T0z = 0;
    const prof = it.prof;
    for (let k = 0; k < ns; k++) {
      const a = Math.max(k - 1, 0) * 3, b = Math.min(k + 1, ns - 1) * 3;
      let tx = sp[b] - sp[a], ty = sp[b + 1] - sp[a + 1], tz = sp[b + 2] - sp[a + 2];
      if (tx * tx + ty * ty + tz * tz < 1e-10) { if (k > 0) { tx = Tx; ty = Ty; tz = Tz; } else { tx = 1; ty = 0; tz = 0; } }
      let l = Math.hypot(tx, ty, tz); tx /= l; ty /= l; tz /= l;
      const o = 3 * k, gx = sgS[o], gy = sgS[o + 1], gz = sgS[o + 2];
      const d = gx * tx + gy * ty + gz * tz;
      let wx = gx - tx * d, wy = gy - ty * d, wz = gz - tz * d;
      if (wx * wx + wy * wy + wz * wz < 1e-8) {
        if (k > 0) { wx = Wx; wy = Wy; wz = Wz; } else { wx = tz; wy = 0; wz = -tx; } // (0,1,0) × T
      }
      l = Math.hypot(wx, wy, wz) || 1; wx /= l; wy /= l; wz /= l;
      const bx = ty * wz - tz * wy, by = tz * wx - tx * wz, bz = tx * wy - ty * wx;
      Tx = tx; Ty = ty; Tz = tz; Wx = wx; Wy = wy; Wz = wz;
      if (k === 0) { T0x = tx; T0y = ty; T0z = tz; }
      const px = sp[o], py = sp[o + 1], pz = sp[o + 2], cap = it.capN[k];
      for (let m = 0; m < M; m++) {
        const q = (k * M + m) * 4, x = prof[q], y = prof[q + 1], nx = prof[q + 2], ny = prof[q + 3];
        const v = (it.v0 + k * M + m) * 3;
        pos[v] = px + wx * x + bx * y; pos[v + 1] = py + wy * x + by * y; pos[v + 2] = pz + wz * x + bz * y;
        if (cap) { nor[v] = -tx; nor[v + 1] = -ty; nor[v + 2] = -tz; }
        else { nor[v] = wx * nx + bx * ny; nor[v + 1] = wy * nx + by * ny; nor[v + 2] = wz * nx + bz * ny; }
      }
    }
    const last = (ns - 1) * 3;
    this.writeCaps(it.v0, ns, (k, out) => { const o = k ? last : 0; out[0] = sp[o]; out[1] = sp[o + 1]; out[2] = sp[o + 2]; },
      (k, sign, out) => { if (k) { out[0] = Tx * sign; out[1] = Ty * sign; out[2] = Tz * sign; } else { out[0] = T0x * sign; out[1] = T0y * sign; out[2] = T0z * sign; } });
  }
}
// Scratch for CartoonGeometry (single-threaded, not re-entrant).
const TT = new Float64Array(3), TN = new Float64Array(3), TC = new Float64Array(3), TB = new Float64Array(3);

// ---------- app wiring ----------

/** Fetches secondary structure for the active document and switches newly opened proteins to cartoon. */
export function installCartoon(app) {
  let seq = 0;
  const looksProtein = (m) => m && m.atoms.length >= 20 && m.atoms.some((a) => a.z === 7);
  const refresh = async () => {
    const d = app.active;
    const vp = app.viewport;
    const my = ++seq;
    if (!d || !looksProtein(d.molecule)) { if (vp.cartoon.data) vp.cartoon.setData(null); return; }
    const n = d.molecule.atoms.length;
    let ss = d.cache?.secondaryStructure;
    if (!ss || ss.atomCount !== n) {
      try { ss = await request('analysis.secondaryStructure', { docId: d.docId }); } catch (e) { ss = null; console.warn('secondary structure:', e.message); }
      if (d.cache) d.cache.secondaryStructure = ss;
    }
    if (my !== seq || app.active !== d) return;
    if (!ss || ss.atomCount !== vp.molecule?.atoms.length) { vp.cartoon.setData(null); return; }
    if (vp.cartoon.data !== ss) vp.cartoon.setData(ss);
    // Auto-select the cartoon the first time a protein file is shown.
    if (!d.cartoonChecked) {
      d.cartoonChecked = true;
      if (d.path && ss.residueCount >= 20 && vp.options.style !== 'cartoon') {
        d.styleBeforeCartoon = vp.options.style;
        vp.setOptions({ style: 'cartoon' });
      }
      // Waters and chains outside the assembly are hidden now and no longer count for the view.
      if (d.path && vp.options.style === 'cartoon') vp.fit();
    }
  };
  let t = null;
  const soon = () => { clearTimeout(t); t = setTimeout(refresh, 30); };
  app.on('doc', soon);
  app.on('molecule', soon);
}
