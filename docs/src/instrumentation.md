# Instrumentation

Attach a loop, nested function or per-item computation to the progress node
that owns it. Use a wrapper to close the node on success and mark it failed
on exceptions; call `update_progress!` inside the wrapper to report work.

## Loops

`@progress` advances a counter after each iteration. Passing `root` attaches
that counter to the tree retained by the caller.

```@example instrumentation
using Treebars
squares, tree = with_progress(:state; description="Analysis") do root
    values = @progress root "Squares" [x^2 for x in 1:4]
    values, root
end
println(squares)
println(render_text(tree))
```

A bare `@progress` uses `Treebars.BACKEND[]`, which defaults to `nothing`.
Pass the parent explicitly in library code. Within an enclosing `@progress`
block, nested markers and counters use the active node automatically.
Bare `for` loops inside that block are instrumented too; a nested counter is
transient and leaves the tree when it finishes. Failed children remain visible.

## Nested functions

A function can accept a `progress` keyword without requiring callers to
choose a display. The same call produces the same numerical result when
progress is disabled.

```@example instrumentation
function squared_sum(values; progress=nothing)
    with_progress(progress, length(values); description="Squared sum") do p
        total = 0
        for (i, x) in enumerate(values)
            total += x^2
            update_progress!(p, i)
        end
        total
    end
end
observed, tree = with_progress(:state; description="Caller") do p
    squared_sum(1:4; progress=p), p
end
plain = squared_sum(1:4)
@assert observed == plain
println("Observed = ", observed, "; disabled = ", plain)
println(render_text(tree))
```

`nothing` disables the progress operations, not the computation or its return
value. Inside a macro body, `__progress__` denotes its active node. Outside
that body it is an ordinary undefined variable; use the callback argument.

## Per-item work

Use `progress_map` when each item needs its own children or message. Its
callback receives the child before the item. The map counter advances as
each item finishes.

```@example instrumentation
results, tree = with_progress(:state; description="Groups") do root
    results = progress_map(root, [[1, 2], [3, 4]]; description="Group sums") do child, values
        update_progress!(child, string(values))
        squared_sum(values; progress=child)
    end
    results, root
end
println(results)
println(render_text(tree))
```

## Terminal display

Load Term to enable `:term`; selecting that backend without the extension
raises an argument error. The live terminal renderer requires a terminal
that supports its display controls. The build executes this call and checks
the result; its captured output is not a recording of a terminal session.

```@example instrumentation
using Term
result = with_progress(:term, 3; description="Terminal counter") do p
    for i in 1:3
        update_progress!(p, i)
    end
    :complete
end
println(result)
```

Use [batch processing](batch.md) for per-item work with a declared phase plan.
