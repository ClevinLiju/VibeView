// Protein cartoon: helices as ribbons, strands as arrows, loops as tubes (style "cartoon").
//
// Data comes from the engine's analysis.secondaryStructure (per-residue N/CA/C/O atom indices, secondary structure
// letters and continuous backbone segments). The trace is a Catmull-Rom spline through the CA atoms (strand CAs are
// smoothed to take out the pleat); the ribbon's width direction follows the carbonyl C=O vectors, flipped to stay
// consistent. All profiles share one vertex count, so a segment is a single continuous tube whose cross-section morphs
// between round (loops), flat ellipse (helices) and rounded box (strands). Everything is merged into one BufferGeometry.
import * as THREE from 'three';
import { STYLE_ICONS } from './icons.js';
import { request } from './api.js';

STYLE_ICONS.cartoon = '<svg viewBox="0 0 54 34"><path d="M4 24c6-14 10-14 14 0s8 14 12 0" fill="none" stroke="#e0457b" stroke-width="5" stroke-linecap="round"/><path d="M32 12h12v-4l8 8-8 8v-4H32z" fill="#f2c230"/></svg>';

export const CARTOON_STYLE = { value: 'cartoon', label: 'Cartoon' };
export const CARTOON_COLORS = [
  { value: 'ss', label: 'Secondary structure' }, { value: 'chain', label: 'Chain' },
  { value: 'rainbow', label: 'Rainbow (N→C)' }, { value: 'uniform', label: 'Single colour' },
];

const SS_COLORS = { helix: 0xe0457b, strand: 0xf2c230, loop: 0xc8ccd2 };
const CHAIN_COLORS = [0x4e8fd8, 0x5cbf73, 0xe48a3a, 0xb06fd0, 0x3fb8b0, 0xd85a5a, 0xc9b23d, 0x7a8ee0, 0xe07ab8, 0x8ab84e];

function kind(ch) {
  if (ch === 'H' || ch === 'G' || ch === 'I') return 'helix';
  if (ch === 'E') return 'strand';
  return 'loop';
}

// Cross-section shapes: half width (along the C=O guide), half thickness, superellipse exponent.
const LOOP = { w: 0.3, h: 0.3, n: 2 };
const HELIX = { w: 1.25, h: 0.28, n: 2 };
const STRAND = { w: 1.05, h: 0.3, n: 5 };
const ARROW = 1.65; // arrow base half width
const smooth = (f) => f * f * (3 - 2 * f);

export class CartoonLayer {
  constructor(vp) {
    this.vp = vp;
    this.data = null;
    this.mesh = null;
    this.covered = null; // Uint8Array per atom: 1 polymer (cartoon), 2 water
    this.caIndex = null; // Set of CA atoms (pickable stand-ins for hidden residues)
    this.builtFrom = null;
    this.lastBuildMs = 0;
    this.lastBuildAt = 0;
  }

  /** Engine result (or null). Must match the viewport's current molecule. */
  setData(data) {
    this.data = data && data.residueCount > 0 ? data : null;
    this.covered = null; this.caIndex = null;
    if (this.data) {
      const n = this.data.atomCount;
      const cov = new Uint8Array(n);
      // Only residues in segments with >= 2 residues get a cartoon; others stay as atoms.
      const drawn = new Uint8Array(this.data.residueCount);
      for (const [s, e] of this.data.segments) if (e - s >= 2) for (let r = s; r < e; r++) drawn[r] = 1;
      const lone = new Set();
      for (let r = 0; r < this.data.residueCount; r++) if (!drawn[r]) for (const k of ['n', 'ca', 'c', 'o']) if (this.data[k][r] >= 0) lone.add(this.data[k][r]);
      for (const i of this.data.polymerAtoms) if (i < n && !lone.has(i)) cov[i] = 1;
      for (const i of this.data.waterAtoms) if (i < n) cov[i] = 2;
      this.covered = cov;
      this.caIndex = new Set(this.data.ca.filter((i, r) => drawn[r]));
    }
    this.vp.rebuild();
  }

  /** Cartoon applies to the molecule now shown. */
  active() {
    const vp = this.vp;
    return vp.options.style === 'cartoon' && !!this.data && !!vp.molecule && vp.molecule.atoms.length === this.data.atomCount;
  }

  /** Atom drawn by the cartoon (or a water hidden in cartoon mode). */
  hides(i) { return !!(this.covered && this.covered[i] && this.active()); }

  /** Waters hidden by the cartoon don't count for zoom-to-fit. */
  excludesFromFit(i) { return !!(this.covered && this.covered[i] === 2 && this.active()); }

  /** CA atom standing in for a cartoon residue (picking, selection highlight). */
  isPickable(i) { return !!(this.caIndex && this.caIndex.has(i) && this.active()); }

  /** Pick the CA of a cartoon residue near the ray (atoms under the cartoon stay pickable through their CA). */
  pick(ray, best) {
    if (!this.active() || !this.caIndex) return best;
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

  /** Called at the end of Viewport.rebuild(): (re)creates the cartoon mesh in `group`. */
  build(group) {
    this.disposeMesh();
    if (!this.active()) return;
    const t0 = performance.now();
    const geo = buildGeometry(this.data, this.vp.positions, this.vp.options);
    if (!geo) return;
    const vp = this.vp;
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

function residueColors(data, options) {
  const R = data.residueCount;
  const out = new Array(R);
  const mode = options.cartoonColor || 'ss';
  const chains = [...new Set(data.chain)];
  for (let r = 0; r < R; r++) {
    let c;
    if (mode === 'chain') c = new THREE.Color(CHAIN_COLORS[chains.indexOf(data.chain[r]) % CHAIN_COLORS.length]);
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
        for (let k = s; k < r; k++) out[k] = new THREE.Color().setHSL(0.66 * (1 - (k - s) / len), 0.75, 0.52);
        s = r;
      }
    }
  }
  return out;
}

function buildGeometry(data, positions, options) {
  const R = data.residueCount;
  const total = data.segments.reduce((a, [s, e]) => a + (e - s >= 2 ? e - s : 0), 0);
  if (!total) return null;
  const S = total > 6000 ? 4 : total > 2000 ? 6 : 10; // samples per residue
  const M = total > 6000 ? 10 : 16; // vertices per ring
  const colors = residueColors(data, options);
  const pos = [], nor = [], col = [], idx = [];
  // profile unit circle
  const cosA = [], sinA = [];
  for (let k = 0; k < M; k++) { const a = (k / M) * Math.PI * 2; cosA.push(Math.cos(a)); sinA.push(Math.sin(a)); }

  for (const [s, e] of data.segments) {
    const n = e - s;
    if (n < 2) continue;
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
      if ((options.cartoonColor || 'ss') === 'rainbow') {
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
        vp.fit(); // waters are hidden now and no longer count for the view
      }
    }
  };
  let t = null;
  const soon = () => { clearTimeout(t); t = setTimeout(refresh, 30); };
  app.on('doc', soon);
  app.on('molecule', soon);
}
