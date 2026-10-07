# ──────────────────────────────────────────────────────────────────────────────
# Text rendering — inspect a progress tree with no web stack
#
# Every other render path (`htmx_render`, `ws_progress`) lives in the
# HTMXObjects/HTTP extensions and produces HTML for a browser. That leaves an
# author of new `@progress` instrumentation with no way to check their work:
# markers that silently render nothing (the docstring trap — see
# `_warn_swallowed_markers` in convenience.jl) are parse-clean and
# precompile-clean, so the FIRST observation of a broken phase tree happens in
# a browser, on a real run. `render_text` closes that loop — run the work under
# a `:state` root, dump the tree, assert on it:
#
#     tree = with_progress(:state; description="probe") do p
#         my_instrumented_function(...; progress=p)
#     end
#
# Display semantics are shared with the HTML renderer on purpose: both go
# through `_flatten_displayed_children` (bare-wrapper inlining / explicit
# `displayed=false` hoisting) and `_first_seen!` (identity dedup of the DAG
# edges DO's substatus fan-out creates). A text dump that disagreed with the
# browser about which nodes exist would be actively misleading — it would
# certify instrumentation that does not render.
# ──────────────────────────────────────────────────────────────────────────────

# Single-character lifecycle markers. Chosen to be visually distinct at a
# glance in a terminal and stable under grep/assertion (`occursin("✗", …)`).
_state_marker(node::ProgressNode) =
    is_failed(node)   ? "✗" :
    is_skipped(node)  ? "⊘" :
    is_reused(node)   ? "↺" :
    is_finished(node) ? "✓" :
    is_pending(node)  ? "·" :
                        "▶"

# One line for one node: marker, description, counter, running message,
# duration. Everything after the marker is optional — a bare wrapper reached
# directly (e.g. as the root of a `render_text` call) legitimately renders as
# just its marker.
function _text_summary(node::ProgressNode{<:StateProgress})
    sp = node.impl
    lock(sp.lock) do
        parts = String[_state_marker(node)]
        isempty(sp.description) || push!(parts, sp.description)
        isnothing(sp.N)         || push!(parts, "($(sp.i)/$(sp.N))")
        isempty(sp.message)     || push!(parts, "— $(sp.message)")
        # A pending, skipped, or never-entered reused node has no started_at,
        # so `duration` would report a meaningless 0s — omit it rather than
        # imply the phase has run. For a skipped or reused node that 0s would
        # be actively misleading: it is the one number that made a bypassed or
        # cached phase look like an instantaneous one.
        isnothing(sp.started_at) ||
            push!(parts, "[$(short_duration(duration(sp)))]")
        # ETA — non-nothing only for a running determinate node (0 < i < N),
        # so it never appears on a pending/skipped/finished/indeterminate one.
        let e = eta(sp)
            isnothing(e) || push!(parts, "· ETA ~$(short_duration(e))")
        end
        _shows_interrupt_request(node) && push!(parts, _INTERRUPT_TEXT)
        join(parts, " ")
    end
end

const _INTERRUPT_TEXT = "· interrupt requested"

# Content bits for a non-StateProgress node: the marker, interrupt flag and
# joinery stay here (shared with the StateProgress method's format), while the
# backend supplies its own middle. The default names the impl type; a backend
# extension with introspectable state (Term.jl jobs) overrides this to show it.
_impl_summary_bits(node::ProgressNode) = String[string(nameof(typeof(node.impl)))]
_text_summary(node::ProgressNode) = join(filter(!isempty, [
    _state_marker(node), _impl_summary_bits(node)...,
    _shows_interrupt_request(node) ? _INTERRUPT_TEXT : ""]), " ")

function _print_text_children(io::IO, node::ProgressNode, prefix::String, seen)
    children = filter(c -> _first_seen!(seen, c), _flatten_displayed_children(node))
    for (i, child) in enumerate(children)
        last = i == length(children)
        print(io, "\n", prefix, last ? "└─ " : "├─ ", _text_summary(child))
        _print_text_children(io, child, prefix * (last ? "   " : "│  "), seen)
    end
end

function _print_text_tree(io::IO, node::ProgressNode)
    seen = Base.IdSet{ProgressNode}()
    # Seed with the root so a node reachable from itself terminates rather
    # than recursing forever.
    _first_seen!(seen, node)
    print(io, _text_summary(node))
    _print_text_children(io, node, "", seen)
end

"""
    render_text(node; phase_overview=false) -> String

Render a progress tree as plain text — the node hierarchy with labels, phase
nesting, counters, running messages and lifecycle state. Works on a finished
**or** in-flight tree, needs no web stack, and is the intended way to verify
`@progress` instrumentation offline:

```julia
tree = with_progress(:state; description="probe") do p
    my_instrumented_function(x; progress=p)
end
println(render_text(tree))
```

```
▶ probe [1.2s]
├─ ✓ load data [0.4s]
├─ ▶ fit (3/10) — chain 2 [0.8s]
│  └─ · warmup
└─ · plot
```

Each line is `<state> <description> [(i/N)] [— message] [duration]`, where
state is `·` pending, `▶` running, `✓` finished, `↺` reused, `✗` failed, or
`⊘` skipped. Pending and skipped nodes show no duration because they never
started; a reused node shows one only if it was entered before
[`reuse_progress!`](@ref) marked it. A
pending or running node that [`request_interrupt!`](@ref) was called on ends in
`· interrupt requested` until it terminates.

Nodes are shown exactly as the HTML renderer would show them: bare wrappers
(no description, message or counter) and `displayed=false` nodes inline,
hoisting their children up a level, and a node attached under more than one
parent renders once per tree. So an empty result means the markers really did
not produce nodes — see [`@progress`](@ref) for why a bare `"label"` inside a
`begin … end` block is swallowed as a docstring. (A caller that opts into
`max_finished` on [`htmx_render_children`](@ref) gets an HTML render that
elides older finished/reused/skipped children; `render_text` always prints every
node.)

`show(io, MIME"text/plain"(), node)` renders the same thing, so a
`ProgressNode` displays as its tree at the REPL and under `@show`.

Returns `"(no progress tree)"` for `nothing`, matching the no-op-on-`nothing`
convention of the lifecycle functions.

Set `phase_overview=true` to prepend the per-plan phase counts from
[`phase_overview`](@ref); a plan declared inside another plan's phase is
indented under it and named after that phase. `phase_overview=:top` shows only
the outermost plans. `phase_overview=:collapsed` shows what the HTML view shows
before a viewer opens anything: outermost plans in full, and each plan nested
directly in them as one `▸ <caption>` line. The ordinary tree follows in full.
"""
function render_text(node::ProgressNode; phase_overview::Union{Bool,Symbol}=false)
    sprint() do io
        entries = _overview_entries(node, phase_overview)
        shown = falses(length(entries))
        for (i, entry) in enumerate(entries)
            # A collapsed plan shows its caption only and hides the plans nested in it.
            parent = entry.parent
            shown[i] = isnothing(parent) || (shown[parent] && entries[parent].open)
            shown[i] || continue
            indent = "  "^entry.depth
            if !entry.open
                println(io, indent, "▸ ", entry.caption)
                continue
            end
            println(io, indent, entry.caption)
            for phase in entry.plan.phases
                println(io, indent, "  ", phase.label, ": ",
                    join(("$(getproperty(phase, state)) $state" for state in
                        (:pending, :running, :finished, :reused, :failed, :skipped)), " · "))
            end
        end
        _print_text_tree(io, node)
    end
end
render_text(::Nothing; phase_overview::Union{Bool,Symbol}=false) = "(no progress tree)"

Base.show(io::IO, ::MIME"text/plain", node::ProgressNode) = _print_text_tree(io, node)

# Compact single-node form, for a ProgressNode nested inside another
# container's display. The multi-line tree is the 3-arg `text/plain` method
# above.
Base.show(io::IO, node::ProgressNode) = print(io, "ProgressNode(", _text_summary(node), ")")
