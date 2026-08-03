# Usage

!!! tip "Always use a convenience entry point"
    Do **not** call [`initialize_progress!`](@ref) / [`prepare_progress!`](@ref) /
    [`update_progress!`](@ref) / [`finalize_progress!`](@ref) manually in
    application code — forgetting `finalize_progress!` or missing an exception
    leaves nodes stuck in *running* or *pending* state forever.

    The convenience API — [`@progress`](@ref), [`with_progress`](@ref),
    [`with_prepared_phases`](@ref) / [`@with_progress`](@ref) /
    [`with_prepared_progress`](@ref) — handles initialisation, error
    propagation, and finalisation automatically. The bare lifecycle functions
    are public only to enable custom backends.

## The `@progress` macro

The simplest way to add progress tracking to `for` loops:

```julia
using Treebars, Term

Treebars.BACKEND[] = :term

# Single loop
@progress for i in 1:100
    sleep(0.01)
end

# Nested loops (inner loops get transient progress bars)
@progress for i in 1:5
    for j in 1:20
        sleep(0.01)
    end
end
```

You can also pass a backend symbol or an existing `ProgressNode` directly:

```julia
@progress :term for i in 1:100; sleep(0.01); end

p = initialize_progress!(:term)
@progress p for i in 1:100; sleep(0.01); end
```

### Labelled single-statement wrap

```julia
@progress :term "Compile" compile_model()   # indeterminate spinner child
```

### Phase markers inside `begin` blocks

`@progress "label"` as a direct statement inside a `@progress … begin … end`
opens a phase that runs from the marker to the next marker (or end of block).
All labelled phases are pre-enumerated as **pending** children, so the whole
pipeline is visible from the outset:

```julia
@progress :state "Pipeline" begin
    @progress "Load data"
    x = load()                      # runs under "Load data"

    @progress "Preprocess"
    for _ in 1:5; preproc(); end    # runs under "Preprocess"

    @progress "Fit"
    for i in 1:N; step(i); end      # for-loop becomes a counter-child of "Fit"

    @progress "Evaluate"
    evaluate(x)                     # x from "Load data" is visible here
end
```

Inside a phase body, the local `__progress__` refers to the current phase's
node — useful for nesting substatus from called functions under the active
phase (e.g. `fetchindex!(__progress__, ip; …)`).

All phase bodies share one scope, so assignments flow across phase boundaries.
On error, the phase that was running is failed before the exception rethrows.
Phases that were never entered become skipped, so they are not blamed for an
error they never saw and do not remain pending forever.

## `with_progress` — non-loop work

For non-loop work with automatic finalise + fail handling, use the do-block
form [`with_progress`](@ref):

```julia
with_progress(:term, 10; description="MCMC") do p
    for i in 1:10
        update_progress!(p, i)
        sleep(0.1)
    end
end
```

## Data-driven phases

When the phase set is only known at runtime (so the static
`@progress "label" begin … end` form doesn't fit), use
[`with_prepared_phases`](@ref) together with [`@with_progress`](@ref) or
[`with_prepared_progress`](@ref). The pattern: bulk-prepare pending phase
nodes up front so the whole pipeline appears immediately, then run each phase
one by one as it transitions pending → running → finished.

```julia
# Keys carry structure; values carry specs / metadata.
chain = (parse=:parse, transform=:transform, fit=:fit)

vals = with_prepared_phases(progress, chain) do phases
    # phases is a NamedTuple with the same keys, ProgressNode values.
    # All three are pending siblings of `progress` right now.
    map(chain, phases) do spec, phase
        with_prepared_progress(phase) do _
            run(spec)                # phase transitions pending → running → finished
        end
    end
end
```

`with_prepared_phases` accepts:

- any iterable (`Vector{String}`, `Tuple`, generator) — `phases` is the same
  shape, elements stringified as descriptions;
- a `NamedTuple` — `phases` is a `NamedTuple` with the same keys. The
  per-phase description is taken from the NT value when it is an
  `AbstractString`, otherwise from `string(key)`.

If anything throws inside the `f(phases)` body, the phase that is
`is_running` is failed via `fail_progress!(p, err)` before the exception
rethrows. Any phase that is still `is_pending` is terminated as skipped. The
same cleanup applies to an early return from the body.

## Labelled sub-progress via `update_progress!` kwargs

Pass keyword arguments to `update_progress!` to create labelled sub-rows:

```julia
with_progress(:term, 100; description="MCMC") do p
    for i in 1:100
        update_progress!(p, i;
            divergent = "$i out of 100",
            ess = "pending...",
            stepsize = "0.1",
        )
        sleep(0.05)
    end
end
```

Each keyword creates a child label row (e.g. `divergent: 5 out of 100`).
Underscores in keyword names are replaced with spaces. Labels are reused on
subsequent calls — the child node is created the first time and updated
thereafter.

## Update patterns

```julia
update_progress!(p, i)              # Set counter to i
update_progress!(p)                 # Increment by 1
update_progress!(p, i; key=val)     # Counter + labels
update_progress!(p, nothing; k=v)   # Labels only (no counter change)
update_progress!(p, "message")      # String message
```

## Formatting utilities

Treebars includes generic display helpers for progress labels:

```julia
round2(3.14159)          # 3.1
round2(0.00123)          # 0.0012
short_string(1_500_000)  # "1.5M"
short_string(42)         # "42"
short_string([1, 2, 3])  # "[1, 2, 3]"
short_string(:a => 1)    # "a => 1"

Fraction(0.95) |> short_string  # "95%"
short_duration(Dates.Second(83))  # "1m 23s"
```

These are useful for formatting metadata in `update_progress!` kwargs:

```julia
update_progress!(p, i;
    stepsize = short_string(ε),
    acceptance = short_string(Fraction(acc_rate)),
)
```

Domain-specific `short_string` methods (e.g. for custom matrix types) can be
added in the consuming package.

## Disabled progress

Passing `nothing` as the progress backend is a no-op — all functions silently
return `nothing`. This makes it easy to optionally enable progress:

```julia
function my_computation(; progress=nothing)
    with_progress(progress, 100; description="Computing") do p
        for i in 1:100
            update_progress!(p, i)
            # ...
        end
    end
end

my_computation()                  # silent
my_computation(progress=:term)    # terminal bars
my_computation(progress=:state)   # web-ready tree
```
