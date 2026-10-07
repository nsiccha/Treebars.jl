module HTTPExt

import HTTP.WebSockets: WebSocket, send
import Treebars: ws_progress, ProgressNode, StateProgress

"""
    ws_progress(ws, node; interval=0.1, render=repr, wake=nothing, min_interval=0)

Push live progress updates over a WebSocket until the node finalizes.

By default sends `repr(node)`. Use `render=htmx_ws_render` for HTML output
when HTMXObjects is loaded.

The `render` function takes a `ProgressNode` and returns a `String` to send.

A frame is sent `interval` seconds after the previous one. Pass a
`Base.Event` as `wake` to send the next frame as soon as it is notified
instead, but never sooner than `min(min_interval, interval)` seconds after the
previous frame, so a burst of notifications coalesces into one frame.
"""
function ws_progress(ws::WebSocket, node::ProgressNode{<:StateProgress};
        interval=0.1, render=repr, wake::Union{Nothing,Base.Event}=nothing, min_interval=0)
    min_interval >= 0 || throw(ArgumentError("ws_progress min_interval must be nonnegative"))
    while node.impl.running
        payload = render(node)
        try; send(ws, payload); catch; break; end
        _await_next_frame(wake, interval, min_interval)
    end
    # Send final state
    payload = render(node)
    try; send(ws, payload); catch; end
end

_await_next_frame(::Nothing, interval, min_interval) = sleep(interval)

# Whichever comes first: a notification after the floor, or the end of
# `interval`. A notification during the floor is kept by the event.
function _await_next_frame(wake::Base.Event, interval, min_interval)
    gap = min(min_interval, interval)
    gap > 0 && sleep(gap)
    timer = Timer(_ -> notify(wake), interval - gap)
    try
        wait(wake)
    finally
        close(timer)
    end
end

end
