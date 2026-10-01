# WebSocket push progress demos. `fake_sampling` creates per-connection state
# in memory; no persistent cache, so WebSocketsData is empty.

@dynamicstruct struct WebSocketsData end

# Wrap WS payload: `<div id=target_id><article><header>title</header>body…</article></div>`.
# Used both for progress pushes (body = htmx_render(node)) and final results.
_ws_html(target_id, title, body...) =
    node_to_html(h.div(; id=target_id)(h.article(h.header(title), body...)))

@htmx struct WebSocketsRoutes
    # HTML helper: renders a task's final article (result or error).
    send_result(key, task) = begin
        if istaskfailed(task)
            _ws_html("ws-result", "Failed", h.pre(sprint(showerror, task.result)))
        else
            rv = fetch(task)
            _ws_html("ws-result", "Result for '$key'", sample_summary(rv), sample_minmax(rv))
        end
    end

    # Simple form submission: HTMX WS sends JSON with the form's `key` field;
    # parse it out, spawn a fake sampling task, stream progress via ws_progress,
    # then send the final result article.
    @ws ws() = begin
        for msg in __ws__
            m = match(r"\"key\"\s*:\s*\"([^\"]+)\"", msg)
            key = isnothing(m) ? msg : m.captures[1]
            p = initialize_progress!(:state; description="Running '$key'")
            task = Threads.@spawn fake_sampling(p)
            ws_progress(__ws__, p;
                render = node -> _ws_html("ws-result", "Computing '$key'...", htmx_render(node)))
            try
                send(__ws__, send_result(key, task))
            catch err
                # Client disconnected mid-stream — expected on tab close.
                # Log and break the loop rather than silently swallowing.
                @debug "ws send_result failed (client gone?)" key=key exception=(err, catch_backtrace())
                break
            end
        end
    end

    # Fresh `ws-connect` element for the chosen kwargs. The index form `hx-get`s
    # this and swaps the result into the persistent `hx-ext=ws` container; htmx
    # processes the swapped-in child, so the (already-active) ws extension opens
    # the socket. This is the reliable way to (re)connect with dynamic params —
    # mutating `ws-connect` on an already-processed element does NOT reconnect.
    @get connect(; key="default", n_steps::Int=200, speed::Int=20) =
        h.div(; ws_connect = query_url(__self__ / "run"; key, n_steps, speed))

    # Kwargs pulled from the query string (key/n_steps/speed).
    @ws run(; key="default", n_steps::Int=200, speed::Int=20) = begin
        sleep_per_step = speed / 1000.0
        p = initialize_progress!(:state; description="Running '$key' ($(n_steps) steps, $(speed)ms)")
        task = Threads.@spawn fake_sampling(p; n_steps, sleep_per_step)
        ws_progress(__ws__, p;
            render = node -> _ws_html("ws-param-result", "'$key' — $(n_steps) steps @ $(speed)ms", htmx_render(node)))
        html = if istaskfailed(task)
            _ws_html("ws-param-result", "Failed")
        else
            rv = fetch(task)
            _ws_html("ws-param-result", "Result for '$key'",
                h.p("$(length(rv)) values. Final: $(short_string(rv[end]))"))
        end
        try
            send(__ws__, html)
        catch err
            # Client disconnected before final result; nothing to recover.
            @debug "ws run final send failed (client gone?)" key=key exception=(err, catch_backtrace())
        end
    end
end
