# The texts a render writes in (`treebar_texts`). An explicit `texts=` wins;
# left out, the language of the HTMXObjects answer being rendered decides: the
# `__lang__` its route's mount chain declares, read through
# `HTMXObjects.page_lang()`. An HTMXObjects generation without that accessor,
# or a render outside any answer, writes English. Each public entry point
# resolves once and threads the value down, so one render speaks one language.
_page_lang() = isdefined(HTMXObjects, :page_lang) ? HTMXObjects.page_lang() : nothing
_texts(::Nothing) = _lang_texts(_page_lang())
_texts(texts::TreebarTexts) = texts
_texts(texts) = throw(ArgumentError(string(
    "texts must be a TreebarTexts, e.g. treebar_texts(:de); got ", repr(texts))))

# Whether a live region shows its pause/play control (`pause=`): the poller
# badge's ❚❚ and a live board's Pause. An explicit Bool wins; left out, the
# HTMXObjects answer being rendered decides, exactly as for `texts`: the
# `__progress_pause__` its route's mount chain declares, read through
# `HTMXObjects.page_progress_pause()` (`nothing` when the chain declares none).
# An HTMXObjects generation without that accessor, a chain that declares
# nothing, or a render outside any answer shows the control. A visitor-facing
# app declares `__progress_pause__ = false` once on its root (snag
# visitor-apps-can-148cfaf6). Resolved once per public entry point and threaded
# down, like the texts.
_page_pause() = isdefined(HTMXObjects, :page_progress_pause) ? HTMXObjects.page_progress_pause() : nothing
_pause(::Nothing) = _page_pause_value(_page_pause())
_pause(pause::Bool) = pause
_pause(pause) = throw(ArgumentError(string(
    "pause must be true, false, or nothing to follow the page's `__progress_pause__`; got ", repr(pause))))
_page_pause_value(::Nothing) = true
_page_pause_value(pause::Bool) = pause
_page_pause_value(pause) = throw(ArgumentError(string(
    "HTMXObjects.page_progress_pause() must return true, false or nothing; got ", repr(pause))))

# The words `htmx_treebar_script` writes itself — a ticking duration, the
# badge's status mirror and pause label, the freshness notes, a board item
# that ended, the board's Pause label, and the duration units — as the JSON
# object it reads from the nearest `data-treebar-texts`. Each live region
# (poller wrapper, WebSocket frame, board) and each standalone tree carries
# it, but only when the words are not the script's own English, so English
# markup is unchanged.
const _CLIENT_TEXTS = (:running, :eta, :polling, :paused, :pause, :resume, :stale, :updated,
    :connection_lost, :updates_failing, :retrying, :ended, :board_pause, :board_resume,
    :unit_ms, :unit_s, :unit_min, :unit_h, :unit_d, :unit_space, :decimal)

# A single-quoted JavaScript string literal, for the words inline onclick
# handlers write.
_js_string(s::AbstractString) = string("'",
    replace(s, '\\' => "\\\\", '\'' => "\\'", '\n' => "\\n", '\r' => "\\r"), "'")

_client_texts_json(t::TreebarTexts) =
    JSON.json(NamedTuple{_CLIENT_TEXTS}(map(n -> getfield(t, n), _CLIENT_TEXTS)))
const _EN_CLIENT_TEXTS_JSON = _client_texts_json(_EN_TEXTS)

# The `data-treebar-texts` value for `t`, or `nothing` (no attribute) for the
# script's own English.
_client_texts_attr(t::TreebarTexts) =
    (json = _client_texts_json(t); json == _EN_CLIENT_TEXTS_JSON ? nothing : json)

# A standalone tree's outermost element with the texts its script words need;
# an empty render stays empty.
_with_client_texts(x::Node, t::TreebarTexts) =
    (json = _client_texts_attr(t); isnothing(json) ? x : x(; data_treebar_texts=json))
_with_client_texts(x, ::TreebarTexts) = x
