using TestItemRunner

# The words of the HTML renderers in a page's language (`treebar_texts`,
# snag treebars-poller-b46d6ecb): German pages show German progress trees,
# English markup stays exactly as it was.

@testitem "treebar_texts: locales, overrides, refusals, page languages" setup=[TreebarsTestImports] tags=[:unit, :render] begin
    let
    en, de = treebar_texts(:en), treebar_texts(:de)
    @test treebar_texts() == en
    @test de.running == "{elapsed} bisher"
    @test en.running == "{elapsed} so far"
    @test treebar_texts(:de; stop="Anhalten").stop == "Anhalten"
    @test treebar_texts(:de; stop="Anhalten").running == de.running
    @test treebar_texts(:en; running="{elapsed} elapsed").running == "{elapsed} elapsed"
    @test_throws ArgumentError treebar_texts(:fr)
    @test_throws ArgumentError treebar_texts(:de; nonsense="x")
    # A placeholder the text does not take is a typo, not a literal.
    @test_throws ArgumentError treebar_texts(:de; stop="{label}")
    @test_throws ArgumentError treebar_texts(:de; running="{eta}")

    # A page language selects by its primary subtag.
    for lang in ("de", "de-DE", "de-CH", "DE-at")
        @test Treebars._lang_texts(lang) == de
    end
    for lang in ("en", "en-GB", "fr", "nl-BE")
        @test Treebars._lang_texts(lang) == en
    end
    @test Treebars._lang_texts(nothing) == en

    # German durations: a space before the unit and a decimal comma, in the
    # client ticker's bands. English keeps `short_duration` exactly.
    d(ms, t) = Treebars._duration_text(Millisecond(ms), t)
    @test d(47, de) == "47 ms"
    @test d(3_900, de) == "3,9 s"
    @test d(13_000, de) == "13 s"
    @test d(83_400, de) == "1 min 23 s"
    @test d(7_530_000, de) == "2 h 5 min"
    @test d(129_600_000, de) == "1 d 12 h"
    for ms in (0, 47, 3_900, 13_000, 83_400, 3_600_500, 7_530_000, 129_600_000)
        @test d(ms, en) == short_duration(Millisecond(ms))
    end
    end
end

@testitem "English renders carry no texts attribute and keep their words" setup=[TreebarsTestImports] tags=[:unit, :render] begin
    let
    html(x) = repr(MIME"text/html"(), x)
    ext = Base.get_extension(Treebars, :HTMXObjectsExt)
    # This HTMXObjects declares no page language, so `texts=nothing` is English.
    @test ext._texts(nothing) == treebar_texts(:en)
    @test_throws ArgumentError htmx_render(initialize_progress!(:state; description="x"); texts=:de)

    root = initialize_progress!(:state; description="Job")
    start_progress!(root)
    done = initialize_progress!(root; description="Load")
    finalize_progress!(done)
    prepare_progress!(root; description="Fit")
    # Two renders differ only in the running node's elapsed time.
    still(s) = replace(s, r"data-elapsed-ms=\"\d+\"" => "", r" — [\d.]+(ms|s) so far" => "")
    plain = html(htmx_render(root))
    @test still(plain) == still(html(htmx_render(root; texts=treebar_texts(:en))))
    @test !occursin("data-treebar-texts", plain)
    @test occursin("1 finished", plain)
    @test occursin("1 pending", plain)
    @test occursin(" — pending", plain)
    @test occursin("so far", plain)

    poller = html(ext._polling_running(root; label="Background job", poll_url="/poll",
        poll_interval="200ms", cancel_url="/stop"))
    @test !occursin("data-treebar-texts", poller)
    @test occursin(">Polling</span>", poller)
    @test occursin("aria-label=\"Pause live updates\"", poller)
    @test occursin("play?&#39;Resume live updates&#39;:&#39;Pause live updates&#39;", poller)
    @test occursin("Background job — running...", poller)
    @test occursin(">Stop</a>", poller)

    entries = [(; key=1, label="one", state=:queued, elapsed_ms=0, meta=(; position=3))]
    board = html(htmx_render_board(entries; poll_url="/jobs"))
    @test !occursin("data-treebar-texts", board)
    @test occursin("0 running · 1 queued", board)
    @test occursin(" — queued · #3", board)
    @test occursin("v===&#39;1&#39;?&#39;Resume&#39;:&#39;Pause&#39;;\">Pause</button>", board)
    @test occursin("No running jobs.", board)
    @test !occursin("data-treebar-texts", htmx_ws_render(root; id="run"))
    finalize_progress!(root)
    end
end

@testitem "German renders: tree, poller, board, WebSocket frame, overview" setup=[TreebarsTestImports] tags=[:unit, :render] begin
    let
    html(x) = repr(MIME"text/html"(), x)
    ext = Base.get_extension(Treebars, :HTMXObjectsExt)
    de = treebar_texts(:de)
    # The script's words travel as JSON in an attribute (HTML-escaped).
    attr = "data-treebar-texts=\"{&quot;running&quot;:&quot;{elapsed} bisher&quot;"

    root = initialize_progress!(:state; description="Eine Datenquelle neu abrufen")
    start_progress!(root)
    done = initialize_progress!(root; description="Laden")
    finalize_progress!(done)
    prepare_progress!(root; description="Prüfen")
    skipped = prepare_progress!(root; description="Veröffentlichen")
    skip_progress!(skipped)
    counted = initialize_progress!(root, 4; description="Dateien")
    update_progress!(counted, 1)
    request_interrupt!(counted)

    tree = html(htmx_render(root; texts=de))
    @test count("data-treebar-texts=", tree) == 1
    @test occursin(attr, tree)
    for word in ("1 abgeschlossen", "1 ausstehend", "1 übersprungen", " — ausstehend",
                 " — übersprungen", "bisher", "noch ca.", "Abbruch angefordert")
        @test occursin(word, tree)
    end
    for word in ("finished", "pending", "skipped", "so far", "ETA", "interrupt requested")
        @test !occursin(word * "<", tree) && !occursin(" " * word, tree)
    end
    @test occursin("Wird gestartet …", html(htmx_render_children(nothing; texts=de)))
    @test occursin("frühere abgeschlossene ausgeblendet",
        html(htmx_render_children(root; texts=de, max_finished=0)))

    # The poller wrapper carries the words once; the tree inside does not repeat them.
    poller = html(ext._polling_running(root; label="Preisträgerliste abrufen", poll_url="/poll",
        poll_interval="200ms", cancel_url="/stop", texts=de))
    @test count("data-treebar-texts=", poller) == 1
    @test occursin("class=\"treebar-poller\"", poller) && occursin(attr, poller)
    @test occursin(">Läuft</span>", poller)
    @test occursin("aria-label=\"Live-Aktualisierung anhalten\"", poller)
    @test occursin("title=\"Live-Aktualisierung anhalten (die Arbeit läuft im Hintergrund weiter)\"", poller)
    @test occursin("play?&#39;Live-Aktualisierung fortsetzen&#39;:&#39;Live-Aktualisierung anhalten&#39;", poller)
    @test occursin("Preisträgerliste abrufen — läuft …", poller)
    @test occursin(">Abbrechen</a>", poller)
    # Before the first node exists, the badge's elapsed says the work is starting.
    @test ext._badge_elapsed(nothing, de) == "Wird gestartet …"
    finalize_progress!(counted)
    finalize_progress!(root)
    done_html = html(ext._polling_resolve(:value, root; label="x", poll_url="/p",
        poll_interval="1s", cancel_url="", render_result=identity, texts=de))
    @test occursin("<summary>Fortschritt</summary>", done_html)
    @test occursin("fertig (", done_html)

    entries = [(; key=1, label="eins", state=:running, elapsed_ms=3_900),
               (; key=2, label="zwei", state=:queued, elapsed_ms=0, meta=(; position=2))]
    board = html(htmx_render_board(entries; poll_url="/jobs", texts=de))
    @test count("data-treebar-texts=", board) == 1
    @test occursin("class=\"treebar-board\"", board) && occursin(attr, board)
    @test occursin("1 laufend · 1 wartend", board)
    @test occursin(" — 3,9 s bisher", board)
    @test occursin(" — wartet · Nr. 2", board)
    @test occursin("v===&#39;1&#39;?&#39;Fortsetzen&#39;:&#39;Anhalten&#39;;\">Anhalten</button>", board)
    @test occursin("Keine laufenden Aufträge.", board)
    @test occursin("Keine laufenden Aufträge.", html(htmx_render_board([]; texts=de)))
    @test occursin("Selbst gewählt", html(htmx_render_board([]; texts=de, empty="Selbst gewählt")))
    # Quotes in a word stay data: escaped for the inline handler and the JSON.
    quoted = treebar_texts(:de; board_resume="Weiter'", polling="Läuft \"jetzt\"")
    @test occursin("?&#39;Weiter\\&#39;&#39;:", html(htmx_render_board(entries; poll_url="/jobs", texts=quoted)))
    @test occursin("&quot;Läuft \\&quot;jetzt\\&quot;&quot;", html(htmx_render_board(entries; texts=quoted)))

    frame = htmx_ws_render(root; id="lauf", texts=de)
    @test count("data-treebar-texts=", frame) == 1
    @test occursin("class=\"treebar-ws-frame\"", frame) && occursin(attr, frame)
    view = html(htmx_ws_progress("Inhalt"; url="/ws", id="lauf", texts=de))
    @test occursin("<summary>Fortschritt</summary>", view)
    @test occursin("Wird bearbeitet …", view)

    batch = initialize_progress!(:state; description="Stapel")
    @progress batch "Einträge" for item in 1:2
        @progress "Laden"
        @progress "Prüfen"
    end
    overview = html(htmx_render(batch; texts=de, phase_overview=true))
    for word in ("<th scope=\"col\">Phase</th>", ">Ausstehend<", ">Laufend<", ">Abgeschlossen<",
                 ">Wiederverwendet<", ">Fehlgeschlagen<", ">Übersprungen<", "vorbereitete Einträge")
        @test occursin(word, overview)
    end
    @test occursin("prepared items", html(htmx_render(batch; phase_overview=true)))
    # `render_text` is for developers and stays English.
    @test occursin("finished", render_text(batch; phase_overview=true))
    end
end

# Notes a package writes into progress nodes (`treebar_notes`, snag
# consumer-written-813ef5a6): DynamicObjects' "from disk: 26.9 MB",
# "queued · #2" and "(cached)" follow the page language; English stays as the
# plain strings wrote it.

@testsnippet PackageNotes begin
    const notes = treebar_notes(
        en = (from_disk = "from disk: {size}", cached = "(cached)", rows = "{n} rows"),
        de = (from_disk = "aus dem Zwischenspeicher ({size})", cached = "(zwischengespeichert)"))
    note_text(x, t) = Treebars._note_text(x, t)
    # DynamicObjects' `_format_size` (DO 6c729ef, src/DynamicObjects.jl:905), the
    # English a `ByteSize` must reproduce exactly.
    format_size(n) = n < 1024 ? "$n B" :
        n < 1024^2 ? string(round(n / 1024, digits=1), " KB") :
        n < 1024^3 ? string(round(n / 1024^2, digits=1), " MB") :
        string(round(n / 1024^3, digits=1), " GB")
end

@testitem "Package notes: tables, values, refusals, app wording" setup=[TreebarsTestImports, PackageNotes] tags=[:unit, :render] begin
    let
    en, de = treebar_texts(:en), treebar_texts(:de)
    for n in (0, 1, 1023, 1024, 870_400, 1_048_575, 1_048_576, 28_206_694, 2^30, 5 * 2^30 + 123)
        @test note_text(notes(:from_disk; size=ByteSize(n)), en) == "from disk: " * format_size(n)
    end
    @test note_text(notes(:from_disk; size=ByteSize(28_206_694)), de) == "aus dem Zwischenspeicher (26,9 MB)"
    @test note_text(notes(:from_disk; size=ByteSize(512)), de) == "aus dem Zwischenspeicher (512 B)"
    @test note_text(notes(:cached), en) == "(cached)"
    @test note_text(notes(:cached), de) == "(zwischengespeichert)"
    # A language that leaves a text out falls back to English.
    @test note_text(notes(:rows; n=3), de) == "3 rows"
    # Treebars' own words.
    @test note_text(treebar_note(:queued_position; position=2), en) == "queued · #2"
    @test note_text(treebar_note(:queued_position; position=2), de) == "wartet · Nr. 2"
    @test note_text(treebar_note(:queued), de) == "wartet"
    @test note_text("as written", de) == "as written"
    @test en.locale === :en && de.locale === :de

    # Refusals: a typo or an English-only value fails where it is written.
    @test_throws ArgumentError treebar_notes(de = (cached = "x",))
    @test_throws ArgumentError treebar_notes(en = (;))
    @test_throws ArgumentError treebar_notes(en = "(cached)")
    @test_throws ArgumentError treebar_notes(en = (cached = 1,))
    @test_throws ArgumentError treebar_notes(en = (cached = "x",), ge = (cached = "y",))
    @test_throws ArgumentError treebar_notes(en = (cached = "x",), de = (cachd = "y",))
    @test_throws ArgumentError treebar_notes(en = (cached = "x",), de = (cached = "{n} y",))
    @test_throws ArgumentError notes(:nonsense)
    @test_throws ArgumentError notes(:from_disk)
    @test_throws ArgumentError notes(:cached; size=ByteSize(1))
    @test_throws ArgumentError notes(:rows; n=1.5)
    @test_throws ArgumentError notes(:rows; n=true)
    # An integer is allowed and written as given.
    @test note_text(notes(:from_disk; size=12), en) == "from disk: 12"
    @test_throws ArgumentError ByteSize(-1)
    @test_throws ArgumentError treebar_note(:nonsense)
    @test_throws ArgumentError treebar_note(:locale)
    @test_throws ArgumentError treebar_note(:queued_position)
    @test_throws ArgumentError treebar_note(:queued; position=1)

    # An app rewords a package's texts in its own texts, checked against the table.
    app = treebar_texts(:de, notes => (from_disk = "von der Festplatte ({size})",); stop="Anhalten")
    @test app.stop == "Anhalten" && app.locale === :de
    @test note_text(notes(:from_disk; size=ByteSize(28_206_694)), app) == "von der Festplatte (26,9 MB)"
    @test note_text(notes(:cached), app) == "(zwischengespeichert)"
    merged = treebar_texts(:de, notes => (cached = "(gecacht)",), notes => (from_disk = "Platte {size}",))
    @test note_text(notes(:cached), merged) == "(gecacht)"
    @test note_text(notes(:from_disk; size=ByteSize(1)), merged) == "Platte 1 B"
    other = treebar_notes(en = (cached = "(other)",))
    @test note_text(other(:cached), app) == "(other)"
    @test_throws ArgumentError treebar_texts(:de, notes => (nonsense = "x",))
    @test_throws ArgumentError treebar_texts(:de, notes => (cached = "{size}",))
    @test_throws ArgumentError treebar_texts(:de, notes => (cached = 1,))
    @test_throws ArgumentError treebar_texts(:de, notes => "x")
    @test_throws ArgumentError treebar_texts(:de, :cached => (cached = "x",))
    @test treebar_texts(:de) == de
    @test treebar_texts(:de, notes => (cached = "x",)) == treebar_texts(:de, notes => (cached = "x",))
    end
end

@testitem "Package notes render in the page's language; English is unchanged" setup=[TreebarsTestImports, PackageNotes] tags=[:unit, :render] begin
    let
    html(x) = repr(MIME"text/html"(), x)
    ext = Base.get_extension(Treebars, :HTMXObjectsExt)
    de = treebar_texts(:de)
    size = 28_206_694
    # DynamicObjects' three notes, once as the strings it writes today and once as notes.
    strings = (load="from disk: " * format_size(size), queue="queued · #2", hit="(cached)")
    noted = (load=notes(:from_disk; size=ByteSize(size)),
             queue=treebar_note(:queued_position; position=2), hit=notes(:cached))
    root = initialize_progress!(:state; description="Bedarfskarte Lieferflächen")
    start_progress!(root)
    load = initialize_progress!(root; description="Lieferflächenbedarf je Blockseite")
    queued = prepare_progress!(root; description="Zusammenfassung")
    hit = initialize_progress!(root; description="Blockseiten")
    finalize_progress!(hit)
    counted = initialize_progress!(root, 4; description="Dateien")
    bare = initialize_progress!(root; description="")
    hidden = initialize_progress!(root; description="Prüfen")
    initialize_progress!(hidden; description="x", displayed=false)
    function write!(m)
        update_progress!(load, m.load); update_progress!(queued, m.queue)
        update_progress!(hit, m.hit); update_progress!(counted, m.load)
        update_progress!(bare, m.queue); update_progress!(hidden, m.load)
    end
    # Two renders differ only in the elapsed times.
    still(s) = replace(s, r"data-elapsed-ms=\"\d+\"" => "", r"[\d.]+(ms|s)\b" => "T")
    write!(strings)
    plain_html, plain_text = html(htmx_render(root)), render_text(root)
    plain_state = Treebars.progress_state(root)
    write!(noted)
    @test still(html(htmx_render(root))) == still(plain_html)
    @test still(html(htmx_render(root; texts=treebar_texts(:en)))) == still(plain_html)
    @test still(render_text(root)) == still(plain_text)
    @test Treebars.progress_state(load)["message"] == strings.load
    @test still(repr(Treebars.progress_state(root))) == still(repr(plain_state))
    @test occursin("Lieferflächenbedarf je Blockseite from disk: 26.9 MB", plain_html)

    german = html(htmx_render(root; texts=de))
    for words in ("Lieferflächenbedarf je Blockseite aus dem Zwischenspeicher (26,9 MB)",
                  "Zusammenfassung wartet · Nr. 2", "Blockseiten (zwischengespeichert)",
                  "<span class=\"treebar-message\">aus dem Zwischenspeicher (26,9 MB)</span>")
        @test occursin(words, german)
    end
    for words in ("from disk", "26.9", "queued", "(cached)")
        @test !occursin(words, german)
    end
    # A message-only node whose children all flatten away shows its note muted.
    @test occursin("aus dem Zwischenspeicher (26,9 MB)", html(htmx_render_children(hidden; texts=de)))
    # A note is content: the node renders, and its duration shows.
    @test !Treebars._is_bare_wrapper(bare)
    @test ext._root_renders_duration(load)
    # `render_text` is for developers and stays English.
    @test occursin("— from disk: 26.9 MB", render_text(root))

    # Left out, `texts` follows the answer's page language (HTMXObjects page_lang()).
    if isdefined(HTMXObjects, :_with_page_lang)
        @test occursin("aus dem Zwischenspeicher (26,9 MB)",
            HTMXObjects._with_page_lang(() -> html(htmx_render(root)), "de"))
        @test occursin("from disk: 26.9 MB",
            HTMXObjects._with_page_lang(() -> html(htmx_render(root)), "en"))
    end
    # A poller and a WebSocket frame fill notes the same way.
    poller = html(ext._polling_running(root; label="Lieferflächen", poll_url="/poll",
        poll_interval="200ms", cancel_url="", texts=de))
    @test occursin("aus dem Zwischenspeicher (26,9 MB)", poller) && !occursin("from disk", poller)
    @test occursin("wartet · Nr. 2", htmx_ws_render(root; id="lauf", texts=de))
    finalize_progress!(root)
    end
end

@testitem "Package notes on the :term backend are English" setup=[TermTestImports, PackageNotes] tags=[:unit, :term] begin
    let
        root = initialize_progress!(:term)
        child = initialize_progress!(root, 2; description="load")
        update_progress!(child, notes(:from_disk; size=ByteSize(28_206_694)))
        @test child.impl.columns[end].msg[] == "from disk: 26.9 MB"
        finalize_progress!(child.impl)
        finalize_progress!(root.impl)
    end
end
