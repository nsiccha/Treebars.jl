module HTMXObjectsExt
import HTMXObjects
import Treebars
import HTMXObjects: h, Node, Raw, fetchindex
import HTTP
import JSON
import HTTP.WebSockets: WebSocket, send
import Treebars: htmx_render, htmx_render_children, htmx_treebar_styles, htmx_treebar_script,
    ws_progress, htmx_ws_render, htmx_ws_progress, polling_fetchindex,
    htmx_render_board, htmx_ws_render_board, ws_board,
    ProgressNode, StateProgress, root, is_pending, is_running, is_finished, is_failed, is_skipped, is_reused, is_displayed, _renders_self, duration, eta, short_duration, _first_seen!,
    _displayed_children, _DisplayTraversal, _shows_interrupt_request
import Treebars: TreebarTexts, _EN_TEXTS, _lang_texts, _fill_text, _duration_text, _note_text, _isempty_text
import Treebars: add_child!
import Treebars: initialize_progress!, update_progress!, start_progress!, finalize_progress!, fail_progress!
import Treebars: current_dispatch_parent
import Dates
using Dates: Millisecond

# The texts a render writes in (`treebar_texts`). An explicit `texts=` wins;
# left out, the language of the HTMXObjects answer being rendered decides: the
# `__lang__` its route's mount chain declares, read through
# `HTMXObjects.page_lang()`. An HTMXObjects generation without that accessor,
# or a render outside any answer, writes English. Each public entry point
# resolves once and threads the value down, so one render speaks one language.
_page_lang() = isdefined(HTMXObjects, :page_lang) ? HTMXObjects.page_lang() : nothing
_texts(::Nothing) = _lang_texts(_page_lang())
_texts(texts::TreebarTexts) = texts
_texts(texts) = throw(ArgumentError(string(
    "texts must be a TreebarTexts, e.g. treebar_texts(:de); got ", repr(texts))))

# Whether a live region shows its pause/play control (`pause=`): the poller
# badge's ❚❚ and a live board's Pause. An explicit Bool wins; left out, the
# HTMXObjects answer being rendered decides, exactly as for `texts`: the
# `__progress_pause__` its route's mount chain declares, read through
# `HTMXObjects.page_progress_pause()` (`nothing` when the chain declares none).
# An HTMXObjects generation without that accessor, a chain that declares
# nothing, or a render outside any answer shows the control. A visitor-facing
# app declares `__progress_pause__ = false` once on its root (snag
# visitor-apps-can-148cfaf6). Resolved once per public entry point and threaded
# down, like the texts.
_page_pause() = isdefined(HTMXObjects, :page_progress_pause) ? HTMXObjects.page_progress_pause() : nothing
_pause(::Nothing) = _page_pause_value(_page_pause())
_pause(pause::Bool) = pause
_pause(pause) = throw(ArgumentError(string(
    "pause must be true, false, or nothing to follow the page's `__progress_pause__`; got ", repr(pause))))
_page_pause_value(::Nothing) = true
_page_pause_value(pause::Bool) = pause
_page_pause_value(pause) = throw(ArgumentError(string(
    "HTMXObjects.page_progress_pause() must return true, false or nothing; got ", repr(pause))))

# The words `htmx_treebar_script` writes itself — a ticking duration, the
# badge's status mirror and pause label, the freshness notes, a board item
# that ended, the board's Pause label, and the duration units — as the JSON
# object it reads from the nearest `data-treebar-texts`. Each live region
# (poller wrapper, WebSocket frame, board) and each standalone tree carries
# it, but only when the words are not the script's own English, so English
# markup is unchanged.
const _CLIENT_TEXTS = (:running, :eta, :polling, :paused, :pause, :resume, :stale, :updated,
    :connection_lost, :updates_failing, :retrying, :ended, :board_pause, :board_resume,
    :unit_ms, :unit_s, :unit_min, :unit_h, :unit_d, :unit_space, :decimal)

# A single-quoted JavaScript string literal, for the words inline onclick
# handlers write.
_js_string(s::AbstractString) = string("'",
    replace(s, '\\' => "\\\\", '\'' => "\\'", '\n' => "\\n", '\r' => "\\r"), "'")

_client_texts_json(t::TreebarTexts) =
    JSON.json(NamedTuple{_CLIENT_TEXTS}(map(n -> getfield(t, n), _CLIENT_TEXTS)))
const _EN_CLIENT_TEXTS_JSON = _client_texts_json(_EN_TEXTS)

# The `data-treebar-texts` value for `t`, or `nothing` (no attribute) for the
# script's own English.
_client_texts_attr(t::TreebarTexts) =
    (json = _client_texts_json(t); json == _EN_CLIENT_TEXTS_JSON ? nothing : json)

# A standalone tree's outermost element with the texts its script words need;
# an empty render stays empty.
_with_client_texts(x::Node, t::TreebarTexts) =
    (json = _client_texts_attr(t); isnothing(json) ? x : x(; data_treebar_texts=json))
_with_client_texts(x, ::TreebarTexts) = x

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
# A WebSocket frame replaces its whole `<div id>` on every update. The frame is
# its tree's pill scope — the tree renders unscoped below it, as under a
# poller — and htmx_treebar_script copies a viewer's pill toggles from each
# frame onto the next frame with the same id. Its leading freshness span is
# where the script says the stream has gone stale or its socket is lost; the
# last frame stays on screen when no more arrive.
_ws_frame(node, t::TreebarTexts; id, phase_overview::Union{Bool,Symbol}=false) =
    h.div(; id, class="treebar-ws-frame", _PILL_DEFAULTS..., data_treebar_texts=_client_texts_attr(t))(
        _freshness_span(), _htmx_render(node, t; scoped=false, phase_overview))

htmx_ws_render(node::ProgressNode; id="treebar-progress", phase_overview::Union{Bool,Symbol}=false, texts=nothing) =
    node_to_html(_ws_frame(node, _texts(texts); id, phase_overview))

function htmx_ws_progress(content; url::AbstractString, id::AbstractString,
        progress=nothing, description=nothing, N=nothing, collapsed::Bool=false, phase_overview::Union{Bool,Symbol}=false,
        texts=nothing)
    isempty(id) && throw(ArgumentError("htmx_ws_progress requires a nonempty unique id"))
    t = _texts(texts)
    node = isnothing(progress) ?
        initialize_progress!(:state; description=something(description, t.working), N, pending=true) : progress
    h.div(; hx_ext="ws", ws_connect=url)(
        content,
        h.details(; id=id * "-disclosure", open=(collapsed ? nothing : true))(
            h.summary(t.progress),
            _ws_frame(node, t; id=id * "-progress", phase_overview)),
        h.div(; id=id * "-updates")(),
    )
end

_ws_progress_root(::Nothing, N; description) = initialize_progress!(:state; description, N)
_ws_progress_root(parent::ProgressNode, N; description) =
    initialize_progress!(parent, N; description, transient=false)

function _validate_ws_progress(id, interval, min_interval, buffer)
    isempty(id) && throw(ArgumentError("ws_progress requires a nonempty unique id"))
    interval > 0 || throw(ArgumentError("ws_progress interval must be positive"))
    min_interval >= 0 || throw(ArgumentError("ws_progress min_interval must be nonnegative"))
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

function _ws_progress_frame(id, progress, fragments, t::TreebarTexts; phase_overview::Union{Bool,Symbol}=false)
    payload = node_to_html(_ws_frame(progress, t; id=id * "-progress", phase_overview))
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
    isempty(plain) || (payload *= node_to_html(h.div(; id=id * "-updates")(plain)))
    for f in oob
        payload *= node_to_html(f)
    end
    payload
end

function ws_progress(produce::Function, ws::WebSocket; id::AbstractString,
        description=nothing, N=nothing, parent=nothing, interval=0.1, min_interval=0.016,
        buffer::Integer=64, phase_overview::Union{Bool,Symbol}=false, texts=nothing)
    _validate_ws_progress(id, interval, min_interval, buffer)
    t = _texts(texts)
    node = _ws_progress_root(parent, N; description=something(description, t.working))
    ws_progress(produce, ws, node; id, interval, min_interval, buffer, phase_overview, texts=t)
end

# The texts are resolved here, in the route's own task: the sender below runs
# on another task, which cannot see the answer's language.
function ws_progress(produce::Function, ws::WebSocket, node::ProgressNode{<:StateProgress};
        id::AbstractString, interval=0.1, min_interval=0.016, buffer::Integer=64,
        phase_overview::Union{Bool,Symbol}=false, texts=nothing)
    _validate_ws_progress(id, interval, min_interval, buffer)
    t = _texts(texts)
    (is_pending(node) || is_running(node)) ||
        throw(ArgumentError("ws_progress producer requires a pending or running node"))
    start_progress!(node)
    queue = Channel{Any}(buffer)
    # Publishing and finishing wake the sender, so a fragment and the final
    # tree leave as soon as the sender is free, not at the next `interval`.
    wake = Base.Event(true)
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
        notify(wake)
        nothing
    end
    # Render outside the send catch: serialization errors are not disconnects.
    initial = htmx_ws_render(node; id=id * "-progress", phase_overview, texts=t)
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
            notify(wake)
        end
    end
    render_live = progress -> begin
        # Everything published before this point rides this frame.
        reset(wake)
        fragments = Any[]
        for _ in 1:buffer
            isready(queue) || break
            push!(fragments, take!(queue))
        end
        _ws_progress_frame(id, progress, fragments, t; phase_overview)
    end
    result = nothing
    try
        # The route's own task is sticky to one thread, which a producer that
        # never yields can occupy until it finishes. The sender gets its own
        # task, free to run on any idle thread (the interactive pool if any).
        connected[] && fetch(Threads.@spawn :interactive ws_progress(ws, node;
            interval, min_interval, wake, render=render_live))
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
function _board_duration_span(state::Symbol, ms::Int, position, t::TreebarTexts)
    d = _duration_text(Millisecond(ms), t)
    cls = "treebar-duration treebar-board-duration"
    if state === :queued
        text = " — " * (isnothing(position) ? t.queued : _fill_text(t.queued_position; position))
        return h.span(class=cls, data_treebar_status="pending")(text)
    end
    status, text = state === :running ? ("running", " — " * _fill_text(t.running; elapsed=d)) :
                   state === :done    ? ("finished", " — " * _fill_text(t.done; elapsed=d)) :
                                        ("failed", " — " * _fill_text(t.failed; elapsed=d))
    h.span(class=cls, data_treebar_status=status, data_elapsed_ms=string(ms))(text)
end

# The tree collapses under the item header. `scoped=false`: the item wrapper
# carries the data-show-* pill state, like `.treebar-poller` does. A terminal
# item's tree is frozen, so a node it still holds as "running" does not tick.
function _board_tree(node, t::TreebarTexts; open::Bool, frozen::Bool)
    body = node isa ProgressNode ? _htmx_render(node, t; scoped=false) : node
    cls = frozen ? "treebar-board-tree treebar-frozen" : "treebar-board-tree"
    open ? h.details(class=cls, open=true)(h.summary(t.progress), body) :
           h.details(class=cls)(h.summary(t.progress), body)
end

function _board_item(entry, t::TreebarTexts; expanded::Bool)
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
    h.div(; class="treebar-board-item",
        data_treebar_key=string(entry.key),
        data_treebar_state=string(state),
        data_open=expanded ? "1" : "0",
        _PILL_DEFAULTS...)(
        h.div(class="treebar-board-item-content")(
            h.div(class="treebar-board-item-header")(
                label_node,
                _board_duration_span(state, ms, position, t),
                isempty(shown) ? "" : h.div(class="treebar-board-meta")(shown...),
            ),
            isnothing(node) ? "" : _board_tree(node, t; open=expanded, frozen=state in (:done, :failed)),
        ),
    )
end

# Board-level Pause: toggles data-paused on the board; the script then cancels
# its poll requests, drops pushed frames, freezes its clocks and holds lingering
# items — the `.treebar-pause` mechanism, keyed on the board.
_board_pause_button(t::TreebarTexts) = h.button(class="treebar-board-pause", type="button",
    onclick="var b=this.closest('.treebar-board'); if(!b) return; var v=b.dataset.paused==='1'?'0':'1'; b.dataset.paused=v; this.textContent=v==='1'?$(_js_string(t.board_resume)):$(_js_string(t.board_pause));")(t.board_pause)

function _board_count(entries, t::TreebarTexts)
    n_running = count(e -> Symbol(e.state) === :running, entries)
    n_queued = count(e -> Symbol(e.state) === :queued, entries)
    text = n_queued == 0 ? _fill_text(t.board_running; running=n_running) :
        _fill_text(t.board_running_queued; running=n_running, queued=n_queued)
    h.span(class="treebar-board-count", data_running=string(n_running),
           data_queued=string(n_queued))(text)
end

function htmx_render_board(entries; poll_url=nothing, poll_interval="1s",
        empty=nothing, id="treebar-board", linger_ms::Integer=3000,
        expanded::Bool=false, live::Bool=!isnothing(poll_url), phase_overview::Union{Bool,Symbol}=false,
        texts=nothing, pause=nothing)
    t = _texts(texts)
    show_pause = _pause(pause)
    empty = something(empty, t.no_jobs)
    # First occurrence of a key wins: the client matches items by key, so a
    # duplicate would make two DOM items fight over one identity.
    seen = Set{String}()
    unique_entries = [e for e in entries if !(string(e.key) in seen) && (push!(seen, string(e.key)); true)]
    items = [_board_item(e, t; expanded) for e in unique_entries]
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
          data_treebar_linger_ms=string(linger_ms), data_treebar_texts=_client_texts_attr(t))(
        h.div(class="treebar-board-header")(
            _board_count(unique_entries, t),
            live ? _freshness_span() : "",
            (live && show_pause) ? _board_pause_button(t) : "",
        ),
        Treebars._overview_enabled(phase_overview) ? _phase_overview_html(
            [node for e in unique_entries for node in (_board_get(e, :node, nothing),)
                if node isa ProgressNode], phase_overview, t; board=true) : "",
        h.div(class="treebar-board-list")(items),
        empty_node,
        poller,
    )
end

htmx_ws_render_board(entries; kwargs...) =
    node_to_html(htmx_render_board(entries; live=true, kwargs..., poll_url=nothing))

# The texts and the pause control are resolved once, in the route's task, for
# every frame.
function ws_board(ws::WebSocket, entries; interval=1.0, until=() -> false, texts=nothing, pause=nothing, kwargs...)
    t = _texts(texts)
    show_pause = _pause(pause)
    while true
        stop = until()
        frame = htmx_ws_render_board(entries(); texts=t, pause=show_pause, kwargs...)
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
    polling_fetchindex(render_result, ip, keys...; poll_context=nothing, poll_url=nothing, label=nothing, force=false, poll_interval="200ms", cancel_url="", sync=false, keep_progress=true, error_obj=nothing, req=nothing, parent=:auto, chrome=:auto, track_job=true, texts=nothing, pause=nothing, kwargs...)

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
`-pending` / `-skipped` / `-reused`, set by pill clicks, and `data-chrome`)
persists across polls.

The badge also says how current the tree is: after five intervals (at least
5s) without an update it reads "Updated 1m 4s ago", and once every poll has
failed for 5s straight (server down, gateway 5xx) it reads "Connection lost ·
updated … · retrying", dims the tree and holds its clocks. Polling never
stops on failure, and the first successful poll clears the notice.

A push source (a server-sent-events stream, a custom socket) can feed the
poller instead of its polls: `window.treebarUpdatePoller(el, html)` applies
one pushed answer (the response a poll would have received) exactly as a poll
answer, and `window.treebarUpdatePoller(el)` confirms the shown answer is still
current. The answer is first offered to `htmx:beforeSwap` on the polling
element, so a page's swap gate or rewrite covers it as it covers a poll answer:
the detail has a poll answer's fields, without `xhr` since no request ran, plus
`treebarPushed: true`. A listener can skip the answer (`shouldSwap = false` or
`preventDefault()`), which still confirms the poller live, or change
`serverResponse`, `target`, `selectOverride`, `ignoreTitle` and the style in
`swapOverride` (its modifiers have no effect).
While pushed, the poller's own polls are suspended, the answer of a
poll already in flight is dropped (that poll is left to finish, because htmx
reports an aborted request as an error), a paused poller holds the newest
pushed answer until resume, and the badge stays live as long
as the source confirms it at least every five intervals (at least 5s).
`window.treebarPollerLost(el, why)` hands the poller back to its polls; if
those fail too, it reads "Connection lost" (`why` empty) or "Updates failing
(why)". `el` is the `.treebar-poller` wrapper or any element in it; both
return `false` once the poller has finished, failed or left the page.

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
- `sync`: resolve now — wait for the compute and return the final fragment,
  with no poller (default `false`). The result is still wrapped in the
  `.treebar-terminal` `<div>`s: `sync` skips polling, not the wrapper. So it is
  not a way to hand a caller the raw value: a `render_result` that returns an
  `HTTP.Response` or an HTMXObjects `MIMEResponse` / `JSONResponse` has it
  written into the HTML, and a warning says so once. To answer with the raw
  value, resolve the IP yourself (`fetchindex` / `fetch`) and return it from
  the route.
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
- `texts`: the [`TreebarTexts`](@ref) every word of the poller is written in —
  badge status, pause control, Stop button, interim header, durations, pills
  and the kept tree. Left at `nothing` it follows the page language of the
  HTMXObjects answer (`__lang__`, see [`htmx_render`](@ref)); the wrapper
  carries the words the page script writes between polls.
- `pause`: whether the badge shows its ❚❚ pause/play control. Left at
  `nothing` it follows the page, like `texts`: under an HTMXObjects route whose
  mount chain declares `__progress_pause__ = false` (read through
  `HTMXObjects.page_progress_pause()`, on an HTMXObjects that provides it) the
  poller has no pause control, which is what a visitor-facing app wants, since
  pausing only freezes the display while the work runs on. Otherwise the
  control shows. `true` / `false` decide for this poller; anything else throws
  `ArgumentError`. The status word, bar, elapsed time, freshness note and any
  Stop button stay either way.
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
function polling_fetchindex(render_result, ip, keys...; poll_context=nothing, poll_url=nothing, label=nothing, force=false, poll_interval="200ms", cancel_url="", sync=false, keep_progress=true, error_obj=nothing, req=nothing, parent=:auto, chrome=:auto, track_job=true, phase_overview::Union{Bool,Symbol}=false, texts=nothing, pause=nothing, kwargs...)
    chrome in (:auto, :quiet) || throw(ArgumentError("polling_fetchindex: chrome must be :auto or :quiet, got $(repr(chrome))"))
    t = _texts(texts)
    show_pause = _pause(pause)
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
                             ip_ctx=_ip_ctx(ip, keys, kwargs), chrome=chrome, phase_overview, texts=t, pause=show_pause)
        end
    catch err
        (keep_progress && !sync) || rethrow()
        _polling_wrap(_polling_inner_done(_caught_error_ex(err, error_obj, req),
                                          _kept_progress(HTMXObjects.getstatus(ip, keys...; kwargs...), t; open=true, phase_overview));
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
_polling_resolve(rv::Task, status; sync=false, keep_progress=true, label, poll_url, poll_interval, cancel_url, render_result, ip_ctx="", chrome=:auto, phase_overview::Union{Bool,Symbol}=false, texts::TreebarTexts=_EN_TEXTS, pause::Bool=true) =
    istaskfailed(rv) ? throw(rv.result) :
    sync ? _polling_resolve(fetch(rv), status; sync, keep_progress, label, poll_url, poll_interval, cancel_url, render_result, ip_ctx, chrome, phase_overview, texts, pause) :
        _polling_running(status; label, poll_url, poll_interval, cancel_url, chrome, phase_overview, texts, pause)

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
function _polling_resolve(rv, status; sync=false, keep_progress=true, label, poll_url, poll_interval, cancel_url, render_result, ip_ctx="", chrome=:auto, phase_overview::Union{Bool,Symbol}=false, texts::TreebarTexts=_EN_TEXTS, pause::Bool=true)
    if _is_unresolved_handle(rv)
        return sync ?
            _polling_resolve(fetch(rv), status; sync, keep_progress, label, poll_url, poll_interval, cancel_url, render_result, ip_ctx, chrome, phase_overview, texts, pause) :
            _polling_running(status; label, poll_url, poll_interval, cancel_url, chrome, phase_overview, texts, pause)
    end
    # A READY handle must never reach render_result raw — resolve it here. This is
    # the guard that `e6f140f` dropped (it deleted `_assert_resolved` and traded
    # Pending-type dispatch for the not-ready duck-test above, which cannot see a
    # ready handle). A compatible ready handle is a legal completion race, so it
    # is normalized silently rather than diagnosed as package skew.
    if _is_handle(rv)
        return _polling_resolve(fetch(rv), status; sync, keep_progress, label, poll_url, poll_interval, cancel_url, render_result, ip_ctx, chrome, phase_overview, texts, pause)
    end
    body = render_result(rv)
    _warn_wrapped_response(body)
    (keep_progress && !sync) ?
        _polling_wrap(_polling_inner_done(body, _kept_progress(status, texts; open=false, phase_overview)); terminal=true) :
        _polling_wrap(_polling_inner_done(body); terminal=true)
end

# A callback that returns a finished answer (a response, not content) has it
# serialized into the poller's HTML, so the caller gets markup where it expected
# JSON or markdown and fails downstream with a serialization error.
# The caller should return the raw
# value from the route instead — so this only says so, once.
_warn_wrapped_response(@nospecialize(body)) = nothing
_warn_wrapped_response(body::Union{HTTP.Response,HTMXObjects.MIMEResponse}) = _warn_wrapped(body)
# `JSONResponse` exists only on newer HTMXObjects.
@static if isdefined(HTMXObjects, :JSONResponse)
    _warn_wrapped_response(body::HTMXObjects.JSONResponse) = _warn_wrapped(body)
end
_warn_wrapped(body) = @warn "polling_fetchindex: render_result returned a $(nameof(typeof(body))), which is written into the poller's HTML instead of being returned. To answer with it, resolve the IP yourself (fetchindex / fetch) and return it from the route." maxlog=1

# Frozen progress tree kept in the final (non-polling) response so a finished or
# failed run can be inspected after polling stops. scoped=true → the
# finished/failed/pending pills act as a static inspector; wrapped in a
# <details> (collapsed on success — stays out of the way; open on failure —
# failed node visible). `treebar-frozen` makes the client ticker skip it, so a
# terminal tree still holding a "running" node is static, not counting up.
# Empty string when there is no status node.
function _kept_progress(status, t::TreebarTexts; open::Bool=false, phase_overview::Union{Bool,Symbol}=false)
    isnothing(status) && return ""
    body = (h.summary(t.progress), _htmx_render(status, t; scoped=true, phase_overview))
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
        !_isempty_text(sp.message) && return !get(status.meta, :annotation, false)
        !isempty(sp.description)
    end
end

# True when the poller `label` restates the status root's description: the
# badge-label and interim-header copies are redundant with the root header.
_label_restates_root(label, status) =
    !isnothing(label) && _status_root_description(status) == string(label)

function _polling_running(status; label, poll_url, poll_interval, cancel_url, chrome=:auto, phase_overview::Union{Bool,Symbol}=false, texts::TreebarTexts=_EN_TEXTS, pause::Bool=true)
    t = texts
    stop_btn = isempty(cancel_url) ? "" : h.a(t.stop; role="button", class="outline secondary treebar-stop",
        hx_get=cancel_url, hx_target="closest div", hx_swap="outerHTML")
    inner_body = if isnothing(label)
        _polling_status_tree(status, t; article=true, scoped=false, phase_overview)
    elseif _label_restates_root(label, status)
        # The badge and the root header already carry this string — an
        # interim "<label> — running..." header would restate it a third
        # time. Only the redundant header line goes: the article wrapper
        # stays, and a configured Stop control stays inside it.
        h.article(stop_btn, _polling_status_tree(status, t; scoped=false, phase_overview))
    else
        h.article(h.header(_fill_text(t.running_header; label), stop_btn), _polling_status_tree(status, t; scoped=false, phase_overview))
    end
    _polling_wrap(_polling_inner_running(poll_url, poll_interval, inner_body);
                  pausable=true, badge=_poll_badge(label, status, t; pause), chrome=chrome, texts=t)
end

# The live tree inside a poller. A missing status keeps `htmx_render`'s own
# answer (its error pointing at the uninitialized `__status__`).
_polling_status_tree(status::ProgressNode, t::TreebarTexts; kwargs...) = _htmx_render(status, t; kwargs...)
_polling_status_tree(status, t::TreebarTexts; kwargs...) = htmx_render(status; kwargs...)

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
_pause_button(t::TreebarTexts) = h.button(class="treebar-pause", type="button",
    aria_label=t.pause,
    title=t.pause_title,
    onclick="var p=this.closest('.treebar-poller'); if(!p) return; if(!p.querySelector(':scope > .treebar-poller-inner[hx-trigger]')) return; var v=p.dataset.paused==='1'?'0':'1'; p.dataset.paused=v; var play=v==='1'; this.textContent=play?'▶':'❚❚'; this.setAttribute('aria-label',play?$(_js_string(t.resume)):$(_js_string(t.pause))); if(window.__tbSyncBadge) window.__tbSyncBadge(p);")("❚❚")

# First-paint badge content. The status word and elapsed are server-rendered
# once; the client mirror owns them afterwards. The bar starts indeterminate
# (no value/max) and the mirror sets the determinate fraction from the first
# `.treebar-progress` in the inner — the bar's shape is a client derivation,
# not a second server render rule. The label never changes across polls, so
# the server owns it outright and the mirror never touches it.
_badge_elapsed(::Nothing, t::TreebarTexts) = t.badge_starting
_badge_elapsed(node::ProgressNode, t::TreebarTexts) =
    node.impl isa StateProgress ? _initial_duration_text(node.impl, t) : ""

function _poll_badge(label, status, t::TreebarTexts; pause::Bool=true)
    h.span(class="treebar-badge")(
        h.span(class="treebar-badge-strip", aria_hidden="true")(),
        h.span(class="treebar-badge-panel")(
            # `pause=false`: no control at all (a visitor-facing page; see
            # `_pause`). The mirror tolerates its absence.
            pause ? _pause_button(t) : "",
            # No badge label when there is none to show, or when it would
            # restate the root header one line below (dedup, see above).
            (isnothing(label) || _label_restates_root(label, status)) ? "" :
                h.span(class="treebar-badge-label")(string(label)),
            h.span(class="treebar-badge-status")(t.polling),
            _freshness_span(),
            h.progress(class="treebar-badge-bar")(),
            # No badge elapsed when the root row renders its own duration
            # span (dedup, see above). The client mirror tolerates the
            # absent span — it re-checks `querySelector` every tick.
            _root_renders_duration(status) ? "" :
                h.span(class="treebar-badge-elapsed")(_badge_elapsed(status, t)),
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
_polling_wrap(inner; pausable=false, terminal=false, badge="", chrome=:auto, texts::TreebarTexts=_EN_TEXTS) =
    terminal ?
        h.div(class="treebar-terminal")(inner) :
        h.div(; class="treebar-poller",
            data_chrome=(chrome === :quiet ? "quiet" : nothing),
            data_paused="0",
            _PILL_DEFAULTS...,
            data_treebar_texts=_client_texts_attr(texts))(pausable ? badge : "", inner)

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
- `texts`: the language of the frames (see [`htmx_render`](@ref)), resolved
  when the route calls this
- `kwargs...`: passed through to `fetchindex`
"""
function polling_fetchindex(ws::WebSocket, render_result, ip, keys...;
        id="treebar-progress", interval=0.1, force=false, phase_overview::Union{Bool,Symbol}=false, texts=nothing, kwargs...)
    # Resolved in the route's task; `ws_progress` renders from its own loop.
    t = _texts(texts)
    progress_render(node) = htmx_ws_render(node; id, phase_overview, texts=t)
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

include("htmx_precompile.jl")

end
