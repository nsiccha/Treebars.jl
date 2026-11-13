# Map a StateProgress's lifecycle into a single status string the client JS can dispatch on.
function _status_string(sp::StateProgress)
    is_pending(sp) && return "pending"
    is_running(sp) && return "running"
    is_failed(sp) && return "failed"
    is_skipped(sp) && return "skipped"
    is_reused(sp) && return "reused"
    "finished"
end

# Capture mutable state under its lock, then build HTML after releasing it.
# Duration and ETA share one clock reading and are reused in text and attrs.
struct _RenderState
    description::String
    N::Union{Int,Nothing}
    i::Int
    message::Union{String,Treebars.TreebarNote}
    status::String
    started::Bool
    elapsed::Millisecond
    eta::Union{Nothing,Millisecond}
    interrupt::Bool
end

function _render_state(node::ProgressNode{<:StateProgress})
    sp = node.impl
    lock(sp.lock) do
        elapsed = duration(sp)
        _RenderState(sp.description, sp.N, sp.i, sp.message, _status_string(sp),
            !isnothing(sp.started_at), elapsed, Treebars._eta(sp, elapsed),
            _shows_interrupt_request(node))
    end
end
_render_state(::ProgressNode) = nothing

# Initial textContent for the duration span. Running nodes get a fresh value here
# but the client-side ticker overwrites every 250ms; finished/failed nodes keep
# whatever the server rendered (the ticker leaves them alone).
function _initial_duration_text(sp::_RenderState, t::TreebarTexts)
    sp.status == "pending" && return " — " * t.pending
    # A label, never an elapsed figure: a skipped node has no `started_at`, so
    # any duration here would be the 0s that made a bypassed phase read as an
    # instantaneous one.
    sp.status == "skipped" && return " — " * t.skipped
    # Same rule for a phase reused before it was entered: it did no work, so
    # it gets no figure. Entered first, it keeps the time spent finding out.
    sp.status == "reused" && return !sp.started ? " — " * t.reused :
        " — " * _fill_text(t.reused_after; elapsed=_duration_text(sp.elapsed, t))
    d = _duration_text(sp.elapsed, t)
    if sp.status == "running"
        # A determinate running node (0 < i < N) also gets a live ETA beside the
        # elapsed; the client ticker counts it down between polls (data-eta-ms).
        e = sp.eta
        running = " — " * _fill_text(t.running; elapsed=d)
        isnothing(e) ? running : running * " · " * _fill_text(t.eta; eta=_duration_text(e, t))
    elseif sp.status == "failed"
        " — " * _fill_text(t.failed; elapsed=d)
    else
        " — " * _fill_text(t.done; elapsed=d)
    end
end

# Duration span. Carries data attrs so the client can tick running nodes locally
# between server polls instead of waiting for the next render to advance them.
function _duration_span(sp::_RenderState, t::TreebarTexts)
    status = sp.status
    text = _initial_duration_text(sp, t)
    if status == "pending"
        return h.span(class="treebar-duration", data_treebar_status=status)(text)
    end
    elapsed_ms = string(Dates.value(Millisecond(sp.elapsed)))
    # data-eta-ms is present only for a running determinate node; the client
    # ticker anchors an absolute finish target from it and counts down. Absent
    # → the span ticks up (elapsed) exactly as before.
    e = sp.eta
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

# Where a live region says how old its shown state is: rendered empty and
# hidden in the region's chrome (a poller's badge panel, a live board's
# header, each WebSocket frame); `htmx_treebar_script` fills it once the
# region goes stale or loses its connection (see "Freshness" there).
_freshness_span() = h.span(class="treebar-freshness", hidden=true)()

# Pending-interrupt marker for a node header (see `_shows_interrupt_request`):
# the same text `render_text` prints, so the two renderers agree.
_interrupt_span(node::ProgressNode, t::TreebarTexts) =
    _shows_interrupt_request(node) ? h.span(class="treebar-interrupt")(t.interrupt) : ""

include("treebar_styles.jl")
include("treebar_script.jl")

# A plan nested in another plan's phase renders as a disclosure inside that
# plan's output, captioned with the declaring phase's label: open for
# `phase_overview=true`, closed for `:collapsed`. `data-treebar-disclosure`
# names the plan stably across snapshots, so `htmx_treebar_script` keeps a
# viewer's choice when a live update replaces the overview.
const _OVERVIEW_STATES = (:pending, :running, :finished, :reused, :failed, :skipped)

_overview_state_text(t::TreebarTexts, state::Symbol) = getfield(t, Symbol("state_", state))

_phase_plan_table(entry, t::TreebarTexts) =
    h.div(class=entry.depth == 0 ? "treebar-phase-plan" : "treebar-phase-plan treebar-phase-plan-nested",
        data_phase_depth=string(min(entry.depth, 3)))(
        h.table()(
            h.caption(entry.caption),
            h.thead(h.tr(h.th(scope="col")(t.phase),
                [h.th(scope="col")(_overview_state_text(t, state)) for state in _OVERVIEW_STATES])),
            h.tbody([h.tr(h.th(scope="row")(phase.label),
                [h.td(data_phase_state=string(state))(string(getproperty(phase, state)))
                    for state in _OVERVIEW_STATES]) for phase in entry.plan.phases]),
        ))

# HTMX flattens a Vector child one level only, so every list below is flat:
# a plan's table followed by the disclosures of the plans nested in it.
function _phase_plan_html(entries, nested, i, t::TreebarTexts)
    entry = entries[i]
    body = Any[_phase_plan_table(entry, t)]
    for j in nested[i]
        push!(body, h.details(class="treebar-phase-disclosure", data_treebar_disclosure=entries[j].key,
            open=entries[j].open ? true : nothing)(h.summary(entries[j].caption), _phase_plan_html(entries, nested, j, t)))
    end
    body
end

_disclosure_onclick(open::Bool) = "var o = this.closest('.treebar-phase-overview'); if(!o) return; " *
    "o.querySelectorAll('details.treebar-phase-disclosure').forEach(function(d){ d.open = $open; });"

function _phase_overview_html(nodes, mode, t::TreebarTexts; board=false)
    entries = Treebars._overview_entries(nodes, mode, t)
    isempty(entries) && !board && return ""
    nested = [Int[] for _ in entries]
    for (i, entry) in enumerate(entries)
        isnothing(entry.parent) || push!(nested[entry.parent], i)
    end
    controls = any(entry -> entry.depth > 0, entries) ?
        h.div(class="treebar-phase-overview-controls")(
            h.button(type="button", class="outline secondary treebar-phase-expand",
                onclick=_disclosure_onclick(true))(t.expand_all),
            h.button(type="button", class="outline secondary treebar-phase-collapse",
                onclick=_disclosure_onclick(false))(t.collapse_all)) : ""
    plans = reduce(vcat, (_phase_plan_html(entries, nested, i, t) for (i, entry) in enumerate(entries)
        if isnothing(entry.parent)); init=Any[])
    h.div(class=board ? "treebar-phase-overview treebar-board-overview" : "treebar-phase-overview")(controls, plans)
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
#
# `texts` (see `_texts`) is resolved once by the public call, which also marks
# its outermost element with the script's words (`_with_client_texts`). The
# recursion and every caller that renders a tree inside its own live region
# (poller, WebSocket frame, board, kept tree) call `_htmx_render` with the
# resolved texts instead: the region carries the words once.
htmx_render(node::ProgressNode; texts=nothing, kwargs...) =
    (t = _texts(texts); _with_client_texts(_htmx_render(node, t; kwargs...), t))

function _htmx_render(node::ProgressNode{<:StateProgress}, t::TreebarTexts; article=false, scoped=true, state::_RenderState=_render_state(node), seen::Base.IdSet{ProgressNode}=Base.IdSet{ProgressNode}(), walk::_DisplayTraversal=_DisplayTraversal(seen), max_finished=nothing, phase_overview::Union{Bool,Symbol}=false, kwargs...)
    is_displayed(node) || return ""
    sp = state
    children_node = isempty(node.children) ? "" : _htmx_render_children(node, t; scoped, seen, walk, max_finished)
    overview = _phase_overview_html(node, phase_overview, t)
    tree = begin
        duration_node = _duration_span(sp, t)
        interrupt_node = sp.interrupt ? h.span(class="treebar-interrupt")(t.interrupt) : ""
        pending = sp.status == "pending"
        node_class = pending      ? "treebar-node treebar-pending" :
                     sp.status == "skipped" ? "treebar-node treebar-skipped" :
                     sp.status == "reused"  ? "treebar-node treebar-reused"  :
                                    "treebar-node"
        if !isnothing(sp.N)
            # Progress bar with counter (pending → value=0, max=N, dim)
            h.div(class=node_class)(
                h.div(class="treebar-header")(
                    h.span(class="treebar-description")("$(sp.description):"),
                    h.span(class="treebar-count")("$(sp.i) / $(sp.N)"),
                    _isempty_text(sp.message) ? "" : h.span(class="treebar-message")(_note_text(sp.message, t)),
                    duration_node,
                    interrupt_node,
                ),
                h.progress(value=string(sp.i), max=string(sp.N), class="treebar-progress")(),
                children_node,
            )
        elseif !_isempty_text(sp.message)
            message = _note_text(sp.message, t)
            header_text = isempty(sp.description) ? message : "$(sp.description) $(message)"
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
    Treebars._overview_enabled(phase_overview) ? h.div(class="treebar-with-overview")(overview, tree) : tree
end

# Render a full progress tree rooted at node. Top-level root is always
# rendered (the wrapper div), but transparent children at this level are
# flattened away — their grandchildren render in their place. Same per-pass
# `seen` dedup as the StateProgress method above (kept in sync for any
# non-StateProgress backend that reaches this fallback).
function _htmx_render(node::ProgressNode, t::TreebarTexts; scoped=true, state=nothing, seen::Base.IdSet{ProgressNode}=Base.IdSet{ProgressNode}(), walk::_DisplayTraversal=_DisplayTraversal(seen), phase_overview::Union{Bool,Symbol}=false, kwargs...)
    children, _ = _displayed_children(node, walk)
    children_html = [_htmx_render(child, t; scoped, seen, walk, kwargs...) for child in children]
    h.div(class="treebar-root")(_phase_overview_html(node, phase_overview, t), children_html)
end

node_to_html(node) = sprint(io -> show(io, MIME"text/html"(), node))

# Initial pill visibility for every scope that holds pill state — a poller or
# board-item wrapper, a WebSocket frame, a scoped static `.treebar-children`:
# pending and failed children show; finished, skipped and reused children are
# terminal history with nothing left to do about them, so they hide behind
# their "N finished" / "N skipped" / "N reused" pills.
const _PILL_DEFAULTS = (; data_show_finished="0", data_show_pending="1",
    data_show_failed="1", data_show_skipped="0", data_show_reused="0")

# Pill onclick: prefer the scope that outlives updates — a .treebar-poller, a
# .treebar-board-item on a board, or a WebSocket frame (.treebar-ws-frame,
# replaced each frame but carried onto the next by htmx_treebar_script) — so
# toggles survive across updates; fall back to the closest .treebar-children
# for static one-shot renders (no wrapper in scope). The two-step `closest` (rather than one comma selector over all three)
# is intentional — `closest('.treebar-poller, .treebar-children')` returns
# whichever is the closer ancestor, which is always .treebar-children. The two
# wrappers share one selector: the nearer one governs its own subtree.
_pill_onclick(key) = """var s = this.closest('.treebar-poller, .treebar-board-item, .treebar-ws-frame') || this.closest('.treebar-children'); if(!s) return; s.dataset.$(key) = s.dataset.$(key) === '1' ? '0' : '1';"""

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
# `max_finished`: an OPT-IN cap on how many FINISHED children — and,
# separately, how many REUSED and SKIPPED ones — a `.treebar-children` container renders
# individually. The default is `nothing`, which renders every child: the user
# does not want capped output by default (feedback on decision `1vsha8b`).
# A caller that knowingly trades fidelity for poll cost can pass a number:
# rendering every hidden finished child cost ~14 ms / 220 KB per poll at 1k
# finished children and ~280 ms / 2.2 MB at 10k. Pending, running and failed
# children are never elided, and pills always count everything.

# Which children render individually: of the finished ones only the newest
# `max_finished` (last in `children` order, i.e. most recently attached), and
# likewise of the reused and the skipped ones. Returns a keep mask plus, keyed by the position
# of each group's first elided child, the one-line note standing in for the
# elided ones. The note carries that group's `treebar-child-*` class, so it
# shows and hides with the group's pill. `nothing` keeps everything.
function _elide_finished(statuses, max_finished, t::TreebarTexts)
    keep = trues(length(statuses))
    notes = Dict{Int,Node}()
    isnothing(max_finished) && return keep, notes
    for (word, text) in (("finished", t.elided_finished),
                         ("reused", t.elided_reused),
                         ("skipped", t.elided_skipped))
        idx = findall(==(word), statuses)
        n = length(idx) - max_finished
        n > 0 || continue
        keep[idx[1:n]] .= false
        notes[first(idx)] = h.div(class="treebar-child-$word treebar-elided")(_fill_text(text; n))
    end
    keep, notes
end

# Backends without StateProgress retain their public lifecycle predicates.
_child_status(::ProgressNode, state::_RenderState) = state.status
_child_status(node::ProgressNode, ::Nothing) =
    is_pending(node) ? "pending" : is_skipped(node) ? "skipped" :
    is_reused(node) ? "reused" : is_finished(node) ? "finished" :
    is_failed(node) ? "failed" : "running"

htmx_render_children(::Nothing; texts=nothing, kwargs...) =
    h.p(_texts(texts).starting; class="u-text-muted", aria_busy="true")
function htmx_render_children(node::ProgressNode{<:StateProgress}; texts=nothing, phase_overview::Union{Bool,Symbol}=false, kwargs...)
    t = _texts(texts)
    tree = _htmx_render_children(node, t; kwargs...)
    _with_client_texts(Treebars._overview_enabled(phase_overview) ?
        h.div(class="treebar-with-overview")(_phase_overview_html(node, phase_overview, t), tree) : tree, t)
end
function _htmx_render_children(node::ProgressNode{<:StateProgress}, t::TreebarTexts; scoped=true, seen::Base.IdSet{ProgressNode}=Base.IdSet{ProgressNode}(), walk::_DisplayTraversal=_DisplayTraversal(seen), max_finished=nothing)
    isnothing(max_finished) || max_finished >= 0 ||
        throw(ArgumentError("max_finished must be a non-negative integer or `nothing`, got $max_finished"))
    sp = node.impl
    # Flatten transparent children: each undisplayed child contributes
    # its own children at this level instead of itself. Grouping/pills/
    # CSS classes all see the hoisted view, which is the whole point of
    # the transparent flag. Then dedup (first-seen-wins) against this pass's
    # `seen` set.
    children, had_visible = _displayed_children(node, walk)
    # All of this node's children were already rendered elsewhere in this same
    # pass (DO's shared-substatus co-tree case) — the children SECTION is
    # empty, but unlike "genuinely no children yet" this isn't a pending/
    # spinner state, so emit nothing rather than fall into the message/
    # "Starting..." fallback below. The node's own header/duration still
    # render via the caller (`htmx_render`) — only this children section is
    # suppressed.
    isempty(children) && had_visible && return ""
    # A terminal node cannot still be starting or busy. This is reachable when
    # raw children exist but every one flattens away (for example, hidden leaf
    # nodes); the caller sees a non-empty `node.children` and therefore asks us
    # to render a children section even though there is nothing visible in it.
    if isempty(children) && (is_finished(sp) || is_failed(sp) || is_skipped(sp) || is_reused(sp))
        return ""
    end
    if isempty(children) && !_isempty_text(sp.message)
        return h.div(
            h.span(_note_text(sp.message, t); class="u-text-muted"),
            h.span(" "; aria_busy="true"),
        )
    end
    isempty(children) && return h.p(t.starting; class="u-text-muted", aria_busy="true")

    states = [_render_state(c) for c in children]
    statuses = [_child_status(c, state) for (c, state) in zip(children, states)]
    n_finished = n_failed = n_pending = n_skipped = n_reused = 0
    for status in statuses
        n_finished += status == "finished"
        n_failed += status == "failed"
        n_pending += status == "pending"
        n_skipped += status == "skipped"
        n_reused += status == "reused"
    end

    pills = Node[]
    if n_pending > 0
        push!(pills, h.span(class="treebar-pill treebar-pill-pending",
            onclick=_pill_onclick("showPending"))(_fill_text(t.pill_pending; n=n_pending)))
    end
    if n_finished > 0
        push!(pills, h.span(class="treebar-pill treebar-pill-finished",
            onclick=_pill_onclick("showFinished"))(_fill_text(t.pill_finished; n=n_finished)))
    end
    if n_reused > 0
        push!(pills, h.span(class="treebar-pill treebar-pill-reused",
            onclick=_pill_onclick("showReused"))(_fill_text(t.pill_reused; n=n_reused)))
    end
    if n_skipped > 0
        push!(pills, h.span(class="treebar-pill treebar-pill-skipped",
            onclick=_pill_onclick("showSkipped"))(_fill_text(t.pill_skipped; n=n_skipped)))
    end
    if n_failed > 0
        push!(pills, h.span(class="treebar-pill treebar-pill-failed",
            onclick=_pill_onclick("showFailed"))(_fill_text(t.pill_failed; n=n_failed)))
    end

    keep, notes = isnothing(max_finished) ? (nothing, nothing) : _elide_finished(statuses, max_finished, t)
    rendered = Any[]
    for (i, child) in enumerate(children)
        if !isnothing(keep)
            haskey(notes, i) && push!(rendered, notes[i])
            keep[i] || continue
        end
        cls = statuses[i] == "running" ? "" : "treebar-child-$(statuses[i])"
        inner = _htmx_render(child, t; scoped, seen, walk, max_finished, state=states[i])
        push!(rendered, isempty(cls) ? inner : h.div(class=cls)(inner))
    end

    # Static one-shot renders (no .treebar-poller wrapper in scope) need the
    # data attrs here so pills at this level can toggle visibility against
    # this scope. Inside a poller we leave them off so only the wrapper's
    # descendant CSS rule applies — otherwise the inner direct-child rule
    # would keep hiding finished children even after the wrapper toggle flips.
    #
    # `rendered` is passed as ONE Vector child, never splatted: HTMX flattens an
    # `AbstractVector` child one level (documented on `Node`/`h`), so the HTML is
    # byte-identical, without a call carrying thousands of arguments. HTMX
    # before `8a113ed` also handled varargs quadratically (measured 10k children:
    # 36 ms / 403 MB splatted vs 9 µs as a Vector), so this matters on older pins
    # too. The same holds for every other potentially long child list here.
    if scoped
        h.div(; class="treebar-children", _PILL_DEFAULTS...)(
            isempty(pills) ? "" : h.div(class="treebar-pills")(pills...),
            rendered,
        )
    else
        h.div(class="treebar-children")(
            isempty(pills) ? "" : h.div(class="treebar-pills")(pills...),
            rendered,
        )
    end
end
