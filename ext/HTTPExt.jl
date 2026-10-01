module HTTPExt

import HTTP.WebSockets: WebSocket, send
import Treebars: ws_progress, ProgressNode, StateProgress

"""
    ws_progress(ws, node; interval=0.1, render=repr)

Push live progress updates over a WebSocket until the node finalizes.

By default sends `repr(node)`. Use `render=htmx_ws_render` for HTML output
when HTMXObjects is loaded.

The `render` function takes a `ProgressNode` and returns a `String` to send.
"""
function ws_progress(ws::WebSocket, node::ProgressNode{<:StateProgress};
        interval=0.1, render=repr)
    while node.impl.running
        payload = render(node)
        try; send(ws, payload); catch; break; end
        sleep(interval)
    end
    # Send final state
    payload = render(node)
    try; send(ws, payload); catch; end
end

end
