module Baumkuchen

abstract type AbstractProgress end

struct Progress{P,I}
    parent::P
    info::I
end
Base.parent(x::Progress) = x.parent
info(x::Progress) = x.info

initialize_progress!(::Nothing, args...; kwargs...) = nothing
initialize_progress!(kind::Symbol, args...; kwargs...) = initialize_progress!(Val(kind), args...; kwargs...)
initialize_progress!(kind::Val, N; description="Running...", transient=false, kwargs...) = initialize_progress!(
    initialize_progress!(kind; kwargs...), N; description, transient, propagates=true
)
# initialize_progress!(kind::Val, N; kwargs...)

update_progress!(::Nothing, args...; kwargs...) = nothing
update_progress!(f::Function, ::Nothing, args...; kwargs...) = nothing
update_progress!(f::Function, args...; kwargs...) = update_progress!(args...; kwargs..., f()...)

fail_progress!(::Nothing, args...; kwargs...) = nothing

finalize_progress!(::Nothing, args...; kwargs...) = nothing

with_progress(f, args...; kwargs...) = begin 
    progress = initialize_progress!(args...; kwargs...)
    try
        return f(progress)
    catch e
        fail_progress!(progress, e)
        rethrow()
    finally
        finalize_progress!(progress)
    end
end

struct IncrementBy{di}
    IncrementBy(di) = new{di}()
end
# initialize_iterable_progress!(kind::Symbol, args...; kwargs...) = initialize_iterable_progress!(Val(kind), args...; kwargs...)
struct IterableProgress{P,W}
    progress::P
    wrapped::W
end
initialize_iterable_progress!(::Nothing, it; kwargs...) = it
initialize_iterable_progress!(progress, it; kwargs...) = IterableProgress(
    initialize_progress!(progress, length(it); kwargs...),
    it
)
Base.iterate(p::IterableProgress) = begin 
    update_progress!(p.progress, 0)
    iterate(p.wrapped)
end
Base.iterate(p::IterableProgress, state) = begin 
    update_progress!(p.progress, IncrementBy(1))
    iterate(p.wrapped, state)
end
finalize_progress!(p::IterableProgress) = finalize_progress!(p.progress)

struct ProgressNode{K,I,M}
    impl::I
    meta::M
    parent::Union{ProgressNode{K},Nothing}
    children::Set{ProgressNode{K}}
    ProgressNode(K, impl, meta; parent=nothing, children=Set{ProgressNode{K}}()) = begin
        rv = new{K,typeof(impl),typeof(meta)}(
            impl, meta, parent, children
        )
        isnothing(parent) || push!(parent.children, rv)
        rv
    end
end
kind(::ProgressNode{K}) where {K} = K
initialize_progress!(node::ProgressNode, args...; kwargs...) = ProgressNode(
    kind(node), initialize_progress!(node.impl, args...; kwargs...)...; parent=node
)
update_progress!(node::ProgressNode, args...; kwargs...) = update_progress!(node.impl, args...; kwargs...)
finalize_progress!(node::ProgressNode) = begin 
    finalize_progress!(node.impl)
    propagates_finalization(node) && finalize_progress!(node.parent)
end
propagates_finalization(node::ProgressNode) = node.meta.propagates

progress_expr(x) = x
progress_expr(x::Expr; progress) = if x.head == :for
    @assert length(x.args) == 2
    head, body = x.args
    @assert Meta.isexpr(head, :(=))
    lhs, rhs = head.args
    subprogress = gensym(:subprogress)
    quote 
        $subprogress = $initialize_iterable_progress!($progress, $rhs)
        try 
            for $lhs in $subprogress
                $body
            end
        catch e
            $fail_progress!($subprogress, e)
            rethrow()
        finally
            $finalize_progress!($subprogress)
        end
    end
    # Expr(:for, head, progress_expr(body))
else
    Expr(x.head, progress_expr.(x.args)...)
end

macro progress(args...)
    @assert length(args) == 2
    progress, body = args
    esc(progress_expr(body; progress))
end

end # module Baumkuchen
