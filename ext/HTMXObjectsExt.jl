module HTMXObjectsExt
import HTMXObjects
import HTMXObjects: h, Node, fetchindex
import Treebars: htmx_render, htmx_render_children, htmx_treebar_styles, htmx_treebar_script,
    ws_progress, polling_fetchindex,
    ProgressNode, StateProgress, root, is_pending, is_running, is_finished, is_failed, duration, short_duration
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
.treebar-stop { padding: 0.1rem 0.4rem; font-size: 0.7em; float: right; }
.treebar-node { margin-bottom: 0.25rem; }
.treebar-children { padding-left: 1rem; margin-left: 0.25rem; border-left: 2px solid color-mix(in srgb, var(--pico-muted-color, #888) 40%, transparent); }
.treebar-label { padding-left: 1rem; margin-left: 0.25rem; }

/* Pill toggle state lives on the closest scope (.treebar-poller for live polls,
   .treebar-children for static one-shot renders). data-show-* values are "0" or
   "1" rather than "true"/"false" because Cobweb drops attrs whose value is the
   string "false". CSS rules apply at both scopes. */
.treebar-poller[data-show-finished="0"] .treebar-child-finished,
.treebar-children[data-show-finished="0"] > .treebar-child-finished { display: none; }
.treebar-poller[data-show-failed="0"] .treebar-child-failed,
.treebar-children[data-show-failed="0"] > .treebar-child-failed { display: none; }
.treebar-poller[data-show-pending="0"] .treebar-child-pending,
.treebar-children[data-show-pending="0"] > .treebar-child-pending { display: none; }

.treebar-poller[data-show-finished="1"] .treebar-pill-finished,
.treebar-children[data-show-finished="1"] > .treebar-pills .treebar-pill-finished,
.treebar-poller[data-show-failed="1"] .treebar-pill-failed,
.treebar-children[data-show-failed="1"] > .treebar-pills .treebar-pill-failed,
.treebar-poller[data-show-pending="1"] .treebar-pill-pending,
.treebar-children[data-show-pending="1"] > .treebar-pills .treebar-pill-pending { border-color: currentColor; }
""")

# Client-side duration ticker. Anchors each running .treebar-duration on first
# sight (and re-anchors after every htmx swap, since data-elapsed-ms comes back
# fresh from the server) then ticks textContent every 250ms locally — so the
# counter advances smoothly between server polls instead of stuttering.
htmx_treebar_script() = h.script("""
(function(){
    // Band-based formatter: only the most relevant unit (plus one finer for
    // precision) is shown in any band, and each band's smallest displayed
    // unit is an integer step. So the rendered string changes at most once
    // per integer step of the smallest unit (per-100ms below 1s, per-second
    // up to 1h, per-minute up to 1d, per-hour beyond) and length stays
    // stable within a band.
    function fmt(ms){
        if (ms < 0) ms = 0;
        if (ms < 1000)        return (Math.floor(ms / 100) * 100) + 'ms';
        if (ms < 60_000)      return Math.floor(ms / 1000) + 's';
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
        if (el._tbAnchor === undefined) anchor(el);
        var s = ' — ' + fmt(Date.now() - el._tbAnchor) + ' so far';
        // Only touch the DOM when the rendered string actually changes —
        // sub-second formatting steps in 100ms increments, second-and-up
        // formatting only changes once per integer step, so most ticks at
        // 100ms cadence are no-ops.
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

# Render a StateProgress node as HTML
function htmx_render(node::ProgressNode{<:StateProgress}; article=false, kwargs...)
    sp = node.impl
    children_node = isempty(node.children) ? "" : htmx_render_children(node)
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
            # Label node (key: value)
            h.div(class="treebar-label")(
                h.span(class="treebar-description")(sp.description),
                h.span(class="treebar-value")(sp.message),
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

# Render a full progress tree rooted at node
function htmx_render(node::ProgressNode; kwargs...)
    children_html = [htmx_render(child; kwargs...) for child in node.children]
    h.div(class="treebar-root")(children_html...)
end

node_to_html(node) = sprint(io -> show(io, MIME"text/html"(), node))

# Pill onclick: walk up to the closest UX-state scope (.treebar-poller in the
# polling case, .treebar-children otherwise) and toggle the data attr there.
# CSS in htmx_treebar_styles() reads data-show-* off the same scope, so children
# visibility tracks the toggle without per-element class flipping. Living on
# .treebar-poller means the toggle survives subsequent polls (the wrapper isn't
# re-rendered).
_pill_onclick(key) = """var s = this.closest('.treebar-poller, .treebar-children'); if(!s) return; s.dataset.$(key) = s.dataset.$(key) === '1' ? '0' : '1';"""

# Render just the children of a ProgressNode (for top-level substatus display)
htmx_render_children(::Nothing) = h.p("Starting..."; style="color:var(--pico-muted-color)", aria_busy="true")
function htmx_render_children(node::ProgressNode{<:StateProgress})
    sp = node.impl
    if isempty(node.children) && !isempty(sp.message)
        return h.div(
            h.span(sp.message; style="color:var(--pico-muted-color)"),
            h.span(" "; aria_busy="true"),
        )
    end
    isempty(node.children) && return h.p("Starting..."; style="color:var(--pico-muted-color)", aria_busy="true")

    children = collect(node.children)
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
            h.div(class="treebar-child-pending")(htmx_render(child))
        elseif is_running(child)
            htmx_render(child)
        elseif is_finished(child)
            h.div(class="treebar-child-finished")(htmx_render(child))
        else
            h.div(class="treebar-child-failed")(htmx_render(child))
        end
    end

    # Default UX state baked into .treebar-children so static (non-polling) renders
    # also have working pill toggles. Inside a .treebar-poller the wrapper's data
    # attrs win because they're a closer ancestor (the click handler walks up to
    # whichever it finds first), and they survive polls.
    h.div(class="treebar-children",
        data_show_finished="0",
        data_show_pending="1",
        data_show_failed="1")(
        isempty(pills) ? "" : h.div(class="treebar-pills")(pills...),
        rendered...,
    )
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

# Stable id for the polling wrapper. Same (ip, keys) tuple → same id across
# initial render, polls, and the final done/failed response — required so the
# done-state OOB swap can find the running wrapper to replace.
_poller_id(ip, keys) = "treebar-poller-" * string(hash((objectid(ip), keys)); base=16)

"""
    polling_fetchindex(render_result, ip, keys...; poll_url, label, force=false, poll_interval="200ms", cancel_url="", kwargs...)

Generic fetchindex + HTMX polling pattern. Returns either a self-polling
progress wrapper (while the task is running), or — once the task is done or
failed — a fragment containing both the final article and an
`hx-swap-oob` element that replaces the (still-polling) wrapper to stop the
polling loop.

While running, the wrapper is a stable element with `hx-target="find
.treebar-poller-inner" hx-swap="outerHTML" hx-select=".treebar-poller-inner"`,
so each poll only swaps the inner progress fragment in place. The wrapper
itself survives across polls, which means UX state (`data-show-finished`,
`data-show-failed`, `data-show-pending`) set by pill clicks persists across
polls instead of being reset on every server response.

- `render_result(rv)`: function that renders the final result (supports `do` syntax)
- `ip`: IndexableProperty (e.g. `app.pathfinder`)
- `keys...`: cache key(s) (variadic — supports multi-index like `f1, f2`)
- `poll_url`: URL to poll while running (use `query_url`)
- `label`: display label (e.g. "Pathfinder (my-model)")
- `force`: force re-computation (default `false`)
- `poll_interval`: HTMX polling interval (default "200ms")
- `cancel_url`: optional URL for a "Stop" button shown while running (default `""` = no button).
  The actual cancel logic lives in DynamicObjects (`cancel!`) — Treebars just renders the button.
  After cancel, the task fails with `InterruptException`; next poll shows the failure.
- `kwargs...`: passed through to `fetchindex`
"""
function polling_fetchindex(render_result, ip, keys...; poll_url, label=nothing, force=false, poll_interval="200ms", cancel_url="", kwargs...)
    pid = _poller_id(ip, keys)
    fetchindex(ip, keys...; force, kwargs...) do rv, status
        if rv isa Task && istaskfailed(rv)
            err_str = try sprint(showerror, rv.result) catch; "$(typeof(rv.result)): $(rv.result)" end
            final = h.article(h.header("$label — failed"), h.pre(err_str))
            _polling_done(pid, final)
        elseif rv isa Task
            stop_btn = isempty(cancel_url) ? "" : h.a("Stop"; role="button", class="outline secondary treebar-stop",
                hx_get=cancel_url, hx_target="closest div", hx_swap="outerHTML")
            inner_body = isnothing(label) ? htmx_render(status; article=true) :
                h.article(h.header("$label — running...", stop_btn), htmx_render(status))
            _polling_running(pid, poll_url, poll_interval, inner_body)
        else
            _polling_done(pid, render_result(rv))
        end
    end
end

# Wrapper that survives across polls. `hx-select=".treebar-poller-inner"` makes
# each poll's response shrink to the inner div before swap, and `hx-target="find
# .treebar-poller-inner" hx-swap="outerHTML"` swaps that inner into the live
# wrapper's child without touching the wrapper itself. Result: data-show-* on
# the wrapper persists across polls.
_polling_running(id, poll_url, interval, inner) = h.div(;
        id,
        class="treebar-poller",
        data_show_finished="0",
        data_show_pending="1",
        data_show_failed="1",
        hx_get=string(poll_url),
        hx_trigger="every $interval",
        hx_target="find .treebar-poller-inner",
        hx_swap="outerHTML",
        hx_select=".treebar-poller-inner",
    )(
        h.div(class="treebar-poller-inner")(inner),
    )

# Done state: emit both the OOB wrapper-replacement (used when polling is in
# flight — stops the poll loop by replacing the polling wrapper outright) and a
# bare copy of the final article (used on first-call-done, when no polling
# wrapper exists yet to OOB-target). HTMX strips OOB elements from the response
# before main-swap, so the bare copy is what lands at the user's main target.
_polling_done(id, final) = [
    h.div(; id, hx_swap_oob="outerHTML")(final),
    final,
]

# Convenience: when called with an IndexableProperty (no render_result), default to identity.
polling_fetchindex(ip::HTMXObjects.DynamicObjects.IndexableProperty, keys...; kwargs...) =
    polling_fetchindex(identity, ip, keys...; kwargs...)

end
