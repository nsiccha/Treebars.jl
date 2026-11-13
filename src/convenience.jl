"""
    with_progress(f, kind::Symbol[, N]; description="Running...", kwargs...)
    with_progress(f, parent::ProgressNode[, N]; description="Running...", transient=false, kwargs...)

Initialize a node, call `f(node)`, and finalize it on completion or fail it on
error. Return the callback's value. Return the node explicitly if the caller
needs to inspect it afterwards.

Arguments follow [`initialize_progress!`](@ref). `N` is a counter total,
passed positionally or as a keyword, not both. `transient=true` detaches a
finished child; a failed child remains. With `parent=nothing`, the callback
receives `nothing` and still runs normally. Use [`update_progress!`](@ref)
inside the callback to report a counter position or message.
"""
function with_progress(f, args...; kwargs...)
    progress = initialize_progress!(args...; kwargs...)
    try
        return f(progress)
    catch e
        fail_progress!(progress, e)
        rethrow()
    finally
        finalize_progress!(progress)
    end
end

"""
    with_prepared_progress(f, phase)

Start a prepared phase, call `f(phase)`, and finalize on completion or fail
and rethrow on error. Return the callback's value. Pair with
[`with_prepared_phases`](@ref), which owns cleanup of unentered phases.
"""
function with_prepared_progress(f, phase)
    start_progress!(phase)
    try
        return f(phase)
    catch e
        fail_progress!(phase, e)
        rethrow()
    finally
        finalize_progress!(phase)
    end
end

"""
    with_prepared_phases(f, parent, descriptions; kwargs...)

Prepare pending children and call `f(phases)`. An iterable supplies labels;
a named tuple preserves its keys and uses string values as labels, otherwise
the key's string. Keywords, including `N` and `transient`, pass to each
[`prepare_progress!`](@ref) call. Return the callback's value.

Enter each reached phase through [`with_prepared_progress`](@ref) or
[`@with_progress`](@ref). On every exit, pending phases become skipped. On
error, running phases are failed before the exception is rethrown.
Repeated plans contribute counts to [`phase_overview`](@ref).
"""
function with_prepared_phases(f, parent, descriptions; kwargs...)
    labels = map(string, descriptions)
    keys = Tuple(1:length(labels))
    phases = _prepare_phase_nodes(parent, (:declared, Tuple(labels)), keys, labels; kwargs...)
    _run_prepared_phases(f, phases)
end

# Per-phase description: use the NT value if it's a string, otherwise stringify the key.
_phase_desc(v::AbstractString, k) = v
_phase_desc(_, k) = string(k)

function with_prepared_phases(f, parent, labels::NamedTuple; kwargs...)
    descriptions = Tuple(_phase_desc(labels[k], k) for k in keys(labels))
    phases = _prepare_phase_nodes(parent, (:named, keys(labels)), keys(labels), descriptions; kwargs...)
    _run_prepared_phases(f, NamedTuple{keys(labels)}(phases))
end

function _run_prepared_phases(f, phases)
    try
        return f(phases)
    catch e
        # Only the phase that was actually RUNNING saw the exception. Phases
        # still pending were never entered, so failing them would attach an
        # error they never met (and a backfilled 0s duration); the `finally`
        # below terminates those as skipped instead.
        for p in phases
            is_running(p) && fail_progress!(p, e)
        end
        rethrow()
    finally
        # Reached on EVERY exit — including a plain `return` out of `f` — so a
        # phase the caller never got to ends terminal-and-skipped rather than
        # dangling pending forever under a finished parent. Idempotent on the
        # throw path: the catch above has already moved the running one.
        for p in phases
            is_pending(p) && skip_progress!(p)
        end
    end
end

"""
    progress_map(f, parent, itrs...; description="Running...", transient=false, kwargs...)

Map the iterables, passing a progress child before each item's arguments:
`f(child, xs...)`. Return the mapped collection. The parent owns a map counter;
`description` labels that counter and `transient` controls its lifetime.
Iterables without a known length have an indeterminate counter.

Per-item children start without labels; give them a message or nested work.
Keywords pass to their [`initialize_progress!`](@ref) calls. Report into the
callback's `child`, not an enclosing macro's `__progress__`.
With `parent=nothing`, the map still runs and children are `nothing`.

The macro form `@progress [label] map(itrs...) do xs...` supplies the child
as its body's `__progress__`. Keywords on that `map` retain ordinary Julia
`map` semantics; use the function form for child keywords.
"""
progress_map(f, parent, itrs...; kwargs...) = _progress_map(f, parent, itrs, (;); kwargs...)

# `map_kwargs` is the keyword block of the `map` call the @progress map-sugar
# rewrote (`(;)` from the function form); it is forwarded to the inner `map`.
function _progress_map(f, parent, itrs::Tuple, map_kwargs::NamedTuple;
                       description="Running...", transient=false, kwargs...)
    N = all(_has_length, itrs) ? minimum(length, itrs) : nothing
    loop = initialize_progress!(parent, N; description, transient)
    try
        map(itrs...; map_kwargs...) do xs...
            child = initialize_progress!(loop; description="", kwargs...)
            try
                f(child, xs...)
            catch e
                fail_progress!(child, e)
                rethrow()
            finally
                finalize_progress!(child)
                update_progress!(loop, IncrementBy(1))
            end
        end
    catch e
        fail_progress!(loop, e)
        rethrow()
    finally
        finalize_progress!(loop)
    end
end

# The iterator a `@progress for` loop runs over. Its type depends ONLY on the
# wrapped iterable: the counter node sits in an untyped field, so the loop stays
# type-stable (inferred loop variable, no per-iteration boxing) even when the
# parent node's type is unknown at the call site — the `BACKEND[]` default, an
# untyped struct field, a `Ref{Any}`. With the node as a type parameter, every
# such loop dispatched `iterate` dynamically and allocated twice per iteration,
# even with progress disabled. The `:state` impl is additionally kept in a
# small-`Union` field so the per-iteration tick is a static call; other backends
# take one dynamic call per iteration. The `iterate` methods are `@inline`:
# without it the `:state` tick measured ~3 ns/iteration slower than the old
# node-typed iterator.
struct IterableProgress{W}
    progress::Any
    counter::Union{Nothing,StateProgress}
    wrapped::W
    IterableProgress(progress, wrapped::W) where {W} = new{W}(progress, _counter(progress), wrapped)
end
_counter(node::ProgressNode{<:StateProgress}) = node.impl
_counter(_) = nothing
@inline function _advance!(p::IterableProgress, i)
    c = p.counter
    if c !== nothing
        update_progress!(c, i)
    elseif p.progress !== nothing
        update_progress!(p.progress, i)
    end
    nothing
end
_iter_has_length(::Union{Base.HasLength, Base.HasShape}) = true
_iter_has_length(_) = false
_has_length(it) = _iter_has_length(Base.IteratorSize(typeof(it)))
# The counter node for iterating `it` under `progress`: determinate when `it`
# has a length. Kept separate from the iterator so the `@progress` lowering can
# bind the node to a local whose type is inferred whenever `progress`'s is
# (`__progress__` in the loop body), while the iterator itself is always stable.
_iterable_node(progress, it; kwargs...) =
    _has_length(it) ? initialize_progress!(progress, length(it); kwargs...) :
                      initialize_progress!(progress; kwargs...)
initialize_iterable_progress!(progress, it; kwargs...) =
    IterableProgress(_iterable_node(progress, it; kwargs...), it)
@inline function Base.iterate(p::IterableProgress)
    _advance!(p, 0)
    iterate(p.wrapped)
end
@inline function Base.iterate(p::IterableProgress, state)
    _advance!(p, IncrementBy(1))
    iterate(p.wrapped, state)
end
Base.length(p::IterableProgress) = length(p.wrapped)
Base.eltype(::Type{IterableProgress{W}}) where {W} = eltype(W)
Base.IteratorSize(::Type{IterableProgress{W}}) where {W} = Base.IteratorSize(W)
Base.size(p::IterableProgress) = size(p.wrapped)
Base.axes(p::IterableProgress) = axes(p.wrapped)
finalize_progress!(p::IterableProgress) = finalize_progress!(p.progress)
fail_progress!(p::IterableProgress, args...; kwargs...) = fail_progress!(p.progress, args...; kwargs...)
