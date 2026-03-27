module HTMXObjectsExt
import HTMXObjects: h, Node, fetchindex
import Treebars: htmx_render, htmx_render_children, ws_progress, polling_fetchindex,
    ProgressNode, StateProgress, root, is_running, is_finished, is_failed, duration, short_duration

# Duration suffix for a node's label
function _duration_suffix(sp::StateProgress)
    d = short_duration(duration(sp))
    if is_running(sp)
        " — $(d) so far"
    elseif is_failed(sp)
        " — failed ($(d))"
    else
        " — done ($(d))"
    end
end

# Render a StateProgress node as HTML
function htmx_render(node::ProgressNode{<:StateProgress}; kwargs...)
    sp = node.impl
    children_html = [htmx_render(child; kwargs...) for child in node.children]
    lock(sp.lock) do
        suffix = _duration_suffix(sp)
        if !isnothing(sp.N)
            # Progress bar with counter
            h.div(class="treebar-node")(
                h.div(class="treebar-header")(
                    h.span(class="treebar-description")(sp.description),
                    h.span(class="treebar-count")("$(sp.i) / $(sp.N)"),
                    !isempty(sp.message) ? h.span(class="treebar-message")(sp.message) : "",
                    h.span(class="treebar-duration")(suffix),
                ),
                h.progress(value=string(sp.i), max=string(sp.N), class="treebar-progress")(),
                children_html...,
            )
        elseif !isempty(sp.message)
            # Label node (key: value)
            h.div(class="treebar-label")(
                h.span(class="treebar-description")(sp.description),
                h.span(class="treebar-value")(sp.message),
            )
        else
            # Container node
            h.div(class="treebar-node")(
                !isempty(sp.description) ? h.div(class="treebar-header")(sp.description, suffix) : "",
                children_html...,
            )
        end
    end
end

# Render a full progress tree rooted at node
function htmx_render(node::ProgressNode; kwargs...)
    children_html = [htmx_render(child; kwargs...) for child in node.children]
    h.div(class="treebar-root")(children_html...)
end

node_to_html(node) = sprint(io -> show(io, MIME"text/html"(), node))

# Render just the children of a ProgressNode (for top-level substatus display)
htmx_render_children(::Nothing) = h.p("Starting..."; style="color:var(--pico-muted-color)", aria_busy="true")
function htmx_render_children(node::ProgressNode{<:StateProgress})
    sp = node.impl
    if isempty(node.children) && !isempty(sp.message)
        return h.div(
            h.span(sp.message; style="color:var(--pico-muted-color)"),
            h.span(" "; aria_busy="true"),
        )
    end
    isempty(node.children) && return h.p("Starting..."; style="color:var(--pico-muted-color)", aria_busy="true")

    children = collect(node.children)
    has_running = any(c -> is_running(c), children)

    rendered = map(children) do child
        if is_running(child)
            # Running children: always shown prominently
            htmx_render(child)
        elseif is_failed(child) && has_running
            # Failed with running siblings: suppress (retry in flight)
            nothing
        else
            # Finished or failed-with-no-running-siblings: collapsed <details>
            child_sp = child.impl
            label = child_sp.description
            suffix = _duration_suffix(child_sp)
            h.details(class="treebar-collapsed")(
                h.summary("$(label)$(suffix)"),
                htmx_render(child),
            )
        end
    end

    h.div(filter(!isnothing, rendered)...)
end

"""
    htmx_ws_render(node; id="treebar-progress")

Default `render` function for `ws_progress` when HTMXObjects is loaded.
Returns an HTML string with a stable `id` so the HTMX ws extension swaps by element id.

Client-side:
```html
<div hx-ext="ws" ws-connect="/ws/progress">
    <div id="treebar-progress"></div>
</div>
```
"""
htmx_ws_render(node; id="treebar-progress") = node_to_html(h.div(; id)(htmx_render(node)))

"""
    polling_fetchindex(render_result, ip, keys...; poll_url, label, rerun="", poll_interval="200ms", kwargs...)

Generic fetchindex + HTMX polling pattern. Returns either a self-polling
progress div (while the task is running), an error article (if failed),
or the result of `render_result(rv)` (when done).

- `render_result(rv)`: function that renders the final result (supports `do` syntax)
- `ip`: IndexableProperty (e.g. `app.pathfinder`)
- `keys...`: cache key(s) (variadic — supports multi-index like `f1, f2`)
- `poll_url`: URL to poll while running (use `query_url`)
- `label`: display label (e.g. "Pathfinder (my-model)")
- `rerun`: pass non-empty string to force re-computation
- `poll_interval`: HTMX polling interval (default "200ms")
- `kwargs...`: passed through to `fetchindex`
"""
function polling_fetchindex(render_result, ip, keys...; poll_url, label, rerun="", poll_interval="200ms", kwargs...)
    fetchindex(ip, keys...; force=!isempty(rerun), kwargs...) do rv, status
        if rv isa Task && istaskfailed(rv)
            err_str = try sprint(showerror, rv.result) catch; "$(typeof(rv.result)): $(rv.result)" end
            h.article(h.header("$label — failed"), h.pre(err_str))
        elseif rv isa Task
            h.div(; hx_get=poll_url, hx_trigger="every $poll_interval", hx_swap="morph:outerHTML",
                style="min-height:200px;")(
                h.article(h.header("$label — running..."), htmx_render_children(status))
            )
        else
            render_result(rv)
        end
    end
end

end
