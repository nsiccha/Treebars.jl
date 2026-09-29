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
