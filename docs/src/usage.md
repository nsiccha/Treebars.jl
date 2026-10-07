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

### Reused phases

A prepared phase whose result already exists — a cache hit, or output an
earlier run prepared — did no work, yet was not bypassed either. Mark it with
[`reuse_progress!`](@ref), before entering it or from inside its body once the
hit is known:

```julia
with_prepared_phases(progress, (prepare="Prepare model", fit="Fit")) do phases
    cached(:prepare) ? reuse_progress!(phases.prepare) :
        with_prepared_progress(_ -> prepare_model(), phases.prepare)
    with_prepared_progress(phases.fit) do phase
        hit = lookup_fit()
        isnothing(hit) || (reuse_progress!(phase); return hit)
        fit_model()
    end
end
```

A reused phase is terminal and successful: [`is_reused`](@ref) is `true` and
it is neither finished nor skipped. [`render_text`](@ref) marks it `↺`, the
HTML renderer labels it `reused` behind an "N reused" pill, and
[`phase_overview`](@ref) counts it in its own `reused` column. A phase reused
before it was entered shows no duration. Skipped phases are unchanged: they
still mean that control flow never reached the phase and its result does not
exist.

## Batched phase overview

Existing pre-enumerated phase code supports a rendering opt-in. Repeated
instances of each plan are counted by phase and lifecycle state: pending,
running, finished, reused, failed, and skipped. The individual trees remain
available.

```@example batch_overview
using Treebars

batch = initialize_progress!(:state; description="Public synthetic batch")
@progress batch "Items" Threads.@threads for item in 1:3
    @progress "Load"
    values = sqrt.(1:8)
    @progress "Fit"
    sum(values) / length(values)
end
println(render_text(batch; phase_overview=true))
```

The same `phase_overview=true` keyword works with `htmx_render`,
`htmx_render_children`, `polling_fetchindex`, `htmx_ws_render`,
`htmx_ws_progress`, and producer-form `ws_progress`. A board uses
`htmx_render_board(entries; phase_overview=true)`; `htmx_ws_render_board`
and `ws_board` forward it. Defaults retain the ordinary tree view.

[`phase_overview`](@ref) returns an immutable snapshot for inspection: a tuple
of plans, each with `label`, `parent`, `items` and `phases`; each phase has
`key`, `label`, and the six lifecycle counts. Counts include completed
transient phases after their nodes detach. Each phase's six counts sum to that
plan's prepared item count. Items that have not instantiated their phase plan
yet are not counted.

### Nested plans

A plan declared inside a prepared phase of another plan — for example, each
stage's own preparations under a per-model stage plan — is nested under that
phase. No extra declaration is needed: the overview names it after the phase
that declared it and indents it under the enclosing plan.

```@example batch_overview
benchmark = initialize_progress!(:state; description="Public synthetic run")
stages = (compile="Compile", sample="Sample")
for model in ("first", "second")
    with_progress(benchmark; description="Model $model") do model_node
        with_prepared_phases(model_node, stages) do stage_phases
            with_prepared_progress(stage_phases.compile) do stage
                with_prepared_phases(stage, (parse="Parse", build="Build")) do steps
                    foreach(step -> with_prepared_progress(_ -> nothing, step), steps)
                end
            end
            with_prepared_progress(_ -> nothing, stage_phases.sample)
        end
    end
end
println(render_text(benchmark; phase_overview=true))
```

In the HTML views each nested plan is a disclosure under the plan it is nested
in, summarized by the declaring phase's label, with "Expand all" / "Collapse
all" controls above the overview. `phase_overview=true` starts them open;
`phase_overview=:collapsed` starts them closed, so a run whose stages each
declare their own preparations shows one summary line per stage until the
viewer opens it. A viewer's open/closed choice per plan survives every live
update (poll, WebSocket frame, board update) as long as `htmx_treebar_script()`
is on the page. In `render_text`, `:collapsed` prints each closed plan as one
`▸` caption line:

```@example batch_overview
println(render_text(benchmark; phase_overview=:collapsed))
```

`phase_overview=:top` shows only the outermost plans, keeping the overview to
one summary per independent plan while every nested phase stays in the tree.
`:top` and `:collapsed` are accepted wherever `phase_overview=true` is. In a snapshot, a nested
plan's `parent` is `(; plan, phase)`: the enclosing record's index and the
enclosing phase's key; plans are ordered so each precedes those nested in it.
The same declaration inside different enclosing phases forms separate plans.
An outermost plan is labeled with the description of the node that declared
it when every declaring node agrees (otherwise `label` is `nothing` and
renderers number it "Phase plan N"); a nested plan rendered without its
enclosing plan keeps its phase label.

Different macro phase blocks stay separate. NamedTuple plans match by their
complete ordered key sequence; iterable plans match by their complete
declared label sequence, within the same enclosing phase. Matching a phase alone never merges different
sequences, and arbitrary tree descriptions do not determine phase identity.
An item-specific display label falls back to the phase key or position when
instances disagree. Shared trees count once, including across board entries.

A board summarizes the roots in its current server snapshot, so keep completed
roots listed when their counts belong in a history overview. Lingering items
that have left the server list are outside that snapshot. Per-plan snapshots
are locked; the entire workload is not frozen for rendering. The `:state`
backend records these counts; disabled and other backends return no plans.
Lifecycle completion records execution, and does not imply that a scientific
result has passed any domain-specific qualification.

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
