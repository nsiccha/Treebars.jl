"""
    initialize_progress!(kind::Symbol, N; description="Running...", kwargs...)
    initialize_progress!(parent::ProgressNode, N; description="Running...", kwargs...)

Create a progress root (from a backend symbol like `:state` or `:term`) or a child
node (from an existing `ProgressNode`). Returns a `ProgressNode`. No-op when `nothing`.

!!! warning "Prefer `@progress` or `with_progress` instead"
    Calling `initialize_progress!` / `update_progress!` / `finalize_progress!` manually
    is error-prone — forgetting `finalize_progress!` or missing exceptions leaves
    progress nodes stuck in the "running" state forever. Use the convenience API:

    ```julia
    # Best: automatic initialize + update + finalize for loops
    @progress parent for i in 1:N
        # ...
    end

    # Good: automatic finalize + fail handling via do-block
    with_progress(parent, N; description="...") do p
        for i in 1:N
            # ...
            update_progress!(p, i)
        end
    end
    ```

    See [`with_progress`](@ref), [`@progress`](@ref).
"""
initialize_progress!(::Nothing, args...; kwargs...) = nothing

"""
    update_progress!(node, i; kwargs...)
    update_progress!(node, message::AbstractString; kwargs...)

Update progress on `node`. Pass an integer to set the counter, a string for a status
message, or keyword arguments to create/update labeled child nodes. No-op when `nothing`.

See [`@progress`](@ref) and [`with_progress`](@ref) for wrappers that handle the
full initialize/update/finalize lifecycle automatically.
"""
update_progress!(::Nothing, args...; kwargs...) = nothing

"""
    fail_progress!(node; kwargs...)

Mark a progress node as failed. No-op when `nothing`.
"""
fail_progress!(::Nothing, args...; kwargs...) = nothing

"""
    finalize_progress!(node; kwargs...)

Mark a progress node as complete. No-op when `nothing`.

!!! warning "Prefer `@progress` or `with_progress` instead"
    Manual `finalize_progress!` is easy to forget or skip on exceptions. Use
    [`@progress`](@ref) or [`with_progress`](@ref) which handle finalization and
    failure automatically in a try/catch/finally block.
"""
finalize_progress!(::Nothing, args...; kwargs...) = nothing

# Symbol dispatch: initialize_progress!(:term, ...) → initialize_progress!(Val(:term), ...)
initialize_progress!(kind::Symbol, args...; kwargs...) = initialize_progress!(Val(kind), args...; kwargs...)
# Convenience: initialize_progress!(Val(:term), N; description=...) creates root + child in one call
initialize_progress!(kind::Val, args...; description="Running...", transient=false, kwargs...) = initialize_progress!(
    initialize_progress!(kind; kwargs...), args...; description, transient, propagates=true
)
# Error fallbacks
initialize_progress!(p, args...; kwargs...) = @error "No implementation loaded for initialize_progress!($(typeof(p)), args...; kwargs...)"
initialize_progress!(p::Val; kwargs...) = @error "No implementation loaded for initialize_progress!($(typeof(p)); kwargs...)"

# Function-form update: update_progress!(f::Function, progress, ...) merges f() into kwargs
update_progress!(f::Function, ::Nothing, args...; kwargs...) = nothing
update_progress!(f::Function, args...; kwargs...) = update_progress!(args...; kwargs..., f()...)

# Fallback errors
update_progress!(p, args...; kwargs...) = @error "No implementation loaded for update_progress!($(typeof(p)), args...; kwargs...)"
fail_progress!(p, args...; kwargs...) = @debug "No implementation loaded for fail_progress!($(typeof(p)), args...; kwargs...)"
finalize_progress!(p, args...; kwargs...) = @error "No implementation loaded for finalize_progress!($(typeof(p)), args...; kwargs...)"

# prepare_progress! / start_progress! no-ops for disabled + non-pending backends
"""
    prepare_progress!(parent, args...; kwargs...)

Create a child progress node in the **pending** state — appears in the tree but
not yet started. Call [`start_progress!`](@ref) to transition it to running.
Used by `@progress begin … end` to pre-enumerate phase markers.
"""
prepare_progress!(::Nothing, args...; kwargs...) = nothing

"""
    start_progress!(node)

Transition a pending progress node to running. Idempotent; no-op for backends
without a pending concept.
"""
start_progress!(::Nothing) = nothing
start_progress!(::Any) = nothing

"""
    skip_progress!(node)

Terminate a **pending** progress node as *skipped* — it was pre-enumerated but
never entered, and never will be (control flow left the block first). Distinct
from [`finalize_progress!`](@ref) (which means "ran and completed") and from
[`fail_progress!`](@ref) (which means "ran and threw").

Idempotent, and a no-op on a node that is not pending: a running node has
started, so it is finalized or failed on its own terms, never skipped.
No-op for backends without a pending concept.
"""
skip_progress!(::Nothing) = nothing
skip_progress!(::Any) = nothing

"""
    reuse_progress!(node)

Terminate a **pending or running** progress node as *reused* — its result was
already available (a cache hit, or output prepared by an earlier run), so the
work it stands for was not done this time. Distinct from
[`finalize_progress!`](@ref) ("ran and completed") and from
[`skip_progress!`](@ref) ("never entered; its result does not exist").

Call it on a prepared phase before entering it, or from inside the phase body
once the hit is known:

```julia
with_prepared_phases(parent, (prepare="Prepare model", fit="Fit")) do phases
    cached(:prepare) ? reuse_progress!(phases.prepare) :
        with_prepared_progress(_ -> prepare_model(), phases.prepare)
    with_prepared_progress(phases.fit) do phase
        hit = lookup_fit()
        isnothing(hit) || (reuse_progress!(phase); return hit)
        fit_model()
    end
end
```

A phase reused before it was entered has no duration; one reused from inside
its body keeps the time spent finding out. The enclosing wrapper's later
finalize leaves a reused node unchanged, while an exception thrown after the
reuse still fails it. Pending children of a reused node become reused too;
running children are finalized. Idempotent, and a no-op on a node that already
finished, failed, or was skipped.

Renders as `↺` in [`render_text`](@ref), as `reused` with an "N reused" pill
in the HTML renderer, and in its own `reused` column of
[`phase_overview`](@ref). Backends without the state (Term.jl) finalize the
node instead; `nothing` is a no-op.
"""
reuse_progress!(::Nothing) = nothing
reuse_progress!(::Any) = nothing

"""
    request_interrupt!(node) -> node

Ask the work running under `node` to stop early. Sets `node`'s interrupt flag,
after which [`interrupt_requested`](@ref) reports `true` for `node` and for
every node below it — including children created after the request — while
siblings and ancestors are unaffected.

Purely a **request**: nothing throws, stops, or changes lifecycle state. A
runner opts in by checking [`interrupt_requested`](@ref) at points where it can
wind down (e.g. a sampler at a checkpoint boundary) and then finalizes or fails
its node as usual; a runner that never checks simply runs to completion.

Thread-safe and idempotent; the flag stays set for the node's lifetime, so
target the node of the job you mean to stop rather than a long-lived root that
later jobs will also hang under. No-op for `nothing`.
"""
request_interrupt!(::Nothing) = nothing

"""
    interrupt_requested(node) -> Bool

`true` when [`request_interrupt!`](@ref) was called on `node` or on any of its
ancestors. Lock-free (one atomic load per level of the `parent` chain), so it
is cheap enough to poll inside a hot loop. `false` for `nothing` — a disabled
progress tree is never interrupted.

```julia
for i in 1:n_steps
    interrupt_requested(progress) && break   # opt in: stop early, keep what we have
    step!(state)
    update_progress!(progress)
end
```

[`throw_if_interrupted`](@ref) is the one-line form for work that simply aborts.
"""
interrupt_requested(::Nothing) = false

"""
    htmx_render(node; article=false, scoped=true, max_finished=nothing, phase_overview=false, kwargs...)

Render a `ProgressNode` tree as an HTMX `Node` fragment. The implementation
lives in the HTMXObjects package extension — loading `HTMXObjects` activates
it. Without that extension the call raises a descriptive `error`.

Rendering rules (for `ProgressNode{<:StateProgress}`):

- Nodes with a counter (`N !== nothing`) render as `<progress>` bars with
  `description: i / N` headers.
- Nodes with a message but no counter render as `key: value` label rows.
- Container nodes render as nested `<div>` (or `<article>` when
  `article=true`) with a header and `htmx_render_children` output.

Each node's header includes a `.treebar-duration` span; the
[`htmx_treebar_script`](@ref) ticker advances running nodes locally between
polls. Skipped nodes, and reused nodes that were never entered, show no
duration. `scoped` and `max_finished` are
forwarded to `htmx_render_children` at every level (see there).

`phase_overview=true` prepends per-plan lifecycle counts from
[`phase_overview`](@ref), once above the tree. A plan declared inside another
plan's prepared phase is indented under it and captioned with that phase's
label; `phase_overview=:top` shows only the outermost plans. It does not elide
individual nodes. The same opt-in is supported by `htmx_render_children`,
`htmx_ws_render`, `htmx_ws_progress`, producer-form `ws_progress`, and
`polling_fetchindex` (HTTP and WebSocket).
"""
htmx_render(p; kwargs...) = error("No implementation loaded for htmx_render($(typeof(p)); kwargs...)")

# Specific guard: a `nothing` status reaches `htmx_render` whenever
# `polling_fetchindex` runs against an IP whose enclosing AppData (or
# wherever the IP lives) didn't initialise `__status__`. The fallback
# above would say "No implementation loaded for htmx_render(Nothing;
# kwargs...)" — accurate but unhelpful. This message points at the
# root cause directly.
htmx_render(::Nothing; kwargs...) = error("""
htmx_render(::Nothing) — `__status__` resolved to `nothing` on the IP
that `polling_fetchindex` is rendering.

The progress tree was never initialized. Add to your AppData @dynamicstruct:

    using Treebars: initialize_progress!

    @dynamicstruct struct AppData
        __status__ = initialize_progress!(:state; description="<your app>")
        # … your IPs and other state
    end

`:state` selects the StateProgress backend (text-tree, suitable for
HTMX rendering). The `description` is the root label shown above the
per-phase nodes.

See HTMXObjects KB "AppData must initialize __status__" for context.
""")

# htmx_render_children — implemented in HTMXObjectsExt
"""
    htmx_render_children(node; scoped=true, max_finished=nothing)

Render the children of a `ProgressNode` as an HTML fragment, classifying them
into pending / running / finished / reused / skipped / failed groups and
emitting toggle pills (`"N pending"`, `"N finished"`, `"N reused"`,
`"N skipped"`, `"N failed"`) at the top. Finished, reused and skipped children
start hidden behind their pills.
Implementation lives in the HTMXObjects package extension — loading
`HTMXObjects` activates it.

Every child is rendered by default (`max_finished=nothing`). As an opt-in,
`max_finished=k` renders individually only the newest `k` finished children
per container (likewise reused, and skipped). The older ones are replaced by one
`.treebar-elided` line ("N earlier finished not shown") that shows and hides
with that group's pill. Pills count every child either way. Pending, running
and failed children are never elided. [`render_text`](@ref) never elides.

`scoped=true` (the default) emits `data-show-*` attributes on the wrapper so
the pills toggle visibility scoped to this children container. Inside a
`.treebar-poller` (as set up by [`polling_fetchindex`](@ref)), pass
`scoped=false` so the wrapper's descendant CSS rules win.

Use [`htmx_render`](@ref) for full-node rendering (it calls
`htmx_render_children` internally for every level of the tree).
"""
function htmx_render_children end

# htmx_treebar_styles — returns a <style> Node with all treebar CSS classes
"""
    htmx_treebar_styles()

Return a `<style>` HTMX node with the CSS for every treebar class
(`treebar-node`, `treebar-pill-*`, `treebar-children`, `treebar-poller`, …).
Implementation lives in the HTMXObjects package extension.

Include it in your app's `<head>` via the `extra_head` kwarg of `htmx(…)`:

```julia
htmx(...; extra_head=(htmx_treebar_styles(), htmx_treebar_script(), ...))
```

Pairs with [`htmx_treebar_script`](@ref), which provides the client-side
duration ticker.
"""
function htmx_treebar_styles end

# htmx_treebar_script — returns a <script> Node with Treebars' client behavior
"""
    htmx_treebar_script()

Return a `<script>` HTMX node with Treebars' client-side polling behavior.
Running `.treebar-duration` spans advance their displayed elapsed time every
100ms locally instead of stuttering between server polls; the script also owns
the badge status mirror (pause glyph, polling/paused word, determinate bar,
elapsed — refreshed from the live tree after every swap and tick), pause
handling, and terminalization of a completed poller's persistent wrapper from
`.treebar-poller` to `.treebar-terminal`. Terminal nodes keep the
server-rendered duration text; skipped nodes and never-entered reused nodes
carry no duration.
It is also the keyed reconciler behind [`htmx_render_board`](@ref): board
polls, WebSocket frames and `window.treebarUpdateBoard(html)` update items in
place by key instead of replacing the board.
Implementation lives in the HTMXObjects package extension.

Include it once alongside [`htmx_treebar_styles`](@ref) via `extra_head`.
Without it the HTMX fragment can still poll and receive terminal content, but
the badge status mirror never updates and the wrapper retains its live-poller
identity and badge control. (Collapse is stylesheet-driven, so a
`chrome=:quiet` poller still collapses without the script — it just never
refreshes its mirrored status.)
"""
function htmx_treebar_script end

# ws_progress fallback
"""
    ws_progress(ws, node; interval=0.1, render=repr)

Push live progress updates over a WebSocket until `node` finalises.
Implementation lives in the HTTP package extension — load `HTTP` to activate
it.

`render(node)` is called every `interval` seconds and the resulting string is
sent over `ws`. The default `render=repr` is text-only; load `HTMXObjects` to
get [`htmx_ws_render`](@ref), which produces an HTML fragment with a stable
`id` suitable for HTMX swap-by-id.
"""
ws_progress(ws, p; kwargs...) = @error "No implementation loaded for ws_progress. Load HTTP to enable WebSocket progress."

"""
    ws_progress(produce, ws; id, description="Working...", N=nothing,
                parent=nothing, interval=0.1, buffer=64)
    ws_progress(produce, ws, progress; id, interval=0.1, buffer=64)

Run `produce(publish, progress)` while streaming HTML updates to a matching
[`htmx_ws_progress`](@ref) view. Load `HTMXObjects` and `HTTP` to activate it.
The callback receives a normal `:state` progress node and `publish(fragment)`:
use the node with `@progress` and publish HTMX update nodes as partial results
arrive. Treebars owns the bounded queue and the sole WebSocket sender; the
initial tree is sent before the producer starts, and queued updates are flushed
before the completed tree. The producer runs on the default thread pool.
`publish` honors `hx-swap-oob`: a published `Node` carrying that attribute is
delivered as a top-level message sibling, so the htmx ws extension swaps it
into its target outside the `<id>-updates` sink instead of appending it there.
`Raw`/`String` fragments always sink.

The return value is the producer's result. Exceptions mark the tree failed and
are rethrown after its final frame. The exception text is never rendered
into a frame: frames carry tree state, counters and pills only. A consumer
that wants the reason visible in the browser publishes its own escaped
alert fragment through `publish` before rethrowing. Disconnecting stops
delivery but lets the producer finish; blocked publishers are released.
The provided-node form owns that node's lifecycle; `parent=` instead
creates a dedicated child node.
"""
ws_progress(produce::Function, ws; kwargs...) =
    throw(ArgumentError("Load HTMXObjects and HTTP to stream partial results with ws_progress."))
ws_progress(produce::Function, ws, progress; kwargs...) =
    throw(ArgumentError("Load HTMXObjects and HTTP to stream partial results with ws_progress."))

"""
    htmx_ws_progress(content; url, id, progress=nothing,
                     description="Working...", N=nothing, collapsed=false)

Render the initial content and an open, unobtrusive progress tree, connecting
to `url` through the htmx WebSocket extension. Pair this with the producer form
of [`ws_progress`](@ref), using the same unique `id` on both routes. The content
stays mounted; progress and published updates have separate stable targets.
`collapsed=true` starts the tree closed; the viewer's choice survives updates.
An optional `progress` renders an existing node; otherwise show a pending node.

Include `htmx_treebar_styles()` and `htmx_treebar_script()` once in the host
page's `extra_head`; HTMXObjects' `htmx()` supplies the WebSocket extension.
This helper accepts any initial HTMX content and update nodes, including AOV
plots and `append_data`/`update_data`, without a plotting dependency in Treebars.
"""
function htmx_ws_progress end

# htmx_ws_render fallback
"""
    htmx_ws_render(node; id="treebar-progress")

Default `render` for [`ws_progress`](@ref) when `HTMXObjects` is loaded.
Wraps [`htmx_render`](@ref) in a `<div id=…>` so the HTMX ws extension swaps
by element id.
"""
htmx_ws_render(p; kwargs...) = @error "No implementation loaded for htmx_ws_render. Load HTMXObjects to enable HTML WebSocket rendering."

"""
    htmx_render_board(entries; poll_url=nothing, poll_interval="1s",
                      empty="No running jobs.", id="treebar-board",
                      linger_ms=3000, expanded=false, live=poll_url !== nothing,
                      phase_overview=false)

Render a keyed, changing collection of progress trees — a live "running jobs"
board — as an HTMX `Node`. Implementation lives in the HTMXObjects package
extension. The board is generic: it knows nothing about where its entries come
from.

`entries` is a vector of NamedTuples (any object with these properties works):

```julia
(; key, label, state, elapsed_ms, node=nothing, meta=(), href=nothing)
```

- `key` — stable identity; the client matches items across updates by it.
  The first entry with a given key wins.
- `label` — the item's heading.
- `state` — `:queued`, `:running`, `:done` or `:failed`. A queued item renders
  dim like a pending node, reading "queued · #3" when `meta` carries a
  `position`.
- `elapsed_ms` — time so far (running) or total (done/failed); a running item's
  header ticks locally between updates.
- `node` — optional [`ProgressNode`](@ref), rendered with [`htmx_render`](@ref)
  in a collapsible `<details>` under the header (open when `expanded`).
- `meta` — small label/value pairs (a NamedTuple, `Dict` or vector of Pairs)
  shown under the header: route, polls, "unwatched" => "12s", …
- `href` — optional link for the label (the job's own poller or result).

Each entry becomes a `.treebar-board-item[data-treebar-key]` wrapper that holds
its UI state — tree expansion (`data-open`) and pill toggles (`data-show-*`) —
exactly as `.treebar-poller` does, around a `.treebar-board-item-content` the
client replaces on every update.

Every update carries the full current list. With `poll_url`, a
`.treebar-board-poll` element fetches it every `poll_interval`, and
[`htmx_treebar_script`](@ref) reconciles the response by key instead of letting
htmx replace the board: existing items update in place (wrappers untouched), new
items are inserted in server order, and items that leave the list show their
final state for `linger_ms` (overridable per item with `data-treebar-linger-ms`)
and are then removed; an item that leaves while still queued or running reads
"ended". A `:done`/`:failed` entry stays as long as the server lists it, so list
finished entries for a moment to show their outcome — or keep listing them for
a history board. Without the script, the poll falls back to replacing the whole
board. Full snapshots are idempotent, survive dropped polls and need no
per-client state on the server.

The header shows the running/queued counts and, when `live`, a Pause button
(same mechanism as the poller's): a paused board issues no polls, drops pushed
frames, freezes its clocks and keeps lingering items. `empty` is shown while the
list is empty. `id` must be a valid CSS id; the reconciler matches updates to
the live board by it. For WebSocket push see [`ws_board`](@ref).

Include [`htmx_treebar_styles`](@ref) and [`htmx_treebar_script`](@ref) on the
page.

`phase_overview=true` (or `:top`, outermost plans only) shows one overview
across the listed entries' progress nodes. Shared nodes and duplicate entry keys count once; entries without a
node contribute no phase counts. The overview follows the current server
snapshot, while departing items may still linger visually. A history board
must continue listing completed roots to include their counts. Item trees
remain in their existing disclosures. `htmx_ws_render_board` and `ws_board`
forward this opt-in.
"""
function htmx_render_board end

"""
    htmx_ws_render_board(entries; id="treebar-board", kwargs...)

[`htmx_render_board`](@ref) as an HTML string for a WebSocket frame: no poll
element, Pause shown. The client script reconciles each frame into the live
board with the same `id` (the htmx `ws` extension's `htmx:wsBeforeMessage`),
exactly as it does poll responses. For other transports (SSE, a hand-written
socket) call `window.treebarUpdateBoard(html)` with the frame.
"""
function htmx_ws_render_board end

"""
    ws_board(ws, entries; interval=1.0, until=() -> false, kwargs...)

WebSocket variant of a polled [`htmx_render_board`](@ref), mirroring
[`ws_progress`](@ref): every `interval` seconds, call the zero-argument
function `entries()` and push the full board snapshot
([`htmx_ws_render_board`](@ref), `kwargs...` forwarded) until the client goes
away or `until()` returns `true` (one final frame is sent then). The page renders
the initial board with the same `id` inside the `ws-connect` element:

```julia
h.div(hx_ext="ws", ws_connect="/ws/jobs")(htmx_render_board(entries(); live=true))
```

Implementation lives in the HTMXObjects package extension (with HTTP).
"""
ws_board(ws, entries; kwargs...) = error("No implementation loaded for ws_board. Load HTMXObjects and HTTP to enable WebSocket boards.")
