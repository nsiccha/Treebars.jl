# Treebars.jl

Tree-structured, nested progress bars for Julia.

Treebars provides a backend-agnostic progress interface built around a tree of
[`ProgressNode`](@ref)s. Each node wraps a backend-specific implementation
([`StateProgress`](@ref) for web/remote, Term.jl for terminal) and maintains
parent–child relationships for hierarchical progress tracking.

## Features

- **Tree-structured progress** — nested progress nodes with parent/child
  relationships, automatic propagation, and per-node lifecycle state
  ([`is_pending`](@ref), [`is_running`](@ref), [`is_finished`](@ref),
  [`is_failed`](@ref), [`duration`](@ref)).
- **Backend-agnostic** — interface dispatches to a `:state` backend (text /
  HTML / WebSocket) or `:term` backend (Term.jl terminal rendering). A `nothing`
  backend disables progress (all operations no-op), making instrumentation
  optional.
- **Convenience entry points** — prefer [`@progress`](@ref),
  [`with_progress`](@ref), and [`with_prepared_phases`](@ref) /
  [`@with_progress`](@ref) over manual `initialize_progress!` / `finalize_progress!`
  — they handle error propagation and finalisation automatically.
- **Phase markers in `begin` blocks** — `@progress "label"` as a statement
  inside `@progress … begin … end` pre-enumerates the whole pipeline as
  *pending* siblings so the entire structure is visible from the start.
- **Web-ready rendering** — when `HTMXObjects` is loaded, [`htmx_render`](@ref)
  renders `StateProgress` trees as HTML with toggle pills, and
  [`polling_fetchindex`](@ref) wraps the entire fetchindex + HTMX polling +
  cancel pattern into a single call.
- **WebSocket streaming** — when `HTTP` is loaded, [`ws_progress`](@ref) pushes
  rendered progress over a WebSocket until the node finalises.
- **Thread-safe** — children and labels are guarded by `ReentrantLock`-backed
  wrappers (`ThreadsafeSet` / `ThreadsafeDict`) so concurrent multi-thread
  progress reporting + polling is safe.

## Quick start — terminal

```julia
using Treebars, Term

Treebars.BACKEND[] = :term
@progress for i in 1:100
    sleep(0.01)
end
```

## Quick start — labelled phases

```julia
@progress :state "Pipeline" begin
    @progress "Load data"
    x = load()                        # runs under "Load data"

    @progress "Preprocess"
    for _ in 1:5; preproc(); end      # runs under "Preprocess"

    @progress "Fit"
    for i in 1:N; step(i); end        # auto counter-child of "Fit"
end
```

All four labelled phases are pre-enumerated as pending children at the start
of the block; each transitions pending → running → done as execution reaches it.

## Quick start — data-driven phases

When the phase set is only known at runtime, use
[`with_prepared_phases`](@ref) + [`with_prepared_progress`](@ref):

```julia
chain = (parse=:parse, transform=:transform, fit=:fit)

vals = with_prepared_phases(progress, chain) do phases
    map(chain, phases) do spec, phase
        with_prepared_progress(phase) do _
            run(spec)
        end
    end
end
```

## Quick start — web polling

With `HTMXObjects` loaded:

```julia
using Treebars, HTMXObjects

@dynamicstruct struct MyApp
    __status__ = initialize_progress!(:state; description="MyApp")
    results(key) = with_progress(__status__, 1000; description="Sampling") do p
        for i in 1:1000; do_work(i); update_progress!(p, i); end
    end
end

# In a route:
polling_fetchindex(app.results, key;
    poll_url=query_url("/results/$key"),
    label="Computation ($key)",
) do rv
    render_my_result(rv)
end
```

See [Usage](usage.md) for more patterns and [Backends](backends.md) for
backend internals.
