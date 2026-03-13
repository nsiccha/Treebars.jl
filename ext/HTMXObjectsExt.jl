module HTMXObjectsExt
import HTMXObjects: h, Node
import Treebars: htmx_render, ProgressNode, StateProgress, root

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

end
