// three.js molecule viewport: styles, picking, selection overlays, labels, measurements,
// isosurfaces, vibrations and image export.
import * as THREE from 'three';
import { EffectComposer } from 'three/addons/postprocessing/EffectComposer.js';
import { RenderPass } from 'three/addons/postprocessing/RenderPass.js';
import { GTAOPass } from 'three/addons/postprocessing/GTAOPass.js';
import { OutputPass } from 'three/addons/postprocessing/OutputPass.js';
import { Pass } from 'three/addons/postprocessing/Pass.js';
import { element, cssColor } from './elements.js';
import { CartoonLayer } from './cartoon.js';
import { MeasureOverlay } from './measure-overlay.js';

// macOS RenderTheme.background (Sources/MolRender/RenderTypes.swift), sRGB:
// light (0.93, 0.94, 0.96), dark (0.12, 0.13, 0.15), black, white.
const srgbHex = (r, g, b) => (Math.round(r * 255) << 16) | (Math.round(g * 255) << 8) | Math.round(b * 255);
export const THEMES = {
  light: { bg: srgbHex(0.93, 0.94, 0.96), fg: '#1a1a1f' },
  dark: { bg: srgbHex(0.12, 0.13, 0.15), fg: '#f2f2f2' },
  black: { bg: 0x000000, fg: '#f2f2f2' },
  white: { bg: 0xffffff, fg: '#1a1a1f' },
};

/** Tessellation by atom count (macOS SceneQuality idea): smooth for small molecules, cheap for proteins. */
function lodSegments(n) {
  if (n <= 400) return { sw: 64, sh: 40, cyl: 40 };
  if (n <= 3000) return { sw: 40, sh: 26, cyl: 28 };
  if (n <= 20000) return { sw: 24, sh: 16, cyl: 16 };
  return { sw: 14, sh: 10, cyl: 10 };
}

/** macOS LightingRig.studioEnvironment: procedural equirectangular "photo studio" (overhead softbox, warm key
 *  softbox upper left, cool strip right, neutral floor), 256×128, 8-bit like the NSImage it builds. */
function studioEnvironment(dark) {
  const w = 256, hh = 128;
  const data = new Uint8Array(w * hh * 4);
  const box = (u, v, cu, cv, su, sv) => {
    const du = Math.min(Math.abs(u - cu), 1 - Math.abs(u - cu)) / su, dv = (v - cv) / sv;
    return Math.exp(-Math.pow(du * du + dv * dv, 2));
  };
  for (let y = 0; y < hh; y++) {
    const v = y / (hh - 1);
    for (let x = 0; x < w; x++) {
      const u = x / w;
      const base = dark ? (v < 0.5 ? 0.10 + 0.12 * (0.5 - v) : 0.03) : (v < 0.5 ? 0.62 + 0.3 * (0.5 - v) : 0.30 - 0.12 * (v - 0.5));
      const top = box(u, v, 0.5, 0.0, 2, 0.16) * (dark ? 1.6 : 1.4);
      const key = box(u, v, 0.37, 0.3, 0.07, 0.1) * 2.4;
      const strip = box(u, v, 0.72, 0.42, 0.025, 0.2) * 1.4;
      const r = base + top + key * 1.0 + strip * 0.8, g = base + top + key * 0.96 + strip * 0.9, b = base + top + key * 0.9 + strip * 1.05;
      // NSImage rows run top to bottom; DataTexture rows bottom to top (flipY is false for data textures).
      const o = ((hh - 1 - y) * w + x) * 4;
      data[o] = Math.min(255, r * 255); data[o + 1] = Math.min(255, g * 255); data[o + 2] = Math.min(255, b * 255); data[o + 3] = 255;
    }
  }
  const tex = new THREE.DataTexture(data, w, hh, THREE.RGBAFormat);
  tex.colorSpace = THREE.SRGBColorSpace;
  tex.mapping = THREE.EquirectangularReflectionMapping;
  tex.magFilter = THREE.LinearFilter; tex.minFilter = THREE.LinearFilter;
  tex.needsUpdate = true;
  return tex;
}

export const DEFAULT_OPTIONS = {
  style: 'ballAndStick', // ballAndStick | tube | wireframe | spaceFilling | cartoon
  cartoonColoring: 'auto', // auto | chain | ss | rainbow | uniform (cartoon.js; auto = RCSB look)
  cartoonAssembly: 'assembly', // assembly (biological assembly 1 of a PDB file) | asymmetric (every chain in the file)
  atomScale: 0.25, bondRadius: 0.12, tubeRadius: 0.18, wireWidth: 1.5,
  showBondOrders: true, showHydrogens: true, splitBondColors: true,
  aromaticStyle: 'kekule', // kekule | dashed (macOS RenderOptions.aromaticStyle)
  colorScheme: 'element', // element | charge | uniform
  uniformColor: '#9aa0a8',
  labelMode: 'none', // none | element | index | elementIndex | charge | custom
  theme: 'auto', background: null,
  material: 'glossy', // matte | glossy | satin | metallic | flat
  ambientOcclusion: true, projection: 'perspective', showAxes: true,
  dihedralPlanes: false, // measure-overlay.js: show the two planes of dihedral monitors (per-monitor override m.planes)
};

// macOS MaterialLibrary.pbrParameters: roughness, metalness, clear coat, clear-coat roughness.
const MATERIALS = {
  glossy: { roughness: 0.34, metalness: 0.0, clearcoat: 0.55, clearcoatRoughness: 0.07 },
  satin: { roughness: 0.5, metalness: 0.0, clearcoat: 0.2, clearcoatRoughness: 0.28 },
  matte: { roughness: 0.82, metalness: 0.0, clearcoat: 0, clearcoatRoughness: 0 },
  ceramic: { roughness: 0.42, metalness: 0.0, clearcoat: 1.0, clearcoatRoughness: 0.03 },
  metallic: { roughness: 0.3, metalness: 0.5, clearcoat: 0.3, clearcoatRoughness: 0.1 },
};
// SceneKit light intensity (lumen-like, 1000 = unit) → three.js physically based intensity (π = unit radiance).
const SCN = (x) => (x / 1000) * Math.PI;

const tmpM = new THREE.Matrix4();
const tmpQ = new THREE.Quaternion();
const tmpS = new THREE.Vector3();
const tmpP = new THREE.Vector3();
const UP = new THREE.Vector3(0, 1, 0);
const tmpColor = new THREE.Color();

function v3(a) { return new THREE.Vector3(a[0], a[1], a[2]); }

/** LightingRig.apply's test: mean sRGB component below 0.5 (THREE.Color stores linear components). */
function isDarkBackground(c) {
  const s = c.getRGB({ r: 0, g: 0, b: 0 }, THREE.SRGBColorSpace);
  return (s.r + s.g + s.b) / 3 < 0.5;
}

/** Ray (origin o, unit dir d) to sphere hit distance, or -1. */
function raySphere(o, d, c, r) {
  const ox = o.x - c.x, oy = o.y - c.y, oz = o.z - c.z;
  const b = ox * d.x + oy * d.y + oz * d.z;
  const cc = ox * ox + oy * oy + oz * oz - r * r;
  const disc = b * b - cc;
  if (disc < 0) return -1;
  const t = -b - Math.sqrt(disc);
  return t > 0 ? t : (-b + Math.sqrt(disc) > 0 ? 0 : -1);
}
/** Closest distance between a ray and a segment, plus the ray parameter at closest approach. */
function raySegment(o, d, a, b) {
  const u = new THREE.Vector3().subVectors(b, a);
  const w = new THREE.Vector3().subVectors(o, a);
  const B = d.dot(u), C = u.dot(u) || 1e-12, D = d.dot(w), E = u.dot(w);
  const den = C - B * B;
  let t = den > 1e-12 ? (E - B * D) / den : 0;
  t = Math.max(0, Math.min(1, t));
  let s = Math.max(0, t * B - D);
  t = Math.max(0, Math.min(1, (s * B + E) / C));
  s = Math.max(0, t * B - D);
  const p = o.clone().addScaledVector(d, s);
  const q = a.clone().addScaledVector(u, t);
  return { dist: p.distanceTo(q), s };
}

/** Eigen-decomposition of a symmetric 3×3 matrix (cyclic Jacobi). vectors[i][k] = component i of eigenvector k. */
function jacobiEigen(M) {
  const a = M.map((r) => r.slice());
  const v = [[1, 0, 0], [0, 1, 0], [0, 0, 1]];
  for (let sweep = 0; sweep < 50; sweep++) {
    let off = 0;
    for (let i = 0; i < 3; i++) for (let j = i + 1; j < 3; j++) off += a[i][j] * a[i][j];
    if (off < 1e-18) break;
    for (let p = 0; p < 3; p++) for (let q = p + 1; q < 3; q++) {
      if (Math.abs(a[p][q]) < 1e-15) continue;
      const theta = (a[q][q] - a[p][p]) / (2 * a[p][q]);
      const t = Math.sign(theta || 1) / (Math.abs(theta) + Math.sqrt(theta * theta + 1));
      const cs = 1 / Math.sqrt(t * t + 1), sn = t * cs;
      for (let k = 0; k < 3; k++) { const akp = a[k][p], akq = a[k][q]; a[k][p] = cs * akp - sn * akq; a[k][q] = sn * akp + cs * akq; }
      for (let k = 0; k < 3; k++) { const apk = a[p][k], aqk = a[q][k]; a[p][k] = cs * apk - sn * aqk; a[q][k] = sn * apk + cs * aqk; }
      for (let k = 0; k < 3; k++) { const vkp = v[k][p], vkq = v[k][q]; v[k][p] = cs * vkp - sn * vkq; v[k][q] = sn * vkp + cs * vkq; }
    }
  }
  return { values: [a[0][0], a[1][1], a[2][2]], vectors: v };
}

/** Maximum matching in a general graph (Edmonds' blossom algorithm). adj: neighbour lists. Returns match[]. */
function maxMatching(n, adj) {
  const match = new Int32Array(n).fill(-1);
  // Greedy start, then augment from every unmatched vertex.
  for (let v = 0; v < n; v++) if (match[v] < 0) for (const u of adj[v]) if (match[u] < 0) { match[v] = u; match[u] = v; break; }
  const p = new Int32Array(n), base = new Int32Array(n), used = new Uint8Array(n), blossom = new Uint8Array(n), mark = new Uint8Array(n);
  const lca = (a, b) => {
    mark.fill(0);
    for (;;) { a = base[a]; mark[a] = 1; if (match[a] < 0) break; a = p[match[a]]; }
    for (;;) { b = base[b]; if (mark[b]) return b; b = p[match[b]]; }
  };
  const markPath = (v, b, child) => {
    while (base[v] !== b) { blossom[base[v]] = blossom[base[match[v]]] = 1; p[v] = child; child = match[v]; v = p[match[v]]; }
  };
  const findPath = (root) => {
    used.fill(0); p.fill(-1);
    for (let i = 0; i < n; i++) base[i] = i;
    used[root] = 1;
    const q = [root];
    for (let qh = 0; qh < q.length; qh++) {
      const v = q[qh];
      for (const to of adj[v]) {
        if (base[v] === base[to] || match[v] === to) continue;
        if (to === root || (match[to] >= 0 && p[match[to]] >= 0)) {
          const cb = lca(v, to);
          blossom.fill(0);
          markPath(v, cb, to); markPath(to, cb, v);
          for (let i = 0; i < n; i++) if (blossom[base[i]]) { base[i] = cb; if (!used[i]) { used[i] = 1; q.push(i); } }
        } else if (p[to] < 0) {
          p[to] = v;
          if (match[to] < 0) return to;
          used[match[to]] = 1; q.push(match[to]);
        }
      }
    }
    return -1;
  };
  for (let v = 0; v < n; v++) {
    if (match[v] >= 0) continue;
    let u = findPath(v);
    while (u >= 0) { const pv = p[u], ppv = match[pv]; match[u] = pv; match[pv] = u; u = ppv; }
  }
  return match;
}

const kekuleCache = new WeakMap();
/**
 * Port of MolCore Molecule.kekuleDisplayOrders(): bond orders for display with every aromatic (1.5) bond shown
 * as single or double in one alternating Kekulé structure. C/Si/B (and 2-connected N/P, cationic 3-connected N/P)
 * without an exocyclic double bond need a double bond; a 2-connected N/P only in five-membered rings may be the
 * pyrrole-type donor when no perfect structure exists; failing that, a maximum partial assignment is used.
 * Each connected aromatic system is matched separately.
 */
export function kekuleDisplayOrders(mol) {
  const hit = kekuleCache.get(mol);
  if (hit && hit.bonds === mol.bonds && hit.count === mol.bonds.length) return hit.orders;
  const n = mol.atoms.length, bonds = mol.bonds;
  const arom = [];
  bonds.forEach((b, k) => { if (b.order === 1.5 && b.a < n && b.b < n) arom.push(k); });
  const deg = new Int32Array(n), exo = new Uint8Array(n), inArom = new Uint8Array(n);
  const aromAdj = Array.from({ length: n }, () => []);
  for (const b of bonds) {
    if (b.a >= n || b.b >= n) continue;
    deg[b.a]++; deg[b.b]++;
    if (b.order === 2 || b.order === 3) exo[b.a] = exo[b.b] = 1;
  }
  for (const k of arom) { const b = bonds[k]; inArom[b.a] = inArom[b.b] = 1; aromAdj[b.a].push(b.b); aromAdj[b.b].push(b.a); }
  // Smallest aromatic ring through a 2-connected atom: shortest path between its two neighbours avoiding it.
  const ringSize = (i) => {
    const [s, t] = aromAdj[i]; if (t == null) return 0;
    const dist = new Map([[s, 0]]); const q = [s];
    for (let h = 0; h < q.length; h++) {
      const v = q[h]; if (v === t) return dist.get(v) + 2;
      if (dist.get(v) > 8) break;
      for (const w of aromAdj[v]) if (w !== i && !dist.has(w)) { dist.set(w, dist.get(v) + 1); q.push(w); }
    }
    return 0;
  };
  const attempt = (relax, partial) => {
    const need = new Uint8Array(n);
    for (let i = 0; i < n; i++) {
      if (!inArom[i] || exo[i]) continue;
      const z = mol.atoms[i].z;
      if (z === 6 || z === 14 || z === 5) need[i] = 1;
      else if (z === 7 || z === 15) {
        const donor = relax && deg[i] === 2 && ringSize(i) === 5;
        need[i] = (deg[i] === 2 && !donor) || (deg[i] === 3 && (mol.atoms[i].charge || 0) > 0.5) ? 1 : 0;
      }
    }
    const sid = new Int32Array(n).fill(-1); let cnt = 0;
    for (let i = 0; i < n; i++) if (need[i]) sid[i] = cnt++;
    const g = Array.from({ length: cnt }, () => []);
    for (const k of arom) { const { a, b } = bonds[k]; if (sid[a] >= 0 && sid[b] >= 0) { g[sid[a]].push(sid[b]); g[sid[b]].push(sid[a]); } }
    // Connected components keep the O(V^3) matcher cheap on proteins (many small rings).
    const comp = new Int32Array(cnt).fill(-1), match = new Int32Array(cnt).fill(-1);
    for (let s = 0; s < cnt; s++) {
      if (comp[s] >= 0) continue;
      const members = [s]; comp[s] = s;
      for (let h = 0; h < members.length; h++) for (const w of g[members[h]]) if (comp[w] < 0) { comp[w] = s; members.push(w); }
      const local = new Map(members.map((v, i) => [v, i]));
      const m = maxMatching(members.length, members.map((v) => g[v].map((w) => local.get(w))));
      members.forEach((v, i) => { match[v] = m[i] >= 0 ? members[m[i]] : -1; });
    }
    if (!partial && match.includes(-1)) return null;
    const out = bonds.map((b) => b.order);
    for (const k of arom) { const { a, b } = bonds[k]; out[k] = sid[a] >= 0 && sid[b] >= 0 && match[sid[a]] === sid[b] ? 2 : 1; }
    return out;
  };
  const orders = attempt(false, false) || attempt(true, false) || attempt(true, true);
  kekuleCache.set(mol, { bonds, count: bonds.length, orders });
  return orders;
}

export class Viewport {
  constructor(container, overlayCanvas) {
    this.container = container;
    this.overlay = overlayCanvas;
    this.octx = overlayCanvas.getContext('2d');
    this.options = { ...DEFAULT_OPTIONS };
    this.molecule = null;
    this.positions = []; // displayed positions (Vector3), may differ from molecule during animation
    this.selection = new Set();
    this.hover = null; // {kind:'atom'|'bond', index}
    this.measurements = []; // {atoms:[...], value, kind}
    this.pendingPicks = []; // atoms picked by Link/Gauge tools
    this.surfaces = new THREE.Group();
    this.hidden = new Set(); // atoms hidden by console commands
    this.cartoon = new CartoonLayer(this); // protein cartoon (style 'cartoon')
    this.colorOverrides = new Map(); // atom index -> css colour (console "color")
    this.arrows = null;
    this.vibration = null;
    this.listeners = {};
    this.dirty = true;
    this.renderer = new THREE.WebGLRenderer({ antialias: true, preserveDrawingBuffer: false, alpha: true, powerPreference: 'high-performance' });
    this.renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 2));
    this.renderer.setClearColor(0x000000, 0);
    this.renderer.outputColorSpace = THREE.SRGBColorSpace;
    // macOS renders HDR with a soft highlight shoulder (whitePoint 1.5) so white H atoms don't clip.
    // Khronos PBR Neutral leaves colours below ~0.8 untouched and only compresses highlights. The theme
    // background is not part of the WebGL image (the canvas is transparent over the container's CSS
    // background), so it stays exactly the macOS colour.
    this.renderer.toneMapping = THREE.NeutralToneMapping;
    this.renderer.toneMappingExposure = 1.0;
    container.appendChild(this.renderer.domElement);
    this.renderer.domElement.tabIndex = 0;
    this.renderer.domElement.className = 'gl';

    this.scene = new THREE.Scene();
    this.pmrem = new THREE.PMREMGenerator(this.renderer);
    this.envMaps = {}; // dark|light -> PMREM texture of the macOS studio environment
    this.scene.environment = this.studioEnvMap(false);

    this.persp = new THREE.PerspectiveCamera(35, 1, 0.05, 2000);
    this.ortho = new THREE.OrthographicCamera(-1, 1, 1, -1, -1000, 1000);
    this.camera = this.persp;
    this.target = new THREE.Vector3();
    this.distance = 12;
    this.orientation = new THREE.Quaternion();
    this.scene.add(this.persp); this.scene.add(this.ortho);

    // Lights follow the camera: the macOS LightingRig (Sources/MolRender/Lighting.swift). Its directional
    // lights shine along their local -z after eulerAngles (x, y) in camera space; a three.js directional
    // light shines from its position toward the target, so the position is the rotated +z axis.
    this.lightRig = new THREE.Group();
    const rigLight = (ex, ey) => {
      const l = new THREE.DirectionalLight(0xffffff, 1);
      l.position.copy(new THREE.Vector3(0, 0, 1).applyEuler(new THREE.Euler(ex, ey, 0, 'XYZ')).multiplyScalar(10));
      this.lightRig.add(l, l.target); // target at the rig origin (the camera)
      return l;
    };
    const key = rigLight(-0.45, -0.55), fill = rigLight(0.25, 0.7), rim = rigLight(0.2, Math.PI * 0.95);
    this.lights = { key, fill, rim };
    this.hemi = new THREE.AmbientLight(0xffffff, 0.4); // the rig's ambient node (name kept for callers)
    this.scene.add(this.hemi);
    this.scene.add(this.lightRig);

    this.molGroup = new THREE.Group();
    this.scene.add(this.molGroup);
    this.scene.add(this.surfaces);
    this.overlayGroup = new THREE.Group();
    this.measureOverlay = new MeasureOverlay(this); // geometry monitors (measure-overlay.js)
    this.scene.add(this.overlayGroup);

    // Overlay geometry (selection halos, hover, arrows); atoms and bonds use the LOD geometry below.
    this.sphereGeo = new THREE.SphereGeometry(1, 40, 28);
    this.cylGeo = new THREE.CylinderGeometry(1, 1, 1, 20, 1, true);
    this.coneGeo = new THREE.ConeGeometry(1, 1, 24, 1);
    this.lodKey = null;
    this.setLOD(0);
    // macOS glossy preset: physically based with a clear coat (MaterialLibrary.pbrParameters).
    this.material = new THREE.MeshPhysicalMaterial({ color: 0xffffff, roughness: 0.34, metalness: 0, clearcoat: 0.55, clearcoatRoughness: 0.07 });
    this.flatMaterial = new THREE.MeshBasicMaterial({ color: 0xffffff });
    this.highlightMat = new THREE.MeshBasicMaterial({ color: 0xffd21a, transparent: true, opacity: 0.45, depthWrite: false });
    this.hoverMat = new THREE.MeshBasicMaterial({ color: 0x4dccff, transparent: true, opacity: 0.4, depthWrite: false });
    this.pickMat = new THREE.MeshBasicMaterial({ color: 0x3dd68c, transparent: true, opacity: 0.5, depthWrite: false });

    // The scene renders into a 4× MSAA half-float target: EffectComposer targets are not antialiased by
    // `antialias: true` (that only affects the default framebuffer), which caused jagged bond edges.
    const rt = new THREE.WebGLRenderTarget(1, 1, { type: THREE.HalfFloatType, samples: 4 });
    this.composer = new EffectComposer(this.renderer, rt);
    this.renderPass = new RenderPass(this.scene, this.camera);
    this.composer.addPass(this.renderPass);
    // Ground-truth AO with a depth-aware Poisson denoise: smooth contact shadows (macOS SSAO radius 1.4 Å).
    this.sao = new GTAOPass(this.scene, this.camera, 1, 1);
    this.sao.output = GTAOPass.OUTPUT.Default;
    this.sao.blendIntensity = 0.85;
    this.sao.updateGtaoMaterial({ radius: 1.4, distanceExponent: 1.5, thickness: 1.5, scale: 1.0, samples: 16, distanceFallOff: 1.0 });
    this.sao.updatePdMaterial({ lumaPhi: 10, depthPhi: 2, normalPhi: 3, radius: 6, radiusExponent: 1, rings: 2, samples: 16 });
    // Keep translucent overlays and surfaces out of the AO G-buffer.
    const toggle = (visible) => { const p = new Pass(); p.needsSwap = false; p.render = () => { this.overlayGroup.visible = visible; this.surfaces.visible = visible; }; return p; };
    this.composer.addPass(toggle(false));
    this.composer.addPass(this.sao);
    this.composer.addPass(toggle(true));
    this.composer.addPass(new OutputPass());

    this.resizeObserver = new ResizeObserver(() => this.resize());
    this.resizeObserver.observe(container);
    this.resize();
    this.applyLook();
    this.loop = this.loop.bind(this);
    requestAnimationFrame(this.loop);
  }

  on(name, fn) { (this.listeners[name] ||= []).push(fn); }
  emit(name, ...a) { for (const f of this.listeners[name] || []) f(...a); }

  /** PMREM of the macOS procedural studio environment (cached per dark/light). */
  studioEnvMap(dark) {
    const k = dark ? 'dark' : 'light';
    if (!this.envMaps[k]) { const eq = studioEnvironment(dark); this.envMaps[k] = this.pmrem.fromEquirectangular(eq).texture; eq.dispose(); }
    return this.envMaps[k];
  }

  /** Atom sphere / bond cylinder tessellation for `n` atoms (instanced, so only the vertex count changes). */
  setLOD(n) {
    const s = lodSegments(n);
    // Fewer AO samples for very large structures keeps rotation interactive.
    this.sao?.updateGtaoMaterial({ samples: n > 20000 ? 8 : 16 });
    const key = `${s.sw}/${s.sh}/${s.cyl}`;
    if (key === this.lodKey) return;
    this.lodKey = key;
    this.atomGeo?.dispose(); this.bondGeo?.dispose();
    this.atomGeo = new THREE.SphereGeometry(1, s.sw, s.sh);
    this.bondGeo = new THREE.CylinderGeometry(1, 1, 1, s.cyl, 1, true);
  }

  /** Camera state for per-document views. */
  getCameraState() {
    return { target: this.target.toArray(), distance: this.distance, orientation: this.orientation.toArray() };
  }
  setCameraState(s) {
    if (!s) return false;
    this.target.fromArray(s.target); this.distance = s.distance; this.orientation.fromArray(s.orientation).normalize();
    this.updateCamera();
    return true;
  }

  // ---------- sizing / camera ----------
  resize() {
    const w = Math.max(1, this.container.clientWidth), h = Math.max(1, this.container.clientHeight);
    this.width = w; this.height = h;
    this.renderer.setSize(w, h, false);
    this.renderer.domElement.style.width = w + 'px';
    this.renderer.domElement.style.height = h + 'px';
    this.composer.setSize(w, h);
    const dpr = window.devicePixelRatio || 1;
    this.overlay.width = Math.round(w * dpr); this.overlay.height = Math.round(h * dpr);
    this.overlay.style.width = w + 'px'; this.overlay.style.height = h + 'px';
    this.updateCamera();
    this.dirty = true;
  }

  updateCamera() {
    const aspect = this.width / this.height;
    const dir = new THREE.Vector3(0, 0, 1).applyQuaternion(this.orientation);
    const pos = this.target.clone().addScaledVector(dir, this.distance);
    for (const cam of [this.persp, this.ortho]) {
      cam.position.copy(pos);
      cam.quaternion.copy(this.orientation);
    }
    this.persp.aspect = aspect;
    this.persp.near = Math.max(0.05, this.distance / 200);
    this.persp.far = this.distance * 20 + 200;
    this.persp.updateProjectionMatrix();
    const halfH = this.distance * Math.tan(THREE.MathUtils.degToRad(this.persp.fov / 2));
    this.ortho.left = -halfH * aspect; this.ortho.right = halfH * aspect;
    this.ortho.top = halfH; this.ortho.bottom = -halfH;
    this.ortho.near = -this.distance * 20 - 200; this.ortho.far = this.distance * 20 + 200;
    this.ortho.updateProjectionMatrix();
    this.lightRig.position.copy(pos);
    this.lightRig.quaternion.copy(this.orientation);
    this.dirty = true;
  }

  setProjection(mode) {
    this.options.projection = mode;
    this.camera = mode === 'orthographic' ? this.ortho : this.persp;
    this.renderPass.camera = this.camera;
    this.sao.camera = this.camera;
    const persp = this.camera.isPerspectiveCamera ? 1 : 0;
    for (const m of [this.sao.gtaoMaterial, this.sao.pdMaterial, this.sao.depthRenderMaterial]) {
      if (m && m.defines && m.defines.PERSPECTIVE_CAMERA !== persp) { m.defines.PERSPECTIVE_CAMERA = persp; m.needsUpdate = true; }
    }
    this.updateCamera();
    this.emit('options', this.options);
  }

  rotate(dx, dy) {
    const speed = 0.008;
    const right = new THREE.Vector3(1, 0, 0).applyQuaternion(this.orientation);
    const up = new THREE.Vector3(0, 1, 0).applyQuaternion(this.orientation);
    const q1 = new THREE.Quaternion().setFromAxisAngle(up, -dx * speed);
    const q2 = new THREE.Quaternion().setFromAxisAngle(right, -dy * speed);
    this.orientation.premultiply(q1).premultiply(q2).normalize();
    this.updateCamera();
  }
  roll(angle) {
    const fwd = new THREE.Vector3(0, 0, 1).applyQuaternion(this.orientation);
    this.orientation.premultiply(new THREE.Quaternion().setFromAxisAngle(fwd, angle)).normalize();
    this.updateCamera();
  }
  pan(dx, dy) {
    const halfH = this.distance * Math.tan(THREE.MathUtils.degToRad(this.persp.fov / 2));
    const k = (2 * halfH) / this.height;
    const right = new THREE.Vector3(1, 0, 0).applyQuaternion(this.orientation);
    const up = new THREE.Vector3(0, 1, 0).applyQuaternion(this.orientation);
    this.target.addScaledVector(right, -dx * k).addScaledVector(up, dy * k);
    this.updateCamera();
  }
  zoom(factor) {
    this.distance = Math.min(2000, Math.max(0.8, this.distance * factor));
    this.updateCamera();
  }

  boundingSphere() {
    if (!this.positions.length) return { center: new THREE.Vector3(), radius: 3 };
    const box = new THREE.Box3();
    this.positions.forEach((p, i) => { if (!this.cartoon.excludesFromFit(i)) box.expandByPoint(p); });
    if (box.isEmpty()) for (const p of this.positions) box.expandByPoint(p);
    const center = box.getCenter(new THREE.Vector3());
    let r = 0;
    this.positions.forEach((p, i) => {
      if (this.cartoon.excludesFromFit(i)) return;
      const z = this.molecule.atoms[i].z;
      r = Math.max(r, p.distanceTo(center) + (this.options.style === 'spaceFilling' ? element(z).vdw : 0.6));
    });
    const atoms = new THREE.Sphere(center, Math.max(r, 1.5));
    // Visible surfaces (orbitals, densities, volumes) and non-atom geometry in molGroup (protein cartoon)
    // count too, so big diffuse orbitals are not clipped.
    const extra = this.extraBounds();
    if (!extra.isEmpty()) atoms.union(extra.getBoundingSphere(new THREE.Sphere()));
    return { center: atoms.center, radius: atoms.radius };
  }

  /** Bounding box of visible surfaces and of molGroup children other than the atom/bond instances. */
  extraBounds() {
    const box = new THREE.Box3();
    const add = (o) => {
      if (!o.visible || o === this.atomMesh || o === this.bondMesh || o.isInstancedMesh) return;
      if (o.geometry) {
        if (!o.geometry.boundingBox) o.geometry.computeBoundingBox();
        o.updateWorldMatrix(true, false);
        box.union(o.geometry.boundingBox.clone().applyMatrix4(o.matrixWorld));
      }
      for (const c of o.children) add(c);
    };
    if (this.surfaces.visible) for (const c of this.surfaces.children) add(c);
    for (const c of this.molGroup.children) add(c);
    return box;
  }

  /** Zooms out (keeping the target and orientation) until the bounds above are fully in view. */
  ensureVisible() {
    const { center, radius } = this.boundingSphere();
    const fov = THREE.MathUtils.degToRad(this.persp.fov);
    const aspect = this.width / this.height;
    const half = Math.min(fov / 2, Math.atan(Math.tan(fov / 2) * aspect));
    const need = ((center.distanceTo(this.target) + radius) / Math.sin(half)) * 1.05;
    if (need > this.distance) { this.distance = need; this.updateCamera(); }
  }

  fit() {
    const { center, radius } = this.boundingSphere();
    this.target.copy(center);
    const fov = THREE.MathUtils.degToRad(this.persp.fov);
    const aspect = this.width / this.height;
    const fitH = radius / Math.sin(fov / 2);
    const fitW = radius / Math.sin(Math.atan(Math.tan(fov / 2) * aspect));
    this.distance = Math.max(fitH, fitW) * 1.08;
    this.updateCamera();
  }

  /** Turn the camera so the molecule's widest extent lies across the screen and its thinnest along the view. */
  orientToPrincipalAxes() {
    const P = this.positions;
    if (P.length < 2) { this.orientation.identity(); this.fit(); return; }
    const c = new THREE.Vector3(); for (const p of P) c.add(p); c.multiplyScalar(1 / P.length);
    const C = [[0, 0, 0], [0, 0, 0], [0, 0, 0]];
    for (const p of P) { const d = [p.x - c.x, p.y - c.y, p.z - c.z]; for (let i = 0; i < 3; i++) for (let j = 0; j < 3; j++) C[i][j] += d[i] * d[j]; }
    const { values, vectors } = jacobiEigen(C);
    const order = [0, 1, 2].sort((a, b) => values[b] - values[a]);
    const ex = new THREE.Vector3(...vectors.map((r) => r[order[0]])).normalize();
    let ey = new THREE.Vector3(...vectors.map((r) => r[order[1]])).normalize();
    if (values[order[1]] < 1e-6) { ey = new THREE.Vector3(0, 1, 0); if (Math.abs(ey.dot(ex)) > 0.9) ey.set(0, 0, 1); ey.sub(ex.clone().multiplyScalar(ey.dot(ex))).normalize(); }
    // Keep a consistent handedness and a "y up" bias so files written with y up stay upright.
    if (ey.y < 0) ey.negate();
    const ez = new THREE.Vector3().crossVectors(ex, ey).normalize();
    this.orientation.setFromRotationMatrix(new THREE.Matrix4().makeBasis(ex, ey, ez));
    this.fit();
  }

  /** Look along an axis: 'x', '-y', ... */
  viewAlong(axis) {
    const neg = axis.startsWith('-');
    const a = axis.replace('-', '');
    const dirs = { x: [1, 0, 0], y: [0, 1, 0], z: [0, 0, 1] };
    const d = new THREE.Vector3(...dirs[a]).multiplyScalar(neg ? -1 : 1); // camera sits on +d side
    const up = a === 'y' ? new THREE.Vector3(0, 0, neg ? 1 : -1) : new THREE.Vector3(0, 1, 0);
    const m = new THREE.Matrix4().lookAt(d, new THREE.Vector3(), up);
    this.orientation.setFromRotationMatrix(m);
    this.fit();
  }

  // ---------- options ----------
  setOptions(patch) {
    const prevStyle = this.options.style;
    Object.assign(this.options, patch);
    if ('projection' in patch) this.setProjection(patch.projection);
    this.applyLook();
    this.rebuild();
    if (patch.style && patch.style !== prevStyle && this.options.style === 'spaceFilling') this.dirty = true;
    this.emit('options', this.options);
  }

  /** 'auto' follows the interface theme (set by the app through `systemDark`). */
  resolvedTheme() {
    const t = this.options.theme;
    return t === 'auto' ? (this.systemDark ? 'dark' : 'light') : (THEMES[t] ? t : 'light');
  }
  setSystemDark(dark) { this.systemDark = dark; this.applyLook(); }

  backgroundColor() {
    return this.options.background ? new THREE.Color(this.options.background) : new THREE.Color(THEMES[this.resolvedTheme()].bg);
  }
  foreground() {
    const bg = this.backgroundColor();
    return isDarkBackground(bg) ? '#f2f2f2' : '#1a1a1f';
  }

  /** macOS LightingRig.apply: background, rig intensities, studio environment and AO per material. */
  applyLook() {
    const bg = this.backgroundColor();
    // The background is the container's CSS colour behind a transparent canvas, so tone mapping and AO
    // never touch it (exact macOS RenderTheme colour). Image export paints it in (exportPNG).
    this.scene.background = null;
    this.container.style.background = '#' + bg.getHexString(THREE.SRGBColorSpace);
    const dark = isDarkBackground(bg); // macOS compares sRGB components
    const name = this.options.material;
    const m = MATERIALS[name] || MATERIALS.glossy;
    Object.assign(this.material, { roughness: m.roughness, metalness: m.metalness, clearcoat: m.clearcoat, clearcoatRoughness: m.clearcoatRoughness });
    this.scene.environment = name === 'flat' ? null : this.studioEnvMap(dark);
    // lightingEnvironment.intensity: metallic 1.4, else 0.7 (dark) / 0.9 (light).
    this.material.envMapIntensity = name === 'metallic' ? 1.4 : (dark ? 0.7 : 0.9);
    this.material.needsUpdate = true;
    const L = this.lights;
    if (name === 'metallic') { L.key.intensity = SCN(1100); L.fill.intensity = SCN(250); L.rim.intensity = SCN(dark ? 500 : 300); this.hemi.intensity = SCN(dark ? 250 : 320); }
    else { L.key.intensity = SCN(820); L.fill.intensity = SCN(180); L.rim.intensity = SCN(dark ? 420 : 160); this.hemi.intensity = SCN(dark ? 380 : 480); }
    this.sao.enabled = !!this.options.ambientOcclusion && name !== 'flat';
    // Cartoons get a wider, softer occlusion (Mol*-like depth between helices and sheets); atoms keep the macOS 1.4 Å.
    const aoRadius = this.options.style === 'cartoon' ? 4.0 : 1.4;
    if (this.aoRadius !== aoRadius) { this.aoRadius = aoRadius; this.sao.updateGtaoMaterial({ radius: aoRadius }); }
    this.dirty = true;
  }

  // ---------- molecule ----------
  setMolecule(mol, { fit = false, keepSelection = false } = {}) {
    this.molecule = mol;
    this.positions = (mol?.atoms || []).map((a) => v3(a.pos));
    if (!keepSelection) { this.selection = new Set(); this.hidden.clear(); this.colorOverrides.clear(); }
    else this.selection = new Set([...this.selection].filter((i) => i < this.positions.length));
    this.hover = null;
    this.measurements = this.measurements.filter((m) => m.atoms.every((i) => i < this.positions.length));
    this.vibration = null;
    this.rebuild();
    if (fit) this.fit();
  }

  atomRadius(z) {
    const o = this.options;
    switch (o.style) {
      case 'spaceFilling': return element(z).vdw;
      case 'tube': return o.tubeRadius;
      case 'wireframe': return 0.06;
      default: return Math.max(o.atomScale * element(z).vdw, o.bondRadius * 1.15);
    }
  }
  bondRadius() {
    const o = this.options;
    switch (o.style) {
      case 'tube': return o.tubeRadius;
      case 'wireframe': return 0.02 * o.wireWidth;
      case 'spaceFilling': return 0;
      default: return o.bondRadius;
    }
  }
  atomVisible(i) {
    if (this.hidden.has(i)) return false;
    if (this.cartoon.hides(i)) return false;
    return this.options.showHydrogens || this.molecule.atoms[i].z !== 1;
  }

  atomColors() {
    const base = this.schemeColors();
    // Cartoon mode: ligand carbons take a tint of their chain colour (RCSB/Mol* look).
    if (this.cartoon.active()) {
      const atoms = this.molecule.atoms;
      for (let i = 0; i < atoms.length; i++) {
        if (atoms[i].z !== 6 || !base[i]) continue;
        const t = this.cartoon.ligandCarbonColor(i, base[i]);
        if (t) base[i] = t;
      }
    }
    for (const [i, c] of this.colorOverrides) if (base[i]) base[i] = new THREE.Color(c);
    return base;
  }

  schemeColors() {
    const atoms = this.molecule?.atoms || [];
    const o = this.options;
    if (o.colorScheme === 'uniform') return atoms.map(() => new THREE.Color(o.uniformColor));
    if (o.colorScheme === 'charge') {
      const range = Math.max(1e-9, ...atoms.map((a) => Math.abs(a.charge || 0)));
      const neg = new THREE.Color(0.84, 0.1, 0.11), pos = new THREE.Color(0.13, 0.3, 0.86), white = new THREE.Color(1, 1, 1);
      return atoms.map((a) => { const t = Math.max(-1, Math.min(1, (a.charge || 0) / range)); return white.clone().lerp(t < 0 ? neg : pos, Math.abs(t)); });
    }
    return atoms.map((a) => new THREE.Color(element(a.z).color));
  }

  /** Rebuild instanced meshes from the molecule and current displayed positions. */
  rebuild() {
    for (const c of [...this.molGroup.children]) { this.molGroup.remove(c); if (c.dispose) c.dispose(); }
    this.atomMesh = null; this.bondMesh = null;
    const mol = this.molecule;
    if (!mol || !mol.atoms.length) { this.updateHighlights(); this.dirty = true; return; }
    const mat = this.options.material === 'flat' ? this.flatMaterial : this.material;
    const n = mol.atoms.length;
    this.setLOD(n);
    this.atomMesh = new THREE.InstancedMesh(this.atomGeo, mat, n);
    this.atomMesh.instanceMatrix.setUsage(THREE.DynamicDrawUsage);
    const colors = this.colors = this.atomColors();
    for (let i = 0; i < n; i++) this.atomMesh.setColorAt(i, colors[i]);
    this.molGroup.add(this.atomMesh);
    // bond segments: each segment = {i, j, from(0..1), to, offset vector index, color atom}
    this.buildBondSegments();
    const segCount = this.bondSegs.length;
    if (segCount) {
      this.bondMesh = new THREE.InstancedMesh(this.bondGeo, mat, segCount);
      this.bondMesh.instanceMatrix.setUsage(THREE.DynamicDrawUsage);
      this.bondSegs.forEach((s, k) => {
        const c = s.color != null ? colors[s.color] : new THREE.Color(0x999999);
        this.bondMesh.setColorAt(k, c);
      });
      this.molGroup.add(this.bondMesh);
    }
    this.cartoon.build(this.molGroup);
    this.updateMatrices();
  }

  buildBondSegments() {
    const mol = this.molecule, o = this.options;
    const segs = [];
    this.bondSegs = segs;
    if (o.style === 'spaceFilling') return;
    // Cartoon mode draws its ligands and other non-polymer atoms as ball and stick, bond orders included.
    const orders = o.showBondOrders && (o.style === 'ballAndStick' || o.style === 'wireframe' || o.style === 'cartoon');
    // neighbour lists for choosing the plane of multiple bonds
    const nbrs = mol.atoms.map(() => []);
    this.bondOrders = new Map();
    for (const b of mol.bonds) { nbrs[b.a]?.push(b.b); nbrs[b.b]?.push(b.a); this.bondOrders.set(Math.min(b.a, b.b) * 1e6 + Math.max(b.a, b.b), b.order); }
    this.neighbors = nbrs;
    // macOS BondGeometry: multiple-bond lines have half the bond radius; double-bond lines sit at ±1.0 and
    // triple-bond lines at 0, ±1.3 bond radii (offsets below are in bond radii, see updateMatrices).
    // Aromatic bonds follow RenderOptions.aromaticStyle (default kekule: one alternating Kekulé structure).
    const aromatic = o.aromaticStyle || 'kekule';
    const kek = orders && aromatic === 'kekule' && mol.bonds.some((b) => b.order === 1.5) ? kekuleDisplayOrders(mol) : null;
    const MULTI = 0.5;
    mol.bonds.forEach((b, bi) => {
      if (!this.atomVisible(b.a) || !this.atomVisible(b.b)) return;
      let lines; // [offset in bond radii, dashed]
      const ord = kek ? kek[bi] : b.order;
      if (!orders || ord === 1 || ord == null) lines = [[0, false]];
      else if (ord === 2) lines = [[-1, false], [1, false]];
      else if (ord === 3) lines = [[-1.3, false], [0, false], [1.3, false]];
      else if (ord === 1.5) lines = [[-1, false], [1, true]];
      else lines = [[0, false]];
      const thin = lines.length > 1 ? MULTI : 1;
      const halves = o.splitBondColors ? [[0, 0.5, b.a], [0.5, 1, b.b]] : [[0, 1, null]];
      for (const [off, dashed] of lines) {
        for (const [h0, h1, color] of halves) {
          if (!dashed) { segs.push({ bond: bi, a: b.a, b: b.b, f0: h0, f1: h1, off, color, thin }); continue; }
          // BondGeometry.expandDashes: period max(3.6 r, 0.05 Å), dash from 10 % to 68 % of each period.
          const pa = this.positions[b.a], pb = this.positions[b.b];
          const len = (pa && pb ? pa.distanceTo(pb) : 1) * (h1 - h0);
          const period = Math.max(this.bondRadius() * thin * 3.6, 0.05);
          const n = Math.max(2, Math.round(len / period));
          const step = (h1 - h0) / n;
          for (let k = 0; k < n; k++) segs.push({ bond: bi, a: b.a, b: b.b, f0: h0 + step * (k + 0.1), f1: h0 + step * (k + 0.68), off, color, thin });
        }
      }
    });
  }

  orderOf(a, b) { return this.bondOrders?.get(Math.min(a, b) * 1e6 + Math.max(a, b)); }

  /** Perpendicular offset direction for bond a-b (in the plane of a neighbour when possible). */
  bondPlaneDir(a, b) {
    const pa = this.positions[a], pb = this.positions[b];
    const axis = new THREE.Vector3().subVectors(pb, pa).normalize();
    // Prefer a neighbour joined by an aromatic bond (so the inner aromatic line points into the ring),
    // then a heavy atom, then anything.
    let ref = null, best = -1;
    for (const [x, y] of [[a, b], [b, a]]) {
      for (const n of this.neighbors[x] || []) {
        if (n === y) continue;
        const score = (this.orderOf(x, n) === 1.5 ? 4 : 0) + (this.molecule.atoms[n].z !== 1 ? 2 : 0) + (x === a ? 1 : 0);
        if (score > best) { best = score; ref = new THREE.Vector3().subVectors(this.positions[n], this.positions[x]); }
      }
    }
    if (!ref) ref = new THREE.Vector3(0, 0, 1).applyQuaternion(this.orientation).cross(axis);
    let perp = ref.sub(axis.clone().multiplyScalar(ref.dot(axis)));
    // Collinear neighbours (H–C≡C–H, CO2): offset across the screen instead of along the view direction.
    if (perp.lengthSq() < 1e-6) perp = new THREE.Vector3(0, 0, 1).applyQuaternion(this.orientation).cross(axis);
    if (perp.lengthSq() < 1e-6) perp = Math.abs(axis.x) < 0.9 ? new THREE.Vector3(1, 0, 0).cross(axis) : new THREE.Vector3(0, 1, 0).cross(axis);
    return perp.normalize();
  }

  updateMatrices() {
    const mol = this.molecule;
    if (!mol || !this.atomMesh) { this.dirty = true; return; }
    const n = mol.atoms.length;
    for (let i = 0; i < n; i++) {
      const r = this.atomVisible(i) ? this.atomRadius(mol.atoms[i].z) : 0;
      tmpS.set(r, r, r);
      tmpM.compose(this.positions[i], tmpQ.identity(), tmpS);
      this.atomMesh.setMatrixAt(i, tmpM);
    }
    this.atomMesh.instanceMatrix.needsUpdate = true;
    if (this.atomMesh.instanceColor) this.atomMesh.instanceColor.needsUpdate = true;
    this.atomMesh.computeBoundingSphere();
    if (this.bondMesh) {
      const br = this.bondRadius();
      const planeCache = new Map();
      this.bondSegs.forEach((s, k) => {
        const pa = this.positions[s.a], pb = this.positions[s.b];
        let A = pa, B = pb;
        if (s.off) {
          let dir = planeCache.get(s.bond);
          if (!dir) { dir = this.bondPlaneDir(s.a, s.b); planeCache.set(s.bond, dir); }
          const spacing = this.options.style === 'wireframe' ? 0.045 : br; // s.off is in bond radii
          A = pa.clone().addScaledVector(dir, s.off * spacing);
          B = pb.clone().addScaledVector(dir, s.off * spacing);
        }
        const p0 = A.clone().lerp(B, s.f0), p1 = A.clone().lerp(B, s.f1);
        const d = new THREE.Vector3().subVectors(p1, p0);
        const len = d.length();
        tmpP.addVectors(p0, p1).multiplyScalar(0.5);
        tmpQ.setFromUnitVectors(UP, len > 1e-9 ? d.divideScalar(len) : UP);
        const r = br * (s.thin || 1);
        tmpS.set(r, len, r);
        tmpM.compose(tmpP, tmpQ, tmpS);
        this.bondMesh.setMatrixAt(k, tmpM);
      });
      this.bondMesh.instanceMatrix.needsUpdate = true;
      this.bondMesh.computeBoundingSphere();
    }
    this.cartoon.sync();
    this.updateHighlights();
    this.dirty = true;
  }

  // ---------- selection / hover overlays ----------
  setSelection(set) { this.selection = new Set(set); this.updateHighlights(); this.emit('selection', this.selection); }

  updateHighlights() {
    const shared = new Set([this.sphereGeo, this.cylGeo, this.coneGeo]);
    for (const c of [...this.overlayGroup.children]) {
      this.overlayGroup.remove(c);
      if (c.geometry && !shared.has(c.geometry)) c.geometry.dispose();
      if (c.isLine) c.material.dispose();
      if (c.isInstancedMesh) c.dispose();
    }
    const mol = this.molecule;
    if (!mol) { this.dirty = true; return; }
    const addSpheres = (indices, mat, scale) => {
      const list = indices.filter((i) => i < this.positions.length && (this.atomVisible(i) || this.cartoon.isPickable(i)));
      if (!list.length) return;
      const m = new THREE.InstancedMesh(this.sphereGeo, mat, list.length);
      list.forEach((i, k) => {
        const r = Math.max(this.atomRadius(mol.atoms[i].z) * scale, this.atomRadius(mol.atoms[i].z) + 0.12);
        tmpS.set(r, r, r); tmpM.compose(this.positions[i], tmpQ.identity(), tmpS); m.setMatrixAt(k, tmpM);
      });
      m.renderOrder = 5;
      this.overlayGroup.add(m);
    };
    addSpheres([...this.selection], this.highlightMat, 1.25);
    addSpheres(this.pendingPicks, this.pickMat, 1.35);
    if (this.hover?.kind === 'atom') addSpheres([this.hover.index], this.hoverMat, 1.3);
    if (this.hover?.kind === 'bond') {
      const b = mol.bonds[this.hover.index];
      if (b) {
        const p0 = this.positions[b.a], p1 = this.positions[b.b];
        const d = new THREE.Vector3().subVectors(p1, p0); const len = d.length();
        const r = Math.max(this.bondRadius(), 0.05) * 1.6 + 0.04;
        const m = new THREE.Mesh(this.cylGeo, this.hoverMat);
        m.position.addVectors(p0, p1).multiplyScalar(0.5);
        m.quaternion.setFromUnitVectors(UP, d.normalize()); m.scale.set(r, len, r);
        m.renderOrder = 5;
        this.overlayGroup.add(m);
      }
    }
    // measurement monitors: dihedral planes in 3D; lines, arcs and values on the 2D overlay (drawOverlay)
    this.measureOverlay.sync(this.overlayGroup);
    if (this.arrows) this.overlayGroup.add(this.arrows);
    this.dirty = true;
  }

  // ---------- picking ----------
  rayFromEvent(x, y) {
    const ndc = new THREE.Vector2((x / this.width) * 2 - 1, -(y / this.height) * 2 + 1);
    const rc = new THREE.Raycaster();
    rc.setFromCamera(ndc, this.camera);
    return rc.ray;
  }

  pick(x, y) {
    const mol = this.molecule;
    if (!mol || !mol.atoms.length) return null;
    const ray = this.rayFromEvent(x, y);
    let best = null;
    mol.atoms.forEach((a, i) => {
      if (!this.atomVisible(i)) return;
      const r = Math.max(this.atomRadius(a.z), this.options.style === 'wireframe' ? 0.22 : 0.15);
      const t = raySphere(ray.origin, ray.direction, this.positions[i], r);
      if (t >= 0 && (!best || t < best.t)) best = { kind: 'atom', index: i, t };
    });
    best = this.cartoon.pick(ray, best);
    const br = Math.max(this.bondRadius(), 0.12);
    if (this.options.style !== 'spaceFilling') {
      mol.bonds.forEach((b, bi) => {
        if (!this.atomVisible(b.a) || !this.atomVisible(b.b)) return;
        const r = raySegment(ray.origin, ray.direction, this.positions[b.a], this.positions[b.b]);
        if (r.dist < br * (b.order > 1 ? 2.2 : 1.3) && (!best || r.s < best.t - 0.05)) best = { kind: 'bond', index: bi, t: r.s };
      });
    }
    return best;
  }

  /** Atoms whose projected centres lie inside a screen rectangle. */
  atomsInRect(x0, y0, x1, y1) {
    const [ax, bx] = [Math.min(x0, x1), Math.max(x0, x1)], [ay, by] = [Math.min(y0, y1), Math.max(y0, y1)];
    const out = [];
    this.positions.forEach((p, i) => {
      if (!this.atomVisible(i)) return;
      const s = this.project(p);
      if (s.x >= ax && s.x <= bx && s.y >= ay && s.y <= by && s.z < 1) out.push(i);
    });
    return out;
  }

  project(p) {
    const v = p.clone().project(this.camera);
    return { x: (v.x + 1) * 0.5 * this.width, y: (1 - v.y) * 0.5 * this.height, z: v.z };
  }

  /** World point under the cursor on the plane through the target facing the camera. */
  unprojectOnTargetPlane(x, y, through = this.target) {
    const ray = this.rayFromEvent(x, y);
    const normal = new THREE.Vector3(0, 0, 1).applyQuaternion(this.orientation);
    const plane = new THREE.Plane().setFromNormalAndCoplanarPoint(normal, through);
    const out = new THREE.Vector3();
    return ray.intersectPlane(plane, out) || through.clone();
  }

  setHover(h) {
    const same = (h?.kind === this.hover?.kind) && (h?.index === this.hover?.index);
    if (same) return;
    this.hover = h ? { kind: h.kind, index: h.index } : null;
    this.updateHighlights();
  }

  // ---------- measurements ----------
  setMeasurements(list) { this.measurements = list; this.updateHighlights(); }
  setPendingPicks(list) { this.pendingPicks = list; this.updateHighlights(); }

  // ---------- surfaces ----------
  clearSurfaces() {
    for (const c of [...this.surfaces.children]) { this.surfaces.remove(c); c.geometry?.dispose(); c.material?.dispose(); }
    this.dirty = true;
  }
  /** meshes: protocol Mesh objects. look: {positive, negative, opacity, mode: solid|transparent|wireframe|points} */
  addSurfaces(meshes, look, tag = 'surface') {
    const dec = (b64, Type) => { const bin = atob(b64); const buf = new Uint8Array(bin.length); for (let i = 0; i < bin.length; i++) buf[i] = bin.charCodeAt(i); return new Type(buf.buffer); };
    for (const m of meshes) {
      if (!m.positionsB64 || !m.vertexCount) continue;
      const g = new THREE.BufferGeometry();
      g.setAttribute('position', new THREE.BufferAttribute(dec(m.positionsB64, Float32Array), 3));
      if (m.normalsB64) g.setAttribute('normal', new THREE.BufferAttribute(dec(m.normalsB64, Float32Array), 3));
      if (m.indicesB64) g.setIndex(new THREE.BufferAttribute(dec(m.indicesB64, Uint32Array), 1));
      if (!m.normalsB64) g.computeVertexNormals();
      let vc = false;
      if (m.colorsB64) { g.setAttribute('color', new THREE.BufferAttribute(dec(m.colorsB64, Float32Array), 4)); vc = true; }
      const color = new THREE.Color(m.sign < 0 ? look.negative : look.positive);
      const mode = look.mode || 'transparent';
      let obj;
      if (mode === 'points') {
        obj = new THREE.Points(g, new THREE.PointsMaterial({ color: vc ? 0xffffff : color, vertexColors: vc, size: 2, sizeAttenuation: false }));
      } else {
        const opacity = mode === 'solid' ? 1 : (look.opacity ?? 0.6);
        const mat = new THREE.MeshStandardMaterial({
          color: vc ? 0xffffff : color, vertexColors: vc, roughness: 0.35, metalness: 0, side: THREE.DoubleSide,
          transparent: opacity < 1, opacity, depthWrite: opacity >= 1, wireframe: mode === 'wireframe', envMapIntensity: 0.6,
        });
        obj = new THREE.Mesh(g, mat);
        obj.renderOrder = opacity < 1 ? 3 : 0;
      }
      obj.userData = { tag, sign: m.sign };
      this.surfaces.add(obj);
    }
    if (this.surfaces.children.length) this.ensureVisible();
    this.dirty = true;
  }
  restyleSurfaces(look) {
    // Cheap path for colour/opacity changes; mode changes need addSurfaces again.
    for (const o of this.surfaces.children) {
      const mat = o.material;
      if (!mat.vertexColors) mat.color.set(o.userData.sign < 0 ? look.negative : look.positive);
      if (!o.isPoints && look.mode !== 'solid') { mat.opacity = look.opacity; mat.transparent = look.opacity < 1; mat.depthWrite = look.opacity >= 1; }
    }
    this.dirty = true;
  }

  // ---------- vibrations ----------
  /** displacements: [[x,y,z]] per atom; amplitude in Å scaling the normalised mode. */
  startVibration(displacements, { amplitude = 0.6, speed = 1, base = null } = {}) {
    if (!this.molecule || displacements.length !== this.molecule.atoms.length) return;
    let maxLen = 0;
    for (const d of displacements) maxLen = Math.max(maxLen, Math.hypot(...d));
    const norm = maxLen > 1e-9 ? 1 / maxLen : 0;
    const b = base && base.length === this.molecule.atoms.length ? base : this.molecule.atoms.map((a) => a.pos);
    this.vibration = { disp: displacements.map((d) => v3(d).multiplyScalar(norm)), amplitude, speed, t0: performance.now(), base: b.map(v3) };
  }
  setVibrationParams({ amplitude, speed }) {
    if (!this.vibration) return;
    if (amplitude != null) this.vibration.amplitude = amplitude;
    if (speed != null) this.vibration.speed = speed;
  }
  stopVibration() {
    if (!this.vibration) return;
    this.vibration = null;
    if (this.molecule) this.positions = this.molecule.atoms.map((a) => v3(a.pos));
    this.updateMatrices();
  }
  showArrows(displacements, scale = 1.6, base = null) {
    if (this.arrows) { this.overlayGroup.remove(this.arrows); this.arrows = null; }
    if (!displacements || !this.molecule) { this.updateHighlights(); return; }
    let maxLen = 0; for (const d of displacements) maxLen = Math.max(maxLen, Math.hypot(...d));
    const k = maxLen > 1e-9 ? scale / maxLen : 0;
    const items = displacements.map((d, i) => ({ i, v: v3(d).multiplyScalar(k) })).filter((x) => x.v.length() > 0.08 && this.atomVisible(x.i));
    const g = new THREE.Group();
    const mat = new THREE.MeshStandardMaterial({ color: 0x1f8fff, roughness: 0.4 });
    const shafts = new THREE.InstancedMesh(this.cylGeo, mat, Math.max(1, items.length));
    const heads = new THREE.InstancedMesh(this.coneGeo, mat, Math.max(1, items.length));
    items.forEach(({ i, v }, n) => {
      const start = base?.[i] ? v3(base[i]) : this.molecule.atoms[i] ? v3(this.molecule.atoms[i].pos) : new THREE.Vector3();
      const len = v.length(); const dir = v.clone().normalize();
      const headLen = Math.min(0.3, len * 0.4);
      tmpQ.setFromUnitVectors(UP, dir);
      tmpM.compose(start.clone().addScaledVector(dir, (len - headLen) / 2), tmpQ, tmpS.set(0.045, len - headLen, 0.045)); shafts.setMatrixAt(n, tmpM);
      tmpM.compose(start.clone().addScaledVector(dir, len - headLen / 2), tmpQ, tmpS.set(0.11, headLen, 0.11)); heads.setMatrixAt(n, tmpM);
    });
    shafts.count = items.length; heads.count = items.length;
    g.add(shafts, heads);
    this.arrows = g;
    this.updateHighlights();
  }

  /** Display a precomputed geometry (trajectory frame) without changing topology. */
  setDisplayedPositions(posArray) {
    if (!this.molecule || posArray.length !== this.molecule.atoms.length) return false;
    this.positions = posArray.map(v3);
    this.updateMatrices();
    return true;
  }

  // ---------- render loop ----------
  loop(now) {
    requestAnimationFrame(this.loop);
    if (this.vibration) {
      const v = this.vibration;
      const s = Math.sin(((now - v.t0) / 1000) * Math.PI * 2 * 0.9 * v.speed) * v.amplitude;
      this.positions = v.base.map((b, i) => b.clone().addScaledVector(v.disp[i] || new THREE.Vector3(), s));
      this.updateMatrices();
    }
    if (!this.dirty) return;
    this.dirty = false;
    this.renderNow();
  }

  renderNow() {
    this.composer.render();
    this.drawOverlay(this.octx, this.width, this.height, window.devicePixelRatio || 1);
  }

  labelText(i) {
    const a = this.molecule.atoms[i];
    switch (this.options.labelMode) {
      case 'element': return a.symbol;
      case 'index': return String(i + 1);
      case 'elementIndex': return `${a.symbol}${i + 1}`;
      case 'charge': return (a.charge >= 0 ? '+' : '') + Number(a.charge || 0).toFixed(2);
      case 'custom': return a.label || '';
      default: return '';
    }
  }

  drawOverlay(ctx, w, h, scale) {
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.clearRect(0, 0, ctx.canvas.width, ctx.canvas.height);
    ctx.setTransform(scale, 0, 0, scale, 0, 0);
    const mol = this.molecule;
    const fg = this.foreground();
    if (mol && this.options.labelMode !== 'none') {
      ctx.font = '600 12px "Segoe UI", system-ui, sans-serif';
      ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
      const order = this.positions.map((p, i) => ({ i, s: this.project(p) })).filter((x) => x.s.z < 1 && this.atomVisible(x.i)).sort((a, b) => b.s.z - a.s.z);
      for (const { i, s } of order) {
        const t = this.labelText(i); if (!t) continue;
        const tw = ctx.measureText(t).width;
        ctx.fillStyle = fg === '#f2f2f2' ? 'rgba(20,22,26,0.72)' : 'rgba(255,255,255,0.78)';
        ctx.beginPath(); ctx.roundRect(s.x - tw / 2 - 4, s.y - 8, tw + 8, 16, 4); ctx.fill();
        ctx.fillStyle = fg; ctx.fillText(t, s.x, s.y);
      }
    }
    if (mol) this.measureOverlay.draw2D(ctx); // distance lines, angle/dihedral arcs and values
    if (this.options.showAxes) this.drawAxes(ctx, 44, h - 44, 26);
    if (this.boxRect) {
      const r = this.boxRect;
      ctx.strokeStyle = '#2f7cf6'; ctx.fillStyle = 'rgba(47,124,246,0.12)'; ctx.lineWidth = 1;
      ctx.fillRect(r.x, r.y, r.w, r.h); ctx.strokeRect(r.x + 0.5, r.y + 0.5, r.w, r.h);
    }
  }

  drawAxes(ctx, cx, cy, len) {
    const inv = this.orientation.clone().invert();
    const axes = [['x', [1, 0, 0], '#e5484d'], ['y', [0, 1, 0], '#30a46c'], ['z', [0, 0, 1], '#3e7bfa']]
      .map(([n, d, c]) => ({ n, c, v: new THREE.Vector3(...d).applyQuaternion(inv) }))
      .sort((a, b) => a.v.z - b.v.z);
    ctx.lineWidth = 2; ctx.font = '600 10px "Segoe UI", sans-serif'; ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
    for (const a of axes) {
      ctx.strokeStyle = a.c; ctx.fillStyle = a.c;
      ctx.beginPath(); ctx.moveTo(cx, cy); ctx.lineTo(cx + a.v.x * len, cy - a.v.y * len); ctx.stroke();
      ctx.fillText(a.n, cx + a.v.x * (len + 9), cy - a.v.y * (len + 9));
    }
  }

  // ---------- export ----------
  /** Renders at width×height and returns a PNG data URL (labels and measurements included). */
  exportPNG(width, height, { transparent = false } = {}) {
    const maxSize = this.renderer.capabilities.maxTextureSize || 8192;
    const f = Math.min(1, maxSize / Math.max(width, height));
    width = Math.round(width * f); height = Math.round(height * f);
    const prev = { w: this.width, h: this.height, pr: this.renderer.getPixelRatio(), bg: this.scene.background };
    this.renderer.setPixelRatio(1);
    this.width = width; this.height = height;
    this.renderer.setSize(width, height, false);
    this.composer.setPixelRatio(1);
    this.composer.setSize(width, height);
    this.updateCamera();
    if (transparent) { this.scene.background = null; this.renderer.setClearColor(0x000000, 0); }
    // scale the camera so the framing matches the on-screen view at a different aspect ratio
    this.composer.render();
    const out = document.createElement('canvas');
    out.width = width; out.height = height;
    const ctx = out.getContext('2d');
    // The on-screen background is CSS behind a transparent canvas: paint it into the image.
    if (!transparent) { ctx.fillStyle = '#' + this.backgroundColor().getHexString(THREE.SRGBColorSpace); ctx.fillRect(0, 0, width, height); }
    ctx.drawImage(this.renderer.domElement, 0, 0);
    const lay = document.createElement('canvas'); lay.width = width; lay.height = height;
    const showAxes = this.options.showAxes; this.options.showAxes = false;
    const s = Math.max(1, Math.min(width / prev.w, height / prev.h));
    // Draw overlay in a logical coordinate system of the export size divided by s, scaled by s.
    this.width = width / s; this.height = height / s;
    this.drawOverlay(lay.getContext('2d'), width / s, height / s, s);
    this.options.showAxes = showAxes;
    ctx.drawImage(lay, 0, 0);
    // restore
    this.scene.background = prev.bg;
    this.renderer.setPixelRatio(prev.pr);
    this.composer.setPixelRatio(prev.pr);
    this.resize();
    this.renderNow();
    return out.toDataURL('image/png');
  }
}

export { cssColor };
