module HTMXObjectsExt
import HTMXObjects: h, Node
import Treebars: htmx_render, htmx_render_children, ws_progress, ProgressNode, StateProgress, root

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

end
