module HTMXObjectsExt
import HTMXObjects: h, Node
import DynamicObjects: fetchindex
import Treebars: htmx_render, htmx_render_children, ws_progress, polling_fetchindex, progress_state, ProgressNode, StateProgress, root

# Render a StateProgress node as HTML
htmx_render(node::ProgressNode{<:StateProgress}; kwargs...) = begin
    sp = node.impl
    children_html = [htmx_render(child; kwargs...) for child in node.children]
    lock(sp.lock) do
        if !isnothing(sp.N)
            # Progress bar with counter
            h.div(class="treebar-node")(
                h.div(class="treebar-header")(
                    h.span(class="treebar-description")(sp.description),
                    h.span(class="treebar-count")("$(sp.i) / $(sp.N)"),
                    !isempty(sp.message) ? h.span(class="treebar-message")(sp.message) : "",
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
                !isempty(sp.description) ? h.div(class="treebar-header")(sp.description) : "",
                children_html...,
            )
        end
    end
end

# Render a full progress tree rooted at node
htmx_render(node::ProgressNode; kwargs...) = begin
    children_html = [htmx_render(child; kwargs...) for child in node.children]
    h.div(class="treebar-root")(children_html...)
end

node_to_html(node) = sprint(io -> show(io, MIME"text/html"(), node))

# Render a progress_state() Dict tree as HTML (for polling pattern)
htmx_render(state::Dict; depth=0) = begin
    children = get(state, "children", [])
    N = get(state, "N", nothing)
    i = get(state, "i", 0)
    desc = get(state, "description", "")
    msg = get(state, "message", "")

    parts = []
    if !isempty(desc)
        push!(parts, h.div(class="treebar-node", style="margin-left:$(depth)rem")(
            h.div(class="treebar-header")(
                h.strong(desc, ": "),
                isnothing(N) ? h.span(class="treebar-message")(msg) : h.span(class="treebar-count")(string(i), " / ", string(N)),
            ),
            isnothing(N) ? "" : h.progress(value=string(i), max=string(N), class="treebar-progress")(),
        ))
    end
    for child in children
        push!(parts, htmx_render(child; depth=depth+1))
    end
    h.div(parts...)
end

# Render just the children of a progress_state() Dict (for top-level substatus nodes)
htmx_render_children(state) = begin
    isnothing(state) && return h.p("Starting..."; style="color:var(--pico-muted-color)", aria_busy="true")
    children = get(state, "children", [])
    root_msg = get(state, "message", "")
    if isempty(children) && !isempty(root_msg)
        return h.div(
            h.span(root_msg; style="color:var(--pico-muted-color)"),
            h.span(" "; aria_busy="true"),
        )
    end
    isempty(children) && return h.p("Starting..."; style="color:var(--pico-muted-color)", aria_busy="true")
    h.div([htmx_render(cs) for cs in children]...)
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
            state = progress_state(status)
            h.div(; hx_get=poll_url, hx_trigger="every $poll_interval", hx_swap="morph:outerHTML",
                style="min-height:200px;")(
                h.article(h.header("$label — running..."), htmx_render_children(state))
            )
        else
            render_result(rv)
        end
    end
end

end
