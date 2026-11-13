# --- Keyed board ---------------------------------------------------------------
#
# A board is a keyed, changing collection of progress trees (a "running jobs"
# list). The server always renders the FULL current list; the client script
# (`htmx_treebar_script`) reconciles it into the live board by
# `data-treebar-key`, so each `.treebar-board-item` wrapper — and the UI state on
# it — persists while only its content is replaced. See `htmx_render_board` in
# src/interface.jl for the entry contract.

const _BOARD_STATES = (:queued, :running, :done, :failed)

# Entries are NamedTuples by contract; any object with the same properties works.
_board_get(entry, name::Symbol, default) =
    hasproperty(entry, name) ? getproperty(entry, name) : default

# `meta` is a NamedTuple / Dict of label => value, or any iterable of Pairs.
_board_meta_pairs(meta::Union{NamedTuple,AbstractDict}) = [string(k) => v for (k, v) in pairs(meta)]
_board_meta_pairs(::Nothing) = Pair{String,Any}[]
_board_meta_pairs(meta) = [string(first(p)) => last(p) for p in meta]

_board_blank(v) = v === nothing || v === missing || (v isa AbstractString && isempty(v))
_board_value(v) = v isa Node || v isa AbstractString ? v : string(v)

_board_ms(::Nothing) = 0
_board_ms(ms::Real) = isfinite(ms) ? max(0, round(Int, ms)) : 0
_board_ms(p::Dates.Period) = max(0, Dates.value(convert(Millisecond, p)))

# Header duration. The same `.treebar-duration` contract as a tree node, so a
# running item ticks locally between updates through the existing ticker; the
# extra class lets the reconciler find the header span when it ends an item.
# A queued item reads like a pending node — no clock, just its queue position.
function _board_duration_span(state::Symbol, ms::Int, position, t::TreebarTexts)
    d = _duration_text(Millisecond(ms), t)
    cls = "treebar-duration treebar-board-duration"
    if state === :queued
        text = " — " * (isnothing(position) ? t.queued : _fill_text(t.queued_position; position))
        return h.span(class=cls, data_treebar_status="pending")(text)
    end
    status, text = state === :running ? ("running", " — " * _fill_text(t.running; elapsed=d)) :
                   state === :done    ? ("finished", " — " * _fill_text(t.done; elapsed=d)) :
                                        ("failed", " — " * _fill_text(t.failed; elapsed=d))
    h.span(class=cls, data_treebar_status=status, data_elapsed_ms=string(ms))(text)
end

# The tree collapses under the item header. `scoped=false`: the item wrapper
# carries the data-show-* pill state, like `.treebar-poller` does. A terminal
# item's tree is frozen, so a node it still holds as "running" does not tick.
function _board_tree(node, t::TreebarTexts; open::Bool, frozen::Bool)
    body = node isa ProgressNode ? _htmx_render(node, t; scoped=false) : node
    cls = frozen ? "treebar-board-tree treebar-frozen" : "treebar-board-tree"
    open ? h.details(class=cls, open=true)(h.summary(t.progress), body) :
           h.details(class=cls)(h.summary(t.progress), body)
end

function _board_item(entry, t::TreebarTexts; expanded::Bool)
    state = Symbol(entry.state)
    state in _BOARD_STATES || throw(ArgumentError(
        "board entry state must be one of $(_BOARD_STATES) (got $(repr(entry.state)))"))
    ms = _board_ms(_board_get(entry, :elapsed_ms, 0))
    node = _board_get(entry, :node, nothing)
    href = _board_get(entry, :href, nothing)
    meta = _board_meta_pairs(_board_get(entry, :meta, ()))
    # `position` is the queue position a queued item's state text shows; it is
    # not repeated as a meta item.
    position = nothing
    shown = Node[]
    for (k, v) in meta
        if k == "position"
            position = _board_blank(v) ? nothing : v
            continue
        end
        _board_blank(v) && continue
        push!(shown, h.span(class="treebar-board-meta-item")(
            h.span(class="treebar-board-meta-key")(k), " ", _board_value(v)))
    end
    label = string(entry.label)
    label_node = isnothing(href) ?
        h.strong(class="treebar-board-label")(label) :
        h.a(class="treebar-board-label", href=string(href))(label)
    h.div(; class="treebar-board-item",
        data_treebar_key=string(entry.key),
        data_treebar_state=string(state),
        data_open=expanded ? "1" : "0",
        _PILL_DEFAULTS...)(
        h.div(class="treebar-board-item-content")(
            h.div(class="treebar-board-item-header")(
                label_node,
                _board_duration_span(state, ms, position, t),
                isempty(shown) ? "" : h.div(class="treebar-board-meta")(shown...),
            ),
            isnothing(node) ? "" : _board_tree(node, t; open=expanded, frozen=state in (:done, :failed)),
        ),
    )
end

# Board-level Pause: toggles data-paused on the board; the script then cancels
# its poll requests, drops pushed frames, freezes its clocks and holds lingering
# items — the `.treebar-pause` mechanism, keyed on the board.
_board_pause_button(t::TreebarTexts) = h.button(class="treebar-board-pause", type="button",
    onclick="var b=this.closest('.treebar-board'); if(!b) return; var v=b.dataset.paused==='1'?'0':'1'; b.dataset.paused=v; this.textContent=v==='1'?$(_js_string(t.board_resume)):$(_js_string(t.board_pause));")(t.board_pause)

function _board_count(entries, t::TreebarTexts)
    n_running = count(e -> Symbol(e.state) === :running, entries)
    n_queued = count(e -> Symbol(e.state) === :queued, entries)
    text = n_queued == 0 ? _fill_text(t.board_running; running=n_running) :
        _fill_text(t.board_running_queued; running=n_running, queued=n_queued)
    h.span(class="treebar-board-count", data_running=string(n_running),
           data_queued=string(n_queued))(text)
end

function htmx_render_board(entries; poll_url=nothing, poll_interval="1s",
        empty=nothing, id="treebar-board", linger_ms::Integer=3000,
        expanded::Bool=false, live::Bool=!isnothing(poll_url), phase_overview::Union{Bool,Symbol}=false,
        texts=nothing, pause=nothing)
    t = _texts(texts)
    show_pause = _pause(pause)
    empty = something(empty, t.no_jobs)
    # First occurrence of a key wins: the client matches items by key, so a
    # duplicate would make two DOM items fight over one identity.
    seen = Set{String}()
    unique_entries = [e for e in entries if !(string(e.key) in seen) && (push!(seen, string(e.key)); true)]
    items = [_board_item(e, t; expanded) for e in unique_entries]
    # The poll element's hx-target/hx-select describe the no-script fallback
    # (replace the whole board); with `htmx_treebar_script` loaded, the
    # `htmx:beforeSwap` hook hands the response to the keyed reconciler instead.
    poller = isnothing(poll_url) ? "" :
        h.div(class="treebar-board-poll",
            hx_get=string(poll_url),
            hx_trigger="every $poll_interval",
            hx_target="closest .treebar-board",
            hx_swap="outerHTML",
            hx_select="#$(id)")()
    empty_node = isempty(items) ?
        h.p(class="treebar-board-empty")(empty) :
        h.p(class="treebar-board-empty", hidden=true)(empty)
    h.div(class="treebar-board", id=string(id), data_paused="0",
          data_treebar_linger_ms=string(linger_ms), data_treebar_texts=_client_texts_attr(t))(
        h.div(class="treebar-board-header")(
            _board_count(unique_entries, t),
            live ? _freshness_span() : "",
            (live && show_pause) ? _board_pause_button(t) : "",
        ),
        Treebars._overview_enabled(phase_overview) ? _phase_overview_html(
            [node for e in unique_entries for node in (_board_get(e, :node, nothing),)
                if node isa ProgressNode], phase_overview, t; board=true) : "",
        h.div(class="treebar-board-list")(items),
        empty_node,
        poller,
    )
end

htmx_ws_render_board(entries; kwargs...) =
    node_to_html(htmx_render_board(entries; live=true, kwargs..., poll_url=nothing))

# The texts and the pause control are resolved once, in the route's task, for
# every frame.
function ws_board(ws::WebSocket, entries; interval=1.0, until=() -> false, texts=nothing, pause=nothing, kwargs...)
    t = _texts(texts)
    show_pause = _pause(pause)
    while true
        stop = until()
        frame = htmx_ws_render_board(entries(); texts=t, pause=show_pause, kwargs...)
        try
            send(ws, frame)
        catch
            break   # client gone
        end
        stop && break
        sleep(interval)
    end
    nothing
end
