# Backends

Treebars is backend-agnostic. The progress interface dispatches to
backend-specific implementations via Julia's type system. A `nothing` backend
disables progress (all operations return `nothing`).

## Term.jl (`:term`)

Terminal progress bars using [Term.jl](https://github.com/FedeClaworkers/Term.jl).
Loaded via the `TermExt` package extension — `using Term` activates it.

```julia
using Treebars, Term

p = initialize_progress!(:term; width=120)
```

Features:

- Background render thread for smooth animation
- ETA calculation
- Coloured progress bars with completion percentage
- Labelled sub-rows for metadata via `update_progress!` kwargs

## StateProgress (`:state`)

Thread-safe, inspectable progress backend for web / remote / polling use
cases. State lives in a mutable [`StateProgress`](@ref) struct guarded by a
`ReentrantLock`.

```julia
p = initialize_progress!(:state; description="My task")
child = initialize_progress!(p, 100; description="Step 1")
update_progress!(child, 50)
```

Each node exposes lifecycle queries — see [`is_pending`](@ref),
[`is_running`](@ref), [`is_finished`](@ref), [`is_failed`](@ref),
[`duration`](@ref).

## HTMXObjects.jl integration

When `HTMXObjects` is loaded, `StateProgress` trees can be rendered as HTML.
Loaded via the `HTMXObjectsExt` package extension.

```julia
using Treebars, HTMXObjects

root = initialize_progress!(:state; description="Fitting")
job = initialize_progress!(root, 100; description="Chain 1")
update_progress!(job, 42)

html = htmx_render(root)   # HTMX Node tree
```

The rendered HTML uses `<progress>` elements plus toggle pills (rendered by
[`htmx_render_children`](@ref)) that hide finished / show failed children at
each tree level.

### Assets

Include the styles + duration ticker once in your app's `<head>` via
`extra_head`:

```julia
htmx(...; extra_head=(htmx_treebar_styles(), htmx_treebar_script(), ...))
```

- [`htmx_treebar_styles`](@ref) returns a `<style>` node with all
  `treebar-*` CSS classes.
- [`htmx_treebar_script`](@ref) returns a `<script>` node with a client-side
  duration ticker that advances running nodes locally between server polls
  (so the elapsed-time counter doesn't stutter).

### Polling with cancel — `polling_fetchindex`

[`polling_fetchindex`](@ref) wraps the entire fetchindex + HTMX polling +
progress rendering pattern into a single call. The poller wrapper survives
across polls (only its inner progress fragment swaps), so pill toggle state
persists between polls.

```julia
polling_fetchindex(app.results, key;
    poll_url=query_url("/results/$key"),
    label="Computation ($key)",
    cancel_url=query_url("/cancel/$key"),  # optional Stop button
    poll_interval="200ms",
) do rv
    render_my_result(rv)
end
```

Three states are handled automatically:

- **Running** — renders the progress tree inside a `.treebar-poller` wrapper;
  each poll only swaps the inner fragment.
- **Failed** — renders the exception as an `<article>` with the error message;
  polling stops naturally because the error article has no `hx-trigger`.
- **Completed** — calls the `render_result` callback and terminalizes the stable
  wrapper as `.treebar-terminal`; no active poll transport or controls remain.

## HTTP / WebSocket (`ws_progress`)

When `HTTP` is loaded, the `HTTPExt` package extension provides
[`ws_progress`](@ref): a push loop that sends rendered progress over a
WebSocket until the node finalises.

```julia
@ws ws = begin
    p = initialize_progress!(:state; description="Running")
    task = Threads.@spawn expensive_computation(p)
    ws_progress(__ws__, p; render=htmx_ws_render)
    send(__ws__, render_result(fetch(task)))
end
```

The default `render` is `repr`; load `HTMXObjects` to use
[`htmx_ws_render`](@ref) which wraps `htmx_render` in a stable-id `<div>` for
HTMX swap-by-id.

## Custom backends

Implement the progress interface for your own types. The minimum surface is:

```julia
struct MyProgress
    # your state
end

Treebars.initialize_progress!(::Val{:mybackend}; kwargs...) = ProgressNode(MyProgress(), …)
Treebars.initialize_progress!(p::MyProgress, N::Integer; kwargs...) = MyProgress(…)
Treebars.update_progress!(p::MyProgress, i::Integer) = …
Treebars.update_progress!(p::MyProgress, msg::AbstractString) = …
Treebars.finalize_progress!(p::MyProgress) = …

# Optional
Treebars.fail_progress!(p::MyProgress, exception) = …
Treebars.start_progress!(p::MyProgress) = …    # if the backend supports a pending state
```

See `ext/TermExt.jl` and `src/implementation.jl` (the `StateProgress` backend)
for full reference implementations.
