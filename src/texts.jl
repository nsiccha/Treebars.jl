## The words of the HTML renderers, in a page's language

"""
    TreebarTexts

The words Treebars' HTML renderers and page script write: node durations
(`running`, `done`, `failed`, `pending`, `skipped`, `reused`), the toggle pills
and elided-history lines, the poller's badge, pause control, Stop button and
interim header, the freshness notes, the phase overview, the job board, and the
duration units. Build one with [`treebar_texts`](@ref).

[`render_text`](@ref) and the `:term` backend always write English: they are
read by developers and agents, not by an app's audience.
"""
struct TreebarTexts
    running::String               # a running node's elapsed time
    eta::String                   # appended after `running` on a determinate node
    done::String
    failed::String
    pending::String
    skipped::String
    reused::String                # reused before it was entered (no elapsed)
    reused_after::String          # reused after the lookup ran
    interrupt::String             # the pending-interrupt marker
    pill_pending::String
    pill_finished::String
    pill_reused::String
    pill_skipped::String
    pill_failed::String
    elided_finished::String       # `max_finished` elision lines
    elided_reused::String
    elided_skipped::String
    starting::String              # a tree with no children yet
    progress::String              # the disclosure holding a kept or streamed tree
    working::String               # the default description of a streamed tree
    badge_starting::String        # the badge's elapsed before the first node
    polling::String               # badge status words
    paused::String
    pause::String                 # pause control: accessible name while live
    pause_title::String           # pause control: tooltip
    resume::String                # pause control: accessible name while paused
    stop::String                  # the `cancel_url` button
    running_header::String        # the interim header above a labelled poller's tree
    stale::String                 # freshness: nothing confirmed for a while
    updated::String               # freshness: the age after a failure notice
    connection_lost::String
    updates_failing::String
    retrying::String
    phase::String                 # phase overview: first column header
    state_pending::String         # phase overview: one column per state
    state_running::String
    state_finished::String
    state_reused::String
    state_failed::String
    state_skipped::String
    prepared_items::String        # phase overview: a plan's caption
    phase_plan::String            # phase overview: an unnamed plan's name
    expand_all::String
    collapse_all::String
    queued::String                # board: a queued item
    queued_position::String       # board: a queued item with its position
    board_running::String         # board header counts
    board_running_queued::String
    ended::String                 # board: an item that left while still running
    board_pause::String
    board_resume::String
    no_jobs::String               # board: the default empty text
    unit_ms::String               # duration units
    unit_s::String
    unit_min::String
    unit_h::String
    unit_d::String
    unit_space::String            # between a number and its unit
    decimal::String               # decimal separator of sub-minute seconds
end

# The `{placeholders}` each text may hold; a text not listed takes none.
const _TEXT_PLACEHOLDERS = (
    running = (:elapsed,), eta = (:eta,), done = (:elapsed,), failed = (:elapsed,),
    reused_after = (:elapsed,),
    pill_pending = (:n,), pill_finished = (:n,), pill_reused = (:n,), pill_skipped = (:n,),
    pill_failed = (:n,),
    elided_finished = (:n,), elided_reused = (:n,), elided_skipped = (:n,),
    running_header = (:label,),
    stale = (:age,), updated = (:age,), updates_failing = (:why,),
    prepared_items = (:name, :n), phase_plan = (:n,),
    queued_position = (:position,), board_running = (:running,),
    board_running_queued = (:running, :queued), ended = (:elapsed,),
)

const _TEXT_LOCALES = (
    en = (
        running = "{elapsed} so far",
        eta = "ETA ~{eta}",
        done = "done ({elapsed})",
        failed = "failed ({elapsed})",
        pending = "pending",
        skipped = "skipped",
        reused = "reused",
        reused_after = "reused ({elapsed})",
        interrupt = "interrupt requested",
        pill_pending = "{n} pending",
        pill_finished = "{n} finished",
        pill_reused = "{n} reused",
        pill_skipped = "{n} skipped",
        pill_failed = "{n} failed",
        elided_finished = "{n} earlier finished not shown",
        elided_reused = "{n} earlier reused not shown",
        elided_skipped = "{n} earlier skipped not shown",
        starting = "Starting...",
        progress = "Progress",
        working = "Working...",
        badge_starting = "Starting…",
        polling = "Polling",
        paused = "Paused",
        pause = "Pause live updates",
        pause_title = "Pause live updates (the work keeps running in the background)",
        resume = "Resume live updates",
        stop = "Stop",
        running_header = "{label} — running...",
        stale = "Updated {age} ago",
        updated = "updated {age} ago",
        connection_lost = "Connection lost",
        updates_failing = "Updates failing ({why})",
        retrying = "retrying",
        phase = "Phase",
        state_pending = "Pending",
        state_running = "Running",
        state_finished = "Finished",
        state_reused = "Reused",
        state_failed = "Failed",
        state_skipped = "Skipped",
        prepared_items = "{name} · {n} prepared items",
        phase_plan = "Phase plan {n}",
        expand_all = "Expand all",
        collapse_all = "Collapse all",
        queued = "queued",
        queued_position = "queued · #{position}",
        board_running = "{running} running",
        board_running_queued = "{running} running · {queued} queued",
        ended = "ended ({elapsed})",
        board_pause = "Pause",
        board_resume = "Resume",
        no_jobs = "No running jobs.",
        unit_ms = "ms", unit_s = "s", unit_min = "m", unit_h = "h", unit_d = "d",
        unit_space = "", decimal = ".",
    ),
    de = (
        running = "{elapsed} bisher",
        eta = "noch ca. {eta}",
        done = "fertig ({elapsed})",
        failed = "fehlgeschlagen ({elapsed})",
        pending = "ausstehend",
        skipped = "übersprungen",
        reused = "wiederverwendet",
        reused_after = "wiederverwendet ({elapsed})",
        interrupt = "Abbruch angefordert",
        pill_pending = "{n} ausstehend",
        pill_finished = "{n} abgeschlossen",
        pill_reused = "{n} wiederverwendet",
        pill_skipped = "{n} übersprungen",
        pill_failed = "{n} fehlgeschlagen",
        elided_finished = "{n} frühere abgeschlossene ausgeblendet",
        elided_reused = "{n} frühere wiederverwendete ausgeblendet",
        elided_skipped = "{n} frühere übersprungene ausgeblendet",
        starting = "Wird gestartet …",
        progress = "Fortschritt",
        working = "Wird bearbeitet …",
        badge_starting = "Wird gestartet …",
        polling = "Läuft",
        paused = "Angehalten",
        pause = "Live-Aktualisierung anhalten",
        pause_title = "Live-Aktualisierung anhalten (die Arbeit läuft im Hintergrund weiter)",
        resume = "Live-Aktualisierung fortsetzen",
        stop = "Abbrechen",
        running_header = "{label} — läuft …",
        stale = "Vor {age} aktualisiert",
        updated = "vor {age} aktualisiert",
        connection_lost = "Verbindung unterbrochen",
        updates_failing = "Aktualisierung schlägt fehl ({why})",
        retrying = "wird erneut versucht",
        phase = "Phase",
        state_pending = "Ausstehend",
        state_running = "Laufend",
        state_finished = "Abgeschlossen",
        state_reused = "Wiederverwendet",
        state_failed = "Fehlgeschlagen",
        state_skipped = "Übersprungen",
        prepared_items = "{name} · {n} vorbereitete Einträge",
        phase_plan = "Phasenplan {n}",
        expand_all = "Alle aufklappen",
        collapse_all = "Alle zuklappen",
        queued = "wartet",
        queued_position = "wartet · Nr. {position}",
        board_running = "{running} laufend",
        board_running_queued = "{running} laufend · {queued} wartend",
        ended = "beendet ({elapsed})",
        board_pause = "Anhalten",
        board_resume = "Fortsetzen",
        no_jobs = "Keine laufenden Aufträge.",
        unit_ms = "ms", unit_s = "s", unit_min = "min", unit_h = "h", unit_d = "d",
        unit_space = " ", decimal = ",",
    ),
)

"""
    treebar_texts(locale::Symbol=:en; texts...)

The [`TreebarTexts`](@ref) for `locale` (`:en` or `:de`), with any of its texts
replaced by keyword:

```julia
htmx_render(node; texts=treebar_texts(:de))
treebar_texts(:de; running="läuft seit {elapsed}", stop="Anhalten")
```

Every HTML renderer takes `texts=`. Left out, the texts follow the page
language that the HTMXObjects route being answered declares (`__lang__ = "de"`
on its mount chain): `de` and every `de-*` tag select German, any other
language or no declaration selects English. An unknown locale or text name, or
a `{placeholder}` a text does not take, throws an `ArgumentError`.
"""
function treebar_texts(locale::Symbol=:en; texts...)
    haskey(_TEXT_LOCALES, locale) || throw(ArgumentError(string("treebar_texts: unknown locale ",
        repr(locale), "; available: ", join(repr.(keys(_TEXT_LOCALES)), ", "))))
    names = fieldnames(TreebarTexts)
    for name in keys(texts)
        name in names || throw(ArgumentError(string("treebar_texts: unknown text ", repr(name),
            "; texts are ", join(names, ", "))))
    end
    merged = merge(getfield(_TEXT_LOCALES, locale), (; (k => string(v) for (k, v) in pairs(texts))...))
    for name in names
        allowed = get(_TEXT_PLACEHOLDERS, name, ())
        for m in eachmatch(r"\{([A-Za-z_]+)\}", merged[name])
            Symbol(m[1]) in allowed || throw(ArgumentError(string("treebar_texts: ", name,
                " has no placeholder {", m[1], "}",
                isempty(allowed) ? "" : string("; it takes ", join(("{$p}" for p in allowed), ", ")))))
        end
    end
    TreebarTexts((merged[name] for name in names)...)
end

const _EN_TEXTS = treebar_texts(:en)
const _LOCALE_TEXTS = Dict{Symbol,TreebarTexts}(k => treebar_texts(k) for k in keys(_TEXT_LOCALES))

# The texts for a page language, a BCP 47 tag such as "de" or "de-CH": its
# primary subtag picks the locale, and a language without one is English.
_lang_texts(::Nothing) = _EN_TEXTS
_lang_texts(lang::AbstractString) =
    get(_LOCALE_TEXTS, Symbol(lowercase(first(split(lang, '-')))), _EN_TEXTS)

# A text with its `{placeholders}` filled in from `values`.
_fill_text(template::AbstractString; values...) =
    replace(template, r"\{([A-Za-z_]+)\}" => m -> string(values[Symbol(m[2:end-1])]))

# A duration in the texts' units. English units keep `short_duration`'s exact
# strings. Any other units take the client ticker's bands, so the server's
# first paint and the ticker that overwrites it agree: whole milliseconds below
# 100ms, floored tenths of a second below a minute, then the two most
# significant of minutes, hours and days.
function _duration_text(d, t::TreebarTexts)
    _english_units(t) && return short_duration(d)
    parts = canonicalize(d).periods
    ms = isempty(parts) ? 0 : max(0, sum(p -> value(convert(Millisecond, p)), parts))
    u(n, unit) = string(n, t.unit_space, unit)
    ms < 100 && return u(ms, t.unit_ms)
    if ms < 60_000
        s = string(floor(ms / 100) / 10)
        endswith(s, ".0") && (s = s[1:end-2])
        return u(replace(s, "." => t.decimal), t.unit_s)
    end
    ms < 3_600_000 && return string(u(div(ms, 60_000), t.unit_min), " ", u(div(ms, 1000) % 60, t.unit_s))
    ms < 86_400_000 && return string(u(div(ms, 3_600_000), t.unit_h), " ", u(div(ms, 60_000) % 60, t.unit_min))
    string(u(div(ms, 86_400_000), t.unit_d), " ", u(div(ms, 3_600_000) % 24, t.unit_h))
end

_english_units(t::TreebarTexts) =
    (t.unit_ms, t.unit_s, t.unit_min, t.unit_h, t.unit_d, t.unit_space, t.decimal) ==
    (_EN_TEXTS.unit_ms, _EN_TEXTS.unit_s, _EN_TEXTS.unit_min, _EN_TEXTS.unit_h, _EN_TEXTS.unit_d,
     _EN_TEXTS.unit_space, _EN_TEXTS.decimal)
