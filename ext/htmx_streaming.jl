"""
    htmx_ws_render(node; id="treebar-progress")

Default `render` function for `ws_progress` when HTMXObjects is loaded.
Returns an HTML string with a stable `id` so the HTMX ws extension swaps by element id.

Client-side:
```html
<div hx-ext="ws" ws-connect="/ws/progress">
    <div id="treebar-progress"></div>
</div>
```
"""
# A WebSocket frame replaces its whole `<div id>` on every update. The frame is
# its tree's pill scope — the tree renders unscoped below it, as under a
# poller — and htmx_treebar_script copies a viewer's pill toggles from each
# frame onto the next frame with the same id. Its leading freshness span is
# where the script says the stream has gone stale or its socket is lost; the
# last frame stays on screen when no more arrive.
_ws_frame(node, t::TreebarTexts; id, phase_overview::Union{Bool,Symbol}=false) =
    h.div(; id, class="treebar-ws-frame", _PILL_DEFAULTS..., data_treebar_texts=_client_texts_attr(t))(
        _freshness_span(), _htmx_render(node, t; scoped=false, phase_overview))

htmx_ws_render(node::ProgressNode; id="treebar-progress", phase_overview::Union{Bool,Symbol}=false, texts=nothing) =
    node_to_html(_ws_frame(node, _texts(texts); id, phase_overview))

function htmx_ws_progress(content; url::AbstractString, id::AbstractString,
        progress=nothing, description=nothing, N=nothing, collapsed::Bool=false, phase_overview::Union{Bool,Symbol}=false,
        texts=nothing)
    isempty(id) && throw(ArgumentError("htmx_ws_progress requires a nonempty unique id"))
    t = _texts(texts)
    node = isnothing(progress) ?
        initialize_progress!(:state; description=something(description, t.working), N, pending=true) : progress
    h.div(; hx_ext="ws", ws_connect=url)(
        content,
        h.details(; id=id * "-disclosure", open=(collapsed ? nothing : true))(
            h.summary(t.progress),
            _ws_frame(node, t; id=id * "-progress", phase_overview)),
        h.div(; id=id * "-updates")(),
    )
end

_ws_progress_root(::Nothing, N; description) = initialize_progress!(:state; description, N)
_ws_progress_root(parent::ProgressNode, N; description) =
    initialize_progress!(parent, N; description, transient=false)

function _validate_ws_progress(id, interval, min_interval, buffer)
    isempty(id) && throw(ArgumentError("ws_progress requires a nonempty unique id"))
    interval > 0 || throw(ArgumentError("ws_progress interval must be positive"))
    min_interval >= 0 || throw(ArgumentError("ws_progress min_interval must be nonnegative"))
    buffer > 0 || throw(ArgumentError("ws_progress buffer must be positive"))
end

# A published fragment carrying `hx-swap-oob` targets an element OUTSIDE the
# stream sink. The htmx ws extension runs oobSwap over TOP-LEVEL message
# children only, so such a node must be delivered as a top-level sibling —
# nested inside the `<id>-updates` wrapper it lands verbatim in the sink
# (snag ws-progress-publ-d1b74c9b). HTMX hyphenates builder kwargs, so
# `hx_swap_oob=...` is stored as `Symbol("hx-swap-oob")`; the `data-` prefixed
# spelling is htmx-equivalent and honored too. Raw/String fragments always sink.
_is_oob_fragment(f) = f isa Node &&
    (haskey(f.attrs, Symbol("hx-swap-oob")) || haskey(f.attrs, Symbol("data-hx-swap-oob")))

function _ws_progress_frame(id, progress, fragments, t::TreebarTexts; phase_overview::Union{Bool,Symbol}=false)
    payload = node_to_html(_ws_frame(progress, t; id=id * "-progress", phase_overview))
    isempty(fragments) && return payload
    plain = Any[]
    oob = Any[]
    for f in fragments
        if _is_oob_fragment(f)
            push!(oob, f)
        else
            push!(plain, f)
        end
    end
    isempty(plain) || (payload *= node_to_html(h.div(; id=id * "-updates")(plain)))
    for f in oob
        payload *= node_to_html(f)
    end
    payload
end

function ws_progress(produce::Function, ws::WebSocket; id::AbstractString,
        description=nothing, N=nothing, parent=nothing, interval=0.1, min_interval=0.016,
        buffer::Integer=64, phase_overview::Union{Bool,Symbol}=false, texts=nothing)
    _validate_ws_progress(id, interval, min_interval, buffer)
    t = _texts(texts)
    node = _ws_progress_root(parent, N; description=something(description, t.working))
    ws_progress(produce, ws, node; id, interval, min_interval, buffer, phase_overview, texts=t)
end

# The texts are resolved here, in the route's own task: the sender below runs
# on another task, which cannot see the answer's language.
function ws_progress(produce::Function, ws::WebSocket, node::ProgressNode{<:StateProgress};
        id::AbstractString, interval=0.1, min_interval=0.016, buffer::Integer=64,
        phase_overview::Union{Bool,Symbol}=false, texts=nothing)
    _validate_ws_progress(id, interval, min_interval, buffer)
    t = _texts(texts)
    (is_pending(node) || is_running(node)) ||
        throw(ArgumentError("ws_progress producer requires a pending or running node"))
    start_progress!(node)
    queue = Channel{Any}(buffer)
    # Publishing and finishing wake the sender, so a fragment and the final
    # tree leave as soon as the sender is free, not at the next `interval`.
    wake = Base.Event(true)
    connected = Threads.Atomic{Bool}(true)
    publish = fragment -> begin
        connected[] || return nothing
        try
            put!(queue, fragment)
        catch err
            # Closing the queue releases a blocked publisher on disconnect.
            connected[] && rethrow()
            err isa InvalidStateException || rethrow()
        end
        notify(wake)
        nothing
    end
    # Render outside the send catch: serialization errors are not disconnects.
    initial = htmx_ws_render(node; id=id * "-progress", phase_overview, texts=t)
    try
        send(ws, initial)
    catch err
        connected[] = false
        close(queue)
        @debug "ws_progress client disconnected before production" exception=(err, catch_backtrace())
    end
    producer = Threads.@spawn begin
        try
            produce(publish, node)
        catch err
            fail_progress!(node, err)
            rethrow()
        finally
            finalize_progress!(node)
            notify(wake)
        end
    end
    render_live = progress -> begin
        # Everything published before this point rides this frame.
        reset(wake)
        fragments = Any[]
        for _ in 1:buffer
            isready(queue) || break
            push!(fragments, take!(queue))
        end
        _ws_progress_frame(id, progress, fragments, t; phase_overview)
    end
    result = nothing
    try
        # The route's own task is sticky to one thread, which a producer that
        # never yields can occupy until it finishes. The sender gets its own
        # task, free to run on any idle thread (the interactive pool if any).
        connected[] && fetch(Threads.@spawn :interactive ws_progress(ws, node;
            interval, min_interval, wake, render=render_live))
    finally
        connected[] = false
        isopen(queue) && close(queue)
        # Observe producer failures even when delivery or rendering failed.
        result = fetch(producer)
    end
    result
end
