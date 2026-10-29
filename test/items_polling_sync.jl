using TestItemRunner

# `polling_fetchindex(…; sync=true)` resolves now but still returns the poller's
# HTML. A callback returning a finished answer (a response, not content) has it
# written into that HTML; a warning says so once (todo 1n3cybx, from `ee12842`).

@testmodule PollingSyncFixtures begin
    using Treebars, DynamicObjects
    export SyncPoll
    @dynamicstruct struct SyncPoll
        __status__ = initialize_progress!(:state; description="Sync poll")
        value(key) = "value-$key"
    end
end

@testitem "polling_fetchindex warns once when render_result returns a response" setup=[PollingSyncFixtures] tags=[:unit, :polling] begin
    using Treebars, HTMXObjects, HTTP, Test
    let
    app = SyncPoll()
    html(x) = sprint(show, MIME"text/html"(), x)

    # Content renders without a word.
    out = @test_logs polling_fetchindex(app.value, :a; sync=true) do v
        HTMXObjects.h.p(v)
    end
    @test occursin("value-a", html(out))

    # A response is written into the wrapper, not returned, and says so.
    out = @test_logs (:warn, r"render_result returned a Response, which is written into the poller's HTML") polling_fetchindex(app.value, :b; sync=true) do v
        HTTP.Response(200, "{\"v\": \"$v\"}")
    end
    @test !(out isa HTTP.Response)
    @test occursin("treebar-terminal", html(out))

    # HTMXObjects' own final answers take the same warning.
    ext = Base.get_extension(Treebars, :HTMXObjectsExt)
    plain = which(ext._warn_wrapped_response, (Any,))
    @test which(ext._warn_wrapped_response, (HTMXObjects.MIMEResponse,)) != plain
    if isdefined(HTMXObjects, :JSONResponse)
        @test which(ext._warn_wrapped_response, (HTMXObjects.JSONResponse,)) != plain
    end
    end # let (restores @testset hard scope)
end
