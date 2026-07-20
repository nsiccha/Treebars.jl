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

# Per-phase description: use the NT value if it's a string, otherwise stringify the key.
_phase_desc(v::AbstractString, k) = v
_phase_desc(_, k) = string(k)

function with_prepared_phases(f, parent, labels::NamedTuple; kwargs...)
    phases = map(keys(labels)) do k
        prepare_progress!(parent; description=_phase_desc(labels[k], k), kwargs...)
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

"""
    progress_map(f, parent, itrs...; description="Running...", transient=false, kwargs...)

Like `map(f, itrs...)`, but renders a **determinate progress bar** under
`parent` for the whole map and gives each element its own child node beneath
that bar, passing it to `f` as the first argument: `f(child, xs...)`. Returns
the mapped collection. Multiple iterables zip like `map`.

The loop (bar) node counts `0 … length` and advances by one as each element
finishes; `description` is its label and `transient` its lifetime. When the
iterables have no length (e.g. a bare generator) the loop node is indeterminate
(no bar) but still brackets the per-element children.

Each per-element `child` is created **label-less** so it stays out of the way
until `f` gives it content (an empty child auto-inlines at render): report into
it with `update_progress!(child, "msg")`, a nested `@progress child …`, etc.
`kwargs` forward to each per-element [`initialize_progress!`](@ref).

`parent` is an explicit progress node. Inside a `@progress` block, pass
`__progress__` (the walker rewrites it to the enclosing node). Outside a
`@progress` block, pass any node, or `nothing` to disable progress (then both
the loop node and `child` are `nothing`, all lifecycle ops no-op).

Inside `f`, report sub-progress into the passed `child` — e.g.
`@progress child for … end`, `with_progress(child, …)`, or
`update_progress!(child, …)` — NOT `__progress__` (which refers to the outer
node, not the per-element child).

```julia
progress_map(__progress__, chains) do child, c
    @fetch!(child, c.df)
end
```

The `@progress [label] map(itrs...) do args… end` sugar lowers to this, threading
the per-element `child` as `__progress__` for the do-body (see [`@progress`](@ref)).
"""
function progress_map(f, parent, itrs...; description="Running...", transient=false, kwargs...)
    N = all(_has_length, itrs) ? minimum(length, itrs) : nothing
    loop = isnothing(N) ?
        initialize_progress!(parent; description, transient) :
        initialize_progress!(parent, N; description, transient)
    try
        map(itrs...) do xs...
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

struct IterableProgress{P,W}
    progress::P
    wrapped::W
end
_iter_has_length(::Union{Base.HasLength, Base.HasShape}) = true
_iter_has_length(_) = false
_has_length(it) = _iter_has_length(Base.IteratorSize(typeof(it)))
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
Base.size(p::IterableProgress) = size(p.wrapped)
Base.axes(p::IterableProgress) = axes(p.wrapped)
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

# @phases macrocall recognition (mirrors the @progress pair). The walker
# (`progress_expr`) detects these and eager-expands them in place via the shared
# `_phases_build`, so an `@phases` nested inside `@progress` binds the active node.
_is_phases_macrocall(x) =
    Meta.isexpr(x, :macrocall) && length(x.args) >= 2 && x.args[1] === Symbol("@phases")

# User-supplied args of an @phases macrocall (strip macro name + LineNumberNode)
_phases_user_args(x) = x.args[3:end]

# True for both plain string literals (`"step"`) and interpolated string
# literals (`"step $i"`, parsed as `Expr(:string, …)`). The downstream
# emitter handles `description=$label` as a generic Expr, so the parser-level
# dispatch arms only need to recognise that the label slot was a string at
# the source level.
_is_string_literal(x) = x isa AbstractString || Meta.isexpr(x, :string)

# Phase-marker recognition. The structural shape is a `:macrocall` to
# `@progress` with exactly one user argument; the *kind* of that argument
# (string literal — plain or interpolated — vs anything else) determines
# whether it acts as a marker. Returns either `nothing` or the raw label
# expression (which downstream code splices into `description=$label`).
function _phase_marker_label(x)
    _is_string_literal(x) && return x
    if x isa Expr && _is_progress_macrocall(x) && length(x.args) == 3
        return _phase_marker_label(x.args[3])
    end
    return nothing
end

# User-supplied args of a @progress macrocall (strip macro name + LineNumberNode)
_progress_user_args(x) = x.args[3:end]

progress_expr(x, ctx) = x
progress_expr(x::Symbol, ctx) =
    x === :__progress__ ? ctx.progress : x

# True iff `x` is a `Threads.@threads` (qualified or bare) applied to a for loop.
function _is_threads_for(x)
    Meta.isexpr(x, :macrocall) || return false
    name = x.args[1]
    is_threads = (
        (Meta.isexpr(name, :.) && name.args[1] === :Threads &&
            name.args[2] isa QuoteNode && name.args[2].value === Symbol("@threads")) ||
        name === Symbol("@threads")
    )
    is_threads && Meta.isexpr(x.args[end], :for)
end

# Threads.@threads for — determinate counter with a thread-safe per-iteration
# increment injected into the loop body (the StateProgress lock makes concurrent
# increments safe). The original macrocall is preserved (schedule arg and all);
# only its for-loop body is rewritten. The increment is in a `finally` so it
# still advances on `continue`.
#
# The body is routed through `_wrap_for_body` (the SAME helper the serial
# `_for_progress_expr` uses), so bare `@progress "label"` phase markers in a
# threaded body get a per-iteration, transient, label-less wrapper running the
# `_emit_phases` machinery — each concurrent iteration builds its own phase
# sub-tree, thread-safe by the StateProgress lock invariant. `transient=true`
# mirrors the serial child ctx (`_for_progress_expr`): every per-iteration node
# (phase wrapper or nested @progress) detaches on finalize, so nothing
# accumulates under concurrency. The lifecycle try/fail/finally is shared via
# `_iterprogress_sandwich` (same helper as the serial/comprehension forms);
# this fn differs only in the irreducible init (`length(itr)` counter) and loop
# emission (preserved macrocall + `finally` increment).
function _threads_for_progress_expr(x::Expr, ctx; description)
    forexpr = x.args[end]
    # Compact multi-generator header (`for a in X, b in Y`): `Threads.@threads`
    # itself rejects this ("nested outer loops are not currently supported by
    # @threads"). Per user decision `8fmgjl`, don't support under @threads what
    # @threads doesn't — emit the macrocall untouched so @threads surfaces its
    # own error (least surprising: identical to un-wrapped @threads).
    Meta.isexpr(forexpr.args[1], :block) && return x
    lhs, rhs = forexpr.args[1].args
    body = forexpr.args[2]
    sub = gensym(:threadsprogress)
    itr = gensym(:itr)
    child_ctx = (progress=sub, transient=true)
    wrapped_body = _wrap_for_body(body, child_ctx)
    desc = description === nothing ? "for $lhs in ..." : description
    newfor = Expr(:for, Expr(:(=), lhs, itr),
        quote
            try
                $wrapped_body
            finally
                $update_progress!($sub, $(IncrementBy)(1))
            end
        end)
    newcall = Expr(:macrocall, x.args[1:end-1]..., newfor)
    init_expr = :($initialize_progress!($(ctx.progress), length($itr);
        description=$desc, transient=$(ctx.transient)))
    quote
        local $itr = $rhs
        $(_iterprogress_sandwich(sub, init_expr, newcall))
    end
end

function progress_expr(x::Expr, ctx)
    # Nested @progress macrocall — rewrite in place using current context
    if _is_progress_macrocall(x)
        return _rewrite_nested_progress(x, ctx)
    end
    # Nested @phases macrocall — eager-expand in place against the active node
    # via the shared builder (Strategy E). This is the ergonomic `@phases body`
    # form: no literal `__progress__` survives; the active `ctx.progress` is
    # substituted directly. The explicit `@phases node body` form also routes
    # here when found during descent.
    if _is_phases_macrocall(x)
        return _phases_build(_phases_user_args(x), ctx)
    end
    # Threads.@threads for — determinate counter, thread-safe increment
    _is_threads_for(x) && return _threads_for_progress_expr(x, ctx; description=nothing)
    # Bare for loop — wrap as iterable child (existing behavior)
    if x.head === :for
        return _for_progress_expr(x, ctx; description=nothing)
    end
    # Anything else: recurse into children
    Expr(x.head, Any[progress_expr(a, ctx) for a in x.args]...)
end

# Parse top-level @progress args into (backend, label, body). Length-cased
# branches dispatch on the position-relevant arg's type instead of running
# `_is_string`-style guards inside the body.
function _parse_toplevel_args(args)
    length(args) == 1 && return _toplevel_one_arg(args[1])
    length(args) == 2 && return _split_two_args(args[1], args[2])
    length(args) == 3 && return _toplevel_three_args(args[1], args[2], args[3])
    error("@progress: too many arguments")
end

# Length-1 form: a body expression. A bare string literal (plain or
# interpolated) here is a user error.
_toplevel_one_arg(a) =
    _is_string_literal(a) ?
        error("@progress with a string label requires a body expression: @progress \"label\" body") :
        (nothing, nothing, a)

# Two-arg @progress form: a (plain or interpolated) string is the label;
# anything else is the backend.
_split_two_args(a, b) = _is_string_literal(a) ? (nothing, a, b) : (a, nothing, b)

# Length-3 form: backend, label, body — label must be a (plain or
# interpolated) string literal.
_toplevel_three_args(backend, label, body) =
    _is_string_literal(label) ? (backend, label, body) :
    error("@progress: three-arg form expects @progress backend \"label\" body")

# Rewrite a nested @progress macrocall (not top-level, so no backend allowed).
# Each length-cased branch dispatches the type test on its label-position arg.
function _rewrite_nested_progress(x::Expr, ctx)
    args = _progress_user_args(x)
    length(args) == 1 && return _nested_one_arg(args[1], ctx)
    length(args) == 2 && return _nested_two_args(args[1], args[2], ctx)
    error("@progress: too many arguments in nested position")
end

# Length-1 nested form: a body expression. A bare string here is a stray
# phase marker (markers are consumed by _block_progress_expr before reaching
# this walker).
_nested_one_arg(a, ctx) = _build_body(a, nothing, ctx)
_nested_one_arg(a::AbstractString, ctx) =
    error("@progress \"$(a)\" phase marker must be a direct statement of an enclosing @progress [begin … end] block")

# Length-2 nested form: label, body. Label must be a (plain or interpolated)
# string literal.
_nested_two_args(a, body, ctx) =
    _is_string_literal(a) ? _build_body(body, a, ctx) :
    error("@progress: nested form does not accept a backend argument; use @progress \"label\" body")

# Dispatch on body shape
function _build_body(body, label, ctx)
    if _is_threads_for(body)
        return _threads_for_progress_expr(body, ctx; description=label)
    elseif _is_map_call(body)
        return _map_progress_expr(body, label, ctx)
    elseif Meta.isexpr(body, :for)
        return _for_progress_expr(body, ctx; description=label)
    elseif Meta.isexpr(body, :comprehension)
        return _comprehension_progress_expr(body, ctx; description=label)
    elseif Meta.isexpr(body, :generator)
        error("@progress over a bare generator `(f(x) for x in itr)` isn't supported — " *
              "use a comprehension `[f(x) for x in itr]` for a counter, or " *
              "`progress_map` / `@progress map(...) do … end` for per-element children")
    elseif Meta.isexpr(body, :block)
        return _block_progress_expr(body, label, ctx)
    elseif label === nothing
        # Unlabeled non-for, non-block: recurse to find any inner for loops / @progress calls
        return progress_expr(body, ctx)
    else
        return _single_stmt_progress_expr(body, label, ctx)
    end
end

# init → run → fail/finalize sandwich shared by the iterable @progress forms.
# `subsym` is bound to `init_expr` (an IterableProgress or a ProgressNode), then
# `run_expr` runs inside the lifecycle try/catch; its value is the block's value.
function _iterprogress_sandwich(subsym, init_expr, run_expr)
    quote
        $subsym = $init_expr
        try
            $run_expr
        catch _e
            $fail_progress!($subsym, _e)
            rethrow()
        finally
            $finalize_progress!($subsym)
        end
    end
end

# True iff the block has any bare `@progress "label"` phase markers as direct
# statements (plain or interpolated string literals — `_phase_marker_label`
# recognises both).
_has_phase_marker(block::Expr) =
    block.head === :block && any(a -> _phase_marker_label(a) !== nothing, block.args)

# Route a for-loop body. A block carrying bare phase markers gets a per-iteration,
# transient, LABEL-LESS wrapper node running the existing `_emit_phases` phase
# machinery (auto-inlines at render, finalized + detached per iteration so phases
# don't accumulate). Anything else recurses generically — unchanged behavior.
_wrap_for_body(body, ctx) =
    _has_phase_marker(body) ?
        _block_progress_expr(body, nothing, ctx; force_wrap=true) :
        progress_expr(body, ctx)

# Desugar a compact multi-generator for-header (`for a in X, b in Y, …`, whose
# header Julia parses as `Expr(:block, =(a,X), =(b,Y), …)`) into nested
# single-variable for loops: `for a in X; for b in Y; …; body; end; end`. The
# existing walker then instruments every level (each nested `for` routes back
# through `_for_progress_expr` via `_wrap_for_body`), so each nesting level gets
# its own progress bar — the least-surprising behavior (user decision `8fmgjl`).
function _nest_multifor(head::Expr, body)
    gens = filter(a -> !(a isa LineNumberNode), head.args)
    expr = body
    for gen in reverse(gens)
        expr = Expr(:for, gen, expr)
    end
    expr
end

# for-loop wrap — description from label (or auto from iteration var)
function _for_progress_expr(x::Expr, ctx; description)
    @assert length(x.args) == 2
    head, body = x.args
    # Compact multi-generator header (`for a in X, b in Y`) → desugar to nested
    # single-var loops and recurse; each level then gets its own bar.
    Meta.isexpr(head, :block) &&
        return _for_progress_expr(_nest_multifor(head, body), ctx; description)
    @assert Meta.isexpr(head, :(=))
    lhs, rhs = head.args
    desc = description === nothing ? "for $lhs in ..." : description
    subprogress = gensym(:iterprogress)
    child_ctx = (progress=:($subprogress.progress), transient=true)
    wrapped_body = _wrap_for_body(body, child_ctx)
    init_expr = :($initialize_iterable_progress!(
        $(ctx.progress), $rhs; description=$desc, transient=$(ctx.transient),
    ))
    run_expr = :(for $lhs in $subprogress; $wrapped_body; end)
    _iterprogress_sandwich(subprogress, init_expr, run_expr)
end

# comprehension wrap — per-element counter (eager). Single, unfiltered iterable
# only; filtered / multi-dimensional comprehensions error rather than miscount.
# (Bare lazy generators are rejected in `_build_body` — a counter on a value
# consumed elsewhere would finalize before the work runs.)
function _comprehension_progress_expr(x::Expr, ctx; description)
    @assert x.head === :comprehension
    gen = x.args[1]
    if length(gen.args) != 2 || !Meta.isexpr(gen.args[2], :(=))
        error("@progress: only single-iterable, unfiltered comprehensions are supported")
    end
    elem_body = gen.args[1]
    lhs, rhs = gen.args[2].args
    desc = description === nothing ? "comprehension over $lhs" : description
    sub = gensym(:iterprogress)
    child_ctx = (progress=:($sub.progress), transient=true)
    wrapped_elem = progress_expr(elem_body, child_ctx)
    new_comp = Expr(:comprehension, Expr(:generator, wrapped_elem, Expr(:(=), lhs, sub)))
    init_expr = :($initialize_iterable_progress!(
        $(ctx.progress), $rhs; description=$desc, transient=$(ctx.transient),
    ))
    _iterprogress_sandwich(sub, init_expr, new_comp)
end

# Recognise a `map(...)` call — plain `map(f, itrs...)` or do-block form
# `map(itrs...) do args... end` — for the opt-in @progress map-sugar.
_is_map_name(n) = n === :map ||
    (Meta.isexpr(n, :.) && n.args[2] isa QuoteNode && n.args[2].value === :map)
function _is_map_call(x)
    Meta.isexpr(x, :do) && return Meta.isexpr(x.args[1], :call) && _is_map_name(x.args[1].args[1])
    Meta.isexpr(x, :call) && return _is_map_name(x.args[1])
    return false
end

# @progress ["label"] map(itrs...) do args...; body; end   (opt-in magic sugar)
# Rewrites `map` → `progress_map`, threading a fresh per-element child node as
# the FIRST argument and walking the do-body so `__progress__` (and any nested
# @progress) inside it bind to that child. The user-facing do-block stays
# "childless": it lists only the element vars and refers to the node as
# `__progress__`. `progress_map` owns the loop (bar) node; `label` (or an auto
# label) becomes its description, so a labeled map renders as a labeled bar.
function _map_progress_expr(x::Expr, label, ctx)
    child = gensym(:mapchild)
    if Meta.isexpr(x, :do)
        callexpr = x.args[1]                 # Expr(:call, :map, itrs...)
        lambda = x.args[2]                   # Expr(:->, params, body)
        itrs = callexpr.args[2:end]
        params = lambda.args[1]
        elem_params = Meta.isexpr(params, :tuple) ? params.args : Any[params]
        wrapped_body = progress_expr(lambda.args[2], (progress=child, transient=ctx.transient))
        g = Expr(:->, Expr(:tuple, child, elem_params...), wrapped_body)
    else                                     # Expr(:call, :map, f, itrs...)
        f = x.args[2]
        itrs = x.args[3:end]
        a = gensym(:args)
        g = Expr(:->, Expr(:tuple, child, Expr(:..., a)), Expr(:call, f, Expr(:..., a)))
    end
    desc = label === nothing ? "map(...)" : label
    :($progress_map($g, $(ctx.progress), $(itrs...); description=$desc, transient=$(ctx.transient)))
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

# Per-block-arg fold for the phase splitter. Dispatched on the precomputed
# `_phase_marker_label(a)` result: `nothing` ⇒ extend the current phase;
# anything else (a plain or interpolated string-literal expression) ⇒ open
# a new phase using that label.
_absorb_block_arg!(phases, cur_label, cur_stmts, a, ::Nothing) =
    (push!(cur_stmts, a); (cur_label, cur_stmts))
_absorb_block_arg!(phases, cur_label, cur_stmts, a, label) = begin
    push!(phases, (cur_label, cur_stmts))
    (label, Any[])
end

# The docstring trap. Inside a `begin … end` (also `quote` / module / file
# top-level), Julia's PARSER rewrites a string literal immediately followed by
# another statement into `Core.@doc "label" stmt`. So a bare `"label"` written
# as a phase marker is swallowed before `@progress` ever sees it: no node, no
# error, no warning. The code is parse-clean and precompile-clean, which makes
# this the one `@progress` failure mode no offline check can catch — it has
# already cost a real DO property four silently-missing phases.
#
# We do NOT recover the intent by treating it as a marker: a genuine docstring
# is legal here, and silently redefining what it means would trade a visible
# bug for an invisible one. Warning at macro-expansion is enough to kill the
# class — the author sees it the first time the block is compiled, with the
# exact replacement spelled out.
_is_doc_macrocall(x) =
    Meta.isexpr(x, :macrocall) && length(x.args) == 4 &&
    (x.args[1] === GlobalRef(Core, Symbol("@doc")) || x.args[1] === Symbol("@doc")) &&
    _is_string_literal(x.args[3])

function _warn_swallowed_markers(block::Expr)
    line = nothing
    for a in block.args
        a isa LineNumberNode && (line = a; continue)
        _is_doc_macrocall(a) || continue
        label = a.args[3]
        @warn """
            @progress: a bare string literal inside a `begin … end` block was parsed as a \
            DOCSTRING (`Core.@doc`), not a phase marker — it will create no node and render \
            nothing. Write the macro form instead:

                @progress $(label isa AbstractString ? repr(label) : string(label))

            (If you really meant a docstring, this warning is expected — move it out of the \
            `@progress` block to silence it.)
            """ location = line
    end
end

# Block wrap — split at phase markers, pre-enumerate labeled phases as pending
function _block_progress_expr(block::Expr, outer_label, ctx; force_wrap=false)
    _warn_swallowed_markers(block)
    # Split block.args into (label, [stmts]) phases at phase-marker statements.
    # The first chunk has label=nothing (pre-first-marker stmts). Labels are
    # the raw source-level expressions (plain string or `Expr(:string, …)`),
    # spliced into `description=$label` downstream.
    phases = Vector{Tuple{Any,Vector{Any}}}()
    cur_label = nothing
    cur_stmts = Any[]
    for a in block.args
        cur_label, cur_stmts = _absorb_block_arg!(phases, cur_label, cur_stmts, a, _phase_marker_label(a))
    end
    push!(phases, (cur_label, cur_stmts))

    # Wrap everything in a per-block node when an outer label was given, or when
    # `force_wrap` is set (the bare `@progress for`-body-with-phase-markers case,
    # which needs a per-iteration LABEL-LESS wrapper). A label-less wrapper uses
    # description="" so `_is_bare_wrapper`/`_renders_self` auto-inline it at render.
    if outer_label !== nothing || force_wrap
        wrapper_desc = outer_label === nothing ? "" : outer_label
        outer = gensym(:progressouter)
        inner_ctx = (progress=outer, transient=ctx.transient)
        inner = _emit_phases(phases, inner_ctx)
        return quote
            $outer = $initialize_progress!(
                $(ctx.progress); description=$wrapper_desc, transient=$(ctx.transient),
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

# Emit: prepare all pending phase nodes, then run phase bodies inside a
# single try/catch so assignments flow naturally across phase boundaries
# (no per-phase `try` scope means no surprise `UndefVarError` for
# variables set in one phase and used in the next). The previous phase
# is finalized at the start of the next; the last running phase is
# cleaned up by the caller's `finally` on the enclosing progress node
# (the labeled-block wrapper at L389-405, or the property-body lifecycle
# in callers like DynamicObjects). This keeps the user's last-stmt
# value as the block's tail. Mirrors `_run_prepared_phases` for the
# dynamic form.
function _emit_phases(phases, ctx)
    labeled = [(lbl, stmts) for (lbl, stmts) in phases if lbl !== nothing]
    pending_syms = [gensym(:phase) for _ in labeled]

    prepare_stmts = Any[
        :( $sym = $prepare_progress!(
            $(ctx.progress); description=$lbl, transient=$(ctx.transient),
        ) )
        for (sym, (lbl, _)) in zip(pending_syms, labeled)
    ]

    # Pre-first-marker (leading) statements run before any labeled phase is
    # started. Keep them outside the try so their assignments remain visible in
    # the enclosing scope (nothing to fail/clean up for them anyway). phases
    # always starts with the (nothing, pre-marker stmts) entry (possibly empty);
    # labeled phases follow.
    #
    # When there ARE labeled phases AND leading statements, wrap the leading
    # statements in an implicit LABEL-LESS node created FIRST — before the
    # labeled phases are prepared — so any progress child a leading statement
    # creates (via `__progress__`, e.g. a `@fetch!` disk-load substatus) sorts
    # ABOVE the labeled phases in `ctx.progress.children` (an OrderedSet). The
    # node is label-less (description="") so `_is_bare_wrapper`/`_renders_self`
    # auto-inline it: with children they hoist to `ctx.progress` ordered first;
    # with none it renders nothing. `transient=ctx.transient` mirrors the block,
    # so a per-iteration (transient) block detaches its leading node each
    # iteration (no accumulation) while a persistent block keeps a lingering
    # finished child visible. The leading statements stay OUTSIDE any new
    # try/let scope (we only rebind `__progress__`, not the variable scope), so
    # their assignments still leak into the enclosing scope as before.
    leading_stmts = first(phases)[2]
    if !isempty(pending_syms) && any(s -> !(s isa LineNumberNode), leading_stmts)
        leading_sym = gensym(:leading)
        leading_ctx = (progress=leading_sym, transient=ctx.transient)
        prepare_stmts = Any[
            :( $leading_sym = $prepare_progress!(
                $(ctx.progress); description="", transient=$(ctx.transient),
            ) ),
            prepare_stmts...,
        ]
        pre_stmts = Any[
            :( $start_progress!($leading_sym) ),
            (progress_expr(s, leading_ctx) for s in leading_stmts)...,
            :( $finalize_progress!($leading_sym) ),
        ]
    else
        pre_stmts = Any[progress_expr(s, ctx) for s in leading_stmts]
    end

    phase_stmts = Any[]
    for (idx, (lbl, stmts)) in enumerate(labeled)
        sym = pending_syms[idx]
        phase_ctx = (progress=sym, transient=ctx.transient)
        idx > 1 && push!(phase_stmts, :( $finalize_progress!($(pending_syms[idx-1])) ))
        push!(phase_stmts, :( $start_progress!($sym) ))
        for s in stmts
            push!(phase_stmts, progress_expr(s, phase_ctx))
        end
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

# ──────────────────────────────────────────────────────────────────────────────
# @phases macro
#
# Auto-instruments each top-level statement of a `begin … end` block (or a
# `for` / `Threads.@threads for` body) as its own pre-enumerated, timed phase —
# conceptually inserting `@progress "<shortened source of stmt>"` before each
# statement. Implemented by injecting bare-string phase markers and delegating to
# the existing `@progress` lowering (`_build_body` → `_block_progress_expr` /
# `_for_progress_expr` + `_wrap_for_body` + `_emit_phases`) — no forked walker.
#
# Surface:
#     @phases body          — drives the ACTIVE progress node (only meaningful
#                             inside @progress; standalone → BACKEND[] no-op)
#     @phases node body     — drives an explicit ProgressNode (self-contained)
#
# Both the standalone macro and the `@progress`-walker hook funnel through the
# single shared `_phases_build`, so the two surfaces lower identically.
# ──────────────────────────────────────────────────────────────────────────────

# Shorten a statement's source to a phase label: stringify (line-numbers
# stripped), collapse all whitespace/newlines to single spaces, truncate.
const _PHASE_LABEL_MAXLEN = 60
function _short_label(stmt)
    clean = stmt isa Expr ? Base.remove_linenums!(deepcopy(stmt)) : stmt
    s = strip(replace(string(clean), r"\s+" => " "))
    length(s) > _PHASE_LABEL_MAXLEN ? first(s, _PHASE_LABEL_MAXLEN - 1) * "…" : String(s)
end

_as_block(x) = Meta.isexpr(x, :block) ? x : Expr(:block, x)

# Interleave a bare-string phase marker (the shortened source) before each
# top-level, non-LineNumberNode statement of a block. `_block_progress_expr`
# splits these back out into one phase per statement.
function _inject_block_markers(block::Expr)
    @assert block.head === :block
    out = Any[]
    for a in block.args
        a isa LineNumberNode ? push!(out, a) : append!(out, (_short_label(a), a))
    end
    Expr(:block, out...)
end

# Insert per-statement markers into the @phases body, preserving its shape so the
# downstream `_build_body` dispatch picks the right lowering (block → split;
# for / @threads for → per-iteration phase sub-tree via `_wrap_for_body`).
function _inject_phase_markers(body)
    if Meta.isexpr(body, :block)
        return _inject_block_markers(body)
    elseif Meta.isexpr(body, :for)
        head, fbody = body.args
        return Expr(:for, head, _inject_block_markers(_as_block(fbody)))
    elseif _is_threads_for(body)
        forexpr = body.args[end]
        head, fbody = forexpr.args
        newfor = Expr(:for, head, _inject_block_markers(_as_block(fbody)))
        return Expr(:macrocall, body.args[1:end-1]..., newfor)
    else
        # A single non-block, non-for statement → one phase.
        return _inject_block_markers(Expr(:block, body))
    end
end

# Shared builder for both @phases surfaces. `args` are the user args (no macro
# name / LineNumberNode). One arg → drive `ctx.progress` (the active node);
# two args → drive the explicit node (run through `progress_expr` so an
# `__progress__` node argument resolves to the active node when expanded by the
# @progress walker). Markers are injected, then the existing @progress lowering
# does the phase split.
function _phases_build(args, ctx)
    if length(args) == 1
        node, body = ctx.progress, args[1]
    elseif length(args) == 2
        node, body = progress_expr(args[1], ctx), args[2]
    else
        error("@phases: expected `@phases body` or `@phases node body`")
    end
    child_ctx = (progress=node, transient=ctx.transient)
    marked = _inject_phase_markers(body)
    # Block / single-statement bodies go through `force_wrap=true` so they get a
    # label-less wrapper with its own try/finally: the LAST phase finalizes at
    # block exit (accurate per-statement timing, not deferred to a later parent
    # finalize), and when this expansion is a for-body the transient wrapper
    # finalizes + detaches its phases per iteration (no accumulation). For/
    # @threads-for bodies route through `_build_body` → `_for_progress_expr`,
    # which already applies the per-iteration `force_wrap` wrapper via
    # `_wrap_for_body`.
    if Meta.isexpr(marked, :block)
        return _block_progress_expr(marked, nothing, child_ctx; force_wrap=true)
    end
    _build_body(marked, nothing, child_ctx)
end

"""
    @phases body
    @phases node body

Auto-instrument **each top-level statement** of `body` as its own pre-enumerated,
timed progress phase — as if a `@progress "<shortened source>"` phase marker were
inserted before every statement. `body` is a `begin … end` block or a `for` /
`Threads.@threads for` loop; in the loop forms each statement becomes a
per-iteration phase under the iteration counter. Reach for it to profile a
sequence/loop body and see which statement dominates.

Two forms:

- `@phases body` — drives the **active** progress node. Only meaningful inside an
  enclosing `@progress` block (whose walker supplies the active node). Used
  standalone it drives `BACKEND[]`, so it is a graceful no-op when progress is
  disabled.
- `@phases node body` — drives an explicit `ProgressNode` expression (`p`,
  `__status__`, …). Self-contained; works anywhere. Mirrors the
  `@progress <node> body` node form.

```julia
@progress "fit" for subject in subjects
    @phases begin
        data  = load(subject)     # phase "data = load(subject)"
        model = build(data)       # phase "model = build(data)"   (data visible)
        fit!(model)               # phase "fit!(model)"
    end
end

# Explicit node, self-contained:
with_progress(:state; description="pipeline") do p
    @phases p begin
        step_a()
        step_b()
    end
end
```

Phase labels are the shortened statement source (whitespace collapsed, truncated).
Compound statements (`if` / nested `for` / blocks) stay **one** phase each — the
split is over top-level statements only, not recursive.

!!! note
    All statements run inside the phase machinery's single `try` scope, so
    assignments stay mutually visible **across** phases but do not leak **past**
    the `@phases` block. Fine for loop bodies (loop-scoped locals) and
    side-effecting sequences; if post-block code needs a binding, set it outside
    the `@phases` block (or use plain `@progress "label"` markers).
"""
macro phases(args...)
    ctx = (progress = :($(BACKEND)[]), transient = false)
    esc(_phases_build(args, ctx))
end
