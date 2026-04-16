struct IncrementBy{di}
    IncrementBy(di) = new{di}()
end

struct ProgressNode{I,M,C}
    impl::I
    meta::M
    parent::Union{ProgressNode,Nothing}
    children::C
    function ProgressNode(impl, meta=(;propagates=false); parent=nothing, children=ThreadsafeSet{ProgressNode}())
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
function initialize_progress!(node::ProgressNode, args...; transient=false, propagates=false, kwargs...)
    ProgressNode(
        initialize_progress!(node.impl, args...; transient, propagates, kwargs...),
        (; propagates, transient, labels=ThreadsafeDict{Symbol,Any}());
        parent=node
    )
end

# Update: forward to impl, then handle kwargs as labeled sub-nodes
update_progress!(node::ProgressNode; kwargs...) = update_progress!(node, IncrementBy(1); kwargs...)
function update_progress!(node::ProgressNode, i; kwargs...)
    update_progress!(node.impl, i)
    _update_labels!(node; kwargs...)
end
update_progress!(node::ProgressNode, ::Nothing; kwargs...) = _update_labels!(node; kwargs...)
function update_progress!(node::ProgressNode, msg::AbstractString; kwargs...)
    update_progress!(node.impl, msg)
    _update_labels!(node; kwargs...)
end

# Handle kwargs as labeled child nodes (like WarmupHMC's labels pattern)
function _update_labels!(node::ProgressNode; kwargs...)
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

function fail_progress!(node::ProgressNode, args...; kwargs...)
    fail_progress!(node.impl, args...; kwargs...)
    # collect() snapshot — a child failing may mutate node.children mid-walk
    for child in node.children
        isrunning(child) && fail_progress!(child, args...; kwargs...)
    end
    propagates_finalization(node) && !isnothing(node.parent) && isrunning(node.parent) && fail_progress!(node.parent, args...; kwargs...)
    # Intentional asymmetry with finalize_progress!: failed transient nodes stay
    # pinned to their parent so htmx_render_children's "N failed" pill can show
    # them until the user retries (which clears the DO cache entry).
end

function finalize_progress!(node::ProgressNode)
    finalize_progress!(node.impl)
    # collect() snapshot — a transient child detaches itself mid-walk
    for child in node.children
        isrunning(child) && finalize_progress!(child)
    end
    propagates_finalization(node) && !isnothing(node.parent) && isrunning(node.parent) && finalize_progress!(node.parent)
    if istransient(node) && !isnothing(node.parent)
        pop!(node.parent.children, node, nothing)
    end
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
    started_at::DateTime
    finalized_at::Union{DateTime,Nothing}
    StateProgress(; description="Running...", N=nothing) = new(
        ReentrantLock(), description, N, 0, "", Dict{Symbol,Any}(), true, false, now(), nothing
    )
end

is_running(s::StateProgress) = isnothing(s.finalized_at)
is_finished(s::StateProgress) = !isnothing(s.finalized_at) && !s.failed
is_failed(s::StateProgress) = !isnothing(s.finalized_at) && s.failed
duration(s::StateProgress) = something(s.finalized_at, now()) - s.started_at

is_running(node::ProgressNode{<:StateProgress}) = is_running(node.impl)
is_finished(node::ProgressNode{<:StateProgress}) = is_finished(node.impl)
is_failed(node::ProgressNode{<:StateProgress}) = is_failed(node.impl)
duration(node::ProgressNode{<:StateProgress}) = duration(node.impl)

isrunning(node::ProgressNode{<:StateProgress}) = is_running(node.impl)
isrunning(node::ProgressNode) = true

initialize_progress!(::Val{:state}; kwargs...) = ProgressNode(
    StateProgress(; kwargs...), (;propagates=false, labels=ThreadsafeDict{Symbol,Any}())
)
function initialize_progress!(sp::StateProgress, N::Integer; description="Running...", transient=false, propagates=false, key=nothing, value="", kwargs...)
    child = StateProgress(; description, N)
    child.message = value
    child
end
function initialize_progress!(sp::StateProgress; description="Running...", transient=false, propagates=false, key=nothing, value="", kwargs...)
    child = StateProgress(; description)
    child.message = value
    child
end

function update_progress!(sp::StateProgress, i::Integer)
    lock(sp.lock) do
        if isnothing(sp.N)
            sp.message = string(i)
        else
            sp.i = clamp(i, 0, sp.N)
        end
    end
end
function update_progress!(sp::StateProgress, ::IncrementBy{di}) where {di}
    lock(sp.lock) do
        sp.i = isnothing(sp.N) ? sp.i + di : clamp(sp.i + di, 0, sp.N)
    end
end
function update_progress!(sp::StateProgress, msg::AbstractString)
    lock(sp.lock) do
        sp.message = msg
    end
end
update_progress!(sp::StateProgress, ::Nothing) = nothing

function fail_progress!(sp::StateProgress, args...; kwargs...)
    lock(sp.lock) do
        sp.failed = true
        sp.running = false
        sp.finalized_at = now()
    end
end
function finalize_progress!(sp::StateProgress)
    lock(sp.lock) do
        sp.running = false
        sp.finalized_at = now()
    end
end

# JSON-serializable snapshot (non-exported — prefer working with ProgressNode directly)
function progress_state(sp::StateProgress)
    lock(sp.lock) do
        Dict{String,Any}(
            "description" => sp.description,
            "N" => sp.N,
            "i" => sp.i,
            "message" => sp.message,
            "running" => sp.running,
            "failed" => sp.failed,
            "started_at" => string(sp.started_at),
            "finalized_at" => isnothing(sp.finalized_at) ? nothing : string(sp.finalized_at),
        )
    end
end
function progress_state(node::ProgressNode{<:StateProgress})
    d = progress_state(node.impl)
    if !isempty(node.children)
        d["children"] = [progress_state(child) for child in node.children]
    end
    d
end
function progress_state(node::ProgressNode)
    d = Dict{String,Any}("type" => string(typeof(node.impl)))
    if !isempty(node.children)
        d["children"] = [progress_state(child) for child in node.children]
    end
    d
end
progress_state(::Nothing) = nothing
