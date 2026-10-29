using TestItemRunner

# Snapshot files (`snapshot_progress`, todo 17aqs53): another process follows a
# running tree by reading one file that is replaced whole, never appended to.

@testitem "snapshot_progress keeps the live tree in a file, then marks it final" setup=[TreebarsTestImports] tags=[:unit, :snapshot] begin
    let
    dir = mktempdir()
    path = joinpath(dir, "fit.progress")
    root = initialize_progress!(:state; description="Sampling")
    mid = Ref("")
    rv = snapshot_progress(root, path; interval=0.05) do
        @progress root begin
            @progress "Prepare model"
            sleep(0.1)
            @progress "Warmup"
            @progress "draws" for i in 1:5
                sleep(0.05)
                i == 3 && (mid[] = read(path, String))
            end
        end
        :result
    end
    @test rv === :result

    # While the run goes on: the header, then the tree as render_text shows it.
    lines = split(mid[], '\n')
    @test startswith(lines[1], "treebars snapshot · live · pid $(getpid()) on $(gethostname()) · written ")
    @test endswith(lines[1], " · every 0.05s")
    @test occursin(r"written \d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ \(unix \d+\)", lines[1])
    @test startswith(lines[2], "▶ Sampling")
    @test occursin("✓ Prepare model", mid[])
    @test occursin(r"▶ draws \(\d/5\)", mid[])

    # Closed: marked final, no interval, and the tree is the current one.
    final = read(path, String)
    header, body = split(final, '\n'; limit=2)
    @test startswith(header, "treebars snapshot · final · ")
    @test !occursin("every", header)
    @test occursin("✓ draws (5/5)", body)
    strip_durations(s) = replace(s, r" \[[^\]]*\]" => "")
    @test strip_durations(chomp(body)) == strip_durations(render_text(root))
    # The temp file was renamed over the snapshot: nothing else is left behind.
    @test readdir(dir) == ["fit.progress"]
    end # let (restores @testset hard scope)
end

@testitem "snapshot_progress: handle form, phase overview, nothing, bad arguments" setup=[TreebarsTestImports] tags=[:unit, :snapshot] begin
    let
    dir = mktempdir()
    path = joinpath(dir, "run.progress")
    root = initialize_progress!(:state; description="Batch")
    s = snapshot_progress(root, path; interval=60, phase_overview=true)
    @test s isa ProgressSnapshot
    @test isopen(s)
    @progress root "Items" for item in 1:2
        @progress "Load"
        @progress "Fit"
    end
    # The opening write happened before any work; with a 60 s interval the
    # next one is the final write.
    @test !occursin("Items", read(path, String))
    close(s)
    @test !isopen(s)
    final = read(path, String)
    @test occursin("Load: 0 pending · 0 running · 2 finished", final)
    @test occursin("✓ Items (2/2)", final)
    close(s)  # idempotent: the final snapshot stays as written
    @test read(path, String) == final
    @test sprint(show, s) == "ProgressSnapshot($(repr(path)), closed)"

    # Progress disabled: no file, the work still runs.
    @test snapshot_progress(nothing, joinpath(dir, "none.progress")) === nothing
    @test snapshot_progress(() -> 7, nothing, joinpath(dir, "none.progress")) == 7
    @test !isfile(joinpath(dir, "none.progress"))

    @test_throws ArgumentError snapshot_progress(root, joinpath(dir, "x.progress"); interval=0)
    # The opening write fails loudly, before any work runs.
    @test_throws Exception snapshot_progress(() -> error("never runs"), root, joinpath(dir, "missing", "x.progress"))
    end # let (restores @testset hard scope)
end

@testitem "a snapshot that cannot be written any more stops; the run carries on" setup=[TreebarsTestImports] tags=[:unit, :snapshot] begin
    let
    dir = mktempdir()
    path = joinpath(dir, "run.progress")
    root = initialize_progress!(:state; description="Long run")
    s = Ref{Any}(nothing)
    # Opened inside `@test_logs`, so the background task logs to it too.
    @test_logs (:error, r"could not write the progress snapshot") match_mode=:any begin
        s[] = snapshot_progress(root, path; interval=0.01)
        rm(dir; recursive=true)
        @progress root "steps" for i in 1:3
            sleep(0.02)
        end
        # Either the background task or this one hits the error first.
        timedwait(() -> !isopen(s[]), 5)
    end
    s = s[]
    @test !isopen(s)
    @test is_finished(only(root.children))
    close(s)  # already stopped: nothing more is written or logged
    @test !isdir(dir)
    end # let (restores @testset hard scope)
end

@testitem "a run that never yields still updates its snapshot; exit marks it final" setup=[TreebarsTestImports] tags=[:unit, :snapshot] begin
    let
    # One thread busy-waiting never runs the background task, so every write
    # here comes from the thread changing the tree. The handle is never closed:
    # Julia's exit closes it.
    path = joinpath(mktempdir(), "busy.progress")
    script = """
    using Treebars
    spin(s) = (t = time(); while time() - t < s; end)
    root = initialize_progress!(:state; description="busy")
    snapshot_progress(root, $(repr(path)); interval=0.05)
    @progress root "steps" for i in 1:10
        spin(0.05)
        i == 6 && println(split(read($(repr(path)), String), '\\n')[3])
    end
    """
    cmd = `$(Base.julia_cmd()) --startup-file=no -t1 --project=$(Base.active_project()) -e $script`
    seen = readchomp(cmd)
    @test occursin(r"▶ steps \([3-6]/10\)", seen)
    final = read(path, String)
    @test startswith(final, "treebars snapshot · final · ")
    @test occursin("✓ steps (10/10)", final)
    end # let (restores @testset hard scope)
end

@testitem "bin/treebars shows a snapshot with its state and age" setup=[TreebarsTestImports] tags=[:unit, :snapshot] begin
    let
    if Sys.iswindows()
        @test_skip "bin/treebars is a POSIX sh script"
    else
        cli = joinpath(pkgdir(Treebars), "bin", "treebars")
        dir = mktempdir()
        path = joinpath(dir, "run.progress")
        cli_show(file) = readchomp(ignorestatus(`$cli show $file`))
        @test cli_show(path) == "no snapshot at $path yet"
        @test !success(`$cli show $path`)

        root = initialize_progress!(:state; description="Run")
        s = snapshot_progress(root, path; interval=30)
        out = cli_show(path)
        @test occursin("▶ Run", out)
        @test occursin(r"\n-- live · written \d+s ago$", out)
        close(s)
        @test occursin(r"\n-- final · written \d+s ago$", cli_show(path))
        # `watch` stops by itself once the snapshot is final.
        @test success(`$cli watch $path`)

        # Live, but not written for far longer than its interval.
        old = floor(Int, time()) - 600
        write(path, "treebars snapshot · live · pid 1 on elsewhere · written then (unix $old) · every 2s\n▶ Run\n")
        @test occursin(r"\n-- stale · last written 10m \ds ago, expected every 2s", cli_show(path))
        write(path, "hello\n")
        @test endswith(cli_show(path), "-- not a treebars snapshot: its first line is \"hello\"")
        @test !success(`$cli`)
    end
    end # let (restores @testset hard scope)
end
