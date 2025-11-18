module Baumkuchen

struct Progress{P,I}
    parent::P
    info::I
end
Base.parent(x::Progress) = x.parent
info(x::Progress) = x.info

initialize_progress!(args...; kwargs...) = nothing
update_progress!(args...; kwargs...) = nothing
fail_progress!(args...; kwargs...) = nothing
finalize_progress!(args...; kwargs...) = nothing

update_progress!(f::Function, ::Nothing, args...; kwargs...) = nothing
update_progress!(f::Function, args...; kwargs...) = update_progress!(args...; kwargs..., f()...)

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


end # module Baumkuchen
