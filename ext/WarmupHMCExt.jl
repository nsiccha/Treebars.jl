module WarmupHMCExt
import WarmupHMC, Treebars

WarmupHMC.initialize_progress!(::Union{Val{:treebars},Val{Treebars}}, args...; kwargs...) = Treebars.initialize_progress!(args...; kwargs...)
WarmupHMC.initialize_progress!(p::Treebars.ProgressNode, args...; kwargs...) = Treebars.initialize_progress!(
    p, args...; kwargs...
)
WarmupHMC.update_progress!(p::Treebars.ProgressNode, args...; kwargs...) = Treebars.update_progress!(
    p, args...; kwargs...
)
WarmupHMC.fail_progress!(p::Treebars.ProgressNode, args...; kwargs...) = Treebars.fail_progress!(
    p, args...; kwargs...
)
WarmupHMC.finalize_progress!(p::Treebars.ProgressNode, args...; kwargs...) = Treebars.finalize_progress!(
    p, args...; kwargs...
)


end