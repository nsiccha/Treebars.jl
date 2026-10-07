using TestItemRunner

@testmodule StreamingFixtures begin
using HTTP, Sockets, Treebars, HTMXObjects
export capture_stream

function capture_stream(run; disconnect=false)
    # HTTP 1.x accepts a pre-bound listener; no guessed or raced test port.
    socket = Sockets.listen(ip"127.0.0.1", 0)
    port = last(Sockets.getsockname(socket))
    outcome = Channel{Any}(1)
    server = HTTP.WebSockets.listen!("127.0.0.1", port; server=socket) do ws
        try
            put!(outcome, (:ok, run(ws)))
        catch err
            put!(outcome, (:error, err))
        end
    end
    frames = String[]
    try
        HTTP.WebSockets.open("ws://127.0.0.1:$port/feed"; proxy=nothing) do ws
            for frame in ws
                push!(frames, String(frame))
                disconnect && break
            end
        end
        timedwait(() -> isready(outcome), 10) == :ok ||
            error("WebSocket producer did not finish after delivery ended")
        frames, take!(outcome)
    finally
        close(server)
        isopen(socket) && close(socket)
    end
end
end

@testitem "Streaming view and public HTML renderer" tags=[:streaming] setup=[TreebarsTestImports] begin
    html(x) = repr(MIME"text/html"(), x)
    p = initialize_progress!(:state, 2; description="Sampling")
    rendered = htmx_ws_render(p; id="public-progress")
    @test rendered isa String
    @test occursin("id=\"public-progress\"", rendered)
    @test occursin("0 / 2", rendered)
    @test occursin("data-treebar-status=\"running\"", rendered)
    finalize_progress!(p)
    @test occursin("data-treebar-status=\"finished\"", htmx_ws_render(p))

    initial = h.div(; id="plot")("Initial plot")
    view = html(htmx_ws_progress(initial; url="/feed", id="stream", N=2))
    @test occursin("id=\"plot\"", view)
    @test occursin("ws-connect=\"/feed\"", view)
    @test occursin("hx-ext=\"ws\"", view)
    @test occursin("id=\"stream-progress\"", view)
    @test occursin("id=\"stream-updates\"", view)
    @test occursin("data-treebar-status=\"pending\"", view)
    @test occursin(r"<details[^>]*\bopen(?:=|\s|>)", view)
    closed = html(htmx_ws_progress(initial; url="/feed", id="stream", collapsed=true))
    @test !occursin(r"<details[^>]*\bopen(?:=|\s|>)", closed)
    @test_throws ArgumentError htmx_ws_progress(initial; url="/feed", id="")
end

@testitem "WebSocket frames hold the pill state viewers toggle" tags=[:streaming] setup=[TreebarsTestImports] begin
    let
        html(x) = repr(MIME"text/html"(), x)
        root = initialize_progress!(:state; description="Run")
        finalize_progress!(initialize_progress!(root; description="loaded"))
        initialize_progress!(root, 10; description="fitting")
        frame() = htmx_ws_render(root; id="run-progress")
        first_frame = frame()
        # The frame root is the pill scope (with the poller's defaults); the
        # tree below it is unscoped, so pill toggles act on the frame.
        @test startswith(first_frame, "<div id=\"run-progress\" class=\"treebar-ws-frame\" data-show-finished=\"0\" " *
            "data-show-pending=\"1\" data-show-failed=\"1\" data-show-skipped=\"0\" data-show-reused=\"0\">")
        @test occursin("treebar-pill-finished", first_frame)
        @test !occursin(r"class=\"treebar-children\" data-show", first_frame)
        @test occursin("<div id=\"run-progress\" class=\"treebar-ws-frame\"",
            html(htmx_ws_progress("Content"; url="/feed", id="run", progress=root)))
        @test occursin(".treebar-ws-frame[data-show-finished=\"1\"]", html(htmx_treebar_styles()))

        # Opt in with TREEBARS_BROWSER_TESTS=1 (needs google-chrome or
        # chromium): a pill toggled on one frame still holds on the next,
        # which replaces the whole frame as the htmx ws extension does.
        if get(ENV, "TREEBARS_BROWSER_TESTS", "") != "1"
            @test_skip true
        else
            chrome = Sys.which("google-chrome")
            isnothing(chrome) && (chrome = Sys.which("chromium"))
            isnothing(chrome) && error("TREEBARS_BROWSER_TESTS=1 requires Chrome")
            finalize_progress!(initialize_progress!(root; description="checked"))
            next_frame = frame()
            literal(s) = "'" * replace(s, "\\"=>"\\\\", "'"=>"\\'", "\n"=>"\\n", "</"=>"<\\/") * "'"
            driver = """
            window.addEventListener('load', async function(){
                var next = $(literal(next_frame));
                var shown = function(){ return Array.prototype.map.call(document.querySelectorAll('.treebar-child-finished'),
                    function(el){ return getComputedStyle(el).display === 'none' ? 0 : 1; }).join(''); };
                var r = [shown()];
                var old = document.getElementById('run-progress');
                old.querySelector('.treebar-pill-finished').click();
                r.push(shown());
                old.outerHTML = next;
                await new Promise(function(done){ setTimeout(done, 0); });
                var now = document.getElementById('run-progress');
                r.push(now !== old ? now.dataset.showFinished + now.dataset.showPending : 'same', shown());
                var out = document.createElement('pre'); out.id = 'result';
                out.textContent = r.join('|');
                document.body.appendChild(out);
            });
            """
            dir = mktempdir()
            file = joinpath(dir, "frames.html")
            write(file, "<!DOCTYPE html>" * html(h.html(
                h.head(htmx_treebar_styles(), htmx_treebar_script()),
                h.body(Raw(first_frame), h.script(Raw(driver))))))
            profile = joinpath(dir, "profile")
            dom = read(pipeline(`$chrome --headless=new --no-sandbox --disable-gpu --disable-dev-shm-usage --virtual-time-budget=2000 --dump-dom --user-data-dir=$profile file://$file`; stderr=devnull), String)
            result = match(r"<pre id=\"result\">([^<]*)</pre>", dom)
            @test result !== nothing
            # hidden, then shown on click, and still shown (toggle carried, the
            # pending default intact) on a replacement frame with two finished.
            @test result === nothing ? false : result.captures[1] == "0|1|11|11"
        end
        finalize_progress!(root)
    end
end

@testitem "Streaming producer delivers every fragment and final progress" tags=[:streaming] setup=[TreebarsTestImports, StreamingFixtures] begin
    parent = initialize_progress!(:state; description="App")
    frames, outcome = StreamingFixtures.capture_stream() do ws
        ws_progress(ws; id="stream", N=96, parent, interval=0.001, buffer=2) do publish, p
            @progress p "Fine steps" for i in 1:96
                publish(h.script(Raw("window.update($i);")))
                update_progress!(p, i)
            end
            96
        end
    end
    @test outcome == (:ok, 96)
    @test occursin("0 / 96", first(frames))
    @test !occursin("window.update", first(frames))
    @test occursin("data-treebar-status=\"finished\"", last(frames))
    @test occursin("96 / 96", last(frames))
    @test all(frame -> occursin("id=\"stream-progress\"", frame), frames)
    @test all(frame -> !occursin("stream-disclosure", frame), frames)
    @test any(frame -> occursin("Fine steps", frame), frames)
    joined = join(frames)
    for i in 1:96
        @test length(findall("window.update($i);", joined)) == 1
    end
    @test all(frame -> length(findall("window.update(", frame)) <= 2, frames)
    @test length(parent.children) == 1
    @test is_finished(only(parent.children))
    @test is_running(parent)
    finalize_progress!(parent)
end

@testitem "Streaming failures surface and leave a failed tree" tags=[:streaming] setup=[TreebarsTestImports, StreamingFixtures] begin
    frames, outcome = StreamingFixtures.capture_stream() do ws
        ws_progress(ws; id="stream", interval=0.001, buffer=1) do publish, p
            publish(h.script(Raw("window.partial();")))
            error("producer failed deliberately")
        end
    end
    @test first(outcome) == :error
    @test last(outcome) isa TaskFailedException
    @test occursin("producer failed deliberately", sprint(showerror, last(outcome)))
    @test occursin("data-treebar-status=\"failed\"", last(frames))
    @test length(findall("window.partial();", join(frames))) == 1
    # Contract (snag popui-stream-err-b8a57b9e): failed frames carry tree
    # state, counters and pills only — the tree renderer never renders the
    # exception text. The reason propagates to the route, not the browser.
    @test all(frame -> !occursin("producer failed deliberately", frame), frames)

    # A consumer that wants the reason visible in the browser publishes its
    # own escaped alert through `publish` and rethrows the original error.
    frames, outcome = StreamingFixtures.capture_stream() do ws
        ws_progress(ws; id="stream", interval=0.001, buffer=8) do publish, p
            try
                @progress p for i in 1:32
                    i == 1 && error("vessel must be 1..5 (got 0)")
                end
            catch err
                publish(h.div(role="alert")("Sampling failed: vessel must be 1..5 (got 0) <done>"))
                rethrow()
            end
        end
    end
    @test first(outcome) == :error
    @test last(outcome) isa TaskFailedException
    @test occursin("vessel must be", sprint(showerror, last(outcome)))
    alerted = join(frames)
    @test occursin("Sampling failed:", alerted)
    @test occursin("&lt;done&gt;", alerted)
    @test !occursin("<done>", alerted)
    @test occursin("data-treebar-status=\"failed\"", last(frames))

    frames, outcome = StreamingFixtures.capture_stream() do ws
        p = initialize_progress!(:state; description="Render failure")
        try
            ws_progress(ws, p; render=node -> error("renderer failed deliberately"))
        finally
            finalize_progress!(p)
        end
    end
    @test first(outcome) == :error
    @test occursin("renderer failed deliberately", sprint(showerror, last(outcome)))
    @test isempty(frames)
end

@testitem "Streaming OOB fragments swap outside the sink" tags=[:streaming] setup=[TreebarsTestImports, StreamingFixtures] begin
    # Contract (snag ws-progress-publ-d1b74c9b): a published Node carrying
    # `hx-swap-oob` targets an element OUTSIDE the `<id>-updates` sink. The
    # htmx ws extension runs oobSwap over TOP-LEVEL message children only, so
    # such a node must be delivered as a top-level sibling — nested inside the
    # sink wrapper it lands verbatim (duplicate ids, stale target).
    oob_node() = h.div(; id="oob-target", hx_swap_oob="innerHTML")("oob-marker-9c1e")

    # Separated delivery: the plain fragment rides inside the sink wrapper;
    # the OOB-only frame carries no sink wrapper at all.
    frames, outcome = StreamingFixtures.capture_stream() do ws
        ws_progress(ws; id="stream", interval=0.001, buffer=8) do publish, p
            publish(h.div("plain-marker-7f3a"))
            sleep(0.05)
            publish(oob_node())
            sleep(0.05)
            :done
        end
    end
    @test outcome == (:ok, :done)
    plain_frames = filter(f -> occursin("plain-marker-7f3a", f), frames)
    oob_frames = filter(f -> occursin("oob-marker-9c1e", f), frames)
    @test length(plain_frames) == 1
    @test length(oob_frames) == 1
    @test occursin("id=\"stream-updates\"", only(plain_frames))
    oob_frame = only(oob_frames)
    @test !occursin("stream-updates", oob_frame)
    @test occursin("id=\"stream-progress\"", oob_frame)
    @test occursin("hx-swap-oob=\"innerHTML\"", oob_frame)

    # Mixed delivery: both fragments in one drain — the sink wrapper closes
    # before the OOB node opens, so it is a sibling, never nested. The plain
    # fragment is a script (no divs), so the first `</div>` after the wrapper
    # opens is the wrapper's own close tag. Robust to either timing outcome:
    # the same assertions hold when the fragments separate across frames.
    frames, outcome = StreamingFixtures.capture_stream() do ws
        ws_progress(ws; id="stream", interval=0.001, buffer=8) do publish, p
            publish(h.script(Raw("window.plain_marker();")))
            publish(oob_node())
            sleep(0.05)
            :done
        end
    end
    @test outcome == (:ok, :done)
    joined = join(frames)
    @test length(findall("window.plain_marker();", joined)) == 1
    @test length(findall("oob-marker-9c1e", joined)) == 1
    oob_frames = filter(f -> occursin("oob-marker-9c1e", f), frames)
    @test !isempty(oob_frames)
    for frame in oob_frames
        @test occursin("hx-swap-oob=\"innerHTML\"", frame)
        i_updates = findfirst("id=\"stream-updates\"", frame)
        isnothing(i_updates) && continue  # OOB-only frame: trivially outside the sink.
        rest = frame[last(i_updates):end]
        i_close = findfirst("</div>", rest)
        i_oob = findfirst("id=\"oob-target\"", rest)
        @test !isnothing(i_close) && !isnothing(i_oob)
        @test last(i_close) < first(i_oob)
    end
end

@testitem "Streaming disconnect releases bounded publishers" tags=[:streaming] setup=[TreebarsTestImports, StreamingFixtures] begin
    finished = Ref(false)
    p = initialize_progress!(:state, 96; description="Disconnect")
    frames, outcome = StreamingFixtures.capture_stream(; disconnect=true) do ws
        ws_progress(ws, p; id="stream", interval=0.001, buffer=1) do publish, progress
            for i in 1:96
                publish(h.script(Raw("window.update($i);")))
                update_progress!(progress, i)
            end
            finished[] = true
            :completed
        end
    end
    @test length(frames) == 1
    @test outcome == (:ok, :completed)
    @test finished[]
    @test is_finished(p)
    @test p.impl.i == 96
end
