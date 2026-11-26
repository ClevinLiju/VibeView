// Geometry monitors drawn over the molecule: dashed distance lines, angle arcs at the vertex atom, dihedral
// arcs around the central bond, and (optionally) the two half-planes of a dihedral meeting along bond 2-3.
// Everything follows the viewport's displayed positions, so monitors track vibrations, trajectory frames
// and edits. Lines, arcs, sectors and values are painted on the 2D overlay canvas from projected 3D points
// (always on top, with a dark halo so they read on light and dark backgrounds, and included in image
// export); the dihedral planes are depth-tested translucent meshes in the 3D scene.
import * as THREE from 'three';

/** Monitor colours (bright, distinct, legible with the dark halo on any background). */
export const MONITOR_COLORS = ['#ffc93c', '#4cc9f0', '#f472b6', '#a3e635', '#fb923c', '#a78bfa', '#2dd4bf', '#f87171'];
/** Plane colours for the two dihedral planes (atoms 1-2-3 and 2-3-4). */
export const PLANE_COLORS = ['#4f8ff7', '#fb8c3c'];

/** Stable colour for a monitor: assigned once (lowest palette slot not used by the others) and kept on it. */
export function monitorColor(m, list = []) {
  if (!m.color) {
    const used = new Set(list.filter((o) => o !== m && o.color).map((o) => o.color));
    m.color = MONITOR_COLORS.find((c) => !used.has(c)) || MONITOR_COLORS[list.indexOf(m) % MONITOR_COLORS.length] || MONITOR_COLORS[0];
  }
  return m.color;
}

/** Whether a dihedral monitor shows its planes: its own toggle, else the global view option. */
export function planesShown(m, options) {
  return m.kind === 'dihedral' && (m.planes ?? !!options.dihedralPlanes);
}

const clamp = (x, a, b) => Math.max(a, Math.min(b, x));
const ARC_STEPS = 40;

/** Angle arc at p1 between p0 and p2: {center, e1, e2, theta, r} (points are center + r(cos t e1 + sin t e2)). */
function angleArc(p0, p1, p2, camDir, atomR = 0) {
  const a = new THREE.Vector3().subVectors(p0, p1), b = new THREE.Vector3().subVectors(p2, p1);
  const la = a.length(), lb = b.length();
  if (la < 1e-6 || lb < 1e-6) return null;
  const e1 = a.divideScalar(la);
  const bh = b.divideScalar(lb);
  const theta = Math.acos(clamp(e1.dot(bh), -1, 1));
  let e2 = bh.clone().addScaledVector(e1, -e1.dot(bh));
  if (e2.lengthSq() < 1e-10) { // straight angle: draw the half circle facing the camera
    e2 = camDir.clone().cross(e1);
    if (e2.lengthSq() < 1e-10) e2 = new THREE.Vector3(Math.abs(e1.x) < 0.9 ? 1 : 0, Math.abs(e1.x) < 0.9 ? 0 : 1, 0).cross(e1);
  }
  e2.normalize();
  // A fraction of the shorter bond, but outside the vertex atom's sphere so the arc is not lost in it.
  const short = Math.min(la, lb);
  const r = Math.min(Math.max(0.38 * short, atomR + 0.16), 0.75 * short, 1.1);
  return { center: p1.clone(), e1, e2, theta, r, value: theta * 180 / Math.PI };
}

/** Dihedral arc around bond p1-p2 (centre at its midpoint) from the projection of p1→p0 to that of p2→p3. */
function dihedralArc(p0, p1, p2, p3) {
  const axis = new THREE.Vector3().subVectors(p2, p1);
  const L = axis.length();
  if (L < 1e-6) return null;
  const u = axis.divideScalar(L);
  const v1 = new THREE.Vector3().subVectors(p0, p1); v1.addScaledVector(u, -u.dot(v1));
  const v2 = new THREE.Vector3().subVectors(p3, p2); v2.addScaledVector(u, -u.dot(v2));
  const l1 = v1.length(), l2 = v2.length();
  // IUPAC torsion (same formula as App.measureValue): positive = clockwise looking from atom 2 to atom 3.
  const b1 = new THREE.Vector3().subVectors(p1, p0), b3 = new THREE.Vector3().subVectors(p3, p2);
  const n1 = b1.clone().cross(u), n2 = u.clone().cross(b3);
  const value = Math.atan2(n1.clone().cross(u).dot(n2), n1.dot(n2)) * 180 / Math.PI;
  const center = p1.clone().lerp(p2, 0.5);
  if (l1 < 1e-6 || l2 < 1e-6) return { center, u, value, theta: 0, r: 0, L, degenerate: true };
  const e1 = v1.divideScalar(l1), w = v2.divideScalar(l2);
  const theta = Math.atan2(e1.clone().cross(w).dot(u), e1.dot(w)); // signed rotation about u from e1 to w
  const e2 = u.clone().cross(e1); // e1 rotated +90° about u
  const r = clamp(0.5 * Math.min(l1, l2, Math.max(L, 0.8)), 0.3, 0.9);
  return { center, u, e1, e2, theta, r, L, value, w, l1, l2 };
}

function arcPoint(arc, t, out = new THREE.Vector3()) {
  const s = arc.theta * t;
  return out.copy(arc.center).addScaledVector(arc.e1, Math.cos(s) * arc.r).addScaledVector(arc.e2, Math.sin(s) * arc.r);
}

export class MeasureOverlay {
  constructor(viewport) {
    this.vp = viewport;
    this.group = new THREE.Group();
    this.group.name = 'measure-overlay';
    this.planes = new Map(); // measurement object -> {mesh, edges} for the dihedral planes
    this.bondKey = null; this.bondSet = new Set();
  }

  /** Called from Viewport.updateHighlights after it emptied overlayGroup: re-attach and refresh the 3D part. */
  sync(parent) {
    parent.add(this.group);
    const vp = this.vp;
    const live = new Set();
    // Translucency blends in linear light: a light background needs more opacity for the same visual weight.
    this.planeOpacity = vp.foreground() === '#f2f2f2' ? 0.16 : 0.34;
    for (const m of vp.measurements) {
      monitorColor(m, vp.measurements);
      if (!planesShown(m, vp.options)) continue;
      const P = m.atoms.map((i) => vp.positions[i]);
      if (P.length !== 4 || P.some((p) => !p)) continue;
      live.add(m);
      this.updatePlanes(m, P);
    }
    for (const [m, obj] of this.planes) if (!live.has(m)) this.disposePlanes(m, obj);
  }

  updatePlanes(m, [p0, p1, p2, p3]) {
    let obj = this.planes.get(m);
    if (!obj) {
      const geo = new THREE.BufferGeometry();
      geo.setAttribute('position', new THREE.BufferAttribute(new Float32Array(8 * 3), 3));
      geo.setAttribute('color', new THREE.BufferAttribute(new Float32Array(8 * 3), 3));
      geo.setIndex([0, 1, 2, 0, 2, 3, 4, 5, 6, 4, 6, 7]);
      const mat = new THREE.MeshBasicMaterial({ vertexColors: true, transparent: true, opacity: 0.15, side: THREE.DoubleSide, depthWrite: false, toneMapped: false });
      const mesh = new THREE.Mesh(geo, mat);
      mesh.renderOrder = 4;
      const egeo = new THREE.BufferGeometry();
      egeo.setAttribute('position', new THREE.BufferAttribute(new Float32Array(16 * 3), 3));
      egeo.setAttribute('color', new THREE.BufferAttribute(new Float32Array(16 * 3), 3));
      const emat = new THREE.LineBasicMaterial({ vertexColors: true, transparent: true, opacity: 0.75, depthWrite: false, toneMapped: false });
      const edges = new THREE.LineSegments(egeo, emat);
      edges.renderOrder = 4;
      const ca = new THREE.Color(PLANE_COLORS[0]), cb = new THREE.Color(PLANE_COLORS[1]);
      const col = geo.attributes.color, ecol = egeo.attributes.color;
      for (let k = 0; k < 8; k++) (k < 4 ? ca : cb).toArray(col.array, k * 3);
      for (let k = 0; k < 16; k++) (k < 8 ? ca : cb).toArray(ecol.array, k * 3);
      obj = { mesh, edges };
      this.planes.set(m, obj);
      this.group.add(mesh, edges);
    }
    obj.mesh.material.opacity = this.planeOpacity ?? 0.16;
    const axis = new THREE.Vector3().subVectors(p2, p1);
    const L = axis.length();
    const pos = obj.mesh.geometry.attributes.position, epos = obj.edges.geometry.attributes.position;
    if (L < 1e-6) { obj.mesh.visible = obj.edges.visible = false; return; }
    obj.mesh.visible = obj.edges.visible = true;
    const u = axis.divideScalar(L);
    // Each plane is the half-plane bounded by the 2-3 axis that contains the outer atom (an open book whose
    // spine is the central bond), long enough along the axis to cover the outer atom's foot point.
    const quad = (outer, k0) => {
      const v = new THREE.Vector3().subVectors(outer, p1);
      const t = u.dot(v);
      v.addScaledVector(u, -t);
      let hgt = v.length();
      const n = hgt > 1e-6 ? v.divideScalar(hgt) : new THREE.Vector3(0, 0, 1).applyQuaternion(this.vp.orientation).cross(u).normalize();
      hgt = Math.max(hgt + 0.35, 0.9);
      const m0 = 0.35;
      const t0 = Math.min(0, t) - m0, t1 = Math.max(L, t) + m0;
      const A = p1.clone().addScaledVector(u, t0), B = p1.clone().addScaledVector(u, t1);
      const C = B.clone().addScaledVector(n, hgt), D = A.clone().addScaledVector(n, hgt);
      [A, B, C, D].forEach((p, j) => p.toArray(pos.array, (k0 + j) * 3));
      [A, B, B, C, C, D, D, A].forEach((p, j) => p.toArray(epos.array, (k0 * 2 + j) * 3));
    };
    quad(p0, 0);
    quad(p3, 4);
    pos.needsUpdate = true; epos.needsUpdate = true;
    obj.mesh.geometry.computeBoundingSphere(); obj.edges.geometry.computeBoundingSphere();
  }

  disposePlanes(m, obj) {
    this.group.remove(obj.mesh, obj.edges);
    obj.mesh.geometry.dispose(); obj.mesh.material.dispose();
    obj.edges.geometry.dispose(); obj.edges.material.dispose();
    this.planes.delete(m);
  }

  dispose() {
    for (const [m, obj] of [...this.planes]) this.disposePlanes(m, obj);
    this.group.parent?.remove(this.group);
  }

  bonded(a, b) {
    const mol = this.vp.molecule;
    if (!mol) return false;
    if (this.bondKey !== mol.bonds) {
      this.bondKey = mol.bonds;
      this.bondSet = new Set(mol.bonds.map((x) => Math.min(x.a, x.b) * 1e6 + Math.max(x.a, x.b)));
    }
    return this.bondSet.has(Math.min(a, b) * 1e6 + Math.max(a, b));
  }

  /** Paints lines, arcs, sectors and values on the 2D overlay (Viewport.drawOverlay). */
  draw2D(ctx) {
    const vp = this.vp;
    if (!vp.molecule || !vp.measurements.length) return;
    const camDir = new THREE.Vector3(0, 0, 1).applyQuaternion(vp.orientation);
    const HALO = 'rgba(10,10,14,0.85)';
    const proj = (p) => vp.project(p);
    const path = (pts) => { ctx.beginPath(); pts.forEach((s, k) => (k ? ctx.lineTo(s.x, s.y) : ctx.moveTo(s.x, s.y))); };
    const stroke = (pts, color, width, dash = null) => {
      ctx.setLineDash(dash || []);
      path(pts); ctx.lineWidth = width + 2.5; ctx.strokeStyle = HALO; ctx.stroke();
      path(pts); ctx.lineWidth = width; ctx.strokeStyle = color; ctx.stroke();
      ctx.setLineDash([]);
    };
    const fill = (pts, color, alpha) => { path(pts); ctx.closePath(); ctx.globalAlpha = alpha; ctx.fillStyle = color; ctx.fill(); ctx.globalAlpha = 1; };
    const sf = vp.options.style === 'spaceFilling';
    // Dashed connector between two monitored atoms when no visible bond already joins them.
    const connector = (i, j, P, color, always) => {
      if (!always && !sf && this.bonded(i, j) && vp.atomVisible(i) && vp.atomVisible(j)) return;
      const a = proj(P[0]), b = proj(P[1]);
      if (a.z >= 1 || b.z >= 1) return;
      stroke([a, b], color, always ? 2 : 1.4, [7, 5]);
    };
    ctx.lineCap = 'round'; ctx.lineJoin = 'round';
    const labels = [];
    for (const m of vp.measurements) {
      const P = m.atoms.map((i) => vp.positions[i]);
      if (P.some((p) => !p)) continue;
      const color = monitorColor(m, vp.measurements);
      let anchor, out = null, value = m.value;
      if (P.length === 2) {
        connector(m.atoms[0], m.atoms[1], P, color, true);
        anchor = P[0].clone().lerp(P[1], 0.5);
        value = P[0].distanceTo(P[1]);
      } else if (P.length === 3) {
        connector(m.atoms[0], m.atoms[1], [P[0], P[1]], color, false);
        connector(m.atoms[1], m.atoms[2], [P[1], P[2]], color, false);
        const arc = angleArc(P[0], P[1], P[2], camDir, vp.atomVisible(m.atoms[1]) ? vp.atomRadius(vp.molecule.atoms[m.atoms[1]].z) : 0);
        if (!arc) { anchor = P[1]; } else {
          value = arc.value;
          const pts = []; for (let k = 0; k <= ARC_STEPS; k++) pts.push(proj(arcPoint(arc, k / ARC_STEPS)));
          const c = proj(arc.center);
          if (c.z < 1 && pts.every((s) => s.z < 1)) {
            fill([c, ...pts], color, 0.2);
            stroke(pts, color, 2.6);
          }
          anchor = arcPoint(arc, 0.5); out = c;
        }
      } else {
        for (let k = 0; k < 3; k++) connector(m.atoms[k], m.atoms[k + 1], [P[k], P[k + 1]], color, false);
        const arc = dihedralArc(P[0], P[1], P[2], P[3]);
        if (!arc) { anchor = P[1].clone().lerp(P[2], 0.5); } else {
          value = arc.value;
          anchor = arc.center;
          if (!arc.degenerate) {
            const pts = []; for (let k = 0; k <= ARC_STEPS; k++) pts.push(proj(arcPoint(arc, k / ARC_STEPS)));
            const c = proj(arc.center);
            const s1 = proj(arc.center.clone().addScaledVector(arc.e1, arc.r * 1.18));
            const s2 = proj(arc.center.clone().addScaledVector(arc.w, arc.r * 1.18));
            if (c.z < 1 && pts.every((s) => s.z < 1)) {
              if (Math.abs(arc.theta) > 1e-3) fill([c, ...pts], color, 0.2);
              // Spokes along the projected bonds 2→1 and 3→4 (both drawn from the bond midpoint).
              stroke([c, s1], color, 1.6, [4, 3]);
              stroke([c, s2], color, 1.6, [4, 3]);
              if (Math.abs(arc.theta) > 1e-3) stroke(pts, color, 2.6);
              const dot = (s) => { ctx.beginPath(); ctx.arc(s.x, s.y, 3.2, 0, Math.PI * 2); ctx.fillStyle = HALO; ctx.fill(); ctx.beginPath(); ctx.arc(s.x, s.y, 2.1, 0, Math.PI * 2); ctx.fillStyle = color; ctx.fill(); };
              dot(c);
            }
            anchor = arcPoint(arc, 0.5); out = c;
          }
        }
      }
      labels.push({ m, anchor, out, value, color });
    }
    // Values: large bold digits in the monitor colour with a thick dark halo, readable on any background
    // and over atoms. Arc labels sit just outside the arc midpoint; overlapping labels are stacked.
    ctx.font = '700 17px "Segoe UI", system-ui, sans-serif';
    ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
    ctx.miterLimit = 2;
    const placed = [];
    for (const { m, anchor, out, value, color } of labels) {
      const s = proj(anchor);
      if (s.z >= 1) continue;
      const unit = m.kind === 'distance' ? ' Å' : '°';
      const t = value != null && Number.isFinite(value) ? `${value.toFixed(m.kind === 'distance' ? 3 : 1)}${unit}` : '…';
      const tw = ctx.measureText(t).width;
      let x = s.x, y = s.y - 14;
      if (out && out.z < 1) {
        let dx = s.x - out.x, dy = s.y - out.y;
        const d = Math.hypot(dx, dy);
        if (d > 1e-3) { dx /= d; dy /= d; } else { dx = 0; dy = -1; }
        // Push the text box centre out along the bisector until the box clears the arc.
        const off = 6 + Math.abs(dx) * tw / 2 + Math.abs(dy) * 10;
        x = s.x + dx * off; y = s.y + dy * off;
      }
      for (let tries = 0; tries < 8 && placed.some((r) => Math.abs(r.x - x) < (r.w + tw) / 2 + 4 && Math.abs(r.y - y) < 20); tries++) y -= 21;
      placed.push({ x, y, w: tw });
      ctx.lineWidth = 5; ctx.strokeStyle = 'rgba(10,10,14,0.92)';
      ctx.strokeText(t, x, y);
      ctx.fillStyle = color;
      ctx.fillText(t, x, y);
      m.screen = { x, y, w: tw + 10 };
    }
  }
}
