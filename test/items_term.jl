using TestItemRunner

# Term-backend lifecycle regression tests (snag with-progress-te-b4c1f9b9).
# Area tag: :term. These items need only Treebars + Term, so they use a local
# snippet instead of TreebarsTestImports (which drags the DO/HTMX/HTTP stack).

@testsnippet TermTestImports begin
    using Dates: Millisecond
    using Test, Treebars, Term
    using Treebars: isrunning, is_pending, is_running, is_finished, is_failed,
        is_skipped, duration, eta, render_text
end

@testitem "term backend finalizes without child->parent->child recursion" setup=[TermTestImports] tags=[:unit, :term] begin
    let
        # Terminal state is observable: a stopped job / bar reads not-running.
        # (Pre-fix both read `true` forever via the `isrunning(::ProgressNode)`
        # fallback — the lie that drove the unbounded recursion.)
        root = initialize_progress!(:term)
        child = initialize_progress!(root, 3; description="term-facts")
        @test isrunning(child)
        @test isrunning(root)
        finalize_progress!(child.impl)
        @test child.impl.finished
        @test !isrunning(child)
        @test isrunning(root)
        finalize_progress!(root.impl)
        @test !root.impl.running
        @test !isrunning(root)

        # Failing marks Term impls terminal too (pre-fix: the generic
        # `fail_progress!` fallback only logged, so the fail walk recursed
        # the same way).
        froot = initialize_progress!(:term)
        fchild = initialize_progress!(froot, 2; description="term-fail-facts")
        fail_progress!(fchild.impl, ErrorException("boom"))
        @test fchild.impl.finished
        @test !isrunning(fchild)
        fail_progress!(froot.impl, ErrorException("boom"))
        @test !froot.impl.running
        @test !isrunning(froot)

        # End-to-end success path: the block runs, the bar stops, the call
        # returns. Bounded: pre-fix this recurses forever, so an unbounded
        # call would hang the suite instead of failing it.
        ran = Ref(false)
        t = @async redirect_stdout(devnull) do
            with_progress(:term, 3; description="term-e2e") do p
                for i in 1:3
                    update_progress!(p, i)
                end
            end
            ran[] = true
        end
        completed = timedwait(() -> istaskdone(t), 60) === :ok
        @test completed
        if completed
            fetch(t)  # rethrow any task exception into the test
            @test ran[]
        end

        # End-to-end fail path: the block error propagates (not a hang) and
        # the bar stops.
        caught = Ref{Any}(nothing)
        e2ebar = Ref{Any}(nothing)
        t2 = @async redirect_stdout(devnull) do
            try
                with_progress(:term, 2; description="term-e2e-fail") do p
                    e2ebar[] = p.parent
                    error("boom")
                end
            catch e
                caught[] = e
            end
        end
        completed2 = timedwait(() -> istaskdone(t2), 60) === :ok
        @test completed2
        if completed2
            fetch(t2)
            @test caught[] isa ErrorException
            @test !e2ebar[].impl.running
        end
    end
end

@testitem "term backend query parity and text dump" setup=[TermTestImports] tags=[:unit, :term] begin
    let
        # A running counter job answers every lifecycle query (pre-fix
        # `is_running`/`is_finished`/`is_failed`/`duration` threw MethodError).
        root = initialize_progress!(:term)
        @test is_pending(root) == false
        @test is_running(root) == true
        @test is_finished(root) == false
        @test is_failed(root) == false
        @test is_skipped(root) == false
        @test eta(root) === nothing
        @test_throws ErrorException duration(root)

        job = initialize_progress!(root, 4; description="term-query")
        update_progress!(job, 1)
        @test is_pending(job) == false
        @test is_running(job) == true
        @test is_finished(job) == false
        @test is_failed(job) == false
        @test is_skipped(job) == false
        @test eta(job) === nothing
        @test duration(job) isa Millisecond
        @test duration(job) >= Millisecond(0)

        # A label job (no counter) has the same query shape.
        lab = initialize_progress!(root; description="term-label", value="v")
        @test is_running(lab) == true
        @test is_finished(lab) == false
        @test duration(lab) isa Millisecond

        # A running tree dumps as text instead of throwing: markers plus the
        # jobs' descriptions, counters and durations; the description-less
        # root bar keeps its impl type name.
        txt = render_text(root)
        @test occursin("▶", txt)
        @test occursin("term-query", txt)
        @test occursin("term-label", txt)
        @test occursin("(1/4)", txt)
        @test occursin("ProgressBar", txt)

        # Terminal states: finished reads finished, and the job duration is
        # frozen (two reads agree exactly).
        finalize_progress!(job.impl)
        @test is_running(job) == false
        @test is_finished(job) == true
        d1 = duration(job)
        sleep(0.05)
        @test duration(job) == d1

        # Term.jl records no failure, so a failed job reads finished — the
        # documented contract (check for the propagated exception instead).
        froot = initialize_progress!(:term)
        fjob = initialize_progress!(froot, 2; description="term-query-fail")
        fail_progress!(fjob.impl, ErrorException("boom"))
        @test is_running(fjob) == false
        @test is_failed(fjob) == false
        @test is_finished(fjob) == true

        # A finished tree dumps with finished markers.
        finalize_progress!(lab.impl)
        finalize_progress!(root.impl)
        @test is_running(root) == false
        @test is_finished(root) == true
        ftxt = render_text(root)
        @test occursin("✓", ftxt)
        @test !occursin("▶", ftxt)
        fail_progress!(froot.impl, ErrorException("boom"))
    end
end
