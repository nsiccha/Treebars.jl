# Push-transport plumbing shared by `ws_progress` (HTTP extension),
# `sse_progress` (below) and the HTMXObjects extension's WebSocket
# `polling_fetchindex` and `sse_fetchindex`. Transport-free: a stream is an
# `emit(frame)::Bool` callback that returns `false` once the client has gone.

# Terminal = finished, failed or skipped — exactly the states with
# `finalized_at` set. A pending node is not terminal: it has yet to run, so a
# stream watching it must keep going.
_is_terminal(sp::StateProgress) = lock(() -> !isnothing(sp.finalized_at), sp.lock)
_is_terminal(node::ProgressNode{<:StateProgress}) = _is_terminal(node.impl)
_is_terminal(::ProgressNode) = false   # no lifecycle to read: the handle ends the stream
_is_terminal(::Nothing) = false

# Has a compute handle settled? `Task` is the legacy handle; anything else is
# duck-typed on `isready`, like the polling path. A failed DynamicObjects
# `Pending` never reports ready; its status node turns failed instead, which
# `_is_terminal` sees.
_is_settled(::Nothing) = false
_is_settled(t::Task) = istaskdone(t)
_is_settled(h) = applicable(isready, h) && isready(h)

# Cheap change detector for a whole tree: each node's identity and `version`.
# Attaching or detaching a child changes the identity sequence; every state
# change bumps a `version`. Walking the tree is orders of magnitude cheaper than
# rendering it, so a frame loop renders only when this moves.
function _tree_fingerprint(node::ProgressNode, h::UInt=UInt(0))
    h = hash(_version(node.impl), hash(objectid(node.impl), h))
    for child in node.children
        h = _tree_fingerprint(child, h)
    end
    h
end
_version(sp::StateProgress) = lock(() -> sp.version, sp.lock)
_version(_) = time_ns()   # no counter to consult: always report a change

# A running node's elapsed time (and ETA) is the only part of a frame that
# changes by itself, and the client ticks it locally from `data-elapsed-ms` /
# `data-eta-ms` (see `htmx_treebar_script`). Frames that differ only there are
# the same frame, so they compare equal after this strips them.
const _RUNNING_DURATION = r"(<span class=\"treebar-duration\" data-treebar-status=\"running\")[^>]*>[^<]*(</span>)"
_frame_signature(frame::AbstractString) = replace(frame, _RUNNING_DURATION => s"\1>\2")
_frame_signature(frame) = frame

# Re-render at least this often even when the fingerprint has not moved: a
# safety net for state changed without going through the Treebars mutators
# (which is what bumps `version`). An unchanged render is still not sent.
const _FRAME_REFRESH_SECONDS = 1.0

# Push `render(node)` frames through `emit` until `node` is terminal or the
# `done` handle settles, rendering only when the tree changed and sending only
# when the frame changed. With `final=true` the terminal state is sent last (if
# it differs from the last frame). Returns `true` when the stream ran to its
# end, `false` as soon as `emit` reports the client gone. A pending node is
# streamed like a running one: it is not terminal yet.
function _stream_frames(emit, node; interval=0.1, render, done=nothing, final=false)
    last_frame = nothing   # signature of the last frame sent
    last_fingerprint = nothing
    last_render = 0.0
    pollint = clamp(interval / 10, 0.001, 0.01)
    while !(_is_terminal(node) || _is_settled(done))
        fingerprint = _tree_fingerprint(node)
        if fingerprint != last_fingerprint || time() - last_render >= _FRAME_REFRESH_SECONDS
            last_fingerprint, last_render = fingerprint, time()
            frame = render(node)
            signature = _frame_signature(frame)
            if signature != last_frame
                emit(frame) || return false
                last_frame = signature
            end
        end
        _pace(done, interval, pollint)
    end
    if final
        frame = render(node)
        _frame_signature(frame) == last_frame || emit(frame) || return false
    end
    true
end

# Wait out one frame interval. With a handle, wake as soon as it settles so the
# terminal frame follows the compute's completion instead of the next tick.
_pace(::Nothing, interval, _) = sleep(interval)
_pace(done, interval, pollint) = timedwait(() -> _is_settled(done), interval; pollint)

# `emit` for a WebSocket (defined in the HTTP extension): send one frame,
# returning `false` instead of throwing once the client has gone.
function _ws_emit end

# --- Server-sent events ------------------------------------------------------
#
# The SSE transport targets a plain `IO` whose response headers the caller has
# already written. Treebars never writes headers, never closes the `io` and
# never sends keep-alive comments. Each frame goes out as ONE `write` of one
# `String`, so a caller that serialises writes (e.g. against its own
# heartbeat) can never see a frame split.

function _check_sse_event(event::AbstractString)
    (occursin('\n', event) || occursin('\r', event)) &&
        throw(ArgumentError("SSE event name must not contain a line break: $(repr(event))"))
    event
end

# One complete `text/event-stream` frame: `event: <name>`, one `data:` line per
# line of `data`, then the blank line that ends the event. Every line break is
# a data-line boundary — `\r\n` and a lone `\r` included, as the SSE parser
# treats them — so the browser rejoins the lines with `\n` and gets the payload
# back intact.
function _sse_frame(event::AbstractString, data::AbstractString)
    io = IOBuffer()
    print(io, "event: ", _check_sse_event(event), '\n')
    for line in split(data, r"\r\n|\r|\n")
        print(io, "data: ", line, '\n')
    end
    print(io, '\n')
    String(take!(io))
end

# `emit` for an SSE stream. A write that throws means the client went away:
# report it, never the compute's business.
function _sse_emit(io::IO, event::AbstractString, data::AbstractString)
    frame = _sse_frame(event, data)
    try
        write(io, frame)
        true
    catch err
        @debug "Treebars: SSE write failed; client disconnected" exception=(err, catch_backtrace())
        false
    end
end

"""
    sse_progress(io, node; interval=0.1, render=repr, event="progress", done=nothing)

Stream live progress as server-sent events on `io` until `node` is terminal
(finished, failed or skipped) or the optional `done` handle settles; a pending
node keeps the stream going. Needs no package extension.

`io` is the open event-stream response: its headers must already be written.
`sse_progress` never writes headers, never closes `io` and sends no keep-alive
comments. Each frame is written with a single `write(io, frame::String)`:

    event: <event>
    data: <first line of render(node)>
    data: <second line …>
    <blank line>

`render(node)` returns the `String` payload; it may span lines. Like
[`ws_progress`](@ref), the tree is re-rendered only when it changed, a frame is
sent only when it differs from the last one (a running node's elapsed time and
ETA do not count), and the terminal state is sent last, as one more `event`
frame.

A write that throws means the client disconnected: the stream stops quietly
(logged at `@debug`) and never touches the compute. Returns `nothing` either
way, so it is safe as the last expression of a route body whose return value
would be sent to the client.

With `HTMXObjects` loaded, [`sse_fetchindex`](@ref) with
[`htmx_sse_container`](@ref) renders the frames, the result and failures for
you.
"""
function sse_progress(io::IO, node::ProgressNode{<:StateProgress};
        interval=0.1, render=repr, event::AbstractString="progress", done=nothing)
    _check_sse_event(event)
    _stream_frames(frame -> _sse_emit(io, event, frame), node; interval, render, done, final=true)
    nothing
end
