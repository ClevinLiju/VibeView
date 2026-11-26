// Protein cartoon: helices as ribbons, strands as arrows, loops as tubes (style "cartoon").
//
// Data comes from the engine's analysis.secondaryStructure (per-residue N/CA/C/O atom indices, secondary structure
// letters, continuous backbone segments, the chain of every atom and the file's biological assembly 1). The trace is a
// Catmull-Rom spline through the CA atoms (strand CAs are smoothed to take out the pleat); the ribbon's width direction
// follows the carbonyl C=O vectors, flipped to stay consistent. All profiles share one vertex count, so a segment is a
// single continuous tube whose cross-section morphs between round (loops), flat ellipse (helices) and rounded box
// (strands). Everything is merged into one BufferGeometry, rebuilt from scratch on every build (never added twice).
//
// RCSB/Mol*-like defaults: colour "auto" (one chain: rainbow N→C; several chains: one colour per chain), waters hidden,
// ligands as ball and stick with their carbons tinted by chain, only the chains of biological assembly 1 shown (its
// symmetry copies are drawn as transformed copies of the same meshes), chain gaps (missing residues) as dashes.
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
    this.builtFrom = null;
    this.lastBuildMs = 0;
    this.lastBuildAt = 0;
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
    const geo = buildGeometry(this.data, vp.positions, vp.options, this.drawn);
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
    this.builtFrom = vp.positions;
    this.lastBuildMs = performance.now() - t0;
    this.lastBuildAt = performance.now();
  }

  /** Called from updateMatrices(): follow displayed positions (trajectory frames, vibrations), throttled. */
  sync() {
    if (!this.mesh || this.builtFrom === this.vp.positions) return;
    const now = performance.now();
    if (this.lastBuildMs > 25 && now - this.lastBuildAt < 8 * this.lastBuildMs) return;
    const group = this.mesh.parent;
    if (group) this.build(group);
  }

  disposeMesh() {
    for (const c of this.copies) c.parent?.remove(c); // geometry and buffers are shared: nothing of their own to free
    this.copies = [];
    if (!this.mesh) return;
    this.mesh.parent?.remove(this.mesh);
    this.mesh.geometry.dispose();
    this.mesh.material.dispose();
    this.mesh = null;
  }
}

// ---------- geometry ----------

function catmull(p0, p1, p2, p3, t, out) {
  const t2 = t * t, t3 = t2 * t;
  for (const c of ['x', 'y', 'z']) {
    out[c] = 0.5 * ((2 * p1[c]) + (-p0[c] + p2[c]) * t + (2 * p0[c] - 5 * p1[c] + 4 * p2[c] - p3[c]) * t2 + (-p0[c] + 3 * p1[c] - 3 * p2[c] + p3[c]) * t3);
  }
  return out;
}

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

function buildGeometry(data, positions, options, drawn) {
  const segments = data.segments.filter(([s]) => !drawn || drawn[s]);
  const total = segments.reduce((a, [s, e]) => a + (e - s), 0);
  if (!total) return null;
  const S = total > 6000 ? 4 : total > 2000 ? 6 : 10; // samples per residue
  const M = total > 6000 ? 10 : 16; // vertices per ring
  const { colors, smoothColors } = residueColors(data, options, drawn);
  const pos = [], nor = [], col = [], idx = [];
  // profile unit circle
  const cosA = [], sinA = [];
  for (let k = 0; k < M; k++) { const a = (k / M) * Math.PI * 2; cosA.push(Math.cos(a)); sinA.push(Math.sin(a)); }

  /** Round tube along a polyline (lone residues, gap dashes), with flat end caps. */
  const tube = (pts, radius, color) => {
    if (pts.length < 2) return;
    const rings = [];
    let prevN = null;
    for (let k = 0; k < pts.length; k++) {
      const T = new THREE.Vector3().subVectors(pts[Math.min(k + 1, pts.length - 1)], pts[Math.max(k - 1, 0)]).normalize();
      let N = prevN ? prevN.clone().addScaledVector(T, -prevN.dot(T)) : new THREE.Vector3(0, 0, 1).cross(T);
      if (N.lengthSq() < 1e-6) N = new THREE.Vector3(1, 0, 0).cross(T);
      N.normalize(); prevN = N;
      const B = new THREE.Vector3().crossVectors(T, N);
      rings.push(pos.length / 3);
      for (let m = 0; m < M; m++) {
        const d = N.clone().multiplyScalar(cosA[m]).addScaledVector(B, sinA[m]);
        pos.push(pts[k].x + d.x * radius, pts[k].y + d.y * radius, pts[k].z + d.z * radius);
        nor.push(d.x, d.y, d.z); col.push(color.r, color.g, color.b);
      }
    }
    for (let k = 0; k + 1 < rings.length; k++) {
      for (let m = 0; m < M; m++) {
        const a = rings[k], b = rings[k + 1], m2 = (m + 1) % M;
        idx.push(a + m, a + m2, b + m, a + m2, b + m2, b + m);
      }
    }
    for (const [k, sign] of [[0, -1], [pts.length - 1, 1]]) {
      const T = new THREE.Vector3().subVectors(pts[Math.min(k + 1, pts.length - 1)], pts[Math.max(k - 1, 0)]).normalize().multiplyScalar(sign);
      const center = pos.length / 3;
      pos.push(pts[k].x, pts[k].y, pts[k].z); nor.push(T.x, T.y, T.z); col.push(color.r, color.g, color.b);
      const ring = pos.length / 3;
      for (let m = 0; m < M; m++) { const v = rings[k] + m; pos.push(pos[v * 3], pos[v * 3 + 1], pos[v * 3 + 2]); nor.push(T.x, T.y, T.z); col.push(color.r, color.g, color.b); }
      for (let m = 0; m < M; m++) { const m2 = (m + 1) % M; if (sign > 0) idx.push(center, ring + m, ring + m2); else idx.push(center, ring + m2, ring + m); }
    }
  };
  const P = (i) => (i >= 0 ? positions[i] : null);

  // Missing residues inside a chain (a break between consecutive segments of the same chain): a dashed line between
  // the two CA atoms, like Mol*.
  for (let k = 0; k + 1 < segments.length; k++) {
    const e = segments[k][1] - 1, s2 = segments[k + 1][0];
    if (data.chain[e] !== data.chain[s2] || s2 !== e + 1) continue;
    const a = P(data.ca[e]), b = P(data.ca[s2]);
    if (!a || !b) continue;
    const len = a.distanceTo(b);
    if (len < 4.2 || len > 80) continue;
    const dash = 0.5, period = 1.0, nd = Math.floor(len / period);
    const c = new THREE.Color(0xa0a4aa);
    for (let j = 0; j < nd; j++) {
      const t0 = (j * period + (len - nd * period + period - dash) / 2) / len, t1 = t0 + dash / len;
      if (t1 > 1) break;
      tube([a.clone().lerp(b, t0), a.clone().lerp(b, t1)], 0.12, c);
    }
  }

  for (const [s, e] of segments) {
    const n = e - s;
    if (n < 2) {
      // Lone residue (neighbours missing): a short loop tube N–CA–C.
      const pts = [P(data.n[s]), P(data.ca[s]), P(data.c[s])].filter(Boolean).map((p) => p.clone());
      tube(pts, LOOP.w, colors[s]);
      continue;
    }
    const ss = []; for (let r = s; r < e; r++) ss.push(kind(data.ss[r]));
    // Control points (CA), strands smoothed.
    const ca = [];
    for (let r = s; r < e; r++) ca.push(positions[data.ca[r]].clone());
    const ctrl = ca.map((p, i) => {
      if (ss[i] === 'strand' && i > 0 && i < n - 1 && ss[i - 1] === 'strand' && ss[i + 1] === 'strand') {
        return p.clone().multiplyScalar(0.5).addScaledVector(ca[i - 1], 0.25).addScaledVector(ca[i + 1], 0.25);
      }
      return p;
    });
    // Guides: C=O direction, made consistent and orthogonal to the local trace.
    const guide = [];
    for (let i = 0; i < n; i++) {
      const r = s + i;
      const tan = new THREE.Vector3().subVectors(ctrl[Math.min(i + 1, n - 1)], ctrl[Math.max(i - 1, 0)]).normalize();
      let g;
      const o = data.o[r], c = data.c[r];
      if (o >= 0 && c >= 0 && positions[o] && positions[c]) g = new THREE.Vector3().subVectors(positions[o], positions[c]);
      else if (i > 0 && i < n - 1) g = new THREE.Vector3().subVectors(ca[i - 1], ca[i]).cross(new THREE.Vector3().subVectors(ca[i + 1], ca[i]));
      else g = new THREE.Vector3(0, 1, 0);
      g.addScaledVector(tan, -g.dot(tan));
      if (g.lengthSq() < 1e-8) g = new THREE.Vector3(1, 0, 0).cross(tan);
      g.normalize();
      if (i > 0 && g.dot(guide[i - 1]) < 0) g.negate();
      guide.push(g);
    }
    // Smooth strand guides (remove the alternation left after flipping).
    const sg = guide.map((g, i) => {
      if (ss[i] !== 'strand') return g;
      const a = guide[Math.max(i - 1, 0)], b = guide[Math.min(i + 1, n - 1)];
      return g.clone().multiplyScalar(2).add(a).add(b).normalize();
    });

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
            return { w: ARROW * (1 - u) + LOOP.w * u, h: STRAND.h * (1 - u) + LOOP.h * u, n: STRAND.n * (1 - u) + 2 * u, ss: 'strand', res: j };
          }
          if (t > j + 0.6 && t < j + 1) return { ...LOOP, ss: ss[Math.min(n - 1, j + 1)], res: Math.min(n - 1, j + 1) };
        }
      }
      const A = prof(ss[lo]), B = prof(ss[hi]);
      // A strand that just ended in an arrow must not blend back up into the next residue.
      if (ss[lo] === 'strand' && ss[hi] !== 'strand') return { ...B, ss: ss[i], res: i };
      const m = ss[lo] === ss[hi] ? 0 : smooth(f);
      return { w: A.w + (B.w - A.w) * m, h: A.h + (B.h - A.h) * m, n: A.n + (B.n - A.n) * m, ss: ss[i], res: i };
    };

    // Sample the spline.
    const samples = [];
    const steps = (n - 1) * S;
    const P = new THREE.Vector3();
    for (let k = 0; k <= steps; k++) {
      const t = k / S;
      const i = Math.min(n - 2, Math.floor(t)), f = t - i;
      const p0 = ctrl[Math.max(i - 1, 0)], p1 = ctrl[i], p2 = ctrl[i + 1], p3 = ctrl[Math.min(i + 2, n - 1)];
      catmull(p0, p1, p2, p3, f, P);
      const g = sg[i].clone().lerp(sg[i + 1], f);
      samples.push({ t, p: P.clone(), g });
    }
    // Insert the arrow base (two extra samples at the same position: narrow end + wide start).
    for (let j = 1; j < n; j++) {
      if (!(ss[j] === 'strand' && ss[j - 1] === 'strand' && (j === n - 1 || ss[j + 1] !== 'strand'))) continue;
      const tb = j - 0.5;
      const k = samples.findIndex((q) => q.t > tb);
      if (k <= 0) continue;
      const a = samples[k - 1], b = samples[k];
      const f = (tb - a.t) / (b.t - a.t);
      const p = a.p.clone().lerp(b.p, f), g = a.g.clone().lerp(b.g, f);
      samples.splice(k, 0, { t: tb - 1e-4, p, g, forceBody: true }, { t: tb, p: p.clone(), g: g.clone(), cap: true }, { t: tb, p: p.clone(), g: g.clone() });
    }
    // Frames and rings.
    const ringStart = [];
    for (let k = 0; k < samples.length; k++) {
      const q = samples[k];
      const a = samples[Math.max(k - 1, 0)].p, b = samples[Math.min(k + 1, samples.length - 1)].p;
      let T = new THREE.Vector3().subVectors(b, a);
      if (T.lengthSq() < 1e-10) T = k > 0 ? samples[k - 1].T.clone() : new THREE.Vector3(1, 0, 0);
      T.normalize();
      q.T = T;
      const W = q.g.clone().addScaledVector(T, -q.g.dot(T));
      if (W.lengthSq() < 1e-8) W.copy(k > 0 ? samples[k - 1].W : new THREE.Vector3(0, 1, 0).cross(T));
      W.normalize();
      q.W = W;
      const B = new THREE.Vector3().crossVectors(T, W);
      let sh = shapeAt(q.t);
      if (q.forceBody) sh = { ...STRAND, ss: 'strand', res: Math.round(q.t + 0.5) };
      if (q.cap) sh = { ...STRAND, w: ARROW, ss: 'strand', res: Math.round(q.t + 0.5) };
      const c = colors[s + Math.min(n - 1, Math.max(0, sh.res))];
      // Rainbow interpolates smoothly; the others switch at residue boundaries.
      let cr = c;
      if (smoothColors) {
        const lo = Math.min(n - 2, Math.floor(q.t)), f = q.t - lo;
        cr = colors[s + lo].clone().lerp(colors[s + lo + 1], Math.max(0, Math.min(1, f)));
      }
      ringStart.push(pos.length / 3);
      const e2 = 2 / sh.n;
      for (let m = 0; m < M; m++) {
        const cx = cosA[m], sy = sinA[m];
        const x = Math.sign(cx) * Math.pow(Math.abs(cx), e2) * sh.w;
        const y = Math.sign(sy) * Math.pow(Math.abs(sy), e2) * sh.h;
        // Superellipse normal ∝ (sign(c)|c|^(2-2/n)/w, sign(s)|s|^(2-2/n)/h).
        const nx = Math.sign(cx) * Math.pow(Math.abs(cx), 2 - e2) / sh.w;
        const ny = Math.sign(sy) * Math.pow(Math.abs(sy), 2 - e2) / sh.h;
        pos.push(q.p.x + W.x * x + B.x * y, q.p.y + W.y * x + B.y * y, q.p.z + W.z * x + B.z * y);
        let N;
        if (q.cap || (k > 0 && samples[k - 1].cap)) N = T.clone().negate();
        else N = new THREE.Vector3().addScaledVector(W, nx).addScaledVector(B, ny).normalize();
        nor.push(N.x, N.y, N.z);
        col.push(cr.r, cr.g, cr.b);
      }
    }
    for (let k = 0; k + 1 < samples.length; k++) {
      const a = ringStart[k], b = ringStart[k + 1];
      for (let m = 0; m < M; m++) {
        const m2 = (m + 1) % M;
        idx.push(a + m, a + m2, b + m, a + m2, b + m2, b + m);
      }
    }
    // End caps.
    for (const [k, sign] of [[0, -1], [samples.length - 1, 1]]) {
      const q = samples[k];
      const base = ringStart[k];
      const center = pos.length / 3;
      const c = new THREE.Color(col[base * 3], col[base * 3 + 1], col[base * 3 + 2]);
      pos.push(q.p.x, q.p.y, q.p.z); nor.push(q.T.x * sign, q.T.y * sign, q.T.z * sign); col.push(c.r, c.g, c.b);
      const ring = pos.length / 3;
      for (let m = 0; m < M; m++) {
        const v = base + m;
        pos.push(pos[v * 3], pos[v * 3 + 1], pos[v * 3 + 2]);
        nor.push(q.T.x * sign, q.T.y * sign, q.T.z * sign);
        col.push(c.r, c.g, c.b);
      }
      for (let m = 0; m < M; m++) {
        const m2 = (m + 1) % M;
        if (sign > 0) idx.push(center, ring + m, ring + m2); else idx.push(center, ring + m2, ring + m);
      }
    }
  }
  const g = new THREE.BufferGeometry();
  g.setAttribute('position', new THREE.Float32BufferAttribute(pos, 3));
  g.setAttribute('normal', new THREE.Float32BufferAttribute(nor, 3));
  g.setAttribute('color', new THREE.Float32BufferAttribute(col, 3));
  g.setIndex(pos.length / 3 > 65535 ? new THREE.Uint32BufferAttribute(idx, 1) : new THREE.Uint16BufferAttribute(idx, 1));
  g.computeBoundingSphere();
  return g;
}

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
