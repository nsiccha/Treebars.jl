"""
    with_progress(f, kind, N; kwargs...)

Initialize progress, call `f(progress_node)`, finalize on completion or fail on error.
"""
function with_progress(f, args...; kwargs...)
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

struct IterableProgress{P,W}
    progress::P
    wrapped::W
end
function initialize_iterable_progress!(progress, it; kwargs...)
    IterableProgress(
        initialize_progress!(progress, length(it); kwargs...),
        it
    )
end
function Base.iterate(p::IterableProgress)
    update_progress!(p.progress, 0)
    iterate(p.wrapped)
end
function Base.iterate(p::IterableProgress, state)
    update_progress!(p.progress, IncrementBy(1))
    iterate(p.wrapped, state)
end
Base.length(p::IterableProgress) = length(p.wrapped)
Base.eltype(::Type{IterableProgress{P,W}}) where {P,W} = eltype(W)
Base.IteratorSize(::Type{IterableProgress{P,W}}) where {P,W} = Base.IteratorSize(W)
finalize_progress!(p::IterableProgress) = finalize_progress!(p.progress)

progress_expr(x; kwargs...) = x
progress_expr(x::Symbol; progress, kwargs...) = x == :__progress__ ? progress : x
function progress_expr(x::Expr; progress, transient=false)
    if x.head == :for
        subprogress = gensym(:subprogress)
        @assert length(x.args) == 2
        head, body = x.args
        body = progress_expr(body; progress=:($subprogress.progress), transient=true)
        @assert Meta.isexpr(head, :(=))
        lhs, rhs = head.args
        description = "for $lhs in ..."
        quote
            $subprogress = $initialize_iterable_progress!($progress, $rhs; description=$description, transient=$transient)
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
    else
        Expr(x.head, progress_expr.(x.args; progress, transient)...)
    end
end

"""
    @progress for i in 1:N ... end
    @progress backend for i in 1:N ... end

Wrap a `for` loop with automatic progress tracking. Rewrites the loop to call
`initialize_progress!`, `update_progress!`, and `finalize_progress!` automatically.
"""
macro progress(body)
    esc(progress_expr(body; progress=:($BACKEND[])))
end
macro progress(args...)
    @assert length(args) == 2
    progress, body = args
    esc(progress_expr(body; progress))
end
