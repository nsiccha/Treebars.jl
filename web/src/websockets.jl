# WebSocket push progress demo: `htmx_ws_container` renders the client side
# (persistent wrapper + inner with a generated id, carried to the socket route
# in its URL) and the WebSocket method of `polling_fetchindex` streams the tree
# into it, then the result — or the recorded failure beside the frozen tree.

@dynamicstruct struct WebSocketsData
    __status__ = initialize_progress!(:state; description="WebSockets")

    "Sampling '$(key)' ($(n_steps) steps @ $(speed)ms)"
    runs(key, n_steps, speed, fail) = fake_sampling(__status__;
        n_steps, sleep_per_step = speed / 1000, fail_at = fail ? n_steps ÷ 2 : nothing)
end

@htmx struct WebSocketsRoutes
    (; websockets) = __appdata__
    (; runs) = websockets

    # Client side of one run. The index form prepends it to the run list, so
    # several streams share the page; each gets its own id, generated here and
    # handed to the socket route in its URL.
    @get start(; key="ws-demo", n_steps::Int=200, speed::Int=20, fail::Bool=false, force::Bool=false) =
        htmx_ws_container(id -> query_url(__self__ / "run"; key, n_steps, speed, fail, force, id))

    @ws run(; key="ws-demo", n_steps::Int=200, speed::Int=20, fail::Bool=false, force::Bool=false, id) =
        polling_fetchindex(__ws__, runs, key, n_steps, speed, fail; id, force,
                           label = "Computing '$key'") do rv
            result_article("Result for '$key'", sample_summary(rv), sample_minmax(rv))
        end
end
