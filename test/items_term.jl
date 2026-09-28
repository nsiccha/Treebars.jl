using TestItemRunner

# Term-backend lifecycle regression tests (snag with-progress-te-b4c1f9b9).
# Area tag: :term. These items need only Treebars + Term, so they use a local
# snippet instead of TreebarsTestImports (which drags the DO/HTMX/HTTP stack).

@testsnippet TermTestImports begin
    using Test, Treebars, Term
    using Treebars: isrunning
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
