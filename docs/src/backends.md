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
[`is_skipped`](@ref), [`is_reused`](@ref), [`duration`](@ref).

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
[`htmx_render_children`](@ref)) that group pending, finished, reused, skipped,
and failed children at each tree level.

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
  (so the elapsed-time counter doesn't stutter). It also owns pausing,
  board reconciliation and each live region's
  [freshness](#freshness-how-current-the-live-view-is).

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
  each poll only swaps the inner fragment. The wrapper carries one
  `.treebar-badge` — a hairline strip plus a panel (pause/play control,
  progress bar and status) above the live tree, expanded by default so a
  first-load region shows progress immediately. Pass `chrome=:quiet` to
  collapse a poller beside already-visible content to the strip (hover/focus
  re-expands it); a poller diverted into HTMXObjects' live-refresh reporter
  is quiet automatically.
- **Failed** — renders the exception as an `<article>` with the error message;
  polling stops naturally because the error article has no `hx-trigger`.
- **Completed** — calls the `render_result` callback and terminalizes the stable
  wrapper as `.treebar-terminal`; no active poll transport or controls remain.

While it polls in-flight work, `polling_fetchindex` also reports the compute to
HTMXObjects' job ledger (`HTMXObjects.track_job!`), so hand-rolled pollers show
on HTMXObjects' runtime dashboard and job boards. Pass `track_job=false` to opt
out.

### Live boards — `htmx_render_board`

[`htmx_render_board`](@ref) renders a keyed, changing collection of progress
trees: a "running jobs" list whose members appear, update in place, and leave.
The board is generic — the caller supplies the entries:

```julia
entries = [
    (; key=job.id, label=job.label, state=job.state,        # :queued/:running/:done/:failed
       elapsed_ms=job.elapsed_ms, node=job.progress,        # optional ProgressNode
       meta=(route=job.route, polls=job.polls),             # small label/value pairs
       href=job.url),                                       # optional link
    …
]
htmx_render_board(entries; poll_url="/jobs", poll_interval="1s",
                  empty="No running jobs.", id="jobs")
```

Each poll returns the full current list, and the client script reconciles it
by `key`: existing items keep their `.treebar-board-item` wrapper (so an
expanded tree and pill toggles survive) and swap only their content, new items
are inserted in server order, and items that drop out of the list show their
final state for `linger_ms` before leaving (a `:done`/`:failed` entry stays as
long as the server lists it). Running
items tick locally between polls; queued items render dim, like pending nodes
(`meta=(position=3,)` reads "queued · #3"). The header carries the
running/queued count and a Pause button that stops the board's polls and
freezes it.

For push instead of polling, [`ws_board`](@ref) sends the same full snapshots
over a WebSocket (the htmx `ws` extension hands each frame to the same
reconciler); other transports can call `window.treebarUpdateBoard(html)`.

### Freshness: how current the live view is

A live region shows the server's state as of its last update. When that
state is old, the region says so, with no setup beyond the page assets:

- **Stale.** No update has arrived for five poll intervals (at least 5s).
  Common causes: a backgrounded tab stopped polling, or the server is slow.
  The region reads "Updated 1m 4s ago" until the next update, and the
  poller's strip stops pulsing.
- **Connection lost.** Every update attempt has failed for 5s straight: the
  server is down, a gateway answers 502/503/504, or the socket dropped. The
  region reads "Connection lost · updated 1m 4s ago · retrying" ("Updates
  failing (HTTP 404)" for other error statuses). The live tree dims, its
  running clocks hold their last known values, the poller's strip turns the
  error color, and a quiet poller opens its panel. A single failed poll that
  the next one recovers from shows nothing.

A lost region keeps retrying (polls keep their timer, and the htmx `ws`
extension reconnects after an abnormal close). It stays marked lost until an
update succeeds, then clears at once.

The notice appears in the poller badge, in a live board's header, and at the
top of each WebSocket frame ([`htmx_ws_progress`](@ref) /
[`htmx_ws_render`](@ref)). Static renders carry none. A stream that ended
normally after its last update, with nothing still running, is settled and
never goes stale.

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
