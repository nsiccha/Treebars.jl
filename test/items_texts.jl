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
