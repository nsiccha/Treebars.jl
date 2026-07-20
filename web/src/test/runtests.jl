using TestModules
using Treebars
using Dates

# Defined at module scope (required for @dynamicstruct type definitions)
@dynamicstruct struct _InlineSubTest
    __status__ = initialize_progress!(:state; description="InlineParent")
    struct InlineSub
        computed = 42
    end
end

@dynamicstruct struct _AutoCleanupTest
    __status__ = initialize_progress!(:state; description="AutoCleanup")
    "Computing $key"
    results(key) = begin
        sleep(0.01)
        key * 2
    end
end

@dynamicstruct struct _FailedSubstatusTest
    __status__ = initialize_progress!(:state; description="FailedRoot")
    "Computing $key"
    results(key) = begin
        key == :boom && error("boom")
        key
    end
end

@testset "nothing backend (no-ops)" begin
    @test initialize_progress!(nothing) === nothing
    @test update_progress!(nothing, 1) === nothing
    @test update_progress!(nothing, "msg") === nothing
    @test fail_progress!(nothing) === nothing
    @test finalize_progress!(nothing) === nothing
    @test update_progress!(Returns((;a=1)), nothing) === nothing
end

@testset "init root" begin
    root = initialize_progress!(:state; description="Root")
    @test root isa ProgressNode
    @test root.impl isa StateProgress
    @test root.impl.description == "Root"
    @test root.impl.running == true
    @test isnothing(root.parent)
    finalize_progress!(root)
    @test root.impl.running == false
end

@testset "init child with N" begin
    root = initialize_progress!(:state; description="Root")
    child = initialize_progress!(root, 10; description="Step")
    @test child isa ProgressNode
    @test child.impl.N == 10
    @test child.impl.description == "Step"
    @test child.parent === root
    @test child in root.children
    finalize_progress!(root)
end

@testset "update counter" begin
    root = initialize_progress!(:state; description="Root")
    child = initialize_progress!(root, 100; description="Loop")
    update_progress!(child, 50)
    @test child.impl.i == 50
    update_progress!(child, 200)
    @test child.impl.i == 100
    finalize_progress!(root)
end

@testset "increment" begin
    root = initialize_progress!(:state; description="Root")
    child = initialize_progress!(root, 10; description="Loop")
    update_progress!(child)
    @test child.impl.i == 1
    update_progress!(child)
    @test child.impl.i == 2
    finalize_progress!(root)
end

@testset "string message" begin
    root = initialize_progress!(:state; description="Root")
    child = initialize_progress!(root; description="Info")
    update_progress!(child, "hello")
    @test child.impl.message == "hello"
    finalize_progress!(root)
end

@testset "fail" begin
    root = initialize_progress!(:state; description="Root")
    fail_progress!(root)
    @test root.impl.failed == true
    @test root.impl.running == false
    @test !isnothing(root.impl.finalized_at)
    @test is_failed(root)
    @test !is_running(root)
end

@testset "timestamps and status helpers" begin
    root = initialize_progress!(:state; description="Root")
    @test root.impl.started_at isa Dates.DateTime
    @test isnothing(root.impl.finalized_at)
    @test is_running(root)
    @test !is_finished(root)
    @test !is_failed(root)
    @test duration(root) isa Union{Dates.Period, Dates.CompoundPeriod}

    finalize_progress!(root)
    @test !is_running(root)
    @test is_finished(root)
    @test !is_failed(root)
    @test root.impl.finalized_at isa Dates.DateTime
    @test root.impl.finalized_at >= root.impl.started_at
end

@testset "short_duration" begin
    @test short_duration(Dates.Second(4)) == "4s"
    @test short_duration(Dates.Minute(1) + Dates.Second(23)) == "1m 23s"
    @test short_duration(Dates.Hour(2) + Dates.Minute(5) + Dates.Second(30)) == "2h 5m"
    @test short_duration(Dates.Millisecond(0)) == "0s"
    @test short_duration(Dates.Millisecond(50)) == "50ms"
    @test short_duration(Dates.Millisecond(500)) == "0.5s"
    # Sub-minute: single one-decimal-second value (floor at 0.1s), not the old
    # two-most-significant join (13900ms used to render "13s 0.9s").
    @test short_duration(Dates.Millisecond(600)) == "0.6s"
    @test short_duration(Dates.Millisecond(2700)) == "2.7s"
    @test short_duration(Dates.Millisecond(13900)) == "13.9s"
    @test short_duration(Dates.Millisecond(59900)) == "59.9s"
    # Trailing .0 trimmed.
    @test short_duration(Dates.Second(13)) == "13s"
    @test short_duration(Dates.Millisecond(13000)) == "13s"
    # Floor, not round: 13990ms truncates to 13.9s (would round up to 14.0s).
    @test short_duration(Dates.Millisecond(13990)) == "13.9s"
    # Sub-100ms keeps millisecond precision.
    @test short_duration(Dates.Millisecond(99)) == "99ms"
    # ≥ 1 min keeps the two-most-significant join.
    @test short_duration(Dates.Minute(1) + Dates.Second(30)) == "1m 30s"
    @test short_duration(Dates.Hour(1) + Dates.Minute(1)) == "1h 1m"
end

@testset "htmx_render duration suffix: work-leaf yes, annotation no" begin
    # A message-bearing work-leaf (disk-load style: message, no counter, not an
    # annotation) shows the duration suffix.
    root = initialize_progress!(:state; description="Root")
    leaf = initialize_progress!(root; description="from disk", value="2.5 GB")
    finalize_progress!(leaf)
    leaf_html = sprint(io -> show(io, MIME"text/html"(), htmx_render(leaf)))
    @test occursin("treebar-duration", leaf_html)
    @test occursin("done", leaf_html)

    # A key:value annotation label (created by _update_labels! via update_progress!
    # kwargs) is marked annotation=true and omits the suffix — its "duration" would
    # just be the parent's lifetime.
    root2 = initialize_progress!(:state; description="Root2")
    update_progress!(root2, nothing; acceptance="0.95")
    ann = first(root2.children)
    @test get(ann.meta, :annotation, false) === true
    ann_html = sprint(io -> show(io, MIME"text/html"(), htmx_render(ann)))
    @test occursin("treebar-label", ann_html)
    @test !occursin("treebar-duration", ann_html)

    finalize_progress!(root)
    finalize_progress!(root2)
end

@testset "_first_seen! render dedup helper (pure, no renderer/DO)" begin
    # Unit-tests Treebars._first_seen! directly on hand-built ProgressNodes —
    # no htmx_render, no HTMXObjects, no DynamicObjects involved.
    root = initialize_progress!(:state; description="Root")
    a = initialize_progress!(root; description="A")
    b = initialize_progress!(root; description="B")

    seen = Base.IdSet{Treebars.ProgressNode}()
    @test Treebars._first_seen!(seen, a) == true    # first encounter -> render + mark
    @test Treebars._first_seen!(seen, a) == false   # same node again in this pass -> skip
    @test Treebars._first_seen!(seen, b) == true    # a distinct node is unaffected

    # A different `seen` set (models a different render pass / different tree)
    # has no memory of the first: this is what preserves DO's cross-tree sharing.
    seen2 = Base.IdSet{Treebars.ProgressNode}()
    @test Treebars._first_seen!(seen2, a) == true

    finalize_progress!(root)
end

@testset "htmx_render dedup: same-tree duplicate renders once" begin
    # (a) A node add_child!'d under TWO parents in the SAME tree: the doubled
    # node's content must appear exactly once in the rendered HTML.
    root = initialize_progress!(:state; description="Root")
    a = initialize_progress!(root; description="HostA")
    dup = initialize_progress!(root; description="DupNode")
    add_child!(a, dup)   # dup is now reachable as BOTH root's direct child AND a's child
    finalize_progress!(dup)
    finalize_progress!(a)

    html = sprint(io -> show(io, MIME"text/html"(), htmx_render(root)))
    @test count("DupNode", html) == 1

    finalize_progress!(root)
end

@testset "htmx_render dedup: cross-tree same node renders in EACH (regression guard)" begin
    # (b) THE critical case: the SAME node add_child!'d under two SEPARATE
    # roots must still render once in EACH root's own render pass — proving
    # per-tree (not global) dedup, which is what preserves DynamicObjects'
    # intentional cross-tree substatus sharing.
    root1 = initialize_progress!(:state; description="Root1")
    root2 = initialize_progress!(:state; description="Root2")
    shared = initialize_progress!(root1; description="SharedNode")
    add_child!(root2, shared)   # shared is reachable from BOTH root1 and root2; .parent stays root1

    html1 = sprint(io -> show(io, MIME"text/html"(), htmx_render(root1)))
    html2 = sprint(io -> show(io, MIME"text/html"(), htmx_render(root2)))
    @test occursin("SharedNode", html1)
    @test occursin("SharedNode", html2)

    finalize_progress!(shared)
    finalize_progress!(root1)
    finalize_progress!(root2)
end

@testset "htmx_render dedup: normal single-parent tree unchanged" begin
    # (c) No regression: an ordinary tree with no shared nodes renders each
    # child exactly once, same as before this feature.
    root = initialize_progress!(:state; description="Root")
    a = initialize_progress!(root; description="ChildA")
    b = initialize_progress!(root; description="ChildB")
    finalize_progress!(a)
    finalize_progress!(b)

    html = sprint(io -> show(io, MIME"text/html"(), htmx_render(root)))
    @test count("ChildA", html) == 1
    @test count("ChildB", html) == 1

    finalize_progress!(root)
end

@testset "htmx_render dedup: children fully deduped away -> header-only, no placeholder" begin
    # Edge case folded in at plan-gate review: if a host node's entire child
    # list dedupes away (every child already rendered elsewhere in this pass),
    # the host's OWN header/duration must still render, but its children
    # section must emit nothing rather than the misleading "Starting..." /
    # message spinner fallback.
    root = initialize_progress!(:state; description="Root")
    a = initialize_progress!(root; description="HostA")
    p = initialize_progress!(root; description="HostP")
    shared = initialize_progress!(a; description="Shared2")
    add_child!(p, shared)   # shared reachable from BOTH a (its real parent) and p

    finalize_progress!(shared)
    finalize_progress!(a)
    finalize_progress!(p)

    html = sprint(io -> show(io, MIME"text/html"(), htmx_render(root)))
    @test occursin("HostP", html)          # p's own header still renders
    @test !occursin("Starting...", html)   # no misleading placeholder for p's deduped-away children
    @test count("Shared2", html) == 1      # shared renders exactly once (under HostA, visited first)

    finalize_progress!(root)
end

@testset "labels create sub-nodes" begin
    root = initialize_progress!(:state; description="Root")
    child = initialize_progress!(root, 10; description="Loop")
    update_progress!(child, 1; speed="fast", temp="hot")
    @test length(child.children) == 2
    finalize_progress!(root)
end

@testset "finalize keeps non-transient node in parent" begin
    root = initialize_progress!(:state; description="Root")
    child = initialize_progress!(root, 10; description="Child")
    @test length(root.children) == 1
    finalize_progress!(child)
    @test length(root.children) == 1
    @test child.impl.running == false
    finalize_progress!(root)
end

@testset "finalize detaches transient node from parent" begin
    root = initialize_progress!(:state; description="Root")
    child = initialize_progress!(root, 10; description="Child", transient=true)
    @test length(root.children) == 1
    finalize_progress!(child)
    @test length(root.children) == 0
    @test child ∉ root.children
    @test child.impl.running == false
    # Double finalize must be a no-op (3-arg pop handles already-detached case)
    finalize_progress!(child)
    @test length(root.children) == 0
    finalize_progress!(root)
end

@testset "fail does NOT detach transient node" begin
    # Intentional asymmetry: failed transients stay pinned so htmx pills can show them
    root = initialize_progress!(:state; description="Root")
    child = initialize_progress!(root, 10; description="Child", transient=true)
    fail_progress!(child)
    @test length(root.children) == 1
    @test child in root.children
    @test is_failed(child)
    finalize_progress!(root)
end

@testset "fail recurses into children" begin
    root = initialize_progress!(:state; description="Root")
    child1 = initialize_progress!(root, 10; description="Child1")
    child2 = initialize_progress!(root, 10; description="Child2")
    fail_progress!(root)
    @test is_failed(root)
    @test is_failed(child1)
    @test is_failed(child2)
end

@testset "propagating finalization" begin
    combo = initialize_progress!(:state, 10; description="Auto")
    parent_node = combo.parent
    @test parent_node.impl.running == true
    finalize_progress!(combo)
    @test parent_node.impl.running == false
end

@testset "with_progress" begin
    result = with_progress(:state; description="Test") do p
        update_progress!(p, "working")
        42
    end
    @test result == 42

    @test_throws ErrorException with_progress(:state; description="Fail") do p
        error("boom")
    end
end

@testset "@progress macro" begin
    root = initialize_progress!(:state; description="Root")
    count = 0
    @progress root for i in 1:5
        count += 1
    end
    @test count == 5
    finalize_progress!(root)
end

@testset "@progress for with bare phase markers" begin
    # Bare `@progress "label"` markers in a for body get an implicit per-iteration
    # label-less wrapper node; phases enumerate per iteration and clean up (no
    # accumulation), and the label-less wrapper auto-inlines at render.
    root = initialize_progress!(:state; description="Root")
    snap = Ref{Any}(nothing)
    count = 0
    @progress root for i in 1:3
        @progress "load"
        count += 1
        i == 2 && (snap[] = Treebars.progress_state(root))
        @progress "fit"
    end
    finalize_progress!(root)
    @test count == 3

    # Mid-iteration: under the counter node sits one label-less wrapper carrying
    # the two pre-enumerated phases.
    counter_snap = snap[]["children"][1]
    @test length(counter_snap["children"]) == 1
    wrap_snap = counter_snap["children"][1]
    @test wrap_snap["description"] == ""                       # label-less ⇒ auto-inlines
    @test [c["description"] for c in wrap_snap["children"]] == ["load", "fit"]

    # The label-less wrapper is a bare wrapper that does not render itself.
    counter = only(root.children)
    @test counter.impl.description == "for i in ..."
    # Phases do not accumulate: each iteration's transient wrapper is detached.
    @test length(counter.children) == 0

    # Bare for WITHOUT markers is unchanged: body attaches straight to the counter
    # (no wrapper, no phase children).
    root2 = initialize_progress!(:state; description="Root2")
    @progress root2 for i in 1:3
        i + 1
    end
    finalize_progress!(root2)
    @test length(only(root2.children).children) == 0

    # Interpolated bare markers are NOT a silent no-op — they pre-enumerate a real
    # phase per iteration with the interpolated (loop-scope) label.
    root3 = initialize_progress!(:state; description="Root3")
    isnap = Ref{Any}(nothing)
    @progress root3 for i in 1:3
        @progress "phase $i"
        i == 2 && (isnap[] = Treebars.progress_state(root3))
    end
    finalize_progress!(root3)
    iwrap = isnap[]["children"][1]["children"][1]
    @test [c["description"] for c in iwrap["children"]] == ["phase 2"]
    @test length(only(root3.children).children) == 0
end

@testset "@progress compact multi-generator for (a bar at every level)" begin
    # `for a in X, b in Y` — Julia's Cartesian sugar, whose header parses as an
    # `Expr(:block, …)` — desugars to nested single-var loops so EVERY level
    # gets its own progress bar (user decision 8fmgjl). Was a hard
    # AssertionError on valid syntax.
    root = initialize_progress!(:state; description="Root")
    snap = Ref{Any}(nothing)
    n = 0
    @progress root for oi in 1:2, di in 1:3
        n += 1
        (oi == 1 && di == 2) && (snap[] = Treebars.progress_state(root))
    end
    finalize_progress!(root)
    @test n == 6                                        # full Cartesian product ran

    outer = snap[]["children"][1]
    @test outer["description"] == "for oi in ..."       # outer bar
    @test outer["N"] == 2
    inner = outer["children"][1]
    @test inner["description"] == "for di in ..."        # inner bar, nested under outer
    @test inner["N"] == 3
    # Inner bars are transient ⇒ detached each outer iteration, no accumulation.
    @test length(only(root.children).children) == 0

    # Three generators ⇒ three nested levels, each with its own bar.
    root2 = initialize_progress!(:state; description="Root2")
    snap2 = Ref{Any}(nothing)
    @progress root2 for a in 1:2, b in 1:2, c in 1:2
        (a == 1 && b == 1 && c == 1) && (snap2[] = Treebars.progress_state(root2))
    end
    finalize_progress!(root2)
    l1 = snap2[]["children"][1]
    l2 = l1["children"][1]
    l3 = l2["children"][1]
    @test [l1["description"], l2["description"], l3["description"]] ==
          ["for a in ...", "for b in ...", "for c in ..."]

    # Reporter's exact case: compact for inside `@progress "label" begin…end`.
    root3 = initialize_progress!(:state; description="Root3")
    hit = 0
    @progress root3 begin
        @progress "compute"
        for oi in 1:2, di in 1:2
            hit += 1
        end
    end
    finalize_progress!(root3)
    @test hit == 4
end

@testset "@progress @threads compact multi-generator → @threads' own error" begin
    # Per user decision 8fmgjl, don't support under @threads what @threads
    # itself rejects. The guardrail passes the compact `@threads for` macrocall
    # through untouched, so @threads surfaces its own native error rather than a
    # Treebars assert or silently-broken code.
    compact = :(Threads.@threads for a in 1:2, b in 1:3
        nothing
    end)
    @test Treebars._threads_for_progress_expr(
        compact, (progress = :__p__, transient = false); description = nothing) === compact

    # End-to-end: expanding the wrapped form raises @threads' native error.
    err = try
        include_string(Main, """
            using Treebars
            let r = initialize_progress!(:state; description="R")
                @progress r Threads.@threads for a in 1:2, b in 1:3
                    nothing
                end
            end
        """)
        nothing
    catch e
        e
    end
    @test err !== nothing
    @test occursin("nested outer loops are not currently supported by @threads",
                   sprint(showerror, err))
end

@testset "@progress @threads for with bare phase markers" begin
    # Mirror of the serial "@progress for with bare phase markers" testset, for the
    # Threads.@threads form. Each concurrent iteration gets its own per-iteration,
    # transient, label-less wrapper hosting the pre-enumerated phases; the wrapper
    # finalizes + detaches per iteration so phases don't accumulate. Valid at any
    # thread count (the lowering + no-accumulation hold under -t1); real concurrency
    # is exercised when run with `julia -t2`.
    root = initialize_progress!(:state; description="Root")
    snap = Ref{Any}(nothing)
    count = Threads.Atomic{Int}(0)
    @progress root Threads.@threads for i in 1:3
        @progress "load"
        Threads.atomic_add!(count, 1)
        i == 2 && (snap[] = Treebars.progress_state(root))
        @progress "fit"
    end
    finalize_progress!(root)
    @test count[] == 3

    # The counter node is determinate (length 3) and labeled by the iteration var.
    counter = only(root.children)
    @test counter.impl.description == "for i in ..."
    # Phases do not accumulate: each iteration's transient wrapper is detached.
    @test length(counter.children) == 0

    # Mid-run: at least one label-less wrapper sits under the counter, each carrying
    # the two pre-enumerated phases. (Under concurrency >1 wrapper may coexist; the
    # finished-pill filter hides completed ones at render — that's expected.)
    counter_snap = snap[]["children"][1]
    @test length(counter_snap["children"]) >= 1
    for wrap_snap in counter_snap["children"]
        @test wrap_snap["description"] == ""                    # label-less ⇒ auto-inlines
        @test [c["description"] for c in wrap_snap["children"]] == ["load", "fit"]
    end

    # Bare @threads for WITHOUT markers (and no nested @progress) is unchanged: the
    # body attaches straight to the counter, no wrapper, no phase children.
    root2 = initialize_progress!(:state; description="Root2")
    @progress root2 Threads.@threads for i in 1:3
        i + 1
    end
    finalize_progress!(root2)
    @test length(only(root2.children).children) == 0
end

@testset "@progress block — leading stmts sort above labeled phases" begin
    # Implicit leading-phase node: statements BEFORE the first phase marker run
    # under an auto LABEL-LESS node created FIRST, so a progress child a leading
    # statement creates (via __progress__) sorts ABOVE the labeled phases in the
    # OrderedSet `children`. Without the fix the leading-created child was
    # add_child!'d after the pending phase nodes and rendered below them.
    root = initialize_progress!(:state; description="Root")
    @progress root begin
        lead = initialize_progress!(__progress__; description="lead-load")
        finalize_progress!(lead)
        @progress "Phase A"
        1 + 1
        @progress "Phase B"
        2 + 2
    end
    snap = Treebars.progress_state(root)
    finalize_progress!(root)

    # root → [leading-wrapper(""), "Phase A", "Phase B"] — the leading wrapper is
    # FIRST, carrying the leading-created child; the labeled phases follow.
    @test [c["description"] for c in snap["children"]] == ["", "Phase A", "Phase B"]
    lead_wrap = snap["children"][1]
    @test lead_wrap["description"] == ""                       # label-less ⇒ auto-inlines
    @test [c["description"] for c in lead_wrap["children"]] == ["lead-load"]
    # Non-transient block: the finished leading child persists (not detached).
    @test lead_wrap["running"] == false

    # Leading stmts that create NO progress child: the leading wrapper still
    # fires (a real pre-marker statement) but stays empty, so it auto-inlines to
    # nothing at render and does not add to the visible tree.
    root2 = initialize_progress!(:state; description="Root2")
    @progress root2 begin
        z = 41 + 1
        @progress "Only"
        z
    end
    snap2 = Treebars.progress_state(root2)
    finalize_progress!(root2)
    @test [c["description"] for c in snap2["children"]] == ["", "Only"]
    # No "children" key ⇒ the wrapper has no children ⇒ auto-inlines to nothing.
    @test !haskey(snap2["children"][1], "children")

    # Marker-FIRST block (no leading stmts): unchanged — no leading wrapper.
    root3 = initialize_progress!(:state; description="Root3")
    @progress root3 begin
        @progress "First"
        1 + 1
        @progress "Second"
        2 + 2
    end
    snap3 = Treebars.progress_state(root3)
    finalize_progress!(root3)
    @test [c["description"] for c in snap3["children"]] == ["First", "Second"]
end

@testset "@phases explicit node — block" begin
    # Each top-level statement of the block becomes its own pre-enumerated,
    # timed phase (label = shortened source). All statements share one try-scope
    # so assignments stay visible across phases, and the block is value-preserving.
    root = initialize_progress!(:state; description="Root")
    result = @phases root begin
        x = 1 + 1
        y = x * 10
    end
    @test result == 20                       # value-preserving + cross-phase visibility (y used x)
    snap = Treebars.progress_state(root)     # wrapper already finalized by its own finally
    finalize_progress!(root)

    # root → label-less wrapper → [phase "x = 1 + 1", phase "y = x * 10"]
    @test length(snap["children"]) == 1
    wrap = snap["children"][1]
    @test wrap["description"] == ""          # label-less ⇒ auto-inlines at render
    @test wrap["running"] == false
    phases = wrap["children"]
    @test [c["description"] for c in phases] == ["x = 1 + 1", "y = x * 10"]
    # Each phase was started AND finalized ⇒ it carries a per-statement duration.
    @test all(c -> c["running"] == false && c["finalized_at"] !== nothing, phases)
end

@testset "@phases explicit node — for body (per-iteration phases)" begin
    # In a for body, each statement becomes a per-iteration phase under the
    # iteration counter; the per-iteration wrapper finalizes + detaches each
    # iteration, so phases never accumulate. The loop-profiling use case.
    root = initialize_progress!(:state; description="Root")
    snap = Ref{Any}(nothing)
    # Capture during the FIRST phase: phase 1 is running and the later phases are
    # still pending — so all three are attached. (As phases finalize they detach,
    # since for-body phases are transient — hence the in-body snapshot.)
    @phases root for i in 1:3
        i == 2 && (snap[] = Treebars.progress_state(root))
        a = i + 1
        b = a * 2
    end
    finalize_progress!(root)

    # root → counter("for i in ...") → per-iteration label-less wrapper → phases
    counter = only(root.children)
    @test counter.impl.description == "for i in ..."
    @test counter.impl.i == 3                # counter advanced once per iteration
    @test length(counter.children) == 0      # per-iteration wrappers detached ⇒ no accumulation

    # Mid-iteration: one wrapper carrying the three pre-enumerated per-statement
    # phases; the last two have clean shortened-source labels.
    counter_snap = snap[]["children"][1]
    @test length(counter_snap["children"]) == 1
    wrap = counter_snap["children"][1]
    @test wrap["description"] == ""
    @test length(wrap["children"]) == 3
    @test [c["description"] for c in wrap["children"]][2:3] == ["a = i + 1", "b = a * 2"]
end

@testset "@phases bare (active node) inside @progress" begin
    # The ergonomic bare form: `@phases body` with no node, eager-expanded by the
    # @progress walker against the active node. Here the transparent
    # `@progress root begin … end` makes root the active node, so the @phases
    # wrapper attaches directly under root.
    root = initialize_progress!(:state; description="Root")
    @progress root begin
        @phases begin
            p = 3
            q = p + 4
        end
    end
    snap = Treebars.progress_state(root)
    finalize_progress!(root)

    @test length(snap["children"]) == 1
    wrap = snap["children"][1]
    @test wrap["description"] == ""
    @test [c["description"] for c in wrap["children"]] == ["p = 3", "q = p + 4"]
end

@testset "IterableProgress" begin
    root = initialize_progress!(:state; description="Root")
    ip = Treebars.initialize_iterable_progress!(root, 1:3; description="Iter")
    collected = []
    for x in ip
        push!(collected, x)
    end
    @test collected == [1, 2, 3]
    finalize_progress!(root)
end

@testset "Treebars.progress_state (JSON snapshot)" begin
    root = initialize_progress!(:state; description="Root")
    child = initialize_progress!(root, 10; description="Step")
    update_progress!(child, 5)

    state = Treebars.progress_state(root)
    @test state isa Dict
    @test state["description"] == "Root"
    @test state["running"] == true
    @test haskey(state, "children")
    @test length(state["children"]) == 1

    child_state = state["children"][1]
    @test child_state["description"] == "Step"
    @test child_state["N"] == 10
    @test child_state["i"] == 5

    finalize_progress!(root)
    state2 = Treebars.progress_state(root)
    @test state2["running"] == false

    @test Treebars.progress_state(nothing) === nothing
end

@testset "Web polling simulation" begin
    root = initialize_progress!(:state; description="Sampling")
    mcmc = initialize_progress!(root, 1000; description="MCMC")

    worker = Threads.@spawn begin
        for i in 1:10
            update_progress!(mcmc, i * 100; stepsize="0.1", divergences="0")
            sleep(0.01)
        end
        finalize_progress!(mcmc)
    end

    states = []
    for _ in 1:5
        push!(states, Treebars.progress_state(root))
        sleep(0.01)
    end
    wait(worker)

    for s in states
        @test s isa Dict
        @test s["description"] == "Sampling"
    end

    final = Treebars.progress_state(root)
    @test final["description"] == "Sampling"

    mid_state = states[end]
    if haskey(mid_state, "children")
        mcmc_children = filter(c -> c["description"] == "MCMC", mid_state["children"])
        if !isempty(mcmc_children)
            @test mcmc_children[1]["N"] == 1000
            @test mcmc_children[1]["i"] >= 0
        end
    end

    finalize_progress!(root)
end

@testset "round2" begin
    @test round2(3.14159) == 3.1
    @test round2(100) == 100
    @test round2(0.00123) == 0.0012
    @test round2((1.23, 4.56)) == (1.2, 4.6)
    @test round2(missing) === missing
    @test round2("hello") == "hello"
end

@testset "short_string" begin
    @test short_string(3.14159) == "3.1"
    @test short_string(1000) == "1.0k"
    @test short_string(1_500_000) == "1.5M"
    @test short_string(2_000_000_000) == "2.0G"
    @test short_string(42) == "42"
    @test short_string([1, 2, 3]) == "[1, 2, 3]"
    @test short_string(:a => 1) == "a => 1"
    @test short_string((; x=1, y=2)) == "(;x=1, y=2)"
end

@testset "Fraction" begin
    f = Fraction(0.5)
    @test short_string(f) == "50%"
    @test Fraction(0.3) < Fraction(0.7)
    @test isequal(Fraction(0.5), Fraction(0.5))
end

@testset "long vector truncation" begin
    v = collect(1:10)
    s = short_string(v)
    @test occursin("...", s)
    @test startswith(s, "[1, 2, 3,")
    @test endswith(s, "8, 9, 10]")
end

@testset "DO ThreadsafeDict leaves failed substatus visible" begin
    # Asymmetric with the success path: on failure, _fail_substatus! calls
    # Treebars.fail_progress! (which does NOT detach transient nodes) so the
    # failed substatus stays pinned to the tree for inspection until the user
    # retries the key (which triggers DO's retry_failed cleanup).
    app = _FailedSubstatusTest(; cache_type=:parallel)
    t = Threads.@spawn app.results[:boom]
    try; wait(t); catch; end
    @test istaskdone(t) && istaskfailed(t)

    children = app.__status__.children
    @test length(children) == 1
    @test is_failed(children[1])

    finalize_progress!(app.__status__)
end

@testset "DO ThreadsafeDict auto-cleans substatus tree" begin
    # The bruno SimState scenario: many cache-miss keys should not accumulate
    # children in app.__status__ after their tasks finish. The TreebarsExt
    # `_default_substatus` now passes transient=true, so finalize_progress!
    # (called by the auto-generated @progress wrapper around the property body)
    # detaches each substatus from the root tree on success.
    app = _AutoCleanupTest(; cache_type=:parallel)
    @test length(app.__status__.children) == 0

    n_keys = 8
    tasks = [Threads.@spawn(app.results[k]) for k in 1:n_keys]
    for t in tasks; wait(t); end

    # All tasks finished → all substatus nodes should be detached
    @test length(app.__status__.children) == 0
    # And the actual cached results are still there
    @test all(app.results[k] == 2k for k in 1:n_keys)

    finalize_progress!(app.__status__)
end

@testset "@dynamicstruct inline child substatus" begin
    p = _InlineSubTest(; cache_type=:parallel)
    # Accessing p.InlineSub triggers construction with __status__ = substatus scoped to :InlineSub
    child_status = p.InlineSub.__status__
    @test child_status isa Treebars.ProgressNode
    # Child's status is a child of the parent's root status
    @test child_status.parent === p.__status__
    @test child_status.impl.description == "InlineSub[]"
    # Inline child inherits cache_type from parent
    @test p.InlineSub.__cache_type__ == p.__cache_type__
    finalize_progress!(p.__status__)
end

@testset "Concurrency stress test" begin
    root = initialize_progress!(:state; description="Stress")

    n_workers = max(4, Threads.nthreads())
    n_iterations = 100
    errors = Threads.Atomic{Int}(0)

    # Spawn workers that rapidly create, update, and finalize children
    workers = map(1:n_workers) do w
        Threads.@spawn begin
            for i in 1:n_iterations
                child = initialize_progress!(root, 10; description="W$w-$i")
                for j in 1:10
                    update_progress!(child, j; speed="$j", temp="$(rand())")
                end
                finalize_progress!(child)
            end
        end
    end

    # Concurrent poller that reads the tree while it's being mutated
    poll_count = Threads.Atomic{Int}(0)
    poller = Threads.@spawn begin
        while any(!istaskdone, workers)
            try
                Treebars.progress_state(root)
                Threads.atomic_add!(poll_count, 1)
            catch e
                Threads.atomic_add!(errors, 1)
            end
            yield()
        end
    end

    for w in workers; wait(w); end
    wait(poller)

    @test errors[] == 0
    @test poll_count[] > 0
    finalize_progress!(root)
end

@testset "render_text: labels, nesting, counters, state, duration" begin
    root = initialize_progress!(:state; description="probe")
    done = initialize_progress!(root; description="load data")
    finalize_progress!(done)
    running = initialize_progress!(root, 10; description="fit")
    update_progress!(running, 3)
    update_progress!(running, "chain 2")
    pending = prepare_progress!(root; description="plot")

    txt = render_text(root)
    lines = split(txt, "\n")

    @test occursin("probe", lines[1])
    @test any(l -> occursin("✓", l) && occursin("load data", l), lines)
    @test any(l -> occursin("▶", l) && occursin("fit", l) && occursin("(3/10)", l) &&
                   occursin("chain 2", l), lines)
    # A pending node shows its marker but NO duration (it has not started).
    plot_line = only(filter(l -> occursin("plot", l), lines))
    @test occursin("·", plot_line)
    @test !occursin("[", plot_line)
    # Children are nested under the root, not flattened into it.
    @test all(l -> occursin("─", l), lines[2:end])

    fail_progress!(pending, ErrorException("boom"))
    @test occursin("✗", render_text(root))

    @test render_text(nothing) == "(no progress tree)"
    finalize_progress!(root)

    # `show(::MIME"text/plain")` delegates to render_text. Asserted on a fully
    # FINALIZED tree so the durations are frozen — a running node's duration
    # counts up to `now()`, so two renders of a live tree legitimately differ.
    frozen = initialize_progress!(:state; description="frozen")
    leaf = initialize_progress!(frozen; description="leaf")
    finalize_progress!(leaf)
    finalize_progress!(frozen)
    @test sprint(show, MIME"text/plain"(), frozen) == render_text(frozen)
    # Compact 2-arg show stays a single line.
    @test !occursin("\n", sprint(show, frozen))
end

@testset "render_text display semantics match the HTML renderer" begin
    # Both renderers go through `_flatten_displayed_children` + `_first_seen!`,
    # so a text dump can be trusted to predict what the browser shows. These
    # are the three behaviors that would silently diverge if they ever forked.
    root = initialize_progress!(:state; description="Root")

    # (a) A bare wrapper (no description/message/counter) inlines, hoisting.
    bare = initialize_progress!(root; description="")
    initialize_progress!(bare; description="hoisted")
    txt = render_text(root)
    @test occursin("hoisted", txt)
    @test count("\n", txt) == 1   # root + hoisted child only — no wrapper level

    # (b) An explicit `displayed=false` node hoists the same way.
    hidden = initialize_progress!(root; description="HIDDENNODE", displayed=false)
    initialize_progress!(hidden; description="VISIBLECHILD")
    txt = render_text(root)
    @test !occursin("HIDDENNODE", txt)
    # …and its child hoists to root's level: a top-level connector, no indent.
    @test any(l -> startswith(l, "└─ ") && occursin("VISIBLECHILD", l), split(txt, "\n"))

    # (c) A node reachable from two parents (DO's substatus fan-out) renders
    # once per tree — matching the htmx_render dedup testset above.
    host = initialize_progress!(root; description="HostA")
    dup = initialize_progress!(root; description="DupNode")
    add_child!(host, dup)
    @test count("DupNode", render_text(root)) == 1

    finalize_progress!(root)
end

@testset "@progress warns on a docstring-swallowed phase marker" begin
    # A bare `"label"` before a statement inside a `begin…end` is rewritten by
    # the PARSER into `Core.@doc`, so it never reaches the macro as a marker and
    # renders nothing — parse-clean and precompile-clean, the one @progress
    # failure mode no offline check catches. Expansion must warn.
    swallowed = quote
        @progress p begin
            "swallowed marker"
            x = 1
        end
    end
    @test_logs (:warn,) match_mode = :any macroexpand(@__MODULE__, swallowed)

    # The macro form must stay silent — no false positive on correct code.
    proper = quote
        @progress p begin
            @progress "real marker"
            x = 1
        end
    end
    @test_logs macroexpand(@__MODULE__, proper)

    # A docstring at `@dynamicstruct` struct-body level (the legitimate DO
    # pattern used throughout this repo's demos) is NOT inside a @progress
    # block body, so it must not warn either.
    @test !Treebars._is_doc_macrocall(:(x = 1))
    @test Treebars._is_doc_macrocall(
        Expr(:macrocall, GlobalRef(Core, Symbol("@doc")), nothing, "d", :(f() = 1)))
end
