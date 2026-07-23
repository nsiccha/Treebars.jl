# Ambient (dynamically-scoped) current node.
#
# Every other nesting mechanism in Treebars is LEXICAL: the `@progress` walker
# rewrites a literal `__progress__` to the enclosing node at macro-expansion
# time (`convenience.jl`). That works only where a macro can see the body, so a
# plain method body — the shape DynamicObjects emits for
# `compute_property(o, ::Val{:x})` — has no variable to thread and nothing to
# attach under.
#
# The ambient node closes that gap: a dynamically-scoped "node currently being
# computed" that any frame can read, at any call depth, with no cooperation
# from the code in between. It is what lets a consumer get correct nesting
# without writing `@progress` / `@fetch!` at all.
#
# Mechanism is version-shimmed (decision `13jb58i`). `Base.ScopedValues` is
# Julia 1.11+; this package supports 1.10, so task-local storage backs it
# today. The two differ in ONE observable way — see `with_current_progress`.

@static if isdefined(Base, :ScopedValues)
    # Julia >= 1.11. Scopes are captured at task creation, so ambient nesting
    # propagates into `Threads.@spawn`ed children automatically.
    #
    # NB unexercised on this host (Julia 1.10.11) — `@static` makes it dead
    # code here. It is compiled only where `Base.ScopedValues` exists.
    _AMBIENT = Base.ScopedValues.ScopedValue{Any}(nothing)

    current_progress() = _AMBIENT[]
    with_current_progress(f, node) = Base.ScopedValues.with(f, _AMBIENT => node)
else
    # Julia 1.10. Task-local storage is NOT inherited by child tasks, so
    # ambient nesting stops at a task boundary this package did not create.
    _AMBIENT_KEY = :__treebars_current_progress__

    current_progress() = get(task_local_storage(), _AMBIENT_KEY, nothing)

    function with_current_progress(f, node)
        tls = task_local_storage()
        had = haskey(tls, _AMBIENT_KEY)
        old = had ? tls[_AMBIENT_KEY] : nothing
        tls[_AMBIENT_KEY] = node
        try
            f()
        finally
            # Restore rather than clear: nesting must survive unwinding, and a
            # bare `delete!` would drop an outer scope's node on the way out.
            had ? (tls[_AMBIENT_KEY] = old) : delete!(tls, _AMBIENT_KEY)
        end
    end
end

"""
    current_progress()

The progress node currently being computed in this dynamic scope, or `nothing`
when no tree is active.

This is the ambient counterpart to the lexical `__progress__` that
[`@progress`](@ref) binds. Unlike `__progress__` it needs no macro and no
threading through intermediate frames, so it is readable from an ordinary
method body at arbitrary call depth — which is what lets a caller nest
correctly without any Treebars syntax at the call site.

Returns `nothing` outside any progress tree, and every Treebars entry point
treats `nothing` as a no-op, so ambient-aware code is safe to run with progress
switched off entirely.

!!! note "Task boundaries on Julia 1.10"
    On Julia 1.10 the ambient node is backed by `task_local_storage()`, which
    child tasks do **not** inherit. A node opened inside a `Threads.@spawn` /
    `@async` that Treebars did not create sees `nothing` and attaches to the
    root instead of nesting. Treebars propagates explicitly across its own
    `@progress` / [`progress_map`](@ref) threaded paths, so this only bites
    consumer-spawned tasks. On Julia 1.11+ the `ScopedValue` backing captures
    the scope at task creation and the limitation disappears with no source
    change.

See [`with_current_progress`](@ref), [`with_ambient_progress`](@ref).
"""
current_progress

"""
    with_current_progress(f, node)

Run `f()` with `node` installed as the ambient [`current_progress`](@ref),
restoring the previous value afterwards (including on exception).

This binds the ambient node **without** creating or finalizing anything — use
it to make an already-created node (typically a tree root) ambient, or to
re-establish the ambient node inside a task that did not inherit it:

```julia
root = initialize_progress!(:state; description="my app")
with_current_progress(root) do
    # anything in here, at any call depth, nests under `root`
    compute_everything()
end
```

For the common case of "open a child, make it ambient, finalize it" use
[`with_ambient_progress`](@ref) instead — this function is the lower-level
half.

Restores rather than clears on exit, so nesting survives unwinding.
"""
with_current_progress

"""
    with_ambient_progress(f, description=""; transient=true, kwargs...)

Open a progress node as a child of the ambient [`current_progress`](@ref), make
it ambient for the dynamic extent of `f`, and finalize it — or fail it and
rethrow if `f` throws. Returns `f`'s value.

This is the single entry point a caller needs in order to become a node in
somebody else's progress tree without knowing that tree exists:

```julia
compute_property(o, ::Val{:x}) = with_ambient_progress("x") do
    o.y + o.z          # `y` and `z` nest under `x` automatically
end
```

**Zero-cost when no tree is active.** If there is no ambient node, `f()` is
called directly — no node is created and no lock is taken — so instrumenting a
function this way costs nothing when progress is switched off.

`description` follows the usual Treebars convention: the empty string marks a
*structural* node, which the renderer hoists rather than displaying. Remaining
keyword arguments are forwarded to [`initialize_progress!`](@ref).

`transient=true` (the default here, unlike `initialize_progress!`) suits
per-evaluation nodes: a tree that gains a node for every property evaluation
would otherwise accumulate finished entries without bound.

See [`current_progress`](@ref), [`with_current_progress`](@ref),
[`with_progress`](@ref).
"""
function with_ambient_progress(f, description=""; transient=true, kwargs...)
    parent = current_progress()
    # No active tree: run untouched. This is the hot path for every consumer
    # that never turns progress on, so it must not allocate a node or touch
    # the backend's lock.
    parent === nothing && return f()
    node = initialize_progress!(parent; description, transient, kwargs...)
    try
        rv = with_current_progress(f, node)
        finalize_progress!(node)
        rv
    catch e
        fail_progress!(node, e)
        rethrow()
    end
end
