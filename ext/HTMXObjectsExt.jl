module HTMXObjectsExt
import HTMXObjects
import Treebars
import HTMXObjects: h, Node, Raw, fetchindex
import HTTP
import JSON
import HTTP.WebSockets: WebSocket, send
import Treebars: htmx_render, htmx_render_children, htmx_treebar_styles, htmx_treebar_script,
    ws_progress, htmx_ws_render, htmx_ws_progress, polling_fetchindex,
    htmx_render_board, htmx_ws_render_board, ws_board,
    ProgressNode, StateProgress, root, is_pending, is_running, is_finished, is_failed, is_skipped, is_reused, is_displayed, _renders_self, duration, eta, short_duration, _first_seen!,
    _displayed_children, _DisplayTraversal, _shows_interrupt_request
import Treebars: TreebarTexts, _EN_TEXTS, _lang_texts, _fill_text, _duration_text, _note_text, _isempty_text
import Treebars: add_child!
import Treebars: initialize_progress!, update_progress!, start_progress!, finalize_progress!, fail_progress!
import Treebars: current_dispatch_parent
import Dates
using Dates: Millisecond

include("htmx_context.jl")
include("htmx_render.jl")
include("htmx_streaming.jl")
include("htmx_board.jl")
include("htmx_polling.jl")

include("htmx_precompile.jl")

end
