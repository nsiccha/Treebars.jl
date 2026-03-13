struct IncrementBy{di}
    IncrementBy(di) = new{di}()
end

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
istransient(node::ProgressNode) = get(node.meta, :transient, false)
propagates_finalization(node::ProgressNode) = get(node.meta, :propagates, false)
labels(node::ProgressNode) = get(node.meta, :labels, nothing)

# Initialize a child progress node
initialize_progress!(node::ProgressNode, args...; kwargs...) = ProgressNode(
    initialize_progress!(node.impl, args...; kwargs...); parent=node
)

# Update: forward to impl, then handle kwargs as labeled sub-nodes
update_progress!(node::ProgressNode; kwargs...) = update_progress!(node, IncrementBy(1); kwargs...)
update_progress!(node::ProgressNode, i; kwargs...) = begin
    update_progress!(node.impl, i)
    _update_labels!(node; kwargs...)
end
update_progress!(node::ProgressNode, ::Nothing; kwargs...) = _update_labels!(node; kwargs...)
update_progress!(node::ProgressNode, msg::AbstractString; kwargs...) = begin
    update_progress!(node.impl, msg)
    _update_labels!(node; kwargs...)
end

# Handle kwargs as labeled child nodes (like WarmupHMC's labels pattern)
_update_labels!(node::ProgressNode; kwargs...) = begin
    labs = labels(node)
    isnothing(labs) && isempty(kwargs) && return node
    for (key, value) in pairs(kwargs)
        skey = replace(string(key), "_" => " ")
        description = "$skey:"
        sjob = if !isnothing(labs)
            get(labs, key, nothing)
        else
            nothing
        end
        if isnothing(sjob)
            sjob = initialize_progress!(node; description, key, value=string(value), transient=false)
            !isnothing(labs) && (labs[key] = sjob)
        else
            update_progress!(sjob, string(value))
        end
    end
    node
end

fail_progress!(node::ProgressNode, args...; kwargs...) = fail_progress!(node.impl, args...; kwargs...)

finalize_progress!(node::ProgressNode) = begin
    finalize_progress!(node.impl)
    isnothing(node.parent) || pop!(node.parent.children, node)
    for child in collect(node.children)
        finalize_progress!(child)
    end
    propagates_finalization(node) && finalize_progress!(node.parent)
end

# StateProgress: a thread-safe progress backend that stores state for inspection.
# Useful for remote/web progress (HTMXObjects, polling, etc.)
mutable struct StateProgress
    lock::ReentrantLock
    description::String
    N::Union{Int,Nothing}
    i::Int
    message::String
    labels::Dict{Symbol,Any}
    running::Bool
    failed::Bool
    StateProgress(; description="Running...", N=nothing) = new(
        ReentrantLock(), description, N, 0, "", Dict{Symbol,Any}(), true, false
    )
end

initialize_progress!(::Val{:state}; kwargs...) = ProgressNode(
    StateProgress(; kwargs...), (;propagates=false, labels=Dict{Symbol,Any}())
)
initialize_progress!(sp::StateProgress, N::Integer; description="Running...", transient=false, propagates=false, key=nothing, value="", kwargs...) = begin
    child = StateProgress(; description, N)
    child.message = value
    child
end
initialize_progress!(sp::StateProgress; description="Running...", transient=false, propagates=false, key=nothing, value="", kwargs...) = begin
    child = StateProgress(; description)
    child.message = value
    child
end

update_progress!(sp::StateProgress, i::Integer) = lock(sp.lock) do
    if isnothing(sp.N)
        sp.message = string(i)
    else
        sp.i = clamp(i, 0, sp.N)
    end
end
update_progress!(sp::StateProgress, ::IncrementBy{di}) where {di} = lock(sp.lock) do
    sp.i = isnothing(sp.N) ? sp.i + di : clamp(sp.i + di, 0, sp.N)
end
update_progress!(sp::StateProgress, msg::AbstractString) = lock(sp.lock) do
    sp.message = msg
end
update_progress!(sp::StateProgress, ::Nothing) = nothing

fail_progress!(sp::StateProgress, args...; kwargs...) = lock(sp.lock) do
    sp.failed = true
end
finalize_progress!(sp::StateProgress) = lock(sp.lock) do
    sp.running = false
end
