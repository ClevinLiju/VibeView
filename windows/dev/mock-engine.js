#!/usr/bin/env node
'use strict';
// A small stand-in for vibeview-engine.exe that implements part of docs/WINDOWS_PROTOCOL.md, for UI
// development without the Swift build. Run by Electron with ELECTRON_RUN_AS_NODE=1, or plain `node`.
// It understands XYZ files and the final geometry of ORCA/Gaussian outputs; results are synthetic.
const fs = require('fs');
const path = require('path');
const readline = require('readline');

const SYMBOLS = ['X', 'H', 'He', 'Li', 'Be', 'B', 'C', 'N', 'O', 'F', 'Ne', 'Na', 'Mg', 'Al', 'Si', 'P', 'S', 'Cl', 'Ar', 'K', 'Ca',
  'Sc', 'Ti', 'V', 'Cr', 'Mn', 'Fe', 'Co', 'Ni', 'Cu', 'Zn', 'Ga', 'Ge', 'As', 'Se', 'Br', 'Kr', 'Rb', 'Sr', 'Y', 'Zr', 'Nb', 'Mo',
  'Tc', 'Ru', 'Rh', 'Pd', 'Ag', 'Cd', 'In', 'Sn', 'Sb', 'Te', 'I', 'Xe'];
const COV = { 1: 0.31, 5: 0.84, 6: 0.76, 7: 0.71, 8: 0.66, 9: 0.57, 14: 1.11, 15: 1.07, 16: 1.05, 17: 1.02, 35: 1.2, 53: 1.39 };
const MASS = { 1: 1.008, 6: 12.011, 7: 14.007, 8: 15.999, 9: 18.998, 16: 32.06, 17: 35.45 };
const zOf = (s) => { const i = SYMBOLS.findIndex((x) => x.toLowerCase() === String(s).toLowerCase()); return i > 0 ? i : (Number(s) || 6); };

function send(obj) { process.stdout.write(JSON.stringify(obj) + '\n'); }
function log(t) { process.stderr.write(`[mock] ${t}\n`); }

// ---------- molecules ----------
function atom(z, pos) { return { z, symbol: SYMBOLS[z] || 'X', pos, charge: 0, label: null }; }
function dist(a, b) { return Math.hypot(a[0] - b[0], a[1] - b[1], a[2] - b[2]); }
function perceiveBonds(atoms) {
  const bonds = [];
  for (let i = 0; i < atoms.length; i++) for (let j = i + 1; j < atoms.length; j++) {
    const r = (COV[atoms[i].z] || 0.8) + (COV[atoms[j].z] || 0.8);
    const d = dist(atoms[i].pos, atoms[j].pos);
    if (d < r * 1.15 && d > 0.3) {
      let order = 1;
      if (atoms[i].z !== 1 && atoms[j].z !== 1) { if (d < r * 0.82) order = 3; else if (d < r * 0.91) order = 2; }
      bonds.push({ a: i, b: j, order });
    }
  }
  return bonds;
}
function formula(m) {
  const c = {};
  for (const a of m.atoms) c[a.symbol] = (c[a.symbol] || 0) + 1;
  const keys = Object.keys(c).sort((x, y) => (x === 'C' ? -1 : y === 'C' ? 1 : x === 'H' ? -1 : y === 'H' ? 1 : x.localeCompare(y)));
  return keys.map((k) => k + (c[k] > 1 ? c[k] : '')).join('');
}
function parseXYZFrames(text) {
  const lines = text.split(/\r?\n/);
  const frames = [];
  let i = 0;
  while (i < lines.length) {
    const n = parseInt(lines[i], 10);
    if (!(n > 0)) { i++; continue; }
    const title = lines[i + 1] || '';
    const atoms = [];
    for (let k = 0; k < n; k++) {
      const p = (lines[i + 2 + k] || '').trim().split(/\s+/);
      if (p.length < 4) break;
      atoms.push(atom(zOf(p[0]), [Number(p[1]), Number(p[2]), Number(p[3])]));
    }
    if (atoms.length === n) frames.push({ title, atoms });
    i += n + 2;
  }
  return frames;
}
function parseOutput(text) {
  // ORCA "CARTESIAN COORDINATES (ANGSTROEM)" blocks, else Gaussian "Standard orientation".
  const frames = [];
  const re = /CARTESIAN COORDINATES \(ANGSTROEM\)\s*\n-+\s*\n([\s\S]*?)\n\s*\n/g;
  let m;
  while ((m = re.exec(text))) {
    const atoms = m[1].trim().split(/\n/).map((l) => l.trim().split(/\s+/)).filter((p) => p.length >= 4)
      .map((p) => atom(zOf(p[0]), [Number(p[1]), Number(p[2]), Number(p[3])]));
    if (atoms.length) frames.push({ title: '', atoms });
  }
  const energies = [...text.matchAll(/FINAL SINGLE POINT ENERGY\s+(-?\d+\.\d+)/g)].map((x) => Number(x[1]));
  const freqs = [];
  const fm = text.match(/VIBRATIONAL FREQUENCIES[\s\S]*?\n\s*\n([\s\S]*?)\n\s*\n\s*\n/);
  if (fm) for (const l of fm[1].split('\n')) { const q = l.match(/^\s*\d+:\s+(-?\d+\.\d+)/); if (q && Math.abs(Number(q[1])) > 1) freqs.push(Number(q[1])); }
  return { frames, energies, freqs, program: /O\s+R\s+C\s+A/.test(text) ? 'ORCA' : null };
}
// PDB: ATOM/HETATM coordinates of the first model (element from columns 77-78, else the atom name).
function parsePDB(text) {
  const atoms = [];
  for (const l of text.split(/\r?\n/)) {
    if (/^ENDMDL/.test(l) && atoms.length) break;
    if (!/^(ATOM|HETATM)/.test(l)) continue;
    const el = l.slice(76, 78).trim() || l.slice(12, 16).trim().replace(/[^A-Za-z]/g, '').slice(0, 1);
    atoms.push(atom(zOf(el), [Number(l.slice(30, 38)), Number(l.slice(38, 46)), Number(l.slice(46, 54))]));
  }
  return atoms.length ? [{ title: '', atoms }] : [];
}

// analysis.secondaryStructure stand-in: backbone N–CA–C(=O) from the bond graph, residues ordered along the
// C–N peptide bonds, and a crude CA-distance classification (helix: CA i..i+3 ≈ 5–5.6 Å, strand: CA i−1..i+1
// > 6.4 Å). Same result shape as Sources/VibeViewEngine/Methods+Structure.swift.
function mockSecondaryStructure(m) {
  const n = m.atoms.length, z = (i) => m.atoms[i].z;
  const adj = m.atoms.map(() => []);
  for (const b of m.bonds) { adj[b.a].push(b.b); adj[b.b].push(b.a); }
  const heavy = (i) => adj[i].filter((j) => z(j) > 1);
  const res = [];
  const byN = new Map();
  for (let ca = 0; ca < n; ca++) {
    if (z(ca) !== 6) continue;
    const N = heavy(ca).find((j) => z(j) === 7);
    const C = heavy(ca).find((j) => z(j) === 6 && heavy(j).some((o) => z(o) === 8 && heavy(o).length === 1));
    if (N == null || C == null) continue;
    const O = heavy(C).find((o) => z(o) === 8 && heavy(o).length === 1);
    const r = { n: N, ca, c: C, o: O ?? -1, next: null, prev: null };
    res.push(r); byN.set(N, r);
  }
  for (const r of res) { const N2 = heavy(r.c).find((j) => z(j) === 7 && byN.has(j)); if (N2 != null) { r.next = byN.get(N2); r.next.prev = r; } }
  const ordered = [], segments = [];
  for (const r of res) {
    if (r.prev) continue;
    const s = ordered.length;
    for (let q = r; q && !q.seen; q = q.next) { q.seen = true; ordered.push(q); }
    segments.push([s, ordered.length]);
  }
  const R = ordered.length, ca = ordered.map((r) => m.atoms[r.ca].pos);
  const ss = new Array(R).fill('L');
  for (const [s, e] of segments) {
    for (let i = s; i + 3 < e; i++) { const d = dist(ca[i], ca[i + 3]); if (d > 4.6 && d < 5.8) for (let k = i; k <= i + 3; k++) ss[k] = 'H'; }
    for (let i = s + 1; i + 1 < e; i++) if (ss[i] !== 'H' && dist(ca[i - 1], ca[i + 1]) > 6.4) ss[i] = 'E';
  }
  const polymer = new Set();
  for (const r of ordered) {
    const stack = [r.n, r.ca, r.c, r.o].filter((i) => i >= 0);
    for (const i of stack) polymer.add(i);
    // side chain and hydrogens: atoms reachable from CA without crossing the backbone N or C
    const q = [r.ca];
    while (q.length) { const v = q.pop(); for (const w of adj[v]) if (!polymer.has(w) && w !== r.n && w !== r.c) { polymer.add(w); q.push(w); } }
    for (const i of [r.n, r.c, r.o]) for (const w of adj[i] || []) if (w >= 0 && z(w) === 1) polymer.add(w);
  }
  return {
    atomCount: n, residueCount: R, residueSource: 'topology', source: R ? 'computed' : 'none', ss: ss.join(''),
    chain: ordered.map(() => 'A'), seq: ordered.map((_, i) => i + 1), iCode: ordered.map(() => ''), name: ordered.map(() => 'UNK'),
    n: ordered.map((r) => r.n), ca: ordered.map((r) => r.ca), c: ordered.map((r) => r.c), o: ordered.map((r) => r.o),
    segments, polymerAtoms: [...polymer].sort((a, b) => a - b), waterAtoms: [],
    helixCount: ss.join('').split(/[^H]+/).filter(Boolean).length, strandCount: ss.join('').split(/[^E]+/).filter(Boolean).length,
  };
}

// ---------- documents ----------
const docs = new Map();
let docCounter = 1;
function newDoc(molecule, extra = {}) {
  const id = `doc${docCounter++}`;
  const d = { id, molecule, undo: [], redo: [], path: null, format: null, program: null, frames: [molecule], energies: [], freqs: [], ...extra };
  docs.set(id, d);
  return d;
}
function getDoc(p) { const d = docs.get(p.docId); if (!d) throw err('not_found', `no document ${p.docId}`); return d; }
function summary(d) {
  const m = d.molecule;
  return {
    docId: d.id, title: m.title, path: d.path, format: d.format, program: d.program, formula: formula(m), atomCount: m.atoms.length,
    frameCount: d.frames.length, canUndo: d.undo.length > 0, canRedo: d.redo.length > 0, hasWavefunction: !!d.program,
    volumeNames: [], modeCount: d.freqs.length, orbitalCount: d.program ? 24 : 0, excitedStateCount: 0, companions: d.companions || [], formchkPending: !!d.formchkPending,
  };
}
function clone(m) { return JSON.parse(JSON.stringify(m)); }
function err(code, message) { return Object.assign(new Error(message), { code }); }

const FRAGMENTS = [
  { id: 'benzene', name: 'Benzene', category: 'Rings' },
  { id: 'methyl', name: 'Methyl', category: 'Groups' },
  { id: 'hydroxyl', name: 'Hydroxyl', category: 'Groups' },
  { id: 'amino', name: 'Amino', category: 'Groups' },
  { id: 'carbonyl', name: 'Carbonyl', category: 'Groups' },
  { id: 'water', name: 'Water', category: 'Small molecules' },
];
function fragmentMolecule(id) {
  let atoms = [];
  if (id === 'benzene') {
    for (let k = 0; k < 6; k++) { const a = (k * Math.PI) / 3; atoms.push(atom(6, [1.39 * Math.cos(a), 1.39 * Math.sin(a), 0])); }
    for (let k = 0; k < 6; k++) { const a = (k * Math.PI) / 3; atoms.push(atom(1, [2.47 * Math.cos(a), 2.47 * Math.sin(a), 0])); }
    const bonds = [];
    for (let k = 0; k < 6; k++) { bonds.push({ a: k, b: (k + 1) % 6, order: 1.5 }); bonds.push({ a: k, b: k + 6, order: 1 }); }
    return { title: 'Benzene', charge: 0, multiplicity: 1, atoms, bonds };
  }
  if (id === 'water') atoms = [atom(8, [0, 0, 0]), atom(1, [0.757, 0.586, 0]), atom(1, [-0.757, 0.586, 0])];
  else if (id === 'methyl') atoms = [atom(6, [0, 0, 0]), atom(1, [0.63, 0.63, 0.63]), atom(1, [-0.63, -0.63, 0.63]), atom(1, [-0.63, 0.63, -0.63])];
  else if (id === 'hydroxyl') atoms = [atom(8, [0, 0, 0]), atom(1, [0.96, 0, 0])];
  else if (id === 'amino') atoms = [atom(7, [0, 0, 0]), atom(1, [0.5, 0.85, 0]), atom(1, [0.5, -0.85, 0])];
  else if (id === 'carbonyl') atoms = [atom(6, [0, 0, 0]), atom(8, [1.21, 0, 0])];
  else throw err('not_found', `unknown fragment ${id}`);
  return { title: id, charge: 0, multiplicity: 1, atoms, bonds: perceiveBonds(atoms) };
}

// build.groups subset (ids as in the engine): element, kind, hybridization, bondOrder; geometry is a crude template.
const MOCK_GROUPS = [
  { id: 'C.sp3', name: 'Carbon, tetrahedral (sp³)', label: 'C sp³', element: 6, kind: 'atom', hybridization: 'sp3', bondOrder: 1, z: [6, 1, 1, 1, 1] },
  { id: 'C.sp2', name: 'Carbon, trigonal (sp²)', label: 'C sp²', element: 6, kind: 'atom', hybridization: 'sp2', bondOrder: 1, z: [6, 1, 1, 1] },
  { id: 'C.methyl', name: 'Methyl', label: '–CH₃', element: 6, kind: 'group', hybridization: null, bondOrder: 1, z: [6, 1, 1, 1, 1] },
  { id: 'N.amino', name: 'Amine', label: '–NH₂', element: 7, kind: 'group', hybridization: null, bondOrder: 1, z: [7, 1, 1, 1] },
  { id: 'O.hydroxyl', name: 'Hydroxyl', label: '–OH', element: 8, kind: 'group', hybridization: null, bondOrder: 1, z: [8, 1, 1] },
  { id: 'O.carbonyl', name: 'Carbonyl (=O)', label: '=O', element: 8, kind: 'group', hybridization: 'sp2', bondOrder: 2, z: [8, 1] },
];
function groupMolecule(g) {
  const dirs = [[1, 1, 1], [1, -1, -1], [-1, 1, -1], [-1, -1, 1]].map((v) => v.map((x) => x / Math.sqrt(3)));
  const atoms = g.z.map((z, i) => atom(z, i === 0 ? [0, 0, 0] : dirs[i - 1].map((x) => x * 1.05)));
  return { title: g.name, charge: 0, multiplicity: 1, atoms, bonds: atoms.slice(1).map((_, i) => ({ a: 0, b: i + 1, order: 1 })) };
}

function commit(d, m) {
  d.undo.push(d.molecule); d.redo = []; d.molecule = m; d.frames = [m];
  return { summary: summary(d), molecule: m };
}
function applyEdit(d, op) {
  const m = clone(d.molecule);
  const bondIdx = (a, b) => m.bonds.findIndex((x) => (x.a === a && x.b === b) || (x.a === b && x.b === a));
  switch (op.type) {
    case 'addAtom': m.atoms.push(atom(op.z, op.pos)); break;
    case 'placeElement':
      if (op.at != null) { m.atoms[op.at].z = op.z; m.atoms[op.at].symbol = SYMBOLS[op.z]; } else m.atoms.push(atom(op.z, op.pos || [0, 0, 0]));
      break;
    case 'deleteAtoms': {
      const del = new Set(op.atoms);
      const map = []; let k = 0;
      m.atoms.forEach((_, i) => { map[i] = del.has(i) ? -1 : k++; });
      m.atoms = m.atoms.filter((_, i) => !del.has(i));
      m.bonds = m.bonds.filter((b) => map[b.a] >= 0 && map[b.b] >= 0).map((b) => ({ ...b, a: map[b.a], b: map[b.b] }));
      break;
    }
    case 'setElement': m.atoms[op.atom].z = op.z; m.atoms[op.atom].symbol = SYMBOLS[op.z]; break;
    case 'addBond': if (bondIdx(op.a, op.b) < 0) m.bonds.push({ a: op.a, b: op.b, order: op.order || 1 }); else m.bonds[bondIdx(op.a, op.b)].order = op.order || 1; break;
    case 'deleteBond': { const i = bondIdx(op.a, op.b); if (i >= 0) m.bonds.splice(i, 1); break; }
    case 'setBondOrder': { const i = bondIdx(op.a, op.b); if (i >= 0) m.bonds[i].order = op.order; break; }
    case 'moveAtoms': for (const i of op.atoms) m.atoms[i].pos = m.atoms[i].pos.map((v, c) => v + op.delta[c]); break;
    case 'growAtom': {
      const a = m.atoms[op.from]; const dir = [Math.random() - 0.5, Math.random() - 0.5, Math.random() - 0.5];
      const l = Math.hypot(...dir) || 1; const r = (COV[a.z] || 0.8) + (COV[op.z] || 0.8);
      m.atoms.push(atom(op.z, a.pos.map((v, c) => v + (dir[c] / l) * r)));
      m.bonds.push({ a: op.from, b: m.atoms.length - 1, order: 1 }); break;
    }
    case 'setDistance': {
      const [i, j] = op.atoms; const a = m.atoms[i].pos, b = m.atoms[j].pos; const d0 = dist(a, b) || 1;
      m.atoms[j].pos = a.map((v, c) => v + ((b[c] - v) / d0) * op.value); break;
    }
    case 'placeFragment': {
      const f = fragmentMolecule(op.fragmentId);
      const at = op.pos || (op.at != null ? m.atoms[op.at].pos : [0, 0, 0]);
      const off = m.atoms.length;
      for (const a of f.atoms) m.atoms.push({ ...a, pos: a.pos.map((v, c) => v + at[c]) });
      for (const b of f.bonds) m.bonds.push({ a: b.a + off, b: b.b + off, order: b.order });
      break;
    }
    case 'placeGroup': { // GaussView-style groups (real engine: MolBuild GroupLibrary); mock: drop the template in
      const g = MOCK_GROUPS.find((x) => x.id === op.groupId); if (!g) throw err('not_found', `unknown group ${op.groupId}`);
      const at = op.pos || (op.at != null ? m.atoms[op.at].pos : [0, 0, 0]); const off = m.atoms.length; const f = groupMolecule(g);
      for (const a of f.atoms) m.atoms.push({ ...a, pos: a.pos.map((v, c) => v + at[c]) });
      for (const b of f.bonds) m.bonds.push({ a: b.a + off, b: b.b + off, order: b.order });
      break;
    }
    case 'setCharge': m.charge = op.charge; m.multiplicity = op.multiplicity; break;
    case 'replaceMolecule': return commit(d, op.molecule);
    case 'addHydrogens': case 'cleanUp': case 'symmetrize': case 'setAngle': case 'setDihedral': case 'rotateAtoms': break;
    default: throw err('bad_request', `unknown edit ${op.type}`);
  }
  return commit(d, m);
}

// ---------- Z-matrix (Methods+ZMatrix.swift subset: input order, references = the previous rows) ----------
const zsub = (a, b) => [a[0] - b[0], a[1] - b[1], a[2] - b[2]];
const zdot = (a, b) => a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
const zcross = (a, b) => [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]];
const znorm = (a) => { const l = Math.hypot(...a) || 1; return a.map((v) => v / l); };
const zangle = (a, b, c) => { const u = zsub(a, b), v = zsub(c, b); return (Math.acos(Math.max(-1, Math.min(1, zdot(u, v) / (Math.hypot(...u) * Math.hypot(...v) || 1)))) * 180) / Math.PI; };
const zdihedral = (a, b, c, d) => {
  const b1 = zsub(b, a), b2 = zsub(c, b), b3 = zsub(d, c); const n1 = zcross(b1, b2), n2 = zcross(b2, b3);
  return (Math.atan2(zdot(zcross(n1, znorm(b2)), n2), zdot(n1, n2)) * 180) / Math.PI;
};
/** Position from references a (bond), b (angle), c (dihedral) — NeRF. */
function zplace(pa, pb, pc, r, ang, dih) {
  if (!pa) return [0, 0, 0];
  if (!pb) return [pa[0], pa[1], pa[2] + r];
  const A = (ang * Math.PI) / 180, D = (dih * Math.PI) / 180;
  const bc = znorm(zsub(pa, pb));
  const ref = pc ? zsub(pb, pc) : (Math.abs(bc[0]) < 0.9 ? [1, 0, 0] : [0, 1, 0]);
  const n = znorm(zcross(ref, bc)); const m = zcross(n, bc);
  const d2 = [-r * Math.cos(A), r * Math.sin(A) * Math.cos(D), r * Math.sin(A) * Math.sin(D)];
  return [0, 1, 2].map((k) => pa[k] + d2[0] * bc[k] + d2[1] * m[k] + d2[2] * n[k]);
}
function zmatrixOf(m) {
  const P = m.atoms.map((a) => a.pos);
  const rows = m.atoms.map((a, r) => {
    const ref = [r - 1, r - 2, r - 3].map((x) => (x >= 0 ? x : null));
    return { row: r, atom: r, z: a.z, symbol: a.symbol, label: `${a.symbol}${r + 1}`,
      bondRow: ref[0], bondAtom: ref[0], bond: ref[0] != null ? dist(P[r], P[ref[0]]) : null,
      bonded: ref[0] != null && m.bonds.some((b) => (b.a === r && b.b === ref[0]) || (b.b === r && b.a === ref[0])),
      angleRow: ref[1], angleAtom: ref[1], angle: ref[1] != null ? zangle(P[r], P[ref[0]], P[ref[1]]) : null,
      dihedralRow: ref[2], dihedralAtom: ref[2], dihedral: ref[2] != null ? zdihedral(P[r], P[ref[0]], P[ref[1]], P[ref[2]]) : null };
  });
  const txt = (r) => [r.symbol, ...(r.bond != null ? [r.bondRow + 1, r.bond.toFixed(6)] : []), ...(r.angle != null ? [r.angleRow + 1, r.angle.toFixed(4)] : []), ...(r.dihedral != null ? [r.dihedralRow + 1, r.dihedral.toFixed(4)] : [])].join('  ');
  const gaussian = rows.map(txt).join('\n') + '\n';
  return { atomCount: m.atoms.length, ordering: 'input', order: rows.map((r) => r.atom), refs: rows.map((r) => [r.bondRow, r.angleRow, r.dihedralRow]), refsUsed: false, rows,
    gaussian, gaussianVariables: gaussian, orca: `* int ${m.charge} ${m.multiplicity}\n` + rows.map((r) => `${r.symbol} ${r.bondRow != null ? r.bondRow + 1 : 0} ${r.angleRow != null ? r.angleRow + 1 : 0} ${r.dihedralRow != null ? r.dihedralRow + 1 : 0} ${(r.bond || 0).toFixed(6)} ${(r.angle || 0).toFixed(4)} ${(r.dihedral || 0).toFixed(4)}`).join('\n') + '\n*\n',
    charge: m.charge, multiplicity: m.multiplicity };
}
function zmatrixParse(text) {
  const lines = String(text).replace(/\r/g, '').split('\n').map((l) => l.trim());
  while (lines.length && !lines[0]) lines.shift();
  let charge = 0, mult = 1;
  if (/^-?\d+\s+\d+$/.test(lines[0] || '')) { [charge, mult] = lines.shift().split(/\s+/).map(Number); }
  const atoms = [];
  for (const l of lines) {
    if (!l) break;
    const t = l.split(/[\s,]+/);
    const z = zOf(t[0].replace(/\d+$/, ''));
    const P = atoms.map((a) => a.pos);
    const ref = (k) => { const v = Number(t[k]); if (!Number.isInteger(v) || v < 1 || v > atoms.length) throw err('parse_error', `bad reference in row ${atoms.length + 1}: ${l}`); return P[v - 1]; };
    const num = (k) => { const v = Number(t[k]); if (!Number.isFinite(v)) throw err('parse_error', `bad number in row ${atoms.length + 1} (mock engine: no variables)`); return v; };
    const n = atoms.length;
    const pos = n === 0 ? [0, 0, 0] : zplace(ref(1), n > 1 ? ref(3) : null, n > 2 ? ref(5) : null, num(2), n > 1 ? num(4) : 0, n > 2 ? num(6) : 0);
    atoms.push(atom(z, pos));
  }
  if (!atoms.length) throw err('parse_error', 'the Z-matrix is empty');
  return { title: 'Z-Matrix', charge, multiplicity: mult, atoms, bonds: perceiveBonds(atoms) };
}
const ZMATRIX_METHODS = {
  'zmatrix.get': (p) => zmatrixOf(getDoc(p).molecule),
  'zmatrix.edit': (p) => {
    const d = getDoc(p); const m = clone(d.molecule);
    const zm = zmatrixOf(m);
    for (const c of p.changes || [{ row: p.row, field: p.field, value: p.value }]) zm.rows[c.row][c.field] = c.value;
    const P = [];
    zm.rows.forEach((r, i) => { P[i] = zplace(P[r.bondRow], P[r.angleRow], P[r.dihedralRow], r.bond || 0, r.angle || 0, r.dihedral || 0); });
    m.atoms.forEach((a, i) => { a.pos = P[i]; });
    const res = commit(d, m);
    return { ...res, zmatrix: zmatrixOf(m) };
  },
  'zmatrix.parse': (p) => { const m = zmatrixParse(p.text); return { molecule: m, rowCount: m.atoms.length, dummyCount: 0, variables: {}, source: 'gaussian', atomCount: m.atoms.length, chargeGiven: true }; },
  'zmatrix.apply': (p) => {
    const m = zmatrixParse(p.text);
    if (!p.docId || p.newDocument) { if (p.title) m.title = p.title; const d = newDoc(m); return { summary: summary(d), molecule: m, mode: 'new', docId: d.id, source: 'gaussian' }; }
    const d = getDoc(p); m.title = d.molecule.title;
    return { ...commit(d, m), mode: 'replace', docId: d.id, source: 'gaussian' };
  },
  'zmatrix.addAtom': (p) => {
    const d = getDoc(p); const m = clone(d.molecule); const n = m.atoms.length;
    const a = p.bondAtom ?? (n ? n - 1 : null), b = p.angleAtom ?? (n > 1 ? (a === 0 ? 1 : a - 1) : null);
    const c = p.dihedralAtom ?? (n > 2 ? [...Array(n).keys()].find((x) => x !== a && x !== b) : null);
    const bond = p.bond ?? (a != null ? (COV[p.z] || 0.8) + (COV[m.atoms[a].z] || 0.8) : null), angle = p.angle ?? (b != null ? 109.4712 : null), dihedral = p.dihedral ?? (c != null ? 180 : null);
    const pos = n ? zplace(m.atoms[a].pos, b != null ? m.atoms[b].pos : null, c != null ? m.atoms[c].pos : null, bond, angle || 0, dihedral || 0) : [0, 0, 0];
    const defaults = { bondAtom: a, angleAtom: b, dihedralAtom: c, bond, angle, dihedral, hybridization: 'none', position: pos };
    if (p.dryRun) return { defaults, position: pos };
    m.atoms.push(atom(p.z, pos)); if (a != null) m.bonds.push({ a, b: n, order: Number(p.bondOrder) || 1 });
    return { ...commit(d, m), defaults, position: pos, atom: n };
  },
};

// ---------- synthetic analysis ----------
function b64f(arr) { return Buffer.from(new Float32Array(arr).buffer).toString('base64'); }
function b64u(arr) { return Buffer.from(new Uint32Array(arr).buffer).toString('base64'); }
function sphereMesh(center, radius, sign) {
  const pos = [], nrm = [], idx = []; const S = 24, R = 16;
  for (let i = 0; i <= R; i++) for (let j = 0; j <= S; j++) {
    const th = (i / R) * Math.PI, ph = (j / S) * 2 * Math.PI;
    const n = [Math.sin(th) * Math.cos(ph), Math.cos(th), Math.sin(th) * Math.sin(ph)];
    pos.push(center[0] + radius * n[0], center[1] + radius * n[1] * 1.3, center[2] + radius * n[2]); nrm.push(...n);
  }
  for (let i = 0; i < R; i++) for (let j = 0; j < S; j++) {
    const a = i * (S + 1) + j, b = a + S + 1;
    idx.push(a, b, a + 1, b, b + 1, a + 1);
  }
  return { sign, isovalue: 0.02 * sign, vertexCount: pos.length / 3, triangleCount: idx.length / 3, positionsB64: b64f(pos), normalsB64: b64f(nrm), indicesB64: b64u(idx), colorsB64: null };
}
function modesFor(d) {
  const n = d.molecule.atoms.length;
  const freqs = d.freqs.length ? d.freqs : [];
  return freqs.map((f, k) => ({
    index: k, frequency: f, irIntensity: 20 + 60 * Math.abs(Math.sin(k * 1.7)), ramanActivity: 10 + 30 * Math.abs(Math.cos(k)), symmetry: null,
    label: `${f.toFixed(1)} cm⁻¹`,
    displacements: d.molecule.atoms.map((a, i) => { const s = (i + k) % 2 ? 1 : -1; const w = a.z === 1 ? 0.6 : 0.1; return [s * w * Math.cos(k), s * w * Math.sin(k + i), w * 0.3 * s]; }),
  })).slice(0, Math.max(0, 3 * n - 6) || freqs.length);
}
function broaden(sticks, xmin, xmax, fwhm) {
  const xs = [], ys = []; const N = 800; const g = fwhm / 2;
  for (let i = 0; i < N; i++) {
    const x = xmin + ((xmax - xmin) * i) / (N - 1); let y = 0;
    for (const s of sticks) y += s.height * (g * g) / ((x - s.x) ** 2 + g * g);
    xs.push(x); ys.push(y);
  }
  return { xB64: b64f(xs), yB64: b64f(ys) };
}

const COMMANDS = ['add', 'bond', 'center', 'cd', 'clean', 'color', 'delete', 'echo', 'fit', 'help', 'hydrogens', 'label', 'ls', 'measure', 'open', 'orbital', 'save', 'select', 'style', 'view'];

const handlers = {
  'engine.info': () => ({ version: '0.0-mock', protocol: 1, platform: 'mock', formats: { read: [{ id: 'xyz', name: 'XYZ', extensions: ['xyz'] }, { id: 'orca', name: 'ORCA output', extensions: ['out'] }], write: [{ id: 'xyz', name: 'XYZ', extensions: ['xyz'] }] }, programs: { xtb: null, orca: null, gaussian: null, qchem: null, formchk: null } }),
  'doc.new': () => summary(newDoc({ title: '', charge: 0, multiplicity: 1, atoms: [], bonds: [] })),
  'doc.open': (p) => {
    let text;
    try { text = fs.readFileSync(p.path, 'utf8'); } catch (e) { throw err('io_error', e.message); }
    const ext = path.extname(p.path).toLowerCase();
    let frames = [], energies = [], freqs = [], program = null;
    if (ext === '.xyz') frames = parseXYZFrames(text);
    else if (ext === '.pdb' || ext === '.ent') frames = parsePDB(text);
    else ({ frames, energies, freqs, program } = parseOutput(text));
    if (!frames.length) throw err('parse_error', `mock engine could not read ${path.basename(p.path)}`);
    const mols = frames.map((f) => ({ title: path.basename(p.path, ext), charge: 0, multiplicity: 1, atoms: f.atoms, bonds: perceiveBonds(f.atoms) }));
    const d = newDoc(mols[mols.length - 1], { path: p.path, format: ext.slice(1), program, energies, freqs });
    d.frames = mols;
    const base = p.path.slice(0, -ext.length);
    d.companions = ['.hess', '.molden.input', '_trj.xyz'].filter((s) => fs.existsSync(base + s)).map((s) => ({ fileName: path.basename(base + s), role: s.slice(1), used: true, note: '' }));
    // Gaussian .chk without an up-to-date .fchk: the real engine runs formchk in the background (Formchk.swift) and
    // sends doc.wavefunction; the mock has no formchk and reports that.
    if (fs.existsSync(base + '.chk') && !fs.existsSync(base + '.fchk')) {
      d.companions.push({ fileName: path.basename(base + '.chk'), role: 'binary', used: false, note: 'binary checkpoint' });
      d.formchkPending = true;
      setTimeout(() => {
        if (!docs.has(d.id)) return;
        d.formchkPending = false;
        d.companions[d.companions.length - 1].note += ' (automatic formchk failed: the mock engine has no formchk)';
        send({ event: 'doc.wavefunction', params: { docId: d.id, jobId: `fc${d.id}`, chk: base + '.chk', ok: false, fchk: null, error: 'the mock engine has no formchk', errorCode: 'not_installed', summary: summary(d) } });
      }, 700);
    }
    return summary(d);
  },
  'doc.openText': (p) => {
    const frames = parseXYZFrames(p.text);
    if (!frames.length) throw err('parse_error', 'mock engine only reads XYZ text');
    return summary(newDoc({ title: p.fileName || '', charge: 0, multiplicity: 1, atoms: frames[0].atoms, bonds: perceiveBonds(frames[0].atoms) }));
  },
  'doc.close': (p) => { docs.delete(p.docId); return {}; },
  'doc.save': (p) => {
    const d = getDoc(p); const m = d.molecule;
    fs.writeFileSync(p.path, `${m.atoms.length}\n${m.title}\n` + m.atoms.map((a) => `${a.symbol} ${a.pos.map((v) => v.toFixed(6)).join(' ')}`).join('\n') + '\n');
    d.path = p.path; return { path: p.path };
  },
  'doc.export': (p) => { const m = getDoc(p).molecule; return { text: `${m.atoms.length}\n${m.title}\n` + m.atoms.map((a) => `${a.symbol} ${a.pos.map((v) => v.toFixed(6)).join(' ')}`).join('\n') + '\n' }; },
  // Methods+Export.swift subset: XYZ only (current / all frames, selection).
  'doc.exportFormats': () => ({ formats: [{ id: 'xyz', name: 'XYZ', extensions: ['xyz'], multiFrame: true, available: true, note: 'mock engine: XYZ only' }] }),
  'doc.exportAs': (p) => {
    const d = getDoc(p);
    if (p.format !== 'xyz') throw err('bad_request', 'mock engine exports XYZ only');
    const mols = p.frames === 'all' ? d.frames : Array.isArray(p.frames) ? p.frames.map((k) => d.frames[k]).filter(Boolean) : [d.molecule];
    const text = mols.map((m) => { const atoms = p.atoms?.length ? p.atoms.map((i) => m.atoms[i]) : m.atoms; return `${atoms.length}\n${m.title}\n` + atoms.map((a) => `${a.symbol} ${a.pos.map((v) => v.toFixed(6)).join(' ')}`).join('\n') + '\n'; }).join('');
    return { text, format: 'xyz', extension: 'xyz', frameCount: mols.length, atomCount: p.atoms?.length || mols[0].atoms.length };
  },
  'doc.molecule': (p) => { const d = getDoc(p); return p.frame == null ? d.molecule : d.frames[Math.max(0, Math.min(d.frames.length - 1, p.frame))]; },
  'doc.summary': (p) => summary(getDoc(p)),
  'doc.undo': (p) => { const d = getDoc(p); if (d.undo.length) { d.redo.push(d.molecule); d.molecule = d.undo.pop(); d.frames = [d.molecule]; } return { summary: summary(d), molecule: d.molecule }; },
  'doc.redo': (p) => { const d = getDoc(p); if (d.redo.length) { d.undo.push(d.molecule); d.molecule = d.redo.pop(); d.frames = [d.molecule]; } return { summary: summary(d), molecule: d.molecule }; },
  'doc.result': (p) => {
    const d = getDoc(p);
    return { energies: d.energies, normalTermination: true, dipole: [0, 0.78, 0], routeSection: '! B3LYP def2-SVP Opt Freq',
      info: { levelOfTheory: d.program ? 'B3LYP/def2-SVP (mock)' : null, rows: [{ label: 'Program', value: d.program || '-' }, { label: 'Final energy', value: d.energies.length ? `${d.energies[d.energies.length - 1].toFixed(8)} Eh` : '-' }, { label: 'Dipole', value: '1.92 D' }] },
      thermo: null, charges: { Mulliken: d.molecule.atoms.map((a) => (a.z === 1 ? 0.32 : -0.64)) } };
  },
  'doc.frames': (p) => { const d = getDoc(p); const e = d.energies.slice(0, d.frames.length); const e0 = Math.min(...e); return { count: d.frames.length, energies: e, profile: e.length > 1 ? { coordinates: e.map((_, i) => i), relativeKcal: e.map((x) => (x - e0) * 627.5095) } : null }; },
  'edit.apply': (p) => applyEdit(getDoc(p), p.op),
  'build.groups': (p) => ({ groups: MOCK_GROUPS.filter((g) => p.element == null || g.element === p.element).map((g) => ({ ...g, anchor: 0, leaving: 1, molecule: groupMolecule(g) })) }),
  'build.fragments': () => ({ fragments: FRAGMENTS.map((f) => ({ ...f, molecule: fragmentMolecule(f.id) })) }),
  'analysis.measure': (p) => {
    const m = getDoc(p).molecule; const P = p.atoms.map((i) => m.atoms[i].pos);
    const sub = (a, b) => a.map((v, i) => v - b[i]); const dot = (a, b) => a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
    const cross = (a, b) => [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]];
    if (P.length === 2) return { kind: 'distance', value: dist(P[0], P[1]) };
    if (P.length === 3) { const u = sub(P[0], P[1]), v = sub(P[2], P[1]); return { kind: 'angle', value: (Math.acos(dot(u, v) / Math.hypot(...u) / Math.hypot(...v)) * 180) / Math.PI }; }
    const b1 = sub(P[1], P[0]), b2 = sub(P[2], P[1]), b3 = sub(P[3], P[2]); const n1 = cross(b1, b2), n2 = cross(b2, b3);
    const m1 = cross(n1, b2.map((v) => v / Math.hypot(...b2)));
    return { kind: 'dihedral', value: (Math.atan2(dot(m1, n2), dot(n1, n2)) * 180) / Math.PI };
  },
  'analysis.secondaryStructure': (p) => {
    const d = getDoc(p);
    return mockSecondaryStructure(p.frame == null ? d.molecule : d.frames[Math.max(0, Math.min(d.frames.length - 1, p.frame))]);
  },
  'analysis.symmetry': () => ({ pointGroup: 'C2v', elements: ['E', 'C2', 'σv', 'σv′'] }),
  'analysis.orbitals': (p) => {
    const d = getDoc(p); if (!d.program) return { columns: [], homoLumoGapEV: null };
    const levels = []; const nocc = 5;
    for (let i = 0; i < 12; i++) { const e = i < nocc ? -1.2 + i * 0.18 : 0.05 + (i - nocc) * 0.12; levels.push({ energy: e, energyEV: e * 27.2114, orbitalIndices: [i], occupation: i < nocc ? 2 : 0, isHOMO: i === nocc - 1, isLUMO: i === nocc }); }
    return { columns: [{ spin: 'restricted', levels }], homoLumoGapEV: (levels[nocc].energy - levels[nocc - 1].energy) * 27.2114 };
  },
  'analysis.orbitalSurface': async (p) => {
    const m = getDoc(p).molecule; await new Promise((r) => setTimeout(r, 300));
    const c = m.atoms[p.orbital % Math.max(1, m.atoms.length)]?.pos || [0, 0, 0];
    return { meshes: [sphereMesh([c[0], c[1] + 0.9, c[2]], 0.8, 1), sphereMesh([c[0], c[1] - 0.9, c[2]], 0.8, -1)], energy: -0.3, isOccupied: p.orbital < 5, isHOMO: p.orbital === 4, isLUMO: p.orbital === 5 };
  },
  'analysis.densitySurface': (p) => { const m = getDoc(p).molecule; return { meshes: [sphereMesh(m.atoms[0]?.pos || [0, 0, 0], 2, 1)] }; },
  'analysis.volumeSurface': () => { throw err('not_found', 'no volumes in mock'); },
  'analysis.modes': (p) => ({ modes: modesFor(getDoc(p)) }),
  'analysis.spectrum': (p) => {
    const d = getDoc(p); const modes = modesFor(d);
    if (p.kind === 'uvvis') { const sticks = [{ x: 180, height: 0.12, label: 'S1', sourceIndex: 0 }, { x: 155, height: 0.4, label: 'S2', sourceIndex: 1 }]; return { xLabel: 'Wavelength (nm)', yLabel: 'Oscillator strength', xAxisReversed: false, sticks, ...broaden(sticks, 100, 400, p.fwhm || 20) }; }
    const sticks = modes.map((m) => ({ x: m.frequency * (p.scale || 1), height: p.kind === 'raman' ? m.ramanActivity : m.irIntensity, label: null, sourceIndex: m.index }));
    return { xLabel: 'Wavenumber (cm⁻¹)', yLabel: p.kind === 'raman' ? 'Raman activity' : 'IR intensity (km/mol)', xAxisReversed: true, sticks, ...broaden(sticks, 400, 4000, p.fwhm || 20) };
  },
  'analysis.thermo': () => ({ rows: [{ label: 'Zero-point energy', hartree: 0.0213, kcal: 13.37 }, { label: 'Gibbs free energy', hartree: -76.3, kcal: null }] }),
  'calc.programs': () => ({ xtb: null, orca: null, gaussian: null, qchem: null, formchk: null }),
  'calc.preview': (p) => { const m = getDoc(p).molecule; const s = p.spec; return { input: `! ${s.method} ${s.basis} ${s.task}\n\n* xyz ${m.charge} ${m.multiplicity}\n` + m.atoms.map((a) => `  ${a.symbol} ${a.pos.map((v) => v.toFixed(6)).join(' ')}`).join('\n') + '\n*\n', errors: [], files: ['job.inp'], commandLine: `${s.program} job.inp` }; },
  'calc.run': (p) => {
    if (p.inputText != null && (typeof p.inputText !== 'string' || !p.inputText.trim())) throw err('bad_request', 'inputText is empty');
    if (p.spec?.program !== 'gaussian') throw err('not_installed', 'The mock engine cannot run calculations.');
    // Gaussian: a fake job that ends like a real one whose automatic formchk failed (job.finished fchk / formchkError).
    const src = getDoc(p); const jobId = `job${Date.now()}`; const dir = p.directory || path.join(require('os').tmpdir(), 'vibeview-mock');
    setTimeout(() => {
      send({ event: 'job.started', params: { jobId, directory: dir, commandLine: 'g16 job.gjf' } });
      for (const line of (p.inputText || '').split('\n').slice(0, 6)) send({ event: 'job.log', params: { jobId, stream: 'file', file: 'job.log', line } });
      send({ event: 'job.log', params: { jobId, stream: 'stdout', file: null, line: ' Normal termination of Gaussian (mock).' } });
      const nd = newDoc(clone(src.molecule), { program: 'gaussian', energies: [-76.0], path: path.join(dir, 'job.log'), format: 'gaussianLog' });
      send({ event: 'job.finished', params: { jobId, exitCode: 0, ok: true, error: null, cancelled: false, docId: nd.id, summary: summary(nd), directory: dir,
        fchk: null, formchkError: 'formchk not found: run `formchk job.chk job.fchk` to view orbitals (mock engine)' } });
    }, 400);
    return { jobId, directory: dir, commandLine: 'g16 job.gjf', inputFile: 'job.gjf', outputFile: 'job.log' };
  },
  ...ZMATRIX_METHODS,
  'xtb.run': (p) => {
    const jobId = `job${Date.now()}`; let n = 0;
    const t = setInterval(() => {
      send({ event: 'job.log', params: { jobId, stream: 'stdout', file: null, line: `cycle ${++n}   E = ${(-5.07 - n * 0.001).toFixed(6)}  gnorm ${(0.1 / n).toFixed(5)}` } });
      if (n >= 6) { clearInterval(t); send({ event: 'job.finished', params: { jobId, exitCode: 0, ok: true, error: null, docId: p.docId, summary: summary(getDoc(p)) } }); }
    }, 300);
    return { jobId, directory: path.join(require('os').tmpdir(), 'vibeview-mock') };
  },
  'calc.cancel': () => ({}),
  // Additive methods from the protocol change log.
  'engine.ping': () => ({ pong: true }),
  'doc.list': () => ({ docs: [...docs.values()].map(summary) }),
  'doc.setSelection': (p) => { const d = getDoc(p); d.selection = (p.atoms || []).filter((i) => i >= 0 && i < d.molecule.atoms.length); return { selection: d.selection }; },
  'calc.setProgramPath': () => ({ xtb: null, orca: null, gaussian: null, qchem: null, formchk: null }),
  'jobs.list': () => ({ jobs: [] }),
  'lookup.suggest': () => ({ candidates: [], error: 'The mock engine is offline.' }),
  'lookup.structure': () => { throw err('offline', 'The mock engine is offline.'); },
  'command.execute': (p) => {
    const line = p.line.trim(); const [cmd, ...args] = line.split(/\s+/);
    if (cmd === 'style') return { results: [{ command: line, success: true, messages: [{ level: 'info', text: `style ${args[0]}` }] }], molecule: null, view: { style: args[0] || 'ball', labels: null, fit: false, view: null, orbital: null, background: null } };
    if (cmd === 'fit') return { results: [{ command: line, success: true, messages: [] }], molecule: null, view: { style: null, labels: null, fit: true, view: null, orbital: null, background: null } };
    if (cmd === 'help') return { results: [{ command: line, success: true, messages: [{ level: 'info', text: 'Commands: ' + COMMANDS.join(', ') }] }], molecule: null, view: null };
    return { results: [{ command: line, success: COMMANDS.includes(cmd), messages: [{ level: COMMANDS.includes(cmd) ? 'info' : 'error', text: COMMANDS.includes(cmd) ? `(mock) ${cmd} accepted` : `unknown command '${cmd}'` }] }], molecule: null, view: null };
  },
  'command.complete': (p) => {
    const before = p.line.slice(0, p.cursor); const m = before.match(/(\S*)$/); const word = m ? m[1] : '';
    const from = before.length - word.length;
    const pool = from === 0 ? COMMANDS : ['ball', 'stick', 'spacefill', 'wire', 'element', 'index', 'all', 'none', 'x', 'y', 'z'];
    return { completions: pool.filter((c) => c.startsWith(word)), replaceFrom: from };
  },
  'session.save': () => ({}),
  'session.load': () => { throw err('not_found', 'sessions are not supported by the mock engine'); },
  cancel: () => ({}),
};

const rl = readline.createInterface({ input: process.stdin });
rl.on('line', async (line) => {
  if (!line.trim()) return;
  let msg;
  try { msg = JSON.parse(line); } catch { log(`bad json ${line}`); return; }
  const h = handlers[msg.method];
  if (!h) { send({ id: msg.id, error: { code: 'bad_request', message: `mock engine: unknown method ${msg.method}` } }); return; }
  try { send({ id: msg.id, result: await h(msg.params || {}) }); } catch (e) {
    send({ id: msg.id, error: { code: e.code || 'internal', message: e.message } });
  }
});
rl.on('close', () => process.exit(0));
log('mock engine ready');
