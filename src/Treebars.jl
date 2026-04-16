module Treebars

using Dates: DateTime, now, canonicalize, CompoundPeriod
using OrderedCollections: OrderedSet, OrderedDict

export @progress, with_progress,
    initialize_progress!, update_progress!, fail_progress!, finalize_progress!,
    add_child!,
    ProgressNode, StateProgress, htmx_render, htmx_render_children, htmx_treebar_styles, ws_progress, htmx_ws_render,
    polling_fetchindex,
    is_running, is_finished, is_failed, duration, short_duration,
    round2, short_string, Fraction

BACKEND = Ref{Any}(nothing)

include("threadsafe.jl")
include("interface.jl")
include("implementation.jl")
function round2 end
function short_string end
include("formatting.jl")
include("convenience.jl")

function polling_fetchindex end

end # module Treebars
