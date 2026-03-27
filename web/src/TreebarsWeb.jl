module TreebarsWeb

using HTMXObjects
using Treebars
import HTTP.WebSockets: send
using TestModules
using Random

include("test/runtests.jl")

node_to_html(node) = sprint(io -> show(io, MIME"text/html"(), node))

# Fake expensive computation that updates progress
function fake_sampling(progress; n_steps=200, sleep_per_step=0.02)
    child = initialize_progress!(progress, n_steps; description="MCMC", propagates=true)
    result = Float64[]
    x = 0.0
    for i in 1:n_steps
        x += randn() * 0.1
        push!(result, x)
        update_progress!(child, i;
            current_value=short_string(x),
            acceptance_rate=short_string(Fraction(min(1.0, 0.5 + i / n_steps / 2))),
        )
        sleep(sleep_per_step)
    end
    finalize_progress!(child)
    result
end


# --- Async computation state (fetchindex + __substatus__ pattern) ---
@dynamicstruct struct AsyncComputations
    __status__ = initialize_progress!(:state; description="Treebars Demo")
    __substatus__(name, args...; kwargs...) =
        initialize_progress!(__status__; description="$name[$(join(args, ","))]")
    results[key] = fake_sampling(__status__)
end
_async = AsyncComputations(; cache_type=:parallel)

function _ws_send_result(key, task)
    rv = istaskfailed(task) ? nothing : fetch(task)
    if isnothing(rv)
        node_to_html(h.div(; id="ws-result")(
            h.article(h.header("Failed"), h.pre(sprint(showerror, task.result)))
        ))
    else
        node_to_html(h.div(; id="ws-result")(
            h.article(
                h.header("Result for '$key'"),
                h.p("Computed $(length(rv)) values. Final: $(short_string(rv[end]))"),
                h.p("Min: $(short_string(minimum(rv))), Max: $(short_string(maximum(rv)))"),
            )
        ))
    end
end


@htmx struct AppContext
    req = nothing

    page(content) = htmx(
        h.main(class="container")(content);
        pico_version="2",
        extra_head=(h.script(; src="https://unpkg.com/htmx-ext-ws@2.0.2/ws.js"), htmx_treebar_styles()),
    )

    # --- Test routes via @include ---
    @include tests = TestRoutes(; req, test_module=@__MODULE__)

    # --- Polling route (using fetchindex + __substatus__) ---
    @get compute(key; rerun="") = fetchindex(_async.results, key; force=!isempty(rerun)) do rv, status
        if rv isa Task && istaskfailed(rv)
            h.article(h.header("Failed"), h.pre(sprint(showerror, rv.result)))
        elseif rv isa Task
            h.div(; hx_get=query_url("/compute/$key"), hx_trigger="every 200ms", hx_swap="outerHTML")(
                h.article(
                    h.header("Computing '$key'..."),
                    htmx_render_children(status),
                )
            )
        else
            h.article(
                h.header("Result for '$key'"),
                h.p("Computed $(length(rv)) values. Final: $(short_string(rv[end]))"),
                h.p("Min: $(short_string(minimum(rv))), Max: $(short_string(maximum(rv)))"),
                h.button("Rerun"; hx_get=query_url("/compute/$key"; rerun="1"), hx_target="closest article", hx_swap="outerHTML"),
            )
        end
    end

    # --- WebSocket routes ---
    # __ws__ is the WebSocket, injected by @htmx's @ws handling
    @ws ws = begin
        for msg in __ws__
            # HTMX WS sends JSON with form fields + HEADERS; extract just the key
            m = match(r"\"key\"\s*:\s*\"([^\"]+)\"", msg)
            key = isnothing(m) ? msg : m.captures[1]
            p = initialize_progress!(:state; description="Running '$key'")
            task = Threads.@spawn fake_sampling(p)
            ws_progress(__ws__, p; render=node -> node_to_html(
                h.div(; id="ws-result")(
                    h.article(h.header("Computing '$key'..."), htmx_render(node))
                )
            ))
            try; send(__ws__, _ws_send_result(key, task)); catch; break; end
        end
    end

    # Kwargs only: /ws_run?n_steps=100&speed=20&key=mykey
    @ws ws_run(; key="default", n_steps::Int=200, speed::Int=20) = begin
        sleep_per_step = speed / 1000.0
        p = initialize_progress!(:state; description="Running '$key' ($(n_steps) steps, $(speed)ms)")
        task = Threads.@spawn fake_sampling(p; n_steps, sleep_per_step)
        ws_progress(__ws__, p; render=node -> node_to_html(
            h.div(; id="ws-param-result")(
                h.article(h.header("'$key' — $(n_steps) steps @ $(speed)ms"), htmx_render(node))
            )
        ))
        html = if istaskfailed(task)
            node_to_html(h.div(; id="ws-param-result")(h.article(h.header("Failed"))))
        else
            rv = fetch(task)
            node_to_html(h.div(; id="ws-param-result")(h.article(
                h.header("Result for '$key'"),
                h.p("$(length(rv)) values. Final: $(short_string(rv[end]))"),
            )))
        end
        try; send(__ws__, html); catch; end
    end

    # --- Pill demo: static snapshot of mixed child states ---
    @get pill_demo() = begin
        root = initialize_progress!(:state; description="Pathfinder")
        # Finished chain
        c1 = initialize_progress!(root, 1000; description="Chain 1")
        update_progress!(c1, 1000)
        finalize_progress!(c1)
        # Failed chain
        c2 = initialize_progress!(root, 1000; description="Chain 2")
        update_progress!(c2, 42)
        fail_progress!(c2)
        # Running chain
        c3 = initialize_progress!(root, 1000; description="Chain 3")
        update_progress!(c3, 350; stepsize="0.12", divergences="0")
        # Another finished chain
        c4 = initialize_progress!(root, 1000; description="Chain 4")
        update_progress!(c4, 1000)
        finalize_progress!(c4)

        h.div(
            h.h3("Pill demo — mixed child states"),
            h.p("Chain 1: finished, Chain 2: failed (dimmed — running sibling), Chain 3: running, Chain 4: finished";
                style="font-size:0.9em;color:var(--pico-muted-color)"),
            htmx_render_children(root),
        )
    end

    # --- Index page with both examples ---
    @get index = h.div(
        h.h1("Treebars Web Demo"),
        h.p(h.a(href="/tests")("Tests"), " | ", h.a(href="/pill_demo")("Pill demo"), " | Two approaches to live progress: HTTP polling and WebSockets."),

        h.hr(),
        h.h3("1. HTTP Polling"),
        h.p("Client polls every 200ms via hx-get + hx-trigger. Simple and stateless."; style="font-size:0.9em;color:var(--pico-muted-color)"),
        h.div(
            h.fieldset(; role="group")(
                h.input(; type="text", id="poll-key", value="poll-demo", placeholder="Key"),
                h.button("Run (polling)"; hx_get="/compute/poll-demo", hx_target="#poll-result", hx_swap="innerHTML",
                    _="on click set my @hx-get to '/compute/' + #poll-key.value"),
            ),
        ),
        h.div(; id="poll-result"),

        h.hr(),
        h.h3("2. WebSocket (server push)"),
        h.p("Server pushes HTML updates over a persistent connection. Lower latency, no polling overhead."; style="font-size:0.9em;color:var(--pico-muted-color)"),
        h.div(; hx_ext="ws", ws_connect="/ws")(
            h.form(; ws_send="true")(
                h.fieldset(; role="group")(
                    h.input(; type="text", name="key", value="ws-demo", placeholder="Key"),
                    h.button("Run (websocket)"; type="submit"),
                ),
            ),
        ),
        h.div(; id="ws-result"),

        h.hr(),
        h.h3("3. WebSocket with path params + kwargs"),
        h.p("Kwargs from query string: /ws_run?key=...&n_steps=...&speed=..."; style="font-size:0.9em;color:var(--pico-muted-color)"),
        h.form(; _="on submit halt the event then set key to #param-key.value then set steps to #param-steps.value then set spd to #param-speed.value then set url to '/ws_run?key=' + key + '&n_steps=' + steps + '&speed=' + spd then set #param-ws-container @ws-connect to url then js(htmx) htmx.process(document.getElementById('param-ws-container'))")(
            h.fieldset(; role="group")(
                h.input(; type="text", id="param-key", value="param-demo", placeholder="Key"),
                h.input(; type="number", id="param-steps", value="100", placeholder="Steps", style="max-width:6rem"),
                h.input(; type="number", id="param-speed", value="20", placeholder="Speed (ms)", style="max-width:7rem"),
                h.button("Run"; type="submit"),
            ),
        ),
        h.div(; id="param-ws-container", hx_ext="ws"),
        h.div(; id="ws-param-result"),
    )
end

function __init__()
    route!(AppContext())
end

end # module TreebarsWeb
