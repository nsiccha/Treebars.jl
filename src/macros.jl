# Macro entry points and context-aware AST walking. Runtime helpers live in
# convenience.jl; syntax recognition and the two lowering families are below.
include("macro_syntax.jl")
include("macro_loops.jl")
include("macro_phases.jl")

"""
    @with_progress phase body

Start a prepared `phase`, run `body`, and finalize it on completion. On an
exception, fail the phase and rethrow. Inline expansion preserves `return`,
`break`, `continue` and local-variable access in the surrounding scope.
Use within [`with_prepared_phases`](@ref) so unentered phases are closed too.
See [`with_prepared_progress`](@ref) for the function form.
"""
macro with_progress(phase, body)
    _phase_sandwich_ast(esc(phase), esc(body))
end

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
#     @progress c ? "a" : "b"         — phase marker with a conditional label (same rule)
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

# Walker context: the node `__progress__` names, whether nodes created under it
# are transient, and whether a bare `for` / `Threads.@threads for` becomes a
# counter (`@progress`, `loops=true`) or stays plain Julia (`@progress_scope`,
# `loops=false`). Every explicit `@progress` / `@phases` form starts a fresh
# `loops=true` context, so explicit loop counting works inside a scope body.
_ctx(progress, transient; loops=true) = (; progress, transient, loops)

progress_expr(x, ctx) = x
progress_expr(x::Symbol, ctx) =
    x === :__progress__ ? ctx.progress : x

# A label — a phase marker's, a labelled wrapper's, a loop's or a map's — is
# evaluated once in the enclosing scope, before the node it describes exists,
# exactly like a loop iterator (todo `02kt4z4`). Walk it against that enclosing
# context, so a bare `__progress__` there names the node the labelled node is
# created under: for phase markers, the node their phases are prepared under
# (snag `progress-unbound-6f79e2f4`; spliced unwalked before, it escaped as an
# undefined global).
_label_expr(label, ctx) = progress_expr(label, ctx)

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
    # Nested @progress_scope — lowered in place, so the enclosing walker neither
    # counts its loops nor rebinds its `__progress__` before it expands.
    if _is_scope_macrocall(x)
        node, body = _scope_args(_progress_user_args(x))
        return _scope_body(body, _ctx(progress_expr(node, ctx), ctx.transient; loops=false))
    end
    # Threads.@threads for — determinate counter, thread-safe increment. In a
    # `@progress_scope` body it falls through to the generic recursion below,
    # which reaches its `for` and leaves that plain.
    _is_threads_for(x) && ctx.loops && return _threads_for_progress_expr(x, ctx; description=nothing)
    # Bare for loop — wrap as iterable child, or keep plain in a scope body
    if x.head === :for
        return ctx.loops ? _for_progress_expr(x, ctx; description=nothing) : _plain_for_expr(x, ctx)
    end
    # Anything else: recurse into children
    Expr(x.head, Any[progress_expr(a, ctx) for a in x.args]...)
end

# Rewrite a nested @progress macrocall (not top-level, so no backend allowed).
# Each length-cased branch dispatches the type test on its label-position arg.
# An explicit `@progress` counts the loops in its body even inside a
# `@progress_scope` body, so it lowers in a fresh `loops=true` context.
function _rewrite_nested_progress(x::Expr, ctx)
    ctx = _ctx(ctx.progress, ctx.transient)
    args = _progress_user_args(x)
    length(args) == 1 && return _nested_one_arg(args[1], ctx)
    length(args) == 2 && return _nested_two_args(args[1], args[2], ctx)
    error("@progress: too many arguments in nested position")
end

# Length-1 nested form: a body expression. A bare string here is a stray
# phase marker (markers are consumed by _block_progress_expr before reaching
# this walker), and so is a conditional between strings. An argument the
# wrapper would do nothing with is refused rather than dropped: written as a
# marker with a computed label (`@progress lbl`, `@progress string("Fit ", k)`)
# it used to vanish, its time going to the previous phase (snag
# `phase-marker-wit-1fcdd284`).
_nested_one_arg(a, ctx) =
    _is_string_conditional(a) ? _stray_marker_error(_source(a)) :
    _wraps_nothing(a) ? _wraps_nothing_error(a) :
    _build_body(a, nothing, ctx)
_nested_one_arg(a::AbstractString, ctx) = _stray_marker_error("\"$(a)\"")

_stray_marker_error(src) =
    error("@progress $(src) phase marker must be a direct statement of an enclosing @progress [begin … end] block")

# Length-2 nested form: `"label" body`, or `node body` for an explicit target.
# The node arm mirrors `@phases node body` (`_phases_build`) exactly, including
# the `progress_expr` pass so an `__progress__` node argument still resolves to
# the enclosing node. It is not new surface: `Treebars.@progress q body` nested
# in a block already behaved this way, because the walker could not see the
# qualified head and left it to expand standalone against `q`. Now that the head
# IS seen, the arm has to exist or that working spelling would start erroring —
# and having the bare form agree is the point of the fix.
#
# A backend LITERAL (`:state`, `:term` — a QuoteNode in the AST) is the one thing
# still rejected: nested, it would silently root a SECOND, detached tree.
_nested_two_args(a, body, ctx) =
    _is_string_literal(a) ? _build_body(body, a, ctx) :
    _build_body(body, nothing, _ctx(progress_expr(a, ctx), ctx.transient))
_nested_two_args(a::QuoteNode, body, ctx) =
    error("@progress: nested form does not accept a backend argument (`:$(a.value)`) — it would " *
          "start a second, detached tree; use `@progress \"label\" body`, or pass a ProgressNode " *
          "to attach the body elsewhere")

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

"""
    @progress [backend_or_node] [label] body

Instrument a loop, comprehension, map, block or expression while preserving
its result. With no explicit backend or node, use `Treebars.BACKEND[]`, whose
default `nothing` disables progress.

A standalone `@progress "label"` inside a block marks a phase. All markers
are prepared up front; a phase finishes at the next marker or block exit.
Unentered phases become skipped. A phase that throws becomes failed and the
exception is rethrown. Labels may be literal or interpolated strings, or
conditionals choosing strings, evaluated before the plan begins.

Within the macro body, `__progress__` denotes the active node. Plain `for`
and `Threads.@threads for` loops inside it become counters too; nested loop
counters are transient. Comprehensions and maps require explicit wrapping.
The map form gives each item its own child. Lazy generators and filtered or
multidimensional comprehensions are not supported as wrapped counters.

Nested `@progress`, `Treebars.@progress` and longer paths ending in Treebars
are recognized; arbitrary aliases are not. Bare strings are not phase
markers. Use [`with_progress`](@ref) to pass a node to an ordinary function.
"""
macro progress(args...)
    backend, label, body = _parse_toplevel_args(args)
    ctx = _ctx(backend === nothing ? :($(BACKEND)[]) : backend, false)
    esc(_build_body(body, label, ctx))
end

# A block body splits at its phase markers like a transparent
# `@progress node begin … end`; any other body is only walked. Either way
# nothing unmarked is counted: `ctx.loops` is false, and a top-level
# comprehension, generator or `map` is never instrumented by the walker.
_scope_body(body, ctx) =
    Meta.isexpr(body, :block) ? _block_progress_expr(body, nothing, ctx) : progress_expr(body, ctx)

"""
    @progress_scope node body

Run `body` with `node` as its progress node, instrumenting only what is marked.
It lowers `body` like `@progress node begin … end`, but a bare `for` /
`Threads.@threads for` loop is not turned into a counter:

- `__progress__` in `body` names `node`, and inside a phase or nested block the
  node of that phase or block; in a label or a loop's iterator, which run before
  their node exists, it names the node that one is created under;
- `@progress "label"` statements split the body into pre-enumerated phases, and
  phase markers in a loop body give each iteration its own phases;
- explicit nested forms (`@progress "label" for …`, `@progress "label" begin …
  end`, `@progress node body`, [`@phases`](@ref)) lower exactly as under
  [`@progress`](@ref), including counting the loops in their own bodies;
- bare loops, comprehensions, generators and `map` calls stay plain Julia: no
  counter node, no per-iteration cost;
- `node === nothing` makes every progress call a no-op.

Meant for code that wraps bodies it did not write, where counting every loop
would cost time on each iteration and add a node per loop run (DynamicObjects
wraps every unmarked property body in it). Not exported: write
`Treebars.@progress_scope`. Nested in a `@progress` block it is recognised in
any of `@progress`'s spellings, and its loops stay plain there too.

```julia
Treebars.@progress_scope node begin
    @progress "Load"
    x = load()
    for i in eachindex(x)        # plain loop: no counter
        x[i] = clean(x[i])
    end
    @progress "Fit"
    @progress "chains" for c in 1:4   # explicitly marked: counted
        fit!(x, c)
    end
end
```
"""
macro progress_scope(args...)
    node, body = _scope_args(args)
    esc(_scope_body(body, _ctx(node, false; loops=false)))
end

"""
    @phases body
    @phases node body

Instrument each top-level statement of a block or loop body as a prepared
phase, labeled with shortened statement source. Compound statements remain
one phase. The node form is self-contained; the body-only form uses the active
node inside [`@progress`](@ref), or `Treebars.BACKEND[]` when standalone.

Statements share a scope across phases, but assignments do not escape the
macro's `try` scope. Define a binding outside the block if it is needed later.
Use explicit phase markers when labels should describe tasks rather than code.
"""
macro phases(args...)
    ctx = _ctx(:($(BACKEND)[]), false)
    esc(_phases_build(args, ctx))
end
