module HTMXObjectsExt
import HTMXObjects
import HTMXObjects: h, Node, Raw, fetchindex
import HTTP.WebSockets: WebSocket, send
import Treebars: htmx_render, htmx_render_children, htmx_treebar_styles, htmx_treebar_script,
    ws_progress, polling_fetchindex, htmx_render_board, htmx_ws_render_board, ws_board, htmx_ws_container, _stream_frames, _ws_emit,
    sse_fetchindex, htmx_sse_container, _sse_emit,
    ProgressNode, StateProgress, root, is_pending, is_running, is_finished, is_failed, is_skipped, is_displayed, _renders_self, duration, eta, short_duration, _first_seen!,
    _flatten_displayed_children
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
.treebar-stop { padding: 0.1rem 0.4rem; font-size: 0.7em; float: right; margin-right: 3.5rem; }
.treebar-node { margin-bottom: 0.25rem; }

/* Pause/resume control. Sits top-right of the persistent .treebar-poller
   wrapper. The margin-right above keeps the (float:right) Stop button clear
   of this absolutely-positioned button when cancel_url is set — a constant
   margin, NOT the inherited-custom-prop visibility scheme, so it does not
   interact with the nested-poller data-show-* logic below. */
.treebar-poller { position: relative; }
.treebar-terminal { position: static; }
.treebar-pause {
    display: none;
    position: absolute; top: 0.25rem; right: 0.4rem; z-index: 2;
    margin: 0; padding: 0.1rem 0.5rem; font-size: 0.7rem; line-height: 1.4;
    width: auto; cursor: pointer;
}
/* Reveal the pause control ONLY while this poller is actively polling — i.e. its
   DIRECT-CHILD inner still carries hx-trigger (running). The done inner and the
   error article (article[aria-invalid]) drop hx-trigger, so :has() goes false and
   the button auto-hides with zero server change. The `>` is load-bearing: without
   it an outer (done) poller would match a NESTED still-running inner and keep its
   own button visible (the same nested-poller trap the data-show-* scheme avoids,
   see comment below). Pause cancels the request via JS but keeps the element (and
   its hx-trigger), so a paused poller still matches → button stays → Resume works. */
.treebar-poller:has(> .treebar-poller-inner[hx-trigger]) .treebar-pause { display: inline-block; }
/* Push transports (WebSocket / SSE) put the connection on the wrapper and send
   inners without hx-trigger: there, a direct-child .treebar-poller-inner is the
   running state, and the terminal frame (.treebar-terminal-content) hides the
   button the same way. */
.treebar-poller[ws-connect]:has(> .treebar-poller-inner) > .treebar-pause,
.treebar-poller[sse-connect]:has(> .treebar-poller-inner) > .treebar-pause { display: inline-block; }
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
# sight (and re-anchors the spans a swap delivers, since their data-elapsed-ms
# comes back fresh from the server) then ticks textContent every 100ms locally —
# so the counter advances smoothly between server polls instead of stuttering.
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
    function terminalizePoller(evt){ terminalize(evt && evt.detail && evt.detail.elt); }
    function terminalize(el){
        if (!el || !el.classList || !el.classList.contains('treebar-terminal-content')) return;
        var p = el.parentElement;
        if (!p || !p.classList.contains('treebar-poller')) return;
        p.classList.replace('treebar-poller', 'treebar-terminal');
        ['paused', 'showFinished', 'showPending', 'showFailed', 'showSkipped'].forEach(function(key){
            delete p.dataset[key];
        });
        var pause = p.querySelector(':scope > .treebar-pause');
        if (pause) pause.remove();
        p._tbHeld = undefined;
    }
    // Re-anchor only spans whose server value changed (or that are new). A swap
    // replaces the spans it delivers, so fresh ones anchor from their own
    // data-elapsed-ms; a span the swap did NOT touch keeps its anchor. Blindly
    // re-reading every span on every swap would reset an untouched span (a
    // board item between its 1s polls, a sibling poller) back to the
    // server value it was rendered with, so it would jump backwards.
    function reanchorAll(){
        document.querySelectorAll('.treebar-duration[data-treebar-status="running"]').forEach(function(el){
            if (el._tbAnchor === undefined || el._tbAnchoredFrom !== el.dataset.elapsedMs) anchor(el);
        });
    }
    function tickAll(){
        document.querySelectorAll('.treebar-duration[data-treebar-status="running"]').forEach(tick);
    }
    function reanchorAndTick(evt){ terminalizePoller(evt); reanchorAll(); tickAll(); }
    document.addEventListener('htmx:afterSwap', reanchorAndTick);
    document.addEventListener('htmx:oobAfterSwap', reanchorAndTick);
    // A WebSocket frame keeps the inner's id, and htmx "settles" an element
    // whose id survives a swap: until the swap's settle tasks run — after
    // htmx:oobAfterSwap — the new element still wears the old element's
    // attributes, class included, so the check above cannot recognise a
    // terminal frame yet. htmx:wsAfterMessage fires once they have run.
    document.addEventListener('htmx:wsAfterMessage', function(evt){
        var id = frameId(evt.detail && evt.detail.message);
        if (id) terminalize(document.getElementById(id));
    });

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
    // Pause for push transports (WebSocket / SSE): there is no request to
    // cancel, so hold back running frames while the wrapper is data-paused.
    // The newest held frame is applied on Resume: the server sends a frame only
    // when the tree changes, so without it a resumed view could stay stale
    // until the next change. The terminal frame is never held back.
    function isTerminalFrame(html){
        return /^\\s*<[^>]*\\btreebar-terminal-content\\b/.test(html);
    }
    // The id on a frame's top-level element (WebSocket frames swap by id).
    function frameId(html){
        var m = typeof html === 'string' && /^\\s*<[^>]*\\sid="([^"]+)"/.exec(html);
        return m ? m[1] : null;
    }
    function holdIfPaused(evt, p, html){
        if (!p || !p.classList.contains('treebar-poller') || p.dataset.paused !== '1') return;
        evt.preventDefault();
        p._tbHeld = html;
    }
    document.addEventListener('htmx:wsBeforeMessage', function(evt){
        var d = evt.detail || {}, html = d.message;
        if (typeof html !== 'string' || isTerminalFrame(html)) return;
        // Frames swap by id, so the poller is the parent of the element with
        // the frame's id; without an id, fall back to the socket's element.
        var id = frameId(html), p;
        if (id){ var t = document.getElementById(id); p = t && t.parentElement; }
        else p = d.elt && d.elt.closest && d.elt.closest('.treebar-poller');
        holdIfPaused(evt, p, html);
    });
    document.addEventListener('htmx:sseBeforeMessage', function(evt){
        // detail is the MessageEvent: type is the SSE event name.
        var d = evt.detail || {}, html = d.data;
        if (d.type === 'done' || typeof html !== 'string' || isTerminalFrame(html)) return;
        holdIfPaused(evt, d.elt && d.elt.closest && d.elt.closest('.treebar-poller'), html);
    });
    // Resume. A document listener runs after the button's own onclick, so
    // data-paused has already flipped back to '0' here.
    document.addEventListener('click', function(evt){
        var b = evt.target && evt.target.closest && evt.target.closest('.treebar-pause');
        var p = b && b.parentElement;
        if (!p || p.dataset.paused === '1' || !p._tbHeld) return;
        var html = p._tbHeld, inner = p.querySelector(':scope > .treebar-poller-inner');
        p._tbHeld = undefined;
        if (inner && window.htmx && htmx.swap) htmx.swap(inner, html, {swapStyle: 'outerHTML'});
    });
    function start(){
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
                ),
                h.progress(value=string(sp.i), max=string(sp.N), class="treebar-progress")(),
                children_node,
            )
        elseif !isempty(sp.message)
            header_text = isempty(sp.description) ? sp.message : "$(sp.description) $(sp.message)"
            h.div(class=node_class)(
                h.div(class="treebar-header")(header_text,
                    get(node.meta, :annotation, false) ? "" : duration_node),
                children_node,
            )
        else
            if article
                # Nested container node
                h.article(class=node_class)(
                    !isempty(sp.description) ? h.header(class="treebar-header")(sp.description, duration_node) : "",
                    children_node,
                )
            else
                # Nested container node
                h.div(class=node_class)(
                    !isempty(sp.description) ? h.div(class="treebar-header")(sp.description, duration_node) : "",
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

A `render` function for `ws_progress` when HTMXObjects is loaded.
Returns an HTML string with a stable `id` so the HTMX ws extension swaps by element id.

Client-side:
```html
<div hx-ext="ws" ws-connect="/ws/progress">
    <div id="treebar-progress"></div>
</div>
```

Each frame replaces the whole tree (pill toggles reset). The WebSocket method
of `polling_fetchindex` with `htmx_ws_container` keeps them.
"""
htmx_ws_render(node; id="treebar-progress") = node_to_html(h.div(; id)(htmx_render(node)))

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
    polling_fetchindex(render_result, ip, keys...; poll_context=nothing, poll_url=nothing, label=nothing, force=false, poll_interval="200ms", cancel_url="", keep_progress=true, error_obj=nothing, req=nothing, track_job=true, kwargs...)

Generic fetchindex + HTMX polling pattern. Renders the running progress
inside a `.treebar-poller` wrapper containing a `.treebar-poller-inner`
element that carries the polling attributes (`hx-trigger="every Xs"
hx-target="this" hx-swap="outerHTML"`). On each poll the inner self-swaps;
once the task is done, the response replaces the inner with
`.treebar-terminal-content`, which naturally stops the loop. The client then
renames the stable wrapper to `.treebar-terminal`, removes its polling UX
state and Pause control, and leaves the rendered result (plus optional frozen
progress record) as an unambiguous terminal fragment. While polling, the
wrapper itself is untouched, so UX state on it (`data-show-finished` /
`-failed` / `-pending`, set by pill clicks) persists across polls.

The host page must include [`htmx_treebar_styles`](@ref) and
[`htmx_treebar_script`](@ref) once, normally through `htmx(...;
extra_head=(htmx_treebar_styles(), htmx_treebar_script()))`. The fragment can
still poll without those page assets, but client-owned behavior is then absent:
the duration ticker and Pause handler are not installed, and a completed inner
swap leaves the persistent wrapper identified as `.treebar-poller` instead of
terminalizing it in place.

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
- `label`: display label (e.g. "Pathfinder (my-model)")
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
- `track_job`: when a poller is emitted for in-flight work, report the compute
  to HTMXObjects' job ledger through `HTMXObjects.track_job!` (with `label`,
  the progress tree and `req`), so hand-rolled pollers appear on the runtime
  dashboard and job boards (default `true`). Skipped on HTMXObjects generations
  without that API; a tracking failure never affects the poller. HTMXObjects'
  own operation transport passes `false` — it records its jobs itself.
- `kwargs...`: passed through to `fetchindex`
"""
function polling_fetchindex(render_result, ip, keys...; poll_context=nothing, poll_url=nothing, label=nothing, force=false, poll_interval="200ms", cancel_url="", sync=false, keep_progress=true, error_obj=nothing, req=nothing, track_job=true, kwargs...)
    if !isnothing(poll_context)
        poll_url = HTMXObjects.query_url(poll_context; force=false)
        force = poll_context.force
        # The route struct doubles as the failure-path error context (its
        # __on_error__/__error__ hooks + __req__ for the log), unless the caller
        # passed error_obj/req explicitly.
        isnothing(error_obj) && (error_obj = poll_context)
        isnothing(req) && hasproperty(poll_context, :__req__) && (req = poll_context.__req__)
    end
    # keep_progress: a failed compute is re-thrown by fetchindex BEFORE the
    # callback runs (compute-at-most-once), so wrap the call to catch it, pull
    # the (failed) tree via getstatus, and render the recorded error + tree
    # rather than let the throw reach HTMXObjects' route-boundary catch (which
    # would discard the tree). keep_progress=false (or sync) re-throws as before.
    try
        fetchindex(ip, keys...; force, kwargs...) do rv, status
            # About to emit a poller for in-flight work: report it to
            # HTMXObjects' job ledger (runtime dashboard / job boards).
            track_job && !sync && _is_unresolved_handle(rv) &&
                _track_job(rv, status, ip; label, req)
            _polling_resolve(rv, status; label, poll_url, poll_interval, cancel_url, render_result, sync, keep_progress,
                             ip_ctx=_ip_ctx(ip, keys, kwargs))
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
_polling_resolve(rv::Task, status; sync=false, keep_progress=true, label, poll_url, poll_interval, cancel_url, render_result, ip_ctx="") =
    istaskfailed(rv) ? throw(rv.result) :
    sync ? _polling_resolve(fetch(rv), status; sync, keep_progress, label, poll_url, poll_interval, cancel_url, render_result, ip_ctx) :
        _polling_running(status; label, poll_url, poll_interval, cancel_url)

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
function _polling_resolve(rv, status; sync=false, keep_progress=true, label, poll_url, poll_interval, cancel_url, render_result, ip_ctx="")
    if _is_unresolved_handle(rv)
        return sync ?
            _polling_resolve(fetch(rv), status; sync, keep_progress, label, poll_url, poll_interval, cancel_url, render_result, ip_ctx) :
            _polling_running(status; label, poll_url, poll_interval, cancel_url)
    end
    # A READY handle must never reach render_result raw — resolve it here. This is
    # the guard that `e6f140f` dropped (it deleted `_assert_resolved` and traded
    # Pending-type dispatch for the not-ready duck-test above, which cannot see a
    # ready handle). A compatible ready handle is a legal completion race, so it
    # is normalized silently rather than diagnosed as package skew.
    if _is_handle(rv)
        return _polling_resolve(fetch(rv), status; sync, keep_progress, label, poll_url, poll_interval, cancel_url, render_result, ip_ctx)
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
# returned article is aria-invalid and sits INSIDE the poller inner — the
# poller's hx-select excludes nested matches (see `_polling_inner_running`) so
# htmx does not double-insert it.
_caught_error_ex(err, error_obj, req) =
    HTMXObjects.safely(; obj=error_obj, req=req) do
        throw(err)
    end

_polling_running(status; label, poll_url, poll_interval, cancel_url) =
    _polling_wrap(_polling_inner_running(poll_url, poll_interval, _running_body(status; label, cancel_url)); pausable=true)

# What a running inner shows, for every transport: the live tree rendered
# scoped=false (the persistent wrapper owns the data-show-* toggles), under an
# optional labelled header.
function _running_body(status; label=nothing, cancel_url="")
    stop_btn = isempty(cancel_url) ? "" : h.a("Stop"; role="button", class="outline secondary treebar-stop",
        hx_get=cancel_url, hx_target="closest div", hx_swap="outerHTML")
    isnothing(label) ? htmx_render(status; article=true, scoped=false) :
        h.article(h.header("$label — running...", stop_btn), htmx_render(status; scoped=false))
end

# Persistent wrapper. UX state baked in via data-show-*; descendant CSS rules
# pick it up. The wrapper is rendered fresh on every response shape but in
# practice only the initial response (and any first-call-done) actually puts
# this wrapper into the DOM — subsequent polls only swap the inner, leaving
# the original wrapper element (and its possibly-toggled data-show-* attrs)
# untouched.
# A small, unobtrusive pause/resume control. onclick toggles `data-paused`
# on the closest .treebar-poller — the persistent wrapper, so the paused
# state survives polls exactly like the data-show-* pills. The
# htmx:beforeRequest listener (htmx_treebar_script) reads that attr to cancel
# this poller's poll requests, and the duration ticker freezes on it. Keyed
# on closest('.treebar-poller') so nested pollers each pause independently.
# The button persists across polls (it lives on the never-swapped wrapper),
# so its JS-toggled label stays consistent.
_pause_button() = h.button(class="treebar-pause", type="button",
    onclick="var p=this.closest('.treebar-poller'); if(!p) return; var v=p.dataset.paused==='1'?'0':'1'; p.dataset.paused=v; this.textContent=v==='1'?'Resume':'Pause';")("Pause")

_polling_wrap(inner; pausable=false, terminal=false) =
    terminal ?
        h.div(class="treebar-terminal")(inner) :
        h.div(class="treebar-poller",
            data_paused="0",
            data_show_finished="0",
            data_show_pending="1",
            data_show_failed="1",
            data_show_skipped="0")(pausable ? _pause_button() : "", inner)

# The polling element. Self-swaps via outerHTML on each `every Xs` trigger.
# `hx-select` strips the wrapper out of the response on each poll (the server
# always emits wrapper > content — initial calls need the wrapper, polls don't —
# and selecting just the running inner or terminal content keeps the live
# wrapper untouched until the afterSwap finalizer changes its state). The last
# branch matches
# HTMXObjects' bare error article (`article[aria-invalid="true"]`) so a
# `keep_progress=false` propagated failure — a 200 carrying just that article —
# still lands in the wrapper, replaces this polling element (no `hx-trigger` →
# polling stops), and shows. The `:not(.treebar-poller-inner article)` is
# load-bearing: with keep_progress the failure response IS a `.treebar-poller-inner`
# that CONTAINS an aria-invalid article (the opaque one from `safely`, see
# `_caught_error_ex`); without the exclusion, hx-select's querySelectorAll matches
# BOTH the inner and that nested article and htmx inserts the article twice.
# Excluding nested matches leaves only the inner selected. No request-sniffing,
# no OOB, no JS state hacks needed.
_polling_inner_running(poll_url, interval, body) = h.div(class="treebar-poller-inner",
        hx_get=string(poll_url),
        hx_trigger="every $interval",
        hx_target="this",
        hx_swap="outerHTML",
        hx_select=".treebar-poller-inner, .treebar-terminal-content, article[aria-invalid='true']:not(.treebar-poller-inner article)")(body)

_polling_inner_done(body...) = h.div(class="treebar-terminal-content")(body...)

# Convenience: when called with an IndexableProperty (no render_result), default to identity.
polling_fetchindex(ip::HTMXObjects.DynamicObjects.IndexableProperty, keys...; kwargs...) =
    polling_fetchindex(identity, ip, keys...; kwargs...)

# --- Push transports ---------------------------------------------------------
#
# WebSocket and SSE streams reuse the polling design: a persistent
# `.treebar-poller` wrapper that frames never replace (so its pill toggles,
# Pause state and the connection it carries survive), holding one
# `.treebar-poller-inner` child that each running frame replaces, until the
# terminal frame replaces it with `.treebar-terminal-content`. The frame BODIES
# are the polling ones; a transport only decides how a frame names its target
# and how it is sent.

# htmx's ws extension swaps each top-level element of a message out-of-band by
# id (outerHTML), so every WebSocket frame carries the inner's id.
struct _WSFrames
    ws::WebSocket
    id::String
end
_running_frame(t::_WSFrames, body) =
    node_to_html(h.div(; id=t.id, class="treebar-poller-inner")(body))
_terminal_frame(t::_WSFrames, body...) =
    node_to_html(h.div(; id=t.id, class="treebar-terminal-content")(body...))
_send_progress(t::_WSFrames, frame) = _ws_emit(t.ws, frame)
_send_done(t::_WSFrames, frame) = _ws_emit(t.ws, frame)

# The persistent wrapper of a push stream: the polling wrapper's UX state plus
# the attributes that open the connection. htmx closes a connection when its
# element leaves the DOM, which is why frames target the inner, never this.
_live_wrap(inner; transport...) = h.div(; class="treebar-poller", transport...,
        data_paused="0",
        data_show_finished="0",
        data_show_pending="1",
        data_show_failed="1",
        data_show_skipped="0")(_pause_button(), inner)

# Unique per process (the counter) and across restarts (the clock), and
# independent of the global RNG, which a compute may have seeded.
const _ID_COUNTER = Threads.Atomic{UInt}(0)
_fresh_id() = "treebar-" * string(hash(time_ns(), Threads.atomic_add!(_ID_COUNTER, UInt(1))); base=36)
_connecting() = h.p("Connecting…"; class="u-text-muted", aria_busy="true")

_container_url(url::Function, id) = string(url(id))
_container_url(url, id) = string(url)

function htmx_ws_container(url; id=_fresh_id(), placeholder=_connecting())
    id = string(id)
    _live_wrap(h.div(; id, class="treebar-poller-inner")(placeholder);
        hx_ext="ws", ws_connect=_container_url(url, id))
end

# The value behind a handle. A failed compute rethrows its own exception; a
# `Task` wraps it in a TaskFailedException, unwrapped as the polling path does.
function _fetch_value(rv::Task)
    try
        fetch(rv)
    catch err
        err isa TaskFailedException ? throw(err.task.result) : rethrow()
    end
end
_fetch_value(rv) = fetch(rv)

# fetchindex + a push stream. Streams running frames while the compute is in
# flight, then returns the terminal frame to send — or `nothing` when the
# client went away mid-stream (the compute is left running; its value lands in
# the cache for the next visitor). Mirrors the polling failure path: a failed
# compute is re-thrown by `fetchindex` before the callback runs (or by the
# fetch inside it), so the WHOLE call is wrapped, and the failure is recorded
# and rendered through `safely` next to the kept tree. A failed send is not a
# failure: `_send_*` report it as `false` and never throw.
function _stream_fetchindex(t, render_result, ip, keys...; interval=0.1, force=false, label=nothing,
        keep_progress=true, error_obj=nothing, req=nothing, kwargs...)
    frame = try
        fetchindex(ip, keys...; force, kwargs...) do rv, status
            _stream_resolve(t, rv, status; interval, label, keep_progress, render_result)
        end
    catch err
        _terminal_frame(t, _caught_error_ex(err, error_obj, req),
            keep_progress ? _kept_progress(HTMXObjects.getstatus(ip, keys...; kwargs...); open=true) : "")
    end
    isnothing(frame) || _send_done(t, frame)
    nothing
end

function _stream_resolve(t, rv, status; interval, label, keep_progress, render_result)
    if _is_unresolved_handle(rv)
        # No status tree → no progress frames: just wait for the value.
        if !isnothing(status)
            live = _stream_frames(frame -> _send_progress(t, frame), status; interval, done=rv,
                render = node -> _running_frame(t, _running_body(node; label)))
            live || return nothing
        end
        rv = _fetch_value(rv)
    elseif _is_handle(rv)
        # A handle that became ready between DynamicObjects' snapshot and this
        # callback (see `_polling_resolve`): resolve it, never render it raw.
        rv = _fetch_value(rv)
    end
    body = render_result(rv)
    keep_progress ? _terminal_frame(t, body, _kept_progress(status; open=false)) : _terminal_frame(t, body)
end

"""
    polling_fetchindex(ws::WebSocket, render_result, ip, keys...; id="treebar-progress", interval=0.1, force=false, label=nothing, keep_progress=true, error_obj=nothing, req=nothing, kwargs...)

WebSocket sibling of [`polling_fetchindex`](@ref): the same
`fetchindex(ip, keys...) do rv, status` dispatch and the same frame shapes, but
pushed over `ws` instead of polled. Pair it with
[`htmx_ws_container`](@ref), which renders the client side with a matching
`id`.

While the compute runs, each changed state of the tree is sent as

    <div id=ID class="treebar-poller-inner">…tree, rendered scoped=false…</div>

which htmx's ws extension swaps in place of the inner by id. The persistent
`.treebar-poller` wrapper around it is never replaced, so pill toggles and
Pause survive. A pending status node is streamed like a running one. Frames are
sent only when the tree changed; a running node's elapsed time and ETA tick on
the client (see [`htmx_treebar_script`](@ref)).

When the compute finishes (as soon as the handle settles, not on the next
tick) the terminal frame replaces the inner, exactly like the polling terminal
content:

    <div id=ID class="treebar-terminal-content">result [+ frozen tree]</div>

It holds `render_result(value)` and, with `keep_progress=true` (the default),
the frozen tree in a collapsed `<details class="treebar-frozen">`. The page
script then turns the wrapper into `.treebar-terminal` and drops its Pause
button. A failed compute (re-thrown by `fetchindex`, or by the fetch while
streaming) or a throwing `render_result` is recorded and rendered through
HTMXObjects' `safely` (`error_obj` / `req` as in the polling path) and sent as
the terminal frame, beside the tree in an open `<details>`; with
`keep_progress=false` the error is sent alone.

If the client disconnects, the stream stops quietly (logged at `@debug`) and
the compute is left running; its value lands in the IP cache for the next
visitor.

Use inside an `@ws` route body, passing `__ws__` as the first argument:

    @ws fit(; model, id) = polling_fetchindex(__ws__, sc.fit, model; id) do rv
        render_fit(rv)
    end

- `ws`: the WebSocket handle (from `__ws__`)
- `render_result(rv)`: renders the final result (supports `do` syntax)
- `ip`, `keys...`: the IndexableProperty and its cache key(s)
- `id`: the inner element's id — the same id [`htmx_ws_container`](@ref) gave
  the client (default `"treebar-progress"`)
- `interval`: seconds between progress checks (default `0.1`)
- `force`: force re-computation (default `false`)
- `label`: optional header over the running tree, as in the polling path
- `keep_progress`: keep the frozen tree in the terminal frame (default `true`)
- `error_obj` / `req`: route context for `safely` on the failure path
- `kwargs...`: passed through to `fetchindex`
"""
function polling_fetchindex(ws::WebSocket, render_result, ip, keys...;
        id="treebar-progress", interval=0.1, force=false, label=nothing,
        keep_progress=true, error_obj=nothing, req=nothing, kwargs...)
    _stream_fetchindex(_WSFrames(ws, string(id)), render_result, ip, keys...;
        interval, force, label, keep_progress, error_obj, req, kwargs...)
end

# Convenience: WS form with no render_result defaults to identity.
polling_fetchindex(ws::WebSocket, ip::HTMXObjects.DynamicObjects.IndexableProperty, keys...; kwargs...) =
    polling_fetchindex(ws, identity, ip, keys...; kwargs...)

# `do` syntax passes the block FIRST: `polling_fetchindex(ws, ip, key) do rv … end`
# arrives as `(render_result, ws, ip, key)`. Without this method that call fell
# through to the HTTP polling method, with the WebSocket taken for the IP.
polling_fetchindex(render_result, ws::WebSocket, ip, keys...; kwargs...) =
    polling_fetchindex(ws, render_result, ip, keys...; kwargs...)
# Tie-breakers for argument orders nobody means. Each is exactly the overlap of
# two methods above, which keeps the method table free of ambiguities.
polling_fetchindex(::WebSocket, ::WebSocket, ip, keys...; kwargs...) = _misordered_ws()
polling_fetchindex(::HTMXObjects.DynamicObjects.IndexableProperty, ::WebSocket, ip, keys...; kwargs...) = _misordered_ws()
_misordered_ws() = throw(ArgumentError(
    "polling_fetchindex: pass the WebSocket, then render_result (or use `do` syntax), the IndexableProperty and its keys"))

# --- Server-sent events ------------------------------------------------------
#
# The same frames as the WebSocket transport, without swap-by-id: htmx's sse
# extension swaps an element on the events named in its `sse-swap`, so every
# running inner carries that (and its own target, so an inherited `hx-target`
# further up the page cannot redirect the swap), while the terminal content
# carries none and so stops listening — as the polling terminal content drops
# `hx-trigger`.
struct _SSEFrames
    io::IO
end
_sse_inner(content...) = h.div(class="treebar-poller-inner",
    sse_swap="progress,done", hx_swap="outerHTML", hx_target="this")(content...)
_running_frame(::_SSEFrames, body) = node_to_html(_sse_inner(body))
_terminal_frame(::_SSEFrames, body...) = node_to_html(_polling_inner_done(body...))
_send_progress(t::_SSEFrames, frame) = _sse_emit(t.io, "progress", frame)
_send_done(t::_SSEFrames, frame) = _sse_emit(t.io, "done", frame)

htmx_sse_container(url; placeholder=_connecting()) =
    _live_wrap(_sse_inner(placeholder); hx_ext="sse", sse_connect=string(url), sse_close="done")

function sse_fetchindex(io::IO, render_result, ip, keys...; interval=0.1, force=false, label=nothing,
        keep_progress=true, error_obj=nothing, req=nothing, kwargs...)
    _stream_fetchindex(_SSEFrames(io), render_result, ip, keys...;
        interval, force, label, keep_progress, error_obj, req, kwargs...)
end
sse_fetchindex(io::IO, ip::HTMXObjects.DynamicObjects.IndexableProperty, keys...; kwargs...) =
    sse_fetchindex(io, identity, ip, keys...; kwargs...)
# `do` syntax passes the block first.
sse_fetchindex(render_result, io::IO, ip, keys...; kwargs...) =
    sse_fetchindex(io, render_result, ip, keys...; kwargs...)
# Tie-breaker for the overlap of the two methods above.
sse_fetchindex(::IO, ::IO, ip, keys...; kwargs...) = throw(ArgumentError(
    "sse_fetchindex: pass the stream, then render_result (or use `do` syntax), the IndexableProperty and its keys"))

end
