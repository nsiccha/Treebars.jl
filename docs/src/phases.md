# Phases

Declare work before it starts and distinguish a completed computation from a
cache hit, a bypass or a failure. Prepared phases begin pending; wrappers
start the phases that are reached and close them on every exit path.

## Static plans

Inside a `@progress` block, a standalone `@progress "label"` marks a phase.
The tree printed inside the first phase already contains the later phase.

```@example phases
using Treebars
tree = with_progress(:state; description="Pipeline") do root
    @progress root begin
        @progress "Prepare"
        println(render_text(root))
        values = [1, 2, 3]
        @progress "Compute"
        update_progress!(__progress__, "sum = $(sum(values))")
    end
    root
end
println(render_text(tree))
```

Labels are evaluated when the plan is created, so they can use only variables
already in scope. Use the macro marker, not a bare string: Julia can treat a
bare string as a docstring instead of a phase. The active `__progress__`
changes to the phase while its body runs.

## Runtime plans

`with_prepared_phases` takes labels known at runtime. A named tuple supplies
stable keys; each string value supplies its display label. Use
`with_prepared_progress` to enter an individual phase.

This run uses an existing preparation and omits an optional report. The
output distinguishes reused preparation from skipped reporting.

```@example phases
tree = with_progress(:state; description="Cached run") do root
    with_prepared_phases(root, (prepare="Prepare", compute="Compute", report="Report")) do phases
        reuse_progress!(phases.prepare)
        with_prepared_progress(phases.compute) do phase
            update_progress!(phase, "result = $(sum(1:5))")
        end
    end
    root
end
println(render_text(tree))
```

An unentered phase becomes skipped when the plan exits. A reused phase is a
separate terminal state; `is_reused` is true and `is_finished` is false. Reuse
before entry has no duration. Reuse after entry keeps the time spent checking
for the result. Treebars does not provide a result cache: the application
owns cache keys, validity and storage.

## Failures

The wrapper marks the phase that threw as failed and rethrows. A later phase
that was never entered is skipped.

```@example phases
saved = Ref{Any}(nothing)
try
    with_progress(:state; description="Failed run") do root
        saved[] = root
        with_prepared_phases(root, (read="Read", analyze="Analyze")) do phases
            with_prepared_progress(phases.read) do _
                error("Missing input")
            end
        end
    end
catch err
    println(sprint(showerror, err))
end
@assert is_failed(saved[])
println(render_text(saved[]))
```

## Interrupts

An interrupt is a request, not forced cancellation. Work must check it at a
point where it can stop. `throw_if_interrupted` raises `ProgressInterrupted`,
which the surrounding wrapper records as a failure. A request on a parent
also applies to its descendants.

```@example phases
saved = Ref{Any}(nothing)
try
    with_progress(:state; description="Interruptible work") do p
        saved[] = p
        request_interrupt!(p)
        println("Request visible: ", interrupt_requested(p))
        throw_if_interrupted(p)
    end
catch err
    @assert err isa ProgressInterrupted
    println(typeof(err))
end
println(render_text(saved[]))
```

## Retained counts

[`phase_overview`](@ref) aggregates repeated plans, including phases whose
transient nodes have left the tree. It reports pending, running, finished,
failed, reused and skipped counts. Plans match by declared keys or labels,
not by arbitrary node descriptions. It counts plans already instantiated,
not future items that have not entered a plan.

[Batch processing](batch.md) uses these counts to account for every sample.
