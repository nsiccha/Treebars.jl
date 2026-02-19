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
struct IterableProgress{P,W}
    progress::P
    wrapped::W
end
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

progress_expr(x; kwargs...) = x
progress_expr(x::Symbol; progress, kwargs...) = x == :__progress__ ? progress : x
progress_expr(x::Expr; progress, transient=false) = if x.head == :for
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

macro progress(body)
    esc(progress_expr(body; progress=:($BACKEND[])))
end
macro progress(args...)
    @assert length(args) == 2
    progress, body = args
    esc(progress_expr(body; progress))
end