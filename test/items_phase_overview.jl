using TestItemRunner

@testitem "Prepared phase overview distinguishes all five states" tags=[:unit, :phase_overview] begin
    using Treebars
    let
        root = initialize_progress!(:state; description="Batch")
        ready = Channel{Nothing}(5)
        release = Channel{Nothing}(5)
        tasks = map(1:5) do i
            @async with_progress(root; description="Item $i") do item
                with_prepared_phases(item, (load="Load", fit="Fit")) do phases
                    if i == 2
                        start_progress!(phases.load)
                    elseif i == 3
                        start_progress!(phases.load)
                        finalize_progress!(phases.load)
                    elseif i == 4
                        start_progress!(phases.load)
                        fail_progress!(phases.load)
                    elseif i == 5
                        skip_progress!(phases.load)
                    end
                    put!(ready, nothing)
                    take!(release)
                end
            end
        end
        for _ in tasks
            take!(ready)
        end
        snapshot = only(phase_overview(root))
        @test snapshot.items == 5
        @test snapshot.phases[1] == (; key=:load, label="Load",
            pending=1, running=1, finished=1, failed=1, skipped=1)
        @test snapshot.phases[2].pending == 5
        @test snapshot.phases[2].running == 0
        # A second reachable edge and a repeated board root count the same
        # actual trees once. Snapshotting does not change lifecycle or children.
        other = initialize_progress!(:state; description="Other view")
        for child in root.children
            add_child!(other, child)
        end
        @test phase_overview([root, other, root]) == (snapshot,)
        @test phase_overview(root) == (snapshot,)
        for _ in tasks
            put!(release, nothing)
        end
        foreach(wait, tasks)
        final = only(phase_overview(root))
        @test final.phases[1].finished == 2
        @test final.phases[1].failed == 1
        @test final.phases[1].skipped == 2
        @test final.phases[2].skipped == 5
        @test snapshot.phases[2].pending == 5 # an earlier snapshot stays frozen
    end
end

@testitem "Macro phase overview keeps completed transient counts" tags=[:unit, :phase_overview, :macro] begin
    using Treebars
    let
        root = initialize_progress!(:state; description="Batch")
        snapshots = Any[]
        @progress root "Items" for i in 1:3
            @progress "Load $i"
            push!(snapshots, only(phase_overview(root)))
            @progress "Fit"
            push!(snapshots, only(phase_overview(root)))
        end
        final = only(phase_overview(root))
        @test final.items == 3
        @test final.phases[1].label == "Phase 1"
        @test final.phases[2].label == "Fit"
        @test all(p -> p.finished == 3 && p.running == 0 && p.pending == 0, final.phases)
        @test isempty(only(root.children).children)
        @test snapshots[1].phases[1].running == 1
        @test snapshots[1].phases[2].pending == 1
        @test snapshots[4].phases[1].finished == 2
        @test snapshots[4].phases[2].running == 1
        @test snapshots[4].phases[2].finished == 1
    end
end

@testitem "Phase plans stay separate and labels remain eager" tags=[:unit, :phase_overview, :macro] begin
    using Treebars
    let
        root = initialize_progress!(:state; description="Batch")
        evaluations = Ref(0)
        label() = (evaluations[] += 1; "Phase")
        @test (@progress root begin
            @progress "$(label())"
            42
        end) == 42
        @test evaluations[] == 1
        @progress root begin
            @progress "Phase"
            nothing
        end
        @test length(phase_overview(root)) == 2
        # Ordinary nodes with matching descriptions are not declared phases.
        with_progress(root; description="Phase") do _
            nothing
        end
        @test length(phase_overview(root)) == 2
        with_prepared_phases(root, (first="Same", second="Same")) do phases
            @with_progress phases.first nothing
        end
        named = last(phase_overview(root))
        @test named.phases[1].finished == 1
        @test named.phases[2].skipped == 1
        @test named.phases[1].key != named.phases[2].key
        @test phase_overview(nothing) == ()
        @test with_prepared_phases(nothing, (first="A", second="B")) do phases
            all(isnothing, phases)
        end
    end
end

@testitem "Threaded macro phase counts conserve every item" tags=[:unit, :phase_overview, :concurrency] begin
    using Treebars
    let
        root = initialize_progress!(:state; description="Batch")
        @progress root Threads.@threads for i in 1:64
            @progress "Load"
            yield()
            @progress "Fit"
            yield()
        end
        result = only(phase_overview(root))
        @test result.items == 64
        @test all(p -> p.finished == 64 && p.pending == 0 && p.running == 0 &&
            p.failed == 0 && p.skipped == 0, result.phases)
    end
end
