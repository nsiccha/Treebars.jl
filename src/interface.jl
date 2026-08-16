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
    htmx_render(node; article=false, scoped=true, kwargs...)

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
polls. Skipped nodes show no duration. `scoped` is forwarded to
`htmx_render_children` (see there).
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
    htmx_render_children(node; scoped=true)

Render the children of a `ProgressNode` as an HTML fragment, classifying them
into pending / running / finished / skipped / failed groups and emitting toggle
pills (`"N pending"`, `"N finished"`, `"N skipped"`, `"N failed"`) at the top.
Implementation lives in the HTMXObjects package extension — loading
`HTMXObjects` activates it.

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
Pause handling and terminalizes a completed poller's persistent wrapper from
`.treebar-poller` to `.treebar-terminal`. Terminal nodes keep the
server-rendered duration text and skipped nodes carry no duration.
Implementation lives in the HTMXObjects package extension.

Include it once alongside [`htmx_treebar_styles`](@ref) via `extra_head`.
Without it the HTMX fragment can still poll and receive terminal content, but
the wrapper retains its live-poller identity and Pause control.
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

# htmx_ws_render fallback
"""
    htmx_ws_render(node; id="treebar-progress")

Default `render` for [`ws_progress`](@ref) when `HTMXObjects` is loaded.
Wraps [`htmx_render`](@ref) in a `<div id=…>` so the HTMX ws extension swaps
by element id.
"""
htmx_ws_render(p; kwargs...) = @error "No implementation loaded for htmx_ws_render. Load HTMXObjects to enable HTML WebSocket rendering."
