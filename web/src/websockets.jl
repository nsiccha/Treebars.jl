# WebSocket push progress demos. `fake_sampling` creates per-connection state
# in memory; no persistent cache, so WebSocketsData is empty.

@dynamicstruct struct WebSocketsData end

@htmx struct WebSocketsRoutes
    # HTML helper: renders a task's final article (result or error).
    send_result(key, task) = begin
        rv = istaskfailed(task) ? nothing : fetch(task)
        article = isnothing(rv) ?
            result_article("Failed", h.pre(sprint(showerror, task.result))) :
            result_article("Result for '$key'", sample_summary(rv), sample_minmax(rv))
        node_to_html(h.div(; id="ws-result")(article))
    end

    # Simple form submission: HTMX WS sends JSON with the form's `key` field;
    # parse it out, spawn a fake sampling task, stream progress via ws_progress,
    # then send the final result article.
    @ws ws = begin
        for msg in __ws__
            m = match(r"\"key\"\s*:\s*\"([^\"]+)\"", msg)
            key = isnothing(m) ? msg : m.captures[1]
            p = initialize_progress!(:state; description="Running '$key'")
            task = Threads.@spawn fake_sampling(p)
            ws_progress(__ws__, p; render=node -> node_to_html(
                h.div(; id="ws-result")(
                    h.article(h.header("Computing '$key'..."), htmx_render(node))
                )
            ))
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

    # Kwargs pulled from the query string (key/n_steps/speed).
    @ws run(; key="default", n_steps::Int=200, speed::Int=20) = begin
        sleep_per_step = speed / 1000.0
        p = initialize_progress!(:state; description="Running '$key' ($(n_steps) steps, $(speed)ms)")
        task = Threads.@spawn fake_sampling(p; n_steps, sleep_per_step)
        ws_progress(__ws__, p; render=node -> node_to_html(
            h.div(; id="ws-param-result")(
                h.article(h.header("'$key' — $(n_steps) steps @ $(speed)ms"), htmx_render(node))
            )
        ))
        article = istaskfailed(task) ?
            result_article("Failed") :
            result_article("Result for '$key'", sample_summary(fetch(task)))
        html = node_to_html(h.div(; id="ws-param-result")(article))
        try
            send(__ws__, html)
        catch err
            # Client disconnected before final result; nothing to recover.
            @debug "ws run final send failed (client gone?)" key=key exception=(err, catch_backtrace())
        end
    end
end
