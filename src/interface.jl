"""
    initialize_progress!(kind::Symbol[, N]; description="Running...", kwargs...)
    initialize_progress!(parent::ProgressNode[, N]; description="Running...", transient=false, kwargs...)

Create a root from a backend symbol, or a child of an existing node. Return a
[`ProgressNode`](@ref); return `nothing` for a disabled parent.
`:state` is built in; `:term` requires Term to be loaded.

An integer `N` creates a determinate counter. Omit it or pass `nothing` for
an indeterminate node. Pass it positionally or by keyword, not both.
`transient=true` detaches a finished child; failed children remain attached.
Unsupported argument shapes and unloaded backends raise `ArgumentError`.

Use [`with_progress`](@ref) for application work so finalization and failure
are handled on every exit. Direct initialization is useful for backends and
nodes whose lifecycle is owned by a replica.
"""
initialize_progress!(::Nothing, args...; kwargs...) = nothing

"""
    update_progress!(node, i; kwargs...)
    update_progress!(node, message::AbstractString; kwargs...)
    update_progress!(node, note::TreebarNote; kwargs...)

Update progress on `node`. Pass an integer to set the counter, a string for a status
message, a [`TreebarNote`](@ref) for a message written in the page's language
([`treebar_notes`](@ref)), or keyword arguments to create/update labeled child nodes.
No-op when `nothing`.

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

Finalize a node without overwriting an existing failure or reuse state.
No-op for `nothing`. Prefer [`with_progress`](@ref) to pair work with cleanup.
"""
finalize_progress!(::Nothing, args...; kwargs...) = nothing

# Symbol dispatch: initialize_progress!(:term, ...) → initialize_progress!(Val(:term), ...)
initialize_progress!(kind::Symbol, args...; kwargs...) = initialize_progress!(Val(kind), args...; kwargs...)
# Convenience: initialize_progress!(Val(:term), N; description=...) creates root + child in one call
initialize_progress!(kind::Val, args...; description="Running...", transient=false, kwargs...) = initialize_progress!(
    initialize_progress!(kind; kwargs...), args...; description, transient, propagates=true
)
# Error fallbacks. An argument shape no backend accepts throws at the call:
# logging and returning `nothing` used to hand back a placeholder node that
# rendered as "Nothing" and silently dropped every later update.
_argtypes(args) = join(map(a -> string(typeof(a)), args), ", ")
initialize_progress!(p, args...; kwargs...) = throw(ArgumentError(
    "initialize_progress!: no method accepts a $(typeof(p)) parent with positional arguments " *
    "($(_argtypes(args))). A child takes an optional counter total, positionally or as `N=`: " *
    "an `Integer` for a determinate counter, `nothing` (or no total) for an indeterminate node. " *
    "A custom backend defines `initialize_progress!` for its own node type."))
initialize_progress!(::Val{K}; kwargs...) where {K} = throw(ArgumentError(
    "initialize_progress!: no progress backend :$K is loaded. `:state` is built in; `:term` needs `using Term`."))

# The counter total of a child node, given positionally. Backends also accept it
# as `N=` (the only spelling `with_prepared_phases` and `prepare_progress!`
# kwargs can forward); passing both is ambiguous, so it throws.
function _positional_N(N, kwargs)
    haskey(kwargs, :N) && throw(ArgumentError(
        "initialize_progress!: the counter total was given both positionally ($(repr(N))) " *
        "and as `N=$(repr(kwargs[:N]))`; pass it once"))
    N
end

# Function-form update: update_progress!(f::Function, progress, ...) merges f() into kwargs
update_progress!(f::Function, ::Nothing, args...; kwargs...) = nothing
update_progress!(f::Function, args...; kwargs...) = update_progress!(args...; kwargs..., f()...)

# Fallback errors. `update_progress!` runs in the body, so an unsupported
# argument throws there. `fail_progress!` / `finalize_progress!` run on the
# cleanup path (`catch` / `finally`), where throwing would replace the exception
# being propagated, so they only log.
update_progress!(p, args...; kwargs...) = throw(ArgumentError(
    "update_progress!: no method accepts a $(typeof(p)) node with arguments ($(_argtypes(args))). " *
    "Pass a counter position `i::Integer`, an `IncrementBy(n)`, a message string, or `nothing` (labels only)."))
fail_progress!(p, args...; kwargs...) = @debug "No implementation loaded for fail_progress!($(typeof(p)), args...; kwargs...)"
finalize_progress!(p, args...; kwargs...) = @error "No implementation loaded for finalize_progress!($(typeof(p)), args...; kwargs...)"

# prepare_progress! / start_progress! no-ops for disabled + non-pending backends
"""
    prepare_progress!(parent, args...; kwargs...)

Create a child progress node in the pending state — appears in the tree but
not yet started. Call [`start_progress!`](@ref) to transition it to running.
Used by `@progress begin … end` to pre-enumerate phase markers. Takes the
arguments of [`initialize_progress!`](@ref), including the counter total
(`prepare_progress!(parent, 5; …)` or `prepare_progress!(parent; N=5, …)`).
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

Terminate a pending progress node as *skipped* — it was pre-enumerated but
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

Mark a pending or running phase reused because its result already exists.
A reused phase is terminal and distinct from finished or skipped. Before
entry it has no duration; after entry it retains time spent checking the
result. Later finalization preserves reuse; a later exception can still fail
it. Pending children become reused and running children are finalized.

Idempotent on terminal nodes. The text view uses `↺`; the HTML view and
[`phase_overview`](@ref) have a reused group. Backends without this state,
including Term, finalize instead. No-op for `nothing`.
"""
reuse_progress!(::Nothing) = nothing
reuse_progress!(::Any) = nothing

"""
    request_interrupt!(node) -> node

Request cooperative interruption on this node and its descendants, including
children created later. Siblings and ancestors are unaffected. This does not
throw or change lifecycle state; work must check [`interrupt_requested`](@ref)
or [`throw_if_interrupted`](@ref).

The request is thread-safe, idempotent and persists for the node's lifetime.
Target the job subtree rather than a long-lived root. No-op for `nothing`.
"""
request_interrupt!(::Nothing) = nothing

"""
    interrupt_requested(node) -> Bool

Whether an interrupt was requested on the node or an ancestor. Return false
for `nothing`. Call at a point where the work can stop; use
[`throw_if_interrupted`](@ref) to abort by exception.
"""
interrupt_requested(::Nothing) = false

"""
    htmx_render(node; article=false, scoped=true, max_finished=nothing,
                phase_overview=false, texts=nothing, kwargs...)

Render a state-backed node as an HTMX HTML fragment. Requires HTMXObjects.
Counters become progress bars, messages become label rows and containers hold
their children. `article=true` uses an article container. Include
[`htmx_treebar_styles`](@ref) and [`htmx_treebar_script`](@ref) in the host page.

`scoped` and `max_finished` pass to [`htmx_render_children`](@ref).
`phase_overview=true` prepends counts with nested plans expanded;
`:collapsed` starts nested plans closed and `:top` shows outermost plans only.
Viewer disclosure choices survive updates when the client script is loaded.

`texts` selects [`TreebarTexts`](@ref). With `nothing`, use the HTMXObjects
page language when available: German for `de` or `de-*`, English otherwise.
All HTML renderers use this language convention. A missing state node raises
an error; initialize the application's status tree before rendering it.
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
    htmx_render_children(node; scoped=true, max_finished=nothing, texts=nothing)

Render children grouped by lifecycle state, with toggle pills. Requires
HTMXObjects. Finished, reused and skipped groups start hidden behind their
pills. Every child is included by default.

`max_finished=k` keeps the newest `k` finished children per container,
likewise reused and skipped, and adds a count for older children. Pending,
running and failed children are never elided; pills count the whole group.
[`render_text`](@ref) never elides nodes.

`scoped=true` owns visibility on this container. Inside a poller's existing
scope, pass `scoped=false`. See [`htmx_render`](@ref) for `texts` and the
full-node renderer.
"""
function htmx_render_children end

# htmx_treebar_styles — returns a <style> Node with all treebar CSS classes
"""
    htmx_treebar_styles()

Return the HTMX style node for progress trees, pills, pollers and boards.
Requires HTMXObjects. Include it once in the host page's `extra_head`, beside
[`htmx_treebar_script`](@ref).
"""
function htmx_treebar_styles end

# htmx_treebar_script — returns a <script> Node with Treebars' client behavior
"""
    htmx_treebar_script()

Return the HTMX script node for duration updates, poller controls, preserved
viewer choices and keyed board updates. Requires HTMXObjects. Include it once
beside [`htmx_treebar_styles`](@ref) in the host page's `extra_head`.

The script advances running clocks between server updates and stops the
transport when a poller receives a completed result. It reconciles boards by
key and retains pill and disclosure choices across updates. Without it,
server-rendered fragments do not provide these client behaviors.
"""
function htmx_treebar_script end

# ws_progress fallback
"""
    ws_progress(ws, node; interval=0.1, render=repr, wake=nothing, min_interval=0)

Push live progress updates over a WebSocket until `node` finalises.
Implementation lives in the HTTP package extension — load `HTTP` to activate
it.

`render(node)` is called every `interval` seconds and the resulting string is
sent over `ws`. The default `render=repr` is text-only; load `HTMXObjects` to
get [`htmx_ws_render`](@ref), which produces an HTML fragment with a stable
`id` suitable for HTMX swap-by-id.

`wake`, a `Base.Event`, sends the next frame as soon as it is notified rather
than at the end of `interval`, but never sooner than `min(min_interval,
interval)` seconds after the previous frame, so a burst of notifications
coalesces into one frame. The producer form below wakes its sender this way.
"""
ws_progress(ws, p; kwargs...) = @error "No implementation loaded for ws_progress. Load HTTP to enable WebSocket progress."

"""
    ws_progress(produce, ws; id, description=nothing, N=nothing,
                parent=nothing, interval=0.1, min_interval=0.016, buffer=64, texts=nothing)
    ws_progress(produce, ws, progress; id, interval=0.1, min_interval=0.016, buffer=64, texts=nothing)

Run `produce(publish, progress)` while streaming HTML updates to a matching
[`htmx_ws_progress`](@ref) view. Load `HTMXObjects` and `HTTP` to activate it.
The callback receives a normal `:state` progress node and `publish(fragment)`:
use the node with `@progress` and publish HTMX update nodes as partial results
arrive. Treebars owns the bounded queue and the sole WebSocket sender; the
initial tree is sent before the producer starts, and queued updates are flushed
before the completed tree. The producer runs on the default thread pool; the
sender runs on its own task (on the interactive pool when Julia has one), so a
producer that never yields cannot hold it up.

Each `publish`, and the producer finishing, wakes the sender: everything queued
so far leaves in one frame with the current tree, without waiting for the next
`interval`. Frames are at least `min(min_interval, interval)` seconds apart, so
a burst of publishes coalesces instead of re-sending the tree for each one;
`min_interval=0` sends as soon as the sender is free. Without publishes, the
tree is re-sent every `interval` seconds. `buffer` bounds the queue: a publisher
that outruns the sender waits for room.
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
creates a dedicated child node. `description` defaults to the texts' `working`
("Working..."). `texts` (see [`htmx_render`](@ref)) is resolved when the route
calls `ws_progress`, so every frame speaks the answer's language.
"""
ws_progress(produce::Function, ws; kwargs...) =
    throw(ArgumentError("Load HTMXObjects and HTTP to stream partial results with ws_progress."))
ws_progress(produce::Function, ws, progress; kwargs...) =
    throw(ArgumentError("Load HTMXObjects and HTTP to stream partial results with ws_progress."))

"""
    htmx_ws_progress(content; url, id, progress=nothing,
                     description=nothing, N=nothing, collapsed=false, texts=nothing)

Render the initial content and an open progress tree, connecting
to `url` through the htmx WebSocket extension. Pair this with the producer form
of [`ws_progress`](@ref), using the same unique `id` on both routes. The content
stays mounted; progress and published updates have separate stable targets.
`collapsed=true` starts the tree closed; the viewer's choice survives updates.
An optional `progress` renders an existing node; otherwise show a pending node
described by `description` (default: the texts' `working`, "Working...").
`texts` is the language of the tree and its "Progress" summary; see
[`htmx_render`](@ref).

Include `htmx_treebar_styles()` and `htmx_treebar_script()` once in the host
page's `extra_head`; HTMXObjects' `htmx()` supplies the WebSocket extension.
This helper accepts any initial HTMX content and update nodes, including AOV
plots and `append_data`/`update_data`, without a plotting dependency in Treebars.
"""
function htmx_ws_progress end

# htmx_ws_render fallback
"""
    htmx_ws_render(node; id="treebar-progress", texts=nothing)

Default `render` for [`ws_progress`](@ref) when `HTMXObjects` is loaded.
Wraps [`htmx_render`](@ref) in a `<div id=… class="treebar-ws-frame">` so the
HTMX ws extension swaps by element id. The frame is the tree's pill scope,
like a poller's wrapper: with [`htmx_treebar_script`](@ref) on the page, a
viewer's pill toggles (and nested phase-plan disclosures) carry over to each
next frame with the same `id`.
"""
htmx_ws_render(p; kwargs...) = @error "No implementation loaded for htmx_ws_render. Load HTMXObjects to enable HTML WebSocket rendering."

"""
    htmx_render_board(entries; poll_url=nothing, poll_interval="1s",
        empty=nothing, id="treebar-board", linger_ms=3000, expanded=false,
        live=poll_url !== nothing, phase_overview=false, texts=nothing, pause=nothing)

Render a changing collection of jobs. Requires HTMXObjects and the Treebars
style and script nodes in the page. Each entry supplies these properties:

| Property | Meaning |
| --- | --- |
| `key` | Stable identity; the first entry for a duplicate key wins. |
| `label` | Job heading. |
| `state` | `:queued`, `:running`, `:done` or `:failed`. |
| `elapsed_ms` | Elapsed or final duration in milliseconds. |
| `node` | Optional progress tree, default `nothing`. |
| `meta` | Label/value pairs, default `()`. |
| `href` | Optional heading link, default `nothing`. |

Every update supplies the full current list. `poll_url` enables polling;
`poll_interval` uses HTMX duration syntax. The script matches by key,
preserves viewer choices, and removes departing items after `linger_ms`.
Keep completed entries in the list to retain their history.

`expanded` opens item trees initially. A live board offers Pause unless
`pause=false` or the page declares `__progress_pause__ = false`. `empty`
overrides the empty-list content. `id` must be a valid CSS id.
`phase_overview` and `texts` follow [`htmx_render`](@ref); counts include
currently listed nodes only, deduplicating shared nodes and duplicate keys.
"""
function htmx_render_board end

"""
    htmx_ws_render_board(entries; id="treebar-board", kwargs...)

[`htmx_render_board`](@ref) as an HTML string for a WebSocket frame: no poll
element, Pause shown unless `pause=false` or the page declares
`__progress_pause__ = false`. The client script reconciles each frame into the live
board with the same `id` (the htmx `ws` extension's `htmx:wsBeforeMessage`),
exactly as it does poll responses. For other transports (SSE, a hand-written
socket) call `window.treebarUpdateBoard(html)` with the frame.
"""
function htmx_ws_render_board end

"""
    ws_board(ws, entries; interval=1.0, until=() -> false, kwargs...)

Call `entries()` and send a full board snapshot every `interval` seconds,
until the client disconnects or `until()` returns true; then send a final
frame. Requires HTMXObjects and HTTP. Keywords pass to
[`htmx_ws_render_board`](@ref). Resolve language and pause policy once for the
connection. Use the same board `id` in the initial page and updates.
"""
ws_board(ws, entries; kwargs...) = error("No implementation loaded for ws_board. Load HTMXObjects and HTTP to enable WebSocket boards.")
