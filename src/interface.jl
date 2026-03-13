# No-op defaults for nothing (disabled progress)
initialize_progress!(::Nothing, args...; kwargs...) = nothing
update_progress!(::Nothing, args...; kwargs...) = nothing
fail_progress!(::Nothing, args...; kwargs...) = nothing
finalize_progress!(::Nothing, args...; kwargs...) = nothing

# Symbol dispatch: initialize_progress!(:term, ...) → initialize_progress!(Val(:term), ...)
initialize_progress!(kind::Symbol, args...; kwargs...) = initialize_progress!(Val(kind), args...; kwargs...)
# Convenience: initialize_progress!(Val(:term), N; description=...) creates root + child in one call
initialize_progress!(kind::Val, args...; description="Running...", transient=false, kwargs...) = initialize_progress!(
    initialize_progress!(kind; kwargs...), args...; description, transient, propagates=true
)
# Error fallbacks
initialize_progress!(p, args...; kwargs...) = @error "No implementation loaded for initialize_progress!($(typeof(p)), args...; kwargs...)"
initialize_progress!(p::Val; kwargs...) = @error "No implementation loaded for initialize_progress!($(typeof(p)); kwargs...)"

# Function-form update: update_progress!(f::Function, progress, ...) merges f() into kwargs
update_progress!(f::Function, ::Nothing, args...; kwargs...) = nothing
update_progress!(f::Function, args...; kwargs...) = update_progress!(args...; kwargs..., f()...)

# Fallback errors
update_progress!(p, args...; kwargs...) = @error "No implementation loaded for update_progress!($(typeof(p)), args...; kwargs...)"
fail_progress!(p, args...; kwargs...) = @debug "No implementation loaded for fail_progress!($(typeof(p)), args...; kwargs...)"
finalize_progress!(p, args...; kwargs...) = @error "No implementation loaded for finalize_progress!($(typeof(p)), args...; kwargs...)"

# htmx_render fallback
htmx_render(p; kwargs...) = @error "No implementation loaded for htmx_render($(typeof(p)); kwargs...)"
