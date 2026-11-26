// Calculation Setup catalog: one table of methods and basis sets with the keyword each program expects.
// The engine writes `spec.method` / `spec.basis` verbatim into the input (Gaussian route, ORCA "!" line, Q-Chem $rem),
// so program-specific spelling lives here. A program key that's missing means "not offered for that program".
//
// Method entry:  { id, label, group, kind, disp, ri, programs: { <program>: keyword | { kw, disp, ri } } }
//   kind  'hf' | 'dft' | 'dh' (double hybrid) | 'composite' (own basis + dispersion) | 'semi' (semi-empirical, no basis) | 'wft' (MP2/CC) | 'xtb'
//   disp  dispersion corrections that have parameters for this method: subset of ['d3bj','d3zero','d4'],
//         or 'builtin' (part of the method, e.g. wB97X-D, B97-D3, composites) or [] (none, e.g. MP2/CC).
//   ri    ORCA needs a /C auxiliary basis (RI-MP2, DLPNO, double hybrids).
// Basis entry:   { id, label, group, maxZ, programs: { <program>: keyword }, orcaC: '<basis>/C' }

export const PROGRAMS = ['orca', 'gaussian', 'qchem', 'xtb'];
export const PROGRAM_TITLES = { orca: 'ORCA', gaussian: 'Gaussian', qchem: 'Q-Chem', xtb: 'xtb' };

const ALL_D = ['d3bj', 'd3zero', 'd4'];
const g = (gaussian, orca, qchem) => {
  const p = {};
  if (gaussian) p.gaussian = gaussian;
  if (orca) p.orca = orca;
  if (qchem) p.qchem = qchem;
  return p;
};

export const METHODS = [
  // Hartree–Fock
  { id: 'HF', label: 'HF', group: 'Hartree–Fock', kind: 'hf', disp: ALL_D, programs: g('HF', 'HF', 'HF') },
  // GGA / meta-GGA
  { id: 'PBE', label: 'PBE', group: 'GGA / meta-GGA', kind: 'dft', disp: ALL_D, programs: g('PBEPBE', 'PBE', 'PBE') },
  { id: 'BP86', label: 'BP86', group: 'GGA / meta-GGA', kind: 'dft', disp: ALL_D, programs: g('BP86', 'BP86', 'BP86') },
  { id: 'BLYP', label: 'BLYP', group: 'GGA / meta-GGA', kind: 'dft', disp: ALL_D, programs: g('BLYP', 'BLYP', 'BLYP') },
  { id: 'revPBE', label: 'revPBE', group: 'GGA / meta-GGA', kind: 'dft', disp: ALL_D, programs: g(null, 'revPBE', 'revPBE') },
  { id: 'B97-D3', label: 'B97-D3', group: 'GGA / meta-GGA', kind: 'dft', disp: 'builtin', programs: g('B97D3', 'B97-D3', 'B97-D3(0)') },
  { id: 'TPSS', label: 'TPSS', group: 'GGA / meta-GGA', kind: 'dft', disp: ALL_D, programs: g('TPSSTPSS', 'TPSS', 'TPSS') },
  { id: 'M06-L', label: 'M06-L', group: 'GGA / meta-GGA', kind: 'dft', disp: ['d3zero'], programs: g('M06L', 'M06L', 'M06-L') },
  { id: 'r2SCAN', label: 'r2SCAN', group: 'GGA / meta-GGA', kind: 'dft', disp: ALL_D, programs: g(null, 'r2SCAN', 'r2SCAN') },
  { id: 'B97M-V', label: 'B97M-V', group: 'GGA / meta-GGA', kind: 'dft', disp: 'builtin', programs: g(null, 'B97M-V', 'B97M-V') },
  // Hybrids
  { id: 'B3LYP', label: 'B3LYP', group: 'Hybrid', kind: 'dft', disp: ALL_D, programs: g('B3LYP', 'B3LYP', 'B3LYP') },
  { id: 'PBE0', label: 'PBE0', group: 'Hybrid', kind: 'dft', disp: ALL_D, programs: g('PBE1PBE', 'PBE0', 'PBE0') },
  { id: 'B3PW91', label: 'B3PW91', group: 'Hybrid', kind: 'dft', disp: ['d3bj', 'd3zero'], programs: g('B3PW91', 'B3PW91', 'B3PW91') },
  { id: 'APFD', label: 'APFD', group: 'Hybrid', kind: 'dft', disp: 'builtin', programs: g('APFD', null, null) },
  { id: 'r2SCAN0', label: 'r2SCAN0', group: 'Hybrid', kind: 'dft', disp: ['d4'], programs: g(null, 'r2SCAN0', 'r2SCAN0') },
  { id: 'PW6B95', label: 'PW6B95', group: 'Hybrid', kind: 'dft', disp: ['d3bj', 'd3zero', 'd4'], programs: g(null, 'PW6B95', 'PW6B95') },
  { id: 'TPSSh', label: 'TPSSh', group: 'Hybrid', kind: 'dft', disp: ALL_D, programs: g('TPSSh', 'TPSSh', 'TPSSh') },
  { id: 'M06', label: 'M06', group: 'Hybrid', kind: 'dft', disp: ['d3zero'], programs: g('M06', 'M06', 'M06') },
  { id: 'M06-2X', label: 'M06-2X', group: 'Hybrid', kind: 'dft', disp: ['d3zero'], programs: g('M062X', 'M062X', 'M06-2X') },
  { id: 'MN15', label: 'MN15', group: 'Hybrid', kind: 'dft', disp: [], programs: g('MN15', 'MN15', 'MN15') },
  // Range-separated hybrids
  { id: 'CAM-B3LYP', label: 'CAM-B3LYP', group: 'Range-separated hybrid', kind: 'dft', disp: ALL_D, programs: g('CAM-B3LYP', 'CAM-B3LYP', 'CAM-B3LYP') },
  { id: 'LC-wPBE', label: 'LC-ωPBE', group: 'Range-separated hybrid', kind: 'dft', disp: ALL_D, programs: g('LC-wHPBE', 'LC-PBE', 'LRC-wPBE') },
  { id: 'wB97X', label: 'ωB97X', group: 'Range-separated hybrid', kind: 'dft', disp: [], programs: g('wB97X', 'wB97X', 'wB97X') },
  { id: 'wB97X-D', label: 'ωB97X-D', group: 'Range-separated hybrid', kind: 'dft', disp: 'builtin', programs: g('wB97XD', 'wB97X-D3', 'wB97X-D') },
  { id: 'wB97X-D3BJ', label: 'ωB97X-D3(BJ)', group: 'Range-separated hybrid', kind: 'dft', disp: 'builtin', programs: g(null, 'wB97X-D3BJ', null) },
  { id: 'wB97X-V', label: 'ωB97X-V', group: 'Range-separated hybrid', kind: 'dft', disp: 'builtin', programs: g(null, 'wB97X-V', 'wB97X-V') },
  { id: 'wB97M-V', label: 'ωB97M-V', group: 'Range-separated hybrid', kind: 'dft', disp: 'builtin', programs: g(null, 'wB97M-V', 'wB97M-V') },
  // Double hybrids
  { id: 'B2PLYP', label: 'B2PLYP', group: 'Double hybrid', kind: 'dh', disp: ALL_D, ri: true, programs: g('B2PLYP', 'B2PLYP', 'B2PLYP') },
  { id: 'mPW2PLYP', label: 'mPW2PLYP', group: 'Double hybrid', kind: 'dh', disp: ['d3bj'], ri: true, programs: g('mPW2PLYP', 'mPW2PLYP', null) },
  { id: 'revDSD-PBEP86-D4', label: 'revDSD-PBEP86-D4', group: 'Double hybrid', kind: 'dh', disp: 'builtin', ri: true, programs: g(null, 'revDSD-PBEP86-D4', null) },
  { id: 'DSD-PBEP86', label: 'DSD-PBEP86', group: 'Double hybrid', kind: 'dh', disp: ['d3bj'], ri: true,
    programs: { gaussian: 'DSDPBEP86', orca: 'DSD-PBEP86', qchem: { kw: 'DSD-PBEP86-D3', disp: 'builtin' } } },
  // Composite (own basis set and corrections; ORCA)
  { id: 'r2SCAN-3c', label: 'r2SCAN-3c', group: 'Composite (own basis)', kind: 'composite', disp: 'builtin', programs: g(null, 'r2SCAN-3c', null) },
  { id: 'B97-3c', label: 'B97-3c', group: 'Composite (own basis)', kind: 'composite', disp: 'builtin', programs: g(null, 'B97-3c', null) },
  { id: 'PBEh-3c', label: 'PBEh-3c', group: 'Composite (own basis)', kind: 'composite', disp: 'builtin', programs: g(null, 'PBEh-3c', null) },
  { id: 'HF-3c', label: 'HF-3c', group: 'Composite (own basis)', kind: 'composite', disp: 'builtin', programs: g(null, 'HF-3c', null) },
  // Gaussian composite thermochemistry models (own basis sets; the engine treats them as basis-free)
  { id: 'CBS-QB3', label: 'CBS-QB3', group: 'Composite (own basis)', kind: 'composite', disp: [], programs: g('CBS-QB3', null, null) },
  { id: 'G4', label: 'G4', group: 'Composite (own basis)', kind: 'composite', disp: [], programs: g('G4', null, null) },
  // Semi-empirical (no basis set)
  { id: 'PM7', label: 'PM7', group: 'Semi-empirical', kind: 'semi', disp: [], programs: g('PM7', null, null) },
  { id: 'PM6', label: 'PM6', group: 'Semi-empirical', kind: 'semi', disp: [], programs: g('PM6', null, null) },
  { id: 'PM3', label: 'PM3', group: 'Semi-empirical', kind: 'semi', disp: [], programs: g('PM3', 'PM3', null) },
  { id: 'AM1', label: 'AM1', group: 'Semi-empirical', kind: 'semi', disp: [], programs: g('AM1', 'AM1', null) },
  // Wavefunction
  { id: 'MP2', label: 'MP2', group: 'Wavefunction', kind: 'wft', disp: [], programs: g('MP2', 'MP2', 'MP2') },
  { id: 'RI-MP2', label: 'RI-MP2', group: 'Wavefunction', kind: 'wft', disp: [], ri: true, programs: g(null, 'RI-MP2', null) },
  { id: 'SCS-MP2', label: 'SCS-RI-MP2', group: 'Wavefunction', kind: 'wft', disp: [], ri: true, programs: g(null, 'RI-SCS-MP2', null) },
  { id: 'MP4', label: 'MP4(SDTQ)', group: 'Wavefunction', kind: 'wft', disp: [], programs: g('MP4', null, null) },
  { id: 'CCSD', label: 'CCSD', group: 'Wavefunction', kind: 'wft', disp: [], programs: g('CCSD', 'CCSD', 'CCSD') },
  { id: 'CCSD(T)', label: 'CCSD(T)', group: 'Wavefunction', kind: 'wft', disp: [], programs: g('CCSD(T)', 'CCSD(T)', 'CCSD(T)') },
  { id: 'DLPNO-CCSD(T)', label: 'DLPNO-CCSD(T)', group: 'Wavefunction', kind: 'wft', disp: [], ri: true, programs: g(null, 'DLPNO-CCSD(T)', null) },
  { id: 'DLPNO-CCSD(T1)', label: 'DLPNO-CCSD(T1)', group: 'Wavefunction', kind: 'wft', disp: [], ri: true, programs: g(null, 'DLPNO-CCSD(T1)', null) },
  // xtb
  { id: 'GFN2-xTB', label: 'GFN2-xTB', group: 'xtb', kind: 'xtb', disp: 'builtin', programs: { xtb: 'GFN2-xTB' } },
  { id: 'GFN1-xTB', label: 'GFN1-xTB', group: 'xtb', kind: 'xtb', disp: 'builtin', programs: { xtb: 'GFN1-xTB' } },
  { id: 'GFN-FF', label: 'GFN-FF', group: 'xtb', kind: 'xtb', disp: 'builtin', programs: { xtb: 'GFN-FF' } },
];

// maxZ: heaviest element the basis is defined for (all-electron or with its standard ECP).
const pople = (id, qchem, maxZ = 36) => ({ id, label: id, group: 'Pople', maxZ, programs: { gaussian: id, orca: id, qchem: qchem || id } });
export const BASES = [
  { id: 'STO-3G', label: 'STO-3G', group: 'Minimal', maxZ: 54, programs: { gaussian: 'STO-3G', orca: 'STO-3G', qchem: 'STO-3G' } },
  pople('3-21G', '3-21G', 54),
  pople('6-31G'),
  pople('6-31G(d)', '6-31G*'),
  pople('6-31G(d,p)', '6-31G**'),
  pople('6-31+G(d,p)', '6-31+G**'),
  pople('6-31++G(d,p)', '6-31++G**'),
  pople('6-31G(2df,p)'),
  pople('6-311G(d,p)', '6-311G**'),
  pople('6-311+G(d,p)', '6-311+G**'),
  pople('6-311+G(2d,p)'),
  pople('6-311++G(d,p)', '6-311++G**'),
  pople('6-311++G(2d,2p)'),
  pople('6-311++G(3df,3pd)'),
  // Karlsruhe def2 (elements past Kr get the def2 ECPs automatically: ORCA and Gaussian built-ins; Q-Chem via ECP def2-ECP)
  { id: 'def2-SVP', label: 'def2-SVP', group: 'Karlsruhe def2', maxZ: 86, ecp: 'def2', programs: { gaussian: 'Def2SVP', orca: 'def2-SVP', qchem: 'def2-SVP' }, orcaC: 'def2-SVP/C' },
  { id: 'def2-SV(P)', label: 'def2-SV(P)', group: 'Karlsruhe def2', maxZ: 86, ecp: 'def2', programs: { orca: 'def2-SV(P)', qchem: 'def2-SV(P)' }, orcaC: 'def2-SVP/C' },
  { id: 'def2-SVPD', label: 'def2-SVPD', group: 'Karlsruhe def2', maxZ: 86, ecp: 'def2', programs: { orca: 'def2-SVPD', qchem: 'def2-SVPD' }, orcaC: 'def2-SVPD/C' },
  { id: 'def2-TZVP', label: 'def2-TZVP', group: 'Karlsruhe def2', maxZ: 86, ecp: 'def2', programs: { gaussian: 'Def2TZVP', orca: 'def2-TZVP', qchem: 'def2-TZVP' }, orcaC: 'def2-TZVP/C' },
  { id: 'def2-TZVP(-f)', label: 'def2-TZVP(-f)', group: 'Karlsruhe def2', maxZ: 86, ecp: 'def2', programs: { orca: 'def2-TZVP(-f)' }, orcaC: 'def2-TZVP/C' },
  { id: 'def2-TZVPP', label: 'def2-TZVPP', group: 'Karlsruhe def2', maxZ: 86, ecp: 'def2', programs: { gaussian: 'Def2TZVPP', orca: 'def2-TZVPP', qchem: 'def2-TZVPP' }, orcaC: 'def2-TZVPP/C' },
  { id: 'def2-TZVPD', label: 'def2-TZVPD', group: 'Karlsruhe def2', maxZ: 86, ecp: 'def2', programs: { orca: 'def2-TZVPD', qchem: 'def2-TZVPD' }, orcaC: 'def2-TZVPD/C' },
  { id: 'def2-QZVP', label: 'def2-QZVP', group: 'Karlsruhe def2', maxZ: 86, ecp: 'def2', programs: { gaussian: 'Def2QZVP', orca: 'def2-QZVP', qchem: 'def2-QZVP' }, orcaC: 'def2-QZVPP/C' },
  { id: 'def2-QZVPP', label: 'def2-QZVPP', group: 'Karlsruhe def2', maxZ: 86, ecp: 'def2', programs: { gaussian: 'Def2QZVPP', orca: 'def2-QZVPP', qchem: 'def2-QZVPP' }, orcaC: 'def2-QZVPP/C' },
  { id: 'ma-def2-SVP', label: 'ma-def2-SVP', group: 'Karlsruhe def2', maxZ: 86, ecp: 'def2', programs: { orca: 'ma-def2-SVP' }, orcaC: 'def2-SVP/C' },
  { id: 'ma-def2-TZVP', label: 'ma-def2-TZVP', group: 'Karlsruhe def2', maxZ: 86, ecp: 'def2', programs: { orca: 'ma-def2-TZVP' }, orcaC: 'def2-TZVP/C' },
  // Dunning
  { id: 'cc-pVDZ', label: 'cc-pVDZ', group: 'Dunning', maxZ: 36, programs: { gaussian: 'cc-pVDZ', orca: 'cc-pVDZ', qchem: 'cc-pVDZ' }, orcaC: 'cc-pVDZ/C' },
  { id: 'cc-pVTZ', label: 'cc-pVTZ', group: 'Dunning', maxZ: 36, programs: { gaussian: 'cc-pVTZ', orca: 'cc-pVTZ', qchem: 'cc-pVTZ' }, orcaC: 'cc-pVTZ/C' },
  { id: 'cc-pVQZ', label: 'cc-pVQZ', group: 'Dunning', maxZ: 36, programs: { gaussian: 'cc-pVQZ', orca: 'cc-pVQZ', qchem: 'cc-pVQZ' }, orcaC: 'cc-pVQZ/C' },
  { id: 'cc-pV5Z', label: 'cc-pV5Z', group: 'Dunning', maxZ: 36, programs: { gaussian: 'cc-pV5Z', orca: 'cc-pV5Z', qchem: 'cc-pV5Z' }, orcaC: 'cc-pV5Z/C' },
  { id: 'aug-cc-pVDZ', label: 'aug-cc-pVDZ', group: 'Dunning', maxZ: 36, programs: { gaussian: 'aug-cc-pVDZ', orca: 'aug-cc-pVDZ', qchem: 'aug-cc-pVDZ' }, orcaC: 'aug-cc-pVDZ/C' },
  { id: 'aug-cc-pVTZ', label: 'aug-cc-pVTZ', group: 'Dunning', maxZ: 36, programs: { gaussian: 'aug-cc-pVTZ', orca: 'aug-cc-pVTZ', qchem: 'aug-cc-pVTZ' }, orcaC: 'aug-cc-pVTZ/C' },
  { id: 'aug-cc-pVQZ', label: 'aug-cc-pVQZ', group: 'Dunning', maxZ: 36, programs: { gaussian: 'aug-cc-pVQZ', orca: 'aug-cc-pVQZ', qchem: 'aug-cc-pVQZ' }, orcaC: 'aug-cc-pVQZ/C' },
  { id: 'jun-cc-pVTZ', label: 'jun-cc-pVTZ', group: 'Dunning', maxZ: 18, programs: { gaussian: 'jun-cc-pVTZ' } },
  // Jensen
  { id: 'pcseg-1', label: 'pcseg-1', group: 'Jensen', maxZ: 36, programs: { orca: 'pcseg-1', qchem: 'pcseg-1' } },
  { id: 'aug-pcseg-1', label: 'aug-pcseg-1', group: 'Jensen', maxZ: 36, programs: { orca: 'aug-pcseg-1', qchem: 'aug-pcseg-1' } },
  { id: 'pcseg-2', label: 'pcseg-2', group: 'Jensen', maxZ: 36, programs: { orca: 'pcseg-2', qchem: 'pcseg-2' } },
  { id: 'aug-pcseg-2', label: 'aug-pcseg-2', group: 'Jensen', maxZ: 36, programs: { orca: 'aug-pcseg-2', qchem: 'aug-pcseg-2' } },
  { id: 'pcseg-3', label: 'pcseg-3', group: 'Jensen', maxZ: 36, programs: { orca: 'pcseg-3', qchem: 'pcseg-3' } },
  // ECP basis for heavy atoms
  { id: 'LANL2DZ', label: 'LANL2DZ (ECP)', group: 'Effective core potential', maxZ: 83, ecp: 'lanl2dz', programs: { gaussian: 'LANL2DZ', orca: 'LANL2DZ', qchem: 'LANL2DZ' } },
  { id: 'SDD', label: 'SDD (Stuttgart/Dresden ECP)', group: 'Effective core potential', maxZ: 86, programs: { gaussian: 'SDD' } },
];

export const DISPERSIONS = [
  { value: 'd3bj', label: 'D3(BJ)', programs: ['gaussian', 'orca', 'qchem'] },
  { value: 'd3zero', label: 'D3(0)', programs: ['gaussian', 'orca', 'qchem'] },
  { value: 'd4', label: 'D4', programs: ['orca', 'qchem'] },
];

/** ORCA RI / auxiliary basis choices (keywords appended to the "!" line). */
export const ORCA_AUX = [
  { value: 'auto', label: 'Automatic', title: 'Program default for Coulomb/exchange; adds the matching /C basis for RI-MP2, DLPNO and double hybrids' },
  { value: 'rijcosx', label: 'RIJCOSX def2/J', keywords: ['RIJCOSX', 'def2/J'] },
  { value: 'rij', label: 'RI-J def2/J', keywords: ['RI', 'def2/J'] },
  { value: 'rijk', label: 'RIJK def2/JK', keywords: ['RIJK', 'def2/JK'] },
  { value: 'autoaux', label: 'AutoAux', keywords: ['AutoAux'] },
  { value: 'nori', label: 'No RI (NoRI)', keywords: ['NoRI'] },
];

export const OTHER = '__other__';

const norm = (s) => String(s || '').trim().toLowerCase();
const entryFor = (e, program) => {
  const p = e.programs[program];
  if (p == null) return null;
  return typeof p === 'string' ? { kw: p, disp: e.disp, ri: !!e.ri } : { kw: p.kw, disp: p.disp ?? e.disp, ri: p.ri ?? !!e.ri };
};

export function methodsFor(program) { return METHODS.filter((m) => m.programs[program] != null); }
export function basesFor(program) { return program === 'xtb' ? [] : BASES.filter((b) => b.programs[program] != null); }

/** Catalog entry by id, label or any program keyword (saved settings may hold an older keyword such as "M062X"). */
export function findMethod(text) {
  const t = norm(text);
  if (!t) return null;
  return METHODS.find((m) => norm(m.id) === t || norm(m.label) === t) ||
    METHODS.find((m) => Object.values(m.programs).some((p) => norm(typeof p === 'string' ? p : p.kw) === t)) || null;
}
export function findBasis(text) {
  const t = norm(text);
  if (!t) return null;
  return BASES.find((b) => norm(b.id) === t || norm(b.label) === t) ||
    BASES.find((b) => Object.values(b.programs).some((p) => norm(p) === t)) || null;
}

/**
 * Resolves the dialog state ({program, methodId|OTHER, methodText, basisId|OTHER, basisText, dispersion, aux})
 * to what goes into CalcSpecJSON, plus UI hints and warnings.
 */
export function resolve(state, molecule) {
  const program = state.program;
  const out = { method: '', basis: '', dispersion: null, auxKeywords: [], warnings: [], basisHidden: false, dispersionMode: 'choose', dispersionOptions: [], auxShown: false };
  // method
  let mEntry = null;
  let mInfo = null;
  if (state.methodId === OTHER) {
    out.method = String(state.methodText || '').trim();
  } else {
    mEntry = METHODS.find((m) => m.id === state.methodId) || null;
    mInfo = mEntry && entryFor(mEntry, program);
    if (mInfo) out.method = mInfo.kw;
    else if (mEntry) out.warnings.push(`${PROGRAM_TITLES[program]} has no ${mEntry.label}.`);
  }
  const kind = mEntry?.kind || (program === 'xtb' ? 'xtb' : 'dft');
  out.kind = kind;
  // basis
  out.basisHidden = program === 'xtb' || kind === 'composite' || kind === 'semi' || kind === 'xtb';
  let bEntry = null;
  if (!out.basisHidden) {
    if (state.basisId === OTHER) out.basis = String(state.basisText || '').trim();
    else {
      bEntry = BASES.find((b) => b.id === state.basisId) || null;
      if (bEntry && bEntry.programs[program]) out.basis = bEntry.programs[program];
      else if (bEntry) out.warnings.push(`${PROGRAM_TITLES[program]} has no built-in ${bEntry.label}; choose another basis or Other….`);
    }
    if (bEntry && molecule?.atoms?.length) {
      const zMax = Math.max(...molecule.atoms.map((a) => a.z ?? a.atomicNumber ?? 0));
      if (zMax > bEntry.maxZ) out.warnings.push(`${bEntry.label} is defined only up to Z = ${bEntry.maxZ}; this molecule has Z = ${zMax}. Use def2-* or LANL2DZ for heavy atoms.`);
    }
  }
  // dispersion
  const progDisp = DISPERSIONS.filter((d) => d.programs.includes(program)).map((d) => d.value);
  const methodDisp = mInfo ? mInfo.disp : (state.methodId === OTHER ? ALL_D : []);
  if (program === 'xtb' || methodDisp === 'builtin') out.dispersionMode = 'builtin';
  else {
    out.dispersionOptions = progDisp.filter((d) => methodDisp.includes(d));
    out.dispersionMode = out.dispersionOptions.length ? 'choose' : 'none';
    if (out.dispersionOptions.includes(state.dispersion)) out.dispersion = state.dispersion;
  }
  // ORCA auxiliary basis / RI
  if (program === 'orca' && !out.basisHidden) {
    out.auxShown = true;
    const aux = ORCA_AUX.find((a) => a.value === state.aux) || ORCA_AUX[0];
    if (aux.keywords) out.auxKeywords.push(...aux.keywords);
    const ri = mInfo?.ri || (state.methodId === OTHER && /^(ri-|dlpno|rijcosx-)/i.test(out.method));
    if (ri && aux.value !== 'autoaux' && aux.value !== 'nori') {
      const c = bEntry?.orcaC;
      out.auxKeywords.push(c || 'AutoAux');
      out.corrAux = c || 'AutoAux';
    }
  }
  // Q-Chem: ECP keyword for basis sets that need one when heavy atoms are present
  if (program === 'qchem' && bEntry?.ecp && molecule?.atoms?.some((a) => (a.z ?? a.atomicNumber ?? 0) > 36)) {
    out.qchemRem = [bEntry.ecp === 'def2' ? 'ECP def2-ECP' : 'ECP fit-LANL2DZ'];
  }
  return out;
}

/** Splits the "Extra keywords" field into CalcSpecJSON.extraKeywords: Q-Chem $rem lines are separated by ";" or newlines. */
export function splitExtraKeywords(program, text) {
  const t = String(text || '');
  if (program === 'qchem') return t.split(/[;\n]/).map((s) => s.trim().replace(/\s*=\s*/, ' ')).filter(Boolean);
  return t.split(/\s+/).filter(Boolean);
}
