using TestItemRunner

# The Python snapshot writer (`python/treebars.py`) re-implements the text
# render for processes without Julia. These items keep the two in lockstep: the
# KB's /compute page and `bin/treebars` read whatever either one writes.

@testsnippet PythonWriter begin
    # A Python 3.8+ interpreter, or `nothing` (the items then skip).
    function _treebars_python()
        for name in ("python3", "python")
            exe = Sys.which(name)
            isnothing(exe) && continue
            success(`$exe -c "import sys; sys.exit(sys.version_info < (3, 8))"`) && return exe
        end
        nothing
    end
    PYTHON = _treebars_python()
    PYDIR = joinpath(pkgdir(Treebars), "python")
end

@testitem "Python snapshot writer: its own test suite passes" setup=[TreebarsTestImports, PythonWriter] tags=[:unit, :snapshot, :python] begin
    if isnothing(PYTHON)
        @test_skip "no Python 3.8+ on this machine"
    else
        out = IOBuffer()
        cmd = addenv(`$PYTHON -m unittest discover -s $PYDIR`, "PYTHONIOENCODING" => "utf-8")
        ok = success(pipeline(cmd; stdout=out, stderr=out))
        ok || println(String(take!(out)))
        @test ok
    end
end

@testitem "Python snapshot writer renders exactly like render_text" setup=[TreebarsTestImports, PythonWriter] tags=[:unit, :snapshot, :python] begin
    using JSON
    if isnothing(PYTHON)
        @test_skip "no Python 3.8+ on this machine"
    else
        let
        # (description, N, i, message, started ms, ended ms, failed, reused, children):
        # every lifecycle state, counters, messages, a bare wrapper whose
        # children move up a level, and both tree joints at several depths.
        # No node is running, so the render does not depend on the clock.
        spec = ["Sampling", nothing, 0, "", 0, 3_725_000, false, false, [
            ["Check density", nothing, 0, "agreement passed", 0, 1_480, false, false, []],
            ["Compile", nothing, 0, "", nothing, 2_000, false, true, []],
            ["Warm-up", 4, 4, "", 1_500, 62_250, false, false, [
                ["window", 100, 100, "", 1_500, 1_599, false, false, []],
                ["", nothing, 0, "", 1_600, 62_000, false, false, [
                    ["hoisted", nothing, 0, "from a bare wrapper", 1_600, 1_600, false, false, []],
                ]],
            ]],
            ["Sample", 400, 37, "seed 52", 62_300, 3_700_000, true, false, [
                ["chains", 4, 2, "", 62_300, 90_061_000, true, false, []],
            ]],
            ["Cached draws", nothing, 0, "", 3_700_000, 3_700_010, false, true, []],
            ["Write", nothing, 0, "", nothing, 3_725_000, false, false, []],
            ["Plot", nothing, 0, "", nothing, nothing, false, false, []],
        ]]
        base = DateTime(2026, 11, 15)
        function build(parent, s)
            desc, N, i, msg, start, stop, failed, reused, children = s
            node = isnothing(parent) ? initialize_progress!(:state; description=desc, N) :
                initialize_progress!(parent; description=desc, N)
            sp = node.impl
            sp.i = i
            sp.message = msg
            sp.started_at = isnothing(start) ? nothing : base + Millisecond(start)
            sp.finalized_at = isnothing(stop) ? nothing : base + Millisecond(stop)
            sp.running = !isnothing(start) && isnothing(stop)
            sp.failed = failed
            sp.reused = reused
            foreach(c -> build(node, c), children)
            node
        end
        julia_text = render_text(build(nothing, spec))

        durations = vcat(0:250, 9_900:10_100, 59_900:61_100, [3_599_999, 3_600_000, 3_660_000,
            86_399_999, 86_400_000, 90_000_000, 604_800_000, 1_300_000_000, -5, -500, -60_000])
        dir = mktempdir()
        write(joinpath(dir, "case.json"), JSON.json((; spec, durations)))
        write(joinpath(dir, "render.py"), """
            import json, sys
            sys.path.insert(0, sys.argv[1])
            import treebars as tb
            case = json.load(open(sys.argv[2], encoding="utf-8"))
            def build(tree, parent, s):
                desc, N, i, msg, start, stop, failed, reused, children = s
                node = tb.ProgressNode(tree, parent, desc, N, False, True)
                node._i, node._message = i, msg
                node._started_at, node._finalized_at = start, stop
                node._failed, node._reused = failed, reused
                if parent is not None:
                    parent._children.append(node)
                for c in children:
                    build(tree, node, c)
                return node
            root = build(tb._Tree(), None, case["spec"])
            with open(sys.argv[3], "w", encoding="utf-8", newline="\\n") as f:
                f.write(tb.render_text(root))
            with open(sys.argv[4], "w", encoding="utf-8", newline="\\n") as f:
                f.write("\\n".join(tb.short_duration(ms) for ms in case["durations"]))
            """)
        rendered, shorts = joinpath(dir, "render.txt"), joinpath(dir, "durations.txt")
        run(`$PYTHON $(joinpath(dir, "render.py")) $PYDIR $(joinpath(dir, "case.json")) $rendered $shorts`)
        @test read(rendered, String) == julia_text
        # Every line differs somewhere, so a mismatch names its duration.
        expected = [short_duration(Millisecond(ms)) for ms in durations]
        @test split(read(shorts, String), '\n') == expected
        end # let
    end
end

@testitem "Python snapshot header matches the Julia writer's" setup=[TreebarsTestImports, PythonWriter] tags=[:unit, :snapshot, :python] begin
    if isnothing(PYTHON)
        @test_skip "no Python 3.8+ on this machine"
    else
        let
        dir = mktempdir()
        jpath, ppath = joinpath(dir, "julia.progress"), joinpath(dir, "python.progress")
        root = initialize_progress!(:state; description="run")
        close(snapshot_progress(root, jpath; interval=0.5))
        s = snapshot_progress(root, joinpath(dir, "julia-live.progress"); interval=0.5)
        julia_live = first(readlines(joinpath(dir, "julia-live.progress")))
        close(s)
        script = joinpath(dir, "write.py")
        write(script, """
            import sys
            sys.path.insert(0, sys.argv[1])
            import treebars as tb
            with tb.with_progress("state", description="run") as root:
                s = tb.snapshot_progress(root, sys.argv[2] + ".live", interval=0.5)
                s.close()
                s = tb.snapshot_progress(root, sys.argv[2] + ".live2", interval=0.5)
                live = open(sys.argv[2] + ".live2", encoding="utf-8").readline()
                s.close()
                open(sys.argv[2], "w", encoding="utf-8").write(live)
            """)
        run(`$PYTHON $script $PYDIR $ppath`)
        python_live = chomp(read(ppath, String))
        python_final = first(readlines(ppath * ".live"))
        julia_final = first(readlines(jpath))
        # Same fields in the same order; only the writer's pid and the time differ.
        normalize(h) = replace(h, r"pid \d+" => "pid P",
            r"written \d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ \(unix \d+\)" => "written T")
        @test normalize(python_live) == normalize(julia_live)
        @test normalize(python_final) == normalize(julia_final)
        @test endswith(python_live, " · every 0.5s")
        end # let
    end
end

@testitem "Python writer's version is the package version" setup=[TreebarsTestImports, PythonWriter] tags=[:unit, :snapshot, :python] begin
    # pyproject.toml reads its version from `treebars.__version__`, so a pip
    # install names the Treebars.jl release it renders like.
    m = match(r"^__version__ = \"([^\"]+)\"$"m, read(joinpath(PYDIR, "treebars.py"), String))
    @test !isnothing(m)
    @test VersionNumber(m[1]) == pkgversion(Treebars)
end
