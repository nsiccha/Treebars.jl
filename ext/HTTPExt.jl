module HTTPExt

import HTTP.WebSockets: WebSocket, send
import Treebars: ws_progress, ProgressNode, StateProgress, _stream_frames, _ws_emit

"""
    ws_progress(ws, node; interval=0.1, render=repr, done=nothing) -> Bool

Push live progress updates over a WebSocket until the node is terminal
(finished, failed or skipped) or the optional `done` handle settles; a pending
node keeps the stream going. Sends only changed frames, then the terminal
state. Returns `false` if the client disconnected, `true` otherwise.

The `render` function takes a `ProgressNode` and returns a `String` to send.
"""
function ws_progress(ws::WebSocket, node::ProgressNode{<:StateProgress};
        interval=0.1, render=repr, done=nothing)
    _stream_frames(frame -> _ws_emit(ws, frame), node; interval, render, done, final=true)
end

# A failed send means the client went away. That ends the stream, quietly, and
# is never a reason to touch the compute, which runs on and fills its cache.
function _ws_emit(ws::WebSocket, frame)
    try
        send(ws, frame)
        true
    catch err
        @debug "Treebars: WebSocket send failed; client disconnected" exception=(err, catch_backtrace())
        false
    end
end

end
