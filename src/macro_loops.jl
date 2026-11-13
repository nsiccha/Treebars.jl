# Lowering for serial/threaded loops, comprehensions and map calls.
# These share the walker in macros.jl and phase-body lowering in macro_phases.jl.

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
    child_ctx = _ctx(sub, true)
    wrapped_body = _wrap_for_body(body, child_ctx)
    desc = description === nothing ? _auto_for_label(lhs, rhs) : _label_expr(description, ctx)
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
        local $itr = $(progress_expr(rhs, ctx))
        $(_iterprogress_sandwich(sub, init_expr, newcall))
    end
end

# init → run → fail/finalize sandwich shared by the iterable @progress forms.
# `subsym` is bound to `init_expr` (a counter ProgressNode), then
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
# recognises both). A bare string in TAIL position is the block's value, not
# a marker (`_tail_index`), so a body carrying only that stays a bare body
# with no per-iteration wrapper.
function _has_phase_marker(block::Expr)
    block.head === :block || return false
    tail = _tail_index(block)
    any(enumerate(block.args)) do (i, a)
        _phase_marker_label(a, i == tail) !== nothing
    end
end

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
    desc = description === nothing ? _auto_for_label(lhs, rhs) : description
    node = gensym(:iterprogress)
    itr = gensym(:itr)
    child_ctx = _ctx(node, true)
    wrapped_body = _wrap_for_body(body, child_ctx)
    run_expr = :(for $lhs in $IterableProgress($node, $itr); $wrapped_body; end)
    _iterable_progress_expr(node, itr, rhs, ctx, desc, run_expr)
end

# A bare `for` in a `@progress_scope` body stays plain Julia: no counter node,
# no `IterableProgress`. Otherwise it is lowered like a counted loop with the
# enclosing node in the counter's place: the iterator is walked against that
# node, and the body is transient (an explicit node made per iteration detaches
# when it finishes) with per-iteration phase markers (`_wrap_for_body`). A
# compact multi-generator header needs no desugaring, since nothing is counted.
_plain_for_expr(x::Expr, ctx) =
    Expr(:for, progress_expr(x.args[1], ctx), _wrap_for_body(x.args[2], merge(ctx, (transient=true,))))

# Shared init for the serial `for` and comprehension forms: evaluate the parent,
# then the iterable (once), then bind the counter NODE itself to `node` — not an
# `IterableProgress` wrapper — so `__progress__` in the body is a local whose
# type is inferred whenever the parent's is. `run_expr` iterates
# `IterableProgress(node, itr)`, which is type-stable either way. The iterable
# and the label are walked against the parent: both run before the loop's node
# exists, so a bare `__progress__` there names the enclosing node (todo
# `02kt4z4`, snag `progress-unbound-6f79e2f4`).
function _iterable_progress_expr(node, itr, rhs, ctx, desc, run_expr)
    par = gensym(:parent)
    par_ctx = _ctx(par, ctx.transient)
    init_expr = :($_iterable_node($par, $itr;
        description=$(_label_expr(desc, par_ctx)), transient=$(ctx.transient)))
    quote
        $par = $(ctx.progress)
        $itr = $(progress_expr(rhs, par_ctx))
        $(_iterprogress_sandwich(node, init_expr, run_expr))
    end
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
    node = gensym(:iterprogress)
    itr = gensym(:itr)
    child_ctx = _ctx(node, true)
    wrapped_elem = progress_expr(elem_body, child_ctx)
    new_comp = Expr(:comprehension, Expr(:generator, wrapped_elem,
        Expr(:(=), lhs, :($IterableProgress($node, $itr)))))
    _iterable_progress_expr(node, itr, rhs, ctx, desc, new_comp)
end

# @progress ["label"] map(itrs...) do args...; body; end   (opt-in magic sugar)
# Rewrites `map` → `progress_map` (its `_progress_map` core, which also takes
# the map call's keyword block), threading a fresh per-element child node as
# the FIRST argument and walking the do-body so `__progress__` (and any nested
# @progress) inside it bind to that child. The user-facing do-block stays
# "childless": it lists only the element vars and refers to the node as
# `__progress__`. `progress_map` owns the loop (bar) node; `label` (or an auto
# label) becomes its description, so a labeled map renders as a labeled bar.
function _map_progress_expr(x::Expr, label, ctx)
    child = gensym(:mapchild)
    if Meta.isexpr(x, :do)
        callexpr = x.args[1]                 # Expr(:call, :map, [kw,] itrs...)
        lambda = x.args[2]                   # Expr(:->, params, body)
        kw, itrs = _split_map_kwargs(callexpr.args[2:end])
        params = lambda.args[1]
        elem_params = Meta.isexpr(params, :tuple) ? params.args : Any[params]
        wrapped_body = progress_expr(lambda.args[2], _ctx(child, ctx.transient))
        g = Expr(:->, Expr(:tuple, child, elem_params...), wrapped_body)
    else                                     # Expr(:call, :map, [kw,] f, itrs...)
        kw, fitrs = _split_map_kwargs(x.args[2:end])
        f = fitrs[1]
        itrs = fitrs[2:end]
        a = gensym(:args)
        g = Expr(:->, Expr(:tuple, child, Expr(:..., a)), Expr(:call, f, Expr(:..., a)))
    end
    desc = label === nothing ? "map(...)" : _label_expr(label, ctx)
    # The collections and the keyword block are evaluated in the enclosing
    # scope: walk them there.
    itrs = Any[progress_expr(i, ctx) for i in itrs]
    map_kwargs = Expr(:tuple, progress_expr(kw, ctx))
    :($_progress_map($g, $(ctx.progress), ($(itrs...),), $map_kwargs;
        description=$desc, transient=$(ctx.transient)))
end

# A `map` call's own keyword block (`map(xs; kw...)`, the `:parameters` node the
# parser puts first) split off its positional arguments; an empty block when it
# has none. It becomes the NamedTuple `_progress_map` forwards to the inner
# `map` — spliced among the positionals it was a lowering error.
_split_map_kwargs(args) =
    !isempty(args) && Meta.isexpr(args[1], :parameters) ? (args[1], args[2:end]) :
                                                          (Expr(:parameters), args)
