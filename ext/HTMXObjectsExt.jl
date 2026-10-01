module HTMXObjectsExt
import HTMXObjects
import HTMXObjects: h, Node, Raw, fetchindex
import HTTP.WebSockets: WebSocket, send
import Treebars: htmx_render, htmx_render_children, htmx_treebar_styles, htmx_treebar_script,
    ws_progress, htmx_ws_render, htmx_ws_progress, polling_fetchindex,
    htmx_render_board, htmx_ws_render_board, ws_board,
    ProgressNode, StateProgress, root, is_pending, is_running, is_finished, is_failed, is_skipped, is_displayed, _renders_self, duration, eta, short_duration, _first_seen!,
    _flatten_displayed_children, _shows_interrupt_request
import Treebars: add_child!
import Treebars: initialize_progress!, update_progress!, start_progress!, finalize_progress!, fail_progress!
import Treebars: current_dispatch_parent
import Dates
using Dates: Millisecond

# Map a StateProgress's lifecycle into a single status string the client JS can dispatch on.
function _status_string(sp::StateProgress)
    is_pending(sp) && return "pending"
    is_running(sp) && return "running"
    is_failed(sp) && return "failed"
    is_skipped(sp) && return "skipped"
    "finished"
end

# Initial textContent for the duration span. Running nodes get a fresh value here
# but the client-side ticker overwrites every 250ms; finished/failed nodes keep
# whatever the server rendered (the ticker leaves them alone).
function _initial_duration_text(sp::StateProgress)
    is_pending(sp) && return " — pending"
    # A label, never an elapsed figure: a skipped node has no `started_at`, so
    # any duration here would be the 0s that made a bypassed phase read as an
    # instantaneous one.
    is_skipped(sp) && return " — skipped"
    d = short_duration(duration(sp))
    if is_running(sp)
        # A determinate running node (0 < i < N) also gets a live ETA beside the
        # elapsed; the client ticker counts it down between polls (data-eta-ms).
        e = eta(sp)
        isnothing(e) ? " — $(d) so far" : " — $(d) so far · ETA ~$(short_duration(e))"
    elseif is_failed(sp)
        " — failed ($(d))"
    else
        " — done ($(d))"
    end
end

# Duration span. Carries data attrs so the client can tick running nodes locally
# between server polls instead of waiting for the next render to advance them.
function _duration_span(sp::StateProgress)
    status = _status_string(sp)
    text = _initial_duration_text(sp)
    if status == "pending"
        return h.span(class="treebar-duration", data_treebar_status=status)(text)
    end
    elapsed_ms = string(Dates.value(Millisecond(duration(sp))))
    # data-eta-ms is present only for a running determinate node; the client
    # ticker anchors an absolute finish target from it and counts down. Absent
    # → the span ticks up (elapsed) exactly as before.
    e = eta(sp)
    if isnothing(e)
        h.span(class="treebar-duration",
            data_treebar_status=status,
            data_elapsed_ms=elapsed_ms)(text)
    else
        h.span(class="treebar-duration",
            data_treebar_status=status,
            data_elapsed_ms=elapsed_ms,
            data_eta_ms=string(Dates.value(Millisecond(e))))(text)
    end
end

# Pending-interrupt marker for a node header (see `_shows_interrupt_request`):
# the same text `render_text` prints, so the two renderers agree.
_interrupt_span(node::ProgressNode) =
    _shows_interrupt_request(node) ? h.span(class="treebar-interrupt")("interrupt requested") : ""

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
.treebar-pending { opacity: 0.55; }
.treebar-pending .treebar-progress { opacity: 0.5; }
/* Dimmer than pending and struck through: the phase is terminal, and the
   strike is what separates "never ran" from "not yet" at a glance. */
.treebar-skipped { opacity: 0.45; }
.treebar-skipped .treebar-description { text-decoration: line-through; }
.treebar-pill:hover { opacity: 0.8; }
.treebar-header { display: flex; gap: 0.5ch; align-items: baseline; flex-wrap: wrap; }
.treebar-duration { font-size: 0.85em; color: var(--pico-muted-color, #888); }
.treebar-interrupt { font-size: 0.85em; font-style: italic; color: var(--pico-muted-color, #888); }
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
.treebar-children { padding-left: 1rem; margin-left: 0.25rem; border-left: 2px solid color-mix(in srgb, var(--pico-muted-color, #888) 40%, transparent); }
/* Message-bearing nodes now use the same treebar-node + treebar-header structure
   as container nodes, so treebar-label/treebar-value/treebar-description classes
   are no longer emitted. */

/* Pill toggle state lives on the closest scope (.treebar-poller for live polls,
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
.treebar-poller[data-show-finished="0"], .treebar-board-item[data-show-finished="0"], .treebar-children[data-show-finished="0"] { --tb-finished-display: none; }
.treebar-poller[data-show-finished="1"], .treebar-board-item[data-show-finished="1"], .treebar-children[data-show-finished="1"] { --tb-finished-display: block; }
.treebar-poller[data-show-failed="0"], .treebar-board-item[data-show-failed="0"], .treebar-children[data-show-failed="0"] { --tb-failed-display: none; }
.treebar-poller[data-show-failed="1"], .treebar-board-item[data-show-failed="1"], .treebar-children[data-show-failed="1"] { --tb-failed-display: block; }
.treebar-poller[data-show-pending="0"], .treebar-board-item[data-show-pending="0"], .treebar-children[data-show-pending="0"] { --tb-pending-display: none; }
.treebar-poller[data-show-pending="1"], .treebar-board-item[data-show-pending="1"], .treebar-children[data-show-pending="1"] { --tb-pending-display: block; }
.treebar-poller[data-show-skipped="0"], .treebar-board-item[data-show-skipped="0"], .treebar-children[data-show-skipped="0"] { --tb-skipped-display: none; }
.treebar-poller[data-show-skipped="1"], .treebar-board-item[data-show-skipped="1"], .treebar-children[data-show-skipped="1"] { --tb-skipped-display: block; }
.treebar-child-finished { display: var(--tb-finished-display, block); }
.treebar-child-failed { display: var(--tb-failed-display, block); }
.treebar-child-pending { display: var(--tb-pending-display, block); }
.treebar-child-skipped { display: var(--tb-skipped-display, block); }

/* Active-pill highlight, same nearest-scope-wins inheritance so a nested
   poller's pills reflect that poller's own toggle, not an ancestor's. */
.treebar-poller[data-show-finished="1"], .treebar-board-item[data-show-finished="1"], .treebar-children[data-show-finished="1"] { --tb-finished-pill-border: currentColor; }
.treebar-poller[data-show-failed="1"], .treebar-board-item[data-show-failed="1"], .treebar-children[data-show-failed="1"] { --tb-failed-pill-border: currentColor; }
.treebar-poller[data-show-pending="1"], .treebar-board-item[data-show-pending="1"], .treebar-children[data-show-pending="1"] { --tb-pending-pill-border: currentColor; }
.treebar-poller[data-show-skipped="1"], .treebar-board-item[data-show-skipped="1"], .treebar-children[data-show-skipped="1"] { --tb-skipped-pill-border: currentColor; }
.treebar-pill-finished { border-color: var(--tb-finished-pill-border, transparent); }
.treebar-pill-failed { border-color: var(--tb-failed-pill-border, transparent); }
.treebar-pill-pending { border-color: var(--tb-pending-pill-border, transparent); }
.treebar-pill-skipped { border-color: var(--tb-skipped-pill-border, transparent); }

/* Keyed board (htmx_render_board). The .treebar-board-item wrapper is never
   replaced by the client reconciler — only its .treebar-board-item-content —
   so UI state on it (data-show-* pill toggles above, data-open for the tree)
   survives updates exactly like the .treebar-poller wrapper does. */
.treebar-board-header { display: flex; gap: 0.5rem; align-items: baseline; justify-content: space-between; flex-wrap: wrap; margin-bottom: 0.5rem; }
.treebar-board-count { font-size: 0.85em; color: var(--pico-muted-color, #888); }
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

# Client-side duration ticker. Anchors each running .treebar-duration on first
# sight (and re-anchors the spans a swap delivered, since their data-elapsed-ms
# comes back fresh from the server) then ticks textContent every 100ms locally —
# so the counter advances smoothly between server polls instead of stuttering.
# Tracking is incremental: two live sets (running spans, poller wrappers)
# seeded once and kept current by a MutationObserver, so ticks and swaps cost
# work proportional to the active nodes / changed fragment, never the document.
# The same script owns poller Pause/terminalization and the keyed board
# reconciler (`htmx_render_board`).
htmx_treebar_script() = h.script(Raw("""
(function(){
    // Band-based formatter mirroring the server-side short_duration: sub-100ms
    // show whole milliseconds, sub-minute shows one-decimal seconds at 0.1s
    // resolution ("13.9s"; FLOOR, so server-render and ticker never disagree at
    // poll boundaries), and minute-and-up show the two most-significant units.
    // Each band's smallest displayed unit steps by a fixed amount (per-100ms
    // below 1min, per-second up to 1h, per-minute up to 1d, per-hour beyond) so
    // the rendered string changes at most once per step and length stays stable
    // within a band.
    function fmt(ms){
        if (ms < 0) ms = 0;
        if (ms < 100)         return ms + 'ms';
        if (ms < 60_000)      return (Math.floor(ms / 100) / 10) + 's';
        if (ms < 3_600_000){
            var m = Math.floor(ms / 60_000);
            var s = Math.floor(ms / 1000) % 60;
            return m + 'm ' + s + 's';
        }
        if (ms < 86_400_000){
            var h = Math.floor(ms / 3_600_000);
            var m = Math.floor(ms / 60_000) % 60;
            return h + 'h ' + m + 'm';
        }
        var d = Math.floor(ms / 86_400_000);
        var h = Math.floor(ms / 3_600_000) % 24;
        return d + 'd ' + h + 'h';
    }
    function anchor(el){
        var ms = parseInt(el.dataset.elapsedMs, 10);
        if (isNaN(ms)) ms = 0;
        el._tbAnchor = Date.now() - ms;
        el._tbAnchoredFrom = el.dataset.elapsedMs;
        el._tbLast = undefined;
        // ETA (running determinate nodes only): anchor an ABSOLUTE finish target
        // so the estimate counts down smoothly between polls; each server poll
        // re-anchors with a fresh data-eta-ms as the position advances.
        var eta = el.dataset.etaMs === undefined ? NaN : parseInt(el.dataset.etaMs, 10);
        el._tbEtaTarget = isNaN(eta) ? undefined : Date.now() + eta;
    }
    function tick(el){
        if (el.dataset.treebarStatus !== 'running') return;
        // Never tick inside a kept snapshot (.treebar-frozen, see _kept_progress):
        // a terminal tree may still carry a "running" node, and a post-hoc
        // inspection view must be static, not counting up forever.
        if (el.closest('.treebar-frozen')) return;
        // Freeze the duration while this span's poller is paused, so the
        // inspected snapshot is genuinely still. On resume the ticker
        // catches up to true elapsed (the work kept running — pause is not
        // cancel) and the next server poll re-anchors.
        var p = el.closest('.treebar-poller');
        if (p && p.dataset.paused === '1') return;
        // Same for a paused board (htmx_render_board): pause freezes it whole.
        var b = el.closest('.treebar-board');
        if (b && b.dataset.paused === '1') return;
        if (el._tbAnchor === undefined) anchor(el);
        var s = ' — ' + fmt(Date.now() - el._tbAnchor) + ' so far';
        // A determinate node also counts its ETA down (fmt clamps negatives to
        // 0; the next server poll re-anchors to the new estimate).
        if (el._tbEtaTarget !== undefined){
            s += ' · ETA ~' + fmt(el._tbEtaTarget - Date.now());
        }
        // Only touch the DOM when the rendered string actually changes —
        // below 1min the value steps every 100ms (matching the tick cadence,
        // so each tick updates), while minute-and-up only change once per
        // integer minute/hour, so those ticks are mostly no-ops.
        if (el._tbLast !== s){ el.textContent = s; el._tbLast = s; }
    }
    function terminalizePoller(evt){
        var el = evt && evt.detail && evt.detail.elt;
        if (!el || !el.classList || !el.classList.contains('treebar-terminal-content')) return;
        var p = el.parentElement;
        if (!p || !p.classList.contains('treebar-poller')) return;
        p.classList.replace('treebar-poller', 'treebar-terminal');
        ['paused', 'showFinished', 'showPending', 'showFailed', 'showSkipped'].forEach(function(key){
            delete p.dataset[key];
        });
        var badge = p.querySelector(':scope > .treebar-badge');
        if (badge) badge.remove();
    }
    // Mirror the live inner into the wrapper's badge: the badge lives on the
    // never-swapped wrapper (so the pause control keeps focus and state across
    // polls), which means its status line would go stale without this. Reads
    // the same nodes the tree renders — the first determinate bar, the first
    // duration span — so the badge can never disagree with the tree it
    // summarizes. Also re-derives the pause glyph from data-paused, so a
    // hand-edited dataset (DevTools) shows the matching control, exactly as a
    // click would. Exposed as window.__tbSyncBadge so the pause onclick can
    // refresh the badge in the same frame as the toggle.
    function syncBadge(p){
        var badge = p.querySelector(':scope > .treebar-badge');
        if (!badge) return;
        var paused = p.dataset.paused === '1';
        var btn = badge.querySelector('.treebar-pause');
        if (btn){
            btn.textContent = paused ? '▶' : '❚❚';
            btn.setAttribute('aria-label', paused ? 'Resume live updates' : 'Pause live updates');
        }
        var st = badge.querySelector('.treebar-badge-status');
        if (st){
            var s = paused ? 'Paused' : 'Polling';
            if (st._tbLast !== s){ st.textContent = s; st._tbLast = s; }
        }
        var inner = p.querySelector(':scope > .treebar-poller-inner');
        var bar = badge.querySelector('.treebar-badge-bar');
        if (bar){
            var src = inner ? inner.querySelector('progress.treebar-progress') : null;
            if (src && src.hasAttribute('value') && src.hasAttribute('max')){
                bar.setAttribute('value', src.getAttribute('value'));
                bar.setAttribute('max', src.getAttribute('max'));
            } else {
                bar.removeAttribute('value');
                bar.removeAttribute('max');
            }
        }
        var el = badge.querySelector('.treebar-badge-elapsed');
        if (el){
            var d = inner ? inner.querySelector('.treebar-duration') : null;
            var t = d ? d.textContent : '';
            if (el._tbLast !== t){ el.textContent = t; el._tbLast = t; }
        }
    }
    // Incremental active-progress tracking: the ticker NEVER scans the
    // document. Two live sets — running duration spans and poller wrappers —
    // are seeded once at startup and kept current by a MutationObserver
    // below, so each tick costs work proportional to the active progress
    // nodes and each swap costs work proportional to the changed fragment;
    // settled hidden trees cost nothing. (Was: document-wide
    // querySelectorAll on every 100ms tick and every swap — ~0.3 CPU-s per
    // 30s on a 16k-node page. Snag browser-progress-573fb052.)
    var liveRunning = new Set();
    var livePollers = new Set();
    var RUNNING_SEL = '.treebar-duration[data-treebar-status="running"]';
    var POLLER_SEL = '.treebar-poller';
    function trackRunning(el){
        if (el._tbAnchor === undefined) anchor(el);
        liveRunning.add(el);
    }
    function collectRunning(root){
        if (root.nodeType === 1 && root.matches(RUNNING_SEL)) trackRunning(root);
        if (root.nodeType !== 1 && root.nodeType !== 9) return;
        var q = root.querySelectorAll(RUNNING_SEL);
        for (var i = 0; i < q.length; i++) trackRunning(q[i]);
    }
    function collectPollers(root){
        if (root.nodeType === 1 && root.matches(POLLER_SEL)) livePollers.add(root);
        if (root.nodeType !== 1 && root.nodeType !== 9) return;
        var q = root.querySelectorAll(POLLER_SEL);
        for (var j = 0; j < q.length; j++) livePollers.add(q[j]);
    }
    function collect(root){ collectRunning(root); collectPollers(root); }
    // Lazy prune: removals and terminalizations drop out on the next tick.
    function runningAlive(el){
        if (!el.isConnected || el.dataset.treebarStatus !== 'running'){ liveRunning.delete(el); return false; }
        return true;
    }
    function syncBadgeLive(p){
        if (!p.isConnected || !p.classList.contains('treebar-poller')){ livePollers.delete(p); return; }
        syncBadge(p);
    }
    function syncAllBadges(){
        livePollers.forEach(syncBadgeLive);
    }
    window.__tbSyncBadge = syncBadge;
    // Re-anchor only spans whose server value changed (or that are new). A swap
    // replaces the spans it delivers, so fresh ones anchor from their own
    // data-elapsed-ms; a span the swap did NOT touch keeps its anchor. Blindly
    // re-reading every span on every swap would reset an untouched span (a
    // board item between its 1s polls, a sibling poller) back to the
    // server value it was rendered with, so it would jump backwards.
    function reanchorAll(){
        liveRunning.forEach(function(el){
            if (runningAlive(el) && (el._tbAnchoredFrom === undefined || el._tbAnchoredFrom !== el.dataset.elapsedMs)) anchor(el);
        });
    }
    function tickAll(){
        liveRunning.forEach(function(el){ if (runningAlive(el)) tick(el); });
        syncAllBadges();
    }
    function reanchorAndTick(evt){
        terminalizePoller(evt);
        // Scope the synchronous refresh to the swapped target; the observer
        // below backstops every other insertion path (OOB inserts outside
        // the target, ws frames, in-place morphs), so this never needs a
        // document-wide scan.
        var t = evt && evt.detail && (evt.detail.target || evt.detail.elt);
        if (t && (t.nodeType === 1 || t.nodeType === 9)) collect(t);
        reanchorAll();
        tickAll();
    }
    // Backstop: every DOM insertion and every status/estimate edit lands
    // here, so nodes the swap handler cannot see still join or leave the
    // live sets. Each callback costs work proportional to the changed nodes
    // only. Poller wrappers are born by insertion (childList) and die by
    // terminalization or removal (lazy prune in syncBadgeLive) — never by a
    // class flip a filter would need to watch, so `class` stays unobserved.
    var tbObserver = new MutationObserver(function(records){
        for (var i = 0; i < records.length; i++){
            var r = records[i];
            if (r.type === 'childList'){
                for (var j = 0; j < r.addedNodes.length; j++) collect(r.addedNodes[j]);
            } else if (r.type === 'attributes' && r.target.nodeType === 1){
                var el = r.target;
                if (!el.classList.contains('treebar-duration')) continue;
                if (r.attributeName === 'data-treebar-status'){
                    if (el.dataset.treebarStatus === 'running') trackRunning(el);
                    else liveRunning.delete(el);
                } else if ((r.attributeName === 'data-elapsed-ms' || r.attributeName === 'data-eta-ms') &&
                           el.dataset.treebarStatus === 'running'){
                    // A morph refreshed the server estimate in place:
                    // re-anchor so the ticker counts from the fresh value.
                    anchor(el);
                    liveRunning.add(el);
                }
            }
        }
    });
    document.addEventListener('htmx:afterSwap', reanchorAndTick);
    document.addEventListener('htmx:oobAfterSwap', reanchorAndTick);

    // --- Keyed board (htmx_render_board) -----------------------------------
    // Every update — a poll response, a WebSocket frame, treebarUpdateBoard —
    // carries the FULL current list, so reconciling is idempotent and a dropped
    // update costs nothing. Items are matched by data-treebar-key: an existing
    // item keeps its wrapper (and the UI state on it) and swaps only its
    // .treebar-board-item-content; a new item is inserted in server order; an
    // item that left the list shows its final state for the board's linger
    // time and is then removed. The server decides how long a done/failed item
    // stays listed, so a board can also hold recent history.
    function isTerminalState(s){ return s === 'done' || s === 'failed' || s === 'ended'; }
    function boardList(board){ return board.querySelector(':scope > .treebar-board-list'); }
    function boardItems(list){
        return Array.prototype.filter.call(list.children, function(c){
            return c.classList.contains('treebar-board-item');
        });
    }
    function boardEmpty(board){
        var list = boardList(board), empty = board.querySelector(':scope > .treebar-board-empty');
        if (list && empty) empty.hidden = boardItems(list).length > 0;
    }
    function boardLinger(board, item){
        var ms = parseInt(item.dataset.treebarLingerMs || board.dataset.treebarLingerMs, 10);
        return isNaN(ms) ? 3000 : Math.max(0, ms);
    }
    function scheduleLeave(board, item){
        if (item._tbLeave) return;
        var leave = function(){
            // A paused board is frozen: lingering items wait for Resume.
            if (board.dataset.paused === '1'){ item._tbLeave = setTimeout(leave, 250); return; }
            item.remove();
            boardEmpty(board);
        };
        item._tbLeave = setTimeout(leave, boardLinger(board, item));
    }
    function cancelLeave(item){
        if (!item._tbLeave) return;
        clearTimeout(item._tbLeave);
        item._tbLeave = null;
        item.classList.remove('treebar-board-leaving');
    }
    // An item that left the list lingers, then leaves. If the server never
    // showed it terminal it ends where it stands: clocks freeze, it reads
    // "ended".
    function endItem(board, item){
        if (!isTerminalState(item.dataset.treebarState)){
            item.dataset.treebarState = 'ended';
            var hd = item.querySelector('.treebar-board-duration');
            if (hd){
                var ms = hd._tbAnchor !== undefined ? Date.now() - hd._tbAnchor : parseInt(hd.dataset.elapsedMs, 10) || 0;
                hd.dataset.treebarStatus = 'ended';
                hd.textContent = ' — ended (' + fmt(ms) + ')';
            }
            var tree = item.querySelector('.treebar-board-tree');
            if (tree) tree.classList.add('treebar-frozen');
        }
        item.classList.add('treebar-board-leaving');
        scheduleLeave(board, item);
    }
    function updateItem(item, next){
        var content = next.querySelector(':scope > .treebar-board-item-content');
        if (!content) return;
        content = document.importNode(content, true);
        // The tree's expanded state belongs to the wrapper, not the response.
        var tree = content.querySelector(':scope > .treebar-board-tree');
        if (tree) tree.open = item.dataset.open === '1';
        var old = item.querySelector(':scope > .treebar-board-item-content');
        old ? item.replaceChild(content, old) : item.appendChild(content);
        ['treebarState', 'treebarLingerMs'].forEach(function(k){
            if (next.dataset[k] === undefined) delete item.dataset[k]; else item.dataset[k] = next.dataset[k];
        });
        if (window.htmx) htmx.process(content);
    }
    function reconcileBoard(board, incoming){
        var list = boardList(board), next = boardList(incoming);
        if (!list || !next) return;
        var live = {}, seen = {}, prev = null;
        boardItems(list).forEach(function(it){ live[it.dataset.treebarKey] = it; });
        boardItems(next).forEach(function(n){
            var key = n.dataset.treebarKey, state = n.dataset.treebarState, item = live[key];
            seen[key] = true;
            if (!item){
                item = document.importNode(n, true);
                if (window.htmx) htmx.process(item);
            } else {
                // Listed again after dropping out (a flapping filter): it stays.
                cancelLeave(item);
                updateItem(item, n);
            }
            var at = prev ? prev.nextSibling : list.firstChild;
            if (item !== at) list.insertBefore(item, at);
            prev = item;
        });
        Object.keys(live).forEach(function(key){ if (!seen[key]) endItem(board, live[key]); });
        var count = board.querySelector(':scope > .treebar-board-header > .treebar-board-count');
        var ncount = incoming.querySelector(':scope > .treebar-board-header > .treebar-board-count');
        if (count && ncount) count.replaceWith(document.importNode(ncount, true));
        boardEmpty(board);
        // The reconciler inserts spans through DOM APIs, not an htmx swap, so
        // track them synchronously (scoped to the board); the observer below
        // backstops the same insertions idempotently.
        collect(board);
        reanchorAll(); tickAll();
    }
    function parseBoards(html){
        if (typeof html !== 'string' || html.indexOf('treebar-board') === -1) return [];
        var t = document.createElement('template');
        t.innerHTML = html;
        return Array.prototype.slice.call(t.content.querySelectorAll('.treebar-board'));
    }
    // Apply every board in `html` to the live board with the same id; returns
    // how many were applied (or dropped because that board is paused). The
    // single client entry point for any transport — polls and htmx WebSocket
    // frames route through it; SSE or custom sockets can call it directly.
    function updateBoards(html){
        var n = 0;
        parseBoards(html).forEach(function(incoming){
            var board = incoming.id && document.getElementById(incoming.id);
            if (!board || !board.classList.contains('treebar-board')) return;
            n += 1;
            if (board.dataset.paused !== '1') reconcileBoard(board, incoming);
        });
        return n;
    }
    window.treebarUpdateBoard = updateBoards;
    // Board polls: htmx would replace the board (the no-script fallback the
    // poll element's hx-target/hx-select describe); hand the response to the
    // reconciler instead.
    document.addEventListener('htmx:beforeSwap', function(evt){
        var d = evt.detail || {};
        if (!d.shouldSwap) return;
        // detail.elt is the swap TARGET here; the requester is on requestConfig.
        var el = (d.requestConfig && d.requestConfig.elt) || d.elt;
        var board = el && el.classList && el.classList.contains('treebar-board-poll') ?
            el.closest('.treebar-board') : d.target;
        if (!board || !board.classList || !board.classList.contains('treebar-board')) return;
        d.shouldSwap = false;
        if (board.dataset.paused === '1') return;
        var incoming = parseBoards(d.serverResponse).filter(function(b){ return b.id === board.id; })[0];
        if (incoming) reconcileBoard(board, incoming);
    });
    // WebSocket boards (htmx ws extension, see ws_board): same reconciler.
    document.addEventListener('htmx:wsBeforeMessage', function(evt){
        if (updateBoards(evt.detail && evt.detail.message) > 0) evt.preventDefault();
    });
    // Remember a board item's tree expansion on its wrapper (toggle does not
    // bubble, hence the capture listener).
    document.addEventListener('toggle', function(evt){
        var d = evt.target;
        if (!d.classList || !d.classList.contains('treebar-board-tree')) return;
        var item = d.closest('.treebar-board-item');
        if (item) item.dataset.open = d.open ? '1' : '0';
    }, true);
    // Pause: cancel a poller's own `every Xs` poll request while its wrapper
    // is data-paused. Scoped to the .treebar-poller-inner element, so the
    // Stop/cancel request (a different element) still fires when paused. The
    // `every` timer keeps rescheduling, so resume needs no re-arming. Keyed
    // on closest('.treebar-poller') → self-contained per poller (nested
    // pollers each govern their own polling).
    document.addEventListener('htmx:beforeRequest', function(evt){
        var el = evt.detail && evt.detail.elt;
        if (el && el.classList.contains('treebar-poller-inner')){
            var p = el.closest('.treebar-poller');
            if (p && p.dataset.paused === '1') evt.preventDefault();
        }
        // A board's poll element pauses the same way, keyed on its board.
        if (el && el.classList.contains('treebar-board-poll')){
            var b = el.closest('.treebar-board');
            if (b && b.dataset.paused === '1') evt.preventDefault();
        }
    });
    function start(){
        // The ONE full-document pass: seeds both live sets. Everything
        // after this is incremental (scoped swap refresh + observer).
        collect(document);
        if (!window.__tbObserverStarted){
            window.__tbObserverStarted = true;
            tbObserver.observe(document.documentElement, {childList: true, subtree: true,
                attributes: true, attributeFilter: ['data-treebar-status', 'data-elapsed-ms', 'data-eta-ms']});
        }
        reanchorAndTick();
        if (!window.__tbTickerStarted){ window.__tbTickerStarted = true; setInterval(tickAll, 100); }
    }
    if (document.readyState === 'loading'){
        document.addEventListener('DOMContentLoaded', start);
    } else {
        start();
    }
})();
"""))

# `_flatten_displayed_children` now lives in Treebars core (src/implementation.jl)
# and is imported above — the core text renderer (`render_text`) shares it, so
# the text dump and this HTML render can never disagree about which nodes exist.

# Render a StateProgress node as HTML. `scoped=false` (used internally by
# polling_fetchindex) suppresses data-show-* attrs on inner .treebar-children,
# so the .treebar-poller wrapper's descendant CSS rule controls visibility
# globally without inner direct-child rules fighting it.
#
# `seen` is a per-render-pass identity set used to dedup a node that DO's
# substatus fan-out attaches under more than one parent within one tree (see
# `Treebars._first_seen!`). Defaulted fresh here so every top-level call to
# `htmx_render` (a one-shot render, a poll, a ws frame) starts its own pass;
# threaded explicitly into every recursive call below so the SAME pass shares
# one `seen` all the way down.
#
# Transparent passthrough: an undisplayed node renders to the empty fragment.
# Its children are hoisted to the parent's level by
# `_flatten_displayed_children`, so a transparent node is normally never
# reached here — this branch is the safety net for direct calls.
function htmx_render(node::ProgressNode{<:StateProgress}; article=false, scoped=true, seen::Base.IdSet{ProgressNode}=Base.IdSet{ProgressNode}(), kwargs...)
    is_displayed(node) || return ""
    sp = node.impl
    children_node = isempty(node.children) ? "" : htmx_render_children(node; scoped, seen)
    lock(sp.lock) do
        duration_node = _duration_span(sp)
        interrupt_node = _interrupt_span(node)
        pending = is_pending(sp)
        node_class = pending      ? "treebar-node treebar-pending" :
                     is_skipped(sp) ? "treebar-node treebar-skipped" :
                                    "treebar-node"
        if !isnothing(sp.N)
            # Progress bar with counter (pending → value=0, max=N, dim)
            h.div(class=node_class)(
                h.div(class="treebar-header")(
                    h.span(class="treebar-description")("$(sp.description):"),
                    h.span(class="treebar-count")("$(sp.i) / $(sp.N)"),
                    !isempty(sp.message) ? h.span(class="treebar-message")(sp.message) : "",
                    duration_node,
                    interrupt_node,
                ),
                h.progress(value=string(sp.i), max=string(sp.N), class="treebar-progress")(),
                children_node,
            )
        elseif !isempty(sp.message)
            header_text = isempty(sp.description) ? sp.message : "$(sp.description) $(sp.message)"
            h.div(class=node_class)(
                h.div(class="treebar-header")(header_text,
                    get(node.meta, :annotation, false) ? "" : duration_node, interrupt_node),
                children_node,
            )
        else
            if article
                # Nested container node
                h.article(class=node_class)(
                    !isempty(sp.description) ? h.header(class="treebar-header")(sp.description, duration_node, interrupt_node) : "",
                    children_node,
                )
            else
                # Nested container node
                h.div(class=node_class)(
                    !isempty(sp.description) ? h.div(class="treebar-header")(sp.description, duration_node, interrupt_node) : "",
                    children_node,
                )
            end
        end
    end
end

# Render a full progress tree rooted at node. Top-level root is always
# rendered (the wrapper div), but transparent children at this level are
# flattened away — their grandchildren render in their place. Same per-pass
# `seen` dedup as the StateProgress method above (kept in sync for any
# non-StateProgress backend that reaches this fallback).
function htmx_render(node::ProgressNode; scoped=true, seen::Base.IdSet{ProgressNode}=Base.IdSet{ProgressNode}(), kwargs...)
    children = filter(c -> _first_seen!(seen, c), _flatten_displayed_children(node))
    children_html = [htmx_render(child; scoped, seen, kwargs...) for child in children]
    h.div(class="treebar-root")(children_html...)
end

node_to_html(node) = sprint(io -> show(io, MIME"text/html"(), node))

# Pill onclick: prefer the persistent wrapper — a .treebar-poller, or a
# .treebar-board-item on a board — so toggles survive across updates; fall back
# to the closest .treebar-children for static one-shot renders (no wrapper in
# scope). The two-step `closest` (rather than one comma selector over all three)
# is intentional — `closest('.treebar-poller, .treebar-children')` returns
# whichever is the closer ancestor, which is always .treebar-children. The two
# wrappers share one selector: the nearer one governs its own subtree.
_pill_onclick(key) = """var s = this.closest('.treebar-poller, .treebar-board-item') || this.closest('.treebar-children'); if(!s) return; s.dataset.$(key) = s.dataset.$(key) === '1' ? '0' : '1';"""

# Render just the children of a ProgressNode (for top-level substatus display).
# When `scoped=true` (default) the wrapper carries data-show-* attrs so pills
# at this level toggle visibility scoped to this .treebar-children. Inside a
# .treebar-poller (polling_fetchindex passes `scoped=false`) we suppress
# those attrs so the wrapper's descendant CSS rule controls visibility
# without inner direct-child rules fighting it.
#
# `seen` (see `htmx_render` above) is applied HERE, in the child walk: the
# flattened child list is filtered against the pass's `seen` set BEFORE pill
# counts/grouping, so a node already rendered earlier in this same pass (a
# different parent reached it first) is dropped from this level entirely —
# no stray pill count, no duplicate render.
htmx_render_children(::Nothing; kwargs...) = h.p("Starting..."; class="u-text-muted", aria_busy="true")
function htmx_render_children(node::ProgressNode{<:StateProgress}; scoped=true, seen::Base.IdSet{ProgressNode}=Base.IdSet{ProgressNode}())
    sp = node.impl
    # Flatten transparent children: each undisplayed child contributes
    # its own children at this level instead of itself. Grouping/pills/
    # CSS classes all see the hoisted view, which is the whole point of
    # the transparent flag. Then dedup (first-seen-wins) against this pass's
    # `seen` set.
    raw = _flatten_displayed_children(node)
    children = filter(c -> _first_seen!(seen, c), raw)
    # All of this node's children were already rendered elsewhere in this same
    # pass (DO's shared-substatus co-tree case) — the children SECTION is
    # empty, but unlike "genuinely no children yet" this isn't a pending/
    # spinner state, so emit nothing rather than fall into the message/
    # "Starting..." fallback below. The node's own header/duration still
    # render via the caller (`htmx_render`) — only this children section is
    # suppressed.
    isempty(children) && !isempty(raw) && return ""
    # A terminal node cannot still be starting or busy. This is reachable when
    # raw children exist but every one flattens away (for example, hidden leaf
    # nodes); the caller sees a non-empty `node.children` and therefore asks us
    # to render a children section even though there is nothing visible in it.
    if isempty(children) && (is_finished(sp) || is_failed(sp) || is_skipped(sp))
        return ""
    end
    if isempty(children) && !isempty(sp.message)
        return h.div(
            h.span(sp.message; class="u-text-muted"),
            h.span(" "; aria_busy="true"),
        )
    end
    isempty(children) && return h.p("Starting..."; class="u-text-muted", aria_busy="true")

    n_finished = count(c -> is_finished(c), children)
    n_failed = count(c -> is_failed(c), children)
    n_pending = count(c -> is_pending(c), children)
    n_skipped = count(c -> is_skipped(c), children)

    pills = Node[]
    if n_pending > 0
        push!(pills, h.span(class="treebar-pill treebar-pill-pending",
            onclick=_pill_onclick("showPending"))("$(n_pending) pending"))
    end
    if n_finished > 0
        push!(pills, h.span(class="treebar-pill treebar-pill-finished",
            onclick=_pill_onclick("showFinished"))("$(n_finished) finished"))
    end
    if n_skipped > 0
        push!(pills, h.span(class="treebar-pill treebar-pill-skipped",
            onclick=_pill_onclick("showSkipped"))("$(n_skipped) skipped"))
    end
    if n_failed > 0
        push!(pills, h.span(class="treebar-pill treebar-pill-failed",
            onclick=_pill_onclick("showFailed"))("$(n_failed) failed"))
    end

    # Every terminal state is named EXPLICITLY and `running` is the residual.
    # This used to be an if/elseif chain whose bare `else` meant *failed*, so
    # any state added later fell into it and rendered as a failure in the
    # browser while `render_text` rendered it correctly — a fifth state would
    # have silently inverted its own meaning. Running is the right residual:
    # it is the one state that legitimately renders with no wrapper div.
    _child_class(c) =
        is_pending(c)  ? "treebar-child-pending"  :
        is_skipped(c)  ? "treebar-child-skipped"  :
        is_finished(c) ? "treebar-child-finished" :
        is_failed(c)   ? "treebar-child-failed"   :
                         ""
    rendered = map(children) do child
        cls = _child_class(child)
        inner = htmx_render(child; scoped, seen)
        isempty(cls) ? inner : h.div(class=cls)(inner)
    end

    # Static one-shot renders (no .treebar-poller wrapper in scope) need the
    # data attrs here so pills at this level can toggle visibility against
    # this scope. Inside a poller we leave them off so only the wrapper's
    # descendant CSS rule applies — otherwise the inner direct-child rule
    # would keep hiding finished children even after the wrapper toggle flips.
    if scoped
        h.div(class="treebar-children",
            data_show_finished="0",
            data_show_pending="1",
            data_show_failed="1",
            # Hidden by default, like finished: both are terminal and there is
            # nothing left to do about them. The "N skipped" pill is what says
            # they exist, so a completed request shows only what actually ran.
            data_show_skipped="0")(
            isempty(pills) ? "" : h.div(class="treebar-pills")(pills...),
            rendered...,
        )
    else
        h.div(class="treebar-children")(
            isempty(pills) ? "" : h.div(class="treebar-pills")(pills...),
            rendered...,
        )
    end
end

"""
    htmx_ws_render(node; id="treebar-progress")

Default `render` function for `ws_progress` when HTMXObjects is loaded.
Returns an HTML string with a stable `id` so the HTMX ws extension swaps by element id.

Client-side:
```html
<div hx-ext="ws" ws-connect="/ws/progress">
    <div id="treebar-progress"></div>
</div>
```
"""
htmx_ws_render(node::ProgressNode; id="treebar-progress") = node_to_html(h.div(; id)(htmx_render(node)))

function htmx_ws_progress(content; url::AbstractString, id::AbstractString,
        progress=nothing, description="Working...", N=nothing, collapsed::Bool=false)
    isempty(id) && throw(ArgumentError("htmx_ws_progress requires a nonempty unique id"))
    node = isnothing(progress) ?
        initialize_progress!(:state; description, N, pending=true) : progress
    h.div(; hx_ext="ws", ws_connect=url)(
        content,
        h.details(; id=id * "-disclosure", open=(collapsed ? nothing : true))(
            h.summary("Progress"),
            h.div(; id=id * "-progress")(htmx_render(node))),
        h.div(; id=id * "-updates")(),
    )
end

_ws_progress_root(::Nothing, N; description) = initialize_progress!(:state; description, N)
_ws_progress_root(parent::ProgressNode, ::Nothing; description) =
    initialize_progress!(parent; description, transient=false)
_ws_progress_root(parent::ProgressNode, N::Integer; description) =
    initialize_progress!(parent, N; description, transient=false)

function _validate_ws_progress(id, interval, buffer)
    isempty(id) && throw(ArgumentError("ws_progress requires a nonempty unique id"))
    interval > 0 || throw(ArgumentError("ws_progress interval must be positive"))
    buffer > 0 || throw(ArgumentError("ws_progress buffer must be positive"))
end

# A published fragment carrying `hx-swap-oob` targets an element OUTSIDE the
# stream sink. The htmx ws extension runs oobSwap over TOP-LEVEL message
# children only, so such a node must be delivered as a top-level sibling —
# nested inside the `<id>-updates` wrapper it lands verbatim in the sink
# (snag ws-progress-publ-d1b74c9b). HTMX hyphenates builder kwargs, so
# `hx_swap_oob=...` is stored as `Symbol("hx-swap-oob")`; the `data-` prefixed
# spelling is htmx-equivalent and honored too. Raw/String fragments always sink.
_is_oob_fragment(f) = f isa Node &&
    (haskey(f.attrs, Symbol("hx-swap-oob")) || haskey(f.attrs, Symbol("data-hx-swap-oob")))

function _ws_progress_frame(id, progress, fragments)
    payload = htmx_ws_render(progress; id=id * "-progress")
    isempty(fragments) && return payload
    plain = Any[]
    oob = Any[]
    for f in fragments
        if _is_oob_fragment(f)
            push!(oob, f)
        else
            push!(plain, f)
        end
    end
    isempty(plain) || (payload *= node_to_html(h.div(; id=id * "-updates")(plain...)))
    for f in oob
        payload *= node_to_html(f)
    end
    payload
end

function ws_progress(produce::Function, ws::WebSocket; id::AbstractString,
        description="Working...", N=nothing, parent=nothing, interval=0.1, buffer::Integer=64)
    _validate_ws_progress(id, interval, buffer)
    node = _ws_progress_root(parent, N; description)
    ws_progress(produce, ws, node; id, interval, buffer)
end

function ws_progress(produce::Function, ws::WebSocket, node::ProgressNode{<:StateProgress};
        id::AbstractString, interval=0.1, buffer::Integer=64)
    _validate_ws_progress(id, interval, buffer)
    (is_pending(node) || is_running(node)) ||
        throw(ArgumentError("ws_progress producer requires a pending or running node"))
    start_progress!(node)
    queue = Channel{Any}(buffer)
    connected = Threads.Atomic{Bool}(true)
    publish = fragment -> begin
        connected[] || return nothing
        try
            put!(queue, fragment)
        catch err
            # Closing the queue releases a blocked publisher on disconnect.
            connected[] && rethrow()
            err isa InvalidStateException || rethrow()
        end
        nothing
    end
    # Render outside the send catch: serialization errors are not disconnects.
    initial = htmx_ws_render(node; id=id * "-progress")
    try
        send(ws, initial)
    catch err
        connected[] = false
        close(queue)
        @debug "ws_progress client disconnected before production" exception=(err, catch_backtrace())
    end
    producer = Threads.@spawn begin
        try
            produce(publish, node)
        catch err
            fail_progress!(node, err)
            rethrow()
        finally
            finalize_progress!(node)
        end
    end
    render_live = progress -> begin
        fragments = Any[]
        for _ in 1:buffer
            isready(queue) || break
            push!(fragments, take!(queue))
        end
        _ws_progress_frame(id, progress, fragments)
    end
    result = nothing
    try
        connected[] && ws_progress(ws, node; interval, render=render_live)
    finally
        connected[] = false
        isopen(queue) && close(queue)
        # Observe producer failures even when delivery or rendering failed.
        result = fetch(producer)
    end
    result
end

# --- Keyed board ---------------------------------------------------------------
#
# A board is a keyed, changing collection of progress trees (a "running jobs"
# list). The server always renders the FULL current list; the client script
# (`htmx_treebar_script`) reconciles it into the live board by
# `data-treebar-key`, so each `.treebar-board-item` wrapper — and the UI state on
# it — persists while only its content is replaced. See `htmx_render_board` in
# src/interface.jl for the entry contract.

const _BOARD_STATES = (:queued, :running, :done, :failed)

# Entries are NamedTuples by contract; any object with the same properties works.
_board_get(entry, name::Symbol, default) =
    hasproperty(entry, name) ? getproperty(entry, name) : default

# `meta` is a NamedTuple / Dict of label => value, or any iterable of Pairs.
_board_meta_pairs(meta::Union{NamedTuple,AbstractDict}) = [string(k) => v for (k, v) in pairs(meta)]
_board_meta_pairs(::Nothing) = Pair{String,Any}[]
_board_meta_pairs(meta) = [string(first(p)) => last(p) for p in meta]

_board_blank(v) = v === nothing || v === missing || (v isa AbstractString && isempty(v))
_board_value(v) = v isa Node || v isa AbstractString ? v : string(v)

_board_ms(::Nothing) = 0
_board_ms(ms::Real) = isfinite(ms) ? max(0, round(Int, ms)) : 0
_board_ms(p::Dates.Period) = max(0, Dates.value(convert(Millisecond, p)))

# Header duration. The same `.treebar-duration` contract as a tree node, so a
# running item ticks locally between updates through the existing ticker; the
# extra class lets the reconciler find the header span when it ends an item.
# A queued item reads like a pending node — no clock, just its queue position.
function _board_duration_span(state::Symbol, ms::Int, position)
    d = short_duration(Millisecond(ms))
    cls = "treebar-duration treebar-board-duration"
    if state === :queued
        text = isnothing(position) ? " — queued" : " — queued · #$(position)"
        return h.span(class=cls, data_treebar_status="pending")(text)
    end
    status, text = state === :running ? ("running", " — $(d) so far") :
                   state === :done    ? ("finished", " — done ($(d))") :
                                        ("failed", " — failed ($(d))")
    h.span(class=cls, data_treebar_status=status, data_elapsed_ms=string(ms))(text)
end

# The tree collapses under the item header. `scoped=false`: the item wrapper
# carries the data-show-* pill state, like `.treebar-poller` does. A terminal
# item's tree is frozen, so a node it still holds as "running" does not tick.
function _board_tree(node; open::Bool, frozen::Bool)
    body = node isa ProgressNode ? htmx_render(node; scoped=false) : node
    cls = frozen ? "treebar-board-tree treebar-frozen" : "treebar-board-tree"
    open ? h.details(class=cls, open=true)(h.summary("Progress"), body) :
           h.details(class=cls)(h.summary("Progress"), body)
end

function _board_item(entry; expanded::Bool)
    state = Symbol(entry.state)
    state in _BOARD_STATES || throw(ArgumentError(
        "board entry state must be one of $(_BOARD_STATES) (got $(repr(entry.state)))"))
    ms = _board_ms(_board_get(entry, :elapsed_ms, 0))
    node = _board_get(entry, :node, nothing)
    href = _board_get(entry, :href, nothing)
    meta = _board_meta_pairs(_board_get(entry, :meta, ()))
    # `position` is the queue position a queued item's state text shows; it is
    # not repeated as a meta item.
    position = nothing
    shown = Node[]
    for (k, v) in meta
        if k == "position"
            position = _board_blank(v) ? nothing : v
            continue
        end
        _board_blank(v) && continue
        push!(shown, h.span(class="treebar-board-meta-item")(
            h.span(class="treebar-board-meta-key")(k), " ", _board_value(v)))
    end
    label = string(entry.label)
    label_node = isnothing(href) ?
        h.strong(class="treebar-board-label")(label) :
        h.a(class="treebar-board-label", href=string(href))(label)
    h.div(class="treebar-board-item",
        data_treebar_key=string(entry.key),
        data_treebar_state=string(state),
        data_open=expanded ? "1" : "0",
        data_show_finished="0",
        data_show_pending="1",
        data_show_failed="1",
        data_show_skipped="0")(
        h.div(class="treebar-board-item-content")(
            h.div(class="treebar-board-item-header")(
                label_node,
                _board_duration_span(state, ms, position),
                isempty(shown) ? "" : h.div(class="treebar-board-meta")(shown...),
            ),
            isnothing(node) ? "" : _board_tree(node; open=expanded, frozen=state in (:done, :failed)),
        ),
    )
end

# Board-level Pause: toggles data-paused on the board; the script then cancels
# its poll requests, drops pushed frames, freezes its clocks and holds lingering
# items — the `.treebar-pause` mechanism, keyed on the board.
_board_pause_button() = h.button(class="treebar-board-pause", type="button",
    onclick="var b=this.closest('.treebar-board'); if(!b) return; var v=b.dataset.paused==='1'?'0':'1'; b.dataset.paused=v; this.textContent=v==='1'?'Resume':'Pause';")("Pause")

function _board_count(entries)
    n_running = count(e -> Symbol(e.state) === :running, entries)
    n_queued = count(e -> Symbol(e.state) === :queued, entries)
    text = n_queued == 0 ? "$(n_running) running" : "$(n_running) running · $(n_queued) queued"
    h.span(class="treebar-board-count", data_running=string(n_running),
           data_queued=string(n_queued))(text)
end

function htmx_render_board(entries; poll_url=nothing, poll_interval="1s",
        empty="No running jobs.", id="treebar-board", linger_ms::Integer=3000,
        expanded::Bool=false, live::Bool=!isnothing(poll_url))
    # First occurrence of a key wins: the client matches items by key, so a
    # duplicate would make two DOM items fight over one identity.
    seen = Set{String}()
    unique_entries = [e for e in entries if !(string(e.key) in seen) && (push!(seen, string(e.key)); true)]
    items = [_board_item(e; expanded) for e in unique_entries]
    # The poll element's hx-target/hx-select describe the no-script fallback
    # (replace the whole board); with `htmx_treebar_script` loaded, the
    # `htmx:beforeSwap` hook hands the response to the keyed reconciler instead.
    poller = isnothing(poll_url) ? "" :
        h.div(class="treebar-board-poll",
            hx_get=string(poll_url),
            hx_trigger="every $poll_interval",
            hx_target="closest .treebar-board",
            hx_swap="outerHTML",
            hx_select="#$(id)")()
    empty_node = isempty(items) ?
        h.p(class="treebar-board-empty")(empty) :
        h.p(class="treebar-board-empty", hidden=true)(empty)
    h.div(class="treebar-board", id=string(id), data_paused="0",
          data_treebar_linger_ms=string(linger_ms))(
        h.div(class="treebar-board-header")(
            _board_count(unique_entries),
            live ? _board_pause_button() : "",
        ),
        h.div(class="treebar-board-list")(items...),
        empty_node,
        poller,
    )
end

htmx_ws_render_board(entries; kwargs...) =
    node_to_html(htmx_render_board(entries; live=true, kwargs..., poll_url=nothing))

function ws_board(ws::WebSocket, entries; interval=1.0, until=() -> false, kwargs...)
    while true
        stop = until()
        frame = htmx_ws_render_board(entries(); kwargs...)
        try
            send(ws, frame)
        catch
            break   # client gone
        end
        stop && break
        sleep(interval)
    end
    nothing
end

"""
    polling_fetchindex(render_result, ip, keys...; poll_context=nothing, poll_url=nothing, label=nothing, force=false, poll_interval="200ms", cancel_url="", sync=false, keep_progress=true, error_obj=nothing, req=nothing, parent=:auto, chrome=:auto, track_job=true, kwargs...)

Generic fetchindex + HTMX polling pattern. Renders the running progress
inside a `.treebar-poller` wrapper containing a `.treebar-poller-inner`
element that carries the polling attributes (`hx-trigger="every Xs [!document.hidden]"
hx-target="this" hx-swap="outerHTML"` — the filter stops a hidden document
from polling for nobody; a returning tab is at most one interval stale). The wrapper also carries one
`.treebar-badge`: a hairline strip plus a panel (pause/play control, poll
label, status word, progress bar, elapsed) above the live tree. The panel
and tree render expanded by default, so a first-load region shows progress
immediately; pass `chrome=:quiet` to collapse a poller to the hairline
strip that expands on hover/focus (emitted as `data-chrome="quiet"`),
and a poller diverted into HTMXObjects' live-refresh reporter is quiet
automatically. On each poll the inner self-swaps; once the task is done,
the response replaces the inner with `.treebar-terminal-content`, which
naturally stops the loop. The client then renames the stable wrapper to
`.treebar-terminal`, removes its polling UX state and badge, and leaves
the rendered result (plus optional frozen progress record) as an
unambiguous terminal fragment. While polling, the wrapper itself is
untouched, so UX state on it (`data-show-finished` / `-failed` /
`-pending`, set by pill clicks, and `data-chrome`) persists across polls.

The inner's `hx-select` is top-level-only: each branch excludes matches
nested inside another match, so a poll response containing a nested poller
(an explicit `polling_fetchindex` under an `:auto` root, or a finished nested
fragment inside a still-running outer poll) swaps exactly the outermost
region instead of duplicating the nested one into a live sibling.

The host page must include [`htmx_treebar_styles`](@ref) and
[`htmx_treebar_script`](@ref) once, normally through `htmx(...;
extra_head=(htmx_treebar_styles(), htmx_treebar_script()))`. The fragment can
still poll without those page assets, but client-owned behavior is then absent:
the badge renders statically above the fully visible tree (no collapse, no
live status mirror), the duration ticker and pause handler are not installed,
and a completed inner swap leaves the persistent wrapper identified as
`.treebar-poller` instead of terminalizing it in place. The badge's pause
control is inert once its poller stops polling, so even an un-terminalized
badge cannot flip its glyph on a finished poller.

Poll requests deliberately inherit ancestor `hx-vals`/form values (no
`hx-params` isolation): HTMXObjects heals a drifted poll by re-executing with
the poll request's current arguments, which requires those arguments to reach
the server.

Failure path (`keep_progress=true`, default): the compute error — re-thrown by
`fetchindex` before this callback runs (compute-at-most-once) — is caught in
`polling_fetchindex`, recorded + rendered through HTMXObjects' `safely` (disk
log + `@error` + the app's `__on_error__`/`__error__` hooks + the opaque "caught
an error" article), and returned alongside the kept tree inside the polling
inner, so polling stops and the tree survives. With `keep_progress=false` the
error propagates to HTMXObjects' route-boundary catch (a 200 HTML error article
that replaces the polling inner, discarding the tree). Either way polling stops
naturally — no custom OOB / HX-Retarget gymnastics.

- `render_result(rv)`: function that renders the final result (supports `do` syntax)
- `ip`: IndexableProperty (e.g. `app.pathfinder`)
- `keys...`: cache key(s) (variadic — supports multi-index like `f1, f2`)
- `poll_context`: HTMX route struct (`__self__`). When provided, derives `poll_url`
  via `query_url(poll_context; force=false)` and `force` from `poll_context.force`.
  Overrides explicit `poll_url` and `force` kwargs.
- `poll_url`: URL to poll while running (use `query_url`). Ignored when `poll_context` is set.
- `label`: display label (e.g. "Pathfinder (my-model)"). When it equals the
  status root's description, the badge-label and interim-header copies are
  omitted — the root header already carries the string — and the badge
  elapsed is omitted whenever the root row renders its own duration span.
- `force`: force re-computation (default `false`). Ignored when `poll_context` is set.
- `poll_interval`: HTMX polling interval (default "200ms")
- `cancel_url`: optional URL for a "Stop" button shown while running (default `""` = no button).
  Treebars only renders the button (pointing at the caller-provided `cancel_url`).
  NOTE: DynamicObjects' `cancel!` was removed with the compute-at-most-once
  refactor, so an in-flight compute now always runs to completion — the button
  is inert unless the caller's `cancel_url` route does something itself.
- `keep_progress`: keep the finished/failed tree for post-hoc inspection (default
  `true`). On success the frozen tree is appended below the result in a collapsed
  `<details>`. On failure the tree (with the failed node) is shown in an open
  `<details>` beside the recorded error. Set `false` for the old result-only /
  propagate-on-failure behavior; ignored on the `sync` path.
- `error_obj` / `req`: route context threaded to `safely` on the failure path
  (its `obj` for `__on_error__`/`__error__`, its `req` for log metadata).
  Auto-derived from `poll_context`; pass explicitly otherwise. Both optional.
- `parent`: `Treebars.ProgressNode`, `nothing`, or `:auto` (default). When
  a node, the IP compute's live substatus tree hangs under this caller-owned
  node (mirroring DO's `fetchindex!(parent, ip, …)` attachment), so an outer
  `dispatch` or `@progress` job tree shows the embed's real compute as
  children instead of the poller running detached on the IP's own
  `__status__` root. `:auto` resolves the dispatch caller automatically —
  the request's dispatch node first (`HTMXObjects.dispatch_parent(req)`,
  when `req` is passed or derived from `poll_context`), else the ambient
  node `dispatch` bound (`Treebars.current_dispatch_parent`), else detached.
  An explicit `parent=` always wins; pass `nothing` to force detached (the
  historical default behavior). Ignored when the compute was already cached
  (no live substatus to attach); the subtree still detaches from the caller
  on transient finalize, exactly as DO's own `fetchindex!` attachment does.
- `chrome`: `:auto` (default) or `:quiet`. `:auto` renders the badge panel
  and live tree expanded — a first-load region shows progress immediately.
  `:quiet` emits `data-chrome="quiet"` on the wrapper, collapsing the
  poller to the hairline strip (hover/focus expands it); use it for a
  poller beside already-visible content. A poller diverted into
  HTMXObjects' live-refresh reporter is quiet by stylesheet rule either
  way. Anything else throws `ArgumentError`.
- `track_job`: when a poller is emitted for in-flight work, report the compute
  to HTMXObjects' job ledger through `HTMXObjects.track_job!` (with `label`,
  the progress tree and `req`), so hand-rolled pollers appear on the runtime
  dashboard and job boards (default `true`). Skipped on HTMXObjects generations
  without that API; a tracking failure never affects the poller. HTMXObjects'
  own operation transport passes `false` — it records its jobs itself.
- `kwargs...`: passed through to `fetchindex`
"""
# Resolve the `parent=:auto` default: the request's dispatch node first (the
# explicitly-passed `req` is the most local statement of dispatch context,
# and it survives the spawned-task boundary that task-local storage does not
# cross on Julia 1.10), else the ambient node `dispatch` bound, else
# detached. The `applicable` guard keeps this inert on HTMXObjects
# generations predating the public `dispatch_parent` accessor (and on
# non-request `req` values): no resolve, no throw — the poller just stays
# detached, exactly as before. The `parent isa ProgressNode` filter at the
# attach site stays the single type gate for whatever this returns.
function _polling_default_parent(req)
    if req !== nothing && isdefined(HTMXObjects, :dispatch_parent) &&
            applicable(HTMXObjects.dispatch_parent, req)
        node = HTMXObjects.dispatch_parent(req)
        node !== nothing && return node
    end
    current_dispatch_parent()
end
function polling_fetchindex(render_result, ip, keys...; poll_context=nothing, poll_url=nothing, label=nothing, force=false, poll_interval="200ms", cancel_url="", sync=false, keep_progress=true, error_obj=nothing, req=nothing, parent=:auto, chrome=:auto, track_job=true, kwargs...)
    chrome in (:auto, :quiet) || throw(ArgumentError("polling_fetchindex: chrome must be :auto or :quiet, got $(repr(chrome))"))
    if !isnothing(poll_context)
        poll_url = HTMXObjects.query_url(poll_context; force=false)
        force = poll_context.force
        # The route struct doubles as the failure-path error context (its
        # __on_error__/__error__ hooks + __req__ for the log), unless the caller
        # passed error_obj/req explicitly.
        isnothing(error_obj) && (error_obj = poll_context)
        isnothing(req) && hasproperty(poll_context, :__req__) && (req = poll_context.__req__)
    end
    # Default-parent resolution (snag make-htmxobjects-7960c091): an absent
    # `parent` follows the dispatch caller; an explicit node — or an explicit
    # `nothing` to force detached — always wins. Resolved here, after the
    # poll_context block, so a derived `req` feeds the request leg.
    parent === :auto && (parent = _polling_default_parent(req))
    # keep_progress: a failed compute is re-thrown by fetchindex BEFORE the
    # callback runs (compute-at-most-once), so wrap the call to catch it, pull
    # the (failed) tree via getstatus, and render the recorded error + tree
    # rather than let the throw reach HTMXObjects' route-boundary catch (which
    # would discard the tree). keep_progress=false (or sync) re-throws as before.
    try
        fetchindex(ip, keys...; force, kwargs...) do rv, status
            # Parent passthrough (snag hang-pdf-embed-c-d79aad34): hang the
            # live substatus under the caller's node so the embed's compute
            # tree renders in the caller's tree. `add_child!` is idempotent on
            # the ThreadsafeSet; `nothing` status = cached/no-live-substatus
            # (a no-op). The subtree still detaches on transient finalize, so
            # this gives the caller the LIVE view, not a post-hoc history.
            (parent isa ProgressNode && !isnothing(status)) && add_child!(parent, status)
            # About to emit a poller for in-flight work: report it to
            # HTMXObjects' job ledger (runtime dashboard / job boards).
            track_job && !sync && _is_unresolved_handle(rv) &&
                _track_job(rv, status, ip; label, req)
            _polling_resolve(rv, status; label, poll_url, poll_interval, cancel_url, render_result, sync, keep_progress,
                             ip_ctx=_ip_ctx(ip, keys, kwargs), chrome=chrome)
        end
    catch err
        (keep_progress && !sync) || rethrow()
        _polling_wrap(_polling_inner_done(_caught_error_ex(err, error_obj, req),
                                          _kept_progress(HTMXObjects.getstatus(ip, keys...; kwargs...); open=true));
                      terminal=true)
    end
end

# DynamicObjects' in-flight handles implement both `Base.isready` and
# `Base.fetch`. Detect that protocol instead of resolving a concrete `Pending`
# type while this extension module is being defined: Treebars should still load
# when HTMXObjects changes where (or whether) it exposes DynamicObjects' handle
# type. `Task` is the previous fetch contract and needs its own readiness test.
#
# `_is_handle` is the readiness-AGNOSTIC companion: does `rv` present the handle
# protocol AT ALL? A resolved VALUE presents neither `isready` nor `fetch`; a DO
# `Pending` (and `Task`/`Future`/`Channel`) presents both. `_is_unresolved_handle`
# is then just "a handle that is not yet ready". The done path (below) needs the
# agnostic form: a handle reaching it is by definition READY (every not-ready one
# took the poll/fetch branch), and `_is_unresolved_handle` cannot see it.
_is_handle(rv::Task) = true
_is_handle(rv) = applicable(Base.isready, rv) && applicable(Base.fetch, rv)
_is_unresolved_handle(rv::Task) = !istaskdone(rv)
_is_unresolved_handle(rv) = _is_handle(rv) && !Base.isready(rv)

# A READY handle reaching the done path must be RESOLVED, never rendered raw.
# DynamicObjects chooses `Pending` from a cache snapshot, then invokes the
# fetchindex callback. The compute may legally finish between those two events,
# so the callback can receive a handle whose value is already ready. `_is_handle`
# proves that the object presents the complete `isready`/`fetch` protocol; fetch
# it silently and let only the VALUE reach `render_result`. A partial or otherwise
# incompatible object does not satisfy that protocol and is not normalized here.

# Keep the old Task contract working while DynamicObjects consumers migrate.
_polling_resolve(rv::Task, status; sync=false, keep_progress=true, label, poll_url, poll_interval, cancel_url, render_result, ip_ctx="", chrome=:auto) =
    istaskfailed(rv) ? throw(rv.result) :
    sync ? _polling_resolve(fetch(rv), status; sync, keep_progress, label, poll_url, poll_interval, cancel_url, render_result, ip_ctx, chrome) :
        _polling_running(status; label, poll_url, poll_interval, cancel_url, chrome)

# Report a hand-rolled poller's in-flight compute to HTMXObjects' job ledger
# (`HTMXObjects.track_job!`), so it shows on the runtime dashboard and job
# boards like the operations HTMXObjects starts itself. Guarded twice over: an
# HTMXObjects generation without the ledger API is skipped, and a ledger
# failure never reaches the poller. The label never carries the cache keys —
# they are request data — only the caller's label, the tree's own
# description, or the property name.
function _track_job(handle, status, ip; label=nothing, req=nothing)
    isdefined(HTMXObjects, :track_job!) || return nothing
    try
        HTMXObjects.track_job!(handle; label=_track_job_label(label, status, ip),
                               progress=status, req)
    catch err
        @debug "Treebars: job tracking failed; polling continues" exception=(err, catch_backtrace())
    end
    nothing
end

function _track_job_label(label, status, ip)
    isnothing(label) || return string(label)
    if status isa ProgressNode{<:StateProgress}
        description = strip(status.impl.description)
        isempty(description) || return String(description)
    end
    try
        string(HTMXObjects.DynamicObjects.name(ip))
    catch
        "Job"
    end
end

# Human-readable "which IP, which key" for the unresolved-handle error below.
# Best-effort: an IP that does not expose `name`/`o` still yields a usable string.
function _ip_ctx(ip, keys, kwargs)
    ipname = try
        string(HTMXObjects.DynamicObjects.name(ip))
    catch
        string(typeof(ip))
    end
    kwstr = isempty(kwargs) ? "" : "; " * join(("$k=$(repr(v))" for (k, v) in pairs(kwargs)), ", ")
    "$ipname($(join((repr(k) for k in keys), ", "))$kwstr)"
end

# Done — already-cached or just-completed. A first-call-done response is born
# terminal. On running-then-done the response replaces the polling inner and
# the client terminalizes the stable wrapper in place. With keep_progress
# (default, but not on the sync loopback), the frozen tree is appended below
# the result in a collapsed <details>.
function _polling_resolve(rv, status; sync=false, keep_progress=true, label, poll_url, poll_interval, cancel_url, render_result, ip_ctx="", chrome=:auto)
    if _is_unresolved_handle(rv)
        return sync ?
            _polling_resolve(fetch(rv), status; sync, keep_progress, label, poll_url, poll_interval, cancel_url, render_result, ip_ctx, chrome) :
            _polling_running(status; label, poll_url, poll_interval, cancel_url, chrome)
    end
    # A READY handle must never reach render_result raw — resolve it here. This is
    # the guard that `e6f140f` dropped (it deleted `_assert_resolved` and traded
    # Pending-type dispatch for the not-ready duck-test above, which cannot see a
    # ready handle). A compatible ready handle is a legal completion race, so it
    # is normalized silently rather than diagnosed as package skew.
    if _is_handle(rv)
        return _polling_resolve(fetch(rv), status; sync, keep_progress, label, poll_url, poll_interval, cancel_url, render_result, ip_ctx, chrome)
    end
    body = render_result(rv)
    (keep_progress && !sync) ?
        _polling_wrap(_polling_inner_done(body, _kept_progress(status; open=false)); terminal=true) :
        _polling_wrap(_polling_inner_done(body); terminal=true)
end

# Frozen progress tree kept in the final (non-polling) response so a finished or
# failed run can be inspected after polling stops. scoped=true → the
# finished/failed/pending pills act as a static inspector; wrapped in a
# <details> (collapsed on success — stays out of the way; open on failure —
# failed node visible). `treebar-frozen` makes the client ticker skip it, so a
# terminal tree still holding a "running" node is static, not counting up.
# Empty string when there is no status node.
function _kept_progress(status; open::Bool=false)
    isnothing(status) && return ""
    body = (h.summary("Progress"), htmx_render(status; scoped=true))
    open ? h.details(class="treebar-frozen", open=true)(body...) : h.details(class="treebar-frozen")(body...)
end

# Record + render a caught compute error THROUGH HTMXObjects' exported `safely`,
# so a keep_progress failure gets the SAME treatment as a route-boundary throw —
# disk log (ERROR_DIR/<uid>.log) + @error + the app's __on_error__/__error__
# hooks + the opaque "caught an error" article — WITHOUT discarding the tree. On
# the compute-at-most-once (Pending) model the failure is re-thrown by fetchindex
# before our callback, so polling_fetchindex catches it and hands the exception
# here; we re-raise inside safely to reuse its record+render. error_obj/req carry
# route context (both may be nothing → default article, no hooks/req-meta). The
# returned article is aria-invalid and sits INSIDE the terminal content — the
# poller's top-level-only hx-select excludes nested matches (see
# `_polling_inner_running`) so htmx does not double-insert it.
_caught_error_ex(err, error_obj, req) =
    HTMXObjects.safely(; obj=error_obj, req=req) do
        throw(err)
    end

# Poller running-face dedup (snag expanded-first-l-360630fb). The badge and
# the tree are co-visible in the expanded default chrome, so a string the
# tree already renders must not be restated above it: when the poller `label`
# equals the status root's description, the badge label, the interim
# "<label> — running..." header, and the root header render one string three
# times — and the badge elapsed always restates the root's duration span.
# The running face omits the redundant copies server-side, so the dedup
# holds with or without the page assets; the tree keeps the single
# surviving copy of each.

# The description the poller tree renders for its own root, or `nothing`
# when the root renders no description row (a status that is nothing,
# non-state, or undisplayed, or a root with an empty description). Mirrors
# `htmx_render`'s header rules — keep in lockstep.
function _status_root_description(status)
    status isa ProgressNode || return nothing
    is_displayed(status) || return nothing
    sp = status.impl
    sp isa StateProgress || return nothing
    return lock(sp.lock) do
        isempty(sp.description) ? nothing : sp.description
    end
end

# True when `htmx_render(status)` emits a `.treebar-duration` span for the
# root itself: a counter, a non-annotation message node, or a described
# container. Mirrors `htmx_render`'s header rules above — keep in lockstep.
function _root_renders_duration(status)
    status isa ProgressNode || return false
    is_displayed(status) || return false
    sp = status.impl
    sp isa StateProgress || return false
    return lock(sp.lock) do
        !isnothing(sp.N) && return true
        !isempty(sp.message) && return !get(status.meta, :annotation, false)
        !isempty(sp.description)
    end
end

# True when the poller `label` restates the status root's description: the
# badge-label and interim-header copies are redundant with the root header.
_label_restates_root(label, status) =
    !isnothing(label) && _status_root_description(status) == string(label)

function _polling_running(status; label, poll_url, poll_interval, cancel_url, chrome=:auto)
    stop_btn = isempty(cancel_url) ? "" : h.a("Stop"; role="button", class="outline secondary treebar-stop",
        hx_get=cancel_url, hx_target="closest div", hx_swap="outerHTML")
    inner_body = if isnothing(label)
        htmx_render(status; article=true, scoped=false)
    elseif _label_restates_root(label, status)
        # The badge and the root header already carry this string — an
        # interim "<label> — running..." header would restate it a third
        # time. Only the redundant header line goes: the article wrapper
        # stays, and a configured Stop control stays inside it.
        h.article(stop_btn, htmx_render(status; scoped=false))
    else
        h.article(h.header("$label — running...", stop_btn), htmx_render(status; scoped=false))
    end
    _polling_wrap(_polling_inner_running(poll_url, poll_interval, inner_body);
                  pausable=true, badge=_poll_badge(label, status), chrome=chrome)
end

# Persistent wrapper. UX state baked in via data-show-*; descendant CSS rules
# pick it up. The wrapper is rendered fresh on every response shape but in
# practice only the initial response (and any first-call-done) actually puts
# this wrapper into the DOM — subsequent polls only swap the inner, leaving
# the original wrapper element (and its possibly-toggled data-show-* attrs)
# untouched.
# Polling badge, one per live `.treebar-poller` wrapper: hairline strip plus
# panel (pause/play button, label, status word, determinate bar, elapsed)
# above the live tree. Expanded by default; `chrome=:quiet` collapses it to
# the strip (hover/focus re-expands). The badge lives on the never-swapped
# wrapper, so the pause control keeps focus and state across polls;
# `syncBadge` (htmx_treebar_script) mirrors the fresh inner into it after
# every swap and tick. Without the page assets there is no collapse and no
# mirror: the badge renders statically above the fully visible tree, and the
# pause button still toggles `data-paused` (but nothing cancels the poll
# requests — the documented asset-less degradation).
#
# The pause onclick toggles `data-paused` on the closest `.treebar-poller` —
# the persistent wrapper, so the paused state survives polls exactly like the
# data-show-* pills. The htmx:beforeRequest listener reads that attr to cancel
# this poller's poll requests, and the duration ticker freezes on it. Keyed on
# closest('.treebar-poller') so nested pollers each pause independently.
# The onclick is INERT once its poller stops polling: it no-ops unless the
# wrapper still holds a direct-child polling inner (`.treebar-poller-inner`
# with `hx-trigger`). A terminal swap replaces that inner with
# `.treebar-terminal-content` (or a bare error article), so a badge left in the
# DOM — a page without `htmx_treebar_script` never runs the afterSwap
# finalizer that removes it — stops responding instead of flipping its glyph
# on a finished poller. A paused poller keeps its inner (and its `hx-trigger`),
# so resume still passes the guard. (Same guard as sibling snag
# treebars-pause-l-19b2227a: this badge subsumes that fix's onclick hunk.)
_pause_button() = h.button(class="treebar-pause", type="button",
    aria_label="Pause live updates",
    title="Pause live updates (the work keeps running in the background)",
    onclick="var p=this.closest('.treebar-poller'); if(!p) return; if(!p.querySelector(':scope > .treebar-poller-inner[hx-trigger]')) return; var v=p.dataset.paused==='1'?'0':'1'; p.dataset.paused=v; var play=v==='1'; this.textContent=play?'▶':'❚❚'; this.setAttribute('aria-label',play?'Resume live updates':'Pause live updates'); if(window.__tbSyncBadge) window.__tbSyncBadge(p);")("❚❚")

# First-paint badge content. The status word and elapsed are server-rendered
# once; the client mirror owns them afterwards. The bar starts indeterminate
# (no value/max) and the mirror sets the determinate fraction from the first
# `.treebar-progress` in the inner — the bar's shape is a client derivation,
# not a second server render rule. The label never changes across polls, so
# the server owns it outright and the mirror never touches it.
_badge_elapsed(::Nothing) = "Starting…"
_badge_elapsed(node::ProgressNode) =
    node.impl isa StateProgress ? _initial_duration_text(node.impl) : ""

function _poll_badge(label, status)
    h.span(class="treebar-badge")(
        h.span(class="treebar-badge-strip", aria_hidden="true")(),
        h.span(class="treebar-badge-panel")(
            _pause_button(),
            # No badge label when there is none to show, or when it would
            # restate the root header one line below (dedup, see above).
            (isnothing(label) || _label_restates_root(label, status)) ? "" :
                h.span(class="treebar-badge-label")(string(label)),
            h.span(class="treebar-badge-status")("Polling"),
            h.progress(class="treebar-badge-bar")(),
            # No badge elapsed when the root row renders its own duration
            # span (dedup, see above). The client mirror tolerates the
            # absent span — it re-checks `querySelector` every tick.
            _root_renders_duration(status) ? "" :
                h.span(class="treebar-badge-elapsed")(_badge_elapsed(status)),
        ),
    )
end

# `chrome` selects the live wrapper's badge presentation: `:auto` (default)
# emits no `data-chrome` attr, so the stylesheet's expanded default applies
# (panel + tree visible — a first-load region shows progress immediately);
# `:quiet` emits `data-chrome="quiet"`, collapsing to the hairline strip
# that expands on hover/focus. A poller diverted into HTMXObjects'
# live-refresh reporter (`.htmxo-live-reporter`) is quiet by stylesheet
# rule regardless of the attr — settled content is already on screen, so
# the poller is background progress. Terminal wrappers carry no badge and
# take no attr. Validated at the public `polling_fetchindex` boundary.
_polling_wrap(inner; pausable=false, terminal=false, badge="", chrome=:auto) =
    terminal ?
        h.div(class="treebar-terminal")(inner) :
        h.div(class="treebar-poller",
            data_chrome=(chrome === :quiet ? "quiet" : nothing),
            data_paused="0",
            data_show_finished="0",
            data_show_pending="1",
            data_show_failed="1",
            data_show_skipped="0")(pausable ? badge : "", inner)

# The polling element. Self-swaps via outerHTML on each `every Xs` trigger.
# `hx-select` strips the wrapper out of the response on each poll (the server
# always emits wrapper > content — initial calls need the wrapper, polls don't —
# and selecting just the running inner or terminal content keeps the live
# wrapper untouched until the afterSwap finalizer changes its state). The last
# branch matches
# HTMXObjects' bare error article (`article[aria-invalid="true"]`) so a
# `keep_progress=false` propagated failure — a 200 carrying just that article —
# still lands in the wrapper, replaces this polling element (no `hx-trigger` →
# polling stops), and shows.
#
# `hx-select` is TOP-LEVEL-ONLY: every branch excludes matches nested inside
# another match. htmx inserts EVERY querySelectorAll match, so without the
# exclusions a response whose selected region CONTAINS a nested poller (an
# explicit `polling_fetchindex` under an `:auto` root, or a finished nested
# poller's terminal fragment inside a still-running outer poll) matches twice
# and the nested region is duplicated into a live sibling on every outer poll
# — linear DOM growth, each duplicate polling. The six `:not()` clauses leave
# exactly the outermost region selected; nested content rides along inside it.
# (The article branch's second clause is sibling snag treebars-pause-l-19b2227a's
# case — a keep_progress failure response whose terminal content contains the
# opaque `safely` article — folded into the same rule; this selector subsumes
# that fix's hx-select hunk.)
#
# Deliberately NO `hx-params` isolation here: poll requests inherit ancestor
# `hx-vals`/form values, and that inheritance is load-bearing. HTMXObjects
# heals a drifted/unknown-token poll by re-executing with the CURRENT request
# args (current-args-wins), which only works because the current args reach
# the server. Stripping them client-side would starve that heal path.
# The trigger filter `[!document.hidden]` stops a backgrounded document (a
# hidden tab or minimized window) from issuing poll requests for nobody and
# resumes on visibility — a returning tab is at most one interval stale. The
# `every` timer keeps rescheduling while filtered, so resume needs no
# re-arming (same shape as the KB's own production poll guard). It lives on
# the trigger (not in the beforeRequest pause hook) so it also covers host
# pages that omit `htmx_treebar_script`, and the value still starts with
# `every` (consumers key running-poller detection on that prefix).
_polling_inner_running(poll_url, interval, body) = h.div(class="treebar-poller-inner",
        hx_get=string(poll_url),
        hx_trigger="every $interval [!document.hidden]",
        hx_target="this",
        hx_swap="outerHTML",
        hx_select=".treebar-poller-inner:not(.treebar-poller-inner .treebar-poller-inner):not(.treebar-terminal-content .treebar-poller-inner), .treebar-terminal-content:not(.treebar-poller-inner .treebar-terminal-content):not(.treebar-terminal-content .treebar-terminal-content), article[aria-invalid='true']:not(.treebar-poller-inner article):not(.treebar-terminal-content article)")(body)

_polling_inner_done(body...) = h.div(class="treebar-terminal-content")(body...)

# Convenience: when called with an IndexableProperty (no render_result), default to identity.
polling_fetchindex(ip::HTMXObjects.DynamicObjects.IndexableProperty, keys...; kwargs...) =
    polling_fetchindex(identity, ip, keys...; kwargs...)

"""
    polling_fetchindex(ws::WebSocket, render_result, ip, keys...; id="treebar-progress", interval=0.1, force=false, kwargs...)

WebSocket sibling of [`polling_fetchindex`](@ref). Same `fetchindex(ip, keys...) do rv, status`
dispatch — but instead of returning a polling HTMX fragment, streams progress
over `ws` via [`ws_progress`](@ref) and pushes the final rendered result as
one last frame on completion.

Producer task is NOT cancelled on client disconnect — `ws_progress` exits
its send loop on WS error and leaves the compute alone; the in-flight compute
runs to completion and its value lands in the IP cache, so the next visitor
reuses it.

Use inside an `@ws` route body, passing `__ws__` as the first argument:

    @ws fit(; model, method, ...) = polling_fetchindex(__ws__, sc.fit, model, method; force, ...) do rv
        render_fit(rv)
    end

Both progress frames and the final frame are wrapped in `<div id=\$id>…</div>`
so the htmx ws-extension swaps by element id on the client.

- `ws`: the WebSocket handle (from `__ws__`)
- `render_result(rv)`: function rendering the final result Node (supports `do` syntax)
- `ip`: IndexableProperty
- `keys...`: cache key(s)
- `id`: stable wrapper element id for ws-extension swap-by-id (default `"treebar-progress"`)
- `interval`: progress push interval in seconds (default `0.1`)
- `force`: force re-computation (default `false`)
- `kwargs...`: passed through to `fetchindex`
"""
function polling_fetchindex(ws::WebSocket, render_result, ip, keys...;
        id="treebar-progress", interval=0.1, force=false, kwargs...)
    progress_render(node) = node_to_html(h.div(; id)(htmx_render(node)))
    final_html(content)   = node_to_html(h.div(; id)(content))
    fetchindex(ip, keys...; force, kwargs...) do rv, status
        if rv isa Task
            ws_progress(ws, status; render=progress_render, interval)
            istaskfailed(rv) ||
                try; send(ws, final_html(render_result(fetch(rv)))); catch; end
        elseif _is_unresolved_handle(rv)
            ws_progress(ws, status; render=progress_render, interval)
            # Block for the finished value and push the final frame. A failed
            # compute makes `fetch` re-throw (caught here → no final frame sent).
            try; send(ws, final_html(render_result(fetch(rv)))); catch; end
        else
            # A resolved VALUE, or a compatible READY handle from the legal
            # completion race described above. Resolve the handle BEFORE the
            # swallow-catch so its serialization can never reach the client raw.
            val = rv
            if _is_handle(rv)
                val = fetch(rv)
            end
            try; send(ws, final_html(render_result(val))); catch; end
        end
    end
end

# Convenience: WS form with no render_result defaults to identity.
polling_fetchindex(ws::WebSocket, ip::HTMXObjects.DynamicObjects.IndexableProperty, keys...; kwargs...) =
    polling_fetchindex(ws, identity, ip, keys...; kwargs...)

end
