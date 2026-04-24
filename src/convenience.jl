"""
    with_progress(f, kind, N; kwargs...)

Initialize progress, call `f(progress_node)`, finalize on completion or fail on error.
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

# Shared AST for the start-progress → body → fail-on-error / finalize sandwich.
# Used by both @with_progress and _emit_phases so there's a single source of
# truth for the per-phase lifecycle. Binds `phase_expr` to a local so it is
# evaluated exactly once.
function _phase_sandwich_ast(phase_expr, body_expr)
    quote
        local _phase = $phase_expr
        $start_progress!(_phase)
        try
            $body_expr
        catch _e
            $fail_progress!(_phase, _e)
            rethrow()
        finally
            $finalize_progress!(_phase)
        end
    end
end

"""
    @with_progress phase body

Per-phase sandwich: start the (prepared, pending) `phase` node, run `body`,
then finalize — calling `fail_progress!(phase, err)` and rethrowing on
exception. Inline expansion (no closure), so `return`, `break`, `continue`,
local-variable access, and early exits behave as in the surrounding scope.

Companion to [`prepare_progress!`](@ref). Use when the set of phases is
data-driven and the static `@progress "label" begin … end` form doesn't apply:

```julia
phases = [prepare_progress!(root; description=string(k)) for k in keys(chain)]
for (spec, phase) in zip(chain, phases)
    @with_progress phase compute(spec)
end
```

See also [`with_prepared_progress`](@ref) for the HOF form.
"""
macro with_progress(phase, body)
    _phase_sandwich_ast(esc(phase), esc(body))
end

"""
    with_prepared_progress(f, phase)

HOF form of [`@with_progress`](@ref). Starts the (prepared, pending) `phase`
node, calls `f(phase)`, and finalizes — with `fail_progress!(phase, err)` and
rethrow on exception. Returns `f`'s value.

Pairs with [`prepare_progress!`](@ref): prepare all phases up front so they
appear as pending siblings, then run each one inside `with_prepared_progress`:

```julia
phases = [prepare_progress!(root; description=string(k)) for k in keys(chain)]
vals = map(pairs(chain), phases) do ((_, spec), phase)
    with_prepared_progress(phase) do _
        compute(spec)
    end
end
```
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

Bulk-prepare a set of pending phase nodes under `parent`, pass them to `f`,
and clean up on exception.

`descriptions` may be:

- an iterable of description strings (e.g. `Vector{String}` or `Tuple`) —
  `phases` is a `Vector{ProgressNode}` of the same length, in iteration order.
- a `NamedTuple` — `phases` is a `NamedTuple` with the same keys and
  `ProgressNode` values. The per-phase description is the NT value if it is
  an `AbstractString`, otherwise `string(key)` — so `NamedTuple`s whose values
  carry non-string metadata (symbols, specs, etc.) still produce sensible
  labels.

If `f(phases)` throws, any phase still `is_pending` or `is_running` is failed
via `fail_progress!(p, err)` before the exception rethrows, so user code never
has to guard the prepare / consume gap manually.

Extra `kwargs...` are forwarded to each [`prepare_progress!`](@ref) call
(e.g. `transient=true`, `N=100`).

See also [`@with_progress`](@ref) and [`with_prepared_progress`](@ref) for
running individual prepared phases.

```julia
# Data-driven chain. Keys carry structure; values carry specs.
chain = (parse=:parse, transform=:transform, wrap=:wrap, brmi=:brmi)

vals = with_prepared_phases(__status__, chain) do phases
    # phases.parse, phases.transform, … are pending ProgressNodes.
    map(chain, phases) do spec, phase
        with_prepared_progress(phase) do _
            getproperty(r, spec)
        end
    end
end
```
"""
function with_prepared_phases(f, parent, descriptions; kwargs...)
    phases = map(d -> prepare_progress!(parent; description=string(d), kwargs...), descriptions)
    _run_prepared_phases(f, phases)
end

function with_prepared_phases(f, parent, labels::NamedTuple; kwargs...)
    phases = map(keys(labels)) do k
        v = labels[k]
        desc = v isa AbstractString ? v : string(k)
        prepare_progress!(parent; description=desc, kwargs...)
    end
    _run_prepared_phases(f, NamedTuple{keys(labels)}(phases))
end

function _run_prepared_phases(f, phases)
    try
        return f(phases)
    catch e
        for p in phases
            (is_pending(p) || is_running(p)) && fail_progress!(p, e)
        end
        rethrow()
    end
end

struct IterableProgress{P,W}
    progress::P
    wrapped::W
end
_has_length(it) = Base.IteratorSize(typeof(it)) isa Union{Base.HasLength, Base.HasShape}
function initialize_iterable_progress!(progress, it; kwargs...)
    IterableProgress(
        _has_length(it) ? initialize_progress!(progress, length(it); kwargs...) :
                          initialize_progress!(progress; kwargs...),
        it
    )
end
function Base.iterate(p::IterableProgress)
    update_progress!(p.progress, 0)
    iterate(p.wrapped)
end
function Base.iterate(p::IterableProgress, state)
    update_progress!(p.progress, IncrementBy(1))
    iterate(p.wrapped, state)
end
Base.length(p::IterableProgress) = length(p.wrapped)
Base.eltype(::Type{IterableProgress{P,W}}) where {P,W} = eltype(W)
Base.IteratorSize(::Type{IterableProgress{P,W}}) where {P,W} = Base.IteratorSize(W)
finalize_progress!(p::IterableProgress) = finalize_progress!(p.progress)
fail_progress!(p::IterableProgress, args...; kwargs...) = fail_progress!(p.progress, args...; kwargs...)

# ──────────────────────────────────────────────────────────────────────────────
# @progress macro
#
# Top-level forms:
#     @progress body
#     @progress "label" body
#     @progress backend body
#     @progress backend "label" body
#
# Nested forms (found during AST descent; backend not allowed here):
#     @progress "label"               — phase marker (must be direct stmt of enclosing begin block)
#     @progress "label" for … end     — labeled child for-loop
#     @progress for … end             — bare for-loop, auto-labeled (as before)
#     @progress "label" begin … end   — labeled sub-block with its own phases
#     @progress begin … end           — transparent sub-block with its own phases
#     @progress "label" expr          — single-stmt wrap (sugar)
#
# Body forms:
#     for loop      → iterable progress (counter)
#     begin block   → phases split by `@progress "label"` markers; labeled phases
#                     pre-enumerated as pending children
#     other expr    → indeterminate (spinner) child; only created if labeled
# ──────────────────────────────────────────────────────────────────────────────

_is_progress_macrocall(x) =
    Meta.isexpr(x, :macrocall) && length(x.args) >= 2 && x.args[1] === Symbol("@progress")

# Phase marker = @progress "label" with exactly one user arg that's a String
function _is_phase_marker(x)
    _is_progress_macrocall(x) || return false
    # args = [Symbol("@progress"), LineNumberNode, user_args...]
    length(x.args) == 3 && x.args[3] isa AbstractString
end
_phase_marker_label(x) = x.args[3]

# User-supplied args of a @progress macrocall (strip macro name + LineNumberNode)
_progress_user_args(x) = x.args[3:end]

progress_expr(x, ctx) = x
progress_expr(x::Symbol, ctx) =
    x === :__progress__ ? ctx.progress : x

function progress_expr(x::Expr, ctx)
    # Nested @progress macrocall — rewrite in place using current context
    if _is_progress_macrocall(x)
        return _rewrite_nested_progress(x, ctx)
    end
    # Bare for loop — wrap as iterable child (existing behavior)
    if x.head === :for
        return _for_progress_expr(x, ctx; description=nothing)
    end
    # Anything else: recurse into children
    Expr(x.head, Any[progress_expr(a, ctx) for a in x.args]...)
end

# Parse top-level @progress args into (backend, label, body)
function _parse_toplevel_args(args)
    if length(args) == 1
        a = args[1]
        a isa AbstractString && error("@progress \"$(a)\": top-level @progress requires a body expression")
        return (nothing, nothing, a)
    elseif length(args) == 2
        a, b = args
        return a isa AbstractString ? (nothing, a, b) : (a, nothing, b)
    elseif length(args) == 3
        backend, label, body = args
        label isa AbstractString || error("@progress: three-arg form expects @progress backend \"label\" body")
        return (backend, label, body)
    else
        error("@progress: too many arguments")
    end
end

# Rewrite a nested @progress macrocall (not top-level, so no backend allowed)
function _rewrite_nested_progress(x::Expr, ctx)
    args = _progress_user_args(x)
    if length(args) == 1
        a = args[1]
        if a isa AbstractString
            # Phase marker in an invalid position (direct-in-block markers are
            # consumed by _block_progress_expr before this walker sees them)
            error("@progress \"$(a)\" phase marker must be a direct statement of an enclosing @progress [begin … end] block")
        end
        return _build_body(a, nothing, ctx)
    elseif length(args) == 2
        a, body = args
        a isa AbstractString || error("@progress: nested form does not accept a backend argument; use @progress \"label\" body")
        return _build_body(body, a, ctx)
    else
        error("@progress: too many arguments in nested position")
    end
end

# Dispatch on body shape
function _build_body(body, label, ctx)
    if Meta.isexpr(body, :for)
        return _for_progress_expr(body, ctx; description=label)
    elseif Meta.isexpr(body, :block)
        return _block_progress_expr(body, label, ctx)
    elseif label === nothing
        # Unlabeled non-for, non-block: recurse to find any inner for loops / @progress calls
        return progress_expr(body, ctx)
    else
        return _single_stmt_progress_expr(body, label, ctx)
    end
end

# for-loop wrap — description from label (or auto from iteration var)
function _for_progress_expr(x::Expr, ctx; description)
    @assert length(x.args) == 2
    head, body = x.args
    @assert Meta.isexpr(head, :(=))
    lhs, rhs = head.args
    desc = description === nothing ? "for $lhs in ..." : description
    subprogress = gensym(:iterprogress)
    child_ctx = (progress=:($subprogress.progress), transient=true)
    wrapped_body = progress_expr(body, child_ctx)
    quote
        $subprogress = $initialize_iterable_progress!(
            $(ctx.progress), $rhs;
            description=$desc, transient=$(ctx.transient),
        )
        try
            for $lhs in $subprogress
                $wrapped_body
            end
        catch _e
            $fail_progress!($subprogress, _e)
            rethrow()
        finally
            $finalize_progress!($subprogress)
        end
    end
end

# Single-stmt wrap (indeterminate child, runs for the duration of `body`)
function _single_stmt_progress_expr(body, label, ctx)
    node = gensym(:progressnode)
    child_ctx = (progress=node, transient=ctx.transient)
    wrapped = progress_expr(body, child_ctx)
    quote
        $node = $initialize_progress!($(ctx.progress); description=$label, transient=$(ctx.transient))
        try
            $wrapped
        catch _e
            $fail_progress!($node, _e)
            rethrow()
        finally
            $finalize_progress!($node)
        end
    end
end

# Block wrap — split at phase markers, pre-enumerate labeled phases as pending
function _block_progress_expr(block::Expr, outer_label, ctx)
    # Split block.args into (label, [stmts]) phases at phase-marker statements.
    # The first chunk has label=nothing (pre-first-marker stmts).
    phases = Vector{Tuple{Union{Nothing,String},Vector{Any}}}()
    cur_label::Union{Nothing,String} = nothing
    cur_stmts = Any[]
    for a in block.args
        if _is_phase_marker(a)
            push!(phases, (cur_label, cur_stmts))
            cur_label = String(_phase_marker_label(a))
            cur_stmts = Any[]
        else
            push!(cur_stmts, a)
        end
    end
    push!(phases, (cur_label, cur_stmts))

    # If an outer label was given, wrap everything in a running labeled node
    if outer_label !== nothing
        outer = gensym(:progressouter)
        inner_ctx = (progress=outer, transient=ctx.transient)
        inner = _emit_phases(phases, inner_ctx)
        return quote
            $outer = $initialize_progress!(
                $(ctx.progress); description=$outer_label, transient=$(ctx.transient),
            )
            try
                $inner
            catch _e
                $fail_progress!($outer, _e)
                rethrow()
            finally
                $finalize_progress!($outer)
            end
        end
    else
        # Transparent block — phases attach directly to the current progress
        return _emit_phases(phases, ctx)
    end
end

# Emit: prepare all pending phase nodes, then run phase bodies inside a single
# try/catch so assignments flow naturally across phase boundaries (no per-phase
# `try` scope means no surprise `UndefVarError` for variables set in one phase
# and used in the next). Mirrors `_run_prepared_phases` for the dynamic form.
function _emit_phases(phases, ctx)
    labeled = [(lbl, stmts) for (lbl, stmts) in phases if lbl !== nothing]
    pending_syms = [gensym(:phase) for _ in labeled]

    prepare_stmts = Any[
        :( $sym = $prepare_progress!(
            $(ctx.progress); description=$lbl, transient=$(ctx.transient),
        ) )
        for (sym, (lbl, _)) in zip(pending_syms, labeled)
    ]

    # Pre-first-marker statements run in the outer ctx, before any phase is
    # started. Keep them outside the try so their assignments remain visible
    # in the enclosing scope (nothing to fail/clean up for them anyway).
    # phases always starts with the (nothing, pre-marker stmts) entry (possibly
    # empty); labeled phases follow. Pre-stmts stay outside the try so their
    # assignments leak into the enclosing scope as before.
    pre_stmts = Any[progress_expr(s, ctx) for s in first(phases)[2]]
    phase_stmts = Any[]
    for (idx, (lbl, stmts)) in enumerate(labeled)
        sym = pending_syms[idx]
        phase_ctx = (progress=sym, transient=ctx.transient)
        push!(phase_stmts, :( $start_progress!($sym) ))
        for s in stmts
            push!(phase_stmts, progress_expr(s, phase_ctx))
        end
        push!(phase_stmts, :( $finalize_progress!($sym) ))
    end

    if isempty(pending_syms)
        return Expr(:block, prepare_stmts..., pre_stmts..., phase_stmts...)
    end

    phases_tuple = Expr(:tuple, pending_syms...)
    quote
        $(prepare_stmts...)
        $(pre_stmts...)
        try
            $(phase_stmts...)
        catch _e
            for _p in $phases_tuple
                ($is_pending(_p) || $is_running(_p)) && $fail_progress!(_p, _e)
            end
            rethrow()
        end
    end
end

"""
    @progress body
    @progress "label" body
    @progress backend body
    @progress backend "label" body

Wrap `body` with automatic progress tracking. Supports:

- **for loops** — iterable progress with a counter:
  `@progress for i in 1:N … end` or `@progress "Sampling" for i in 1:N … end`

- **begin blocks with phase markers** — `@progress "label"` as a direct statement
  of a `begin` block acts as a phase marker. Statements following a marker run
  under that phase. All labeled phases are pre-enumerated as pending children
  so the whole pipeline is visible from the outset:

  ```julia
  @progress "Pipeline" begin
      @progress "Load"      # marker — "Load" starts here
      x = load()
      @progress "Train"     # "Load" finishes, "Train" starts
      for i in 1:N; train(i); end
      @progress "Eval"
      evaluate(x)
  end
  ```

- **any other labeled expression** — wrapped as an indeterminate spinner child.

The `backend` argument is only accepted at the outermost call (defaults to
`Treebars.BACKEND[]`). Nested `@progress` calls use the enclosing progress node.
"""
macro progress(args...)
    backend, label, body = _parse_toplevel_args(args)
    ctx = (
        progress = backend === nothing ? :($(BACKEND)[]) : backend,
        transient = false,
    )
    esc(_build_body(body, label, ctx))
end
