// Small original line icons (24×24, currentColor).
const s = (body) => `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round">${body}</svg>`;

export const ICONS = {
  select: s('<path d="M5 3l13 8-6 1.5L9 19z"/>'),
  place: s('<circle cx="12" cy="12" r="5"/><path d="M12 2v3M12 19v3M2 12h3M19 12h3"/>'),
  link: s('<circle cx="6" cy="17" r="3"/><circle cx="18" cy="7" r="3"/><path d="M8.3 15.2l7.4-6.4"/>'),
  gauge: s('<path d="M3 17l7-10 7 10"/><path d="M6.5 12.5a5 5 0 0 1 7 0"/><circle cx="3" cy="17" r="1.3"/><circle cx="17" cy="17" r="1.3"/>'),
  delete: s('<path d="M4 7h16M9 7V4h6v3M6 7l1 13h10l1-13"/><path d="M10 11v6M14 11v6"/>'),
  hydrogens: s('<circle cx="12" cy="12" r="8"/><path d="M9 8v8M15 8v8M9 12h6"/>'),
  clean: s('<path d="M4 20l10-10"/><path d="M14 4l1 2.5L17.5 7.5 15 8.5 14 11l-1-2.5L10.5 7.5 13 6.5z"/><path d="M19 13l.6 1.4 1.4.6-1.4.6L19 17l-.6-1.4-1.4-.6 1.4-.6z"/>'),
  bolt: s('<path d="M13 2L4 14h7l-1 8 9-12h-7z"/>'),
  calc: s('<rect x="4" y="3" width="16" height="18" rx="2"/><path d="M8 7h8M8 12h2M14 12h2M8 16h2M14 16h2"/>'),
  jobs: s('<path d="M4 5h16v4H4zM4 11h16v4H4zM4 17h10"/>'),
  palette: s('<rect x="3" y="5" width="18" height="14" rx="2"/><path d="M7 10l3 2-3 2M12 15h5"/>'),
  console: s('<rect x="3" y="4" width="18" height="16" rx="2"/><path d="M7 9l3 3-3 3M12 15h5"/>'),
  lookup: s('<circle cx="10.5" cy="10.5" r="6"/><path d="M15 15l5 5"/>'),
  inspector: s('<rect x="3" y="4" width="18" height="16" rx="2"/><path d="M15 4v16"/>'),
  library: s('<rect x="3" y="4" width="18" height="16" rx="2"/><path d="M9 4v16"/>'),
  results: s('<rect x="3" y="4" width="18" height="16" rx="2"/><path d="M3 14h18M7 11l2-3 2 2 3-4"/>'),
  fit: s('<path d="M4 9V4h5M20 9V4h-5M4 15v5h5M20 15v5h-5"/><circle cx="12" cy="12" r="3"/>'),
  undo: s('<path d="M9 14L4 9l5-5"/><path d="M4 9h10a6 6 0 0 1 0 12h-3"/>'),
  redo: s('<path d="M15 14l5-5-5-5"/><path d="M20 9H10a6 6 0 0 0 0 12h3"/>'),
  open: s('<path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v1H3z"/><path d="M3 10h18l-2 9H5z"/>'),
  save: s('<path d="M5 3h11l3 3v15H5z"/><path d="M8 3v5h7V3M8 21v-7h8v7"/>'),
  play: s('<path d="M7 4l13 8-13 8z"/>'),
  pause: s('<path d="M7 4v16M17 4v16"/>'),
  stop: s('<rect x="6" y="6" width="12" height="12" rx="1"/>'),
  prev: s('<path d="M18 5l-9 7 9 7zM6 5v14"/>'),
  next: s('<path d="M6 5l9 7-9 7zM18 5v14"/>'),
  camera: s('<path d="M4 8h3l2-3h6l2 3h3v11H4z"/><circle cx="12" cy="13" r="3.5"/>'),
};

/** Style thumbnails for the inspector. */
export const STYLE_ICONS = {
  ballAndStick: '<svg viewBox="0 0 54 34"><line x1="12" y1="22" x2="42" y2="12" stroke="#999" stroke-width="4"/><circle cx="12" cy="22" r="8" fill="#ff3b3b"/><circle cx="42" cy="12" r="6" fill="#bbb"/></svg>',
  tube: '<svg viewBox="0 0 54 34"><line x1="10" y1="22" x2="27" y2="16" stroke="#ff3b3b" stroke-width="7" stroke-linecap="round"/><line x1="27" y1="16" x2="44" y2="11" stroke="#9a9a9a" stroke-width="7" stroke-linecap="round"/></svg>',
  wireframe: '<svg viewBox="0 0 54 34"><polyline points="8,24 20,12 34,22 46,10" fill="none" stroke="#888" stroke-width="2"/><line x1="8" y1="24" x2="14" y2="18" stroke="#ff3b3b" stroke-width="2"/></svg>',
  spaceFilling: '<svg viewBox="0 0 54 34"><circle cx="34" cy="16" r="11" fill="#bbb"/><circle cx="20" cy="18" r="13" fill="#ff3b3b"/></svg>',
};
