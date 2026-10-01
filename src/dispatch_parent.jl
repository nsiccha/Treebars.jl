# Dispatch-parent ambient (the HTMXObjects `dispatch` parenting protocol).
#
# Narrowly scoped: this is ONLY the default for `polling_fetchindex`'s
# `parent` kwarg, set ONLY by HTMXObjects' `dispatch`, read ONLY when that
# kwarg is absent (`parent=:auto`). It is deliberately NOT the general
# ambient current-node Treebars shipped and reverted in July 2026
# (`d6881e5`/`1ab6df1`, "hidden ancestry"): no `@progress` lowering reads it,
# no HOF binds it, and an explicit `parent=` (including `parent=nothing` to
# force detached) always wins.
#
# Flow: `dispatch(...; parent=node)` binds `node` for the dynamic extent of
# the in-process request (same task, unconditional — a nested `dispatch`
# without `parent` binds `nothing`, shadowing an outer scope, so the inner
# route's execution and its nested pollers agree). A route body that runs
# nested compute through a hand-rolled `polling_fetchindex` without `parent=`
# then hangs that compute under the dispatch caller with zero per-site edits.
# Outside `dispatch` nothing is bound and the poller stays detached, exactly
# as before.
#
# Mechanism is version-shimmed (same shape as the reverted `ambient.jl`,
# decision `13jb58i`). `Base.ScopedValues` is Julia 1.11+; this package
# supports 1.10, so task-local storage backs it today. The two differ in ONE
# observable way: a `ScopedValue` scope is captured at task creation, so on
# 1.11+ the dispatch parent propagates into spawned tasks; on 1.10 a route
# body running in a spawned task (the `:polling`/spawned transport branch)
# sees `nothing`. `polling_fetchindex` covers that branch through its `req`
# leg instead (`HTMXObjects.dispatch_parent(req)`), which needs no task
# inheritance — so prefer passing `req`/`poll_context` where a spawned body
# nests polling.

@static if isdefined(Base, :ScopedValues)
    # Julia >= 1.11. Scopes are captured at task creation, so the dispatch
    # parent propagates into `Threads.@spawn`ed children automatically.
    #
    # NB unexercised on a 1.10 host — `@static` makes it dead code there. It
    # is compiled only where `Base.ScopedValues` exists.
    _DISPATCH_PARENT = Base.ScopedValues.ScopedValue{Any}(nothing)

    current_dispatch_parent() = _DISPATCH_PARENT[]
    with_dispatch_parent(f, node) = Base.ScopedValues.with(f, _DISPATCH_PARENT => node)
else
    # Julia 1.10. Task-local storage is NOT inherited by child tasks, so the
    # dispatch parent stops at a task boundary (see the header note).
    _DISPATCH_PARENT_KEY = :__treebars_dispatch_parent__

    current_dispatch_parent() = get(task_local_storage(), _DISPATCH_PARENT_KEY, nothing)

    function with_dispatch_parent(f, node)
        tls = task_local_storage()
        had = haskey(tls, _DISPATCH_PARENT_KEY)
        old = had ? tls[_DISPATCH_PARENT_KEY] : nothing
        tls[_DISPATCH_PARENT_KEY] = node
        try
            f()
        finally
            # Restore rather than clear: nesting must survive unwinding, and a
            # bare `delete!` would drop an outer scope's node on the way out.
            had ? (tls[_DISPATCH_PARENT_KEY] = old) : delete!(tls, _DISPATCH_PARENT_KEY)
        end
    end
end

"""
    current_dispatch_parent()

The caller progress node the in-flight `HTMXObjects.dispatch(...; parent=node)`
call bound for this dynamic scope, or `nothing` outside such a dispatch.

Framework seam, not consumer API: `polling_fetchindex` reads it ONLY as the
`parent=:auto` default. An explicit `parent=` always wins.
"""
current_dispatch_parent

"""
    with_dispatch_parent(f, node)

Run `f()` with `node` installed as the [`current_dispatch_parent`](@ref),
restoring the previous value afterwards (including on exception).

Called by `HTMXObjects.dispatch` (through its extension seam) around the
in-process request — never by route bodies directly. The bind is
UNCONDITIONAL: a nested `dispatch` without `parent` binds `nothing`,
shadowing an outer dispatch's node for its extent, so the inner route's own
execution (detached — its fresh request carries no key) and its nested
pollers agree.
"""
with_dispatch_parent
