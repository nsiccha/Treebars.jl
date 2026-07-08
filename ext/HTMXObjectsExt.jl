module HTMXObjectsExt
import HTMXObjects
import HTMXObjects: h, Node, fetchindex
import HTTP.WebSockets: WebSocket, send
import Treebars: htmx_render, htmx_render_children, htmx_treebar_styles, htmx_treebar_script,
    ws_progress, polling_fetchindex,
    ProgressNode, StateProgress, root, is_pending, is_running, is_finished, is_failed, is_displayed, _renders_self, duration, short_duration, _first_seen!
import Dates
using Dates: Millisecond

# Map a StateProgress's lifecycle into a single status string the client JS can dispatch on.
function _status_string(sp::StateProgress)
    is_pending(sp) && return "pending"
    is_running(sp) && return "running"
    is_failed(sp) && return "failed"
    "finished"
end

# Initial textContent for the duration span. Running nodes get a fresh value here
# but the client-side ticker overwrites every 250ms; finished/failed nodes keep
# whatever the server rendered (the ticker leaves them alone).
function _initial_duration_text(sp::StateProgress)
    is_pending(sp) && return " — pending"
    d = short_duration(duration(sp))
    if is_running(sp)
        " — $(d) so far"
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
    elapsed_ms = string(Dates.value(Millisecond(duration(sp))))
    if status == "pending"
        h.span(class="treebar-duration", data_treebar_status=status)(_initial_duration_text(sp))
    else
        h.span(class="treebar-duration",
            data_treebar_status=status,
            data_elapsed_ms=elapsed_ms)(_initial_duration_text(sp))
    end
end

# Global stylesheet for treebar components — include via extra_head in htmx()
htmx_treebar_styles() = h.style("""
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
.treebar-pending { opacity: 0.55; }
.treebar-pending .treebar-progress { opacity: 0.5; }
.treebar-pill:hover { opacity: 0.8; }
.treebar-header, .treebar-label { display: flex; gap: 0.5ch; align-items: baseline; flex-wrap: wrap; }
.treebar-duration { font-size: 0.85em; color: var(--pico-muted-color, #888); }
.treebar-stop { padding: 0.1rem 0.4rem; font-size: 0.7em; float: right; margin-right: 3.5rem; }
.treebar-node { margin-bottom: 0.25rem; }

/* Inline error box for the keep_progress failure path (see `_error_article`).
   A dedicated class, NOT aria-invalid, to avoid a second hx-select match. */
.treebar-error {
    border: 1px solid var(--pico-del-color, #e74c3c);
    background: color-mix(in srgb, var(--pico-del-color, #fee2e2) 12%, transparent);
}
.treebar-error > header { color: var(--pico-del-color, #e74c3c); font-weight: 600; }
.treebar-error > .treebar-error-msg { white-space: pre-wrap; overflow-x: auto; margin: 0.25rem 0; font-size: 0.9em; }
.treebar-error-trace > summary { cursor: pointer; font-size: 0.85em; color: var(--pico-muted-color, #888); }
.treebar-error-trace > pre { white-space: pre; overflow: auto; max-height: 22rem; margin: 0.25rem 0 0; font-size: 0.8em; }

/* Pause/resume control. Sits top-right of the persistent .treebar-poller
   wrapper. The margin-right above keeps the (float:right) Stop button clear
   of this absolutely-positioned button when cancel_url is set — a constant
   margin, NOT the inherited-custom-prop visibility scheme, so it does not
   interact with the nested-poller data-show-* logic below. */
.treebar-poller { position: relative; }
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
.treebar-children { padding-left: 1rem; margin-left: 0.25rem; border-left: 2px solid color-mix(in srgb, var(--pico-muted-color, #888) 40%, transparent); }
/* .treebar-label intentionally carries NO self-indent: it inherits indentation
   from the enclosing .treebar-children like every other node, so a nested label
   aligns with its sibling .treebar-node instead of being double-indented. Its
   flex layout lives in the `.treebar-header, .treebar-label` rule above. */

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
.treebar-poller[data-show-finished="0"], .treebar-children[data-show-finished="0"] { --tb-finished-display: none; }
.treebar-poller[data-show-finished="1"], .treebar-children[data-show-finished="1"] { --tb-finished-display: block; }
.treebar-poller[data-show-failed="0"], .treebar-children[data-show-failed="0"] { --tb-failed-display: none; }
.treebar-poller[data-show-failed="1"], .treebar-children[data-show-failed="1"] { --tb-failed-display: block; }
.treebar-poller[data-show-pending="0"], .treebar-children[data-show-pending="0"] { --tb-pending-display: none; }
.treebar-poller[data-show-pending="1"], .treebar-children[data-show-pending="1"] { --tb-pending-display: block; }
.treebar-child-finished { display: var(--tb-finished-display, block); }
.treebar-child-failed { display: var(--tb-failed-display, block); }
.treebar-child-pending { display: var(--tb-pending-display, block); }

/* Active-pill highlight, same nearest-scope-wins inheritance so a nested
   poller's pills reflect that poller's own toggle, not an ancestor's. */
.treebar-poller[data-show-finished="1"], .treebar-children[data-show-finished="1"] { --tb-finished-pill-border: currentColor; }
.treebar-poller[data-show-failed="1"], .treebar-children[data-show-failed="1"] { --tb-failed-pill-border: currentColor; }
.treebar-poller[data-show-pending="1"], .treebar-children[data-show-pending="1"] { --tb-pending-pill-border: currentColor; }
.treebar-pill-finished { border-color: var(--tb-finished-pill-border, transparent); }
.treebar-pill-failed { border-color: var(--tb-failed-pill-border, transparent); }
.treebar-pill-pending { border-color: var(--tb-pending-pill-border, transparent); }

/* Demo helpers */
.tb-input-narrow { max-width: 6rem; }
.tb-input-narrow-7 { max-width: 7rem; }
""")

# Client-side duration ticker. Anchors each running .treebar-duration on first
# sight (and re-anchors after every htmx swap, since data-elapsed-ms comes back
# fresh from the server) then ticks textContent every 250ms locally — so the
# counter advances smoothly between server polls instead of stuttering.
htmx_treebar_script() = h.script("""
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
        el._tbLast = undefined;
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
        if (el._tbAnchor === undefined) anchor(el);
        var s = ' — ' + fmt(Date.now() - el._tbAnchor) + ' so far';
        // Only touch the DOM when the rendered string actually changes —
        // below 1min the value steps every 100ms (matching the tick cadence,
        // so each tick updates), while minute-and-up only change once per
        // integer minute/hour, so those ticks are mostly no-ops.
        if (el._tbLast !== s){ el.textContent = s; el._tbLast = s; }
    }
    function reanchorAll(){
        document.querySelectorAll('.treebar-duration[data-treebar-status="running"]').forEach(anchor);
    }
    function tickAll(){
        document.querySelectorAll('.treebar-duration[data-treebar-status="running"]').forEach(tick);
    }
    function reanchorAndTick(){ reanchorAll(); tickAll(); }
    document.addEventListener('htmx:afterSwap', reanchorAndTick);
    document.addEventListener('htmx:oobAfterSwap', reanchorAndTick);
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
""")

# Walk `node.children` and replace each non-self-rendering child with its own
# (recursively flattened) children. A child does not render itself when it is
# explicitly `displayed=false` OR it is a bare wrapper with no display
# preference set (see `Treebars._renders_self`). Pure render-time transform;
# the underlying tree is unchanged. Returns a flat Vector{ProgressNode},
# preserving iteration order.
function _flatten_displayed_children(node::ProgressNode)
    out = ProgressNode[]
    for child in node.children
        if _renders_self(child)
            push!(out, child)
        else
            append!(out, _flatten_displayed_children(child))
        end
    end
    out
end

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
        node_class = pending ? "treebar-node treebar-pending" : "treebar-node"
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
            # Message-bearing leaf. Show the duration suffix by default (a timed
            # work-leaf like a disk-load substatus "from disk: 2.5 GB"), EXCEPT on
            # `key: value` annotation labels (set by `_update_labels!`, meta flag
            # `annotation=true`) whose "duration" is just the parent's lifetime and
            # so misleading. Nodes whose meta lacks the flag default to showing it.
            h.div(class="treebar-label")(
                h.span(class="treebar-description")(sp.description),
                h.span(class="treebar-value")(sp.message),
                get(node.meta, :annotation, false) ? "" : duration_node,
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

# Pill onclick: prefer the .treebar-poller (so polling toggles survive across
# polls); fall back to the closest .treebar-children for static one-shot
# renders (no poller in scope). The two-step `closest` (rather than a single
# comma selector) is intentional — `closest('.treebar-poller, .treebar-children')`
# returns whichever is the closer ancestor, which is always .treebar-children.
_pill_onclick(key) = """var s = this.closest('.treebar-poller') || this.closest('.treebar-children'); if(!s) return; s.dataset.$(key) = s.dataset.$(key) === '1' ? '0' : '1';"""

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

    pills = Node[]
    if n_pending > 0
        push!(pills, h.span(class="treebar-pill treebar-pill-pending",
            onclick=_pill_onclick("showPending"))("$(n_pending) pending"))
    end
    if n_finished > 0
        push!(pills, h.span(class="treebar-pill treebar-pill-finished",
            onclick=_pill_onclick("showFinished"))("$(n_finished) finished"))
    end
    if n_failed > 0
        push!(pills, h.span(class="treebar-pill treebar-pill-failed",
            onclick=_pill_onclick("showFailed"))("$(n_failed) failed"))
    end

    rendered = map(children) do child
        if is_pending(child)
            h.div(class="treebar-child-pending")(htmx_render(child; scoped, seen))
        elseif is_running(child)
            htmx_render(child; scoped, seen)
        elseif is_finished(child)
            h.div(class="treebar-child-finished")(htmx_render(child; scoped, seen))
        else
            h.div(class="treebar-child-failed")(htmx_render(child; scoped, seen))
        end
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
            data_show_failed="1")(
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
htmx_ws_render(node; id="treebar-progress") = node_to_html(h.div(; id)(htmx_render(node)))

"""
    polling_fetchindex(render_result, ip, keys...; poll_context=nothing, poll_url=nothing, label=nothing, force=false, poll_interval="200ms", cancel_url="", keep_progress=true, kwargs...)

Generic fetchindex + HTMX polling pattern. Renders the running progress
inside a `.treebar-poller` wrapper containing a `.treebar-poller-inner`
element that carries the polling attributes (`hx-trigger="every Xs"
hx-target="this" hx-swap="outerHTML"`). On each poll the inner self-swaps;
once the task is done, the response replaces the inner with non-polling
content (the rendered result), which naturally stops the loop. The wrapper
itself is never touched by polling, so UX state on it (`data-show-finished`
/ `-failed` / `-pending`, set by pill clicks) persists across polls.

Failure path: `throw(rv.result)`. HTMXObjects wraps user errors as a 200
HTML response for HTMX requests; that response replaces the polling inner
via the inner's own `hx-target="this" hx-swap="outerHTML"`, so polling
stops naturally without any custom OOB / HX-Retarget gymnastics.

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
  The actual cancel logic lives in DynamicObjects (`cancel!`) — Treebars just renders the button.
  After cancel, the task fails with `InterruptException`; next poll throws and
  HTMXObjects renders the error article.
- `keep_progress`: keep the finished/failed progress tree around for post-hoc
  inspection (default `true`). On success the frozen tree is appended below the
  result in a collapsed `<details>`; on failure the tree (with the failed node)
  is shown in an open `<details>` alongside an inline error article — instead of
  `throw`ing to HTMXObjects' error handler, which would discard the tree. Set
  `false` to restore the old result-only / throw-on-failure behavior. Ignored on
  the `sync` path (no tree in the loopback result).
- `kwargs...`: passed through to `fetchindex`
"""
function polling_fetchindex(render_result, ip, keys...; poll_context=nothing, poll_url=nothing, label=nothing, force=false, poll_interval="200ms", cancel_url="", sync=false, keep_progress=true, kwargs...)
    if !isnothing(poll_context)
        poll_url = HTMXObjects.query_url(poll_context; force=false)
        force = poll_context.force
    end
    fetchindex(ip, keys...; force, kwargs...) do rv, status
        _polling_resolve(rv, status; label, poll_url, poll_interval, cancel_url, render_result, sync, keep_progress)
    end
end

# Two-method dispatch on the IP's resolved value: a `Task` is still
# running (or just failed); anything else is the final (done) result.
# Replaces the `if _is_task(rv) … elseif _is_task(rv) … else …` chain
# in `polling_fetchindex`'s `do rv, status` block — the type test now
# lives at the method boundary, and the failure-vs-running split inside
# the Task method is a plain value test (`istaskfailed`).
# When `sync=true`, block on a running Task instead of returning polling
# HTML — used by PDF export loopback (wants_markdown) and other callers
# that need synchronous resolution.
# Failed: with keep_progress (default) render an inline error article + the
# frozen tree (failed node visible) so the run can be inspected — see
# `_kept_progress`/`_error_article`. Without it, fall back to `throw`ing so
# HTMXObjects renders its own recorded-error article (discards the tree).
_polling_resolve(rv::Task, status; sync=false, keep_progress=true, label, poll_url, poll_interval, cancel_url, render_result) =
    istaskfailed(rv) ?
        (keep_progress ? _polling_wrap(_polling_inner_done(_error_article(rv), _kept_progress(status; open=true))) :
                         throw(rv.result)) :
    sync ? _polling_resolve(fetch(rv), status; sync, keep_progress, label, poll_url, poll_interval, cancel_url, render_result) :
        _polling_running(status; label, poll_url, poll_interval, cancel_url)

# Done — already-cached or just-completed. The wrapper here is
# vestigial on first-call-done (no polling ever happened) but
# harmless; on running-then-done the response replaces the polling
# inner so the wrapper persists with its UX state intact. With
# keep_progress (default, but not on the sync loopback), the frozen tree
# is appended below the result in a collapsed <details> for inspection.
function _polling_resolve(rv, status; sync=false, keep_progress=true, label, poll_url, poll_interval, cancel_url, render_result)
    body = render_result(rv)
    (keep_progress && !sync) ?
        _polling_wrap(_polling_inner_done(body, _kept_progress(status; open=false))) :
        _polling_wrap(_polling_inner_done(body))
end

# Frozen progress tree kept in the final (non-polling) response so a finished
# or failed run can be inspected after polling stops. Rendered scoped=true so
# the finished/failed/pending pills act as a static inspector, wrapped in a
# <details> (collapsed on success — stays out of the way; open on failure —
# failed node visible immediately). Empty string when there is no status node.
function _kept_progress(status; open::Bool=false)
    isnothing(status) && return ""
    # `treebar-frozen`: the client ticker skips durations inside it, so this is a
    # genuinely static snapshot. Needed because a terminal tree may still hold a
    # node marked "running" (a consumer whose failure/finalization didn't
    # propagate to every node) — without this it would tick forever.
    body = (h.summary("Progress"), htmx_render(status; scoped=true))
    open ? h.details(class="treebar-frozen", open=true)(body...) : h.details(class="treebar-frozen")(body...)
end

# Self-contained error article for the keep_progress failure path, rendered
# inline here instead of `throw`ing (which hands control to HTMXObjects and
# discards the kept tree). Carries the `treebar-error` class rather than
# `aria-invalid="true"` ON PURPOSE: this article sits INSIDE the returned
# `.treebar-poller-inner`, and the poller's `hx-select` second branch matches
# `article[aria-invalid='true']` — so an aria-invalid here would be a SECOND
# hx-select match and htmx would double-insert it. The class gets its own error
# styling in `htmx_treebar_styles`. The concise reason (everything before the
# first "Stacktrace:") shows inline; the full nested trace is tucked into a
# collapsed, height-capped <details> so it does not bury the kept tree below it.
function _error_article(t::Task)
    full = sprint(Base.showerror, Base.TaskFailedException(t))
    idx = findfirst("Stacktrace:", full)
    reason = isnothing(idx) ? full : rstrip(full[1:prevind(full, first(idx))])
    h.article(class="treebar-error")(
        h.header("Failed"),
        h.pre(class="treebar-error-msg")(reason),
        h.details(class="treebar-error-trace")(h.summary("Full stacktrace"), h.pre(full)),
    )
end

function _polling_running(status; label, poll_url, poll_interval, cancel_url)
    stop_btn = isempty(cancel_url) ? "" : h.a("Stop"; role="button", class="outline secondary treebar-stop",
        hx_get=cancel_url, hx_target="closest div", hx_swap="outerHTML")
    inner_body = isnothing(label) ? htmx_render(status; article=true, scoped=false) :
        h.article(h.header("$label — running...", stop_btn), htmx_render(status; scoped=false))
    _polling_wrap(_polling_inner_running(poll_url, poll_interval, inner_body); pausable=true)
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

_polling_wrap(inner; pausable=false) = h.div(class="treebar-poller",
        data_paused="0",
        data_show_finished="0",
        data_show_pending="1",
        data_show_failed="1")(pausable ? _pause_button() : "", inner)

# The polling element. Self-swaps via outerHTML on each `every Xs` trigger.
# `hx-select` strips the wrapper out of the response on each poll (the server
# always emits wrapper > inner — initial calls need the wrapper, polls don't —
# and selecting just the inner keeps the live wrapper untouched, which is what
# preserves `data-show-*` UX state across polls). The selector also matches
# HTMXObjects' default error article shape (`article[aria-invalid="true"]`),
# so a thrown task failure — which HTMXObjects turns into a 200 with that
# article — still lands inside the wrapper, replaces this polling element
# (no `hx-trigger` in the error article → polling stops naturally), and is
# visible to the user. No request-sniffing, no OOB, no JS state hacks needed.
_polling_inner_running(poll_url, interval, body) = h.div(class="treebar-poller-inner",
        hx_get=string(poll_url),
        hx_trigger="every $interval",
        hx_target="this",
        hx_swap="outerHTML",
        hx_select=".treebar-poller-inner, article[aria-invalid='true']")(body)

_polling_inner_done(body...) = h.div(class="treebar-poller-inner")(body...)

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
its send loop on WS error and leaves the task alone; the IP cache retains
the running task, so the next visitor reuses it.

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
        else
            try; send(ws, final_html(render_result(rv))); catch; end
        end
    end
end

# Convenience: WS form with no render_result defaults to identity.
polling_fetchindex(ws::WebSocket, ip::HTMXObjects.DynamicObjects.IndexableProperty, keys...; kwargs...) =
    polling_fetchindex(ws, identity, ip, keys...; kwargs...)

end
