module Treebars

export @progress, with_progress,
    initialize_progress!, update_progress!, fail_progress!, finalize_progress!,
    ProgressNode, StateProgress, htmx_render, htmx_render_children, ws_progress, htmx_ws_render,
    round2, short_string, Fraction,
    progress_state

BACKEND = Ref{Any}(nothing)

include("threadsafe.jl")
include("interface.jl")
include("implementation.jl")
function round2 end
function short_string end
include("formatting.jl")
include("convenience.jl")

end # module Treebars
