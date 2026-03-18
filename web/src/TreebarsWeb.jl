module TreebarsWeb

using HTMXObjects
using Treebars
import HTTP.WebSockets: send
using TestModules
using Random

# Include tests — defer so they register but don't run on load
TestModules.defer!()
include("runtests.jl")
TestModules.undefer!()

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

progress_html(state) = begin
    children = get(state, "children", [])
    parts = []
    for cs in children
        N = cs["N"]
        i = cs["i"]
        desc = cs["description"]
        push!(parts, h.div(; style="margin-bottom:8px")(
            h.strong("$(desc): "),
            isnothing(N) ? h.span(cs["message"]) :
                h.span("$(i) / $(N)"),
            isnothing(N) ? "" :
                h.progress(; value=string(i), max=string(N), style="margin-top:4px"),
        ))
        for sc in get(cs, "children", [])
            push!(parts, h.div(; style="margin-left:1rem;font-size:0.9em;color:var(--pico-muted-color)")(
                h.span("$(sc["description"]) "),
                h.span(sc["message"]),
            ))
        end
    end
    h.div(parts...)
end

# --- Polling example state ---
_tasks = Dict{String, Task}()
_progress = Dict{String, Any}()
_results = Dict{String, Any}()

function start_computation(key)
    haskey(_results, key) && return
    haskey(_tasks, key) && !istaskdone(_tasks[key]) && return
    p = initialize_progress!(:state; description="Running '$key'")
    _progress[key] = p
    _tasks[key] = Threads.@spawn begin
        result = fake_sampling(p)
        _results[key] = result
        result
    end
end

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
    md = wants_markdown(req)

    # --- Test routes (via HTMXObjects TestModulesExt) ---
    @get tests = test_list(@__MODULE__, md)
    @post tests_run(name) = test_run!(@__MODULE__, name, md)
    @post tests_run_all = test_run_all!(@__MODULE__, md)
    @post tests_run_missing = test_run_missing!(@__MODULE__, md)
    @post tests_run_failed = test_run_failed!(@__MODULE__, md)
    @post tests_run_batch(; names="") = test_run_batch!(@__MODULE__, names, md)
    @post tests_clear_cache = test_clear_cache!(@__MODULE__, md)

    # --- Polling route ---
    @get compute(key) = begin
        start_computation(key)
        task = _tasks[key]
        if !istaskdone(task)
            state = progress_state(_progress[key])
            h.div(; hx_get="/compute/$key", hx_trigger="every 200ms", hx_swap="outerHTML")(
                h.article(
                    h.header("Computing '$key'..."),
                    progress_html(state),
                )
            )
        elseif istaskfailed(task)
            h.article(h.header("Failed"), h.pre(sprint(showerror, task.result)))
        else
            rv = _results[key]
            h.article(
                h.header("Result for '$key'"),
                h.p("Computed $(length(rv)) values. Final: $(short_string(rv[end]))"),
                h.p("Min: $(short_string(minimum(rv))), Max: $(short_string(maximum(rv)))"),
            )
        end
    end

    # --- WebSocket routes ---
    # __ws__ is the WebSocket, injected by @htmx's @ws handling
    @ws ws = begin
        for msg in __ws__
            key = "ws-" * msg
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

    # --- Index page with both examples ---
    @get index = htmx(
        h.main(class="container")(
            h.h1("Treebars Web Demo"),
            h.p(h.a(href="/tests")("Tests"), " | Two approaches to live progress: HTTP polling and WebSockets."),

            h.hr(),
            h.h3("1. HTTP Polling"),
            h.p("Client polls every 200ms via hx-get + hx-trigger. Simple and stateless."; style="font-size:0.9em;color:var(--pico-muted-color)"),
            h.form(; hx_get="/compute/poll-demo", hx_target="#poll-result", hx_swap="innerHTML")(
                h.fieldset(; role="group")(
                    h.input(; type="text", name="key", value="poll-demo", placeholder="Key",
                        _="on input set @hx-get of closest <form/> to '/compute/' + my value"),
                    h.button("Run (polling)"; type="submit"),
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
            h.form(; _="on submit halt the event
                set key to #param-key.value
                set steps to #param-steps.value
                set spd to #param-speed.value
                set url to '/ws_run?key=' + key + '&n_steps=' + steps + '&speed=' + spd
                set #param-ws-container @ws-connect to url
                js(htmx) htmx.process(document.getElementById('param-ws-container'))")(
                h.fieldset(; role="group")(
                    h.input(; type="text", id="param-key", value="param-demo", placeholder="Key"),
                    h.input(; type="number", id="param-steps", value="100", placeholder="Steps", style="max-width:6rem"),
                    h.input(; type="number", id="param-speed", value="20", placeholder="Speed (ms)", style="max-width:7rem"),
                    h.button("Run"; type="submit"),
                ),
            ),
            h.div(; id="param-ws-container", hx_ext="ws"),
            h.div(; id="ws-param-result"),
        ),
        h.script(; src="https://unpkg.com/htmx-ext-ws@2.0.2/ws.js");
        pico_version="2",
    )
end

function __init__()
    route!(AppContext())
end

end # module TreebarsWeb
