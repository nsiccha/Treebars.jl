module Treebars

export @progress, with_progress,
    initialize_progress!, update_progress!, fail_progress!, finalize_progress!,
    ProgressNode, htmx_render

BACKEND = Ref{Any}(nothing)

include("interface.jl")
include("implementation.jl")
include("convenience.jl")

end # module Treebars
