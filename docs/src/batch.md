# Batch processing

This example computes the mean of each sample in a batch. Each synthetic sample is a
named collection of dimensionless measurements, with a flag that requests an
export record. The data are defined below; no file, service or fitted model
is needed. One sample has a cached mean, calculated before the tracked run to
represent a result from earlier work. The cache is separate from the progress
tree: Treebars records that a result was reused, but does not decide whether
a cached value is valid.

```@example batch
using Treebars
samples = [
    (id=:A, values=[2.0, 4.0, 6.0], export_record=true),
    (id=:B, values=[1.0, 3.0, 5.0], export_record=false),
    (id=:C, values=[4.0, 8.0], export_record=false),
]
cached_sample = samples[2]
cache = Dict(cached_sample.id => sum(cached_sample.values) / length(cached_sample.values))
samples
```

## Object

The root owns the batch. A map counter owns one child per sample, and each
child declares the same phase plan: Validate, Summarize and Export. The plan
is known before the sample starts, so an observer can distinguish work that
has not started from work that does not exist. The named tuple's keys identify
the phases; its values provide their labels. Repeating the same ordered keys
lets the overview combine the samples without matching arbitrary messages.

The function returns both the numerical results and the root node. Keeping
those objects separate matters: the callback's last expression determines
the return value of `with_progress`. A progress node is an observation of the
work, not a container for its numerical result. The explicit parent passed
to `progress_map` also keeps this batch independent of the process-wide
default backend.

```@example batch
function summarize_batch(samples, cache)
    with_progress(:state; description="Sample batch") do root
        exports = Pair{Symbol,Float64}[]
        means = progress_map(root, samples; description="Samples") do child, sample
            update_progress!(child, string(sample.id))
            plan = (validate="Validate", summarize="Summarize", export_record="Export")
            with_prepared_phases(child, plan) do phases
                with_prepared_progress(phases.validate) do _
                    isempty(sample.values) && error("Empty sample")
                    all(isfinite, sample.values) || error("Non-finite measurement")
                end
                average = if haskey(cache, sample.id)
                    reuse_progress!(phases.summarize)
                    cache[sample.id]
                else
                    with_prepared_progress(phases.summarize) do _
                        sum(sample.values) / length(sample.values)
                    end
                end
                if sample.export_record
                    with_prepared_progress(phases.export_record) do _
                        push!(exports, sample.id => average)
                    end
                end
                average
            end
        end
        (; means, exports, tree=root)
    end
end
nothing # hide
```

Validation runs for every sample, including a cache hit. Reuse applies only
to the Summarize phase. The Export phase is entered only when requested;
otherwise the enclosing wrapper marks it skipped on exit. These choices
describe different outcomes and should remain different in a user interface.
A reused result exists without being recomputed. A skipped export has no
output from this run.

## Run

The returned means and export records show the numerical work. The text view
then shows which phases produced them.

```@example batch
run = summarize_batch(samples, cache)
println("Means: ", run.means)
println("Exports: ", run.exports)
println(render_text(run.tree))
```

The root is finished because its callback returned normally. A finished root
does not imply that every prepared phase ran: reuse and a deliberate bypass
are successful paths through this computation. Durations in the text are
wall-clock observations of this documentation build. They include compilation
and instrumentation and are not a performance comparison or an estimate for
a larger dataset.

## Phase counts

The overview aggregates the declared plan. It preserves the distinction
between finished, reused and skipped work instead of treating every terminal
phase as an executed phase.

```@example batch
using AlgebraOfVega
overview = only(phase_overview(run.tree))
states = [:finished, :reused, :skipped]
counts = [(phase=phase.label, state=string(state), count=getproperty(phase, state))
          for phase in overview.phases for state in states]
nothing # hide
```

```@example batch
figure = data(counts) *
    mapping(:phase => "Phase", :count => "Count (sample phases)";
            color=:state => "State", dodge_x=:state) * visual(BarPlot) *
    config(width=480, height=240,
        config=(; axis=(; labelFontSize=13, titleFontSize=14),
            legend=(; labelFontSize=13, titleFontSize=14),
            axisX=(; labelAngle=0), axisY=(; tickMinStep=1)),
        scales=scales(
        X=(; categories=[phase.label for phase in overview.phases]),
        Y=(; zero=true),
        Color=(; categories=string.(states), palette=["#2a78d6", "#eb6834", "#777777"])))
include(joinpath(pkgdir(Treebars), "docs", "figures.jl")) # hide
docs_figure(figure, "batch-phases"; # hide
    caption="Finished, reused and skipped sample phases. Counts come from this run.") # hide
```

Blue bars count work that ran; orange bars count an existing result that was
reused; grey bars count work that was bypassed. The values come from the
executed overview, not a separate description of the intended run. Compare
the Summarize and Export groups with the cache and export flags in the input.
No pending, running or failed phase is expected after this successful call;
the diagnostics below check those states instead of omitting them silently.

Only instantiated plans contribute to these counts. An input that has not
yet reached `with_prepared_phases` is not counted as pending. This matters
when interpreting a live batch: the number of planned sample phases may grow
as new items enter the computation. The snapshot is also an observation,
not a lock over the entire workload; different plans can advance while a
reader obtains an overview.

## Diagnostics

The following checks compare the result with an independent direct
calculation and verify that no phase remains pending or running. These
assertions execute in the documentation build, so a change that leaves a
phase open prevents this example from being published.

```@example batch
expected = [sum(sample.values) / length(sample.values) for sample in samples]
@assert run.means == expected
@assert is_finished(run.tree)
@assert all(p -> p.pending == 0 && p.running == 0 && p.failed == 0, overview.phases)
@assert all(p -> p.finished + p.reused + p.skipped == overview.items, overview.phases)
println("Numerical result matches direct calculation: ", run.means == expected)
println("Every prepared phase has a terminal state: ",
    all(p -> p.pending == 0 && p.running == 0, overview.phases))
```

An exception inside a phase follows a different path. Its wrapper marks that
phase failed, rethrows the exception and leaves unentered phases skipped.
The enclosing work also fails. Catch the exception at the boundary where your
application can decide what to do with a partial result; do not catch it
inside a phase merely to obtain a finished progress display. The
[phases guide](phases.md) executes this failure path separately.

For a long-running version, open a snapshot around the root's work or send
mirror frames to another process, as shown in [monitoring](monitoring.md).
These observers use the same tree; they do not run the batch again. Choose
retained children when you need to inspect individual sample histories.
For repeated short steps, transient children can leave the tree after
completion while their prepared-phase counts remain in the overview.

## Reproduce

```@raw html
<details><summary>Environment and commands</summary>
```

Run these shell commands from a checkout after installing the docs dependencies
as described in `docs/README.md`. The build uses that checkout, not a release.

```sh
julia --project=docs docs/instantiate.jl
julia --project=docs docs/make.jl
```

```@example batch
println("Julia: ", VERSION)
println("Treebars: ", pkgversion(Treebars))
println("AlgebraOfVega: ", pkgversion(AlgebraOfVega))
println("Source revision: ", readchomp(`git -C $(pkgdir(Treebars)) rev-parse HEAD`))
println("Input: literals in this page; no external data or fit cache")
```

```@raw html
</details>
```
