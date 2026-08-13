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

@testset "eta eligibility and formula" begin
    # The parent has a determinate total, but i == 0 gives no rate yet.
    parent = initialize_progress!(:state; description="parent", N=4)
    @test eta(parent) === nothing

    # Two seconds elapsed at 2/10 implies roughly eight seconds remaining:
    # elapsed * (N - i) / i = elapsed * 4.
    eligible = initialize_progress!(parent, 10; description="eligible")
    eligible.impl.started_at = Dates.now() - Dates.Second(2)
    update_progress!(eligible, 2)
    remaining = eta(eligible)
    @test remaining isa Dates.Millisecond
    @test isapprox(
        Dates.value(remaining),
        4 * Dates.value(duration(eligible));
        atol=50,
    )

    # Automatic ETA is omitted when there is no meaningful estimate.
    indeterminate = initialize_progress!(parent; description="indeterminate")
    @test eta(indeterminate) === nothing

    pending = prepare_progress!(parent, 10; description="pending")
    @test eta(pending) === nothing
    skip_progress!(pending)
    @test eta(pending) === nothing

    one_item = initialize_progress!(parent, 1; description="one item")
    @test eta(one_item) === nothing
    update_progress!(one_item, 1)
    @test eta(one_item) === nothing

    terminal = initialize_progress!(parent, 10; description="terminal")
    terminal.impl.started_at = Dates.now() - Dates.Second(2)
    update_progress!(terminal, 2)
    finalize_progress!(terminal)
    @test eta(terminal) === nothing

    text = render_text(parent)
    @test count("eligible", text) == 1
    @test count("ETA ~", text) == 1

    finalize_progress!(parent)
end

@testset "htmx_render automatic ETA eligibility" begin
    # Render the real extension over one eligible child plus the important
    # omission cases. Exactly one node may carry ETA markup/text.
    parent = initialize_progress!(:state; description="parent", N=4)

    eligible = initialize_progress!(parent, 10; description="eligible")
    eligible.impl.started_at = Dates.now() - Dates.Second(2)
    update_progress!(eligible, 2)

    one_item = initialize_progress!(parent, 1; description="one item")
    update_progress!(one_item, 1)

    terminal = initialize_progress!(parent, 10; description="terminal")
    terminal.impl.started_at = Dates.now() - Dates.Second(2)
    update_progress!(terminal, 2)
    finalize_progress!(terminal)

    html = sprint(io -> show(io, MIME"text/html"(), htmx_render(parent)))
    @test count("data-elapsed-ms", html) == 4  # control: all four nodes rendered
    @test count("data-eta-ms", html) == 1
    @test count("ETA ~", html) == 1

    finalize_progress!(parent)
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
    @test occursin("treebar-header", ann_html)
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

@testset "skip_progress! — the never-ran terminal state" begin
    # The lifecycle is encoded in two timestamps plus `failed`; `skipped` is the
    # combination that was previously unreachable (finalized, never started).
    # These assert it stays MUTUALLY EXCLUSIVE with the other four — the whole
    # point of not backfilling `started_at`.
    root = initialize_progress!(:state; description="Root")
    p = prepare_progress!(root; description="never run")
    @test is_pending(p)
    skip_progress!(p)
    @test is_skipped(p)
    @test !is_pending(p) && !is_running(p) && !is_finished(p) && !is_failed(p)
    @test p.impl.started_at === nothing        # the discriminator: never ran
    @test p.impl.finalized_at !== nothing      # …but terminal, not dangling

    # Idempotent, and it can never downgrade a node that actually ran.
    was = p.impl.finalized_at
    skip_progress!(p)
    @test p.impl.finalized_at == was

    ran = prepare_progress!(root; description="ran")
    start_progress!(ran)
    finalize_progress!(ran)
    skip_progress!(ran)
    @test is_finished(ran) && !is_skipped(ran)

    running = prepare_progress!(root; description="running")
    start_progress!(running)
    skip_progress!(running)
    @test is_running(running) && !is_skipped(running)

    # No-ops on the disabled backend, like every other lifecycle function.
    @test skip_progress!(nothing) === nothing
    finalize_progress!(root)
end

@testset "finalize_progress! terminates pending children as skipped" begin
    # Covers every hand-rolled prepare_progress! caller, not just the two phase
    # macros: once the parent is done, a child still waiting to start never will,
    # so it must not stay `·` pending under a ✓ parent.
    root = initialize_progress!(:state; description="Root")
    ran = prepare_progress!(root; description="ran")
    start_progress!(ran)
    finalize_progress!(ran)
    left = prepare_progress!(root; description="left pending")
    nested = prepare_progress!(left; description="nested")

    finalize_progress!(root)
    @test is_finished(ran)
    @test is_skipped(left)
    @test is_skipped(nested)                   # recurses
    @test is_finished(root)
end

@testset "@progress block — an early return skips the phases it bypassed" begin
    # The reported case: a `return` past later phase markers left them PENDING
    # forever under a FINISHED parent. The macro's `finally` now terminates them.
    root = initialize_progress!(:state; description="Root")
    function _early(node, hit)
        @progress node begin
            @progress "resolve"
            r = 1
            @progress "read"
            hit && return :cached
            @progress "deserialize"
            r += 1
            @progress "postprocess"
            r
        end
    end
    @test _early(root, true) == :cached
    snap = Treebars.progress_state(root)
    finalize_progress!(root)

    # Marker-first block ⇒ the phases attach directly under root, no wrapper.
    phases = snap["children"]
    @test [c["description"] for c in phases] == ["resolve", "read", "deserialize", "postprocess"]
    # The two that ran carry a start; the two bypassed are terminal-but-unstarted.
    @test [c["skipped"] for c in phases] == [false, false, true, true]
    @test [c["started_at"] === nothing for c in phases] == [false, false, true, true]
    @test [c["finalized_at"] !== nothing for c in phases] == [true, false, true, true]
    @test all(c -> c["failed"] == false, phases)            # skipped ≠ failed

    # Phase 2 — the one control was INSIDE when it returned — is still running,
    # and that is unchanged, pre-existing behaviour, not an early-return artifact:
    # `_emit_phases` emits no trailing finalize, so the LAST in-flight phase is
    # terminated by the parent's `finalize_progress!` on the normal path too.
    # Asserted so a future change to that contract shows up here deliberately.
    @test phases[2]["running"] == true && phases[2]["skipped"] == false
end

@testset "@progress block — an exception fails only the RUNNING phase" begin
    # The corollary, and the one behaviour-visible change: unvisited phases used
    # to be marked FAILED with a backfilled started_at (✗, 0s, an error they
    # never saw). Only the phase that actually threw is failed now.
    root = initialize_progress!(:state; description="Root")
    function _boom(node)
        @progress node begin
            @progress "validate"
            v = 1
            @progress "filter"
            error("boom")
            @progress "reindex"
            v += 1
            @progress "summarize"
            v
        end
    end
    @test_throws ErrorException _boom(root)
    snap = Treebars.progress_state(root)
    finalize_progress!(root)

    phases = snap["children"]
    @test [c["description"] for c in phases] == ["validate", "filter", "reindex", "summarize"]
    @test [c["failed"] for c in phases] == [false, true, false, false]
    @test [c["skipped"] for c in phases] == [false, false, true, true]
    # The failed phase DID run, so it keeps a real start; the bypassed two do not.
    @test [c["started_at"] === nothing for c in phases] == [false, false, true, true]
end

@testset "with_prepared_phases — same skip semantics as the macro" begin
    # The HOF twin goes through _run_prepared_phases; it must not diverge from
    # the macro form, which is emitted separately.
    root = initialize_progress!(:state; description="Root")
    got = with_prepared_phases(root, ("a", "b", "c")) do phases
        start_progress!(phases[1]); finalize_progress!(phases[1])
        return :early
    end
    @test got == :early
    kids = collect(root.children)          # ThreadsafeSet — order-preserving, not indexable
    @test is_finished(kids[1])
    @test all(is_skipped, kids[2:3])

    # …and on the throw path, only the running one fails.
    root2 = initialize_progress!(:state; description="Root2")
    @test_throws ErrorException with_prepared_phases(root2, (:x, :y, :z)) do phases
        start_progress!(phases[1]); finalize_progress!(phases[1])
        start_progress!(phases[2])
        error("boom")
    end
    kids2 = collect(root2.children)
    @test is_finished(kids2[1])
    @test is_failed(kids2[2])
    @test is_skipped(kids2[3])
    finalize_progress!(root); finalize_progress!(root2)
end

@testset "render_text + htmx_render classify skipped distinctly" begin
    root = initialize_progress!(:state; description="Root")
    done = prepare_progress!(root; description="ranphase")
    start_progress!(done); finalize_progress!(done)
    gone = prepare_progress!(root; description="skippedphase")
    skip_progress!(gone)

    txt = render_text(root)
    skipped_line = only(filter(l -> occursin("skippedphase", l), split(txt, "\n")))
    @test occursin("⊘", skipped_line)
    @test !occursin("✓", skipped_line) && !occursin("✗", skipped_line)
    # No duration: the 0s is exactly what made a bypassed phase look instantaneous.
    @test !occursin("[", skipped_line)
    @test occursin("✓", only(filter(l -> occursin("ranphase", l), split(txt, "\n"))))

    html = sprint(io -> show(io, MIME"text/html"(), htmx_render(root)))
    @test occursin("treebar-child-skipped", html)
    @test occursin("1 skipped", html)                      # the toggle pill
    @test occursin("data-treebar-status=\"skipped\"", html)  # what the ticker dispatches on
    @test occursin("— skipped", html)                      # not a 0s duration
    # The regression this guards: the per-child map's bare `else` meant FAILED,
    # so a skipped child rendered in the failed group.
    @test !occursin("treebar-child-failed", html)
    finalize_progress!(root)
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
    # Reals abbreviate exactly like Integers — same value, same rendering.
    @test short_string(72000.0) == "72k"
    @test short_string(72000) == short_string(72000.0)
    @test short_string(1.5e6) == "1.5M"
    @test short_string(-72000.0) == "-72k"
    @test short_string(-72000) == "-72k"
    @test short_string(500.0) == "500"      # below the 1e3 threshold: round2, no suffix
    # round2 may round *up* across the threshold; the suffix keys off the raw value.
    @test short_string(999.0) == "1000"
    @test short_string(999_999) == "1000k"
    # A scaled value ≥ 1e3 must not be abbreviated twice ("1.0kG"), and must not
    # fall back to scientific notation ("9.2e9G") — the SI table runs to E.
    @test short_string(10^12) == "1.0T"
    @test short_string(1e12) == "1.0T"
    @test short_string(1e15) == "1.0P"
    @test short_string(9.2e18) == "9.2E"
    @test short_string(typemax(Int64)) == "9.2E"
    @test short_string(typemin(Int64)) == "-9.2E"   # float() before abs(): no wraparound
    @test short_string(big(10)^15) == "1.0P"
    # Past the largest suffix, render un-suffixed rather than emit "1000E".
    @test short_string(big(10)^24) == string(big(10)^24)
    # -x always renders as x with a leading "-" (the ".0" trim must ignore the sign).
    for v in Any[1.0, 10.0, 0.0, 1000, 1000.0, 2_000_000_000, 2.0e9, 72000.0, 1.5e6, 1e12]
        @test short_string(-v) == "-" * short_string(v)
    end
    @test short_string(-1.0) == "-1.0"
    @test short_string(-1000) == "-1.0k"
    # Non-finite Reals pass through untouched.
    @test short_string(NaN) == "NaN"
    @test short_string(Inf) == "Inf"
    @test short_string(-Inf) == "-Inf"
    # Bool is an Integer but must not be abbreviated or numeric-ified.
    @test short_string(true) == "true"
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

@testset "@progress / @phases accept a module-qualified head" begin
    # The walker only ever sees SOURCE, so `Treebars.@progress` is a different
    # macro head from `@progress`. Matching only the bare Symbol made every
    # qualified spelling invisible to it, and the three failure modes differed:
    # a 1-arg marker died with an ARITY error describing a different mistake,
    # while the 2-arg wrap and `@phases` silently built against `BACKEND[]`
    # (nothing in a web app) and produced NO node at all. Snag
    # `used-an-inline-p-baab62f1` — the qualified spelling is what a
    # `using DynamicObjects` consumer reaches for, since DO's `@progress` is
    # only its LHS parse-marker and no bare `@progress` is in scope.

    # (a) Qualified phase MARKERS split the block, exactly like bare ones.
    root = initialize_progress!(:state; description="QualMarkers")
    val = Treebars.@progress root begin
        Treebars.@progress "first"
        x = 1
        Treebars.@progress "second"
        x * 2
    end
    finalize_progress!(root)
    @test val == 2
    txt = render_text(root)
    @test occursin("first", txt)
    @test occursin("second", txt)

    # Bare and qualified must lower to the SAME tree — the whole point.
    # Durations are wall-clock, so compare the structure with them stripped.
    bare_root = initialize_progress!(:state; description="QualMarkers")
    @progress bare_root begin
        @progress "first"
        y = 1
        @progress "second"
        y * 2
    end
    finalize_progress!(bare_root)
    undated(s) = replace(s, r"\[[^\]]*\]" => "[]")
    @test undated(render_text(bare_root)) == undated(txt)

    # (b) The qualified 2-arg wrap attaches to the ENCLOSING node, not BACKEND[].
    #     This was the silent one: no node, no error.
    w = initialize_progress!(:state; description="QualWrap")
    Treebars.@progress w begin
        Treebars.@progress "sub" begin
            1 + 1
        end
    end
    finalize_progress!(w)
    @test occursin("sub", render_text(w))

    # (c) Qualified @phases likewise binds the active node.
    ph = initialize_progress!(:state; description="QualPhases")
    Treebars.@progress ph begin
        Treebars.@phases begin
            a = 1
            b = a + 1
        end
    end
    finalize_progress!(ph)
    @test occursin("a = 1", render_text(ph))

    # (d) A longer path whose LAST module component is Treebars also matches —
    #     `DynamicObjects.Treebars.@progress` is the spelling available to a
    #     consumer that only did `using DynamicObjects`.
    @test Treebars._is_progress_macrocall(
        Expr(:macrocall,
             Expr(:., Expr(:., :DynamicObjects, QuoteNode(:Treebars)),
                  QuoteNode(Symbol("@progress"))),
             nothing, "lbl"))
    @test Treebars._is_phases_macrocall(
        Expr(:macrocall, Expr(:., :Treebars, QuoteNode(Symbol("@phases"))),
             nothing, :(begin end)))

    # (e) Anchoring on a trailing `Treebars` is deliberate: another package's
    #     same-named macro (ProgressLogging.jl exports a `@progress`) must NOT
    #     be hijacked when nested inside our block.
    @test !Treebars._is_progress_macrocall(
        Expr(:macrocall, Expr(:., :ProgressLogging, QuoteNode(Symbol("@progress"))),
             nothing, "lbl"))

    # (f) An UNRECOGNISED head still falls through to the standalone path — the
    #     error there must name the marker/import cause, not just the arity.
    stray = quote
        @progress "orphan"
    end
    err = try
        macroexpand(@__MODULE__, stray); nothing
    catch e
        e
    end
    @test err !== nothing
    msg = sprint(showerror, err)
    @test occursin("PHASE MARKER", msg)
    @test occursin("using Treebars: @progress", msg)
end

@testset "@progress nested node argument" begin
    # `@progress node body` in nested position targets that node. Previously
    # only reachable by writing the head qualified (which the walker could not
    # see, so it expanded standalone); now both spellings agree.
    root = initialize_progress!(:state; description="NestedNode")
    side = initialize_progress!(root; description="sidecar")
    @progress root begin
        @progress side begin
            1 + 1
        end
    end
    finalize_progress!(side)
    finalize_progress!(root)
    @test occursin("sidecar", render_text(root))

    # `__progress__` still resolves in the node slot.
    r2 = initialize_progress!(:state; description="NestedAmbient")
    @progress r2 begin
        @progress __progress__ begin
            @progress "inner"
            1 + 1
        end
    end
    finalize_progress!(r2)
    @test occursin("inner", render_text(r2))

    # A backend LITERAL stays rejected — nested, it would root a second,
    # detached tree rather than attach to the block.
    bad = quote
        @progress p begin
            @progress :state begin
                1 + 1
            end
        end
    end
    err = try
        macroexpand(@__MODULE__, bad); nothing
    catch e
        e
    end
    @test err !== nothing
    @test occursin("detached tree", sprint(showerror, err))
end

@testset "@progress recognises an EMITTED GlobalRef head (the DO wrap)" begin
    # Source-level `Treebars.@progress` parses to a dotted Expr, but a macro that
    # EMITS the call writes `GlobalRef(Treebars, Symbol("@progress"))` — a third
    # head shape. DynamicObjects emits exactly this for its property-body wrap at
    # three sites (DynamicObjects.jl:5708/:5725/:5760 @ 9f9c8a5: the @progress-,
    # @PROGRESS- and UNMARKED paths), and since it wraps EVERY unmarked property
    # body the GlobalRef is the dominant emitted head in the ecosystem.
    # Reported by DynamicObjects:sbpmx-reflect — not visible from this side.
    gr_progress = GlobalRef(Treebars, Symbol("@progress"))
    gr_phases = GlobalRef(Treebars, Symbol("@phases"))

    # The exact AST DO emits: `@progress __status__ begin … end`, label-less.
    do_wrap = Expr(:macrocall, gr_progress, LineNumberNode(0, :unknown),
                   :__status__, Expr(:block, :(1 + 1)))
    @test Treebars._is_progress_macrocall(do_wrap)
    @test Treebars._is_phases_macrocall(
        Expr(:macrocall, gr_phases, LineNumberNode(0, :unknown), Expr(:block, :(x = 1))))

    # A GlobalRef into ANOTHER module is not ours, even with the same macro name.
    @test !Treebars._is_progress_macrocall(
        Expr(:macrocall, GlobalRef(Base, Symbol("@progress")), nothing, "lbl"))

    # Now the behavioural half. A GlobalRef-headed wrap NESTED inside a @progress
    # block is what the walker newly sees. It must attach to the node the wrap
    # names (`__status__`) — not error, and not detach to BACKEND[]. This is why
    # the nested node-argument arm has to exist: before it, the walker seeing this
    # head would have raised "nested form does not accept a backend argument" on
    # every DO property nested inside a progress block.
    # Evaluated at module scope, because DO's wrap names the node with the literal
    # SYMBOL `__status__` and that has to resolve the way it does in a real
    # property body — not as a testset-local.
    nested = Expr(:macrocall, gr_progress, LineNumberNode(0, :unknown),
                  :__status__,
                  Expr(:block,
                       Expr(:macrocall, gr_progress, LineNumberNode(0, :unknown), "inner"),
                       :(1 + 1)))
    txt = @eval begin
        _gr_root = initialize_progress!(:state; description="GlobalRefRoot")
        __status__ = initialize_progress!(_gr_root; description="PropertyNode")
        @progress _gr_root begin
            $nested
        end
        finalize_progress!(__status__)
        finalize_progress!(_gr_root)
        render_text(_gr_root)
    end
    @test occursin("PropertyNode", txt)
    @test occursin("inner", txt)

    # And the reporter's other concern: DO's wrap is emitted LABEL-LESS and bare so
    # the renderer inlines it away and it adds no row. A label-less wrap the walker
    # now sees must still not grow one.
    bare = Expr(:macrocall, gr_progress, LineNumberNode(0, :unknown),
                :__progress__, Expr(:block, :(1 + 1)))
    txt2 = @eval begin
        _bw_root = initialize_progress!(:state; description="BareWrapRoot")
        @progress _bw_root begin
            $bare
        end
        finalize_progress!(_bw_root)
        render_text(_bw_root)
    end
    # One line only: the root. The label-less wrap contributed no row.
    @test length(split(strip(txt2), '\n')) == 1
end
