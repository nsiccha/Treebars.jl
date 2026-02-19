
struct ProgressNode{I,M,C}
    impl::I
    meta::M
    parent::Union{ProgressNode,Nothing}
    children::C
    ProgressNode(impl, meta=(;propagates=false); parent=nothing, children=Set{ProgressNode}()) = begin
        rv = new{typeof(impl),typeof(meta),typeof(children)}(
            impl, meta, parent, children
        )
        isnothing(parent) || push!(parent.children, rv)
        rv
    end
end
root(node::ProgressNode) = isnothing(node.parent) ? node : root(node.parent)
initialize_progress!(node::ProgressNode, args...; kwargs...) = ProgressNode(
    initialize_progress!(node.impl, args...; kwargs...); parent=node
)
update_progress!(node::ProgressNode, args...; kwargs...) = update_progress!(node.impl, args...; kwargs...)
fail_progress!(node::ProgressNode, args...; kwargs...) = fail_progress!(node.impl, args...; kwargs...)
finalize_progress!(node::ProgressNode) = begin 
    finalize_progress!(node.impl)
    (istransient(node) && !isnothing(node.parent)) && pop!(node.parent.children, node)
    for child in node.children
        finalize_progress!(child)
    end
    propagates_finalization(node) && finalize_progress!(node.parent)
end
istransient(node::ProgressNode) = get(node.meta, :transient, false)
propagates_finalization(node::ProgressNode) = get(node.meta, :propagates, false)