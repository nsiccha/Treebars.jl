struct IncrementBy{di}
    IncrementBy(di) = new{di}()
end

"""
    ProgressNode{I,M,C}

Tree node of a Treebars progress tree. Wraps a backend-specific `impl`
(`StateProgress`, Term.jl `ProgressBar` / `ProgressJob`, …) plus metadata,
a (possibly `nothing`) parent, and a thread-safe set of children.

All progress operations (`update_progress!`, `finalize_progress!`,
`fail_progress!`, `add_child!`, …) dispatch through `ProgressNode` to the
backend `impl`, and children are tracked automatically by the constructor.
Prefer the convenience entry points ([`@progress`](@ref),
[`with_progress`](@ref), [`with_prepared_phases`](@ref)) over building
`ProgressNode`s by hand.
"""
struct ProgressNode{I,M,C}
    impl::I
    meta::M
    parent::Union{ProgressNode,Nothing}
    children::C
    function ProgressNode(impl, meta=(;propagates=false); parent=nothing, children=ThreadsafeSet{ProgressNode}())
        rv = new{typeof(impl),typeof(meta),typeof(children)}(
            impl, meta, parent, children
        )
        isnothing(parent) || push!(parent.children, rv)
        rv
    end
end

ProgressNode(children::AbstractVector; description="", kwargs...) =
    ProgressNode(StateProgress(; description, kwargs...), (;propagates=false);
        children=ThreadsafeSet{ProgressNode}(filter(!isnothing, children)))

root(node::ProgressNode) = isnothing(node.parent) ? node : root(node.parent)

"""
    add_child!(parent, child)

Attach `child` as a child of `parent`. No-op when either argument is `nothing`,
which makes it safe to use with optional/disabled progress trees.
"""
add_child!(parent::ProgressNode, child::ProgressNode) = push!(parent.children, child)
add_child!(::Nothing, ::Any) = nothing
add_child!(::Any, ::Nothing) = nothing
istransient(node::ProgressNode) = get(node.meta, :transient, false)
propagates_finalization(node::ProgressNode) = get(node.meta, :propagates, false)
labels(node::ProgressNode) = get(node.meta, :labels, nothing)

"""
    is_displayed(node) -> Bool

Render-only flag. `true` (the default) means the node renders normally;
`false` makes the node a **transparent passthrough** — it still exists in
the tree (children can parent under it, the full
`start_progress!` / `update_progress!` / `fail_progress!` /
`finalize_progress!` lifecycle still runs), but at render time the node
itself emits nothing and its children are hoisted one level up into the
parent's children container.

The display **preference** is three-state (`_display_pref`): `true` / `false`
set explicitly via `displayed=` on [`initialize_progress!`](@ref) /
[`prepare_progress!`](@ref), or *unset* (the default). `is_displayed`
collapses that to a `Bool` — only an explicit `false` hides; unset and
explicit `true` both report `true`.

Note the render side (`_renders_self`) goes one step further: a node with
**no preference set** that is also a bare wrapper (no description, message,
or counter) is inlined just like an explicit `displayed=false`, so
undecorated structural nodes don't add empty levels to the rendered tree.

Returns `false` for `nothing` (a no-op target has nothing to render).
"""
is_displayed(node::ProgressNode) = get(node.meta, :displayed, true) !== false
is_displayed(::Nothing) = false

# Raw three-state display preference: `true`/`false` when set explicitly via
# `displayed=`, or `nothing` when the caller expressed none. `_renders_self`
# uses this to tell "explicitly show/hide" apart from "decide automatically".
_display_pref(node::ProgressNode) = get(node.meta, :displayed, nothing)
# `_is_bare_wrapper` / `_renders_self` are defined below, after the
# `StateProgress` struct, since their dispatch mentions that type.

# Initialize a child progress node. `displayed` is a three-state preference:
# `false` = transparent passthrough, `true` = always render, `nothing`
# (default) = let the render side decide (bare wrappers inline). Lifecycle is
# unaffected either way — this is render-side only.
function initialize_progress!(node::ProgressNode, args...; transient=false, propagates=false, displayed=nothing, kwargs...)
    ProgressNode(
        initialize_progress!(node.impl, args...; transient, propagates, kwargs...),
        (; propagates, transient, displayed, labels=ThreadsafeDict{Symbol,Any}());
        parent=node
    )
end

"""
    prepare_progress!(parent, args...; kwargs...)

Create a child progress node in the **pending** state — visible in the tree but
not yet started. Call [`start_progress!`](@ref) to transition it to running.

Used by the `@progress begin … end` macro to pre-enumerate phase markers so
the whole pipeline is visible from the outset.
"""
prepare_progress!(node::ProgressNode, args...; kwargs...) =
    initialize_progress!(node, args...; pending=true, kwargs...)

"""
    start_progress!(node)

Transition a pending progress node to running. Idempotent — no-op if the node
has already started or finished.
"""
start_progress!(node::ProgressNode) = (start_progress!(node.impl); node)

# Update: forward to impl, then handle kwargs as labeled sub-nodes
update_progress!(node::ProgressNode; kwargs...) = update_progress!(node, IncrementBy(1); kwargs...)
function update_progress!(node::ProgressNode, i; kwargs...)
    update_progress!(node.impl, i)
    _update_labels!(node; kwargs...)
end
update_progress!(node::ProgressNode, ::Nothing; kwargs...) = _update_labels!(node; kwargs...)
function update_progress!(node::ProgressNode, msg::AbstractString; kwargs...)
    update_progress!(node.impl, msg)
    _update_labels!(node; kwargs...)
end

# Handle kwargs as labeled child nodes (like WarmupHMC's labels pattern)
function _update_labels!(node::ProgressNode; kwargs...)
    labs = labels(node)
    isnothing(labs) && isempty(kwargs) && return node
    for (key, value) in pairs(kwargs)
        skey = replace(string(key), "_" => " ")
        description = "$skey:"
        sjob = if !isnothing(labs)
            get(labs, key, nothing)
        else
            nothing
        end
        if isnothing(sjob)
            sjob = initialize_progress!(node; description, key, value=string(value), transient=false)
            !isnothing(labs) && (labs[key] = sjob)
        else
            update_progress!(sjob, string(value))
        end
    end
    node
end

function fail_progress!(node::ProgressNode, args...; kwargs...)
    fail_progress!(node.impl, args...; kwargs...)
    # collect() snapshot — a child failing may mutate node.children mid-walk
    for child in node.children
        isrunning(child) && fail_progress!(child, args...; kwargs...)
    end
    propagates_finalization(node) && !isnothing(node.parent) && isrunning(node.parent) && fail_progress!(node.parent, args...; kwargs...)
    # Intentional asymmetry with finalize_progress!: failed transient nodes stay
    # pinned to their parent so htmx_render_children's "N failed" pill can show
    # them until the user retries (which clears the DO cache entry).
end

function finalize_progress!(node::ProgressNode)
    finalize_progress!(node.impl)
    # collect() snapshot — a transient child detaches itself mid-walk
    for child in node.children
        isrunning(child) && finalize_progress!(child)
    end
    propagates_finalization(node) && !isnothing(node.parent) && isrunning(node.parent) && finalize_progress!(node.parent)
    if istransient(node) && !isnothing(node.parent)
        pop!(node.parent.children, node, nothing)
    end
end

# StateProgress: a thread-safe progress backend that stores state for inspection.
# Useful for remote/web progress (HTMXObjects, polling, etc.)
"""
    StateProgress

Thread-safe progress backend that stores all lifecycle state in mutable fields
guarded by a `ReentrantLock`. Used by the `:state` backend (selected via
`initialize_progress!(:state; …)`) and rendered by the HTMXObjects extension
(`htmx_render`) and the HTTP extension (`ws_progress`).

Lifecycle fields:

- `started_at` — `nothing` while the node is **pending** (created by
  [`prepare_progress!`](@ref)), set to `now()` by [`start_progress!`](@ref)
  or by the eager constructors.
- `finalized_at` — `nothing` while the node is running, set to `now()` by
  [`finalize_progress!`](@ref) or [`fail_progress!`](@ref).
- `failed` — `true` after [`fail_progress!`](@ref).

Query the lifecycle via [`is_pending`](@ref), [`is_running`](@ref),
[`is_finished`](@ref), [`is_failed`](@ref), [`duration`](@ref).
"""
mutable struct StateProgress
    lock::ReentrantLock
    description::String
    N::Union{Int,Nothing}
    i::Int
    message::String
    labels::Dict{Symbol,Any}
    running::Bool
    failed::Bool
    started_at::Union{DateTime,Nothing}  # nothing = pending (not yet started)
    finalized_at::Union{DateTime,Nothing}
    StateProgress(; description="Running...", N=nothing, pending=false) = new(
        ReentrantLock(), description, N, 0, "", Dict{Symbol,Any}(),
        !pending, false, pending ? nothing : now(), nothing
    )
end

# A node is a *bare wrapper* when it would render as a pure structural level —
# no description, no running message, no counter — i.e. its only content is its
# children. Such a node carries no information of its own, so with no explicit
# display preference the render side inlines it (hoisting its children).
# Non-`StateProgress` impls are never treated as bare. Defined here (after the
# StateProgress struct) so the type is in scope for the method signature.
_is_bare_wrapper(node::ProgressNode{<:StateProgress}) =
    isempty(node.impl.description) && isempty(node.impl.message) && isnothing(node.impl.N)
_is_bare_wrapper(::ProgressNode) = false

# Render-side display decision, sharper than `is_displayed`: an explicit
# `displayed=false` hides, an explicit `displayed=true` always shows, and with
# no preference set the node shows iff it is not a bare wrapper. When `false`
# the node emits nothing and its children hoist one level up.
function _renders_self(node::ProgressNode)
    pref = _display_pref(node)
    pref === false && return false
    pref === true && return true
    !_is_bare_wrapper(node)
end
_renders_self(::Nothing) = false

"""
    is_pending(s)

`true` when a progress node has been created (via [`prepare_progress!`](@ref))
but not yet started. Defined on `StateProgress` and on
`ProgressNode{<:StateProgress}`; `false` for backends without a pending concept
and for `nothing`.
"""
is_pending(s::StateProgress) = isnothing(s.started_at)

"""
    is_running(s)

`true` when a progress node has been started (via [`start_progress!`](@ref) or
an eager `initialize_progress!`) and not yet finalized or failed.
"""
is_running(s::StateProgress) = !isnothing(s.started_at) && isnothing(s.finalized_at)

"""
    is_finished(s)

`true` when a progress node has been finalized successfully (via
[`finalize_progress!`](@ref)).
"""
is_finished(s::StateProgress) = !isnothing(s.finalized_at) && !s.failed

"""
    is_failed(s)

`true` when a progress node has been finalized as a failure (via
[`fail_progress!`](@ref)).
"""
is_failed(s::StateProgress) = !isnothing(s.finalized_at) && s.failed

"""
    duration(s)

Elapsed wall-clock time for a progress node as a `Dates.Period`. Returns
`Millisecond(0)` for pending nodes; for running nodes counts up to `now()`;
for finalized/failed nodes returns the frozen `finalized_at - started_at`.
"""
function duration(s::StateProgress)
    isnothing(s.started_at) && return Millisecond(0)
    something(s.finalized_at, now()) - s.started_at
end

is_pending(node::ProgressNode{<:StateProgress}) = is_pending(node.impl)
is_running(node::ProgressNode{<:StateProgress}) = is_running(node.impl)
is_finished(node::ProgressNode{<:StateProgress}) = is_finished(node.impl)
is_failed(node::ProgressNode{<:StateProgress}) = is_failed(node.impl)
duration(node::ProgressNode{<:StateProgress}) = duration(node.impl)

# Defaults for non-StateProgress (no pending concept) and disabled backend.
# A `nothing` phase is a no-op target, so it's neither pending nor running —
# with_prepared_phases' cleanup handler skips it.
is_pending(::Any) = false
is_pending(::Nothing) = false
is_running(::Nothing) = false
is_finished(::Nothing) = false
is_failed(::Nothing) = false

isrunning(node::ProgressNode{<:StateProgress}) = is_running(node.impl)
isrunning(node::ProgressNode) = true

# Root initializer for the :state backend. Only `description`/`N`/`pending`
# reach `StateProgress`; node-meta kwargs a caller might pass (`transient`,
# `propagates`, `displayed`) are irrelevant to a parent-less root, so they are
# dropped rather than splatted into the constructor (which would error).
initialize_progress!(::Val{:state}; description="Running...", N=nothing, pending=false, kwargs...) = ProgressNode(
    StateProgress(; description, N, pending), (;propagates=false, labels=ThreadsafeDict{Symbol,Any}())
)
function initialize_progress!(sp::StateProgress, N::Integer; description="Running...", transient=false, propagates=false, key=nothing, value="", pending=false, kwargs...)
    child = StateProgress(; description, N, pending)
    child.message = value
    child
end
function initialize_progress!(sp::StateProgress; description="Running...", transient=false, propagates=false, key=nothing, value="", pending=false, kwargs...)
    child = StateProgress(; description, pending)
    child.message = value
    child
end

# Transition a pending node to running. Idempotent — no-op if already started.
function start_progress!(sp::StateProgress)
    lock(sp.lock) do
        if isnothing(sp.started_at)
            sp.started_at = now()
            sp.running = true
        end
    end
end

function update_progress!(sp::StateProgress, i::Integer)
    lock(sp.lock) do
        if isnothing(sp.N)
            sp.message = string(i)
        else
            sp.i = clamp(i, 0, sp.N)
        end
    end
end
function update_progress!(sp::StateProgress, ::IncrementBy{di}) where {di}
    lock(sp.lock) do
        sp.i = isnothing(sp.N) ? sp.i + di : clamp(sp.i + di, 0, sp.N)
    end
end
function update_progress!(sp::StateProgress, msg::AbstractString)
    lock(sp.lock) do
        sp.message = msg
    end
end
update_progress!(sp::StateProgress, ::Nothing) = nothing

function fail_progress!(sp::StateProgress, args...; kwargs...)
    lock(sp.lock) do
        sp.failed = true
        sp.running = false
        t = now()
        isnothing(sp.started_at) && (sp.started_at = t)
        sp.finalized_at = t
    end
end
function finalize_progress!(sp::StateProgress)
    lock(sp.lock) do
        sp.running = false
        t = now()
        isnothing(sp.started_at) && (sp.started_at = t)
        sp.finalized_at = t
    end
end

# JSON-serializable snapshot (non-exported — prefer working with ProgressNode directly)
function progress_state(sp::StateProgress)
    lock(sp.lock) do
        Dict{String,Any}(
            "description" => sp.description,
            "N" => sp.N,
            "i" => sp.i,
            "message" => sp.message,
            "running" => sp.running,
            "failed" => sp.failed,
            "started_at" => string(sp.started_at),
            "finalized_at" => isnothing(sp.finalized_at) ? nothing : string(sp.finalized_at),
        )
    end
end
function progress_state(node::ProgressNode{<:StateProgress})
    d = progress_state(node.impl)
    if !isempty(node.children)
        d["children"] = [progress_state(child) for child in node.children]
    end
    d
end
function progress_state(node::ProgressNode)
    d = Dict{String,Any}("type" => string(typeof(node.impl)))
    if !isempty(node.children)
        d["children"] = [progress_state(child) for child in node.children]
    end
    d
end
progress_state(::Nothing) = nothing
