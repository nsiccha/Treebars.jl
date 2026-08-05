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
        # Neither a pending nor a skipped node has a started_at, so `duration`
        # would report a meaningless 0s — omit it rather than imply the phase
        # has run. For a skipped node that 0s would be actively misleading:
        # it is the one number that made a bypassed phase look like an
        # instantaneous one.
        (is_pending(sp) || is_skipped(sp)) ||
            push!(parts, "[$(short_duration(duration(sp)))]")
        # ETA — non-nothing only for a running determinate node (0 < i < N),
        # so it never appears on a pending/skipped/finished/indeterminate one.
        let e = eta(sp)
            isnothing(e) || push!(parts, "· ETA ~$(short_duration(e))")
        end
        join(parts, " ")
    end
end

# Backends other than StateProgress (Term.jl bars, custom impls) carry no
# introspectable state contract — name the impl type and let the tree shape
# carry the rest.
_text_summary(node::ProgressNode) = string(_state_marker(node), " ", nameof(typeof(node.impl)))

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
    render_text(node) -> String

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
state is `·` pending, `▶` running, `✓` finished, `✗` failed, or `⊘` skipped.
Pending and skipped nodes show no duration because they never started.

Nodes are shown exactly as the HTML renderer would show them: bare wrappers
(no description, message or counter) and `displayed=false` nodes inline,
hoisting their children up a level, and a node attached under more than one
parent renders once per tree. So an empty result means the markers really did
not produce nodes — see [`@progress`](@ref) for why a bare `"label"` inside a
`begin … end` block is swallowed as a docstring.

`show(io, MIME"text/plain"(), node)` renders the same thing, so a
`ProgressNode` displays as its tree at the REPL and under `@show`.

Returns `"(no progress tree)"` for `nothing`, matching the no-op-on-`nothing`
convention of the lifecycle functions.
"""
render_text(node::ProgressNode) = sprint(_print_text_tree, node)
render_text(::Nothing) = "(no progress tree)"

Base.show(io::IO, ::MIME"text/plain", node::ProgressNode) = _print_text_tree(io, node)

# Compact single-node form, for a ProgressNode nested inside another
# container's display. The multi-line tree is the 3-arg `text/plain` method
# above.
Base.show(io::IO, node::ProgressNode) = print(io, "ProgressNode(", _text_summary(node), ")")
