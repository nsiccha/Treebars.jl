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


# --- Async computation state (flat) ---
@dynamicstruct struct AsyncComputations
    __status__ = initialize_progress!(:state; description="Treebars Demo")
    results(key) = fake_sampling(__status__)
    parameterized(n_steps, sleep_per_step) = fake_sampling(__status__; n_steps, sleep_per_step)
end
_async = AsyncComputations(; cache_type=:parallel)

# --- Inline child demo: automatic substatus inheritance ---
# Sub inherits cache_type from parent and gets a scoped ProgressNode as __status__
# (provided by DynamicObjects/ext/TreebarsExt.jl default __substatus__ wiring)
@dynamicstruct struct NestedComputations
    __status__ = initialize_progress!(:state; description="Nested Demo")
    struct Sub
        results(key) = fake_sampling(__status__; n_steps=100, sleep_per_step=0.02)
    end
end
_nested = NestedComputations(; cache_type=:parallel)

# --- Auto-cleanup demo: exercises the new transient-substatus detach path ---
# Each `results[k]` call goes through DO's ThreadsafeDict.get! spawn block, which
# now calls _finalize_substatus! on success → the TreebarsExt override calls
# Treebars.finalize_progress! → transient nodes detach from the parent tree.
# Fire N in parallel, watch children count spike then collapse to 0.
@dynamicstruct struct AutoCleanupDemo
    __status__ = initialize_progress!(:state; description="AutoCleanup Demo")
    "Computing '$key'"
    results(key) = fake_sampling(__status__; n_steps=40, sleep_per_step=0.05)
    "Failing '$key'"
    failing(key) = begin
        child = initialize_progress!(__status__, 20; description="Working", propagates=true)
        for i in 1:10
            update_progress!(child, i); sleep(0.05)
        end
        error("boom on $key")
    end
end
_autocleanup = AutoCleanupDemo(; cache_type=:parallel)

_autocleanup_view(msg="") = h.div(;
    id="autocleanup-view",
    hx_get="/autocleanup_view", hx_trigger="every 300ms", hx_swap="outerHTML",
)(
    h.p("Root children: ", h.strong(string(length(_autocleanup.__status__.children))),
        isempty(msg) ? "" : " — $msg"),
    htmx_render(_autocleanup.__status__),
)

# --- Docstring descriptions demo ---
# Properties with docstrings use the docstring as progress description instead
# of the auto-generated "name[args]" format
@dynamicstruct struct DocstringDemo
    __status__ = initialize_progress!(:state; description="Docstring Demo")
    "Sampling chain"
    results(key) = fake_sampling(__status__)
    "Sampling $(n_steps) steps at $(sleep_per_step)s intervals"
    parameterized(n_steps, sleep_per_step) = fake_sampling(__status__; n_steps, sleep_per_step)
    "Cached sampling for $(key)"
    @cached cached_results(key) = fake_sampling(__status__)
end
_docstring = DocstringDemo(; cache_type=:parallel)

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


# --- Pill demo helpers ---

function _pill_demo_flat()
    root = initialize_progress!(:state; description="Pathfinder")
    c1 = initialize_progress!(root, 1000; description="Chain 1")
    update_progress!(c1, 1000); finalize_progress!(c1)
    c2 = initialize_progress!(root, 1000; description="Chain 2")
    update_progress!(c2, 42); fail_progress!(c2)
    c3 = initialize_progress!(root, 1000; description="Chain 3")
    update_progress!(c3, 350; stepsize="0.12", divergences="0")
    c4 = initialize_progress!(root, 1000; description="Chain 4")
    update_progress!(c4, 1000); finalize_progress!(c4)
    htmx_render_children(root)
end

function _pill_demo_nested()
    root = initialize_progress!(:state; description="Sim Dose-Response")
    # Healthy group: always-running parent, substatus children accumulate
    healthy = initialize_progress!(root; description="Healthy")
    for i in 1:3
        c = initialize_progress!(healthy, 500; description="auc24s[dose=$i]")
        update_progress!(c, 500); finalize_progress!(c)
    end
    c_run = initialize_progress!(healthy, 500; description="auc24s[dose=4]")
    update_progress!(c_run, 200)
    # PD group: one finished, one failed
    pd = initialize_progress!(root; description="PD")
    c_ok = initialize_progress!(pd, 500; description="mcfb_pbmc[dose=1]")
    update_progress!(c_ok, 500); finalize_progress!(c_ok)
    c_fail = initialize_progress!(pd, 500; description="mcfb_csf[dose=1]")
    update_progress!(c_fail, 100); fail_progress!(c_fail)
    htmx_render_children(root)
end

function _pill_demo_deep()
    root = initialize_progress!(:state; description="Experiment")
    for (gname, n_chains) in [("Group A", 4), ("Group B", 3)]
        group = initialize_progress!(root; description=gname)
        for ci in 1:n_chains
            chain = initialize_progress!(group, 1000; description="Chain $ci")
            if ci < n_chains
                update_progress!(chain, 1000; ess="$(rand(100:400))", rhat="$(round2(1.0 + rand()*0.02))")
                finalize_progress!(chain)
            elseif gname == "Group A"
                update_progress!(chain, 600; ess="$(rand(50:150))", rhat="$(round2(1.0 + rand()*0.1))")
            else
                update_progress!(chain, 200)
                fail_progress!(chain)
            end
        end
    end
    htmx_render_children(root)
end

function _pill_demo_all_finished()
    root = initialize_progress!(:state; description="Completed run")
    for i in 1:5
        c = initialize_progress!(root, 200; description="Step $i")
        update_progress!(c, 200); finalize_progress!(c)
    end
    htmx_render_children(root)
end

function _pill_demo_all_running()
    root = initialize_progress!(:state; description="Active run")
    for i in 1:3
        c = initialize_progress!(root, 500; description="Worker $i")
        update_progress!(c, i * 100)
    end
    htmx_render_children(root)
end

function _pill_demo_docstrings()
    # Compare auto-generated vs docstring descriptions in the same tree
    root = initialize_progress!(:state; description="Docstring vs Auto")
    # Simulate what _default_substatus produces WITHOUT a docstring
    auto1 = initialize_progress!(root; description="results[key1]")
    c = initialize_progress!(auto1, 500; description="MCMC", propagates=true)
    update_progress!(c, 500); finalize_progress!(c)
    auto2 = initialize_progress!(root; description="parameterized[200,0.02]")
    c = initialize_progress!(auto2, 500; description="MCMC", propagates=true)
    update_progress!(c, 300)
    # Simulate what _property_description produces WITH a docstring
    doc1 = initialize_progress!(root; description="Sampling chain")
    c = initialize_progress!(doc1, 500; description="MCMC", propagates=true)
    update_progress!(c, 500); finalize_progress!(c)
    doc2 = initialize_progress!(root; description="Sampling 200 steps at 0.02s intervals")
    c = initialize_progress!(doc2, 500; description="MCMC", propagates=true)
    update_progress!(c, 300)
    htmx_render_children(root)
end

@htmx struct AppContext
    page(content) = htmx(
        h.main(class="container")(content);
        pico_version="2",
        extra_head=(h.script(; src="https://unpkg.com/htmx-ext-ws@2.0.2/ws.js"), htmx_treebar_styles()),
    )

    # --- Test routes via @include ---
    @include tests = TestRoutes(; __req__, test_module=@__MODULE__)

    # --- Polling route (using polling_fetchindex with cancel support) ---
    @get compute(key; force::Bool=false) = polling_fetchindex(_async.results, key;
        poll_url=query_url("/compute/$key"), label="Computing '$key'",
        cancel_url=query_url("/cancel/$key"), force,
    ) do rv
        h.article(
            h.header("Result for '$key'"),
            h.p("Computed $(length(rv)) values. Final: $(short_string(rv[end]))"),
            h.p("Min: $(short_string(minimum(rv))), Max: $(short_string(maximum(rv)))"),
            h.button("Rerun"; hx_get=query_url("/compute/$key"; force=true), hx_target="closest article", hx_swap="outerHTML"),
        )
    end

    # --- Cancel route ---
    @get cancel(key) = begin
        cancel!(_async.results, key)
        h.article(h.header("Cancelled '$key'"), h.p("Task was cancelled."))
    end

    # --- Parameterized route (no docstring, for baseline comparison) ---
    @get param_compute(n_steps::Int, sleep_ms::Int; force::Bool=false) = begin
        sleep_per_step = sleep_ms / 1000.0
        polling_fetchindex(_async.parameterized, n_steps, sleep_per_step;
            poll_url=query_url("/param_compute/$n_steps/$sleep_ms"), label="Parameterized", force,
        ) do rv
            h.article(
                h.header("Result ($n_steps steps @ $(sleep_ms)ms)"),
                h.p("Computed $(length(rv)) values. Final: $(short_string(rv[end]))"),
                h.button("Rerun"; hx_get=query_url("/param_compute/$n_steps/$sleep_ms"; force=true), hx_target="closest article", hx_swap="outerHTML"),
            )
        end
    end

    # --- Inline child demo route ---
    # _nested.Sub inherits cache_type=:parallel and gets a scoped ProgressNode under _nested.__status__
    @get nested_compute(key; force::Bool=false) = polling_fetchindex(_nested.Sub.results, key;
        poll_url=query_url("/nested_compute/$key"), label="Nested '$key'", force,
    ) do rv
        h.article(
            h.header("Nested result for '$key'"),
            h.p("Computed $(length(rv)) values. Final: $(short_string(rv[end]))"),
            h.p("Min: $(short_string(minimum(rv))), Max: $(short_string(maximum(rv)))"),
            h.button("Rerun"; hx_get=query_url("/nested_compute/$key"; force=true), hx_target="closest article", hx_swap="outerHTML"),
        )
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

    # --- Docstring description demo routes ---
    @get dsdemo_compute(key; force::Bool=false) = polling_fetchindex(_docstring.results, key;
        poll_url=query_url("/dsdemo_compute/$key"), label="Docstring '$key'", force,
    ) do rv
        h.article(
            h.header("Result for '$key'"),
            h.p("Computed $(length(rv)) values. Final: $(short_string(rv[end]))"),
            h.button("Rerun"; hx_get=query_url("/dsdemo_compute/$key"; force=true), hx_target="closest article", hx_swap="outerHTML"),
        )
    end

    @get dsdemo_cached(key; force::Bool=false) = polling_fetchindex(_docstring.cached_results, key;
        poll_url=query_url("/dsdemo_cached/$key"), label="Cached '$key'", force,
    ) do rv
        h.article(
            h.header("Cached result for '$key'"),
            h.p("Computed $(length(rv)) values. Final: $(short_string(rv[end]))"),
            h.button("Rerun"; hx_get=query_url("/dsdemo_cached/$key"; force=true), hx_target="closest article", hx_swap="outerHTML"),
        )
    end

    @get dsdemo_param(n_steps::Int, sleep_ms::Int; force::Bool=false) = begin
        sleep_per_step = sleep_ms / 1000.0
        polling_fetchindex(_docstring.parameterized, n_steps, sleep_per_step;
            poll_url=query_url("/dsdemo_param/$n_steps/$sleep_ms"), label="Parameterized", force,
        ) do rv
            h.article(
                h.header("Result ($n_steps steps @ $(sleep_ms)ms)"),
                h.p("Computed $(length(rv)) values. Final: $(short_string(rv[end]))"),
                h.button("Rerun"; hx_get=query_url("/dsdemo_param/$n_steps/$sleep_ms"; force=true), hx_target="closest article", hx_swap="outerHTML"),
            )
        end
    end

    # --- Auto-cleanup demo routes ---
    @get autocleanup_demo = h.div(
        h.h3("Auto-cleanup demo"),
        h.p("Fires N parallel ", h.code("_autocleanup.results[randkey]"),
            " computations. With the new TreebarsExt hook, each substatus detaches from the root tree on success — watch the ",
            h.em("Root children"), " count spike during the run and collapse back to 0. The failing button stays pinned as a red child."),
        h.fieldset(; role="group")(
            h.button("Fire 8"; hx_get="/autocleanup_fire/8", hx_target="#autocleanup-view", hx_swap="outerHTML"),
            h.button("Fire 16"; hx_get="/autocleanup_fire/16", hx_target="#autocleanup-view", hx_swap="outerHTML"),
            h.button("Fire failing"; hx_get="/autocleanup_fire_fail", hx_target="#autocleanup-view", hx_swap="outerHTML"),
        ),
        _autocleanup_view(),
    )

    @get autocleanup_view = _autocleanup_view()

    @get autocleanup_fire(n::Int) = begin
        for _ in 1:n
            k = "k$(rand(1:1_000_000))"
            Threads.@spawn try; _autocleanup.results[k]; catch; end
        end
        _autocleanup_view("spawned $n tasks")
    end

    @get autocleanup_fire_fail = begin
        k = "boom$(rand(1:1_000_000))"
        Threads.@spawn try; _autocleanup.failing[k]; catch; end
        _autocleanup_view("spawned failing '$k' (stays pinned)")
    end
    # --- Pill demos: various nesting patterns ---
    @get pill_demo = begin
        h.div(
            h.h3("Pill Demos"),
            h.p("Various tree structures demonstrating pill filtering at different nesting levels.";
                style="font-size:0.9em;color:var(--pico-muted-color)"),

            # 1. Flat: mixed states at one level
            h.h4("1. Flat — mixed child states"),
            _pill_demo_flat(),

            h.hr(),

            # 2. Nested: two-level tree (like Bruno analysis tabs)
            h.h4("2. Nested — structural parents with substatus children"),
            h.p("Simulates the Bruno pattern: always-running parent nodes with finished/failed/running grandchildren.";
                style="font-size:0.85em;color:var(--pico-muted-color)"),
            _pill_demo_nested(),

            h.hr(),

            # 3. Deep: three levels of nesting
            h.h4("3. Deep — three-level tree"),
            h.p("Root → groups → chains → labels. Pills should appear at every level.";
                style="font-size:0.85em;color:var(--pico-muted-color)"),
            _pill_demo_deep(),

            h.hr(),

            # 4. All finished: only pills, no running children
            h.h4("4. All finished — only pills visible"),
            _pill_demo_all_finished(),

            h.hr(),

            # 5. All running: no pills needed
            h.h4("5. All running — no pills"),
            _pill_demo_all_running(),

            h.hr(),

            # 6. Docstring descriptions: side-by-side comparison
            h.h4("6. Docstring descriptions — auto vs custom"),
            h.p("Top two nodes show auto-generated descriptions (\"results[key1]\", \"parameterized[200,0.02]\"). Bottom two show the same properties with docstrings (\"Sampling chain\", \"Sampling 200 steps at 0.02s intervals\").";
                style="font-size:0.85em;color:var(--pico-muted-color)"),
            _pill_demo_docstrings(),
        )
    end

    # --- Index page with both examples ---
    @get index = h.div(
        h.h1("Treebars Web Demo"),
        h.p(h.a(href="/tests")("Tests"), " | ", h.a(href="/pill_demo")("Pill demos"), " | ", h.a(href="/autocleanup_demo")("Auto-cleanup demo"), " | HTTP polling, WebSockets, and inline child substatus."),

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
        h.h3("3. Inline child substatus (new pattern)"),
        h.p("Demonstrates automatic substatus inheritance: the inline Sub struct gets its own ProgressNode under the parent's status. No manual __substatus__ needed."; style="font-size:0.9em;color:var(--pico-muted-color)"),
        h.div(
            h.fieldset(; role="group")(
                h.input(; type="text", id="nested-key", value="nested-demo", placeholder="Key"),
                h.button("Run (nested)"; hx_get="/nested_compute/nested-demo", hx_target="#nested-result", hx_swap="innerHTML",
                    _="on click set my @hx-get to '/nested_compute/' + #nested-key.value"),
            ),
        ),
        h.div(; id="nested-result"),

        h.hr(),
        h.h3("4. Docstring descriptions (new)"),
        h.p("Left: auto-generated description (\"results[key]\"). Right: docstring as progress description (\"Sampling chain\"). Run both and compare the progress text."; style="font-size:0.9em;color:var(--pico-muted-color)"),
        h.div(; style="display:grid;grid-template-columns:1fr 1fr;gap:1rem")(
            h.div(
                h.h5("Without docstring"),
                h.fieldset(; role="group")(
                    h.input(; type="text", id="doc-cmp-key", value="compare", placeholder="Key"),
                    h.button("Run"; hx_get="/compute/compare", hx_target="#doc-cmp-left", hx_swap="innerHTML",
                        _="on click set my @hx-get to '/compute/' + #doc-cmp-key.value"),
                ),
                h.div(; id="doc-cmp-left"),
            ),
            h.div(
                h.h5("With docstring"),
                h.fieldset(; role="group")(
                    h.input(; type="text", id="doc-cmp-key2", value="compare", placeholder="Key"),
                    h.button("Run"; hx_get="/dsdemo_compute/compare", hx_target="#doc-cmp-right", hx_swap="innerHTML",
                        _="on click set my @hx-get to '/dsdemo_compute/' + #doc-cmp-key2.value"),
                ),
                h.div(; id="doc-cmp-right"),
            ),
        ),
        h.p("Interpolated: auto-generated shows \"parameterized[100,0.02]\", docstring shows \"Sampling 100 steps at 0.02s intervals\"."; style="font-size:0.9em;color:var(--pico-muted-color);margin-top:0.5rem"),
        h.div(; style="display:grid;grid-template-columns:1fr 1fr;gap:1rem")(
            h.div(
                h.h5("Without docstring"),
                h.fieldset(; role="group")(
                    h.input(; type="number", id="doc-steps-l", value="100", placeholder="Steps", style="max-width:6rem"),
                    h.input(; type="number", id="doc-sleep-l", value="20", placeholder="ms", style="max-width:6rem"),
                    h.button("Run"; hx_get="/param_compute/100/20", hx_target="#doc-param-left", hx_swap="innerHTML",
                        _="on click set my @hx-get to '/param_compute/' + #doc-steps-l.value + '/' + #doc-sleep-l.value"),
                ),
                h.div(; id="doc-param-left"),
            ),
            h.div(
                h.h5("With docstring"),
                h.fieldset(; role="group")(
                    h.input(; type="number", id="doc-steps-r", value="100", placeholder="Steps", style="max-width:6rem"),
                    h.input(; type="number", id="doc-sleep-r", value="20", placeholder="ms", style="max-width:6rem"),
                    h.button("Run"; hx_get="/dsdemo_param/100/20", hx_target="#doc-param-right", hx_swap="innerHTML",
                        _="on click set my @hx-get to '/dsdemo_param/' + #doc-steps-r.value + '/' + #doc-sleep-r.value"),
                ),
                h.div(; id="doc-param-right"),
            ),
        ),

        h.hr(),
        h.h3("5. WebSocket with path params + kwargs"),
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
