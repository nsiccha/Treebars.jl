# Server-sent-event progress demo: `htmx_sse_container` opens the stream on its
# persistent wrapper and `sse_fetchindex` pushes the same fragments as the
# WebSocket demo — `event: progress` while computing, one `event: done` at the
# end, which also closes the EventSource. Needs an HTMXObjects with `@sse`
# routes; without one the section says so instead.

@dynamicstruct struct SSEData
    __status__ = initialize_progress!(:state; description="SSE")

    "Sampling '$(key)' ($(n_steps) steps @ $(speed)ms)"
    runs(key, n_steps, speed, fail) = fake_sampling(__status__;
        n_steps, sleep_per_step = speed / 1000, fail_at = fail ? n_steps ÷ 2 : nothing)
end

@static if isdefined(HTMXObjects, :SSEStream)
    @htmx struct SSERoutes
        (; sse) = __appdata__
        (; runs) = sse

        # Client side of one run, prepended to the run list by the index form.
        @get start(; key="sse-demo", n_steps::Int=200, speed::Int=20, fail::Bool=false, force::Bool=false) =
            htmx_sse_container(query_url(__self__ / "run"; key, n_steps, speed, fail, force))

        @sse run(; key="sse-demo", n_steps::Int=200, speed::Int=20, fail::Bool=false, force::Bool=false) =
            sse_fetchindex(__sse__, runs, key, n_steps, speed, fail; force,
                           label = "Computing '$key'") do rv
                result_article("Result for '$key'", sample_summary(rv), sample_minmax(rv))
            end
    end
else
    @htmx struct SSERoutes
        @get start(; key="sse-demo", n_steps::Int=200, speed::Int=20, fail::Bool=false, force::Bool=false) =
            h.p("This demo needs an HTMXObjects with `@sse` routes."; class="u-text-muted")
    end
end
