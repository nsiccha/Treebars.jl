## The words of the HTML renderers, in a page's language

"""
    TreebarTexts

The words Treebars' HTML renderers and page script write: node durations
(`running`, `done`, `failed`, `pending`, `skipped`, `reused`), the toggle pills
and elided-history lines, the poller's badge, pause control, Stop button and
interim header, the freshness notes, the phase overview, the job board, and the
duration units. Build one with [`treebar_texts`](@ref).

It also carries its language, which picks the words of the notes packages
write into progress nodes ([`treebar_notes`](@ref)), and an app's own words for
any of those notes.

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
    decimal::String               # decimal separator of sub-minute seconds and of note values
    locale::Symbol                # the language of these texts; picks the words of packages' notes
    notes::Tuple                  # an app's words for packages' notes: (table => (name = text, …), …)
end

# The texts proper: every field that holds words.
const _TEXT_NAMES = Tuple(n for n in fieldnames(TreebarTexts) if fieldtype(TreebarTexts, n) === String)

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
    treebar_texts(locale::Symbol=:en, notes::Pair...; texts...)

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

`locale` also picks the words of the notes packages write into progress nodes
([`treebar_notes`](@ref)). An app replaces any of a package's texts by passing
that package's table with its own words, checked against the table:

```julia
treebar_texts(:de, progress_notes => (from_disk = "von der Festplatte ({size})",))
```
"""
function treebar_texts(locale::Symbol=:en, notes::Pair...; texts...)
    haskey(_TEXT_LOCALES, locale) || throw(ArgumentError(string("treebar_texts: unknown locale ",
        repr(locale), "; available: ", join(repr.(keys(_TEXT_LOCALES)), ", "))))
    for name in keys(texts)
        name in _TEXT_NAMES || throw(ArgumentError(string("treebar_texts: unknown text ", repr(name),
            "; texts are ", join(_TEXT_NAMES, ", "))))
    end
    merged = merge(getfield(_TEXT_LOCALES, locale), (; (k => string(v) for (k, v) in pairs(texts))...))
    for name in _TEXT_NAMES
        _check_placeholders("treebar_texts: $name", merged[name], get(_TEXT_PLACEHOLDERS, name, ()))
    end
    TreebarTexts((merged[name] for name in _TEXT_NAMES)..., locale, _note_overrides(notes))
end

const _PLACEHOLDER = r"\{([A-Za-z_]+)\}"

_placeholders(template::AbstractString) = unique!([Symbol(m[1]) for m in eachmatch(_PLACEHOLDER, template)])

# A `{placeholder}` the text does not take is a typo, not a literal.
function _check_placeholders(what, template::AbstractString, allowed)
    for p in _placeholders(template)
        p in allowed || throw(ArgumentError(string(what, " has no placeholder {", p, "}",
            isempty(allowed) ? "" : string("; it takes ", join(("{$a}" for a in allowed), ", ")))))
    end
end

## Notes a package writes into progress nodes, in the page's language
#
# A package writes a note into a node once, often on a background task and into
# a node every viewer shares, so it cannot know the page's language. It writes a
# `TreebarNote` instead of a string; each renderer turns it into words with its
# own texts.

"""
    ByteSize(n::Integer)

A byte count for a progress note's `{placeholder}`. English writes it as
`"512 B"`, `"850.0 KB"`, `"26.9 MB"` or `"1.2 GB"` (powers of 1024, one
decimal); other languages use their decimal separator (`"26,9 MB"`).
"""
struct ByteSize
    n::Int
    function ByteSize(n::Integer)
        n < 0 && throw(ArgumentError("ByteSize: a byte count cannot be negative, got $n"))
        new(n)
    end
end

"""
    TreebarNotes

The words of the notes one package writes into progress nodes, in each language
it supports. Build one with [`treebar_notes`](@ref); calling it,
`notes(:name; values...)`, makes a [`TreebarNote`](@ref).
"""
struct TreebarNotes
    words::Dict{Symbol,Dict{Symbol,String}}    # locale => text name => text
    placeholders::Dict{Symbol,Vector{Symbol}}  # text name => the placeholders its English text takes
end

"""
    TreebarNote

A progress note whose words are chosen when the tree is drawn, in the language
of the renderer's texts. Make one from a package's [`TreebarNotes`](@ref)
table, or with [`treebar_note`](@ref) for one of Treebars' own texts, and pass
it to `update_progress!(node, note)`.
"""
struct TreebarNote
    notes::Union{TreebarNotes,Nothing}  # `nothing`: one of Treebars' own texts
    name::Symbol
    values::NamedTuple
end

"""
    treebar_notes(; en, de=…)

The words of the notes a package writes into progress nodes: one `NamedTuple`
of texts per language, English required. A text's `{placeholders}` are named
by its English text; the other languages may use any of them, and a language
that leaves a text out falls back to the English one.

```julia
const progress_notes = treebar_notes(
    en = (from_disk = "from disk: {size}", cached = "(cached)"),
    de = (from_disk = "aus dem Zwischenspeicher ({size})", cached = "(zwischengespeichert)"))

update_progress!(node, progress_notes(:from_disk; size = ByteSize(n)))
update_progress!(node, progress_notes(:cached))
```

Every HTML renderer writes the note in the language of its texts (the page's
language, or `texts=`); [`render_text`](@ref) and the `:term` backend write
English. An app rewords a package's texts through [`treebar_texts`](@ref).
A language Treebars has no texts for, an unknown text, a `{placeholder}` the
English text does not take, or a missing or unsupported value throws an
`ArgumentError`. Values are strings and integers, written as given, and
[`ByteSize`](@ref).
"""
function treebar_notes(; locales...)
    haskey(locales, :en) || throw(ArgumentError(
        "treebar_notes: the English texts are required, e.g. en = (from_disk = \"from disk: {size}\",)"))
    words = Dict{Symbol,Dict{Symbol,String}}()
    for (locale, texts) in pairs(locales)
        haskey(_TEXT_LOCALES, locale) || throw(ArgumentError(string("treebar_notes: unknown locale ",
            repr(locale), "; available: ", join(repr.(keys(_TEXT_LOCALES)), ", "))))
        texts isa NamedTuple || throw(ArgumentError(string("treebar_notes: ", locale,
            " must be a NamedTuple of texts, e.g. (from_disk = \"…\",); got ", repr(texts))))
        words[locale] = Dict{Symbol,String}(name => _note_template_string(locale, name, text)
            for (name, text) in pairs(texts))
    end
    en = words[:en]
    isempty(en) && throw(ArgumentError("treebar_notes: en declares no texts"))
    placeholders = Dict(name => _placeholders(text) for (name, text) in en)
    for (locale, texts) in words, (name, text) in texts
        haskey(en, name) || throw(ArgumentError(string("treebar_notes: ", locale, " has the text ", name,
            ", which en does not declare; en declares ", join(sort!(collect(keys(en))), ", "))))
        _check_placeholders("treebar_notes: $locale.$name", text, placeholders[name])
    end
    TreebarNotes(words, placeholders)
end

_note_template_string(_, _, text::AbstractString) = String(text)
_note_template_string(locale, name, text) = throw(ArgumentError(string(
    "treebar_notes: ", locale, ".", name, " must be a string; got ", repr(text))))

(notes::TreebarNotes)(name::Symbol; values...) =
    TreebarNote(notes, name, _note_values("note $name", _note_placeholders(notes, name), values))

"""
    treebar_note(name::Symbol; values...)

A [`TreebarNote`](@ref) in one of Treebars' own texts ([`TreebarTexts`](@ref)),
for a note that says what Treebars already has words for:

```julia
update_progress!(node, treebar_note(:queued_position; position = 2))  # "queued · #2" / "wartet · Nr. 2"
```

An unknown text, or a missing or unsupported value, throws an `ArgumentError`.
"""
function treebar_note(name::Symbol; values...)
    name in _TEXT_NAMES || throw(ArgumentError(string("treebar_note: unknown text ", repr(name),
        "; texts are ", join(_TEXT_NAMES, ", "))))
    TreebarNote(nothing, name, _note_values("treebar_note: $name", get(_TEXT_PLACEHOLDERS, name, ()), values))
end

_note_placeholders(notes::TreebarNotes, name::Symbol) = get(notes.placeholders, name) do
    throw(ArgumentError(string("note: unknown text ", repr(name), "; this table's texts are ",
        join(sort!(collect(keys(notes.placeholders))), ", "))))
end

# A note's values fill exactly its text's placeholders.
function _note_values(what, placeholders, values)
    for p in placeholders
        haskey(values, p) || throw(ArgumentError(string(what, " needs a value for {", p, "}")))
    end
    for k in keys(values)
        k in placeholders || throw(ArgumentError(string(what, " has no placeholder {", k, "}",
            isempty(placeholders) ? "" : string("; it takes ", join(("{$p}" for p in placeholders), ", ")))))
    end
    (; (k => _note_arg(what, k, v) for (k, v) in pairs(values))...)
end

# A value the page's language would write differently (a float's decimal
# point, `true`) is refused rather than shown in English on a German page.
_note_arg(_, _, v::AbstractString) = String(v)
_note_arg(_, _, v::Integer) = v
_note_arg(_, _, v::ByteSize) = v
_note_arg(what, k, v::Bool) = _note_arg_error(what, k, v)
_note_arg(what, k, v) = _note_arg_error(what, k, v)
_note_arg_error(what, k, v) = throw(ArgumentError(string(what, ": {", k, "} must be a string, an integer or a ByteSize; got ",
    repr(v), " (format other values as a string first)")))

# An app's own words for packages' notes, checked against each package's table.
function _note_overrides(pairs_)
    merged = Pair{TreebarNotes,NamedTuple}[]
    for p in pairs_
        notes, words = p.first, p.second
        notes isa TreebarNotes || throw(ArgumentError(string(
            "treebar_texts: a note override is `table => (name = \"…\", …)` with a table from treebar_notes; got ", repr(p))))
        words isa NamedTuple || throw(ArgumentError(string(
            "treebar_texts: a table's words must be a NamedTuple, e.g. (from_disk = \"…\",); got ", repr(words))))
        for (name, text) in pairs(words)
            placeholders = _note_placeholders(notes, name)
            text isa AbstractString || throw(ArgumentError(string("treebar_texts: note ", name,
                " must be a string; got ", repr(text))))
            _check_placeholders("treebar_texts: note $name", text, placeholders)
        end
        i = findfirst(q -> q.first === notes, merged)
        isnothing(i) ? push!(merged, notes => map(String, words)) :
            (merged[i] = notes => merge(merged[i].second, map(String, words)))
    end
    Tuple(merged)
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
    replace(template, _PLACEHOLDER => m -> string(values[Symbol(m[2:end-1])]))

# A node's running message in the texts' language: a string as written, a note
# filled in from its text. `render_text`, `progress_state` and the `:term`
# backend pass the English texts.
_note_text(message::AbstractString, ::TreebarTexts) = message
_note_text(note::TreebarNote, t::TreebarTexts) =
    _fill_text(_note_text_template(note.notes, note.name, t);
        (k => _note_value(v, t) for (k, v) in pairs(note.values))...)

_isempty_text(message::AbstractString) = isempty(message)
_isempty_text(::TreebarNote) = false

_note_text_template(::Nothing, name::Symbol, t::TreebarTexts) = getfield(t, name)
function _note_text_template(notes::TreebarNotes, name::Symbol, t::TreebarTexts)
    for (table, words) in t.notes
        table === notes && haskey(words, name) && return words[name]
    end
    en = notes.words[:en]
    get(get(notes.words, t.locale, en), name, en[name])
end

_note_value(v::String, ::TreebarTexts) = v
_note_value(v::Integer, ::TreebarTexts) = string(v)
function _note_value(b::ByteSize, t::TreebarTexts)
    n = b.n
    n < 1024 && return string(n, " B")
    x, unit = n < 1024^2 ? (n / 1024, "KB") : n < 1024^3 ? (n / 1024^2, "MB") : (n / 1024^3, "GB")
    string(replace(string(round(x; digits=1)), "." => t.decimal), " ", unit)
end

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
