// Dialogs: name lookup, calculation setup, xtb settings, image export, job log, about, shortcuts.
import { h, clear, modal, field, select, segmented, toast } from './dom.js';
import { request, api } from './api.js';
import { drawThumbnail } from './sidebar.js';
import { escapeHTML } from './app.js';

// ---------- Structure lookup (PubChem, RCSB PDB, ChEMBL, DrugBank via PubChem, NCI CACTUS; engine lookup.*) ----------
const LOOKUP_SOURCES = [
  { id: 'auto', name: 'Auto', placeholder: 'Name, CAS, SMILES, CID, PDB ID, CHEMBL or DrugBank ID (e.g. caffeine, 50-78-2, 1CRN, CHEMBL25, DB00945)' },
  { id: 'pubchem', name: 'PubChem', placeholder: 'Name, CAS number, SMILES or CID (e.g. caffeine, 50-78-2, c1ccccc1, 2244)' },
  { id: 'pdb', name: 'RCSB PDB', placeholder: 'PDB ID or text (e.g. 1CRN, 4HHB, hemoglobin, lysozyme)' },
  { id: 'chembl', name: 'ChEMBL', placeholder: 'ChEMBL ID or name (e.g. CHEMBL25, imatinib)' },
  { id: 'drugbank', name: 'DrugBank', placeholder: 'DrugBank ID or drug name (e.g. DB00945, ibuprofen), resolved through PubChem' },
  { id: 'cactus', name: 'NCI CACTUS', placeholder: 'Name, CAS number or SMILES (NCI Chemical Identifier Resolver)' },
  { id: 'scifinder', name: 'SciFinder', placeholder: 'SciFinder needs an institutional CAS subscription' },
];
const SOURCE_FOOTER = {
  auto: 'Auto picks the database from the query: PDB IDs go to RCSB, CHEMBL… to ChEMBL, DB… to DrugBank (via PubChem); names search PubChem and the PDB.',
  pubchem: 'Structures come from PubChem (3D conformers).',
  pdb: 'Entries come from the RCSB Protein Data Bank and open as PDB / mmCIF documents.',
  chembl: 'Records come from ChEMBL (EMBL-EBI); 3D coordinates from PubChem by InChIKey, or embedded from the ChEMBL molfile.',
  drugbank: 'DrugBank has no free API: DrugBank IDs are resolved through PubChem cross-references, and the structure comes from PubChem.',
  cactus: 'NCI CACTUS resolves names, CAS numbers and SMILES; it is slower than PubChem and sometimes unavailable.',
  scifinder: 'SciFinder (CAS) has no public API.',
};

export function openLookup(app) {
  let source = LOOKUP_SOURCES.some((s) => s.id === app.settings.lookupSource) ? app.settings.lookupSource : 'auto';
  if (source === 'scifinder') source = 'auto';
  const input = h('input', { type: 'search', autofocus: true, style: { width: '100%' } });
  const results = h('div.lookup-results');
  const status = h('div.lookup-status');
  const note = h('div.lookup-note');
  const footerText = h('span.grow.lookup-foot');
  let candidates = []; let chosen = 0; let token = null; let seq = 0; let timer;
  const btnOpen = h('button.btn.primary', { disabled: true, onclick: () => use('open') }, 'Open as new document');
  const btnInsert = h('button.btn', { disabled: true, onclick: () => use('insert') }, 'Insert into current');
  const btnSketch = h('button.btn', { disabled: true, onclick: () => use('replace') }, 'Replace current');
  const sourceSel = segmented(LOOKUP_SOURCES.map((s) => ({ value: s.id, label: s.name, title: s.id === 'scifinder' ? 'No public API (needs a CAS subscription)' : s.placeholder })), source, (v) => setSource(v), 'lookup-sources');
  const m = modal('Look Up Structure', h('div', {}, sourceSel, input, note, status, results), {
    width: 720,
    footer: [footerText, btnSketch, btnInsert, btnOpen],
    onClose: () => { if (token != null) api.cancel(token); },
  });

  function setSource(v) {
    source = v;
    if (v !== 'scifinder') { app.settings.lookupSource = v; app.saveSettingsSoon(); }
    const s = LOOKUP_SOURCES.find((x) => x.id === v);
    input.placeholder = s.placeholder;
    footerText.textContent = SOURCE_FOOTER[v] || '';
    clear(note);
    if (v === 'scifinder') {
      note.append(h('b', {}, 'SciFinder is not available here. '),
        'CAS SciFinder has no public API: it needs an institutional CAS subscription and is used through the SciFinder website. ',
        'CAS registry numbers (e.g. 50-78-2) still work: Auto and PubChem resolve them through PubChem. ',
        h('a', { href: 'https://scifinder-n.cas.org/', target: '_blank' }, 'Open SciFinder-n'));
      note.style.display = '';
      if (token != null) api.cancel(token);
      seq++;
      candidates = []; render(); status.textContent = '';
      input.disabled = true;
      return;
    }
    input.disabled = false;
    note.style.display = 'none';
    input.focus();
    if (input.value.trim()) search();
  }

  const sourceBadge = (c) => h('span.src-badge.src-' + c.source, { title: c.sourceNote || c.sourceName }, c.source === 'drugbank' ? 'DrugBank · via PubChem' : c.sourceName);
  const render = () => {
    clear(results);
    candidates.forEach((c, i) => {
      const mime = c.thumbnailMIME || 'image/png';
      const thumb = c.thumbnailB64 ? h('img', { src: `data:${mime};base64,${c.thumbnailB64}`, alt: '' }) : h('div.thumb', {}, c.isMacromolecule ? 'no image' : '');
      const ids = c.source === 'pubchem' || c.source === 'drugbank'
        ? [c.formula, c.molecularWeight ? `${Number(c.molecularWeight).toFixed(2)} g/mol` : null, c.cid ? `CID ${c.cid}` : null, c.casNumber ? `CAS ${c.casNumber}` : null, c.drugBankID && c.source !== 'drugbank' ? c.drugBankID : null]
        : c.source === 'pdb' ? [`PDB ${c.identifier}`]
          : [c.formula, c.molecularWeight ? `${Number(c.molecularWeight).toFixed(2)} g/mol` : null];
      const link = c.webURL ? h('a.weblink', { href: c.webURL, target: '_blank', title: c.webURL, onclick: (e) => e.stopPropagation() }, 'web page ↗') : null;
      results.append(h('div.cand' + (i === chosen ? '.on' : ''), { onclick: () => { chosen = i; render(); }, ondblclick: () => { chosen = i; use('open'); } }, thumb,
        h('div.meta', {},
          h('div.cand-head', {}, h('b', { title: c.title }, c.title || c.iupacName || c.identifier), sourceBadge(c), link),
          h('div', {}, ids.filter(Boolean).join(' · ')),
          ...(c.details || []).map((d) => h('div.syn', { title: d }, d)),
          c.iupacName && c.source !== 'pdb' ? h('div.syn', { title: c.iupacName }, c.iupacName) : null,
          c.canonicalSMILES ? h('div.syn', { title: c.canonicalSMILES, style: { fontFamily: 'var(--mono)' } }, c.canonicalSMILES) : null,
          (c.synonyms || []).length ? h('div.syn', { title: c.synonyms.join(', ') }, c.synonyms.slice(0, 6).join(', ')) : null)));
    });
    const c = candidates[chosen];
    for (const b of [btnOpen, btnInsert, btnSketch]) b.disabled = !c;
    btnInsert.title = c && c.isMacromolecule ? 'Adds every atom of the entry to the current document (without residue information)' : '';
  };
  const search = async () => {
    const q = input.value.trim();
    if (!q || source === 'scifinder') { candidates = []; render(); status.textContent = ''; return; }
    if (token != null) api.cancel(token);
    const my = ++seq;
    status.innerHTML = '<span class="spinner" style="display:inline-block;vertical-align:middle;margin-right:6px"></span>Searching ' + escapeHTML(LOOKUP_SOURCES.find((s) => s.id === source).name) + '…';
    try {
      const r = await request('lookup.suggest', { query: q, limit: 8, source }, { cancellable: true, onToken: (t) => { token = t; } });
      if (my !== seq) return;
      candidates = r.candidates || []; chosen = 0;
      const n = candidates.length;
      const kinds = [...new Set(candidates.map((c) => c.sourceName))];
      let s = r.error ? (r.errorCode === 'offline' ? 'You appear to be offline.' : r.errorCode === 'timeout' ? 'The database did not answer in time. Try again, or pick another source.' : r.error)
        : n ? `${n} match${n > 1 ? 'es' : ''}${source === 'auto' && kinds.length ? ' · ' + kinds.join(', ') : ''}` : 'No matches';
      if (r.notice) s += ' · ' + r.notice;
      status.textContent = s;
      render();
    } catch (e) { if (my === seq && e.code !== 'cancelled') status.textContent = e.code === 'offline' ? 'You appear to be offline.' : e.message; }
  };
  input.addEventListener('input', () => { clearTimeout(timer); timer = setTimeout(search, 450); });
  input.addEventListener('keydown', (e) => {
    if (e.key === 'Enter') { clearTimeout(timer); if (candidates.length) use('open'); else search(); }
    if (e.key === 'ArrowDown' && candidates.length) { e.preventDefault(); chosen = Math.min(candidates.length - 1, chosen + 1); render(); }
    if (e.key === 'ArrowUp' && candidates.length) { e.preventDefault(); chosen = Math.max(0, chosen - 1); render(); }
  });
  setSource(source);
  // For the smoke test: drive the dialog without synthesising key events.
  m.lookup = { setSource: (v) => { sourceSel.setValue(v); setSource(v); }, search: (q) => { input.value = q; return search(); }, use: (how, i = 0) => { chosen = i; return use(how); } };
  app.lookupDialog = m;

  async function use(how) {
    const c = candidates[chosen]; if (!c) return;
    for (const b of [btnOpen, btnInsert, btnSketch]) b.disabled = true;
    try {
      if (c.isMacromolecule && c.source === 'pdb' && how === 'open') {
        // Download the entry (.pdb, or .cif for large structures) and open it as a file: cartoon, chains, assemblies.
        status.textContent = `Downloading ${c.identifier} from the RCSB PDB…`;
        const f = await request('lookup.download', { id: c.id });
        m.close();
        await app.openPath(f.path);
        return;
      }
      status.textContent = c.source === 'pdb' ? `Downloading ${c.identifier}…` : 'Downloading the 3D structure…';
      const mol = await request('lookup.structure', { id: c.id, title: c.title });
      if (!mol.title) mol.title = c.title || '';
      m.close();
      if (how === 'open') {
        await app.newDocument();
        await app.edit({ type: 'replaceMolecule', molecule: mol });
        app.active.name = c.title || c.identifier; app.emit('docs', app.docs, app.active);
        app.viewport.fit();
      } else if (how === 'replace') {
        await app.edit({ type: 'replaceMolecule', molecule: mol }); app.viewport.fit();
      } else {
        const cur = app.active.molecule;
        const off = cur.atoms.length;
        // place next to the current structure
        let maxX = -Infinity; for (const a of cur.atoms) maxX = Math.max(maxX, a.pos[0]);
        let minX = Infinity; for (const a of mol.atoms) minX = Math.min(minX, a.pos[0]);
        const dx = cur.atoms.length ? maxX - minX + 3 : 0;
        const merged = { ...cur, atoms: [...cur.atoms, ...mol.atoms.map((a) => ({ ...a, pos: [a.pos[0] + dx, a.pos[1], a.pos[2]] }))], bonds: [...cur.bonds, ...mol.bonds.map((b) => ({ ...b, a: b.a + off, b: b.b + off }))] };
        await app.edit({ type: 'replaceMolecule', molecule: merged }); app.viewport.fit();
      }
    } catch (e) {
      status.textContent = e.code === 'offline' ? 'You appear to be offline.' : e.message;
      render();
    }
  }
}

/** Smoke test (VIBEVIEW_SMOKE_LOOKUP="source|query|how", how = show|open|insert|replace; several joined by ";;"). */
export async function smokeLookup(app, spec, log) {
  let ok = true;
  for (const one of spec.split(';;')) {
    const [source, query, how = 'show'] = one.split('|');
    openLookup(app);
    const dlg = app.lookupDialog;
    dlg.lookup.setSource(source);
    await dlg.lookup.search(query);
    const items = [...document.querySelectorAll('.lookup-results .cand')];
    const status = document.querySelector('.lookup-status')?.textContent || '';
    log(`lookup ${source} "${query}": ${items.length} candidates; ${status}; first: ${items[0]?.querySelector('b')?.textContent || '-'}; thumbs ${document.querySelectorAll('.lookup-results img').length}`);
    if (source === 'scifinder') { ok = ok && !!document.querySelector('.lookup-note')?.textContent.includes('CAS'); if (how !== 'show') dlg.close(); continue; }
    if (!items.length) { ok = false; dlg.close(); continue; }
    if (how === 'show') continue;   // leave the dialog open for the screenshot
    const before = app.docs.length;
    await dlg.lookup.use(how, 0);
    const d = app.active;
    log(`  ${how}: docs ${before} -> ${app.docs.length}, active "${d?.name}" ${d?.molecule.atoms.length} atoms, format ${d?.summary.format}`);
    ok = ok && !!d && d.molecule.atoms.length > 0;
  }
  return { ok };
}

// ---------- Calculation setup ----------
// The dialog and its method/basis catalog live in calc-setup.js and calc-catalog.js.
export { openCalcSetup } from './calc-setup.js';

// ---------- xtb ----------
const XTB_SOLVENTS = {
  alpb: ['acetone', 'acetonitrile', 'aniline', 'benzaldehyde', 'benzene', 'ch2cl2', 'chcl3', 'cs2', 'dioxane', 'dmf', 'dmso', 'ether', 'ethylacetate', 'furane', 'hexadecane', 'hexane', 'methanol', 'nitromethane', 'octanol', 'woctanol', 'phenol', 'toluene', 'thf', 'water'],
  gbsa: ['acetone', 'acetonitrile', 'benzene', 'ch2cl2', 'chcl3', 'cs2', 'dmf', 'dmso', 'ether', 'water', 'methanol', 'n-hexane', 'thf', 'toluene'],
};

export function defaultXTBSettings(app) {
  return { method: 'gfn2', task: 'optimize', optLevel: 'normal', maxCycles: null, solvationModel: 'none', solvent: null, charge: null, uhf: null, electronicTemperature: null, accuracy: null, threads: 4, extraArguments: [], timeout: null, ...(app.settings.xtb || {}) };
}

export async function runXTB(app, settings) {
  const d = app.active;
  if (!d || !d.molecule.atoms.length) { toast('Build or open a molecule first.', { kind: 'warn' }); return; }
  const label = settings.task === 'optimize' ? 'xtb optimization' : settings.task === 'hessian' ? 'xtb optimization + Hessian' : 'xtb single point';
  app.setBusy('Starting xtb…');
  try {
    const r = await request('xtb.run', { docId: d.docId, settings });
    app.jobStarted(r.jobId, { title: `${label} · ${d.name}`, directory: r.directory, docId: d.docId }, `${label}…`);
  } catch (e) {
    app.setBusy(null);
    if (e.code === 'not_installed') toast('xtb was not found. Install it (for example: conda install -c conda-forge xtb) and make sure xtb.exe is on PATH.', { kind: 'error', timeout: 0 });
    else app.error('xtb failed to start', e);
  }
}

export function openXTBSettings(app) {
  const s = defaultXTBSettings(app);
  const method = segmented([{ value: 'gfn2', label: 'GFN2-xTB' }, { value: 'gfn1', label: 'GFN1-xTB' }, { value: 'gfn0', label: 'GFN0-xTB' }, { value: 'gfnff', label: 'GFN-FF' }], s.method, (v) => { s.method = v; upd(); });
  const task = segmented([{ value: 'singlePoint', label: 'Single point' }, { value: 'optimize', label: 'Optimize' }, { value: 'hessian', label: 'Optimize + Hessian' }], s.task, (v) => { s.task = v; upd(); });
  const opt = select(['crude', 'sloppy', 'loose', 'normal', 'tight', 'vtight', 'extreme'].map((v) => ({ value: v, label: v === 'vtight' ? 'Very tight' : v[0].toUpperCase() + v.slice(1) })), s.optLevel, (v) => { s.optLevel = v; upd(); });
  const cycles = h('input', { type: 'number', min: 1, placeholder: 'default', value: s.maxCycles ?? '', oninput: () => { s.maxCycles = cycles.value ? Number(cycles.value) : null; upd(); } });
  const solvent = h('select', { onchange: () => { s.solvent = solvent.value || null; upd(); } });
  const fillSolvents = () => { clear(solvent); for (const x of XTB_SOLVENTS[s.solvationModel] || []) solvent.append(h('option', { value: x, selected: x === s.solvent }, x)); solvent.disabled = s.solvationModel === 'none'; if (s.solvationModel !== 'none' && !s.solvent) s.solvent = solvent.value; };
  const model = select([{ value: 'none', label: 'None (gas phase)' }, { value: 'alpb', label: 'ALPB' }, { value: 'gbsa', label: 'GBSA' }], s.solvationModel, (v) => { s.solvationModel = v; s.solvent = null; fillSolvents(); upd(); });
  const m = app.active?.molecule;
  const charge = h('input', { type: 'number', step: 1, placeholder: String(m?.charge ?? 0), value: s.charge ?? '', oninput: () => { s.charge = charge.value === '' ? null : Number(charge.value); upd(); } });
  const uhf = h('input', { type: 'number', min: 0, step: 1, placeholder: String((m?.multiplicity ?? 1) - 1), value: s.uhf ?? '', oninput: () => { s.uhf = uhf.value === '' ? null : Number(uhf.value); upd(); } });
  const etemp = h('input', { type: 'number', min: 1, placeholder: '300', value: s.electronicTemperature ?? '', oninput: () => { s.electronicTemperature = etemp.value ? Number(etemp.value) : null; upd(); } });
  const acc = h('input', { type: 'number', min: 0.0001, step: 0.1, placeholder: '1.0', value: s.accuracy ?? '', oninput: () => { s.accuracy = acc.value ? Number(acc.value) : null; upd(); } });
  const threads = h('input', { type: 'number', min: 1, max: 256, value: s.threads, oninput: () => { s.threads = Number(threads.value) || 1; upd(); } });
  const extra = h('input', { type: 'text', value: s.extraArguments.join(' '), placeholder: 'e.g. --vparam file', oninput: () => { s.extraArguments = extra.value.split(/\s+/).filter(Boolean); upd(); } });
  const previewEl = h('pre.preview');
  const errs = h('div.errors');
  fillSolvents();
  function upd() {
    const a = ['xtb', 'input.xyz'];
    if (s.method === 'gfnff') a.push('--gfnff'); else a.push('--gfn', s.method.slice(3));
    if (s.task === 'optimize') a.push('--opt', s.optLevel); if (s.task === 'hessian') a.push('--ohess', s.optLevel);
    if (s.maxCycles && s.task !== 'singlePoint') a.push('--cycles', String(s.maxCycles));
    if (s.solvationModel !== 'none' && s.solvent) a.push('--' + s.solvationModel, s.solvent);
    a.push('--chrg', String(s.charge ?? m?.charge ?? 0), '--uhf', String(s.uhf ?? ((m?.multiplicity ?? 1) - 1)));
    if (s.electronicTemperature) a.push('--etemp', String(s.electronicTemperature));
    if (s.accuracy) a.push('--acc', String(s.accuracy));
    a.push('-P', String(s.threads), ...s.extraArguments);
    previewEl.textContent = a.join(' ');
    const e = [];
    if (s.threads < 1 || s.threads > 256) e.push('Threads must be between 1 and 256.');
    if (s.uhf != null && s.uhf < 0) e.push('Unpaired electrons cannot be negative.');
    errs.textContent = e.join(' '); runBtn.disabled = e.length > 0;
  }
  const runBtn = h('button.btn.primary', { onclick: () => { app.settings.xtb = { ...s }; app.saveSettingsSoon(); dlg.close(); runXTB(app, s); } }, 'Run xtb');
  const found = app.engineInfo?.programs?.xtb;
  const dlg = modal('xtb Settings', h('div', {},
    field('Method', method), field('Task', task),
    h('div.grid2', {}, field('Optimization level', opt), field('Max cycles', cycles), field('Solvation', model), field('Solvent', solvent),
      field('Charge', charge, 'Empty: from the molecule'), field('Unpaired electrons (uhf)', uhf, 'Empty: multiplicity − 1'),
      field('Electronic temperature (K)', etemp), field('Accuracy', acc), field('Threads', threads), field('Extra arguments', extra)),
    h('div', { style: { fontWeight: 600, fontSize: '12px', marginTop: '6px' } }, 'Command'), previewEl, errs,
    h('div', { style: { fontSize: '12px', color: found ? 'var(--text-2)' : 'var(--err)', marginTop: '6px' } }, found ? `xtb: ${found}` : 'xtb was not found on this computer. Install it and make sure xtb.exe is on PATH.'),
  ), { width: 600, footer: [h('button.btn', { onclick: () => dlg.close() }, 'Cancel'), runBtn] });
  upd();
}

// ---------- Export image ----------
export function openExportImage(app) {
  const vp = app.viewport;
  const s = app.settings.export || { scale: 2, width: Math.round(vp.width * 2), height: Math.round(vp.height * 2), transparent: false };
  const w = h('input', { type: 'number', min: 64, max: 8192, value: s.width, style: { width: '90px' } });
  const hh = h('input', { type: 'number', min: 64, max: 8192, value: s.height, style: { width: '90px' } });
  const keep = h('input', { type: 'checkbox', checked: true });
  const transparent = h('input', { type: 'checkbox', checked: !!s.transparent });
  const aspect = vp.width / vp.height;
  w.addEventListener('input', () => { if (keep.checked) hh.value = Math.round(Number(w.value) / aspect); });
  hh.addEventListener('input', () => { if (keep.checked) w.value = Math.round(Number(hh.value) * aspect); });
  const presets = h('div.btn-row', {}, [1, 2, 3, 4].map((k) => h('button.btn.small', { onclick: () => { w.value = Math.round(vp.width * k); hh.value = Math.round(vp.height * k); } }, `${k}×`)),
    h('button.btn.small', { onclick: () => { w.value = 1920; hh.value = keep.checked ? Math.round(1920 / aspect) : 1080; } }, '1920 wide'),
    h('button.btn.small', { onclick: () => { w.value = 3000; hh.value = keep.checked ? Math.round(3000 / aspect) : 2000; } }, '3000 wide (print)'));
  const go = async () => {
    const W = Math.max(64, Math.min(8192, Number(w.value) || 1600)), H = Math.max(64, Math.min(8192, Number(hh.value) || 1200));
    app.settings.export = { width: W, height: H, transparent: transparent.checked }; app.saveSettingsSoon();
    const name = (app.active?.name || 'molecule').replace(/\.[^.]+$/, '');
    const p = await api.saveFileDialog({ title: 'Export Image', defaultPath: `${name}.png`, filters: [{ name: 'PNG image', extensions: ['png'] }] });
    if (!p) return;
    dlg.close();
    const url = vp.exportPNG(W, H, { transparent: transparent.checked });
    await api.writeFileBase64(p, url.split(',')[1]);
    toast(`Saved ${p.split(/[\\/]/).pop()} (${W}×${H})`, { kind: 'ok', action: { label: 'Show in Explorer', run: () => api.revealInExplorer(p) } });
  };
  const dlg = modal('Export Image', h('div', {},
    h('div.row', {}, h('label', {}, 'Width'), w, h('label', {}, 'Height'), hh, h('span', {}, 'px')),
    h('label.check', {}, keep, 'Keep the window\'s aspect ratio'), h('label.check', {}, transparent, 'Transparent background'),
    h('div', { style: { margin: '8px 0 4px', fontSize: '12px', color: 'var(--text-2)' } }, 'Presets'), presets,
  ), { width: 470, footer: [h('button.btn', { onclick: () => dlg.close() }, 'Cancel'), h('button.btn.primary', { onclick: go }, 'Export…')] });
}

// ---------- Job log ----------
export function openJobLog(app, focusJob) {
  const list = h('div.joblist');
  const pre = h('pre');
  const searchIn = h('input', { type: 'search', placeholder: 'Find in log', style: { width: '180px' } });
  const follow = h('input', { type: 'checkbox', checked: true });
  const streamSel = select([{ value: 'all', label: 'All output' }, { value: 'stdout', label: 'stdout' }, { value: 'stderr', label: 'stderr' }, { value: 'file', label: 'Output file' }], 'all', () => renderLog());
  const info = h('span', { style: { fontSize: '12px', color: 'var(--text-2)' } });
  let current = focusJob || [...app.jobs.keys()].pop() || null;
  const reveal = h('button.btn.small', { onclick: () => { const j = app.jobs.get(current); if (j?.directory) api.openPath(j.directory); } }, 'Open folder');
  const cancel = h('button.btn.small', { onclick: async () => { try { await request('calc.cancel', { jobId: current }); } catch (e) { app.error('Cancel failed', e); } } }, 'Stop job');
  const renderList = () => {
    clear(list);
    if (!app.jobs.size) list.append(h('div.empty', {}, 'No jobs yet'));
    for (const j of [...app.jobs.values()].reverse()) {
      list.append(h('button' + (j.jobId === current ? '.on' : ''), { onclick: () => { current = j.jobId; renderList(); renderLog(); } },
        h('div', { style: { fontWeight: 600, fontSize: '12px', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' } }, j.title),
        h('span.badge' + (j.done ? (j.ok ? '.ok' : '.err') : ''), {}, j.done ? (j.ok ? 'done' : 'failed') : 'running')));
    }
  };
  const renderLog = () => {
    const j = app.jobs.get(current);
    if (!j) { pre.textContent = ''; info.textContent = ''; return; }
    const q = searchIn.value.trim().toLowerCase();
    const want = streamSel.value;
    const lines = j.lines.filter((l) => want === 'all' || l.stream === want);
    let html = '';
    let hits = 0;
    for (const l of lines.slice(-8000)) {
      let t = escapeHTML(l.line);
      if (q && l.line.toLowerCase().includes(q)) { hits++; t = t.replace(new RegExp(q.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'gi'), (x) => `<mark>${x}</mark>`); }
      html += l.stream === 'stderr' ? `<span class="stderr">${t}</span>\n` : `${t}\n`;
    }
    pre.innerHTML = html;
    info.textContent = `${j.directory || ''}${q ? ` · ${hits} matching lines` : ''}${j.done ? ` · exit ${j.exitCode}` : ''}`;
    cancel.disabled = j.done;
    if (follow.checked && !q) pre.scrollTop = pre.scrollHeight;
    else if (q) pre.querySelector('mark')?.scrollIntoView({ block: 'center' });
  };
  searchIn.addEventListener('input', renderLog);
  const offLog = app.on('job-log', (j) => { if (j.jobId === current) { clearTimeout(offLog.t); offLog.t = setTimeout(renderLog, 60); } });
  const offJob = app.on('job', () => { renderList(); renderLog(); });
  const offJobs = app.on('jobs', () => { renderList(); });
  modal('Job Log', h('div.joblog', {}, list, h('div.jobview', {}, h('div.tools', {}, searchIn, streamSel, h('label.check', {}, follow, 'Follow'), h('span', { style: { flex: 1 } }), reveal, cancel), pre, h('div', { style: { padding: '4px 10px', borderTop: '1px solid var(--border)' } }, info))),
    { width: 980, onClose: () => { offLog(); offJob(); offJobs(); } });
  renderList(); renderLog();
}

// ---------- Program locations (calc.setProgramPath) ----------
/**
 * Sends the saved formchk location (calc.setProgramPath {program: "formchk"}); App.sendProgramPaths covers the four
 * QC programs only. Called after the Program Locations dialog and whenever engine info arrives (startup, restart).
 */
let formchkSent = null;
export async function sendFormchkPath(app, { force = false } = {}) {
  const saved = app.settings.programPaths?.formchk?.trim() || null;
  if (!force && (saved === formchkSent || (!saved && formchkSent === null))) return;
  formchkSent = saved;
  try {
    const programs = await request('calc.setProgramPath', { program: 'formchk', path: saved });
    if (programs && app.engineInfo) app.engineInfo.programs = { ...(app.engineInfo.programs || {}), ...programs };
  } catch (e) { if (saved) toast(`formchk path not used: ${e.message}`, { kind: 'warn' }); }
}
export function openProgramPaths(app) {
  const progs = [['xtb', 'xtb'], ['orca', 'ORCA'], ['gaussian', 'Gaussian (g16.exe)'], ['formchk', 'formchk (Gaussian .chk → .fchk)'], ['qchem', 'Q-Chem']];
  const saved = { ...(app.settings.programPaths || {}) };
  const found = h('pre.preview');
  const showFound = () => { const p = app.engineInfo?.programs || {}; found.textContent = progs.map(([k, n]) => `${n}: ${p[k] || 'not found'}`).join('\n'); };
  const inputs = {};
  const rows = progs.map(([k, n]) => {
    const inp = h('input', { type: 'text', value: saved[k] || '', placeholder: 'Automatic (PATH, conda, usual install folders)', style: { flex: 1 } });
    inputs[k] = inp;
    const browse = h('button.btn.small', { onclick: async () => {
      const r = await api.openFileDialog({ title: `Locate ${n}`, filters: [{ name: 'Programs', extensions: ['exe', 'bat', 'cmd'] }, { name: 'All files', extensions: ['*'] }] });
      if (r && r[0]) inp.value = r[0];
    } }, 'Browse…');
    return field(n, h('div.row', {}, inp, browse));
  });
  const ok = async () => {
    const next = {};
    for (const [k] of progs) { const v = inputs[k].value.trim(); if (v) next[k] = v; }
    app.settings.programPaths = next; app.saveSettingsSoon();
    await app.sendProgramPaths();
    await sendFormchkPath(app, { force: true });
    showFound();
    toast('Program locations updated', { kind: 'ok' });
    dlg.close();
  };
  const dlg = modal('Program Locations', h('div', {}, ...rows,
    h('div', { style: { fontWeight: 600, fontSize: '12px', margin: '8px 0 4px' } }, 'Currently used by the engine'), found),
  { width: 620, footer: [h('button.btn', { onclick: () => dlg.close() }, 'Cancel'), h('button.btn.primary', { onclick: ok }, 'Save')] });
  showFound();
}

// ---------- Charge / multiplicity ----------
export function openChargeDialog(app) {
  const m = app.active?.molecule; if (!m) return;
  const c = h('input', { type: 'number', step: 1, value: m.charge, autofocus: true });
  const mu = h('input', { type: 'number', step: 1, min: 1, value: m.multiplicity });
  const ok = () => { dlg.close(); app.edit({ type: 'setCharge', charge: Number(c.value) || 0, multiplicity: Math.max(1, Number(mu.value) || 1) }, { keepSelection: true }); };
  const dlg = modal('Charge and Multiplicity', h('div.grid2', {}, field('Charge', c), field('Multiplicity', mu)), { width: 360, footer: [h('button.btn', { onclick: () => dlg.close() }, 'Cancel'), h('button.btn.primary', { onclick: ok }, 'OK')] });
}

// ---------- About / shortcuts ----------
export async function openAbout(app) {
  const info = await api.appInfo();
  const e = app.engineInfo;
  const c = h('canvas', { width: 160, height: 120, style: { width: '80px', height: '60px' } });
  drawThumbnail(c, { atoms: [{ z: 8, pos: [0, 0, 0] }, { z: 1, pos: [0.76, 0.59, 0] }, { z: 1, pos: [-0.76, 0.59, 0] }], bonds: [{ a: 0, b: 1, order: 1 }, { a: 0, b: 2, order: 1 }] });
  const progs = e?.programs ? Object.entries(e.programs).map(([k, v]) => `${k}: ${v || 'not found'}`).join('\n') : '';
  modal('About VibeView', h('div', { style: { display: 'flex', gap: '14px' } }, c,
    h('div.selectable', {}, h('div', { style: { fontSize: '16px', fontWeight: 600 } }, 'VibeView'),
      h('div', {}, `Version ${info.version} for Windows`),
      h('div', {}, e ? `Engine ${e.version} · protocol ${e.protocol} · ${e.platform}` : 'Engine not connected'),
      h('pre.preview', {}, progs || '–'),
      h('div', { style: { fontSize: '12px', color: 'var(--text-2)', marginTop: '6px' } }, 'An independent molecular builder and viewer for computational chemistry. MIT License.'))), { width: 520 });
}

export function openShortcuts() {
  const rows = [
    ['Ctrl+N / Ctrl+O / Ctrl+S', 'New, open, save'], ['Ctrl+Shift+S', 'Save as'], ['Ctrl+E', 'Export image'], ['Ctrl+W', 'Close document'],
    ['Ctrl+Z / Ctrl+Y', 'Undo, redo'], ['Delete', 'Delete selected atoms'], ['Ctrl+A / Ctrl+Shift+A / Ctrl+I', 'Select all, none, invert'],
    ['Ctrl+1 … Ctrl+5', 'Select, Place, Link, Gauge, Delete tools'], ['C, N, O, Cl…', 'Type a symbol to pick an element (Place tool)'],
    ['1 / 2 / 3', 'Bond order (Link tool)'], ['Alt+1 … Alt+4', 'Ball and stick, tube, wireframe, space filling'],
    ['Ctrl+0 or F', 'Fit to window'], ['Ctrl+Shift+O', 'Orthographic projection'], ['Arrow keys', 'Rotate the view'],
    ['Left drag', 'Rotate (Alt: roll)'], ['Right or middle drag', 'Pan (Ctrl+right drag: zoom)'], ['Wheel', 'Zoom'],
    ['Shift-drag on empty space', 'Box select (Select tool)'], ['Drag selected atoms', 'Move them (Alt: rotate)'], ['Double-click', 'Select fragment / fit'],
    ['Ctrl+K', 'Command palette'], ['Ctrl+Shift+C', 'Console'], ['Ctrl+L', 'Look up a structure by name'], ['Ctrl+T', 'Periodic table'],
    ['Ctrl+Shift+H', 'Add hydrogens'], ['Ctrl+Shift+K', 'Clean up geometry'], ['Ctrl+Shift+X', 'Optimize with xtb'], ['Ctrl+Alt+C', 'Calculation setup'], ['Ctrl+Alt+J', 'Job log'],
  ];
  modal('Keyboard Shortcuts', h('table.shortcuts', {}, rows.map(([k, v]) => h('tr', {}, h('td', {}, h('kbd', {}, k)), h('td', {}, v)))), { width: 600 });
}
