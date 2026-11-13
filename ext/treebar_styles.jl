# Global stylesheet for treebar components — include via extra_head in htmx()
htmx_treebar_styles() = h.style(Raw("""
.treebar-pills { display: flex; gap: 0.5rem; margin-bottom: 0.5rem; }
.treebar-pill {
    display: inline-block;
    padding: 0.15rem 0.6rem;
    border-radius: 1rem;
    font-size: 0.8rem;
    cursor: pointer;
    user-select: none;
    border: 1px solid transparent;
    transition: opacity 0.15s;
}
.treebar-pill-finished {
    background: color-mix(in srgb, var(--pico-ins-color, #d1fae5) 35%, transparent);
}
.treebar-pill-failed {
    background: color-mix(in srgb, var(--pico-del-color, #fee2e2) 35%, transparent);
}
.treebar-pill-pending {
    background: color-mix(in srgb, var(--pico-muted-color, #ccc) 25%, transparent);
}
.treebar-pill-skipped {
    background: color-mix(in srgb, var(--pico-muted-color, #ccc) 15%, transparent);
}
.treebar-pill-reused {
    background: color-mix(in srgb, var(--pico-ins-color, #d1fae5) 15%, transparent);
}
.treebar-pending { opacity: 0.55; }
.treebar-pending .treebar-progress { opacity: 0.5; }
/* Dimmer than pending and struck through: the phase is terminal, and the
   strike is what separates "never ran" from "not yet" at a glance. */
.treebar-skipped { opacity: 0.45; }
.treebar-skipped .treebar-description { text-decoration: line-through; }
/* A success whose output already existed: dimmed like history, but never
   struck through — unlike skipped, its result is available. */
.treebar-reused { opacity: 0.7; }
.treebar-pill:hover { opacity: 0.8; }
.treebar-header { display: flex; gap: 0.5ch; align-items: baseline; flex-wrap: wrap; }
.treebar-duration { font-size: 0.85em; color: var(--pico-muted-color, #888); }
.treebar-interrupt { font-size: 0.85em; font-style: italic; color: var(--pico-muted-color, #888); }
.treebar-elided { font-size: 0.85em; font-style: italic; color: var(--pico-muted-color, #888); }
.treebar-stop { padding: 0.1rem 0.4rem; font-size: 0.7em; float: right; }
.treebar-node { margin-bottom: 0.25rem; }

/* Polling badge chrome. Each live `.treebar-poller` carries one
   `.treebar-badge`: a hairline strip plus a panel (pause/play control,
   poll label, status word, progress bar, elapsed) above the live tree.
   The panel and tree render EXPANDED by default, so a first-load region —
   nothing on screen yet — shows progress immediately instead of a bare
   hairline (snag first-load-polle-9728d9da). Quiet chrome (hairline that
   expands on hover/focus) is opt-in per poller via `data-chrome="quiet"`
   (the `chrome=:quiet` kwarg), or automatic for a poller diverted into
   HTMXObjects' live-refresh reporter (`.htmxo-live-reporter`), where
   settled content is already on screen and the poller is background
   progress. Visual constraints (binding): no gradient accents, no glowing
   shadows, no emoji icons (the pause/play glyphs are text), no lift/scale
   hover effects, and the polling pulse is gated on
   `prefers-reduced-motion`. */
.treebar-poller { position: relative; }
.treebar-terminal { position: static; }
.treebar-badge { display: block; padding: 0.3rem 0 0.15rem; }
.treebar-badge-strip {
    display: block; height: 2px; border-radius: 1px;
    background: var(--pico-muted-color, #888);
    opacity: 0.55;
}
/* The pulse says "polling" without moving anything: the strip never changes
   size or position, and reduced-motion users get the static strip plus the
   glyph and status text, which carry the same state. A paused poller holds
   still at low opacity. */
@media (prefers-reduced-motion: no-preference) {
    .treebar-poller[data-paused="0"] .treebar-badge-strip {
        animation: tb-badge-pulse 1.6s ease-in-out infinite;
    }
}
@keyframes tb-badge-pulse { 0%, 100% { opacity: 0.35; } 50% { opacity: 0.8; } }
.treebar-poller[data-paused="1"] .treebar-badge-strip { opacity: 0.3; }
/* The quiet panel is CLIPPED when collapsed, never `display: none` — the
   pause button stays keyboard-focusable, so tabbing to it matches
   `:focus-within` and expands the badge in the same frame (no
   invisible-focus trap). The quiet live tree is `display: none` until
   then: it carries no focusable controls of its own that must stay
   reachable (pills reappear with it), and a hidden inner still polls and
   swaps — htmx never checks visibility. The inner rules use the
   DIRECT-CHILD `>` so expanding an outer poller never auto-expands a
   nested one (the same nested-poller trap the data-show-* scheme avoids,
   see comment below). */
.treebar-badge-panel {
    display: flex; gap: 0.5rem; align-items: center; flex-wrap: wrap;
}
.treebar-poller > .treebar-poller-inner { display: block; }
.treebar-poller[data-chrome="quiet"] .treebar-badge-panel,
.htmxo-live-reporter .treebar-poller .treebar-badge-panel {
    max-height: 0; overflow: hidden;
}
.treebar-poller[data-chrome="quiet"]:hover .treebar-badge-panel,
.treebar-poller[data-chrome="quiet"]:focus-within .treebar-badge-panel,
.htmxo-live-reporter .treebar-poller:hover .treebar-badge-panel,
.htmxo-live-reporter .treebar-poller:focus-within .treebar-badge-panel { max-height: none; }
.treebar-poller[data-chrome="quiet"] > .treebar-poller-inner,
.htmxo-live-reporter .treebar-poller > .treebar-poller-inner { display: none; }
.treebar-poller[data-chrome="quiet"]:hover > .treebar-poller-inner,
.treebar-poller[data-chrome="quiet"]:focus-within > .treebar-poller-inner,
.htmxo-live-reporter .treebar-poller:hover > .treebar-poller-inner,
.htmxo-live-reporter .treebar-poller:focus-within > .treebar-poller-inner { display: block; }
.treebar-pause {
    margin: 0; padding: 0.1rem 0.45rem; font-size: 0.75rem; line-height: 1.4;
    width: auto; cursor: pointer; flex: none;
}
/* The badge label WRAPS, never clips: a poller label is read content, so no
   max-width / overflow / ellipsis / nowrap here (snag
   poller-badge-lab-78301564). The panel flex-wraps so the status siblings
   drop below the label on narrow widths instead of crushing it, and the
   quiet hover/focus expansion above caps nothing (max-height: none) so a
   wrapped multi-line label is never cut there either. */
.treebar-badge-label {
    font-size: 0.8rem; color: var(--pico-muted-color, #888);
}
.treebar-badge-status { font-size: 0.8rem; flex: none; }
.treebar-badge-bar { width: 6rem; margin: 0; flex: none; }
.treebar-badge-elapsed { font-size: 0.8rem; color: var(--pico-muted-color, #888); flex: none; }
/* Freshness (htmx_treebar_script): a live region whose shown state is old
   says how old, in the `.treebar-freshness` text of its chrome. `stale`
   stops the polling pulse; `lost` (updates have failed for seconds, not
   one blip) also marks the strip and the text in the error color, dims the
   live content, and opens a quiet badge's panel, so the notice is seen
   without hovering. The text wraps like the badge label; nothing clips. */
.treebar-freshness { font-size: 0.8rem; color: var(--pico-muted-color, #888); }
.treebar-freshness[hidden] { display: none; }
.treebar-poller[data-treebar-freshness] > .treebar-badge > .treebar-badge-strip { animation: none; }
.treebar-poller[data-treebar-freshness="lost"] > .treebar-badge > .treebar-badge-strip {
    background: var(--pico-del-color, #c62828); opacity: 0.9;
}
.treebar-poller[data-treebar-freshness="lost"] > .treebar-badge .treebar-freshness,
.treebar-board[data-treebar-freshness="lost"] > .treebar-board-header > .treebar-freshness,
[data-treebar-freshness="lost"] .treebar-ws-frame > .treebar-freshness { color: var(--pico-del-color, #c62828); }
.treebar-poller[data-treebar-freshness="lost"] > .treebar-poller-inner,
.treebar-board[data-treebar-freshness="lost"] > .treebar-board-list,
[data-treebar-freshness="lost"] .treebar-ws-frame > :not(.treebar-freshness) { opacity: 0.55; }
.treebar-poller[data-chrome="quiet"][data-treebar-freshness="lost"] > .treebar-badge > .treebar-badge-panel,
.htmxo-live-reporter .treebar-poller[data-treebar-freshness="lost"] > .treebar-badge > .treebar-badge-panel { max-height: none; }
.treebar-children { padding-left: 1rem; margin-left: 0.25rem; border-left: 2px solid color-mix(in srgb, var(--pico-muted-color, #888) 40%, transparent); }
/* Message-bearing nodes now use the same treebar-node + treebar-header structure
   as container nodes, so treebar-label/treebar-value/treebar-description classes
   are no longer emitted. */

/* Pill toggle state lives on the closest scope (.treebar-poller for live polls,
   .treebar-board-item on a board, .treebar-ws-frame for WebSocket frames,
   .treebar-children for static one-shot renders). data-show-* values are "0" or
   "1" rather than "true"/"false" because Cobweb drops attrs whose value is the
   string "false".

   Visibility is driven through INHERITED custom properties, NOT a descendant
   combinator (`.treebar-poller[data-show-finished="0"] .treebar-child-finished`).
   The combinator reached straight through *nested* pollers: an outer poller
   stuck at "0" kept hiding finished nodes inside a nested poller even after
   that inner poller's pill flipped it to "1" (the outer match still applied;
   CSS descendant selectors have no nearest-ancestor-wins rule). Custom
   properties inherit and the NEAREST definition wins, so each scope governs
   its own subtree down to the next scope — nested-poller-correct by
   construction. Only scopes that actually carry the data-show-* attribute set
   the var, so a scopeless inner .treebar-children (scoped=false inside a
   poller) is transparent to inheritance: the poller's value passes through. */
.treebar-poller[data-show-finished="0"], .treebar-board-item[data-show-finished="0"], .treebar-ws-frame[data-show-finished="0"], .treebar-children[data-show-finished="0"] { --tb-finished-display: none; }
.treebar-poller[data-show-finished="1"], .treebar-board-item[data-show-finished="1"], .treebar-ws-frame[data-show-finished="1"], .treebar-children[data-show-finished="1"] { --tb-finished-display: block; }
.treebar-poller[data-show-failed="0"], .treebar-board-item[data-show-failed="0"], .treebar-ws-frame[data-show-failed="0"], .treebar-children[data-show-failed="0"] { --tb-failed-display: none; }
.treebar-poller[data-show-failed="1"], .treebar-board-item[data-show-failed="1"], .treebar-ws-frame[data-show-failed="1"], .treebar-children[data-show-failed="1"] { --tb-failed-display: block; }
.treebar-poller[data-show-pending="0"], .treebar-board-item[data-show-pending="0"], .treebar-ws-frame[data-show-pending="0"], .treebar-children[data-show-pending="0"] { --tb-pending-display: none; }
.treebar-poller[data-show-pending="1"], .treebar-board-item[data-show-pending="1"], .treebar-ws-frame[data-show-pending="1"], .treebar-children[data-show-pending="1"] { --tb-pending-display: block; }
.treebar-poller[data-show-skipped="0"], .treebar-board-item[data-show-skipped="0"], .treebar-ws-frame[data-show-skipped="0"], .treebar-children[data-show-skipped="0"] { --tb-skipped-display: none; }
.treebar-poller[data-show-skipped="1"], .treebar-board-item[data-show-skipped="1"], .treebar-ws-frame[data-show-skipped="1"], .treebar-children[data-show-skipped="1"] { --tb-skipped-display: block; }
.treebar-poller[data-show-reused="0"], .treebar-board-item[data-show-reused="0"], .treebar-ws-frame[data-show-reused="0"], .treebar-children[data-show-reused="0"] { --tb-reused-display: none; }
.treebar-poller[data-show-reused="1"], .treebar-board-item[data-show-reused="1"], .treebar-ws-frame[data-show-reused="1"], .treebar-children[data-show-reused="1"] { --tb-reused-display: block; }
.treebar-child-finished { display: var(--tb-finished-display, block); }
.treebar-child-failed { display: var(--tb-failed-display, block); }
.treebar-child-pending { display: var(--tb-pending-display, block); }
.treebar-child-skipped { display: var(--tb-skipped-display, block); }
.treebar-child-reused { display: var(--tb-reused-display, block); }

/* Active-pill highlight, same nearest-scope-wins inheritance so a nested
   poller's pills reflect that poller's own toggle, not an ancestor's. */
.treebar-poller[data-show-finished="1"], .treebar-board-item[data-show-finished="1"], .treebar-ws-frame[data-show-finished="1"], .treebar-children[data-show-finished="1"] { --tb-finished-pill-border: currentColor; }
.treebar-poller[data-show-failed="1"], .treebar-board-item[data-show-failed="1"], .treebar-ws-frame[data-show-failed="1"], .treebar-children[data-show-failed="1"] { --tb-failed-pill-border: currentColor; }
.treebar-poller[data-show-pending="1"], .treebar-board-item[data-show-pending="1"], .treebar-ws-frame[data-show-pending="1"], .treebar-children[data-show-pending="1"] { --tb-pending-pill-border: currentColor; }
.treebar-poller[data-show-skipped="1"], .treebar-board-item[data-show-skipped="1"], .treebar-ws-frame[data-show-skipped="1"], .treebar-children[data-show-skipped="1"] { --tb-skipped-pill-border: currentColor; }
.treebar-poller[data-show-reused="1"], .treebar-board-item[data-show-reused="1"], .treebar-ws-frame[data-show-reused="1"], .treebar-children[data-show-reused="1"] { --tb-reused-pill-border: currentColor; }
.treebar-pill-finished { border-color: var(--tb-finished-pill-border, transparent); }
.treebar-pill-failed { border-color: var(--tb-failed-pill-border, transparent); }
.treebar-pill-pending { border-color: var(--tb-pending-pill-border, transparent); }
.treebar-pill-skipped { border-color: var(--tb-skipped-pill-border, transparent); }
.treebar-pill-reused { border-color: var(--tb-reused-pill-border, transparent); }

/* Keyed board (htmx_render_board). The .treebar-board-item wrapper is never
   replaced by the client reconciler — only its .treebar-board-item-content —
   so UI state on it (data-show-* pill toggles above, data-open for the tree)
   survives updates exactly like the .treebar-poller wrapper does. */
.treebar-board-header { display: flex; gap: 0.5rem; align-items: baseline; justify-content: space-between; flex-wrap: wrap; margin-bottom: 0.5rem; }
.treebar-board-header > .treebar-freshness { flex: 1; }
.treebar-board-count { font-size: 0.85em; color: var(--pico-muted-color, #888); }
.treebar-phase-overview { margin-block: 0.75rem; }
.treebar-phase-plan { overflow-x: auto; margin-block: 0.5rem; }
.treebar-phase-plan table { width: 100%; font-size: 0.85em; }
.treebar-phase-plan caption { text-align: left; font-weight: 600; padding-block: 0.3rem; }
.treebar-phase-plan th, .treebar-phase-plan td { padding: 0.3rem 0.5rem; }
.treebar-phase-plan th { text-align: left; overflow-wrap: anywhere; }
.treebar-phase-plan th[scope="row"] { overflow-wrap: anywhere; min-width: 8rem; }
.treebar-phase-plan td { text-align: right; font-variant-numeric: tabular-nums; }
/* A nested plan is a disclosure inside the plan it is nested in, so each level
   indents once more; its summary carries the caption, which the table keeps
   for assistive technology only. */
.treebar-phase-disclosure {
    margin: 0.25rem 0 0.25rem 1rem; padding-inline-start: 0.5rem;
    border-inline-start: 2px solid var(--pico-muted-border-color, #ddd);
}
.treebar-phase-disclosure > summary { font-size: 0.85em; font-weight: 600; overflow-wrap: anywhere; cursor: pointer; }
.treebar-phase-disclosure[open] > summary { margin-bottom: 0.25rem; }
.treebar-phase-disclosure > .treebar-phase-plan caption {
    position: absolute; width: 1px; height: 1px; overflow: hidden;
    clip-path: inset(50%); white-space: nowrap;
}
.treebar-phase-overview-controls { display: flex; flex-wrap: wrap; gap: 0.4rem; justify-content: flex-end; }
.treebar-phase-overview-controls button {
    margin: 0; padding: 0.1rem 0.5rem; font-size: 0.7rem; line-height: 1.4;
    width: auto; cursor: pointer;
}
@media (max-width: 600px) {
    .treebar-phase-plan table, .treebar-phase-plan caption, .treebar-phase-plan tbody { display: block; }
    .treebar-phase-plan thead { display: none; }
    .treebar-phase-plan tr { display: grid; grid-template-columns: repeat(6, minmax(0, 1fr)); margin-bottom: 0.5rem; }
    .treebar-phase-plan th[scope="row"] { grid-column: 1 / -1; min-width: 0; }
    .treebar-phase-plan td { display: flex; flex-direction: column; align-items: flex-start; padding-inline: 0.25rem; }
    .treebar-phase-plan td::before { content: attr(data-phase-state); font-size: 0.7rem; text-transform: capitalize; overflow-wrap: anywhere; }
}
.treebar-board-pause {
    margin: 0; padding: 0.1rem 0.5rem; font-size: 0.7rem; line-height: 1.4;
    width: auto; cursor: pointer;
}
.treebar-board-list { display: flex; flex-direction: column; gap: 0.4rem; }
.treebar-board-item {
    min-width: 0;
    padding: 0.35rem 0.6rem;
    border-left: 3px solid color-mix(in srgb, var(--pico-muted-color, #888) 45%, transparent);
    border-radius: 0.25rem;
    background: color-mix(in srgb, var(--pico-muted-color, #888) 7%, transparent);
    transition: opacity 0.3s;
}
.treebar-board-item[data-treebar-state="running"] { border-left-color: var(--pico-primary, #1095c1); }
.treebar-board-item[data-treebar-state="done"] { border-left-color: var(--pico-ins-color, #2e7d32); }
.treebar-board-item[data-treebar-state="failed"] { border-left-color: var(--pico-del-color, #c62828); }
/* Queued renders like a pending node: dim, not yet started. */
.treebar-board-item[data-treebar-state="queued"] { opacity: 0.55; }
.treebar-board-item.treebar-board-leaving { opacity: 0.45; }
.treebar-board-item-header { display: flex; gap: 0.5ch; align-items: baseline; flex-wrap: wrap; overflow-wrap: anywhere; }
.treebar-board-label { font-weight: 600; }
.treebar-board-meta {
    display: flex; flex-wrap: wrap; gap: 0 0.9rem; width: 100%;
    font-size: 0.8em; color: var(--pico-muted-color, #888);
}
.treebar-board-meta-key { opacity: 0.75; }
.treebar-board-tree { margin: 0.25rem 0 0; }
.treebar-board-tree > summary { cursor: pointer; font-size: 0.8em; color: var(--pico-muted-color, #888); }
.treebar-board-tree > .treebar-node { margin-top: 0.25rem; }
.treebar-board-empty { margin: 0; color: var(--pico-muted-color, #888); }
.treebar-board-empty[hidden] { display: none; }

/* Demo helpers */
.tb-input-narrow { max-width: 6rem; }
.tb-input-narrow-7 { max-width: 7rem; }
"""))
