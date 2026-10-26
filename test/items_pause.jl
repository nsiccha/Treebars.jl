using TestItemRunner

# The pause/play control a visitor-facing page leaves out (`pause=`, snag
# visitor-apps-can-148cfaf6): an explicit Bool decides; `nothing` follows the
# page's `__progress_pause__` through `HTMXObjects.page_progress_pause()`, and
# shows the control when the page declares none.

@testmodule PauseFixtures begin
using DynamicObjects, Treebars

export _PAUSE_GATE, _PauseGateTest

const _PAUSE_GATE = Ref(Base.Event())

@dynamicstruct struct _PauseGateTest
    __status__ = initialize_progress!(:state; description="PauseGate")
    "Gated visitor work"
    gated(key) = (wait(_PAUSE_GATE[]); key)
end
end

@testitem "pause: an explicit Bool wins, nothing follows the page" setup=[TreebarsTestImports] tags=[:unit, :render] begin
    let
    ext = Base.get_extension(Treebars, :HTMXObjectsExt)
    @test ext._pause(true) === true
    @test ext._pause(false) === false
    # The page's declaration: none shows the control, a Bool is taken as is.
    @test ext._page_pause_value(nothing) === true
    @test ext._page_pause_value(false) === false
    @test ext._page_pause_value(true) === true
    @test_throws ArgumentError ext._page_pause_value("no")
    # Outside any route nothing is declared, whether or not this HTMXObjects
    # provides the accessor yet, so the control shows.
    @test ext._page_pause() === nothing
    @test ext._pause(nothing) === true
    for bad in (:off, 0, "false")
        @test_throws ArgumentError ext._pause(bad)
        @test_throws ArgumentError htmx_render_board([]; pause=bad)
    end
    end
end

@testitem "pause=false: a poller badge without the pause control" setup=[PauseFixtures, TreebarsTestImports] tags=[:unit, :render] begin
    let
    html(x) = repr(MIME"text/html"(), x)
    ext = Base.get_extension(Treebars, :HTMXObjectsExt)
    # Two renders differ only in the running nodes' elapsed times.
    still(s) = replace(s, r"data-elapsed-ms=\"\d+\"" => "", r" — [\d.]+(ms|s) so far" => "")
    button = r"<button class=\"treebar-pause\".*?</button>"s

    root = initialize_progress!(:state; description="Job")
    start_progress!(root)
    initialize_progress!(root; description="Load")
    running(; kw...) = html(ext._polling_running(root; label="Background job", poll_url="/poll",
        poll_interval="200ms", cancel_url="/stop", kw...))
    shown = running()
    @test count(button, shown) == 1
    @test still(shown) == still(running(pause=true))
    hidden = running(pause=false)
    @test !occursin("treebar-pause", hidden)
    # Exactly the control goes; the badge's status, bar and freshness note, the
    # label, the Stop button and the live tree stay.
    @test still(replace(shown, button => "")) == still(hidden)
    for keep in ("treebar-badge-strip", ">Polling</span>", "treebar-badge-bar",
                 "treebar-freshness", "treebar-badge-label", ">Stop</a>",
                 "treebar-poller-inner", "Load")
        @test occursin(keep, hidden)
    end
    # German pages lose the same control and keep their words.
    de = html(ext._polling_running(root; label="Job im Hintergrund", poll_url="/poll",
        poll_interval="200ms", cancel_url="", texts=treebar_texts(:de), pause=false))
    @test !occursin("treebar-pause", de)
    @test occursin(">Läuft</span>", de)
    # The Task contract threads it too.
    task = @async sleep(30)
    via_task = html(ext._polling_resolve(task, root; label="Background job", poll_url="/poll",
        poll_interval="200ms", cancel_url="", render_result=identity, pause=false))
    @test occursin("treebar-poller-inner", via_task)
    @test !occursin("treebar-pause", via_task)
    finalize_progress!(root)

    # End to end through `polling_fetchindex`, in flight.
    _PAUSE_GATE[] = Base.Event()
    app = _PauseGateTest()
    try
        visitor = html(polling_fetchindex(identity, app.gated, :k; poll_url="/p",
            label="Visitor job", track_job=false, pause=false))
        @test occursin("treebar-poller-inner", visitor)
        @test !occursin("treebar-pause", visitor)
        developer = html(polling_fetchindex(identity, app.gated, :k; poll_url="/p",
            label="Visitor job", track_job=false))
        @test count(button, developer) == 1
        @test_throws ArgumentError polling_fetchindex(identity, app.gated, :k; poll_url="/p", pause=:no)
    finally
        notify(_PAUSE_GATE[])
    end
    @test timedwait(() -> !occursin("treebar-poller-inner",
        html(polling_fetchindex(identity, app.gated, :k; poll_url="/p", track_job=false))), 10.0) === :ok
    finalize_progress!(app.__status__)
    end
end

@testitem "pause=false: a live board without its Pause button" setup=[BoardFixtures, TreebarsTestImports] tags=[:unit, :board] begin
    let
    entries = [(; key=1, label="one", state=:running, elapsed_ms=10)]
    shown = _board_html(htmx_render_board(entries; poll_url="/jobs"))
    @test count("class=\"treebar-board-pause\"", shown) == 1
    hidden = _board_html(htmx_render_board(entries; poll_url="/jobs", pause=false))
    @test !occursin("treebar-board-pause", hidden)
    # The count, the freshness note and the poll element stay.
    for keep in ("1 running", "treebar-freshness", "treebar-board-poll", "data-treebar-key=\"1\"")
        @test occursin(keep, hidden)
    end
    @test !occursin("treebar-board-pause", htmx_ws_render_board(entries; pause=false))
    @test occursin("treebar-board-pause", htmx_ws_render_board(entries))

    # `ws_board` resolves it once, for every frame.
    frames, (status, _) = capture_board_frames() do ws
        ws_board(ws, () -> entries; interval=0.01, until=() -> true, pause=false)
    end
    @test status === :ok
    @test !isempty(frames)
    @test all(f -> !occursin("treebar-board-pause", f), frames)
    end
end
