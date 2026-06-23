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
