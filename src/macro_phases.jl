# Phase lifecycle and lowering for blocks, single statements and @phases.

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

# Single-stmt wrap (indeterminate child, runs for the duration of `body`)
function _single_stmt_progress_expr(body, label, ctx)
    node = gensym(:progressnode)
    child_ctx = _ctx(node, ctx.transient)
    wrapped = progress_expr(body, child_ctx)
    quote
        $node = $initialize_progress!($(ctx.progress);
            description=$(_label_expr(label, ctx)), transient=$(ctx.transient))
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
    tail = _tail_index(block)
    for (i, a) in enumerate(block.args)
        cur_label, cur_stmts = _absorb_block_arg!(phases, cur_label, cur_stmts, a, _phase_marker_label(a, i == tail))
    end
    push!(phases, (cur_label, cur_stmts))

    # Wrap everything in a per-block node when an outer label was given, or when
    # `force_wrap` is set (the bare `@progress for`-body-with-phase-markers case,
    # which needs a per-iteration LABEL-LESS wrapper). A label-less wrapper uses
    # description="" so `_is_bare_wrapper`/`_renders_self` auto-inline it at render.
    if outer_label !== nothing || force_wrap
        wrapper_desc = outer_label === nothing ? "" : _label_expr(outer_label, ctx)
        outer = gensym(:progressouter)
        inner_ctx = merge(ctx, (progress=outer,))
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
# is finalized at the start of the next; the phase still running when
# the block exits is finalized by the block's own `finally`, so it ends
# with its statements even when the block runs on a node it did not
# create and does not finalize (`@progress node begin … end` on a
# caller's node; snag `last-phase-of-a-5a5f5db6`). A `try` evaluates to
# its body, so the user's last statement stays the block's value.
# Mirrors `_run_prepared_phases` for the dynamic form.
function _emit_phases(phases, ctx)
    labeled = [(lbl, stmts) for (lbl, stmts) in phases if lbl !== nothing]
    pending_syms = [gensym(:phase) for _ in labeled]
    group_sym = gensym(:phase_group)
    labels_sym = gensym(:phase_labels)
    plan_identity = QuoteNode((:macro, gensym(:phase_plan)))
    phase_keys = QuoteNode(Tuple(eachindex(labeled)))
    # Evaluated at enumeration, under `ctx.progress`: that is the node a label's
    # `__progress__` names.
    labels_expr = Expr(:tuple, (_label_expr(lbl, ctx) for (lbl, _) in labeled)...)

    prepare_stmts = Any[
        :( $labels_sym = $labels_expr ),
        :( $group_sym = $_prepare_phase_group($(ctx.progress), $plan_identity, $phase_keys, $labels_sym) ),
        (:( $sym = $_prepare_planned_phase(
            $(ctx.progress), $group_sym, $i; description=$labels_sym[$i], transient=$(ctx.transient),
        ) )
        for (i, sym) in enumerate(pending_syms))...,
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
        leading_ctx = merge(ctx, (progress=leading_sym,))
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
        phase_ctx = merge(ctx, (progress=sym,))
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
            # Only the RUNNING phase saw the exception. Phases after it were
            # never entered, so failing them would render a ✗ with a 0s
            # duration and an error they never met; the `finally` skips them.
            for _p in $phases_tuple
                $is_running(_p) && $fail_progress!(_p, _e)
            end
            rethrow()
        finally
            # Every exit ends every phase. The phase control was in (the last
            # one on a normal exit, the one a `return`/`break` left) finishes
            # here, not when some enclosing node does: a block on a caller's
            # node would otherwise leave it `▶` running while the caller works
            # on. Phases below the exit point were never entered and are
            # skipped — a `return`/`break` runs no `catch`, so before this they
            # stayed pending forever under a parent already marked ✓. On the
            # throw path the catch has already failed the running phase.
            for _p in $phases_tuple
                if $is_running(_p)
                    $finalize_progress!(_p)
                elseif $is_pending(_p)
                    $skip_progress!(_p)
                end
            end
        end
    end
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
    s = _flat_source(stmt)
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
    child_ctx = _ctx(node, ctx.transient)
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
