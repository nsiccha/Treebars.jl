"""
    initialize_progress!(kind::Symbol, N; description="Running...", kwargs...)
    initialize_progress!(parent::ProgressNode, N; description="Running...", kwargs...)

Create a progress root (from a backend symbol like `:state` or `:term`) or a child
node (from an existing `ProgressNode`). Returns a `ProgressNode`. No-op when `nothing`.

!!! warning "Prefer `@progress` or `with_progress` instead"
    Calling `initialize_progress!` / `update_progress!` / `finalize_progress!` manually
    is error-prone — forgetting `finalize_progress!` or missing exceptions leaves
    progress nodes stuck in the "running" state forever. Use the convenience API:

    ```julia
    # Best: automatic initialize + update + finalize for loops
    @progress parent for i in 1:N
        # ...
    end

    # Good: automatic finalize + fail handling via do-block
    with_progress(parent, N; description="...") do p
        for i in 1:N
            # ...
            update_progress!(p, i)
        end
    end
    ```

    See [`with_progress`](@ref), [`@progress`](@ref).
"""
initialize_progress!(::Nothing, args...; kwargs...) = nothing

"""
    update_progress!(node, i; kwargs...)
    update_progress!(node, message::AbstractString; kwargs...)

Update progress on `node`. Pass an integer to set the counter, a string for a status
message, or keyword arguments to create/update labeled child nodes. No-op when `nothing`.

See [`@progress`](@ref) and [`with_progress`](@ref) for wrappers that handle the
full initialize/update/finalize lifecycle automatically.
"""
update_progress!(::Nothing, args...; kwargs...) = nothing

"""
    fail_progress!(node; kwargs...)

Mark a progress node as failed. No-op when `nothing`.
"""
fail_progress!(::Nothing, args...; kwargs...) = nothing

"""
    finalize_progress!(node; kwargs...)

Mark a progress node as complete. No-op when `nothing`.

!!! warning "Prefer `@progress` or `with_progress` instead"
    Manual `finalize_progress!` is easy to forget or skip on exceptions. Use
    [`@progress`](@ref) or [`with_progress`](@ref) which handle finalization and
    failure automatically in a try/catch/finally block.
"""
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

# prepare_progress! / start_progress! no-ops for disabled + non-pending backends
"""
    prepare_progress!(parent, args...; kwargs...)

Create a child progress node in the **pending** state — appears in the tree but
not yet started. Call [`start_progress!`](@ref) to transition it to running.
Used by `@progress begin … end` to pre-enumerate phase markers.
"""
prepare_progress!(::Nothing, args...; kwargs...) = nothing

"""
    start_progress!(node)

Transition a pending progress node to running. Idempotent; no-op for backends
without a pending concept.
"""
start_progress!(::Nothing) = nothing
start_progress!(::Any) = nothing

# htmx_render fallback
htmx_render(p; kwargs...) = error("No implementation loaded for htmx_render($(typeof(p)); kwargs...)")

# htmx_render_children — implemented in HTMXObjectsExt
function htmx_render_children end

# htmx_treebar_styles — returns a <style> Node with all treebar CSS classes
function htmx_treebar_styles end

# ws_progress fallback
ws_progress(ws, p; kwargs...) = @error "No implementation loaded for ws_progress. Load HTTP to enable WebSocket progress."

# htmx_ws_render fallback
htmx_ws_render(p; kwargs...) = @error "No implementation loaded for htmx_ws_render. Load HTMXObjects to enable HTML WebSocket rendering."
