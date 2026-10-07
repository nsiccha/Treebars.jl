using TestItemRunner

@testitem "Prepared phase overview distinguishes all six states" tags=[:unit, :phase_overview] begin
    using Treebars
    let
        root = initialize_progress!(:state; description="Batch")
        ready = Channel{Nothing}(6)
        release = Channel{Nothing}(6)
        tasks = map(1:6) do i
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
                    elseif i == 6
                        reuse_progress!(phases.load)
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
        @test snapshot.items == 6
        @test snapshot.phases[1] == (; key=:load, label="Load",
            pending=1, running=1, finished=1, failed=1, skipped=1, reused=1)
        @test snapshot.phases[2].pending == 6
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
        @test final.phases[1].reused == 1   # never folded into finished
        @test final.phases[2].skipped == 6
        @test snapshot.phases[2].pending == 6 # an earlier snapshot stays frozen
    end
end

@testitem "Phase overview rendering is opt-in and keeps ordinary trees" tags=[:unit, :phase_overview, :render] begin
    using Treebars, HTMXObjects
    let
        root = initialize_progress!(:state; description="Batch")
        with_prepared_phases(root, (load="Load <public> & all labels", fit="Fit", cache="Cache")) do phases
            @with_progress phases.load nothing
            reuse_progress!(phases.cache)
        end
        html(x) = sprint(show, MIME"text/html"(), x)
        @test !occursin("treebar-phase-overview", html(htmx_render(root)))
        @test !occursin("Phase plan", render_text(root))
        view = html(htmx_render(root; phase_overview=true))
        @test occursin("1 prepared items", view)
        @test occursin("Load &lt;public&gt; &amp; all labels", view)
        @test occursin("data-phase-state=\"finished\">1</td>", view)
        @test occursin("data-phase-state=\"skipped\">1</td>", view)
        @test occursin("data-phase-state=\"reused\">1</td>", view)
        @test occursin("<th scope=\"col\">Reused</th>", view)
        @test occursin("treebar-children", view)
        @test occursin("treebar-pill-finished", view)
        @test length(findall("treebar-phase-overview", view)) == 1
        @test occursin("treebar-phase-overview", html(htmx_render_children(root; phase_overview=true)))
        @test occursin("treebar-phase-overview", htmx_ws_render(root; phase_overview=true))
        @test occursin("treebar-phase-overview", html(htmx_ws_progress("Content";
            progress=root, url="/public", id="probe", phase_overview=true)))
        text = render_text(root; phase_overview=true)
        @test occursin("1 finished", text) && occursin("1 skipped", text)
        @test occursin("0 finished · 1 reused · 0 failed · 0 skipped", text)   # the Cache row
        @test occursin("↺ Cache", text)
        @test occursin("✓ Load <public> & all labels", text)
        @test render_text(nothing; phase_overview=true) == "(no progress tree)"
        entry = (; key="one", label="Item", state=:done, node=root)
        board = html(htmx_render_board([entry, entry]; phase_overview=true))
        @test occursin("1 prepared items", board)
        @test length(findall("treebar-phase-overview", board)) == 1
        @test occursin("treebar-board-tree", board)
        @test !occursin("treebar-phase-overview", html(htmx_render_board([entry])))
    end
end

@testmodule PhaseOverviewPollingFixtures begin
    using Treebars, DynamicObjects
    export PhaseOverviewPoll, _PHASE_READY, _PHASE_RELEASE
    const _PHASE_READY = Ref(Channel{Nothing}(1))
    const _PHASE_RELEASE = Ref(Channel{Nothing}(1))
    @dynamicstruct struct PhaseOverviewPoll
        __status__ = initialize_progress!(:state; description="Synthetic batch")
        "Synthetic item"
        @progress result(key) = begin
            @progress "Load"
            put!(_PHASE_READY[], nothing)
            take!(_PHASE_RELEASE[])
            key === :fail && error("Synthetic failure")
            @progress "Fit"
            "Done"
        end
    end
end

@testitem "Board phase overview updates without resetting inspection" tags=[:unit, :phase_overview, :board] begin
    using Treebars, HTMXObjects
    let
        if get(ENV, "TREEBARS_BROWSER_TESTS", "") != "1"
            @test_skip true
        else
            chrome = Sys.which("google-chrome")
            isnothing(chrome) && (chrome = Sys.which("chromium"))
            isnothing(chrome) && error("TREEBARS_BROWSER_TESTS=1 requires Chrome")
            root = initialize_progress!(:state; description="Synthetic item")
            html(x) = sprint(show, MIME"text/html"(), x)
            entry = (; key="one", label="Item one", state=:running, node=root)
            board(; enabled=true) = htmx_render_board([entry]; id="overview-board", phase_overview=enabled)
            initial = html(board()) # no instantiated phase plan yet
            snapshots = String[]
            with_prepared_phases(root, (load="Load", fit="Fit")) do phases
                start_progress!(phases.load)
                push!(snapshots, html(board()))
                finalize_progress!(phases.load)
                skip_progress!(phases.fit)
                push!(snapshots, html(board()))
            end
            push!(snapshots, html(board(; enabled=false)))
            literal(s) = "'" * replace(s, "\\"=>"\\\\", "'"=>"\\'", "\n"=>"\\n", "</"=>"<\\/") * "'"
            driver = """
            window.addEventListener('load', function(){
                var S = [$(join(literal.(snapshots), ","))];
                var item = document.querySelector('.treebar-board-item');
                item._owned = true;
                item.querySelector('details').open = true;
                item.dataset.open = '1';
                treebarUpdateBoard(S[0]);
                var overview = document.querySelector('.treebar-board-overview');
                var live = overview.querySelector('td[data-phase-state="running"]').textContent;
                treebarUpdateBoard(S[1]);
                var done = document.querySelector('.treebar-board-overview td[data-phase-state="finished"]').textContent;
                var same = document.querySelector('.treebar-board-item') === item;
                var open = item.querySelector('details').open;
                treebarUpdateBoard(S[2]);
                var removed = !document.querySelector('.treebar-board-overview');
                var out = document.createElement('pre'); out.id = 'result';
                out.textContent = [live, done, same, open, removed].join('|');
                document.body.appendChild(out);
            });
            """
            dir = mktempdir()
            file = joinpath(dir, "overview.html")
            write(file, "<!DOCTYPE html>" * html(h.html(
                h.head(htmx_treebar_styles(), htmx_treebar_script()),
                h.body(Raw(initial), h.script(Raw(driver))))))
            profile = joinpath(dir, "profile")
            dom = read(pipeline(`$chrome --headless=new --no-sandbox --disable-gpu --disable-dev-shm-usage --virtual-time-budget=2000 --dump-dom --user-data-dir=$profile file://$file`; stderr=devnull), String)
            result = match(r"<pre id=\"result\">([^<]*)</pre>", dom)
            @test result !== nothing
            @test result === nothing ? false : result.captures[1] == "1|1|true|true|true"
        end
    end
end

@testitem "Polling phase overview reaches live success and error trees" setup=[PhaseOverviewPollingFixtures] tags=[:unit, :phase_overview, :polling] begin
    using Treebars, HTMXObjects, DynamicObjects
    let
        app = PhaseOverviewPoll()
        _PHASE_READY[] = Channel{Nothing}(1)
        _PHASE_RELEASE[] = Channel{Nothing}(1)
        html(x) = sprint(show, MIME"text/html"(), x)
        polling_fetchindex(identity, app.result, :public; poll_url="/public", phase_overview=true)
        timedwait(() -> isready(_PHASE_READY[]), 10) === :ok || error("Synthetic compute did not prepare its phases")
        take!(_PHASE_READY[])
        try
            running = html(polling_fetchindex(identity, app.result, :public;
                poll_url="/public", phase_overview=true))
            @test occursin("data-phase-state=\"running\">1</td>", running)
            @test occursin("data-phase-state=\"pending\">1</td>", running)
        finally
            put!(_PHASE_RELEASE[], nothing)
        end
        # Observe compute completion before asking for the retained tree.
        polling_fetchindex(identity, app.result, :public; sync=true)
        done = html(polling_fetchindex(identity, app.result, :public; phase_overview=true))
        @test occursin("treebar-frozen", done)
        @test occursin("data-phase-state=\"finished\">1</td>", done)
        @test occursin("Done", done)
        polling_fetchindex(identity, app.result, :fail; poll_url="/public", phase_overview=true)
        timedwait(() -> isready(_PHASE_READY[]), 10) === :ok || error("Synthetic failing compute did not prepare its phases")
        take!(_PHASE_READY[])
        put!(_PHASE_RELEASE[], nothing)
        @test_throws Exception polling_fetchindex(identity, app.result, :fail; sync=true)
        failed = html(polling_fetchindex(identity, app.result, :fail; phase_overview=true))
        @test occursin("treebar-phase-overview", failed)
        @test occursin("data-phase-state=\"skipped\">1</td>", failed)
        @test occursin("treebar-frozen", failed)
    end
end

@testitem "Streaming phase overview survives the final frame" setup=[StreamingFixtures] tags=[:unit, :phase_overview, :streaming] begin
    using Treebars, HTMXObjects
    frames, outcome = StreamingFixtures.capture_stream() do ws
        ws_progress(ws; id="batch-stream", phase_overview=true, interval=0.001) do publish, node
            @progress node begin
                @progress "Load"
                publish(HTMXObjects.h.span("Public fragment"))
                @progress "Fit"
                nothing
            end
        end
    end
    @test outcome == (:ok, nothing)
    @test occursin("treebar-phase-overview", last(frames))
    @test occursin("data-phase-state=\"finished\">1</td>", last(frames))
    @test occursin("Public fragment", join(frames))
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

@testitem "Transient phase overviews respect subtree scope and input order" tags=[:unit, :phase_overview] begin
    using Treebars
    let
        root = initialize_progress!(:state; description="Batch")
        items = ProgressNode[]
        snapshots = Any[]
        for i in 1:2
            with_progress(root; description="Item $i", transient=true) do item
                push!(items, item)
                with_prepared_phases(item, (load="Load", fit="Fit")) do phases
                    @with_progress phases.load nothing
                    push!(snapshots, only(phase_overview(item)))
                    @test only(phase_overview(root)).items == i
                end
            end
        end
        @test isempty(root.children)
        @test all(s -> s.items == 1 && s.phases[1].finished == 1 &&
            s.phases[2].pending == 1, snapshots)
        total = phase_overview(root)
        @test only(total).items == 2
        @test phase_overview([items..., root]) == total
        @test phase_overview([root, items...]) == total
        @test phase_overview(items) == total
    end
end

@testitem "Prepared phase collection shapes remain compatible" tags=[:unit, :phase_overview] begin
    using Treebars
    let
        labels = ("Load", "Fit")
        @test with_prepared_phases(nothing, labels) do phases
            phases isa Tuple && length(phases) == 2
        end
        @test with_prepared_phases(nothing, collect(labels)) do phases
            phases isa Vector && length(phases) == 2
        end
        @test with_prepared_phases(nothing, (label for label in labels)) do phases
            phases isa Vector && length(phases) == 2
        end
        root = initialize_progress!(:state)
        @test with_prepared_phases(root, reshape(["A", "B", "C", "D"], 2, 2)) do phases
            size(phases) == (2, 2)
        end
        @test all(p -> p.skipped == 1, only(phase_overview(root)).phases)
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
