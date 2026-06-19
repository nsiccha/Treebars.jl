module Treebars

using Dates: DateTime, Millisecond, now, canonicalize, CompoundPeriod
using OrderedCollections: OrderedSet, OrderedDict

export @progress, @with_progress, with_progress, with_prepared_progress, with_prepared_phases, progress_map,
    initialize_progress!, update_progress!, fail_progress!, finalize_progress!,
    add_child!,
    ProgressNode, StateProgress, htmx_render, htmx_render_children, htmx_treebar_styles, htmx_treebar_script, ws_progress, htmx_ws_render,
    polling_fetchindex,
    is_pending, is_running, is_finished, is_failed, is_displayed, duration, short_duration,
    prepare_progress!, start_progress!,
    round2, short_string, Fraction

BACKEND = Ref{Any}(nothing)

include("threadsafe.jl")
include("interface.jl")
include("implementation.jl")
function round2 end
function short_string end
include("formatting.jl")
include("convenience.jl")

"""
    polling_fetchindex(render_result, ip, keys...; kwargs...)

Generic fetchindex + HTMX polling + progress rendering pattern. Implementation
lives in the HTMXObjects package extension — load `HTMXObjects` to activate
it.

Renders the running progress tree inside a `.treebar-poller` wrapper; each
poll only swaps the inner fragment, so pill toggle state on the wrapper
survives across polls. Three response shapes are handled automatically:

- the IP's value is a still-running `Task` → renders the progress tree (and
  an optional Stop button if `cancel_url` is provided);
- the `Task` failed → re-throws so HTMXObjects' route-error machinery renders
  the exception as an error article and the polling loop stops naturally;
- the value is done → calls `render_result(rv)`.

Common kwargs:

- `poll_url::String` — URL to poll while running (use `query_url`).
- `label::String` — label shown in the running-state article header.
- `cancel_url::String` — optional URL for a "Stop" button.
- `poll_interval::String` — HTMX polling interval (default `"200ms"`).
- `force::Bool` — passed through to `fetchindex`; default `false`.

See the HTMXObjects extension source for the full call signature.
"""
function polling_fetchindex end

end # module Treebars
