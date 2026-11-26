import { ELEMENT_ROWS } from './elements-data.js';

/** Element table (Jmol colours, covalent and van der Waals radii), indexed by atomic number. */
export const ELEMENTS = ELEMENT_ROWS.map(([z, symbol, name, mass, covalent, vdw, color, valences]) => ({
  z, symbol, name, mass, covalent: covalent > 0 ? covalent : 0.75, vdw: vdw > 0 ? vdw : 1.5, color, valences,
}));
const BY_SYMBOL = new Map(ELEMENTS.map((e) => [e.symbol.toLowerCase(), e]));

export function element(z) { return ELEMENTS[z] || ELEMENTS[0]; }
export function elementBySymbol(s) { return BY_SYMBOL.get(String(s).toLowerCase()) || null; }
export function colorHex(z) { return element(z).color; }
export function cssColor(z) { return '#' + element(z).color.toString(16).padStart(6, '0'); }
/** Readable text colour on top of the element colour. */
export function textOn(z) {
  const c = element(z).color; const r = (c >> 16) & 255, g = (c >> 8) & 255, b = c & 255;
  return (0.299 * r + 0.587 * g + 0.114 * b) > 150 ? '#1a1a1e' : '#ffffff';
}

/** Periodic-table placement [row, column] (1-based, f-block on rows 9 and 10). */
export function tablePosition(z) {
  if (z === 1) return [1, 1];
  if (z === 2) return [1, 18];
  const periods = [[3, 10, 2], [11, 18, 3], [19, 36, 4], [37, 54, 5], [55, 86, 6], [87, 118, 7]];
  for (const [a, b, row] of periods) {
    if (z < a || z > b) continue;
    const i = z - a;
    if (row <= 3) return [row, i < 2 ? i + 1 : i + 11];
    if (row <= 5) return [row, i + 1];
    // rows 6 and 7 with lanthanides / actinides split out
    if (i < 2) return [row, i + 1];
    if (i < 17) return [row + 3, i + 1]; // La..Lu / Ac..Lr → f-block row, columns 3..17
    return [row, i - 14 + 1];
  }
  return [1, 1];
}

/** Category used for tinting the periodic table. */
export function category(z) {
  const nonmetals = [1, 6, 7, 8, 15, 16, 34];
  const halogens = [9, 17, 35, 53, 85, 117];
  const noble = [2, 10, 18, 36, 54, 86, 118];
  const alkali = [3, 11, 19, 37, 55, 87];
  const alkaline = [4, 12, 20, 38, 56, 88];
  const metalloids = [5, 14, 32, 33, 51, 52];
  if (nonmetals.includes(z)) return 'nonmetal';
  if (halogens.includes(z)) return 'halogen';
  if (noble.includes(z)) return 'noble';
  if (alkali.includes(z)) return 'alkali';
  if (alkaline.includes(z)) return 'alkaline';
  if (metalloids.includes(z)) return 'metalloid';
  if ((z >= 57 && z <= 71)) return 'lanthanide';
  if ((z >= 89 && z <= 103)) return 'actinide';
  if ((z >= 21 && z <= 30) || (z >= 39 && z <= 48) || (z >= 72 && z <= 80) || (z >= 104 && z <= 112)) return 'transition';
  return 'post';
}
